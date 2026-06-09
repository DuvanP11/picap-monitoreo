# app/services/background_email_jobs_helper.rb
# v3.3.44: helper genérico para correr enviar_email en background CON tracking
# del estado para que el frontend pueda hacer polling y mostrar el progreso.
#
# Reemplaza al viejo `BackgroundMailerHelper.run` (que ignoraba errores) para
# casos donde queremos feedback visible al usuario:
#   - "⏳ Cargando datos…"
#   - "⏳ Construyendo Excel…"
#   - "📤 Enviando a Resend…"
#   - "✅ Email enviado · re_abc123"
#   - "❌ Adjunto demasiado grande (32 MB > 25 MB). Filtrá por menos días."
#
# Uso típico desde un controller:
#
#   def enviar_email
#     # validar params (to_list vacío, emails inválidos, etc.)
#     job_id = BackgroundEmailJobsHelper.start(label: "ReporteOpsCV", to: to_list) do |progress|
#       progress.call("cargando_datos")
#       rows = cargar_filas(desde:, hasta:, ...)
#
#       progress.call("construyendo_excel")
#       xlsx = Api::ExportarController.build_xxx_xlsx(...)
#
#       progress.call("enviando_a_resend")
#       result = ResendMailerService.send_email(
#         to:, cc:, bcc:, subject:, html:,
#         attachment_bytes: xlsx[:data],
#         attachment_filename: "report.xlsx",
#       )
#       result  # debe ser un hash con :id (el message id de Resend)
#     end
#     render json: { ok: true, queued: true, job_id: job_id }, status: :accepted
#   end
#
#   def enviar_email_status
#     job = BackgroundEmailJobsHelper.get_status(params[:job_id])
#     return render(json: {ok: false, error: "Job no encontrado o expirado"},
#                   status: :not_found) if job.nil?
#     render json: BackgroundEmailJobsHelper.serialize(job)
#   end
module BackgroundEmailJobsHelper
  @@jobs       = {}
  @@jobs_mutex = Mutex.new
  TTL_SEC      = 1_800  # 30 min

  # Lanza el block en un Thread separado y devuelve un job_id que el cliente
  # puede consultar via get_status.
  #
  # El block recibe un único argumento: un Proc para actualizar el step actual
  # del job (ej. "cargando_datos", "construyendo_excel", "enviando_a_resend").
  # El block DEBE devolver un Hash con clave :id (el message id de Resend) o
  # similar — eso se reporta como resend_id en el status.
  def self.start(label:, to:, &block)
    job_id = SecureRandom.hex(16)
    @@jobs_mutex.synchronize do
      @@jobs[job_id] = {
        label: label,
        to: Array(to),
        status: :running,
        step: "queued",
        t0: Time.now,
      }
    end

    progress = ->(step) { _update_step(job_id, step) }

    Thread.new do
      begin
        Rails.logger.info("[BackgroundEmail/#{label}] job=#{job_id} START to=#{Array(to).inspect}")
        result = block.call(progress)
        resend_id = result.is_a?(Hash) ? result[:id] || result["id"] : nil
        @@jobs_mutex.synchronize do
          job = @@jobs[job_id]
          next unless job
          job[:status]    = :done
          job[:step]      = "delivered"
          job[:resend_id] = resend_id
          job[:t_elapsed] = (Time.now - job[:t0]).round(1)
        end
        Rails.logger.info(
          "[BackgroundEmail/#{label}] job=#{job_id} OK en " \
          "#{@@jobs[job_id][:t_elapsed]}s, resend_id=#{resend_id.inspect}"
        )
      rescue => e
        Rails.logger.error("[BackgroundEmail/#{label}] job=#{job_id} #{e.class}: #{e.message}")
        Rails.logger.error(e.backtrace.first(8).join("\n")) if e.backtrace
        @@jobs_mutex.synchronize do
          job = @@jobs[job_id]
          next unless job
          job[:status]      = :error
          job[:error]       = e.message
          job[:error_class] = e.class.name
          job[:t_elapsed]   = (Time.now - job[:t0]).round(1)
        end
      end
    end

    job_id
  end

  # Devuelve una copia del job (o nil si no existe o expiró).
  def self.get_status(job_id)
    cleanup
    @@jobs_mutex.synchronize do
      job = @@jobs[job_id.to_s]
      job ? job.dup : nil
    end
  end

  # Serializa un job para enviar al cliente. Incluye un mensaje "humano"
  # del step actual y resend_id si está disponible.
  STEP_LABELS = {
    "queued"             => "🕐 En cola…",
    "cargando_datos"     => "📥 Cargando datos de ClickHouse…",
    "construyendo_excel" => "📊 Construyendo Excel…",
    "comprimiendo"       => "🗜️ Comprimiendo (Excel grande)…",
    "enviando_a_resend"  => "📤 Enviando a Resend…",
    "delivered"          => "✅ Entregado a Resend",
  }.freeze

  def self.serialize(job)
    {
      ok:        job[:status] != :error,
      status:    job[:status],
      step:      job[:step],
      step_label: STEP_LABELS[job[:step]] || job[:step],
      label:     job[:label],
      to:        job[:to],
      elapsed_sec: (Time.now - job[:t0]).round(1),
      t_elapsed:   job[:t_elapsed],
      resend_id:   job[:resend_id],
      error:       job[:error],
      error_class: job[:error_class],
    }
  end

  def self.cleanup
    now = Time.now
    @@jobs_mutex.synchronize do
      @@jobs.delete_if { |_, j| (now - j[:t0]) > TTL_SEC }
    end
  end

  # Helper interno para actualizar el step desde el block del usuario.
  def self._update_step(job_id, step)
    @@jobs_mutex.synchronize do
      job = @@jobs[job_id]
      job[:step] = step.to_s if job && job[:status] == :running
    end
  end
end
