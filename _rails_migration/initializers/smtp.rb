# config/initializers/smtp.rb
# Configura ActionMailer para usar las envvars SMTP_HOST/PORT/EMAIL/PASSWORD.
# Sin esta config, Rails intenta enviar via sendmail/localhost:25 y tira
# "Connection refused" en producción.
#
# Envvars esperadas (declaradas en deploy/render.yaml como sync:false):
#   SMTP_HOST     ej. "smtp.gmail.com" o "smtp.office365.com"
#   SMTP_PORT     587 (STARTTLS, default) o 465 (SSL)
#   SMTP_EMAIL    usuario completo, ej. "monitoreo@picap.io"
#   SMTP_PASSWORD password de la cuenta (o app password para Gmail)
#   SMTP_AUTH     opcional: 'plain' (default) | 'login' | 'cram_md5'

smtp_host = ENV["SMTP_HOST"].to_s.strip
smtp_user = ENV["SMTP_EMAIL"].to_s.strip

if smtp_host.empty? || smtp_user.empty?
  if defined?(Rails) && Rails.logger
    Rails.logger.warn("[SMTP] envvars SMTP_HOST/SMTP_EMAIL vacías — el envío de email NO funcionará. Configúralas en el panel de Render/AWS.")
  end
else
  port_raw = ENV["SMTP_PORT"].to_s.strip
  port     = port_raw.empty? ? 587 : port_raw.to_i

  settings = {
    address:        smtp_host,
    port:           port,
    user_name:      smtp_user,
    password:       ENV["SMTP_PASSWORD"].to_s,
    domain:         (smtp_user.split("@").last || "picap.io"),
    authentication: (ENV["SMTP_AUTH"].to_s.strip.empty? ? :plain : ENV["SMTP_AUTH"].to_sym),
  }

  # Port 465 usa SSL directo; 587 usa STARTTLS.
  if port == 465
    settings[:tls] = true
  else
    settings[:enable_starttls_auto] = true
  end

  ActionMailer::Base.delivery_method     = :smtp
  ActionMailer::Base.smtp_settings       = settings
  ActionMailer::Base.raise_delivery_errors = true
  ActionMailer::Base.perform_deliveries  = true

  if defined?(Rails) && Rails.logger
    Rails.logger.info("[SMTP] Configurado vía #{smtp_host}:#{port} (#{smtp_user})")
  end
end
