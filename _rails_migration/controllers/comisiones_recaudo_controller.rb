# app/controllers/api/comisiones_recaudo_controller.rb
# v3.3.29 — Comisiones Recaudo: informe mensual de 9 hojas.
#
# Paridad EXACTA con comisiones_bi/generar_comisiones.py (validado abril 2026:
# cuadra con plantilla del usuario centavo a centavo).
#
# Endpoints:
#   GET  /api/comisiones_recaudo/estadisticas        → KPIs + tabla Cruce Company + Surtitodo
#   GET  /api/comisiones_recaudo/query_recaudos      → data Query A (async)
#   GET  /api/comisiones_recaudo/query_comision      → data Query B (async)
#   GET  /api/comisiones_recaudo/informe_general     → Excel 9 hojas (async + download)
#   GET  /api/comisiones_recaudo/job_status/:job_id  → polling
#   POST /api/comisiones_recaudo/enviar_email        → manda Excel adjunto por email
#
# Roles: admin / monitoreo / financiero.

module Api
  class ComisionesRecaudoController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol_comisiones_recaudo

    ROLES_PERMITIDOS = %w[admin monitoreo financiero].freeze
    LIMIT_UI         = 5_000

    # Empresas a EXCLUIR en hojas Ida y Vuelta (matching case-insensitive sobre substring)
    EXCLUSIONES_IDA_VUELTA = %w[
      multipaquete surtitodo pibox\ admin testeo test qa prueba
    ].freeze

    @@jobs = {}
    @@jobs_mutex = Mutex.new
    JOB_TTL_SEC = 1_800

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/comisiones_recaudo/estadisticas?desde=YYYY-MM-DD&hasta=YYYY-MM-DD
    # ──────────────────────────────────────────────────────────────────────

    def estadisticas
      desde = desde_param
      hasta = hasta_param

      cache_key = "estadisticas_#{desde}_#{hasta}"
      hit = buscar_job_done(cache_key)
      return render(json: hit[:result]) if hit

      job_id = lanzar_job(cache_key, "estadisticas", desde, hasta) do
        recaudos      = ejecutar_query_recaudos(desde, hasta)
        comision      = ejecutar_query_comision(desde, hasta)
        fees          = ejecutar_query_fees
        resumen_user  = ejecutar_query_resumen(desde, hasta)
        construir_estadisticas(desde, hasta, recaudos, comision, fees, resumen_user)
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[ComisionesRecaudoController#estadisticas] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/comisiones_recaudo/query_recaudos?desde=...&hasta=...
    # ──────────────────────────────────────────────────────────────────────

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
      Rails.logger.error("[ComisionesRecaudoController#query_recaudos] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/comisiones_recaudo/query_comision?desde=...&hasta=...
    # ──────────────────────────────────────────────────────────────────────

    def query_comision
      desde = desde_param
      hasta = hasta_param
      cache_key = "query_comision_#{desde}_#{hasta}"

      hit = buscar_job_done(cache_key)
      return render(json: hit[:result]) if hit

      job_id = lanzar_job(cache_key, "query_comision", desde, hasta) do
        rows = ejecutar_query_comision(desde, hasta)
        limpiar({
          ok: true, async: false,
          desde: desde, hasta: hasta,
          total: rows.size,
          filas: rows.first(LIMIT_UI),
        })
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[ComisionesRecaudoController#query_comision] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/comisiones_recaudo/informe_general?desde=...&hasta=...
    # ──────────────────────────────────────────────────────────────────────

    def informe_general
      desde = desde_param
      hasta = hasta_param

      if params[:download].to_s == "1" && params[:job_id].present?
        return _descargar_excel(params[:job_id].to_s)
      end

      cache_key = "informe_general_#{desde}_#{hasta}"
      hit = buscar_job_done(cache_key)
      if hit
        job_id = @@jobs_mutex.synchronize { @@jobs.find { |_, j| j[:cache_key] == cache_key && j[:status] == :done }&.first }
        return render(json: { ok: true, async: false, job_id: job_id, status: "done", listo_para_descargar: true })
      end

      job_id = lanzar_job(cache_key, "informe_general", desde, hasta) do
        recaudos      = ejecutar_query_recaudos(desde, hasta)
        comision      = ejecutar_query_comision(desde, hasta)
        fees          = ejecutar_query_fees
        resumen_user  = ejecutar_query_resumen(desde, hasta)
        excel = ComisionesRecaudoExcelBuilder.build(
          desde:        desde,
          hasta:        hasta,
          recaudos:     recaudos,
          comision:     comision,
          fees:         fees,
          resumen_user: resumen_user,
        )
        {
          ok:                  true,
          async:               false,
          desde:               desde,
          hasta:               hasta,
          total_recaudos:      recaudos.size,
          total_comision:      comision.size,
          excel_bytes:         excel[:data],
          excel_filename:      excel[:filename],
          listo_para_descargar: true,
        }
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[ComisionesRecaudoController#informe_general] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/comisiones_recaudo/job_status/:job_id
    # ──────────────────────────────────────────────────────────────────────

    def job_status
      job_id = params[:job_id].to_s
      cleanup_old_jobs
      @@jobs_mutex.synchronize do
        job = @@jobs[job_id]
        return render(json: { ok: false, error: "Job no encontrado o expirado (>30 min)" }, status: :not_found) if job.nil?
        case job[:status]
        when :done
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

    # ──────────────────────────────────────────────────────────────────────
    # POST /api/comisiones_recaudo/enviar_email
    # ──────────────────────────────────────────────────────────────────────

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

      BackgroundMailerHelper.run("ComisionesRecaudo") do
        recaudos      = ejecutar_query_recaudos(desde, hasta)
        comision      = ejecutar_query_comision(desde, hasta)
        fees          = ejecutar_query_fees
        resumen_user  = ejecutar_query_resumen(desde, hasta)
        excel = ComisionesRecaudoExcelBuilder.build(
          desde:        desde,
          hasta:        hasta,
          recaudos:     recaudos,
          comision:     comision,
          fees:         fees,
          resumen_user: resumen_user,
        )

        subject_default = "Comisiones Recaudo · #{desde} → #{hasta}"
        html = construir_html_email(desde, hasta, recaudos, comision, fees, resumen_user, mensaje, usuario)

        ResendMailerService.send_email(
          to:                  to_list,
          cc:                  cc_list,
          bcc:                 bcc_list,
          subject:             asunto.empty? ? subject_default : asunto,
          html:                html,
          attachment_bytes:    excel[:data],
          attachment_filename: excel[:filename],
        )
      end

      render json: {
        ok: true,
        queued: true,
        destinatarios: to_list,
        cc: cc_list,
        bcc: bcc_list,
        mensaje: "Reporte en proceso. El email con el Excel (9 hojas) llegará en unos minutos.",
      }, status: :accepted
    rescue => e
      Rails.logger.error("[ComisionesRecaudoController#enviar_email] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    # ──────────────────────────────────────────────────────────────────────
    # Queries CH
    # ──────────────────────────────────────────────────────────────────────

    def ejecutar_query_recaudos(desde, hasta)
      sql = QueriesService.format(QueriesService::Q_COMISIONES_RECAUDO_A,
                                  fecha_desde: desde, fecha_hasta: hasta)
      t0 = Time.now
      Rails.logger.info("[ComisionesRecaudo] Query A (Recaudos) inicio (#{desde} → #{hasta})")
      rows = ch.query(sql, timeout: 600)
      Rails.logger.info("[ComisionesRecaudo] Query A OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    def ejecutar_query_comision(desde, hasta)
      sql = QueriesService.format(QueriesService::Q_COMISIONES_RECAUDO_B,
                                  fecha_desde: desde, fecha_hasta: hasta)
      t0 = Time.now
      Rails.logger.info("[ComisionesRecaudo] Query B (Comisión) inicio (#{desde} → #{hasta})")
      rows = ch.query(sql, timeout: 600)
      Rails.logger.info("[ComisionesRecaudo] Query B OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    def ejecutar_query_fees
      t0 = Time.now
      rows = ch.query(QueriesService::Q_COMISIONES_RECAUDO_FEE, timeout: 120)
      out = {}
      rows.each do |r|
        next if r["_id"].to_s.empty?
        out[r["_id"].to_s] = r["fee_decimal"].to_f
      end
      Rails.logger.info("[ComisionesRecaudo] Query C (Fees) OK: #{out.size} empresas en #{(Time.now - t0).round(1)}s")
      out
    end

    def ejecutar_query_resumen(desde, hasta)
      sql = QueriesService.format(QueriesService::Q_COMISIONES_RECAUDO_RESUMEN,
                                  fecha_desde: desde, fecha_hasta: hasta)
      t0 = Time.now
      rows = ch.query(sql, timeout: 300)
      out = {}
      rows.each { |r| out[r["User_Company"].to_s] = r["Suma_Transaction_amount"].to_f }
      Rails.logger.info("[ComisionesRecaudo] Query D (Resumen) OK: #{out.size} empresas en #{(Time.now - t0).round(1)}s")
      out
    end

    # ──────────────────────────────────────────────────────────────────────
    # Stats / agregados (replica de Hoja 3 + Hoja 5 del Excel)
    # ──────────────────────────────────────────────────────────────────────

    def construir_estadisticas(desde, hasta, recaudos, comision, fees, resumen_user)
      # Pivot por empresa de RECAUDOS (Hoja 3 izquierda)
      por_empresa = Hash.new { |h, k| h[k] = { recaudos: 0.0, comision_sum: 0.0, company_id: "" } }
      recaudos.each do |r|
        emp = r["Company_name"].to_s
        next if emp.empty?
        por_empresa[emp][:recaudos] += r["VAL_AMOUNT"].to_f
        por_empresa[emp][:company_id] = r["company_id"].to_s if por_empresa[emp][:company_id].empty?
      end
      comision.each do |r|
        emp = r["Company_name"].to_s
        next if emp.empty?
        por_empresa[emp][:comision_sum] += r["VAL_AMOUNT"].to_f
      end

      cruce_company = por_empresa.map do |emp, info|
        pct        = fees[info[:company_id]].to_f
        com_real   = info[:recaudos] * pct
        com_trump  = info[:comision_sum]
        dif        = com_trump - com_real
        {
          empresa:        emp,
          recaudos:       info[:recaudos].round(2),
          porcentaje:     pct,
          comision_real:  com_real.round(2),
          comision_trump: com_trump.round(2),
          dif:            dif.round(2),
          company_id:     info[:company_id],
        }
      end.sort_by { |h| -h[:recaudos] }

      total_recaudos      = cruce_company.sum { |h| h[:recaudos] }
      total_comision_real = cruce_company.sum { |h| h[:comision_real] }
      total_comision_trump = cruce_company.sum { |h| h[:comision_trump] }

      # ── Periodo legible (ej. "1 al 30 Abril 2026") ──
      meses_es = {
        1 => "Enero", 2 => "Febrero", 3 => "Marzo", 4 => "Abril",
        5 => "Mayo", 6 => "Junio", 7 => "Julio", 8 => "Agosto",
        9 => "Septiembre", 10 => "Octubre", 11 => "Noviembre", 12 => "Diciembre",
      }
      año, mes = desde.split("-")
      last_day = Date.new(año.to_i, mes.to_i, -1).day rescue hasta.split("-")[2].to_i
      periodo_txt = "1 al #{last_day} #{meses_es[mes.to_i]} #{año}"

      # Resumen Final (Hoja 5) — solo % > 0, excluir Cruz Verde.
      # ⚠️ NO usar `comision` como nombre local dentro del block: pisa al
      # parámetro de la función (Ruby reasigna en scope outer). Usar `com_calc`.
      resumen = cruce_company
        .reject { |h| h[:porcentaje] <= 0 }
        .reject { |h| h[:empresa].downcase.include?("cruz verde") }
        .map do |h|
          recaudo_real = resumen_user[h[:empresa]].to_f
          com_calc     = recaudo_real * -h[:porcentaje]
          anticipo     = -com_calc
          pendiente    = anticipo + com_calc
          {
            empresa:    h[:empresa],
            recaudos:   recaudo_real.round(2),
            porcentaje: h[:porcentaje],
            comision:   com_calc.round(2),
            periodo:    periodo_txt,
            anticipo:   anticipo.round(2),
            pendiente:  pendiente.round(2),
            estado:     pendiente.abs < 0.01 ? "Pagada" : "Pendiente",
          }
        end

      # ── Pivote "1. Comisión Recaudo" (Hoja 1) por Company_name ──
      # Suma VAL_AMOUNT de la Query B (BookingCompanyCollectionFee).
      # Muestra los cobros del sistema por empresa (valores negativos = empresa debe).
      pivot_comision = Hash.new(0.0)
      comision.each do |r|
        emp = r["Company_name"].to_s.strip
        next if emp.empty?
        pivot_comision[emp] += r["VAL_AMOUNT"].to_f
      end
      comision_pivot = pivot_comision
        .map { |emp, monto| { empresa: emp, monto: monto.round(2) } }
        .sort_by { |h| h[:empresa].downcase }

      # Resumen Surtitodo
      surt = cruce_company.find { |h| h[:empresa].downcase.strip == "surtitodo express" } || {}
      surt_recaudo  = resumen_user["Surtitodo express"].to_f
      surt_pct      = surt[:porcentaje].to_f
      surt_comision = surt_recaudo * -surt_pct
      surt_servicios = surt[:comision_trump].to_f
      surt_ica      = (-surt_servicios * 9.66) / 1000.0
      surt_total    = surt_recaudo + surt_servicios + surt_comision + surt_ica

      limpiar({
        ok: true,
        async: false,
        desde: desde,
        hasta: hasta,
        kpis: {
          total_recaudos:       total_recaudos.round(2),
          total_comision_real:  total_comision_real.round(2),
          total_comision_trump: total_comision_trump.round(2),
          dif_total:            (total_comision_trump - total_comision_real).round(2),
          empresas_activas:     cruce_company.size,
          empresas_resumen:     resumen.size,
          transacciones_recaudos: recaudos.size,
          transacciones_comision: comision.size,
        },
        cruce_company:  cruce_company.first(20),
        resumen_final:  resumen,
        comision_pivot: comision_pivot,
        surtitodo: {
          recaudos:  surt_recaudo.round(2),
          servicios: surt_servicios.round(2),
          comision:  surt_comision.round(2),
          ica:       surt_ica.round(2),
          total:     surt_total.round(2),
        },
      })
    end

    # ──────────────────────────────────────────────────────────────────────
    # Async jobs (mismo patrón Saldo Recaudos / MINTIC)
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
          Rails.logger.info("[ComisionesRecaudoJob #{job_id}] #{kind} OK en #{@@jobs[job_id][:t_elapsed].round(1)}s")
        rescue => e
          Rails.logger.error("[ComisionesRecaudoJob #{job_id}] #{e.class}: #{e.message}")
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
      Date.today.beginning_of_month.strftime("%Y-%m-%d")
    end

    def hasta_param
      v = params[:hasta].to_s.strip
      return v if v.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      Date.today.end_of_month.strftime("%Y-%m-%d")
    end

    def validar_rol_comisiones_recaudo
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

    # HTML email corporativo Picap.
    def construir_html_email(desde, hasta, recaudos, comision, fees, resumen_user, mensaje_usuario, autor)
      stats = construir_estadisticas(desde, hasta, recaudos, comision, fees, resumen_user)
      kpis  = stats[:kpis]
      surt  = stats[:surtitodo]
      resumen = stats[:resumen_final] || []

      money = ->(n) { n.to_f.round(2).to_s.gsub(/\B(?=(\d{3})+(?!\d))/, ".") }

      mensaje_html = mensaje_usuario.to_s.strip.empty? ? "" : %Q{
        <div style="background:#F3F0FA;border-left:4px solid #6B21A8;padding:14px 18px;margin:16px 0;border-radius:6px;">
          <p style="margin:0;color:#1E1333;font-size:14px;">#{ERB::Util.h(mensaje_usuario)}</p>
        </div>
      }

      resumen_rows = resumen.first(10).map do |r|
        "<tr>
          <td style='border:1px solid #EDE9F5;padding:6px 10px;'>#{ERB::Util.h(r[:empresa])}</td>
          <td style='border:1px solid #EDE9F5;text-align:right;padding:6px 10px;'>$ #{money.call(r[:recaudos])}</td>
          <td style='border:1px solid #EDE9F5;text-align:right;padding:6px 10px;'>#{(r[:porcentaje]*100).round(2)}%</td>
          <td style='border:1px solid #EDE9F5;text-align:right;padding:6px 10px;color:#DC2626;'>$ #{money.call(r[:comision])}</td>
          <td style='border:1px solid #EDE9F5;padding:6px 10px;'>#{r[:estado]}</td>
        </tr>"
      end.join

      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;background:#F8F7FB;margin:0;padding:24px;">
          <div style="max-width:760px;margin:0 auto;background:#FFFFFF;border-radius:12px;overflow:hidden;box-shadow:0 4px 16px rgba(30,19,51,0.08);">
            <div style="background:linear-gradient(135deg,#16A34A 0%,#065F46 100%);padding:28px 32px;">
              <h1 style="margin:0;color:#FFFFFF;font-size:22px;">Comisiones Recaudo</h1>
              <p style="margin:6px 0 0 0;color:#DCFCE7;font-size:14px;">#{desde} → #{hasta}</p>
            </div>
            <div style="padding:28px 32px;">
              #{mensaje_html}
              <h2 style="color:#1E1333;font-size:16px;margin:0 0 12px 0;">📊 KPIs</h2>
              <table width="100%" cellspacing="0" cellpadding="10" style="border-collapse:collapse;font-size:14px;">
                <tr><td style="border:1px solid #EDE9F5;color:#16A34A;font-weight:bold;">Total Recaudos</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;font-weight:bold;">$ #{money.call(kpis[:total_recaudos])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;color:#16A34A;font-weight:bold;">Comisión Real (calculada)</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;">$ #{money.call(kpis[:total_comision_real])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;color:#DC2626;font-weight:bold;">Comisión Trump (sistema)</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;color:#DC2626;">$ #{money.call(kpis[:total_comision_trump])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;color:#1E1333;font-weight:bold;">Diferencia (Trump - Real)</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;font-weight:bold;">$ #{money.call(kpis[:dif_total])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;">Empresas activas</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;">#{kpis[:empresas_activas]}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;">Clientes en resumen</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;">#{kpis[:empresas_resumen]}</td></tr>
              </table>

              <h2 style="color:#1E1333;font-size:16px;margin:24px 0 12px 0;">💼 Resumen Final por Cliente</h2>
              <table width="100%" cellspacing="0" cellpadding="6" style="border-collapse:collapse;font-size:13px;">
                <thead><tr style="background:#16A34A;color:#FFFFFF;">
                  <th style="padding:8px 10px;text-align:left;">Cliente</th>
                  <th style="padding:8px 10px;text-align:right;">Recaudo</th>
                  <th style="padding:8px 10px;text-align:right;">%</th>
                  <th style="padding:8px 10px;text-align:right;">Comisión</th>
                  <th style="padding:8px 10px;text-align:left;">Estado</th>
                </tr></thead>
                <tbody>#{resumen_rows}</tbody>
              </table>

              <p style="color:#666;font-size:12px;margin-top:24px;">El Excel completo con las <b>9 hojas</b> (Comisión Recaudo, Recaudos, Cruce company, Cruce Booking, Resumen, e Ida y Vuelta) está adjunto.</p>
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

    # NOTA: el helper `ch` (= ClickhouseClient) viene de ApplicationController.
  end
end
