module Api
  class PiboxController < ApplicationController
    before_action :authenticate_user!
    def servicios
      render json: { ok: true, desde: desde_param, hasta: hasta_param,
                     servicios: [], total: 0,
                     nota: "Pibox B2B: pendiente (Bloque G)" }
    end
    def alertas
      render json: { ok: true, total: 0, alertas: [],
                     resumen: { criticas: 0, altas: 0, medias: 0 },
                     nota: "Pibox alertas: pendiente (Bloque G)" }
    end
    def export
      render json: { ok: false, error: "Pibox export: pendiente (Bloque G)" },
             status: :service_unavailable
    end
  end
end
