# app/controllers/api/consolidado_cash_out_controller.rb
# v3.3.56 — Consolidado Cash Out (submódulo de Cash Out).
#
# Construye 5 tablas resumen + 2 detalles a partir de Q_CONSOLIDADO_CASH_OUT.
#
# Reglas de no-duplicación en GRAN TOTAL:
#   - Clientes = registros con Es_Cliente=1 (company_id NOT NULL)
#   - Pilotos / Pasajeros / Empleados = registros con Es_Cliente=0 + Tipo_de_Usuario
#   - GRAN_TOTAL = Pilotos + Pasajeros + Empleados + Clientes (= SUM(todo))
#
# Endpoints:
#   GET  /api/consolidado_cash_out/cargar_async                 → arranca job
#   GET  /api/consolidado_cash_out/cargar_status/:job_id        → polling
#   GET  /api/consolidado_cash_out/exportar_async               → Excel async
#   GET  /api/consolidado_cash_out/export_status/:job_id        → polling Excel
#   POST /api/consolidado_cash_out/enviar_email                 → email
#   GET  /api/consolidado_cash_out/enviar_email_status/:job_id  → polling email
#
# Roles: admin / monitoreo / financiero.
require "tempfile"

module Api
  class ConsolidadoCashOutController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol

    ROLES_PERMITIDOS = %w[admin monitoreo financiero].freeze
    JORNADAS = ["Bolsa Mañana", "Bolsa Tarde"].freeze
    TIPOS_USUARIO = %w[Piloto Pasajero Empleado].freeze

    @@load_jobs       = {}
    @@load_jobs_mutex = Mutex.new
    LOAD_JOB_TTL_SEC  = 600

    @@export_jobs       = {}
    @@export_jobs_mutex = Mutex.new
    EXPORT_JOB_TTL_SEC  = 1_800

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/consolidado_cash_out/cargar_async?desde=&hasta=
    # ──────────────────────────────────────────────────────────────────────
    def cargar_async
      desde = normalizar_fecha(params[:desde].to_s, "00:00:00", -7)
      hasta = normalizar_fecha(params[:hasta].to_s, "23:59:59", 0)

      cache_key = "consol_#{desde}_#{hasta}"
      hit = @@load_jobs_mutex.synchronize { @@load_jobs.find { |_, j| j[:cache_key] == cache_key && j[:status] == :done } }
      if hit
        job_id, job = hit
        return render(json: limpiar(job[:result].merge(cached: true, status: "done", ok: true, job_id: job_id)))
      end

      job_id = SecureRandom.hex(16)
      @@load_jobs_mutex.synchronize do
        @@load_jobs[job_id] = { status: :running, cache_key: cache_key, t0: Time.now, desde: desde, hasta: hasta }
      end

      Thread.new do
        begin
          Rails.logger.info("[ConsolidadoCashOut load #{job_id}] START #{desde} → #{hasta}")
          rows  = ejecutar_query(desde, hasta)
          result = procesar_data(rows, desde, hasta)
          @@load_jobs_mutex.synchronize do
            @@load_jobs[job_id][:status]    = :done
            @@load_jobs[job_id][:result]    = result
            @@load_jobs[job_id][:t_elapsed] = Time.now - @@load_jobs[job_id][:t0]
          end
          Rails.logger.info("[ConsolidadoCashOut load #{job_id}] DONE #{rows.size} filas en #{@@load_jobs[job_id][:t_elapsed].round(1)}s")
        rescue => e
          Rails.logger.error("[ConsolidadoCashOut load #{job_id}] #{e.class}: #{e.message}")
          Rails.logger.error(e.backtrace.first(8).join("\n"))
          @@load_jobs_mutex.synchronize do
            @@load_jobs[job_id][:status] = :error
            @@load_jobs[job_id][:error]  = e.message
          end
        end
      end

      render json: { ok: true, async: true, status: "queued", job_id: job_id }, status: :accepted
    rescue => e
      Rails.logger.error("[ConsolidadoCashOutController#cargar_async] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    def cargar_status
      job_id = params[:job_id].to_s
      _cleanup_load_jobs
      @@load_jobs_mutex.synchronize do
        job = @@load_jobs[job_id]
        return render(json: { ok: false, error: "Job no encontrado o expirado" }, status: :not_found) if job.nil?
        case job[:status]
        when :done
          render json: limpiar(job[:result].merge(ok: true, status: "done", t_elapsed: job[:t_elapsed].to_f.round(1)))
        when :error
          render json: { ok: false, status: "error", error: job[:error] }, status: :internal_server_error
        else
          render json: { ok: true, status: "running", elapsed_sec: (Time.now - job[:t0]).round(1) }, status: :accepted
        end
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # GET /api/consolidado_cash_out/exportar_async + export_status
    # ──────────────────────────────────────────────────────────────────────
    def exportar_async
      desde = normalizar_fecha(params[:desde].to_s, "00:00:00", -7)
      hasta = normalizar_fecha(params[:hasta].to_s, "23:59:59", 0)

      if params[:download].to_s == "1" && params[:job_id].present?
        return _descargar_export(params[:job_id].to_s)
      end

      job_id = SecureRandom.hex(16)
      @@export_jobs_mutex.synchronize do
        @@export_jobs[job_id] = { status: :running, t0: Time.now, desde: desde, hasta: hasta }
      end
      Thread.new do
        begin
          Rails.logger.info("[ConsolidadoCashOut export #{job_id}] START #{desde} → #{hasta}")
          rows   = ejecutar_query(desde, hasta)
          result = procesar_data(rows, desde, hasta)
          xlsx_bytes = ConsolidadoCashOutExcelBuilder.build(desde: desde, hasta: hasta, result: result, rows: rows)
          tmp = Tempfile.new(["consolidado_cash_out_#{job_id}_", ".xlsx"], binmode: true)
          tmp.write(xlsx_bytes); tmp.flush; tmp.close
          GC.start

          @@export_jobs_mutex.synchronize do
            @@export_jobs[job_id][:status]    = :done
            @@export_jobs[job_id][:file_path] = tmp.path
            @@export_jobs[job_id][:filename]  = "Picap_Consolidado_Cash_Out_#{desde.first(10)}_#{hasta.first(10)}.xlsx".gsub(/[: ]/, "_")
            @@export_jobs[job_id][:t_elapsed] = Time.now - @@export_jobs[job_id][:t0]
            @@export_jobs[job_id][:size_kb]   = (File.size(tmp.path).to_f / 1024).round
          end
          Rails.logger.info("[ConsolidadoCashOut export #{job_id}] DONE #{@@export_jobs[job_id][:size_kb]}KB en #{@@export_jobs[job_id][:t_elapsed].round(1)}s")
        rescue => e
          Rails.logger.error("[ConsolidadoCashOut export #{job_id}] #{e.class}: #{e.message}")
          Rails.logger.error(e.backtrace.first(8).join("\n"))
          @@export_jobs_mutex.synchronize do
            @@export_jobs[job_id][:status] = :error
            @@export_jobs[job_id][:error]  = e.message
          end
        end
      end

      render json: { ok: true, async: true, status: "queued", job_id: job_id }, status: :accepted
    rescue => e
      Rails.logger.error("[ConsolidadoCashOutController#exportar_async] #{e.class}: #{e.message}")
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
          render json: { ok: true, status: "done", listo_para_descargar: true, job_id: job_id, size_kb: job[:size_kb], t_elapsed: job[:t_elapsed].to_f.round(1) }
        when :error
          render json: { ok: false, error: job[:error], job_id: job_id }, status: :internal_server_error
        else
          render json: { ok: true, async: true, status: "running", elapsed_sec: (Time.now - job[:t0]).round(1), job_id: job_id }, status: :accepted
        end
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # POST /api/consolidado_cash_out/enviar_email
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

      desde = normalizar_fecha(params[:desde].to_s, "00:00:00", -7)
      hasta = normalizar_fecha(params[:hasta].to_s, "23:59:59", 0)
      controller = self
      job_id = BackgroundEmailJobsHelper.start(label: "ConsolidadoCashOut", to: to_list) do |progress|
        progress.call("cargando_datos")
        rows   = controller.send(:ejecutar_query, desde, hasta)
        result = controller.send(:procesar_data, rows, desde, hasta)

        progress.call("construyendo_excel")
        xlsx_bytes = ConsolidadoCashOutExcelBuilder.build(desde: desde, hasta: hasta, result: result, rows: rows)
        filename = "Picap_Consolidado_Cash_Out_#{desde.first(10)}_#{hasta.first(10)}.xlsx".gsub(/[: ]/, "_")
        html = controller.send(:construir_html_email, desde, hasta, result, mensaje, usuario)

        ResendMailerService.send_email(
          to: to_list, cc: cc_list, bcc: bcc_list,
          subject: asunto.empty? ? "Consolidado Cash Out · #{desde.first(10)} → #{hasta.first(10)}" : asunto,
          html: html, attachment_bytes: xlsx_bytes, attachment_filename: filename,
          auto_zip: true, progress: progress,
        )
      end

      render json: { ok: true, queued: true, job_id: job_id, destinatarios: to_list, cc: cc_list, bcc: bcc_list,
                     mensaje: "Consolidado en proceso. Polling a /enviar_email_status/:job_id." }, status: :accepted
    rescue => e
      Rails.logger.error("[ConsolidadoCashOutController#enviar_email] #{e.class}: #{e.message}")
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
      render json: { ok: false, error: "Acceso restringido — solo roles: #{ROLES_PERMITIDOS.join(', ')}. Tu rol: #{current_rol || 'sin rol'}" }, status: :forbidden
    end

    def normalizar_fecha(raw, default_time, days_offset_default)
      raw = raw.to_s.strip
      return "#{(Date.today + days_offset_default).strftime('%Y-%m-%d')} #{default_time}" if raw.empty?
      if raw.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        "#{raw} #{default_time}"
      elsif raw.match?(/\A\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}(:\d{2})?\z/)
        raw.sub("T", " ").then { |s| s.match?(/:\d{2}:\d{2}\z/) ? s : "#{s}:00" }
      else
        raise ArgumentError, "Fecha inválida: #{raw.inspect}. Usá YYYY-MM-DD o YYYY-MM-DD HH:MM:SS."
      end
    end

    def ejecutar_query(desde, hasta)
      sql = QueriesService.format(QueriesService::Q_CONSOLIDADO_CASH_OUT,
                                  fecha_desde: desde, fecha_hasta: hasta)
      t0 = Time.now
      rows = ch.query(sql, timeout: 300)
      Rails.logger.info("[ConsolidadoCashOut] Q OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    # ──────────────────────────────────────────────────────────────────────
    # PROCESAMIENTO — pivot tables + detalles
    # ──────────────────────────────────────────────────────────────────────
    #
    # Estructura de retorno:
    #   {
    #     desde:, hasta:, total_rows:,
    #     resumen_tipo:        { rows: [{label, Bolsa Mañana, Bolsa Tarde, Total}, ...], totals: {...} },
    #     resumen_desglosado:  { rows: [...], totals: {...} },
    #     resumen_clientes:    { rows: [...], totals: {...} },
    #     resumen_bolsa:       { rows: [...], totals: {...} },
    #     totales:             { pilotos, pasajeros, empleados, clientes, gran_total },
    #     detallado:           [ { Fecha, Jornada, Tipo_de_Usuario, Tipo, Tipo_de_Desglosado, Valor } ],
    #     clientes_detalle:    [ { Fecha, Jornada, Cliente_Nombre, Tipo, Tipo_de_Desglosado, Valor } ],
    #   }
    def procesar_data(rows, desde, hasta)
      no_cliente = rows.reject { |r| r["Es_Cliente"].to_i == 1 }
      clientes   = rows.select { |r| r["Es_Cliente"].to_i == 1 }

      {
        desde: desde, hasta: hasta, total_rows: rows.size,

        # Tabla 1: pivot Tipo × Jornada (todos los registros)
        resumen_tipo:       pivot_table(rows, key: "Tipo"),
        # Tabla 2: pivot Tipo_de_Desglosado × Jornada
        resumen_desglosado: pivot_table(rows, key: "Tipo_de_Desglosado"),
        # Tabla 3: pivot Cliente_Nombre × Jornada (solo clientes)
        resumen_clientes:   pivot_table(clientes, key: "Cliente_Nombre"),
        # Tabla 4: pivot Tipo_de_Usuario × Jornada (solo NO-clientes)
        resumen_bolsa:      pivot_table(no_cliente, key: "Tipo_de_Usuario"),

        # Tabla 5: totales (sin overlap)
        totales: {
          pilotos:    no_cliente.select { |r| r["Tipo_de_Usuario"] == "Piloto"    }.sum { |r| r["Valor"].to_f },
          pasajeros:  no_cliente.select { |r| r["Tipo_de_Usuario"] == "Pasajero"  }.sum { |r| r["Valor"].to_f },
          empleados:  no_cliente.select { |r| r["Tipo_de_Usuario"] == "Empleado"  }.sum { |r| r["Valor"].to_f },
          clientes:   clientes.sum { |r| r["Valor"].to_f },
          gran_total: rows.sum { |r| r["Valor"].to_f },
        },

        # Detallado para Panel 2 (Pilotos / Pasajeros / Empleados)
        detallado: no_cliente.map { |r| r.slice("Fecha", "Jornada", "Tipo_de_Usuario", "Tipo", "Tipo_de_Desglosado", "Valor") },

        # Detalle clientes para Panel 3
        clientes_detalle: clientes.map { |r| r.slice("Fecha", "Jornada", "Cliente_Nombre", "Tipo", "Tipo_de_Desglosado", "Valor") },
      }
    end

    # Construye una pivot tipo "key × Jornada" con Total por fila + fila TOTAL final.
    def pivot_table(rows, key:)
      agg = Hash.new { |h, k| h[k] = Hash.new(0.0) }
      JORNADAS.each { |j| }
      rows.each do |r|
        label   = (r[key].to_s.empty? ? "(sin valor)" : r[key].to_s)
        jornada = r["Jornada"].to_s
        agg[label][jornada] += r["Valor"].to_f
      end
      out_rows = agg.sort_by { |label, _| -agg[label].values.sum }.map do |label, jornadas|
        row = { "label" => label }
        JORNADAS.each { |j| row[j] = (jornadas[j] || 0.0).round(2) }
        row["Total"] = JORNADAS.sum { |j| row[j] }.round(2)
        row
      end
      totals = { "label" => "TOTAL" }
      JORNADAS.each { |j| totals[j] = out_rows.sum { |r| r[j].to_f }.round(2) }
      totals["Total"] = out_rows.sum { |r| r["Total"].to_f }.round(2)
      { rows: out_rows, totals: totals, jornadas: JORNADAS }
    end

    def construir_html_email(desde, hasta, result, mensaje_usuario, usuario)
      t = result[:totales]
      fmt = ->(n) { "$ #{n.to_i.abs.to_s.reverse.scan(/\d{1,3}/).join(".").reverse}#{n < 0 ? " (neg)" : ""}" }
      mensaje_html = mensaje_usuario.to_s.empty? ? "" : "<p style='background:#ede9f5;padding:12px;border-left:3px solid #6b21a8;margin:0 0 16px'>#{ERB::Util.h(mensaje_usuario)}</p>"
      <<~HTML
        <!doctype html><html><body style='font-family:Arial,sans-serif;color:#1e1333;max-width:680px;margin:0 auto'>
        <div style='background:linear-gradient(90deg,#6b21a8,#3b0764);color:#fff;padding:24px;border-radius:8px 8px 0 0'>
          <h2 style='margin:0;font-size:18px'>Consolidado Cash Out</h2>
          <p style='margin:6px 0 0;font-size:13px;color:#e9d5ff'>Período: #{desde} → #{hasta}</p>
        </div>
        <div style='border:1px solid #d8d0ec;border-top:0;padding:20px;border-radius:0 0 8px 8px'>
          #{mensaje_html}
          <table style='width:100%;border-collapse:collapse;font-size:13px;margin-bottom:16px'>
            <tr><th align='left' style='padding:6px;border-bottom:1px solid #d8d0ec'>Categoría</th><th align='right' style='padding:6px;border-bottom:1px solid #d8d0ec'>Total</th></tr>
            <tr><td style='padding:6px'>Pilotos</td><td align='right' style='padding:6px;color:#3b82f6'>#{fmt.(t[:pilotos])}</td></tr>
            <tr><td style='padding:6px'>Pasajeros</td><td align='right' style='padding:6px;color:#16a34a'>#{fmt.(t[:pasajeros])}</td></tr>
            <tr><td style='padding:6px'>Empleados</td><td align='right' style='padding:6px;color:#f97316'>#{fmt.(t[:empleados])}</td></tr>
            <tr><td style='padding:6px'>Clientes (Compañías)</td><td align='right' style='padding:6px;color:#7c3aed'>#{fmt.(t[:clientes])}</td></tr>
            <tr><th align='left' style='padding:6px;border-top:1px solid #d8d0ec'>GRAN TOTAL</th><th align='right' style='padding:6px;border-top:1px solid #d8d0ec;color:#6b21a8'>#{fmt.(t[:gran_total])}</th></tr>
          </table>
          <p style='font-size:12px;color:#6b5f8a;margin:12px 0 0'>Reporte generado por #{ERB::Util.h(usuario)}. Adjunto: Excel con resúmenes + detalles.</p>
        </div>
        </body></html>
      HTML
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
      send_file file_path, filename: job[:filename],
                type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                disposition: "attachment"
    end

    def _cleanup_load_jobs
      now = Time.now
      @@load_jobs_mutex.synchronize { @@load_jobs.delete_if { |_, j| (now - j[:t0]) > LOAD_JOB_TTL_SEC } }
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
              Rails.logger.warn("[ConsolidadoCashOut cleanup] could not delete #{j[:file_path]}: #{e.message}")
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
