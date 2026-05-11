module Api
  class AuditoriaController < ApplicationController
    before_action :authenticate_user!
    def comisiones; render_pending; end
    def creditos;   render_pending; end
    def exportar
      render json: { ok: false, error: "Auditoría export: pendiente (Bloque F)" },
             status: :service_unavailable
    end
    private
    def render_pending
      render json: {
        ok: true,
        desde: desde_param, hasta: hasta_param,
        resumen: {
          total: 0, con_error: 0, correctos: 0,
          por_tipo: {}, por_kam: [], por_ciudad: [],
        },
        alertas: [], total_filas: 0,
        nota: "Auditoría Pibox: pendiente de migrar (Bloque F)",
      }
    end
  end
end
