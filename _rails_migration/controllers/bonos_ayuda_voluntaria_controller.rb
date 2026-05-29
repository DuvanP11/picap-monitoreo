# app/controllers/api/bonos_ayuda_voluntaria_controller.rb
# v3.3.23 — Bonos de Ayuda Voluntaria.
# Reporta transacciones tipo WalletAccountTransactionBookingHelpBonus
# divididas en 2 sub-conjuntos:
#   • Masivo:      wallet_accounts.company_id vacío. wallet_type derivado de
#                  description: 'masivo pibox' o 'masivo picap'.
#   • Corporativo: wallet_accounts.company_id no vacío. wallet_type = 'corporativo pibox'.
#
# Cada fila incluye un flag `coherente` que detecta inconsistencias:
#   - Coherente si (company_id vacío AND wallet_type comienza con 'masivo')
#                  OR (company_id no vacío AND wallet_type = 'corporativo pibox').
#   - Inconsistente cualquier otra combinación → alerta.
#
# Endpoints:
#   GET  /api/bonos_ayuda                   → lista (2 tablas) + stats
#   POST /api/bonos_ayuda/enviar_email      → xlsx 2 hojas vía Resend (background)

module Api
  class BonosAyudaVoluntariaController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol_bonos

    ROLES_PERMITIDOS = %w[admin monitoreo financiero].freeze
    LIMIT_UI = 5_000

    # GET /api/bonos_ayuda?desde=&hasta=&wallet_type=&pais=&q=
    def index
      desde       = desde_param
      hasta       = hasta_param
      wallet_type = params[:wallet_type].to_s.strip
      pais        = params[:pais].to_s.strip.upcase
      q_search    = params[:q].to_s.strip

      rows = cargar_filas(desde: desde, hasta: hasta,
                          wallet_type: wallet_type, pais: pais, q: q_search)

      # Particionar en 2 tablas
      filas_masivo      = rows.select { |r| r["company_id"].to_s.strip.empty? }
      filas_corporativo = rows.select { |r| !r["company_id"].to_s.strip.empty? }

      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta,
        total: rows.size,
        masivo_count:      filas_masivo.size,
        corporativo_count: filas_corporativo.size,
        stats: calcular_stats(rows),
        filas_masivo:      filas_masivo.first(LIMIT_UI),
        filas_corporativo: filas_corporativo.first(LIMIT_UI),
      })
    rescue => e
      Rails.logger.error("[BonosAyudaVoluntariaController#index] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/bonos_ayuda/enviar_email
    def enviar_email
      to_list  = BackgroundMailerHelper.parse_email_list(params[:email] || params[:to])
      cc_list  = BackgroundMailerHelper.parse_email_list(params[:cc])
      bcc_list = BackgroundMailerHelper.parse_email_list(params[:bcc])
      asunto   = params[:asunto].to_s.strip
      mensaje  = params[:mensaje].to_s.strip[0, 1000]
      desde    = desde_param
      hasta    = hasta_param
      wallet_type = params[:wallet_type].to_s.strip
      pais        = params[:pais].to_s.strip.upcase
      q_search    = params[:q].to_s.strip
      usuario     = current_usuario.to_s

      if to_list.empty?
        return render(json: { ok: false, error: "Tenés que ingresar al menos un destinatario en 'Para'." }, status: :bad_request)
      end
      _v, invalids = BackgroundMailerHelper.split_validos(to_list + cc_list + bcc_list)
      if invalids.any?
        return render(json: { ok: false, error: "Email(s) inválido(s): #{invalids.join(', ')}" }, status: :bad_request)
      end

      BackgroundMailerHelper.run("BonosAyuda") do
        rows = cargar_filas(desde: desde, hasta: hasta,
                            wallet_type: wallet_type, pais: pais, q: q_search)
        xlsx = Api::ExportarController.build_bonos_ayuda_xlsx(
          desde, hasta, ch,
          wallet_type: wallet_type, pais: pais, q: q_search,
          preloaded_rows: rows,
        )
        filename = "Picap_Bonos_Ayuda_Voluntaria_#{desde}_#{hasta}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.xlsx"
        subject_default = "Bonos de Ayuda Voluntaria · #{desde} → #{hasta} (#{rows.size} tx)"
        html = construir_html_email(desde, hasta, rows, mensaje, usuario)
        ResendMailerService.send_email(
          to: to_list, cc: cc_list, bcc: bcc_list,
          subject: asunto.empty? ? subject_default : asunto,
          html: html,
          attachment_bytes: xlsx[:data],
          attachment_filename: filename,
        )
      end

      render json: {
        ok: true, queued: true,
        destinatarios: to_list, cc: cc_list, bcc: bcc_list,
        mensaje: "Reporte en proceso. El email con el Excel adjunto llegará en unos minutos.",
      }, status: :accepted
    rescue => e
      Rails.logger.error("[BonosAyudaVoluntariaController#enviar_email] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def validar_rol_bonos
      return if ROLES_PERMITIDOS.include?(current_rol.to_s)
      render json: {
        ok: false,
        error: "Acceso restringido — solo roles: #{ROLES_PERMITIDOS.join(', ')}. Tu rol: #{current_rol || 'sin rol'}",
      }, status: :forbidden
    end

    def cargar_filas(desde:, hasta:, wallet_type: "", pais: "", q: "")
      sql = QueriesService.format(
        QueriesService::Q_BONOS_AYUDA_VOLUNTARIA,
        fecha_desde: desde, fecha_hasta: hasta,
      )
      rows = ch.query(sql, timeout: 300).map { |r| normalizar(r) }

      # Filtros opcionales en memoria
      unless wallet_type.empty?
        rows = rows.select { |r| r["wallet_type"] == wallet_type }
      end
      unless pais.empty?
        rows = rows.select { |r| r["pais"].to_s.upcase == pais }
      end
      unless q.empty?
        q_low = q.downcase
        rows = rows.select { |r|
          r["id_passenger"].to_s.downcase.include?(q_low) ||
          r["company_id"].to_s.downcase.include?(q_low) ||
          r["company_name"].to_s.downcase.include?(q_low) ||
          r["id_transaccion"].to_s.downcase.include?(q_low)
        }
      end
      rows
    end

    def normalizar(r)
      company_id   = r["company_id"].to_s.strip
      wallet_type  = r["wallet_type"].to_s
      tiene_company = !company_id.empty?
      es_corporativo = wallet_type == "corporativo pibox"
      # Coherente si (sin company AND no es corporativo) o (con company AND es corporativo).
      coherente = (tiene_company && es_corporativo) || (!tiene_company && !es_corporativo)
      {
        "id_transaccion"     => r["id_transaccion"].to_s,
        "id_passenger"       => r["id_passenger"].to_s,
        "fecha"              => r["fecha"].to_s,
        "company_id"         => company_id,
        "company_name"       => r["company_name"].to_s,
        "type_cd"            => r["type_cd"].to_s,
        "tipo_tx"            => r["tipo_tx"].to_s,
        "monto_cop"          => r["monto_cop"].to_f.round(2),
        "descripcion"        => r["descripcion"].to_s,
        "wallet_type"        => wallet_type,
        "daviplata_response" => r["daviplata_response"].to_s,
        "pais"               => r["pais"].to_s,
        "from_trump"         => r["from_trump"].to_s,
        "reverted_to_id"     => r["reverted_to_id"].to_s,
        "custom_message"     => r["custom_message"].to_s,
        "coherente"          => coherente,
      }
    end

    def calcular_stats(rows)
      total     = rows.size
      monto_tot = rows.sum { |r| r["monto_cop"].to_f }
      inconsist = rows.count { |r| !r["coherente"] }

      # Breakdown por wallet_type
      por_wallet_type = rows.group_by { |r| r["wallet_type"] }
                            .map { |k, g| {
                              wallet_type: k,
                              cant: g.size,
                              monto: g.sum { |r| r["monto_cop"].to_f }.round(2),
                            } }
                            .sort_by { |h| -h[:cant] }

      # Top 3 empresas (solo corporativo)
      top_empresas = rows.reject { |r| r["company_id"].to_s.strip.empty? }
                         .group_by { |r| r["company_name"].to_s.empty? ? "(sin nombre)" : r["company_name"] }
                         .map { |k, g| { company: k, cant: g.size, monto: g.sum { |r| r["monto_cop"].to_f }.round(2) } }
                         .sort_by { |h| -h[:cant] }
                         .first(3)

      # Top 3 países (solo masivo, ya que corporativo no tiene país)
      top_paises = rows.reject { |r| r["pais"].to_s.empty? }
                       .group_by { |r| r["pais"] }
                       .map { |k, g| { pais: k, cant: g.size, monto: g.sum { |r| r["monto_cop"].to_f }.round(2) } }
                       .sort_by { |h| -h[:cant] }
                       .first(3)

      {
        total:              total,
        monto_total:        monto_tot.round(2),
        inconsistentes:     inconsist,
        por_wallet_type:    por_wallet_type,
        top_empresas:       top_empresas,
        top_paises:         top_paises,
      }
    end

    def construir_html_email(desde, hasta, rows, mensaje_usuario, usuario)
      fmt_num   = ->(n) { (n || 0).to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1.').reverse }
      fmt_money = ->(n) { "$ #{fmt_num.((n || 0).abs)}" }
      total       = rows.size
      monto_total = rows.sum { |r| r["monto_cop"].to_f }
      n_masivo_pibox    = rows.count { |r| r["wallet_type"] == "masivo pibox" }
      n_masivo_picap    = rows.count { |r| r["wallet_type"] == "masivo picap" }
      n_corporativo     = rows.count { |r| r["wallet_type"] == "corporativo pibox" }
      n_inconsistentes  = rows.count { |r| !r["coherente"] }
      msj_html = mensaje_usuario.empty? ? "" :
        %Q(<p style="background:#FFFBEB;border-left:4px solid #F59E0B;padding:12px 16px;margin:16px 0;border-radius:4px;color:#78350F"><strong>Mensaje:</strong> #{ERB::Util.h(mensaje_usuario)}</p>)

      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#F0FDF4;color:#1F2937;">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F0FDF4;padding:20px 0">
            <tr><td align="center">
              <table cellpadding="0" cellspacing="0" border="0" width="640" style="background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
                <tr><td style="background:linear-gradient(90deg,#059669 0%,#047857 100%);padding:24px 28px;color:#fff">
                  <div style="font-size:22px;font-weight:700;letter-spacing:-0.5px">🤝 Bonos de Ayuda Voluntaria</div>
                  <div style="font-size:13px;margin-top:6px;opacity:0.92">Período: #{desde} → #{hasta}</div>
                </td></tr>
                <tr><td style="padding:28px">
                  <p style="margin:0 0 12px;font-size:14px">Hola,</p>
                  <p style="margin:0 0 12px;font-size:14px;line-height:1.5">Reporte de bonos de ayuda voluntaria entre pasajeros. El Excel adjunto trae <strong>2 hojas</strong>: <em>Masivo</em> + <em>Corporativo</em>, con flag de coherencia (alerta si company_id y wallet_type están mal alineados).</p>
                  #{msj_html}
                  <h3 style="color:#047857;margin:24px 0 12px;font-size:15px">📈 Resumen ejecutivo</h3>
                  <table cellpadding="0" cellspacing="6" border="0" width="100%" style="margin:0 -6px">
                    <tr>
                      <td style="background:#DCFCE7;border-top:3px solid #059669;padding:12px;border-radius:6px;width:50%">
                        <div style="font-size:22px;font-weight:700;color:#1F2937">#{fmt_num.(total)}</div>
                        <div style="font-size:11px;color:#166534;margin-top:4px">Transacciones totales</div>
                      </td>
                      <td style="background:#F0FDF4;border-top:3px solid #059669;padding:12px;border-radius:6px;width:50%">
                        <div style="font-size:22px;font-weight:700;color:#047857">#{fmt_money.(monto_total)}</div>
                        <div style="font-size:11px;color:#166534;margin-top:4px">Monto total COP</div>
                      </td>
                    </tr>
                    <tr>
                      <td style="background:#FAFAFA;border:1px solid #E5E7EB;padding:10px;border-radius:6px">
                        <div style="font-size:11px;color:#6B7280">🟢 Masivo Pibox · 🟣 Masivo Picap · 🟠 Corporativo</div>
                        <div style="font-size:14px;font-weight:700;color:#1F2937;margin-top:4px">#{fmt_num.(n_masivo_pibox)} · #{fmt_num.(n_masivo_picap)} · #{fmt_num.(n_corporativo)}</div>
                      </td>
                      <td style="background:#{n_inconsistentes > 0 ? 'FEE2E2' : 'F0FDF4'};border:1px solid #{n_inconsistentes > 0 ? 'FCA5A5' : '86EFAC'};padding:10px;border-radius:6px">
                        <div style="font-size:11px;color:#{n_inconsistentes > 0 ? '991B1B' : '166534'}">#{n_inconsistentes > 0 ? '⚠️ Inconsistentes' : '✓ Todas coherentes'}</div>
                        <div style="font-size:14px;font-weight:700;color:#{n_inconsistentes > 0 ? '991B1B' : '166534'};margin-top:4px">#{fmt_num.(n_inconsistentes)}</div>
                      </td>
                    </tr>
                  </table>
                  <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">📎 Excel adjunto con detalle por transacción. Detalle interactivo en <a href="https://monitoring.picap.io" style="color:#047857">monitoring.picap.io</a> → Informes → Bonos Ayuda.</p>
                </td></tr>
                <tr><td style="background:#F9FAFB;padding:16px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                  Generado automáticamente · <strong style="color:#047857">Picap Monitoreo</strong> · #{Time.now.strftime('%d/%m/%Y %H:%M')}<br>
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
