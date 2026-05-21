# app/mailers/recaudos_mailer.rb
# Envío de reportes de Recaudos por email con plantilla HTML corporativa
# (header morado Picap + KPIs inline) + adjunto xlsx.
#
# Requiere SMTP configurado en config/environments/production.rb vía envvars:
#   SMTP_EMAIL, SMTP_PASSWORD, SMTP_HOST, SMTP_PORT.

class RecaudosMailer < ApplicationMailer
  default from: ENV.fetch("SMTP_EMAIL", "monitoreo@picap.io")

  # @param destinatario [String] email destino
  # @param asunto [String] subject del email
  # @param html [String] cuerpo HTML completo
  # @param adjunto_bytes [String] bytes raw del xlsx
  # @param adjunto_nombre [String] nombre del adjunto (ej. "Reporte.xlsx")
  def reporte(destinatario:, asunto:, html:, adjunto_bytes:, adjunto_nombre:)
    attachments[adjunto_nombre] = {
      mime_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      content:   adjunto_bytes,
    }
    mail(
      to:           destinatario,
      subject:      asunto,
      content_type: "text/html",
      body:         html,
    )
  end
end
