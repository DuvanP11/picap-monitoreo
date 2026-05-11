module Api
  class CalendarioController < ApplicationController
    before_action :authenticate_user!

    # GET /api/calendario — lista de tareas (frontend usa localStorage)
    def index
      render json: { ok: true, tareas: [] }
    end

    # POST /api/calendario/notificar — envía email de la tarea
    def notificar
      data = params.permit(:titulo, :hora, :fecha, :email, :detalle).to_h
      email = data["email"].to_s.strip
      return render json: { ok: false, error: "Email requerido" }, status: :bad_request if email.blank?
      # TODO Bloque I: integrar EmailService real
      Rails.logger.info("[Calendario] notificación a #{email}: #{data.inspect}")
      render json: { ok: true, mensaje: "Notificación encolada para #{email}",
                     nota: "Email real pendiente de Bloque I" }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end
  end
end
