# app/controllers/api/recaudos_dispersiones_controller.rb
# v3.3.30 — Recaudos y Dispersiones: informe mensual de 7 hojas.
#
# Paridad EXACTA con recaudos_dispersiones_bi/generar_recaudos_dispersiones.py
# (validado contra plantilla del usuario al 100%).
#
# Endpoints:
#   GET  /api/recaudos_dispersiones/estadisticas        → KPIs + tablas resumen
#   GET  /api/recaudos_dispersiones/query_dispersiones  → data Query A (async)
#   GET  /api/recaudos_dispersiones/query_recaudos      → data Query B (async)
#   GET  /api/recaudos_dispersiones/informe_general     → Excel 7 hojas (async)
#   GET  /api/recaudos_dispersiones/job_status/:job_id  → polling
#   POST /api/recaudos_dispersiones/enviar_email        → Excel adjunto por email
#
# Roles: admin / monitoreo / financiero.

module Api
  class RecaudosDispersionesController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol_recaudos_dispersiones

    ROLES_PERMITIDOS = %w[admin monitoreo financiero].freeze
    LIMIT_UI         = 5_000

    PRUEBA_KEYWORDS = %w[pibox\ admin testeo prueba qa test].freeze

    @@jobs = {}
    @@jobs_mutex = Mutex.new
    JOB_TTL_SEC = 1_800

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/recaudos_dispersiones/estadisticas?desde=...&hasta=...
    # ──────────────────────────────────────────────────────────────────────

    def estadisticas
      desde = desde_param
      hasta = hasta_param

      cache_key = "estadisticas_#{desde}_#{hasta}"
      hit = buscar_job_done(cache_key)
      return render(json: hit[:result]) if hit

      job_id = lanzar_job(cache_key, "estadisticas", desde, hasta) do
        dispersiones = ejecutar_query_dispersiones(desde, hasta)
        recaudos     = ejecutar_query_recaudos(desde, hasta)
        construir_estadisticas(desde, hasta, dispersiones, recaudos)
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[RecaudosDispersionesController#estadisticas] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/recaudos_dispersiones/query_dispersiones
    # ──────────────────────────────────────────────────────────────────────

    def query_dispersiones
      desde = desde_param
      hasta = hasta_param
      cache_key = "query_dispersiones_#{desde}_#{hasta}"

      hit = buscar_job_done(cache_key)
      return render(json: hit[:result]) if hit

      job_id = lanzar_job(cache_key, "query_dispersiones", desde, hasta) do
        rows = ejecutar_query_dispersiones(desde, hasta)
        limpiar({ ok: true, async: false, desde: desde, hasta: hasta,
                  total: rows.size, filas: rows.first(LIMIT_UI) })
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[RecaudosDispersionesController#query_dispersiones] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/recaudos_dispersiones/query_recaudos
    # ──────────────────────────────────────────────────────────────────────

    def query_recaudos
      desde = desde_param
      hasta = hasta_param
      cache_key = "query_recaudos_#{desde}_#{hasta}"

      hit = buscar_job_done(cache_key)
      return render(json: hit[:result]) if hit

      job_id = lanzar_job(cache_key, "query_recaudos", desde, hasta) do
        rows = ejecutar_query_recaudos(desde, hasta)
        limpiar({ ok: true, async: false, desde: desde, hasta: hasta,
                  total: rows.size, filas: rows.first(LIMIT_UI) })
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[RecaudosDispersionesController#query_recaudos] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/recaudos_dispersiones/informe_general
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
        dispersiones = ejecutar_query_dispersiones(desde, hasta)
        recaudos     = ejecutar_query_recaudos(desde, hasta)
        excel = RecaudosDispersionesExcelBuilder.build(
          desde:        desde,
          hasta:        hasta,
          dispersiones: dispersiones,
          recaudos:     recaudos,
        )
        {
          ok:                  true,
          async:               false,
          desde:               desde,
          hasta:               hasta,
          total_dispersiones:  dispersiones.size,
          total_recaudos:      recaudos.size,
          excel_bytes:         excel[:data],
          excel_filename:      excel[:filename],
          listo_para_descargar: true,
        }
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[RecaudosDispersionesController#informe_general] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/recaudos_dispersiones/job_status/:job_id
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
    # POST /api/recaudos_dispersiones/enviar_email
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

      BackgroundMailerHelper.run("RecaudosDispersiones") do
        dispersiones = ejecutar_query_dispersiones(desde, hasta)
        recaudos     = ejecutar_query_recaudos(desde, hasta)
        excel = RecaudosDispersionesExcelBuilder.build(
          desde:        desde,
          hasta:        hasta,
          dispersiones: dispersiones,
          recaudos:     recaudos,
        )

        subject_default = "Recaudos y Dispersiones · #{desde} → #{hasta}"
        html = construir_html_email(desde, hasta, dispersiones, recaudos, mensaje, usuario)

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
        mensaje: "Reporte en proceso. El email con el Excel (7 hojas) llegará en unos minutos.",
      }, status: :accepted
    rescue => e
      Rails.logger.error("[RecaudosDispersionesController#enviar_email] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    # ──────────────────────────────────────────────────────────────────────
    # Queries CH
    # ──────────────────────────────────────────────────────────────────────

    def ejecutar_query_dispersiones(desde, hasta)
      sql = QueriesService.format(QueriesService::Q_DISPERSIONES_DAVIPLATA,
                                  fecha_desde: desde, fecha_hasta: hasta)
      t0 = Time.now
      Rails.logger.info("[RecaudosDispersiones] Query A (Dispersiones) inicio (#{desde} → #{hasta})")
      rows = ch.query(sql, timeout: 300)
      Rails.logger.info("[RecaudosDispersiones] Query A OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    def ejecutar_query_recaudos(desde, hasta)
      sql = QueriesService.format(QueriesService::Q_DISPERSIONES_RECAUDOS,
                                  fecha_desde: desde, fecha_hasta: hasta)
      t0 = Time.now
      Rails.logger.info("[RecaudosDispersiones] Query B (Recaudos) inicio (#{desde} → #{hasta})")
      rows = ch.query(sql, timeout: 600)
      Rails.logger.info("[RecaudosDispersiones] Query B OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    # ──────────────────────────────────────────────────────────────────────
    # Estadísticas (replica Hojas 2, 5 + KPIs)
    # ──────────────────────────────────────────────────────────────────────

    def construir_estadisticas(desde, hasta, dispersiones, recaudos)
      # ── Periodo legible ──
      meses_es = {
        1 => "Enero", 2 => "Febrero", 3 => "Marzo", 4 => "Abril",
        5 => "Mayo", 6 => "Junio", 7 => "Julio", 8 => "Agosto",
        9 => "Septiembre", 10 => "Octubre", 11 => "Noviembre", 12 => "Diciembre",
      }
      año, mes = desde.split("-")
      last_day = Date.new(año.to_i, mes.to_i, -1).day rescue 30
      corte = "1 TO #{last_day} #{meses_es[mes.to_i].upcase}"

      # ── Hoja 2: Pivote Dispersiones (Company + tipo + monto) ──
      pivot_disp_kv = Hash.new(0.0)
      dispersiones.each do |r|
        emp = r["Company_name"].to_s.strip
        tip = r["tipo_dispersion"].to_s
        next if emp.empty?
        pivot_disp_kv[[emp, tip]] += r["amount_cents"].to_f
      end
      tabla_dispersion = pivot_disp_kv
        .map { |(emp, tip), monto| { empresa: emp, tipo: tip, monto: monto.round(2) } }
        .sort_by { |h| h[:empresa].downcase }
      total_dispersion = tabla_dispersion.sum { |h| h[:monto] }

      # ── Hoja 5: TD Recaudos (Company + monto + tipología) ──
      pivot_rec = Hash.new(0.0)
      recaudos.each do |r|
        emp = r["User_Company"].to_s.strip
        next if emp.empty?
        pivot_rec[emp] += r["Transaction_amount"].to_f
      end
      td_recaudos = pivot_rec
        .map { |emp, monto|
          { empresa: emp, monto: monto.round(2), tipo_cliente: tipo_cliente(emp) }
        }
        .sort_by { |h| -h[:monto] }
      total_recaudos = td_recaudos.sum { |h| h[:monto] }

      # ── Surtitodo: Recaudo (suma de TD Recaudos donde empresa contiene "surtitodo") ──
      surtitodo_recaudo = td_recaudos
        .select { |h| h[:empresa].downcase.include?("surtitodo") }
        .sum { |h| h[:monto] }

      surtitodo_dispersion = tabla_dispersion
        .select { |h| h[:empresa].downcase.include?("surtitodo") }
        .sum { |h| h[:monto] }

      # ── KPIs ──
      limpiar({
        ok: true,
        async: false,
        desde: desde,
        hasta: hasta,
        corte: corte,
        kpis: {
          total_dispersion:         total_dispersion.round(2),
          total_recaudos:           total_recaudos.round(2),
          surtitodo_dispersion:     surtitodo_dispersion.round(2),
          surtitodo_recaudo:        surtitodo_recaudo.round(2),
          empresas_recaudos:        td_recaudos.size,
          filas_dispersiones:       dispersiones.size,
          filas_recaudos:           recaudos.size,
        },
        tabla_dispersion: tabla_dispersion,
        td_recaudos:      td_recaudos.first(50),
      })
    end

    # ──────────────────────────────────────────────────────────────────────
    # Tipología (Hoja 5 col "Tipo de cliente")
    # ──────────────────────────────────────────────────────────────────────

    def tipo_cliente(empresa)
      return "ida y vuelta" if empresa.to_s.strip.empty?
      n = empresa.to_s.downcase.strip
      return "Reportar" if n.include?("surtitodo")
      return "prueba" if PRUEBA_KEYWORDS.any? { |kw| n.include?(kw) }
      "ida y vuelta"
    end

    # ──────────────────────────────────────────────────────────────────────
    # Async jobs (mismo patrón Saldo Recaudos / Comisiones Recaudo)
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
          Rails.logger.info("[RecaudosDispersionesJob #{job_id}] #{kind} OK en #{@@jobs[job_id][:t_elapsed].round(1)}s")
        rescue => e
          Rails.logger.error("[RecaudosDispersionesJob #{job_id}] #{e.class}: #{e.message}")
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

    def validar_rol_recaudos_dispersiones
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
    def construir_html_email(desde, hasta, dispersiones, recaudos, mensaje_usuario, autor)
      stats = construir_estadisticas(desde, hasta, dispersiones, recaudos)
      kpis  = stats[:kpis]
      td    = stats[:td_recaudos].first(10)

      money = ->(n) { n.to_f.round(2).to_s.gsub(/\B(?=(\d{3})+(?!\d))/, ".") }

      mensaje_html = mensaje_usuario.to_s.strip.empty? ? "" : %Q{
        <div style="background:#F3F0FA;border-left:4px solid #6B21A8;padding:14px 18px;margin:16px 0;border-radius:6px;">
          <p style="margin:0;color:#1E1333;font-size:14px;">#{ERB::Util.h(mensaje_usuario)}</p>
        </div>
      }

      td_rows = td.map do |r|
        "<tr>
          <td style='border:1px solid #EDE9F5;padding:6px 10px;'>#{ERB::Util.h(r[:empresa])}</td>
          <td style='border:1px solid #EDE9F5;text-align:right;padding:6px 10px;'>$ #{money.call(r[:monto])}</td>
          <td style='border:1px solid #EDE9F5;padding:6px 10px;color:#5b21b6;font-weight:600;'>#{r[:tipo_cliente]}</td>
        </tr>"
      end.join

      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;background:#F8F7FB;margin:0;padding:24px;">
          <div style="max-width:760px;margin:0 auto;background:#FFFFFF;border-radius:12px;overflow:hidden;box-shadow:0 4px 16px rgba(30,19,51,0.08);">
            <div style="background:linear-gradient(135deg,#6366f1 0%,#4338ca 100%);padding:28px 32px;">
              <h1 style="margin:0;color:#FFFFFF;font-size:22px;">Recaudos y Dispersiones</h1>
              <p style="margin:6px 0 0 0;color:#E0E7FF;font-size:14px;">#{desde} → #{hasta} (#{stats[:corte]})</p>
            </div>
            <div style="padding:28px 32px;">
              #{mensaje_html}
              <h2 style="color:#1E1333;font-size:16px;margin:0 0 12px 0;">📊 KPIs</h2>
              <table width="100%" cellspacing="0" cellpadding="10" style="border-collapse:collapse;font-size:14px;">
                <tr><td style="border:1px solid #EDE9F5;color:#6366f1;font-weight:bold;">Total Dispersión Recaudo</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;color:#DC2626;font-weight:bold;">$ #{money.call(kpis[:total_dispersion])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;color:#6366f1;font-weight:bold;">Total Recaudos</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;color:#16A34A;font-weight:bold;">$ #{money.call(kpis[:total_recaudos])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;color:#6366f1;">Surtitodo · Dispersión</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;color:#DC2626;">$ #{money.call(kpis[:surtitodo_dispersion])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;color:#6366f1;">Surtitodo · Recaudo</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;color:#16A34A;">$ #{money.call(kpis[:surtitodo_recaudo])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;">Empresas Recaudos</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;">#{kpis[:empresas_recaudos]}</td></tr>
              </table>

              <h2 style="color:#1E1333;font-size:16px;margin:24px 0 12px 0;">🏢 TD Recaudos · Top 10 por empresa</h2>
              <table width="100%" cellspacing="0" cellpadding="6" style="border-collapse:collapse;font-size:13px;">
                <thead><tr style="background:#6366f1;color:#FFFFFF;">
                  <th style="padding:8px 10px;text-align:left;">Empresa</th>
                  <th style="padding:8px 10px;text-align:right;">Σ Transaction_amount</th>
                  <th style="padding:8px 10px;text-align:left;">Tipo de cliente</th>
                </tr></thead>
                <tbody>#{td_rows}</tbody>
              </table>

              <p style="color:#666;font-size:12px;margin-top:24px;">El Excel completo con las <b>7 hojas</b> está adjunto.</p>
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
