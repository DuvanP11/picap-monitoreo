# app/controllers/api/cedula_alertas_controller.rb
# Replica /api/cedula-alertas (api.py 2880-2956).
# Compara cédula de OCR (rekognition_metadata.fiscal_number) vs cédula del
# reporte de antecedentes (extract pwd.people_police_records). Si difieren,
# alerta — la persona registró documento ajeno.

module Api
  class CedulaAlertasController < ApplicationController
    before_action :authenticate_user!

    LIMIT_DETALLE = 5000

    PAIS_ISO = {
      "Colombia" => "CO", "Mexico" => "MX", "México" => "MX",
      "Nicaragua" => "NI", "Guatemala" => "GT",
      "Peru" => "PE", "Perú" => "PE", "Ecuador" => "EC",
    }.freeze
    PAIS_NOMBRE = {
      "CO" => "Colombia", "MX" => "México", "NI" => "Nicaragua",
      "GT" => "Guatemala", "PE" => "Perú", "EC" => "Ecuador",
    }.freeze

    # GET /api/cedula-alertas?desde=&hasta=&pais=
    def index
      desde = desde_param
      hasta = hasta_param
      pais  = pais_param
      iso   = PAIS_ISO[pais] || pais.to_s.upcase
      filtro_pais = iso.to_s.empty? ? "" : "AND p.g_country = '#{iso}'"

      # 1) Agregación: totales reales por día (sin LIMIT)
      sql_agg = QueriesService.format(
        QueriesService::Q_CEDULA_AGG,
        desde: desde, hasta: hasta, filtro_pais: filtro_pais
      )
      agg_rows = ch.query(sql_agg)
      total_real   = agg_rows.sum { |r| r["total_dia"].to_i }
      alertas_real = agg_rows.sum { |r| r["alertas_dia"].to_i }
      ok_real      = total_real - alertas_real

      trend = agg_rows.map do |r|
        td = r["total_dia"].to_i
        ad = r["alertas_dia"].to_i
        { fecha: r["dia"].to_s, alertas: ad, ok: td - ad }
      end

      # 2) Sample detallado (hasta LIMIT_DETALLE filas)
      sql_det = QueriesService.format(
        QueriesService::Q_CEDULA_DETALLE,
        desde: desde, hasta: hasta, filtro_pais: filtro_pais,
        limit_filas: LIMIT_DETALLE
      )
      rows = ch.query(sql_det).map do |r|
        fc = r["creacion_cuenta"].to_s
        r["creacion_cuenta"] = fc[0, 19]
        r["pais_nombre"] = PAIS_NOMBRE[r["pais_codigo"].to_s] || r["pais_codigo"].to_s
        r
      end

      muestra_truncada = total_real > rows.size

      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta, pais: pais,
        resumen: {
          total:            total_real,
          alertas:          alertas_real,
          ok:               ok_real,
          pct_alertas:      total_real > 0 ? (alertas_real.to_f / total_real * 100).round(1) : 0,
          pct_ok:           total_real > 0 ? (ok_real.to_f      / total_real * 100).round(1) : 0,
          muestra_size:     rows.size,
          muestra_truncada: muestra_truncada,
        },
        trend:   trend,
        alertas: rows,
      })
    rescue => e
      Rails.logger.error("[CedulaAlertasController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/cedula-alertas/exportar?desde=&hasta=&pais=
    # Puerto del Python api.py:2959-3063 (cedula_alertas_exportar).
    def exportar
      desde = desde_param
      hasta = hasta_param
      pais  = pais_param
      iso   = PAIS_ISO[pais] || pais.to_s.upcase
      send_xlsx(self.class.build_cedula_xlsx(desde, hasta, pais, iso, ch))
    rescue => e
      Rails.logger.error("[CedulaAlertasController#exportar] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # v3.3.20: builder reutilizable desde enviar_email.
    def self.build_cedula_xlsx(desde, hasta, pais, iso, ch)
      filtro_pais = iso.to_s.empty? ? "" : "AND p.g_country = '#{iso}'"
      sql = QueriesService.format(
        QueriesService::Q_CEDULA_DETALLE,
        desde: desde, hasta: hasta, filtro_pais: filtro_pais, limit_filas: 20_000,
      )
      rows = ch.query(sql, timeout: 300)
      titulo_sub    = "#{desde} → #{hasta}  ·  #{pais.to_s.empty? ? 'Todos los países' : pais}"
      filename_base = "alerta_cedula_#{desde}_#{hasta}"

      ExcelExportService.build(filename_base) do |x|
        x.add_sheet("Alertas Cédula") do |s|
          s.banner("Alertas de Cédula", titulo_sub, 8)
          s.headers([
            "Creación cuenta", "ID Usuario", "Nombre", "País",
            "CC Rekognition", "CC Antecedentes", "Nombre antecedentes", "Resultado",
          ])
          wb = s.ws.workbook
          style_alerta = wb.styles.add_style(
            b: true, sz: 10, fg_color: "991B1B", bg_color: "FEE2E2",
            alignment: { horizontal: :center, vertical: :center },
            border:    { style: :thin, color: "EEEEEE" },
          )
          style_ok = wb.styles.add_style(
            b: true, sz: 10, fg_color: "166534", bg_color: "DCFCE7",
            alignment: { horizontal: :center, vertical: :center },
            border:    { style: :thin, color: "EEEEEE" },
          )
          rows.each do |r|
            cc_igual    = r["cc_igual"].to_s
            pais_nombre = PAIS_NOMBRE[r["pais_codigo"].to_s] || r["pais_codigo"].to_s
            s.data_row(
              [
                r["creacion_cuenta"].to_s[0, 19],
                r["id_user"].to_s,
                r["name_user"].to_s,
                pais_nombre,
                r["rekognition_cc"].to_s,
                r["cc_antecedentes"].to_s,
                r["nombre_antecedentes"].to_s,
                cc_igual.upcase,
              ],
              cell_styles: { 8 => (cc_igual == "alerta" ? style_alerta : style_ok) },
            )
          end
          s.finalize(freeze_row: 4)
        end
      end
    end

    # POST /api/cedula-alertas/enviar_email
    # v3.3.20: envía el xlsx de Alertas Cédula vía Resend en background.
    def enviar_email
      to_list  = BackgroundMailerHelper.parse_email_list(params[:email] || params[:to])
      cc_list  = BackgroundMailerHelper.parse_email_list(params[:cc])
      bcc_list = BackgroundMailerHelper.parse_email_list(params[:bcc])
      asunto   = params[:asunto].to_s.strip
      mensaje  = params[:mensaje].to_s.strip[0, 1000]
      desde    = desde_param
      hasta    = hasta_param
      pais     = pais_param
      iso      = PAIS_ISO[pais] || pais.to_s.upcase
      usuario  = current_usuario.to_s

      if to_list.empty?
        return render(json: { ok: false, error: "Tenés que ingresar al menos un destinatario en 'Para'." }, status: :bad_request)
      end
      _vals, invalids = BackgroundMailerHelper.split_validos(to_list + cc_list + bcc_list)
      if invalids.any?
        return render(json: { ok: false, error: "Email(s) inválido(s): #{invalids.join(', ')}" }, status: :bad_request)
      end

      BackgroundMailerHelper.run("CedulaAlertas") do
        xlsx = self.class.build_cedula_xlsx(desde, hasta, pais, iso, ch)
        filename = "Picap_AlertaCedula_#{desde}_#{hasta}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.xlsx"
        subject_default = "Reporte Alertas de Cédula · #{desde} → #{hasta}"
        html = construir_html_email_cedula(desde, hasta, pais, mensaje, usuario)
        ResendMailerService.send_email(
          to: to_list, cc: cc_list, bcc: bcc_list,
          subject: asunto.empty? ? subject_default : asunto,
          html: html,
          attachment_bytes: xlsx[:data],
          attachment_filename: filename,
        )
      end

      render json: {
        ok: true,
        queued: true,
        destinatarios: to_list,
        cc: cc_list,
        bcc: bcc_list,
        mensaje: "Reporte en proceso. El email con el Excel adjunto llegará en unos minutos.",
      }, status: :accepted
    rescue => e
      Rails.logger.error("[CedulaAlertasController#enviar_email] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def construir_html_email_cedula(desde, hasta, pais, mensaje_usuario, usuario)
      msj_html = mensaje_usuario.to_s.empty? ? "" :
        %Q(<p style="background:#FFFBEB;border-left:4px solid #F59E0B;padding:12px 16px;margin:16px 0;border-radius:4px;color:#78350F"><strong>Mensaje:</strong> #{ERB::Util.h(mensaje_usuario)}</p>)
      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#FEFCE8;color:#1F2937">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#FEFCE8;padding:20px 0">
            <tr><td align="center">
              <table cellpadding="0" cellspacing="0" border="0" width="620" style="background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
                <tr><td style="background:linear-gradient(90deg,#ca8a04 0%,#854d0e 100%);padding:24px 28px;color:#fff">
                  <div style="font-size:20px;font-weight:700">🪪 Alertas de Cédula</div>
                  <div style="font-size:12px;opacity:0.92;margin-top:4px">Período: #{desde} → #{hasta} · País: #{pais.to_s.empty? ? 'Todos' : pais}</div>
                </td></tr>
                <tr><td style="padding:28px">
                  <p style="margin:0 0 16px;font-size:14px">Hola,</p>
                  <p style="margin:0 0 16px;font-size:14px;line-height:1.5">Te compartimos el reporte de validación documental: compara la cédula extraída por OCR contra la cédula del reporte de antecedentes. Las filas con <strong>ALERTA</strong> indican posible suplantación.</p>
                  #{msj_html}
                  <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">📎 Excel adjunto con la lista completa (semaforizado por resultado). Detalle en <a href="https://monitoring.picap.io" style="color:#ca8a04">monitoring.picap.io</a> → Alerta Cédula.</p>
                </td></tr>
                <tr><td style="background:#F9FAFB;padding:12px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                  Generado por <strong style="color:#ca8a04">Picap Monitoreo</strong> · #{Time.now.strftime('%d/%m/%Y %H:%M')} · Por: #{ERB::Util.h(usuario)}
                </td></tr>
              </table>
            </td></tr>
          </table>
        </body></html>
      HTML
    end

    private

    def send_xlsx(xlsx)
      send_data xlsx[:data], type: xlsx[:mimetype],
                filename: xlsx[:filename], disposition: "attachment"
    end
  end
end
