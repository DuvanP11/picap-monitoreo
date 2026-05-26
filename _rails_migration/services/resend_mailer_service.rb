# app/services/resend_mailer_service.rb
# Envío de email vía Resend.com API (https://resend.com/docs/api-reference/emails/send-email).
#
# Reemplazo del setup SMTP clásico — Resend usa una sola envvar (RESEND_API_KEY),
# tiene free tier 3000 emails/mes, y no requiere abrir puertos 587/465.
#
# Envvars:
#   RESEND_API_KEY   obligatorio — formato "re_XXXXXXXX". Generar en resend.com → API Keys.
#   RESEND_FROM      opcional — remitente. Default: "Picap Monitoreo <onboarding@resend.dev>".
#                    Para usar un dominio propio (ej. "monitoreo@picap.io") hay que verificar
#                    el dominio en resend.com → Domains primero.
#
# Errores propios (subclases de StandardError) para que el controller pueda
# discriminar entre falta de config (HTTP 500 user-facing "configurá la envvar")
# y errores reales de la API (400/401/422).

require "net/http"
require "uri"
require "json"
require "base64"

class ResendMailerService
  API_URL          = "https://api.resend.com/emails".freeze
  DEFAULT_FROM     = "Picap Monitoreo <onboarding@resend.dev>".freeze
  TIMEOUT_SECONDS  = 30

  # Errores tipados — el controller los rescue para devolver mensajes específicos.
  class ConfigError       < StandardError; end  # RESEND_API_KEY vacía
  class AuthError         < StandardError; end  # 401: API key inválida
  class ValidationError   < StandardError; end  # 400/422: payload inválido / from no verificado
  class NetworkError      < StandardError; end  # timeout, DNS, conexión

  # Envía un email con adjunto opcional.
  #
  # @param to [String, Array<String>] destinatario(s) principal(es)
  # @param subject [String]
  # @param html [String] cuerpo HTML
  # @param from [String, nil] remitente. Si nil usa RESEND_FROM o DEFAULT_FROM.
  # @param cc [String, Array<String>, nil] copia visible (CC)
  # @param bcc [String, Array<String>, nil] copia oculta (BCC/CCO)
  # @param attachment_bytes [String, nil] bytes raw del adjunto (xlsx, pdf, etc.)
  # @param attachment_filename [String, nil] nombre del adjunto (ej. "Reporte.xlsx")
  # @return [Hash] { id: "<resend-message-id>" } en éxito
  # @raise [ConfigError, AuthError, ValidationError, NetworkError]
  def self.send_email(to:, subject:, html:, from: nil, cc: nil, bcc: nil,
                       attachment_bytes: nil, attachment_filename: nil)
    api_key = ENV["RESEND_API_KEY"].to_s.strip
    if api_key.empty?
      raise ConfigError, "RESEND_API_KEY no configurada. Generá una key en https://resend.com → API Keys y agregala como envvar en el panel de Render/AWS."
    end

    payload = {
      from:    from || ENV["RESEND_FROM"].to_s.strip.then { |v| v.empty? ? DEFAULT_FROM : v },
      to:      Array(to).reject { |e| e.to_s.strip.empty? },
      subject: subject.to_s,
      html:    html.to_s,
    }

    cc_list  = Array(cc).reject  { |e| e.to_s.strip.empty? }
    bcc_list = Array(bcc).reject { |e| e.to_s.strip.empty? }
    payload[:cc]  = cc_list  if cc_list.any?
    payload[:bcc] = bcc_list if bcc_list.any?

    if attachment_bytes && !attachment_bytes.empty?
      payload[:attachments] = [{
        filename: attachment_filename || "adjunto.xlsx",
        content:  Base64.strict_encode64(attachment_bytes),
      }]
    end

    response = post_json(API_URL, payload, api_key)
    interpret_response(response)
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT => e
    raise NetworkError, "No se pudo conectar a Resend (#{e.class}): #{e.message}"
  end

  # POST con headers de auth + JSON, manejando https.
  def self.post_json(url, body, api_key)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl     = (uri.scheme == "https")
    http.open_timeout = TIMEOUT_SECONDS
    http.read_timeout = TIMEOUT_SECONDS

    req = Net::HTTP::Post.new(uri.request_uri)
    req["Authorization"] = "Bearer #{api_key}"
    req["Content-Type"]  = "application/json"
    req["Accept"]        = "application/json"
    req.body             = JSON.generate(body)

    http.request(req)
  end

  # Convierte la respuesta HTTP en éxito (Hash) o raise tipado.
  def self.interpret_response(response)
    code = response.code.to_i
    body_raw = response.body.to_s
    body = begin
      JSON.parse(body_raw)
    rescue JSON::ParserError
      { "raw" => body_raw }
    end

    case code
    when 200, 201, 202
      { id: body["id"].to_s }
    when 401, 403
      raise AuthError, "Resend rechazó la API key (HTTP #{code}). Revisá RESEND_API_KEY — debe empezar con 're_'. Mensaje: #{body['message'] || body_raw}"
    when 400, 422
      msg = body["message"] || body["name"] || body_raw
      raise ValidationError, "Resend rechazó el email (HTTP #{code}): #{msg}. Tip común: el 'from' debe usar un dominio verificado en resend.com → Domains, o el default onboarding@resend.dev."
    when 429
      raise NetworkError, "Resend rate limit alcanzado (HTTP 429). Esperá unos segundos y reintentá."
    else
      raise NetworkError, "Resend respondió HTTP #{code}: #{body['message'] || body_raw}"
    end
  end
end
