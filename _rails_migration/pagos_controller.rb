# app/controllers/api/pagos_controller.rb
# Replica /api/pagos/{tc,promo} con clasificación GPS-based (api.py 3066-3302):
#   OK             → driver recibió pago wallet (pd.pagado > 0)
#   Mala práctica  → pagado=0 AND geoDistance(cancel → dest) ≤ radio país
#   Fraude         → pagado=0 AND (sin GPS OR geoDistance > radio)
# Radio: CO 450m | MX/NI 280m | resto 450m
#
# Shape EXACTO que el frontend espera:
#   kpis:     { total, ok, mala_practica, fraude, monto_mp, monto_fraude, monto_total }
#   trend:    [{ fecha, ok, mala_practica, fraude }]
#   ciudades: [{ ciudad, pais, total, mala_practica, fraude }]
#   duo:      [{ driver_id, passenger_id, servicios, monto_total, n_fraude, n_mp }]

module Api
  class PagosController < ApplicationController
    before_action :authenticate_user!

    # GET /api/pagos/tc?desde=&hasta=&pais=&ciudad=
    def tc
      render_pagos(:tc)
    end

    # GET /api/pagos/promo?desde=&hasta=&pais=&ciudad=
    def promo
      render_pagos(:promo)
    end

    # GET /api/pagos_stats?desde=&hasta=
    def stats
      sql = QueriesService.format(
        QueriesService::Q_PAGOS_STATS,
        desde: desde_param, hasta: hasta_param
      )
      rows = ch.query(sql)
      total  = rows.sum { |r| r["total_servicios"].to_i }
      monto  = rows.sum { |r| r["monto_total_cop"].to_f }
      render json: limpiar({
        ok: true,
        desde: desde_param, hasta: hasta_param,
        resumen: { total: total, monto: monto },
        por_pais_medio: rows,
      })
    rescue => e
      Rails.logger.error("[PagosController#stats] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def render_pagos(tipo)
      desde    = desde_param
      hasta    = hasta_param
      pais_iso = iso_pais
      ciudad   = params[:ciudad].to_s.strip
      filtro   = QueriesService.pagos_filtro(pais_iso, ciudad)

      queries = if tipo == :tc
        {
          kpis:     QueriesService::Q_TC_KPIS,
          trend:    QueriesService::Q_TC_TREND,
          ciudades: QueriesService::Q_TC_CIUDADES,
          duo:      QueriesService::Q_TC_DUO,
        }
      else
        {
          kpis:     QueriesService::Q_PROMO_KPIS,
          trend:    QueriesService::Q_PROMO_TREND,
          ciudades: QueriesService::Q_PROMO_CIUDADES,
          duo:      QueriesService::Q_PROMO_DUO,
        }
      end

      # Ejecuta cada query con rescue aislado — si una rompe, el panel sigue
      data = {}
      queries.each do |key, sql_tpl|
        begin
          sql = QueriesService.format(sql_tpl, desde: desde, hasta: hasta, filtro: filtro)
          data[key] = ch.query(sql)
        rescue => e
          Rails.logger.warn("[PagosController##{tipo}/#{key}] #{e.message[0,200]}")
          data[key] = []
        end
      end

      kpi_row = data[:kpis].first || {}

      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta,
        pais_filtro: pais_param,
        kpis: {
          total:         kpi_row["total"].to_i,
          ok:            kpi_row["ok"].to_i,
          mala_practica: kpi_row["mala_practica"].to_i,
          fraude:        kpi_row["fraude"].to_i,
          monto_mp:      kpi_row["monto_mp"].to_f,
          monto_fraude:  kpi_row["monto_fraude"].to_f,
          monto_total:   kpi_row["monto_total"].to_f,
        },
        trend: data[:trend].map { |r|
          { fecha:         r["fecha"].to_s[0, 10],
            ok:            r["ok"].to_i,
            mala_practica: r["mala_practica"].to_i,
            fraude:        r["fraude"].to_i }
        },
        ciudades: data[:ciudades].map { |r|
          { ciudad:        r["ciudad"].to_s,
            pais:          r["pais"].to_s,
            total:         r["total"].to_i,
            mala_practica: r["mala_practica"].to_i,
            fraude:        r["fraude"].to_i }
        },
        duo: data[:duo].map { |r|
          { driver_id:    r["driver_id"].to_s,
            passenger_id: r["passenger_id"].to_s,
            servicios:    r["servicios"].to_i,
            monto_total:  r["monto_total"].to_f,
            n_fraude:     r["n_fraude"].to_i,
            n_mp:         r["n_mp"].to_i }
        },
      })
    rescue => e
      Rails.logger.error("[PagosController##{tipo}] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message, type: e.class.name },
             status: :internal_server_error
    end

    # POST /api/pagos/enviar_email — v3.3.21
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
      ciudad   = params[:ciudad].to_s.strip
      tipo     = params[:tipo].to_s == "promo" ? "promo" : "tc"
      usuario  = current_usuario.to_s

      return render(json: { ok: false, error: "Tenés que ingresar al menos un destinatario en 'Para'." }, status: :bad_request) if to_list.empty?
      _v, invalids = BackgroundMailerHelper.split_validos(to_list + cc_list + bcc_list)
      return render(json: { ok: false, error: "Email(s) inválido(s): #{invalids.join(', ')}" }, status: :bad_request) if invalids.any?

      BackgroundMailerHelper.run("Pagos") do
        xlsx = Api::ExportarController.build_pagos_xlsx(desde, hasta, iso, ciudad, tipo, ch)
        label = tipo == "promo" ? "PromoCode" : "Tarjeta Crédito"
        filename = "Picap_Pagos_#{tipo}_#{desde}_#{hasta}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.xlsx"
        ResendMailerService.send_email(
          to: to_list, cc: cc_list, bcc: bcc_list,
          subject: asunto.empty? ? "Reporte Pagos #{label} · #{desde} → #{hasta}" : asunto,
          html: html_email_pagos(label, desde, hasta, pais, mensaje, usuario),
          attachment_bytes: xlsx[:data], attachment_filename: filename,
        )
      end

      render json: { ok: true, queued: true, destinatarios: to_list, cc: cc_list, bcc: bcc_list,
                     mensaje: "Reporte en proceso. El email llegará en unos minutos." }, status: :accepted
    rescue => e
      Rails.logger.error("[PagosController#enviar_email] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def html_email_pagos(label, desde, hasta, pais, mensaje_usuario, usuario)
      msj_html = mensaje_usuario.to_s.empty? ? "" :
        %Q(<p style="background:#FFFBEB;border-left:4px solid #F59E0B;padding:12px 16px;margin:16px 0;border-radius:4px;color:#78350F"><strong>Mensaje:</strong> #{ERB::Util.h(mensaje_usuario)}</p>)
      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#EFF6FF;color:#1F2937">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#EFF6FF;padding:20px 0"><tr><td align="center">
            <table cellpadding="0" cellspacing="0" border="0" width="620" style="background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
              <tr><td style="background:linear-gradient(90deg,#1d4ed8,#1e3a8a);padding:24px 28px;color:#fff">
                <div style="font-size:20px;font-weight:700">💳 Reporte Pagos #{label}</div>
                <div style="font-size:12px;opacity:0.92;margin-top:4px">Período: #{desde} → #{hasta} · País: #{pais.to_s.empty? ? 'Todos' : pais}</div>
              </td></tr>
              <tr><td style="padding:28px">
                <p style="margin:0 0 16px;font-size:14px">Hola,</p>
                <p style="margin:0 0 16px;font-size:14px;line-height:1.5">Te compartimos el reporte de pagos #{label}. El Excel adjunto contiene 4 hojas: <strong>Resumen</strong>, <strong>Tendencia diaria</strong>, <strong>Top Ciudades</strong> y <strong>Pares Driver+Pasajero</strong> sospechosos.</p>
                #{msj_html}
                <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">📎 Excel adjunto. Análisis en vivo en <a href="https://monitoring.picap.io" style="color:#1d4ed8">monitoring.picap.io</a> → Pagos.</p>
              </td></tr>
              <tr><td style="background:#F9FAFB;padding:12px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                <strong style="color:#1d4ed8">Picap Monitoreo</strong> · #{Time.now.strftime('%d/%m/%Y %H:%M')} · Por: #{ERB::Util.h(usuario)}
              </td></tr>
            </table>
          </td></tr></table>
        </body></html>
      HTML
    end
  end
end
