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
require "zip"

class ResendMailerService
  API_URL          = "https://api.resend.com/emails".freeze
  DEFAULT_FROM     = "Picap Monitoreo <onboarding@resend.dev>".freeze
  TIMEOUT_SECONDS  = 30
  # v3.3.44: Si el adjunto raw > 20 MB lo comprimimos a ZIP automáticamente.
  # Excel típicamente baja al 30-50% del tamaño original — para Reporte OPS CV
  # con 27k servicios (~35-50 MB raw) eso lo deja en ~15-25 MB, dentro del
  # límite de Resend. Activar con `auto_zip: true` en send_email.
  AUTO_ZIP_THRESHOLD_MB = 20.0
  MAX_ATTACHMENT_MB     = 25.0

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
  # @param auto_zip [Boolean] si true (default) y el attachment > AUTO_ZIP_THRESHOLD_MB,
  #                            lo comprimimos a ZIP antes de enviarlo. v3.3.44.
  # @param progress [Proc, nil] optional callback que recibe un step string (para BackgroundEmailJobsHelper).
  def self.send_email(to:, subject:, html:, from: nil, cc: nil, bcc: nil,
                       attachment_bytes: nil, attachment_filename: nil,
                       auto_zip: true, progress: nil)
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
      raw_size_mb = (attachment_bytes.bytesize.to_f / 1024 / 1024).round(2)
      final_bytes = attachment_bytes
      final_filename = attachment_filename || "adjunto.xlsx"

      # ── v3.3.44: auto-comprimir si > 20 MB ──
      # Resend acepta payloads hasta ~40 MB (base64 incluido). Base64 incrementa
      # el tamaño ~33%, así que el límite raw es ~25 MB. Para Reporte OPS CV con
      # 27k servicios el Excel raw es 35-50 MB → no entra. ZIP típicamente reduce
      # 50-70% (Excel ya está parcialmente comprimido pero hay padding XML).
      if auto_zip && raw_size_mb > AUTO_ZIP_THRESHOLD_MB
        progress&.call("comprimiendo")
        Rails.logger.info("[ResendMailerService] adjunto raw=#{raw_size_mb} MB > #{AUTO_ZIP_THRESHOLD_MB} MB, comprimiendo a ZIP…") if defined?(Rails)
        final_bytes = compress_to_zip(attachment_bytes, final_filename)
        final_filename = final_filename.sub(/\.[^.]+\z/, "") + ".zip"
        zip_size_mb = (final_bytes.bytesize.to_f / 1024 / 1024).round(2)
        ratio = ((1 - (final_bytes.bytesize.to_f / attachment_bytes.bytesize)) * 100).round(1)
        Rails.logger.info("[ResendMailerService] ZIP listo: #{zip_size_mb} MB (#{ratio}% reducción)") if defined?(Rails)
      end

      final_size_mb = (final_bytes.bytesize.to_f / 1024 / 1024).round(2)
      if final_size_mb > MAX_ATTACHMENT_MB
        msg = "Adjunto demasiado grande para Resend: #{final_size_mb} MB " \
              "(raw original: #{raw_size_mb} MB · límite Resend: #{MAX_ATTACHMENT_MB} MB). " \
              "Aun comprimido a ZIP no entra. Reducí el rango de fechas (probá con 7-15 días) " \
              "o filtrá por ciudad para que el Excel sea más chico. " \
              "Archivo: #{final_filename}"
        Rails.logger.error("[ResendMailerService] #{msg}") if defined?(Rails)
        raise ValidationError, msg
      end

      progress&.call("enviando_a_resend")
      payload[:attachments] = [{
        filename: final_filename,
        content:  Base64.strict_encode64(final_bytes),
      }]

      Rails.logger.info(
        "[ResendMailerService] enviando email " \
        "(to=#{Array(to).size}, cc=#{Array(cc).size}, bcc=#{Array(bcc).size}, " \
        "subject=#{subject.to_s.first(80).inspect}, " \
        "attachment=#{final_filename.inspect}, size=#{final_size_mb} MB)"
      ) if defined?(Rails)
    else
      progress&.call("enviando_a_resend")
    end

    response = post_json(API_URL, payload, api_key)
    interpret_response(response)
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT => e
    raise NetworkError, "No se pudo conectar a Resend (#{e.class}): #{e.message}"
  end

  # Comprime un archivo individual a ZIP usando rubyzip.
  # Útil para que adjuntos > 25 MB entren en el límite de Resend.
  def self.compress_to_zip(file_bytes, filename_inside_zip)
    buffer = StringIO.new("".b)
    buffer.set_encoding(Encoding::ASCII_8BIT)
    Zip::OutputStream.write_buffer(buffer) do |zos|
      zos.put_next_entry(filename_inside_zip)
      zos.write(file_bytes)
    end
    buffer.string
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
