# app/controllers/api/dispersiones_controller.rb
# Dispersiones — transacciones WalletAccountDriverBalanceTransactionDaviplataCashOut
# (dispersiones de Picap hacia cuentas Daviplata de companies). Acceso restringido
# a roles: admin, monitoreo, financiero.
#
# Endpoints:
#   GET  /api/dispersiones              → lista + stats (filtros + paginación)
#   POST /api/dispersiones/enviar_email → enviar xlsx adjunto vía Resend

module Api
  class DispersionesController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol_dispersiones

    ROLES_PERMITIDOS = %w[admin monitoreo financiero].freeze

    # GET /api/dispersiones?desde=&hasta=&company=&tipo=
    def index
      desde   = desde_param
      hasta   = hasta_param
      company = params[:company].to_s.strip
      tipo    = params[:tipo].to_s.strip   # "Recaudo" | "Garantía" | ""

      rows = cargar_filas(desde: desde, hasta: hasta, company: company, tipo: tipo)

      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta,
        total: rows.size,
        stats: calcular_stats(rows),
        filas: rows.first(5_000),  # safety cap UI
      })
    rescue => e
      Rails.logger.error("[DispersionesController#index] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/dispersiones/enviar_email
    # Body: { email|to, cc?, bcc?, asunto?, mensaje?, desde, hasta, company?, tipo? }
    def enviar_email
      to_list  = parse_email_list(params[:email] || params[:to])
      cc_list  = parse_email_list(params[:cc])
      bcc_list = parse_email_list(params[:bcc])
      asunto   = params[:asunto].to_s.strip
      mensaje  = params[:mensaje].to_s.strip[0, 1000]
      desde    = desde_param
      hasta    = hasta_param
      company  = params[:company].to_s.strip
      tipo     = params[:tipo].to_s.strip

      if to_list.empty?
        return render(json: { ok: false, error: "Tenés que ingresar al menos un destinatario en 'Para'." }, status: :bad_request)
      end
      invalid = (to_list + cc_list + bcc_list).reject { |e| e.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) }
      if invalid.any?
        return render(json: { ok: false, error: "Email(s) inválido(s): #{invalid.join(', ')}" }, status: :bad_request)
      end

      # Reusa el builder centralizado del Excel (mismo archivo del export directo)
      xlsx = Api::ExportarController.build_dispersiones_xlsx(desde, hasta, ch,
                                                             company: company, tipo: tipo)
      filename = "Picap_Dispersiones_#{desde}_#{hasta}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.xlsx"

      rows = cargar_filas(desde: desde, hasta: hasta, company: company, tipo: tipo)
      subject_default = "Reporte Dispersiones · #{desde} → #{hasta} (#{rows.size} tx)"
      html = construir_html_email(desde, hasta, rows, mensaje, current_usuario)

      result = ResendMailerService.send_email(
        to:                  to_list,
        cc:                  cc_list,
        bcc:                 bcc_list,
        subject:             asunto.empty? ? subject_default : asunto,
        html:                html,
        attachment_bytes:    xlsx[:data],
        attachment_filename: filename,
      )

      render json: {
        ok: true,
        destinatarios: to_list,
        cc: cc_list,
        bcc: bcc_list,
        filename: filename,
        total: rows.size,
        resend_id: result[:id],
      }
    rescue ResendMailerService::ConfigError, ResendMailerService::AuthError => e
      Rails.logger.error("[DispersionesController#enviar_email] Resend: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    rescue ResendMailerService::ValidationError => e
      Rails.logger.error("[DispersionesController#enviar_email] Validation: #{e.message}")
      render json: { ok: false, error: e.message }, status: :bad_request
    rescue ResendMailerService::NetworkError => e
      Rails.logger.error("[DispersionesController#enviar_email] Network: #{e.message}")
      render json: { ok: false, error: e.message }, status: :bad_gateway
    rescue => e
      Rails.logger.error("[DispersionesController#enviar_email] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def parse_email_list(val)
      return [] if val.nil?
      raw = val.is_a?(Array) ? val.join(",") : val.to_s
      raw.split(/[,;\s\n]+/).map(&:strip).reject(&:empty?).uniq
    end

    def validar_rol_dispersiones
      return if ROLES_PERMITIDOS.include?(current_rol.to_s)
      render json: {
        ok: false,
        error: "Acceso restringido — solo roles: #{ROLES_PERMITIDOS.join(', ')}. Tu rol: #{current_rol || 'sin rol'}",
      }, status: :forbidden
    end

    # Carga rows de CH + aplica filtros de company/tipo en memoria (low volume).
    def cargar_filas(desde:, hasta:, company: "", tipo: "")
      sql = QueriesService.format(
        QueriesService::Q_DISPERSIONES,
        fecha_desde: desde, fecha_hasta: hasta,
      )
      rows = ch.query(sql, timeout: 300).map { |r| normalizar(r) }
      unless company.empty?
        c_low = company.downcase
        rows = rows.select { |r| r["company_name"].to_s.downcase.include?(c_low) }
      end
      unless tipo.empty?
        # 'Recaudo' o 'Garantía' (substring case-insensitive)
        t_low = tipo.downcase
        rows = rows.select { |r| r["tipo_dispersion"].to_s.downcase.include?(t_low) }
      end
      rows
    end

    def normalizar(r)
      {
        "id_tx"           => r["id_tx"].to_s,
        "fecha_tx"        => r["fecha_tx"].to_s,
        "valor"           => r["valor"].to_f.round(2),
        "tipo_tx"         => r["tipo_tx"].to_s,
        "company_id"      => r["company_id"].to_s,
        "company_name"    => r["company_name"].to_s,
        "tipo_dispersion" => r["tipo_dispersion"].to_s,
      }
    end

    # Stats globales + breakdown por company / tipo / día.
    # Convención: valores negativos = dispersión efectiva, positivos = reversión.
    def calcular_stats(rows)
      total = rows.size
      negativas = rows.select { |r| r["valor"].to_f < 0 }
      positivas = rows.select { |r| r["valor"].to_f > 0 }
      valor_total      = rows.sum { |r| r["valor"].to_f }
      valor_dispersado = negativas.sum { |r| r["valor"].to_f }.abs    # absoluto, monto que salió
      valor_revertido  = positivas.sum { |r| r["valor"].to_f }        # monto que regresó
      n_companies      = rows.map { |r| r["company_id"] }.uniq.size
      n_recaudo   = rows.count { |r| r["tipo_dispersion"] == "Dispersión Recaudo" }
      n_garantia  = rows.count { |r| r["tipo_dispersion"] == "Dispersión Garantía" }
      v_recaudo   = rows.select { |r| r["tipo_dispersion"] == "Dispersión Recaudo" }.sum { |r| r["valor"].to_f }
      v_garantia  = rows.select { |r| r["tipo_dispersion"] == "Dispersión Garantía" }.sum { |r| r["valor"].to_f }

      # Tendencia diaria
      por_dia = rows.group_by { |r| r["fecha_tx"] }
                    .map { |fecha, grupo| {
                      fecha: fecha,
                      cant:  grupo.size,
                      valor: grupo.sum { |g| g["valor"].to_f }.round(2),
                    } }
                    .sort_by { |h| h[:fecha] }

      # Top companies por VALOR DISPERSADO (absoluto, descendente).
      # Cada company puede tener Recaudo y Garantía — los separamos.
      top_companies = rows.group_by { |r| [r["company_name"], r["tipo_dispersion"]] }
                          .map { |(name, tipo), grupo| {
                            company:  name,
                            tipo:     tipo,
                            cant:     grupo.size,
                            valor:    grupo.sum { |g| g["valor"].to_f }.round(2),
                          } }
                          .sort_by { |h| h[:valor] }   # más negativo primero (más dispersado)
                          .first(20)

      {
        total:            total,
        n_companies:      n_companies,
        valor_total:      valor_total.round(2),
        valor_dispersado: valor_dispersado.round(2),
        valor_revertido:  valor_revertido.round(2),
        n_recaudo:        n_recaudo,
        n_garantia:       n_garantia,
        v_recaudo:        v_recaudo.round(2),
        v_garantia:       v_garantia.round(2),
        por_dia:          por_dia,
        top_companies:    top_companies,
      }
    end

    def construir_html_email(desde, hasta, rows, mensaje_usuario, usuario)
      fmt_num   = ->(n) { (n || 0).to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1.').reverse }
      fmt_money = ->(n) { "$ #{fmt_num.((n || 0).abs)}" }
      total       = rows.size
      valor_total = rows.sum { |r| r["valor"].to_f }
      valor_dispersado = rows.select { |r| r["valor"].to_f < 0 }.sum { |r| r["valor"].to_f }.abs
      n_companies = rows.map { |r| r["company_id"] }.uniq.size
      n_recaudo  = rows.count { |r| r["tipo_dispersion"] == "Dispersión Recaudo" }
      n_garantia = rows.count { |r| r["tipo_dispersion"] == "Dispersión Garantía" }
      msj_html = mensaje_usuario.empty? ? "" : %Q(<p style="background:#FFFBEB;border-left:4px solid #F59E0B;padding:12px 16px;margin:16px 0;border-radius:4px;color:#78350F"><strong>Mensaje:</strong> #{ERB::Util.h(mensaje_usuario)}</p>)

      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#F5F3FF;color:#1F2937;">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F5F3FF;padding:20px 0">
            <tr><td align="center">
              <table cellpadding="0" cellspacing="0" border="0" width="640" style="background:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
                <tr><td style="background:linear-gradient(90deg,#059669 0%,#10b981 100%);padding:24px 28px;color:#ffffff">
                  <div style="font-size:22px;font-weight:700;letter-spacing:-0.5px">💸 Reporte de Dispersiones</div>
                  <div style="font-size:13px;margin-top:6px;opacity:0.92">Período: #{desde} → #{hasta}</div>
                </td></tr>
                <tr><td style="padding:28px">
                  <p style="margin:0 0 12px;font-size:14px">Hola,</p>
                  <p style="margin:0 0 12px;font-size:14px;line-height:1.5">Te compartimos el reporte de dispersiones del período indicado. El detalle completo está en el archivo Excel adjunto con dos hojas: <strong>BD Dispersiones</strong> (raw) y <strong>TD Dispersiones</strong> (pivot por company × tipo).</p>
                  #{msj_html}
                  <h3 style="color:#059669;margin:24px 0 12px;font-size:15px">📈 Resumen ejecutivo</h3>
                  <table cellpadding="0" cellspacing="6" border="0" width="100%" style="margin:0 -6px">
                    <tr>
                      <td style="background:#DCFCE7;border-top:3px solid #059669;padding:12px;border-radius:6px;width:50%">
                        <div style="font-size:22px;font-weight:700;color:#1F2937">#{fmt_num.(total)}</div>
                        <div style="font-size:11px;color:#6B7280;margin-top:4px">Transacciones</div>
                      </td>
                      <td style="background:#FEE2E2;border-top:3px solid #DC2626;padding:12px;border-radius:6px;width:50%">
                        <div style="font-size:22px;font-weight:700;color:#991B1B">#{fmt_money.(valor_dispersado)}</div>
                        <div style="font-size:11px;color:#991B1B;margin-top:4px">Total dispersado</div>
                      </td>
                    </tr>
                    <tr>
                      <td style="background:#FAFAFA;border:1px solid #E5E7EB;padding:12px;border-radius:6px">
                        <div style="font-size:11px;color:#6B7280">Companies únicas</div>
                        <div style="font-size:18px;font-weight:700;color:#059669;margin-top:4px">#{fmt_num.(n_companies)}</div>
                      </td>
                      <td style="background:#FAFAFA;border:1px solid #E5E7EB;padding:12px;border-radius:6px">
                        <div style="font-size:11px;color:#6B7280">Recaudo · Garantía</div>
                        <div style="font-size:18px;font-weight:700;color:#059669;margin-top:4px">#{fmt_num.(n_recaudo)} · #{fmt_num.(n_garantia)}</div>
                      </td>
                    </tr>
                  </table>
                  <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">📎 <strong>Adjunto:</strong> archivo Excel (.xlsx) con 2 hojas: BD Dispersiones (todas las transacciones) y TD Dispersiones (pivot por company × tipo).</p>
                </td></tr>
                <tr><td style="background:#F9FAFB;padding:16px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                  Generado automáticamente · <strong style="color:#059669">Picap Monitoreo</strong> · #{Time.now.strftime('%d/%m/%Y %H:%M')}<br>
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
