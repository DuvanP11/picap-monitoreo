# app/controllers/api/moviired_controller.rb
# MoviiRed — transacciones WalletAccountTransactionPinPurchase (recargas en
# puntos físicos vía Incomm/MoviiRed). Acceso restringido a roles:
# admin, monitoreo, financiero.
#
# Endpoints:
#   GET  /api/moviired                  → lista + stats (filtros + paginación)
#   POST /api/moviired/enviar_email     → enviar CSV adjunto vía Resend

require "csv"

module Api
  class MoviiredController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol_moviired

    # Roles autorizados a ver/exportar/enviar MoviiRed.
    ROLES_PERMITIDOS = %w[admin monitoreo financiero].freeze

    # GET /api/moviired
    # Params: desde, hasta, ref (búsqueda parcial NUMERO_REFERENCIA), user (búsqueda parcial passenger_id)
    def index
      desde = desde_param
      hasta = hasta_param
      ref   = params[:ref].to_s.strip
      user  = params[:user].to_s.strip

      rows = cargar_filas(desde: desde, hasta: hasta, ref: ref, user: user)

      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta,
        total: rows.size,
        stats: calcular_stats(rows),
        filas: rows.first(5_000),  # safety cap UI
      })
    rescue => e
      Rails.logger.error("[MoviiredController#index] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/moviired/enviar_email
    # Body: { email, asunto?, mensaje?, desde, hasta, ref?, user? }
    def enviar_email
      destinatario = params[:email].to_s.strip
      asunto       = params[:asunto].to_s.strip
      mensaje      = params[:mensaje].to_s.strip[0, 1000]
      desde        = desde_param
      hasta        = hasta_param
      ref          = params[:ref].to_s.strip
      user         = params[:user].to_s.strip

      unless destinatario.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
        return render(json: { ok: false, error: "Email destinatario inválido" }, status: :bad_request)
      end

      rows = cargar_filas(desde: desde, hasta: hasta, ref: ref, user: user)
      csv_bytes = construir_csv(rows)
      filename  = "Picap_MoviiRed_#{desde}_#{hasta}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.csv"

      subject_default = "Reporte MoviiRed · #{desde} → #{hasta} (#{rows.size} tx)"
      html = construir_html_email(desde, hasta, rows, mensaje, current_usuario)

      result = ResendMailerService.send_email(
        to:                  destinatario,
        subject:             asunto.empty? ? subject_default : asunto,
        html:                html,
        attachment_bytes:    csv_bytes,
        attachment_filename: filename,
      )

      render json: {
        ok: true,
        destinatario: destinatario,
        filename: filename,
        total: rows.size,
        resend_id: result[:id],
      }
    rescue ResendMailerService::ConfigError, ResendMailerService::AuthError => e
      Rails.logger.error("[MoviiredController#enviar_email] Resend: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    rescue ResendMailerService::ValidationError => e
      Rails.logger.error("[MoviiredController#enviar_email] Resend validation: #{e.message}")
      render json: { ok: false, error: e.message }, status: :bad_request
    rescue ResendMailerService::NetworkError => e
      Rails.logger.error("[MoviiredController#enviar_email] Resend network: #{e.message}")
      render json: { ok: false, error: e.message }, status: :bad_gateway
    rescue => e
      Rails.logger.error("[MoviiredController#enviar_email] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def validar_rol_moviired
      return if ROLES_PERMITIDOS.include?(current_rol.to_s)
      render json: {
        ok: false,
        error: "Acceso restringido — solo roles: #{ROLES_PERMITIDOS.join(', ')}. Tu rol: #{current_rol || 'sin rol'}",
      }, status: :forbidden
    end

    def cargar_filas(desde:, hasta:, ref:, user:)
      esc = ->(v) { v.to_s.gsub("'", "''") }
      filtro_ref  = ref.length  >= 3 ? "AND e.id_tx ILIKE '%#{esc.(ref)}%'"      : ""
      filtro_user = user.length >= 3 ? "AND e.id_user ILIKE '%#{esc.(user)}%'"   : ""

      sql = QueriesService.format(
        QueriesService::Q_MOVIIRED,
        desde: desde, hasta: hasta,
        filtro_ref: filtro_ref,
        filtro_user: filtro_user,
        limit_filas: 20_000,
      )
      ch.query(sql, timeout: 300).map { |r| normalizar(r) }
    end

    def normalizar(r)
      {
        "id_tx"                         => r["id_tx"].to_s,
        "id_user"                       => r["id_user"].to_s,
        "codigo_service_type"           => r["codigo_service_type"].to_s,
        "fecha_hora"                    => r["fecha_hora"].to_s,
        "numero_moviired"               => r["numero_moviired"].to_s,
        "valor_tx"                      => r["valor_tx"].to_f.round(2),
        "numero_referencia_transaccion" => r["numero_referencia_transaccion"].to_s,
        "numero_tx_mahindra"            => r["numero_tx_mahindra"].to_s,
        "dane"                          => r["dane"].to_s,
        "codigo_punto"                  => r["codigo_punto"].to_s,
        "ciudad"                        => r["ciudad"].to_s,
        "nombre_municipio"              => r["nombre_municipio"].to_s,
      }
    end

    def calcular_stats(rows)
      total = rows.size
      valor_total = rows.sum { |r| r["valor_tx"].to_f }
      valor_max   = rows.map { |r| r["valor_tx"].to_f }.max || 0
      valor_min   = rows.map { |r| r["valor_tx"].to_f }.reject(&:zero?).min || 0
      promedio    = total > 0 ? (valor_total / total) : 0
      n_usuarios  = rows.map { |r| r["id_user"] }.uniq.size

      # Tendencia diaria: agrupar por fecha (sin hora)
      por_dia = rows.group_by { |r| r["fecha_hora"].to_s[0, 10] }
                    .map { |fecha, grupo| { fecha: fecha, cant: grupo.size, valor: grupo.sum { |g| g["valor_tx"].to_f }.round(2) } }
                    .sort_by { |h| h[:fecha] }

      # Top municipios
      top_municipios = rows.group_by { |r| r["nombre_municipio"].to_s.empty? ? "(sin municipio)" : r["nombre_municipio"] }
                           .map { |muni, grupo| { municipio: muni, cant: grupo.size, valor: grupo.sum { |g| g["valor_tx"].to_f }.round(2) } }
                           .sort_by { |h| -h[:cant] }.first(10)

      {
        total:           total,
        n_usuarios:      n_usuarios,
        valor_total:     valor_total.round(2),
        valor_max:       valor_max.round(2),
        valor_min:       valor_min.round(2),
        promedio:        promedio.round(2),
        por_dia:         por_dia,
        top_municipios:  top_municipios,
      }
    end

    # CSV con todas las columnas que se ven en la tabla. Encabezado en español
    # ALL CAPS por convención de reportes regulatorios.
    def construir_csv(rows)
      CSV.generate(col_sep: ",", force_quotes: true) do |csv|
        csv << [
          "ID_TX", "ID_USER", "CODIGO_SERVICE_TYPE", "FECHA_HORA",
          "NUMERO_MOVIIRED", "VALOR_TX", "NUMERO_REFERENCIA_TRANSACCION",
          "NUMERO_TX_MAHINDRA", "DANE", "CODIGO_PUNTO",
          "CIUDAD", "NOMBRE_MUNICIPIO",
        ]
        rows.each do |r|
          csv << [
            r["id_tx"], r["id_user"], r["codigo_service_type"], r["fecha_hora"],
            r["numero_moviired"], r["valor_tx"], r["numero_referencia_transaccion"],
            r["numero_tx_mahindra"], r["dane"], r["codigo_punto"],
            r["ciudad"], r["nombre_municipio"],
          ]
        end
      end
    end

    def construir_html_email(desde, hasta, rows, mensaje_usuario, usuario)
      fmt_num   = ->(n) { (n || 0).to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1.').reverse }
      fmt_money = ->(n) { "$ #{fmt_num.((n || 0).abs)}" }
      total       = rows.size
      valor_total = rows.sum { |r| r["valor_tx"].to_f }
      n_usuarios  = rows.map { |r| r["id_user"] }.uniq.size
      promedio    = total > 0 ? (valor_total / total) : 0
      msj_html = mensaje_usuario.empty? ? "" : %Q(<p style="background:#FFFBEB;border-left:4px solid #F59E0B;padding:12px 16px;margin:16px 0;border-radius:4px;color:#78350F"><strong>Mensaje:</strong> #{ERB::Util.h(mensaje_usuario)}</p>)

      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#F5F3FF;color:#1F2937;">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F5F3FF;padding:20px 0">
            <tr><td align="center">
              <table cellpadding="0" cellspacing="0" border="0" width="640" style="background:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
                <tr><td style="background:linear-gradient(90deg,#6B21A8 0%,#7C3AED 100%);padding:24px 28px;color:#ffffff">
                  <div style="font-size:22px;font-weight:700;letter-spacing:-0.5px">💵 Reporte MoviiRed</div>
                  <div style="font-size:13px;margin-top:6px;opacity:0.92">Período: #{desde} → #{hasta}</div>
                </td></tr>
                <tr><td style="padding:28px">
                  <p style="margin:0 0 12px;font-size:14px">Hola,</p>
                  <p style="margin:0 0 12px;font-size:14px;line-height:1.5">Te compartimos el reporte de transacciones MoviiRed del período indicado. El detalle completo está en el archivo CSV adjunto.</p>
                  #{msj_html}
                  <h3 style="color:#6B21A8;margin:24px 0 12px;font-size:15px">📈 Resumen ejecutivo</h3>
                  <table cellpadding="0" cellspacing="6" border="0" width="100%" style="margin:0 -6px">
                    <tr>
                      <td style="background:#EDE9F5;border-top:3px solid #6B21A8;padding:12px;border-radius:6px;width:50%">
                        <div style="font-size:22px;font-weight:700;color:#1F2937">#{fmt_num.(total)}</div>
                        <div style="font-size:11px;color:#6B7280;margin-top:4px">Transacciones MoviiRed</div>
                      </td>
                      <td style="background:#DCFCE7;border-top:3px solid #22C55E;padding:12px;border-radius:6px;width:50%">
                        <div style="font-size:22px;font-weight:700;color:#166534">#{fmt_money.(valor_total)}</div>
                        <div style="font-size:11px;color:#166534;margin-top:4px">Valor total transaccionado</div>
                      </td>
                    </tr>
                    <tr>
                      <td style="background:#FAFAFA;border:1px solid #E5E7EB;padding:12px;border-radius:6px">
                        <div style="font-size:11px;color:#6B7280">Usuarios únicos</div>
                        <div style="font-size:18px;font-weight:700;color:#6B21A8;margin-top:4px">#{fmt_num.(n_usuarios)}</div>
                      </td>
                      <td style="background:#FAFAFA;border:1px solid #E5E7EB;padding:12px;border-radius:6px">
                        <div style="font-size:11px;color:#6B7280">Promedio por transacción</div>
                        <div style="font-size:18px;font-weight:700;color:#6B21A8;margin-top:4px">#{fmt_money.(promedio)}</div>
                      </td>
                    </tr>
                  </table>
                  <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">📎 <strong>Adjunto:</strong> archivo CSV (.csv) con el detalle completo de las transacciones MoviiRed del período.</p>
                </td></tr>
                <tr><td style="background:#F9FAFB;padding:16px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                  Generado automáticamente · <strong style="color:#6B21A8">Picap Monitoreo</strong> · #{Time.now.strftime('%d/%m/%Y %H:%M')}<br>
                  Por: #{ERB::Util.h(usuario || 'sistema')}
                </td></tr>
              </table>
            </td></tr>
          </table>
        </body></html>
      HTML
    end

    # Helpers genéricos (mismo patrón que otros controllers)
    def desde_param
      v = params[:desde].to_s.strip
      v.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? v : (Date.today - 7).strftime("%Y-%m-%d")
    end

    def hasta_param
      v = params[:hasta].to_s.strip
      v.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? v : Date.today.strftime("%Y-%m-%d")
    end

    # Convierte nil → "" en valores planos, recursivamente.
    def limpiar(obj)
      case obj
      when Hash  then obj.transform_values { |v| limpiar(v) }
      when Array then obj.map { |v| limpiar(v) }
      when nil   then ""
      else            obj
      end
    end
  end
end
