# app/controllers/api/validador_dispersiones_controller.rb
# v3.3.52 — Validador de Dispersiones (submódulo de Cash Out).
#
# Permite validar el estado de dispersiones (wallet_account_transactions):
#   - Pago exitoso (status_cd=1)
#   - Aprobado     (status_cd=2 con daviplata_response presente)
#   - Reembolso    (status_cd=2 con daviplata_response vacío)
#   - Pendiente    (status_cd=0)
#   - Otro
#
# Filtros soportados:
#   - desde / hasta:  rango de fechas obligatorio
#   - moneda:         opcional (default 'COP')
#   - banco:          opcional (nombre exacto o LIKE)
#   - buscar_por:     opcional - selector: id_tx | id_user | consecutivo
#   - q:              opcional - valor a buscar según buscar_por
#
# Endpoints:
#   GET  /api/validador_dispersiones/cargar_async               → arranca job (202)
#   GET  /api/validador_dispersiones/cargar_status/:job_id      → polling
#   GET  /api/validador_dispersiones/exportar_async             → Excel async
#   GET  /api/validador_dispersiones/export_status/:job_id      → polling Excel
#   POST /api/validador_dispersiones/enviar_email               → email job
#   GET  /api/validador_dispersiones/enviar_email_status/:job_id → polling email
#
# Roles: admin / monitoreo / financiero.
require "tempfile"

module Api
  class ValidadorDispersionesController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol

    ROLES_PERMITIDOS = %w[admin monitoreo financiero].freeze
    LIMIT_UI         = 5_000

    # Jobs de carga (listado + stats)
    @@load_jobs       = {}
    @@load_jobs_mutex = Mutex.new
    LOAD_JOB_TTL_SEC  = 600

    # Jobs de export Excel
    @@export_jobs       = {}
    @@export_jobs_mutex = Mutex.new
    EXPORT_JOB_TTL_SEC  = 1_800

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/validador_dispersiones/cargar_async?desde=&hasta=&moneda=&banco=&buscar_por=&q=
    # ──────────────────────────────────────────────────────────────────────
    def cargar_async
      params_norm = normalizar_params

      cache_key = "load_#{params_norm.values_at(:desde, :hasta, :moneda, :banco, :buscar_por, :q).join('|')}"
      hit = @@load_jobs_mutex.synchronize do
        @@load_jobs.find { |_, j| j[:cache_key] == cache_key && j[:status] == :done }
      end
      if hit
        job_id, job = hit
        return render(json: limpiar({
          ok: true, async: false, status: "done", job_id: job_id, cached: true,
          **job[:result],
        }))
      end

      job_id = SecureRandom.hex(16)
      @@load_jobs_mutex.synchronize do
        @@load_jobs[job_id] = { status: :running, cache_key: cache_key, t0: Time.now, params: params_norm }
      end

      Thread.new do
        begin
          Rails.logger.info("[ValidadorDispersiones load #{job_id}] START #{params_norm.inspect}")
          rows = ejecutar_query(params_norm)
          stats = construir_stats(rows)
          result = {
            desde:  params_norm[:desde],
            hasta:  params_norm[:hasta],
            total:  rows.size,
            stats:  stats,
            filas:  rows.first(LIMIT_UI),
          }
          @@load_jobs_mutex.synchronize do
            @@load_jobs[job_id][:status]    = :done
            @@load_jobs[job_id][:result]    = result
            @@load_jobs[job_id][:t_elapsed] = Time.now - @@load_jobs[job_id][:t0]
          end
          Rails.logger.info("[ValidadorDispersiones load #{job_id}] DONE #{rows.size} filas en #{@@load_jobs[job_id][:t_elapsed].round(1)}s")
        rescue => e
          Rails.logger.error("[ValidadorDispersiones load #{job_id}] #{e.class}: #{e.message}")
          Rails.logger.error(e.backtrace.first(8).join("\n"))
          @@load_jobs_mutex.synchronize do
            @@load_jobs[job_id][:status] = :error
            @@load_jobs[job_id][:error]  = e.message
          end
        end
      end

      render json: { ok: true, async: true, status: "queued", job_id: job_id }, status: :accepted
    rescue => e
      Rails.logger.error("[ValidadorDispersionesController#cargar_async] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    def cargar_status
      job_id = params[:job_id].to_s
      _cleanup_load_jobs
      @@load_jobs_mutex.synchronize do
        job = @@load_jobs[job_id]
        return render(json: { ok: false, error: "Job no encontrado o expirado (>10 min)" }, status: :not_found) if job.nil?
        case job[:status]
        when :done
          render json: limpiar({
            ok: true, status: "done",
            t_elapsed: job[:t_elapsed].to_f.round(1),
            **job[:result],
          })
        when :error
          render json: { ok: false, status: "error", error: job[:error] }, status: :internal_server_error
        else
          elapsed = (Time.now - job[:t0]).round(1)
          render json: { ok: true, status: "running", elapsed_sec: elapsed }, status: :accepted
        end
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/validador_dispersiones/exportar_async + export_status
    # ──────────────────────────────────────────────────────────────────────
    def exportar_async
      params_norm = normalizar_params

      if params[:download].to_s == "1" && params[:job_id].present?
        return _descargar_export(params[:job_id].to_s)
      end

      cache_key = "export_#{params_norm.values_at(:desde, :hasta, :moneda, :banco, :buscar_por, :q).join('|')}"
      hit = @@export_jobs_mutex.synchronize do
        @@export_jobs.find { |_, j| j[:cache_key] == cache_key && j[:status] == :done }
      end
      if hit
        return render json: { ok: true, async: false, job_id: hit[0], status: "done", listo_para_descargar: true }
      end

      job_id = SecureRandom.hex(16)
      @@export_jobs_mutex.synchronize do
        @@export_jobs[job_id] = { status: :running, cache_key: cache_key, t0: Time.now, params: params_norm }
      end
      Thread.new do
        begin
          Rails.logger.info("[ValidadorDispersiones export #{job_id}] START")
          rows = ejecutar_query(params_norm)
          stats = construir_stats(rows)
          xlsx_bytes = ValidadorDispersionesExcelBuilder.build(
            desde: params_norm[:desde],
            hasta: params_norm[:hasta],
            filtros: params_norm,
            rows: rows,
            stats: stats,
          )

          tmp = Tempfile.new(["validador_dispersiones_#{job_id}_", ".xlsx"], binmode: true)
          tmp.write(xlsx_bytes); tmp.flush; tmp.close
          xlsx_bytes = nil
          GC.start

          @@export_jobs_mutex.synchronize do
            @@export_jobs[job_id][:status]    = :done
            @@export_jobs[job_id][:file_path] = tmp.path
            @@export_jobs[job_id][:filename]  = "Picap_Validador_Dispersiones_#{params_norm[:desde]}_#{params_norm[:hasta]}.xlsx".gsub(/[: ]/, "_")
            @@export_jobs[job_id][:t_elapsed] = Time.now - @@export_jobs[job_id][:t0]
            @@export_jobs[job_id][:size_kb]   = (File.size(tmp.path).to_f / 1024).round
          end
          Rails.logger.info("[ValidadorDispersiones export #{job_id}] DONE #{@@export_jobs[job_id][:size_kb]}KB en #{@@export_jobs[job_id][:t_elapsed].round(1)}s")
        rescue => e
          Rails.logger.error("[ValidadorDispersiones export #{job_id}] #{e.class}: #{e.message}")
          Rails.logger.error(e.backtrace.first(8).join("\n"))
          @@export_jobs_mutex.synchronize do
            @@export_jobs[job_id][:status] = :error
            @@export_jobs[job_id][:error]  = e.message
          end
        end
      end

      render json: { ok: true, async: true, status: "queued", job_id: job_id }, status: :accepted
    rescue => e
      Rails.logger.error("[ValidadorDispersionesController#exportar_async] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    def export_status
      job_id = params[:job_id].to_s
      _cleanup_export_jobs
      @@export_jobs_mutex.synchronize do
        job = @@export_jobs[job_id]
        return render(json: { ok: false, error: "Job no encontrado o expirado" }, status: :not_found) if job.nil?
        case job[:status]
        when :done
          render json: {
            ok: true, status: "done", listo_para_descargar: true, job_id: job_id,
            size_kb: job[:size_kb], t_elapsed: job[:t_elapsed].to_f.round(1),
          }
        when :error
          render json: { ok: false, error: job[:error], job_id: job_id }, status: :internal_server_error
        else
          elapsed = (Time.now - job[:t0]).round(1)
          render json: { ok: true, async: true, status: "running", elapsed_sec: elapsed, job_id: job_id }, status: :accepted
        end
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # POST /api/validador_dispersiones/enviar_email
    # ──────────────────────────────────────────────────────────────────────
    def enviar_email
      to_list  = BackgroundMailerHelper.parse_email_list(params[:email] || params[:to])
      cc_list  = BackgroundMailerHelper.parse_email_list(params[:cc])
      bcc_list = BackgroundMailerHelper.parse_email_list(params[:bcc])
      asunto   = params[:asunto].to_s.strip
      mensaje  = params[:mensaje].to_s.strip[0, 1000]
      usuario  = current_usuario.to_s

      if to_list.empty?
        return render(json: { ok: false, error: "Tenés que ingresar al menos un destinatario en 'Para'." }, status: :bad_request)
      end
      invalid = (to_list + cc_list + bcc_list).reject { |e| e.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) }
      if invalid.any?
        return render(json: { ok: false, error: "Email(s) inválido(s): #{invalid.join(', ')}" }, status: :bad_request)
      end

      params_norm = normalizar_params
      controller = self
      job_id = BackgroundEmailJobsHelper.start(label: "ValidadorDispersiones", to: to_list) do |progress|
        progress.call("cargando_datos")
        rows = controller.send(:ejecutar_query, params_norm)
        stats = controller.send(:construir_stats, rows)

        progress.call("construyendo_excel")
        xlsx_bytes = ValidadorDispersionesExcelBuilder.build(
          desde: params_norm[:desde],
          hasta: params_norm[:hasta],
          filtros: params_norm,
          rows: rows,
          stats: stats,
        )
        filename = "Picap_Validador_Dispersiones_#{params_norm[:desde]}_#{params_norm[:hasta]}.xlsx".gsub(/[: ]/, "_")
        subject_default = "Validador de Dispersiones · #{params_norm[:desde]} → #{params_norm[:hasta]} (#{rows.size} tx)"
        html = controller.send(:construir_html_email, params_norm, stats, rows.size, mensaje, usuario)

        ResendMailerService.send_email(
          to:                  to_list,
          cc:                  cc_list,
          bcc:                 bcc_list,
          subject:             asunto.empty? ? subject_default : asunto,
          html:                html,
          attachment_bytes:    xlsx_bytes,
          attachment_filename: filename,
          auto_zip:            true,
          progress:            progress,
        )
      end

      render json: {
        ok: true, queued: true, job_id: job_id,
        destinatarios: to_list, cc: cc_list, bcc: bcc_list,
        mensaje: "Reporte en proceso. Polling a /enviar_email_status/:job_id.",
      }, status: :accepted
    rescue => e
      Rails.logger.error("[ValidadorDispersionesController#enviar_email] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    def enviar_email_status
      job = BackgroundEmailJobsHelper.get_status(params[:job_id].to_s)
      return render(json: { ok: false, error: "Job no encontrado o expirado" }, status: :not_found) if job.nil?
      render json: BackgroundEmailJobsHelper.serialize(job)
    end

    private

    def validar_rol
      return if ROLES_PERMITIDOS.include?(current_rol.to_s)
      render json: {
        ok: false,
        error: "Acceso restringido — solo roles: #{ROLES_PERMITIDOS.join(', ')}. Tu rol: #{current_rol || 'sin rol'}",
      }, status: :forbidden
    end

    # Normaliza y sanitiza params del request.
    # Devuelve un hash con: :desde, :hasta, :moneda, :banco, :buscar_por, :q.
    def normalizar_params
      desde_raw = params[:desde].to_s.strip
      hasta_raw = params[:hasta].to_s.strip
      desde = desde_raw.empty? ? "#{(Date.today - 7).strftime('%Y-%m-%d')} 00:00:00" : normalizar_fecha(desde_raw, "00:00:00")
      hasta = hasta_raw.empty? ? "#{Date.today.strftime('%Y-%m-%d')} 23:59:59"        : normalizar_fecha(hasta_raw, "23:59:59")

      moneda     = params[:moneda].to_s.strip.upcase
      moneda     = "COP" if moneda.empty?
      moneda     = "" unless moneda.match?(/\A[A-Z]{3}\z/) && moneda != "ALL"
      banco      = params[:banco].to_s.strip
      buscar_por = params[:buscar_por].to_s.strip
      q          = params[:q].to_s.strip
      {
        desde: desde, hasta: hasta, moneda: moneda,
        banco: banco, buscar_por: buscar_por, q: q,
      }
    end

    # Acepta "YYYY-MM-DD" o "YYYY-MM-DD HH:MM:SS". Devuelve siempre "YYYY-MM-DD HH:MM:SS".
    def normalizar_fecha(raw, default_time)
      raw = raw.to_s.strip
      if raw.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        "#{raw} #{default_time}"
      elsif raw.match?(/\A\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}(:\d{2})?\z/)
        raw.sub("T", " ").then { |s| s.match?(/:\d{2}:\d{2}\z/) ? s : "#{s}:00" }
      else
        raise ArgumentError, "Fecha inválida: #{raw.inspect}. Usá formato YYYY-MM-DD o YYYY-MM-DD HH:MM:SS."
      end
    end

    # Construye el filtro_extra dinámico (sanitizando entradas).
    def construir_filtro_extra(params_norm)
      partes = []
      if params_norm[:moneda].to_s.length == 3
        partes << "AND JSONExtractString(wat.amount, 'currency_iso') = '#{params_norm[:moneda]}'"
      end
      banco = params_norm[:banco].to_s.gsub("'", "")
      partes << "AND lowerUTF8(bk.name) LIKE '%#{banco.downcase}%'" unless banco.empty?

      campo, valor = mapear_busqueda(params_norm[:buscar_por], params_norm[:q])
      partes << "AND #{campo} = '#{valor}'" if campo && valor
      partes.join("\n        ")
    end

    # Mapea buscar_por → campo SQL, sanitizando el valor.
    # Soportados: id_tx, id_user, consecutivo, id_company.
    def mapear_busqueda(buscar_por, q)
      return [nil, nil] if q.to_s.empty?
      val = q.to_s.gsub(/[^a-zA-Z0-9_\-]/, "")
      return [nil, nil] if val.empty?

      case buscar_por.to_s.downcase
      when "id_tx", "id_transaccion"
        ["wat._id", val]
      when "id_user", "id_usuario", "passenger_id"
        ["wa.passenger_id", val]
      when "id_company"
        ["p.company_id", val]
      when "consecutivo", "consecutive"
        ["wat.consecutive", val]
      else
        [nil, nil]
      end
    end

    def ejecutar_query(params_norm)
      filtro_extra = construir_filtro_extra(params_norm)
      sql = QueriesService.format(QueriesService::Q_VALIDADOR_DISPERSIONES,
                                  fecha_desde: params_norm[:desde],
                                  fecha_hasta: params_norm[:hasta],
                                  filtro_extra: filtro_extra)
      t0 = Time.now
      rows = ch.query(sql, timeout: 300)
      Rails.logger.info("[ValidadorDispersiones] Q OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    def construir_stats(rows)
      total = rows.size
      conteos = Hash.new(0)
      sumas   = Hash.new(0.0)
      rows.each do |r|
        est = r["estado"].to_s
        conteos[est] += 1
        sumas[est]   += r["valor"].to_f
      end
      {
        total:                total,
        total_valor:          rows.sum { |r| r["valor"].to_f }.round(2),
        pago_exitoso:         conteos["Pago exitoso"],
        pago_exitoso_valor:   sumas["Pago exitoso"].round(2),
        aprobado:             conteos["Aprobado"],
        aprobado_valor:       sumas["Aprobado"].round(2),
        reembolso:            conteos["Reembolso"],
        reembolso_valor:      sumas["Reembolso"].round(2),
        pendiente:            conteos["Pendiente"],
        pendiente_valor:      sumas["Pendiente"].round(2),
        otro:                 conteos["Otro"],
        otro_valor:           sumas["Otro"].round(2),
      }
    end

    def construir_html_email(p, stats, total, mensaje_usuario, usuario)
      fmt = ->(n) { "$ #{n.to_i.to_s.reverse.scan(/\d{1,3}/).join(".").reverse}" }
      "<!doctype html><html><body style='font-family:Arial,sans-serif;color:#1e1333;max-width:680px;margin:0 auto'>" \
      "<div style='background:linear-gradient(90deg,#6b21a8,#5b21b6);color:#fff;padding:24px;border-radius:8px 8px 0 0'>" \
      "<h2 style='margin:0;font-size:18px'>Validador de Dispersiones</h2>" \
      "<p style='margin:6px 0 0;font-size:13px;color:#e9d5ff'>Período: #{p[:desde]} → #{p[:hasta]}</p>" \
      "</div>" \
      "<div style='border:1px solid #d8d0ec;border-top:0;padding:20px;border-radius:0 0 8px 8px'>" \
      (mensaje_usuario.to_s.empty? ? "" : "<p style='background:#ede9f5;padding:12px;border-left:3px solid #6b21a8;margin:0 0 16px'>#{ERB::Util.h(mensaje_usuario)}</p>") + \
      "<table style='width:100%;border-collapse:collapse;font-size:13px;margin-bottom:16px'>" \
      "<tr><th align='left' style='padding:6px;border-bottom:1px solid #d8d0ec'>Estado</th><th align='right' style='padding:6px;border-bottom:1px solid #d8d0ec'>Cantidad</th><th align='right' style='padding:6px;border-bottom:1px solid #d8d0ec'>Valor</th></tr>" \
      "<tr><td style='padding:6px'>Pago exitoso</td><td align='right' style='padding:6px'>#{stats[:pago_exitoso]}</td><td align='right' style='padding:6px;color:#16a34a'>#{fmt.(stats[:pago_exitoso_valor])}</td></tr>" \
      "<tr><td style='padding:6px'>Aprobado</td><td align='right' style='padding:6px'>#{stats[:aprobado]}</td><td align='right' style='padding:6px;color:#16a34a'>#{fmt.(stats[:aprobado_valor])}</td></tr>" \
      "<tr><td style='padding:6px'>Reembolso</td><td align='right' style='padding:6px'>#{stats[:reembolso]}</td><td align='right' style='padding:6px;color:#dc2626'>#{fmt.(stats[:reembolso_valor])}</td></tr>" \
      "<tr><td style='padding:6px'>Pendiente</td><td align='right' style='padding:6px'>#{stats[:pendiente]}</td><td align='right' style='padding:6px;color:#f59e0b'>#{fmt.(stats[:pendiente_valor])}</td></tr>" \
      "<tr><th align='left' style='padding:6px;border-top:1px solid #d8d0ec'>TOTAL</th><th align='right' style='padding:6px;border-top:1px solid #d8d0ec'>#{total}</th><th align='right' style='padding:6px;border-top:1px solid #d8d0ec'>#{fmt.(stats[:total_valor])}</th></tr>" \
      "</table>" \
      "<p style='font-size:12px;color:#6b5f8a;margin:12px 0 0'>Reporte generado por #{ERB::Util.h(usuario)}. Adjunto: detalle completo en Excel.</p>" \
      "</div></body></html>"
    end

    def _descargar_export(job_id)
      _cleanup_export_jobs
      job = @@export_jobs_mutex.synchronize { @@export_jobs[job_id] }
      return render(json: { ok: false, error: "Job no encontrado o expirado" }, status: :not_found) if job.nil?
      return render(json: { ok: false, error: "Job aún corriendo o falló" }, status: :unprocessable_entity) unless job[:status] == :done

      file_path = job[:file_path]
      unless file_path && File.exist?(file_path)
        return render(json: { ok: false, error: "Archivo temporal no disponible" }, status: :gone)
      end
      send_file file_path,
                filename: job[:filename],
                type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                disposition: "attachment"
    end

    def _cleanup_load_jobs
      now = Time.now
      @@load_jobs_mutex.synchronize do
        @@load_jobs.delete_if { |_, j| (now - j[:t0]) > LOAD_JOB_TTL_SEC }
      end
    end

    def _cleanup_export_jobs
      now = Time.now
      @@export_jobs_mutex.synchronize do
        @@export_jobs.delete_if do |_, j|
          expired = (now - j[:t0]) > EXPORT_JOB_TTL_SEC
          if expired && j[:file_path] && File.exist?(j[:file_path])
            begin
              File.delete(j[:file_path])
            rescue => e
              Rails.logger.warn("[ValidadorDispersiones cleanup] could not delete #{j[:file_path]}: #{e.message}")
            end
          end
          expired
        end
      end
    end

    def limpiar(obj)
      ClickhouseClient.limpiar(obj)
    end
  end
end
