# app/controllers/api/reporte_ops_cv_controller.rb
# Reporte OPS CV — bookings Pibox para companies Cruz Verde
# ('60bfe7d575970c0108014b12' y '624dd6cdac8991004cafc881').
# Acceso restringido: admin / monitoreo / financiero.
#
# Endpoints:
#   GET  /api/reporte_ops_cv               → lista + stats
#   POST /api/reporte_ops_cv/enviar_email  → enviar xlsx adjunto vía Resend

module Api
  class ReporteOpsCvController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol_reporte_ops_cv

    ROLES_PERMITIDOS = %w[admin monitoreo financiero].freeze

    # GET /api/reporte_ops_cv?desde=&hasta=&estado=&next_day=&ciudad=
    def index
      desde    = desde_param
      hasta    = hasta_param
      estado   = params[:estado].to_s.strip
      next_day = params[:next_day].to_s.strip
      ciudad   = params[:ciudad].to_s.strip

      rows = cargar_filas(desde: desde, hasta: hasta,
                          estado: estado, next_day: next_day, ciudad: ciudad)

      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta,
        total: rows.size,
        stats: calcular_stats(rows),
        filas: rows.first(5_000),  # safety cap UI
      })
    rescue => e
      Rails.logger.error("[ReporteOpsCvController#index] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/reporte_ops_cv/enviar_email
    # v3.3.12: respuesta inmediata + envío en background thread.
    # La query CH tarda ~2m + build xlsx + Resend = ~3m total. El proxy
    # frontend cierra la conexión a los ~60s (502 Bad Gateway), aunque
    # internamente el envío sí completaba. Ahora respondemos 202 al
    # toque y el thread sigue solo.
    def enviar_email
      to_list  = parse_email_list(params[:email] || params[:to])
      cc_list  = parse_email_list(params[:cc])
      bcc_list = parse_email_list(params[:bcc])
      asunto   = params[:asunto].to_s.strip
      mensaje  = params[:mensaje].to_s.strip[0, 1000]
      desde    = desde_param
      hasta    = hasta_param
      estado   = params[:estado].to_s.strip
      next_day = params[:next_day].to_s.strip
      ciudad   = params[:ciudad].to_s.strip
      usuario  = current_usuario.to_s

      if to_list.empty?
        return render(json: { ok: false, error: "Tenés que ingresar al menos un destinatario en 'Para'." }, status: :bad_request)
      end
      invalid = (to_list + cc_list + bcc_list).reject { |e| e.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) }
      if invalid.any?
        return render(json: { ok: false, error: "Email(s) inválido(s): #{invalid.join(', ')}" }, status: :bad_request)
      end

      # v3.3.20: usa BackgroundMailerHelper (helper común).
      BackgroundMailerHelper.run("ReporteOpsCV") do
        rows = cargar_filas(desde: desde, hasta: hasta,
                            estado: estado, next_day: next_day, ciudad: ciudad)
        xlsx = Api::ExportarController.build_reporte_ops_cv_xlsx(
          desde, hasta, ch,
          estado: estado, next_day: next_day, ciudad: ciudad,
          preloaded_rows: rows,
        )
        filename = "Picap_Reporte_OPS_CV_#{desde}_#{hasta}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.xlsx"
        subject_default = "Reporte OPS CV · #{desde} → #{hasta} (#{rows.size} servicios)"
        html = construir_html_email(desde, hasta, rows, mensaje, usuario)
        ResendMailerService.send_email(
          to:                  to_list,
          cc:                  cc_list,
          bcc:                 bcc_list,
          subject:             asunto.empty? ? subject_default : asunto,
          html:                html,
          attachment_bytes:    xlsx[:data],
          attachment_filename: filename,
        )
      end

      render json: {
        ok: true,
        queued: true,
        destinatarios: to_list,
        cc: cc_list,
        bcc: bcc_list,
        mensaje: "Reporte en proceso. El email con el adjunto Excel llegará en 2-4 minutos.",
      }, status: :accepted
    rescue => e
      Rails.logger.error("[ReporteOpsCvController#enviar_email] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def parse_email_list(val)
      return [] if val.nil?
      raw = val.is_a?(Array) ? val.join(",") : val.to_s
      raw.split(/[,;\s\n]+/).map(&:strip).reject(&:empty?).uniq
    end

    def validar_rol_reporte_ops_cv
      return if ROLES_PERMITIDOS.include?(current_rol.to_s)
      render json: {
        ok: false,
        error: "Acceso restringido — solo roles: #{ROLES_PERMITIDOS.join(', ')}. Tu rol: #{current_rol || 'sin rol'}",
      }, status: :forbidden
    end

    def cargar_filas(desde:, hasta:, estado: "", next_day: "", ciudad: "")
      sql = QueriesService.format(
        QueriesService::Q_REPORTE_OPS_CV,
        fecha_desde: desde, fecha_hasta: hasta,
      )
      rows = ch.query(sql, timeout: 600).map { |r| normalizar(r) }
      rows = rows.select { |r| r["estado"].to_s == estado }   unless estado.empty?
      rows = rows.select { |r| r["next_day"].to_s == next_day } unless next_day.empty?
      unless ciudad.empty?
        c_low = ciudad.downcase
        rows = rows.select { |r| r["ciudad"].to_s.downcase.include?(c_low) }
      end
      rows
    end

    def normalizar(r)
      {
        "uuid_booking"                    => r["uuid_booking"].to_s,
        "id_parada"                       => r["id_parada"].to_s,
        "iniciado"                        => r["iniciado"].to_s,
        "asignado"                        => r["asignado"].to_s,
        "llego_al_origen"                 => r["llego_al_origen"].to_s,
        "salio_de_origen"                 => r["salio_de_origen"].to_s,
        "llego_donde_el_cliente"          => r["llego_donde_el_cliente"].to_s,
        "id_paquete"                      => r["id_paquete"].to_s,
        "fecha_entrega_paquete"           => r["fecha_entrega_paquete"].to_s,
        "descripcion"                     => r["descripcion"].to_s,
        "fecha_devolucion_paquete"        => r["fecha_devolucion_paquete"].to_s,
        "fecha_cancelacion_paquete"       => r["fecha_cancelacion_paquete"].to_s,
        "fecha_paquete_no_recibido"       => r["fecha_paquete_no_recibido"].to_s,
        "estado"                          => r["estado"].to_s,
        "programado"                      => r["programado"].to_s,
        "next_day"                        => r["next_day"].to_s,
        "finalizado_fallido"              => r["finalizado_fallido"].to_s,
        "finalizo_servicio"               => r["finalizo_servicio"].to_s,
        "num_orden"                       => r["num_orden"].to_s,
        "nombre_usuario"                  => r["nombre_usuario"].to_s,
        "ciudad"                          => r["ciudad"].to_s,
        "direccion_origen"                => r["direccion_origen"].to_s,
        "direccion_de_destino"            => r["direccion_de_destino"].to_s,
        "parada_de_regreso"               => r["parada_de_regreso"].to_s,
        "nombre_cliente"                  => r["nombre_cliente"].to_s,
        "telefono_cliente"                => r["telefono_cliente"].to_s,
        "duracion_espera"                 => r["duracion_espera"].to_i,
        "duracion_servicio_copy"          => r["duracion_servicio_copy"].to_i,
        "min_tiempo_de_relanzamiento_min" => r["min_tiempo_de_relanzamiento_min"].to_f.round(2),
        "min_tiempo_de_servicio"          => r["min_tiempo_de_servicio"].to_f.round(2),
        "latitud"                         => r["latitud"].to_f.round(3),
        "longitud"                        => r["longitud"].to_f.round(3),
        "recuento_definido_de_uuid"       => r["recuento_definido_de_uuid"].to_i,
        "costo_servicio"                  => r["costo_servicio"].to_f.round(2),
        "distancia_km"                    => r["distancia_km"].to_f.round(2),
        "llegada_a_origen_min"            => r["llegada_a_origen_min"].to_f.round(2),
        "orden_parada"                    => r["orden_parada"].to_i,
        "valor_declarado"                 => r["valor_declarado"].to_f.round(2),
      }
    end

    # KPIs ejecutivos + breakdowns
    def calcular_stats(rows)
      total      = rows.size
      finalizados = rows.count { |r| r["estado"] == "Finalizado" }
      cancelados  = rows.count { |r| r["estado"] == "Cancelado"  }
      expirados   = rows.count { |r| r["estado"] == "Expirado"   }
      sin_clasif  = rows.count { |r| r["estado"].to_s.start_with?("Status [") }
      fallidos    = rows.count { |r| r["finalizado_fallido"] == "SI" }
      same_day    = rows.count { |r| r["next_day"] == "Same Day" }
      next_day_n  = rows.count { |r| r["next_day"] == "Next Day" }
      costo_total = rows.sum { |r| r["costo_servicio"].to_f }
      distancia_total = rows.sum { |r| r["distancia_km"].to_f }
      tiempos = rows.map { |r| r["min_tiempo_de_servicio"].to_f }.reject(&:zero?)
      tiempo_avg  = tiempos.empty? ? 0 : (tiempos.sum / tiempos.size)
      n_unique_bookings = rows.map { |r| r["uuid_booking"] }.uniq.size
      n_unique_paquetes = rows.map { |r| r["id_paquete"] }.uniq.size

      # Tendencia diaria por fecha_iniciado (yyyy-mm-dd)
      por_dia = rows.group_by { |r| r["iniciado"].to_s[0, 10] }
                    .map { |fecha, grupo| {
                      fecha: fecha,
                      cant:  grupo.size,
                      finalizados: grupo.count { |g| g["estado"] == "Finalizado" },
                      costo: grupo.sum { |g| g["costo_servicio"].to_f }.round(2),
                    } }
                    .sort_by { |h| h[:fecha] }

      # Top ciudades por #servicios
      top_ciudades = rows.group_by { |r| r["ciudad"].to_s.empty? ? "(sin ciudad)" : r["ciudad"] }
                         .map { |c, g| { ciudad: c, cant: g.size,
                                          finalizados: g.count { |x| x["estado"] == "Finalizado" },
                                          costo: g.sum { |x| x["costo_servicio"].to_f }.round(2) } }
                         .sort_by { |h| -h[:cant] }
                         .first(10)

      # Top usuarios (passengers / sucursales)
      top_usuarios = rows.group_by { |r| r["nombre_usuario"].to_s.empty? ? "(sin nombre)" : r["nombre_usuario"] }
                         .map { |u, g| { usuario: u, cant: g.size,
                                          costo: g.sum { |x| x["costo_servicio"].to_f }.round(2) } }
                         .sort_by { |h| -h[:cant] }
                         .first(10)

      # Top motivos de fallo / cancelación (descripcion)
      top_motivos = rows.select { |r| !r["descripcion"].to_s.strip.empty? }
                        .group_by { |r| r["descripcion"].to_s.strip }
                        .map { |m, g| { motivo: m, cant: g.size } }
                        .sort_by { |h| -h[:cant] }
                        .first(10)

      pct = ->(n) { total > 0 ? (n.to_f / total * 100).round(1) : 0 }

      {
        total:                total,
        bookings_unicos:      n_unique_bookings,
        paquetes_unicos:      n_unique_paquetes,
        finalizados:          finalizados,
        cancelados:           cancelados,
        expirados:            expirados,
        sin_clasificar:       sin_clasif,
        fallidos:             fallidos,
        same_day:             same_day,
        next_day:             next_day_n,
        pct_finalizados:      pct.(finalizados),
        pct_cancelados:       pct.(cancelados),
        pct_fallidos:         pct.(fallidos),
        costo_total:          costo_total.round(2),
        distancia_total:      distancia_total.round(2),
        tiempo_promedio_min:  tiempo_avg.round(2),
        por_dia:              por_dia,
        top_ciudades:         top_ciudades,
        top_usuarios:         top_usuarios,
        top_motivos:          top_motivos,
      }
    end

    def construir_html_email(desde, hasta, rows, mensaje_usuario, usuario)
      fmt_num   = ->(n) { (n || 0).to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1.').reverse }
      fmt_money = ->(n) { "$ #{fmt_num.((n || 0).abs)}" }
      total       = rows.size
      finalizados = rows.count { |r| r["estado"] == "Finalizado" }
      cancelados  = rows.count { |r| r["estado"] == "Cancelado"  }
      fallidos    = rows.count { |r| r["finalizado_fallido"] == "SI" }
      costo_total = rows.sum { |r| r["costo_servicio"].to_f }
      pct = ->(n) { total > 0 ? "#{(n.to_f / total * 100).round(1)}%" : "0%" }
      msj_html = mensaje_usuario.empty? ? "" : %Q(<p style="background:#FFFBEB;border-left:4px solid #F59E0B;padding:12px 16px;margin:16px 0;border-radius:4px;color:#78350F"><strong>Mensaje:</strong> #{ERB::Util.h(mensaje_usuario)}</p>)

      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#F5F3FF;color:#1F2937;">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F5F3FF;padding:20px 0">
            <tr><td align="center">
              <table cellpadding="0" cellspacing="0" border="0" width="640" style="background:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
                <tr><td style="background:linear-gradient(90deg,#0e7490 0%,#0369a1 100%);padding:24px 28px;color:#ffffff">
                  <div style="font-size:22px;font-weight:700;letter-spacing:-0.5px">🚀 Reporte Operaciones CV</div>
                  <div style="font-size:13px;margin-top:6px;opacity:0.92">Período: #{desde} → #{hasta}</div>
                </td></tr>
                <tr><td style="padding:28px">
                  <p style="margin:0 0 12px;font-size:14px">Hola,</p>
                  <p style="margin:0 0 12px;font-size:14px;line-height:1.5">Te compartimos el reporte de operaciones Cruz Verde del período indicado. El detalle completo (37 columnas, 1 fila por paquete) está en el archivo Excel adjunto.</p>
                  #{msj_html}
                  <h3 style="color:#0e7490;margin:24px 0 12px;font-size:15px">📈 Resumen ejecutivo</h3>
                  <table cellpadding="0" cellspacing="6" border="0" width="100%" style="margin:0 -6px">
                    <tr>
                      <td style="background:#E0F2FE;border-top:3px solid #0e7490;padding:12px;border-radius:6px;width:50%">
                        <div style="font-size:22px;font-weight:700;color:#1F2937">#{fmt_num.(total)}</div>
                        <div style="font-size:11px;color:#6B7280;margin-top:4px">Servicios (paquetes)</div>
                      </td>
                      <td style="background:#DCFCE7;border-top:3px solid #16A34A;padding:12px;border-radius:6px;width:50%">
                        <div style="font-size:22px;font-weight:700;color:#166534">#{fmt_num.(finalizados)} · #{pct.(finalizados)}</div>
                        <div style="font-size:11px;color:#166534;margin-top:4px">Finalizados</div>
                      </td>
                    </tr>
                    <tr>
                      <td style="background:#FEE2E2;border:1px solid #FCA5A5;padding:12px;border-radius:6px">
                        <div style="font-size:11px;color:#991B1B">Cancelados · Fallidos</div>
                        <div style="font-size:18px;font-weight:700;color:#991B1B;margin-top:4px">#{fmt_num.(cancelados)} · #{fmt_num.(fallidos)}</div>
                      </td>
                      <td style="background:#FAFAFA;border:1px solid #E5E7EB;padding:12px;border-radius:6px">
                        <div style="font-size:11px;color:#6B7280">Costo total servicios</div>
                        <div style="font-size:18px;font-weight:700;color:#0e7490;margin-top:4px">#{fmt_money.(costo_total)}</div>
                      </td>
                    </tr>
                  </table>
                  <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">📎 <strong>Adjunto:</strong> archivo Excel (.xlsx) con la hoja "Data" — 37 columnas y todas las filas del período (paquetes Pibox para companies Cruz Verde).</p>
                </td></tr>
                <tr><td style="background:#F9FAFB;padding:16px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                  Generado automáticamente · <strong style="color:#0e7490">Picap Monitoreo</strong> · #{Time.now.strftime('%d/%m/%Y %H:%M')}<br>
                  Por: #{ERB::Util.h(usuario || 'sistema')}
                </td></tr>
              </table>
            </td></tr>
          </table>
        </body></html>
      HTML
    end

    def desde_param
      params[:desde].presence || (Date.today - 30).strftime("%Y-%m-%d")
    end

    def hasta_param
      params[:hasta].presence || Date.today.strftime("%Y-%m-%d")
    end

    def limpiar(obj)
      ClickhouseClient.limpiar(obj)
    end
  end
end
