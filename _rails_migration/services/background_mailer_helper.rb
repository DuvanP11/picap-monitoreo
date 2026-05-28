# app/services/background_mailer_helper.rb
# v3.3.20: helper común para enviar emails en background sin bloquear el
# request. Patrón:
#   def enviar_email
#     # validar y capturar params como locals
#     BackgroundMailerHelper.run("MiModulo") do
#       rows = cargar_filas(...)
#       xlsx = ExportarController.build_mi_xlsx(...)
#       ResendMailerService.send_email(to:, subject:, html:, ...)
#     end
#     render json: { ok: true, queued: true, ... }, status: :accepted
#   end
#
# Beneficios:
# - El proxy frontend tiene timeout ~60s. Queries CH pueden tomar 2-3 min.
#   Si todo es sync, el cliente recibe 502 aunque el email llegue OK.
# - Con run() respondemos 202 al instante; el thread sigue solo.
# - Errores van solo a Rails.logger (no pueden ser reportados al cliente
#   que ya cerró conexión). Si necesitamos confirmación firme, agregar
#   ActiveJob+Sidekiq en una futura iteración.
module BackgroundMailerHelper
  # Ejecuta el bloque en un thread separado. label es solo para logging.
  def self.run(label, &block)
    Thread.new do
      begin
        block.call
        Rails.logger.info("[BackgroundMailer/#{label}] OK")
      rescue => e
        Rails.logger.error("[BackgroundMailer/#{label}] #{e.class}: #{e.message}")
        Rails.logger.error(e.backtrace.first(8).join("\n")) if e.backtrace
      end
    end
  end

  # Parser tolerante: acepta string separado por coma/semicolon/whitespace,
  # devuelve array de strings únicos y trimmed. Útil en cada controller.
  def self.parse_email_list(val)
    return [] if val.nil?
    raw = val.is_a?(Array) ? val.join(",") : val.to_s
    raw.split(/[,;\s\n]+/).map(&:strip).reject(&:empty?).uniq
  end

  # Validador de formato email (lista). Devuelve [validos, invalidos]
  RX_EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/.freeze
  def self.split_validos(emails)
    emails.partition { |e| e.match?(RX_EMAIL) }
  end
end
