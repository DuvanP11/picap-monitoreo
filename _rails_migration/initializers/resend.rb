# config/initializers/resend.rb
# Resend.com → reemplaza el setup SMTP clásico. NO configura ActionMailer
# (usamos ResendMailerService que llama directo a la API REST).
#
# Sólo loguea al boot si la envvar está vacía, para que cuando alguien intente
# enviar email vea inmediatamente en logs por qué falla.
#
# Envvars:
#   RESEND_API_KEY  obligatoria — generar en https://resend.com → API Keys.
#   RESEND_FROM     opcional — remitente. Default: "Picap Monitoreo <onboarding@resend.dev>".
#                   Para usar @picap.io: verificar el dominio en resend.com → Domains.

if defined?(Rails) && Rails.logger
  api_key = ENV["RESEND_API_KEY"].to_s.strip
  if api_key.empty?
    Rails.logger.warn("[Resend] RESEND_API_KEY vacía — el envío de email NO funcionará. Generá una key en resend.com y agregala como envvar.")
  else
    masked = api_key.length > 8 ? "#{api_key[0,4]}…#{api_key[-4..]}" : "***"
    from   = ENV["RESEND_FROM"].to_s.strip
    from   = "onboarding@resend.dev (default)" if from.empty?
    Rails.logger.info("[Resend] Configurado · key=#{masked} · from=#{from}")
  end
end
