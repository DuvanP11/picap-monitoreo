# app/controllers/api/estado_cuenta_controller.rb
# v3.3.31 — Estado de cuenta SURTITODO: informe mensual 3 hojas con logo Pibox.
#
# Paridad EXACTA con estado_cuenta_bi/generar_estado_cuenta.py (validado abril
# 2026 contra plantilla manual del usuario).
#
# Endpoints:
#   GET  /api/estado_cuenta/estadisticas             → tabla resumen + KPIs
#   GET  /api/estado_cuenta/query_recaudos           → data Query A (async)
#   GET  /api/estado_cuenta/query_valor_mensajeria   → data Query B (async)
#   GET  /api/estado_cuenta/informe_general          → Excel 3 hojas + logo (async)
#   GET  /api/estado_cuenta/job_status/:job_id       → polling
#   POST /api/estado_cuenta/enviar_email             → Excel adjunto por email
#
# Roles: admin / monitoreo / financiero.

module Api
  class EstadoCuentaController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol_estado_cuenta

    ROLES_PERMITIDOS = %w[admin monitoreo financiero].freeze
    LIMIT_UI         = 5_000

    @@jobs = {}
    @@jobs_mutex = Mutex.new
    JOB_TTL_SEC = 1_800

    MESES_ES = {
      1 => "enero", 2 => "febrero", 3 => "marzo", 4 => "abril",
      5 => "mayo", 6 => "junio", 7 => "julio", 8 => "agosto",
      9 => "septiembre", 10 => "octubre", 11 => "noviembre", 12 => "diciembre",
    }.freeze

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/estado_cuenta/estadisticas?desde=...&hasta=...
    # ──────────────────────────────────────────────────────────────────────

    def estadisticas
      desde = desde_param
      hasta = hasta_param

      cache_key = "estadisticas_#{desde}_#{hasta}"
      hit = buscar_job_done(cache_key)
      return render(json: hit[:result]) if hit

      job_id = lanzar_job(cache_key, "estadisticas", desde, hasta) do
        recaudos          = ejecutar_query_recaudos(desde, hasta)
        valor_mensajeria  = ejecutar_query_valor_mensajeria(desde, hasta)
        construir_estadisticas(desde, hasta, recaudos, valor_mensajeria)
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[EstadoCuentaController#estadisticas] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/estado_cuenta/query_recaudos
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
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/estado_cuenta/query_valor_mensajeria
    # ──────────────────────────────────────────────────────────────────────

    def query_valor_mensajeria
      desde = desde_param
      hasta = hasta_param
      cache_key = "query_valor_mensajeria_#{desde}_#{hasta}"

      hit = buscar_job_done(cache_key)
      return render(json: hit[:result]) if hit

      job_id = lanzar_job(cache_key, "query_valor_mensajeria", desde, hasta) do
        rows = ejecutar_query_valor_mensajeria(desde, hasta)
        limpiar({ ok: true, async: false, desde: desde, hasta: hasta,
                  total: rows.size, filas: rows.first(LIMIT_UI) })
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/estado_cuenta/informe_general
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
        recaudos         = ejecutar_query_recaudos(desde, hasta)
        valor_mensajeria = ejecutar_query_valor_mensajeria(desde, hasta)
        excel = EstadoCuentaExcelBuilder.build(
          desde:            desde,
          hasta:            hasta,
          recaudos:         recaudos,
          valor_mensajeria: valor_mensajeria,
        )
        {
          ok:                    true,
          async:                 false,
          desde:                 desde,
          hasta:                 hasta,
          total_recaudos:        recaudos.size,
          total_valor_mensajeria: valor_mensajeria.size,
          excel_bytes:           excel[:data],
          excel_filename:        excel[:filename],
          listo_para_descargar:  true,
        }
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[EstadoCuentaController#informe_general] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/estado_cuenta/job_status/:job_id
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
              job_id: job_id, listo_para_descargar: true,
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
    # POST /api/estado_cuenta/enviar_email
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

      BackgroundMailerHelper.run("EstadoCuentaSurtitodo") do
        recaudos         = ejecutar_query_recaudos(desde, hasta)
        valor_mensajeria = ejecutar_query_valor_mensajeria(desde, hasta)
        excel = EstadoCuentaExcelBuilder.build(
          desde:            desde,
          hasta:            hasta,
          recaudos:         recaudos,
          valor_mensajeria: valor_mensajeria,
        )

        subject_default = "Estado de cuenta SURTITODO · #{desde} → #{hasta}"
        html = construir_html_email(desde, hasta, recaudos, valor_mensajeria, mensaje, usuario)

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
        cc: cc_list, bcc: bcc_list,
        mensaje: "Reporte en proceso. El email con el Excel (3 hojas + logo) llegará en unos minutos.",
      }, status: :accepted
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    # ──────────────────────────────────────────────────────────────────────
    # Queries CH
    # ──────────────────────────────────────────────────────────────────────

    def ejecutar_query_recaudos(desde, hasta)
      sql = QueriesService.format(QueriesService::Q_ESTADO_CUENTA_RECAUDOS,
                                  fecha_desde: desde, fecha_hasta: hasta)
      t0 = Time.now
      Rails.logger.info("[EstadoCuenta] Query A (Recaudos) inicio (#{desde} → #{hasta})")
      rows = ch.query(sql, timeout: 300)
      Rails.logger.info("[EstadoCuenta] Query A OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    def ejecutar_query_valor_mensajeria(desde, hasta)
      sql = QueriesService.format(QueriesService::Q_ESTADO_CUENTA_VALOR_MENSAJERIA,
                                  fecha_desde: desde, fecha_hasta: hasta)
      t0 = Time.now
      Rails.logger.info("[EstadoCuenta] Query B (Valor Mensajería) inicio (#{desde} → #{hasta})")
      rows = ch.query(sql, timeout: 600)
      Rails.logger.info("[EstadoCuenta] Query B OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    # ──────────────────────────────────────────────────────────────────────
    # Estadísticas — tabla resumen igual al pantallazo del usuario
    # ──────────────────────────────────────────────────────────────────────

    def construir_estadisticas(desde, hasta, recaudos, valor_mensajeria)
      # Sumas (mismas fórmulas del Excel: SUM(Recaudos.MONTO), SUM(VM.MONTO))
      total_recaudos        = recaudos.sum { |r| r["MONTO"].to_f }
      total_pago_servicios  = valor_mensajeria.sum { |r| r["MONTO"].to_f }
      comision_1pct         = -(total_recaudos * 0.01)
      ica                   = (-total_pago_servicios * 9.66) / 1000.0
      total_cruce           = total_recaudos + total_pago_servicios + comision_1pct + ica

      # Período legible: "Periodo del 01 al 30 de abril 2026"
      año, mes = desde.split("-")
      last_day = Date.new(año.to_i, mes.to_i, -1).day rescue 30
      periodo_txt = "Periodo del 01 al #{last_day.to_s.rjust(2, '0')} de #{MESES_ES[mes.to_i]} #{año}"

      limpiar({
        ok: true,
        async: false,
        desde: desde, hasta: hasta,
        periodo_txt: periodo_txt,
        resumen: {
          recaudos:        total_recaudos.round(2),
          pago_servicios:  total_pago_servicios.round(2),
          comision_1pct:   comision_1pct.round(2),
          ica:             ica.round(2),
          total_cruce:     total_cruce.round(2),
        },
        kpis: {
          total_transacciones_recaudos:        recaudos.size,
          total_transacciones_valor_mensajeria: valor_mensajeria.size,
        },
      })
    end

    # ──────────────────────────────────────────────────────────────────────
    # Async jobs
    # ──────────────────────────────────────────────────────────────────────

    def lanzar_job(cache_key, kind, desde, hasta, &block)
      job_id = SecureRandom.hex(16)
      @@jobs_mutex.synchronize do
        @@jobs[job_id] = {
          status: :running, kind: kind,
          desde: desde, hasta: hasta,
          cache_key: cache_key, t0: Time.now,
        }
      end
      Thread.new do
        begin
          result = block.call
          @@jobs_mutex.synchronize do
            @@jobs[job_id][:status]    = :done
            @@jobs[job_id][:result]    = result
            @@jobs[job_id][:t_elapsed] = Time.now - @@jobs[job_id][:t0]
          end
          Rails.logger.info("[EstadoCuentaJob #{job_id}] #{kind} OK en #{@@jobs[job_id][:t_elapsed].round(1)}s")
        rescue => e
          Rails.logger.error("[EstadoCuentaJob #{job_id}] #{e.class}: #{e.message}")
          Rails.logger.error(e.backtrace.first(8).join("\n"))
          @@jobs_mutex.synchronize do
            @@jobs[job_id][:status] = :error
            @@jobs[job_id][:error]  = e.message
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

    def validar_rol_estado_cuenta
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

    # HTML email corporativo Picap con tabla resumen Surtitodo.
    def construir_html_email(desde, hasta, recaudos, valor_mensajeria, mensaje_usuario, autor)
      stats = construir_estadisticas(desde, hasta, recaudos, valor_mensajeria)
      r = stats[:resumen]
      money = ->(n) { n.to_f.round(0).to_s.gsub(/\B(?=(\d{3})+(?!\d))/, ".") }
      money_signo = ->(n) {
        if n < 0
          "<span style='color:#dc2626'>-$ #{money.call(n.abs)}</span>"
        else
          "<span style='color:#16a34a'>$ #{money.call(n)}</span>"
        end
      }

      mensaje_html = mensaje_usuario.to_s.strip.empty? ? "" : %Q{
        <div style="background:#F3F0FA;border-left:4px solid #6B21A8;padding:14px 18px;margin:16px 0;border-radius:6px;">
          <p style="margin:0;color:#1E1333;font-size:14px;">#{ERB::Util.h(mensaje_usuario)}</p>
        </div>
      }

      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;background:#F8F7FB;margin:0;padding:24px;">
          <div style="max-width:560px;margin:0 auto;background:#FFFFFF;border-radius:12px;overflow:hidden;box-shadow:0 4px 16px rgba(30,19,51,0.08);">
            <div style="background:linear-gradient(135deg,#5B21B6 0%,#3B0764 100%);padding:24px 28px;text-align:center;">
              <h1 style="margin:0;color:#FFFFFF;font-size:18px;font-style:italic;letter-spacing:1px;">SURTITODO</h1>
              <p style="margin:6px 0 0 0;color:#E9D5FF;font-size:13px;">#{stats[:periodo_txt]}</p>
            </div>
            <div style="padding:24px 28px;">
              #{mensaje_html}
              <table width="100%" cellspacing="0" cellpadding="10" style="border-collapse:collapse;font-size:14px;">
                <tr><td style="border:1px solid #EDE9F5;">Recaudos</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;">#{money_signo.call(r[:recaudos])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;">Pago Servicios</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;">#{money_signo.call(r[:pago_servicios])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;">Comisión del 1%</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;">#{money_signo.call(r[:comision_1pct])}</td></tr>
                <tr><td style="border:1px solid #EDE9F5;">ICA</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;">#{money_signo.call(r[:ica])}</td></tr>
                <tr style="background:#F3E8FF;font-weight:bold;">
                    <td style="border:1px solid #EDE9F5;">valor a pagar despues del cruce:</td>
                    <td style="border:1px solid #EDE9F5;text-align:right;">#{money_signo.call(r[:total_cruce])}</td></tr>
              </table>
              <p style="color:#666;font-size:12px;margin-top:24px;">El Excel completo (3 hojas con logo) está adjunto.</p>
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
