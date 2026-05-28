# app/controllers/api/resumen_controller.rb
# Replica cargar_datos() + endpoint /api/resumen del api.py Python (líneas 438-676)
module Api
  class ResumenController < ApplicationController
    before_action :authenticate_user!

    # GET /api/resumen?desde=YYYY-MM-DD&hasta=YYYY-MM-DD&pais=Colombia
    def index
      desde  = desde_param
      hasta  = hasta_param
      pais   = pais_param
      iso    = iso_pais  # ej: "CO", "MX", "" (vacío = todos)
      moneda = params[:moneda].to_s.strip
      tasa   = QueriesService.tasa_para(pais)

      # Construir CTE con filtro de país inyectado (replica .replace() del Python)
      cte = QueriesService.cte_con_pais(iso, moneda)

      # Componer las 4 queries y formatear con fechas
      q_kpis     = QueriesService.format(cte + QueriesService::KPIS_SUFFIX,        fecha_desde: desde, fecha_hasta: hasta)
      q_tend     = QueriesService.format(cte + QueriesService::TENDENCIA_SUFFIX,   fecha_desde: desde, fecha_hasta: hasta)
      q_ciudad   = QueriesService.format(cte + QueriesService::CIUDADES_SUFFIX,    fecha_desde: desde, fecha_hasta: hasta)
      q_drivers  = QueriesService.format(cte + QueriesService::TOP_DRIVERS_SUFFIX, fecha_desde: desde, fecha_hasta: hasta)

      k = (ch.query(q_kpis).first || {})
      t =  ch.query(q_tend)
      c =  ch.query(q_ciudad)
      d =  ch.query(q_drivers)

      total       = k["total"].to_i
      conf        = k["confirmadas"].to_i
      prob        = k["probables"].to_i
      tasa_evas   = total > 0 ? ((conf + prob).to_f / total * 100).round(1) : 0

      payload = {
        ok: true,
        loading: false,
        stale: false,
        cache_desde: desde,
        cache_hasta: hasta,
        updated_at: Time.now.iso8601,
        kpis: {
          total:                    total,
          confirmadas:              conf,
          probables:                prob,
          ok:                       k["ok"].to_i,
          tasa_evasion:             tasa_evas,
          comision_evadida_cop:     k["comision_evadida"].to_i,
          penalizacion_evadida_cop: k["penalizacion_evadida"].to_i,
          sin_gps:                  k["sin_gps"].to_i,
          tasa_comision_pct:        (tasa * 100).round,
          pais_filtro:              pais,
          moneda_filtro:            moneda,
          pilotos_auditados:        k["pilotos_auditados"].to_i,
          pilotos_evadieron:        k["pilotos_evadieron"].to_i,
        },
        operativo: {
          prom_minutos_evasion:   k["prom_minutos"].to_f,
          prom_distancia_evasion: k["prom_distancia"].to_f,
        },
        funnel: {
          total:          total,
          flag_tiempo:    k["flag_tiempo"].to_i,
          flag_distancia: k["flag_distancia"].to_i,
          confirmadas:    conf,
        },
        tendencia: t.map { |r|
          { fecha: r["fecha"].to_s[0,10], conf: r["conf"].to_i, prob: r["prob"].to_i, ok: r["ok"].to_i }
        },
        ciudades: c.map { |r|
          { ciudad: r["ciudad"], count: r["evasiones"].to_i }
        },
        top_drivers: d.map { |r|
          {
            id:           r["id_driver"],
            nombre:       (r["nombre"] && !r["nombre"].to_s.empty?) ? r["nombre"] : "Sin nombre",
            conf:         r["conf"].to_i,
            prob:         r["prob"].to_i,
            total:        r["total"].to_i,
            conf_primera: r["conf_primera"].to_i,
            conf_segunda: r["conf_segunda"].to_i,
          }
        },
      }

      render json: limpiar(payload)
    rescue => e
      Rails.logger.error("[ResumenController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message, type: e.class.name }, status: :internal_server_error
    end

    # POST /api/resumen/enviar_email — v3.3.21
    def enviar_email
      to_list  = BackgroundMailerHelper.parse_email_list(params[:email] || params[:to])
      cc_list  = BackgroundMailerHelper.parse_email_list(params[:cc])
      bcc_list = BackgroundMailerHelper.parse_email_list(params[:bcc])
      asunto   = params[:asunto].to_s.strip
      mensaje  = params[:mensaje].to_s.strip[0, 1000]
      desde    = desde_param
      hasta    = hasta_param
      pais     = pais_param
      iso      = iso_pais
      usuario  = current_usuario.to_s

      return render(json: { ok: false, error: "Tenés que ingresar al menos un destinatario en 'Para'." }, status: :bad_request) if to_list.empty?
      _v, invalids = BackgroundMailerHelper.split_validos(to_list + cc_list + bcc_list)
      return render(json: { ok: false, error: "Email(s) inválido(s): #{invalids.join(', ')}" }, status: :bad_request) if invalids.any?

      BackgroundMailerHelper.run("Evasion") do
        xlsx = Api::ExportarController.build_evasion_xlsx(desde, hasta, pais, iso, ch)
        filename = "Picap_Evasion_#{desde}_#{hasta}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.xlsx"
        ResendMailerService.send_email(
          to: to_list, cc: cc_list, bcc: bcc_list,
          subject: asunto.empty? ? "Reporte Evasión de Comisión · #{desde} → #{hasta}" : asunto,
          html: html_email_simple("📊 Evasión de Comisión", "linear-gradient(90deg,#1d4ed8,#1e3a8a)", "#1d4ed8", desde, hasta, pais, mensaje, usuario,
                                  "Te compartimos el reporte de evasión de comisión. El Excel adjunto contiene <strong>Resumen Ejecutivo</strong> + <strong>Detalle</strong> servicio por servicio."),
          attachment_bytes: xlsx[:data], attachment_filename: filename,
        )
      end

      render json: { ok: true, queued: true, destinatarios: to_list, cc: cc_list, bcc: bcc_list,
                     mensaje: "Reporte en proceso. El email llegará en unos minutos." }, status: :accepted
    rescue => e
      Rails.logger.error("[ResumenController#enviar_email] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    # v3.3.21: helper para HTML email común a todos los módulos sin botón propio.
    def html_email_simple(titulo, gradient, color_main, desde, hasta, pais, mensaje_usuario, usuario, descripcion)
      msj_html = mensaje_usuario.to_s.empty? ? "" :
        %Q(<p style="background:#FFFBEB;border-left:4px solid #F59E0B;padding:12px 16px;margin:16px 0;border-radius:4px;color:#78350F"><strong>Mensaje:</strong> #{ERB::Util.h(mensaje_usuario)}</p>)
      pais_txt = pais.to_s.empty? ? "Todos" : pais
      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#F9FAFB;color:#1F2937">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F9FAFB;padding:20px 0"><tr><td align="center">
            <table cellpadding="0" cellspacing="0" border="0" width="620" style="background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
              <tr><td style="background:#{gradient};padding:24px 28px;color:#fff">
                <div style="font-size:20px;font-weight:700">#{titulo}</div>
                <div style="font-size:12px;opacity:0.92;margin-top:4px">Período: #{desde} → #{hasta} · País: #{pais_txt}</div>
              </td></tr>
              <tr><td style="padding:28px">
                <p style="margin:0 0 16px;font-size:14px">Hola,</p>
                <p style="margin:0 0 16px;font-size:14px;line-height:1.5">#{descripcion}</p>
                #{msj_html}
                <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">📎 Excel adjunto. Detalle en vivo en <a href="https://monitoring.picap.io" style="color:#{color_main}">monitoring.picap.io</a>.</p>
              </td></tr>
              <tr><td style="background:#F9FAFB;padding:12px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                <strong style="color:#{color_main}">Picap Monitoreo</strong> · #{Time.now.strftime('%d/%m/%Y %H:%M')} · Por: #{ERB::Util.h(usuario)}
              </td></tr>
            </table>
          </td></tr></table>
        </body></html>
      HTML
    end
  end
end
