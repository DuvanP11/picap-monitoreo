# app/controllers/api/saldo_recaudos_controller.rb
# v3.3.28 — Saldo Recaudos: balance mensual Recaudos vs Servicios B2B.
#
# Paridad EXACTA con recaudos_bi/generar_recaudos.py (validado abril 2026:
# total $414,712,527 cuadra centavo a centavo, Surtitodo -$33,910.04).
#
# Endpoints:
#   GET  /api/saldo_recaudos/estadisticas        → KPIs principales + top empresas + resumen Surtitodo
#   GET  /api/saldo_recaudos/query_recaudos      → data hoja "Query Recaudos"   (async + polling)
#   GET  /api/saldo_recaudos/query_transacciones → data hoja "Query Transacciones" (async + polling)
#   GET  /api/saldo_recaudos/informe_general     → Excel 5 hojas + Surtitodo (async + polling)
#   GET  /api/saldo_recaudos/job_status/:job_id  → polling de jobs async
#   POST /api/saldo_recaudos/enviar_email        → manda Excel adjunto por email
#
# Roles: admin / monitoreo / financiero (mismo patrón MoviiRed / MINTIC).

module Api
  class SaldoRecaudosController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol_saldo_recaudos

    ROLES_PERMITIDOS = %w[admin monitoreo financiero].freeze
    LIMIT_UI         = 5_000

    # Clientes considerados "pruebas" (cuentas internas) en el comentario de Control.
    CLIENTES_PRUEBA = %w[PIBOX\ ADMIN TESTEO\ 2].freeze

    # Storage en memoria de jobs async (mismo patrón que MINTIC).
    @@jobs = {}
    @@jobs_mutex = Mutex.new
    JOB_TTL_SEC = 1_800

    # GET /api/saldo_recaudos/estadisticas?desde=YYYY-MM-DD&hasta=YYYY-MM-DD
    # Devuelve KPIs SIN ejecutar queries pesadas — solo agregados rápidos.
    # Si los datos están en cache (job done) los reusa. Si no, los calcula sync.
    def estadisticas
      desde = desde_param
      hasta = hasta_param

      cache_key = "estadisticas_#{desde}_#{hasta}"
      hit = buscar_job_done(cache_key)
      return render(json: hit[:result]) if hit

      # No cacheado: lanzo el cálculo en background y devuelvo job_id.
      job_id = lanzar_job(cache_key, "estadisticas", desde, hasta) do
        recaudos = ejecutar_query_recaudos(desde, hasta)
        transacciones = ejecutar_query_transacciones(desde, hasta)
        construir_estadisticas(desde, hasta, recaudos, transacciones)
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[SaldoRecaudosController#estadisticas] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/saldo_recaudos/query_recaudos?desde=...&hasta=...
    def query_recaudos
      desde = desde_param
      hasta = hasta_param
      cache_key = "query_recaudos_#{desde}_#{hasta}"

      hit = buscar_job_done(cache_key)
      return render(json: hit[:result]) if hit

      job_id = lanzar_job(cache_key, "query_recaudos", desde, hasta) do
        rows = ejecutar_query_recaudos(desde, hasta)
        limpiar({
          ok: true, async: false,
          desde: desde, hasta: hasta,
          total: rows.size,
          filas: rows.first(LIMIT_UI),
        })
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[SaldoRecaudosController#query_recaudos] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/saldo_recaudos/query_transacciones?desde=...&hasta=...
    def query_transacciones
      desde = desde_param
      hasta = hasta_param
      cache_key = "query_transacciones_#{desde}_#{hasta}"

      hit = buscar_job_done(cache_key)
      return render(json: hit[:result]) if hit

      job_id = lanzar_job(cache_key, "query_transacciones", desde, hasta) do
        rows = ejecutar_query_transacciones(desde, hasta)
        limpiar({
          ok: true, async: false,
          desde: desde, hasta: hasta,
          total: rows.size,
          filas: rows.first(LIMIT_UI),
        })
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[SaldoRecaudosController#query_transacciones] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/saldo_recaudos/informe_general?desde=...&hasta=...
    # Genera el Excel completo de 5 hojas + tabla Surtitodo.
    # Async: devuelve job_id; el frontend descarga vía GET /informe_general?job_id=X&download=1.
    def informe_general
      desde = desde_param
      hasta = hasta_param

      # Si viene download=1 + job_id, devolvemos el binario del Excel.
      if params[:download].to_s == "1" && params[:job_id].present?
        return _descargar_excel(params[:job_id].to_s)
      end

      cache_key = "informe_general_#{desde}_#{hasta}"
      hit = buscar_job_done(cache_key)
      if hit
        # Re-uso del job done — devolvemos su job_id para que el frontend descargue.
        job_id = @@jobs_mutex.synchronize { @@jobs.find { |_, j| j[:cache_key] == cache_key && j[:status] == :done }&.first }
        return render(json: { ok: true, async: false, job_id: job_id, status: "done", listo_para_descargar: true })
      end

      job_id = lanzar_job(cache_key, "informe_general", desde, hasta) do
        recaudos      = ejecutar_query_recaudos(desde, hasta)
        transacciones = ejecutar_query_transacciones(desde, hasta)
        company_ids   = transacciones.map { |r| r["company_id"].to_s }.reject(&:empty?).uniq
        comisiones    = ejecutar_query_comisiones(company_ids)
        excel = SaldoRecaudosExcelBuilder.build(
          desde:         desde,
          hasta:         hasta,
          recaudos:      recaudos,
          transacciones: transacciones,
          comisiones:    comisiones,
        )
        {
          ok:               true,
          async:            false,
          desde:            desde,
          hasta:            hasta,
          total_recaudos:   recaudos.size,
          total_transacciones: transacciones.size,
          excel_bytes:      excel[:data],
          excel_filename:   excel[:filename],
          listo_para_descargar: true,
        }
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[SaldoRecaudosController#informe_general] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/saldo_recaudos/job_status/:job_id
    def job_status
      job_id = params[:job_id].to_s
      cleanup_old_jobs
      @@jobs_mutex.synchronize do
        job = @@jobs[job_id]
        return render(json: { ok: false, error: "Job no encontrado o expirado (>30 min)" }, status: :not_found) if job.nil?
        case job[:status]
        when :done
          # Para el Excel binario NO lo metemos en el JSON (sería enorme).
          # Devolvemos los metadatos y el frontend pide aparte el binario.
          if job[:kind] == "informe_general" && job[:result][:excel_bytes]
            render json: job[:result].except(:excel_bytes).merge(
              job_id: job_id,
              listo_para_descargar: true,
            )
          else
            render json: job[:result]
          end
        when :error
          render json: { ok: false, error: job[:error], job_id: job_id }, status: :internal_server_error
        else
          elapsed = (Time.now - job[:t0]).round(1)
          render json: {
            ok: true, async: true, status: "running",
            elapsed_sec: elapsed, job_id: job_id,
            kind: job[:kind], desde: job[:desde], hasta: job[:hasta],
          }, status: :accepted
        end
      end
    end

    # POST /api/saldo_recaudos/enviar_email
    # Body: { email|to, cc?, bcc?, asunto?, mensaje?, desde, hasta }
    def enviar_email
      to_list  = parse_email_list(params[:email] || params[:to])
      cc_list  = parse_email_list(params[:cc])
      bcc_list = parse_email_list(params[:bcc])
      asunto   = params[:asunto].to_s.strip
      mensaje  = params[:mensaje].to_s.strip[0, 1000]
      desde    = desde_param
      hasta    = hasta_param
      usuario  = current_usuario.to_s

      if to_list.empty?
        return render(json: { ok: false, error: "Tenés que ingresar al menos un destinatario en 'Para'." }, status: :bad_request)
      end

      invalid = (to_list + cc_list + bcc_list).reject { |e| e.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) }
      if invalid.any?
        return render(json: { ok: false, error: "Email(s) inválido(s): #{invalid.join(', ')}" }, status: :bad_request)
      end

      # v3.3.48: BackgroundEmailJobsHelper con tracking — frontend hace polling.
      # auto_zip:true comprime adjuntos > 20MB para que entren en límite Resend.
      controller = self
      job_id = BackgroundEmailJobsHelper.start(label: "SaldoRecaudos", to: to_list) do |progress|
        progress.call("cargando_datos")
        recaudos      = controller.send(:ejecutar_query_recaudos, desde, hasta)
        transacciones = controller.send(:ejecutar_query_transacciones, desde, hasta)
        company_ids   = transacciones.map { |r| r["company_id"].to_s }.reject(&:empty?).uniq
        comisiones    = controller.send(:ejecutar_query_comisiones, company_ids)

        progress.call("construyendo_excel")
        excel = SaldoRecaudosExcelBuilder.build(
          desde:         desde,
          hasta:         hasta,
          recaudos:      recaudos,
          transacciones: transacciones,
          comisiones:    comisiones,
        )

        subject_default = "Saldo Recaudos · #{desde} → #{hasta}"
        html = controller.send(:construir_html_email, desde, hasta, recaudos, transacciones, mensaje, usuario)

        ResendMailerService.send_email(
          to:                  to_list,
          cc:                  cc_list,
          bcc:                 bcc_list,
          subject:             asunto.empty? ? subject_default : asunto,
          html:                html,
          attachment_bytes:    excel[:data],
          attachment_filename: excel[:filename],
          auto_zip:            true,
          progress:            progress,
        )
      end

      render json: {
        ok: true,
        queued: true,
        job_id: job_id,
        destinatarios: to_list,
        cc: cc_list,
        bcc: bcc_list,
        mensaje: "Reporte en proceso. Polling a /enviar_email_status/:job_id.",
      }, status: :accepted
    rescue => e
      Rails.logger.error("[SaldoRecaudosController#enviar_email] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # v3.3.48: GET /api/saldo_recaudos/enviar_email_status/:job_id
    def enviar_email_status
      job = BackgroundEmailJobsHelper.get_status(params[:job_id].to_s)
      if job.nil?
        return render(json: { ok: false, error: "Job no encontrado o expirado" },
                      status: :not_found)
      end
      render json: BackgroundEmailJobsHelper.serialize(job)
    end

    private

    # ──────────────────────────────────────────────────────────────────────
    # Ejecutar queries CH
    # ──────────────────────────────────────────────────────────────────────

    def ejecutar_query_recaudos(desde, hasta)
      sql = QueriesService.format(
        QueriesService::Q_SALDO_RECAUDOS_RECAUDOS,
        fecha_desde: desde, fecha_hasta: hasta,
      )
      t0 = Time.now
      Rails.logger.info("[SaldoRecaudos] Q_RECAUDOS inicio (#{desde} → #{hasta})")
      rows = ch.query(sql, timeout: 600)
      Rails.logger.info("[SaldoRecaudos] Q_RECAUDOS OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    def ejecutar_query_transacciones(desde, hasta)
      sql = QueriesService.format(
        QueriesService::Q_SALDO_RECAUDOS_TRANSACCIONES,
        fecha_desde: desde, fecha_hasta: hasta,
      )
      t0 = Time.now
      Rails.logger.info("[SaldoRecaudos] Q_TRANSACCIONES inicio (#{desde} → #{hasta})")
      rows = ch.query(sql, timeout: 600)
      Rails.logger.info("[SaldoRecaudos] Q_TRANSACCIONES OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    def ejecutar_query_comisiones(company_ids)
      return {} if company_ids.empty?
      ids_str = company_ids.map { |id| "'#{id}'" }.join(",")
      sql = QueriesService.format(
        QueriesService::Q_SALDO_RECAUDOS_COMMISSION,
        ids: ids_str,
      )
      rows = ch.query(sql, timeout: 120)
      rows.each_with_object({}) { |r, h| h[r["_id"].to_s] = r["fee"].to_f }
    rescue => e
      Rails.logger.warn("[SaldoRecaudos] comisiones falló: #{e.message}")
      {}
    end

    # ──────────────────────────────────────────────────────────────────────
    # Stats / agregados
    # ──────────────────────────────────────────────────────────────────────

    def construir_estadisticas(desde, hasta, recaudos, transacciones)
      # Pivot por empresa de RECAUDOS (User_Company → ΣTransaction_amount)
      por_empresa_recaudos = recaudos
        .group_by { |r| r["User_Company"].to_s }
        .reject { |emp, _| emp.empty? }
        .map { |emp, g| [emp, g.sum { |r| r["Transaction_amount"].to_f }] }
        .sort_by { |_, monto| -monto }

      total_recaudos = por_empresa_recaudos.sum { |_, m| m }

      # Pivot por Company_name de TRANSACCIONES → suma de Servicios
      por_empresa_servicios = transacciones
        .group_by { |r| r["Company_name"].to_s }
        .reject { |emp, _| emp.empty? }
        .map do |emp, g|
          servicios = g.sum do |r|
            t = r["TXT_TYPE"].to_s
            v = r["VAL_AMOUNT"].to_f
            (t == "WalletAccountTransactionBookingCompanyCharge" ||
             t == "WalletAccountTransactionCommissionCompanyPayment") ? v : 0.0
          end
          recs = g.sum do |r|
            (r["TXT_TYPE"].to_s == "WalletAccountCounterDeliveryPaymentTransaction") ? r["VAL_AMOUNT"].to_f : 0.0
          end
          { empresa: emp, servicios: servicios.round(2), recaudos_tx: recs.round(2) }
        end
        .sort_by { |h| -h[:recaudos_tx].abs }

      total_servicios = por_empresa_servicios.sum { |h| h[:servicios] }

      # Resumen Surtitodo
      surtitodo_rec_tx_total = por_empresa_recaudos.find { |emp, _| emp.downcase.strip == "surtitodo express" }&.last.to_f
      surtitodo_servicios    = por_empresa_servicios.find { |h| h[:empresa].downcase.strip == "surtitodo express" }
      surtitodo_servicios_val = surtitodo_servicios ? surtitodo_servicios[:servicios] : 0.0
      surtitodo_comision     = -surtitodo_rec_tx_total * 0.01
      surtitodo_ica          = (-surtitodo_servicios_val * 9.66) / 1000.0
      surtitodo_total        = surtitodo_rec_tx_total + surtitodo_servicios_val + surtitodo_comision + surtitodo_ica

      # Top empresas (ranking por Recaudo absoluto)
      top_empresas = por_empresa_recaudos.first(10).map { |emp, monto|
        { empresa: emp, recaudos: monto.round(2) }
      }

      limpiar({
        ok: true,
        async: false,
        desde: desde,
        hasta: hasta,
        kpis: {
          total_recaudos:        total_recaudos.round(2),
          total_servicios:       total_servicios.round(2),
          balance_neto:          (total_recaudos + total_servicios).round(2),
          empresas_activas:      por_empresa_recaudos.size,
          transacciones:         transacciones.size,
          bookings_recaudo:      recaudos.uniq { |r| r["ID_Booking"] }.size,
        },
        top_empresas: top_empresas,
        surtitodo: {
          recaudos:  surtitodo_rec_tx_total.round(2),
          servicios: surtitodo_servicios_val.round(2),
          comision:  surtitodo_comision.round(2),
          ica:       surtitodo_ica.round(2),
          total:     surtitodo_total.round(2),
        },
      })
    end

    # ──────────────────────────────────────────────────────────────────────
    # Async jobs (mismo patrón MINTIC)
    # ──────────────────────────────────────────────────────────────────────

    def lanzar_job(cache_key, kind, desde, hasta, &block)
      job_id = SecureRandom.hex(16)
      @@jobs_mutex.synchronize do
        @@jobs[job_id] = {
          status: :running,
          kind: kind, desde: desde, hasta: hasta,
          cache_key: cache_key,
          t0: Time.now,
        }
      end
      Thread.new do
        begin
          result = block.call
          @@jobs_mutex.synchronize do
            @@jobs[job_id][:status] = :done
            @@jobs[job_id][:result] = result
            @@jobs[job_id][:t_elapsed] = Time.now - @@jobs[job_id][:t0]
          end
          Rails.logger.info("[SaldoRecaudosJob #{job_id}] #{kind} OK en #{@@jobs[job_id][:t_elapsed].round(1)}s")
        rescue => e
          Rails.logger.error("[SaldoRecaudosJob #{job_id}] #{e.class}: #{e.message}")
          Rails.logger.error(e.backtrace.first(8).join("\n"))
          @@jobs_mutex.synchronize do
            @@jobs[job_id][:status] = :error
            @@jobs[job_id][:error] = e.message
          end
        end
      end
      job_id
    end

    def buscar_job_done(cache_key)
      @@jobs_mutex.synchronize do
        @@jobs.values.find { |j| j[:cache_key] == cache_key && j[:status] == :done }
      end
    end

    def cleanup_old_jobs
      now = Time.now
      @@jobs_mutex.synchronize do
        @@jobs.delete_if { |_id, job| now - job[:t0] > JOB_TTL_SEC }
      end
    end

    # Devuelve el Excel binario para descargar (consumido por el frontend
    # cuando informe_general?download=1&job_id=X).
    def _descargar_excel(job_id)
      cleanup_old_jobs
      job = @@jobs_mutex.synchronize { @@jobs[job_id] }
      return render(json: { ok: false, error: "Job no encontrado o expirado" }, status: :not_found) if job.nil?
      return render(json: { ok: false, error: "Job aún corriendo o falló" }, status: :unprocessable_entity) unless job[:status] == :done
      bytes = job[:result][:excel_bytes]
      filename = job[:result][:excel_filename]
      send_data bytes,
                filename: filename,
                type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                disposition: "attachment"
    end

    # ──────────────────────────────────────────────────────────────────────
    # Params + auth
    # ──────────────────────────────────────────────────────────────────────

    def desde_param
      v = params[:desde].to_s.strip
      return v if v.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      # Default: primer día del mes actual
      Date.today.beginning_of_month.strftime("%Y-%m-%d")
    end

    def hasta_param
      v = params[:hasta].to_s.strip
      return v if v.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      # Default: último día del mes actual
      Date.today.end_of_month.strftime("%Y-%m-%d")
    end

    def validar_rol_saldo_recaudos
      return if ROLES_PERMITIDOS.include?(current_rol.to_s)
      render json: {
        ok: false,
        error: "Acceso restringido — solo roles: #{ROLES_PERMITIDOS.join(', ')}. Tu rol: #{current_rol || 'sin rol'}",
      }, status: :forbidden
    end

    def parse_email_list(value)
      return [] if value.blank?
      list = value.is_a?(Array) ? value : value.to_s.split(/[,;\n]+/)
      list.map { |s| s.to_s.strip }.reject(&:empty?).uniq
    end

    # HTML email corporativo Picap — KPIs + tabla resumen Surtitodo.
    def construir_html_email(desde, hasta, recaudos, transacciones, mensaje_usuario, autor)
      stats = construir_estadisticas(desde, hasta, recaudos, transacciones)
      kpis  = stats[:kpis]
      surt  = stats[:surtitodo]

      money = ->(n) { n.to_f.round(2).to_s.gsub(/\B(?=(\d{3})+(?!\d))/, ".") }

      mensaje_html = mensaje_usuario.to_s.strip.empty? ? "" : %Q{
        <div style="background:#F3F0FA;border-left:4px solid #6B21A8;padding:14px 18px;margin:16px 0;border-radius:6px;">
          <p style="margin:0;color:#1E1333;font-size:14px;">#{ERB::Util.h(mensaje_usuario)}</p>
        </div>
      }

      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;background:#F8F7FB;margin:0;padding:24px;">
          <div style="max-width:720px;margin:0 auto;background:#FFFFFF;border-radius:12px;overflow:hidden;box-shadow:0 4px 16px rgba(30,19,51,0.08);">
            <div style="background:linear-gradient(135deg,#6B21A8 0%,#1E1333 100%);padding:28px 32px;">
              <h1 style="margin:0;color:#FFFFFF;font-size:22px;">Saldo Recaudos</h1>
              <p style="margin:6px 0 0 0;color:#EDE9F5;font-size:14px;">#{desde} → #{hasta}</p>
            </div>
            <div style="padding:28px 32px;">
              #{mensaje_html}
              <h2 style="color:#1E1333;font-size:16px;margin:0 0 12px 0;">📊 KPIs principales</h2>
              <table width="100%" cellspacing="0" cellpadding="10" style="border-collapse:collapse;font-size:14px;">
                <tr><td style="border:1px solid #EDE9F5;color:#6B21A8;font-weight:bold;">Total Recaudos</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;color:#16A34A;font-weight:bold;">$ #{money.call(kpis[:total_recaudos])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;color:#6B21A8;font-weight:bold;">Total Servicios</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;color:#DC2626;font-weight:bold;">$ #{money.call(kpis[:total_servicios])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;color:#6B21A8;font-weight:bold;">Balance Neto</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;font-weight:bold;">$ #{money.call(kpis[:balance_neto])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;color:#6B21A8;">Empresas activas</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;">#{kpis[:empresas_activas]}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;color:#6B21A8;">Transacciones</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;">#{kpis[:transacciones]}</td></tr>
              </table>

              <h2 style="color:#1E1333;font-size:16px;margin:24px 0 12px 0;">🎯 Resumen Surtitodo</h2>
              <table width="100%" cellspacing="0" cellpadding="10" style="border-collapse:collapse;font-size:14px;border:1px solid #6B21A8;border-radius:6px;overflow:hidden;">
                <tr style="background:#6B21A8;color:#FFFFFF;"><td colspan="2" style="text-align:center;font-weight:bold;">Surtitodo · #{desde[0,7]}</td></tr>
                <tr><td style="background:#EDE9F5;font-weight:bold;">Recaudos</td>
                    <td style="background:#FFFFCC;text-align:right;font-weight:bold;">$ #{money.call(surt[:recaudos])}</td></tr>
                <tr><td style="background:#EDE9F5;font-weight:bold;">Servicios</td>
                    <td style="background:#D4EDDA;text-align:right;font-weight:bold;">$ #{money.call(surt[:servicios])}</td></tr>
                <tr><td style="background:#EDE9F5;font-weight:bold;">Comisión (1%)</td>
                    <td style="text-align:right;color:#DC2626;">$ #{money.call(surt[:comision])}</td></tr>
                <tr><td style="background:#EDE9F5;font-weight:bold;">ICA (9.66/1000)</td>
                    <td style="text-align:right;">$ #{money.call(surt[:ica])}</td></tr>
                <tr style="background:#6B21A8;color:#FFFFFF;"><td style="font-weight:bold;">Total</td>
                    <td style="text-align:right;font-weight:bold;">$ #{money.call(surt[:total])}</td></tr>
              </table>

              <p style="color:#666;font-size:12px;margin-top:24px;">El Excel completo con las 5 hojas (Query Recaudos, TD Recaudos, Query Transacciones, Mensual, Control) está adjunto a este email.</p>
              <p style="color:#999;font-size:11px;margin-top:8px;">Generado por #{ERB::Util.h(autor)} · Portal Picap Monitoreo</p>
            </div>
          </div>
        </body></html>
      HTML
    end

    def limpiar(obj)
      case obj
      when Hash  then obj.transform_values { |v| limpiar(v) }
      when Array then obj.map { |v| limpiar(v) }
      when Float then obj.nan? || obj.infinite? ? nil : obj
      else obj
      end
    end

    # NOTA: el helper `ch` (= ClickhouseClient) ya viene de ApplicationController.
    # NO definir aquí — antes había una def errónea que pisaba al padre con
    # `ClickHouseClient.instance` (capital H + .instance) y rompía con
    # "uninitialized constant Api::SaldoRecaudosController::ClickHouseClient".
  end
end
