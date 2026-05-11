module Api
  class CedulaAlertasController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: {
        ok: true,
        desde: desde_param, hasta: hasta_param,
        pais_filtro: pais_param,
        resumen: { total: 0, ok: 0, alerta: 0, pct_alerta: 0 },
        trend: [], alertas: [], total_filas: 0,
        nota: "Alertas Cédula: pendiente de migrar (Bloque G)",
      }
    end
    def exportar
      render json: { ok: false, error: "Export Cédula Excel: pendiente (Bloque H)" },
             status: :service_unavailable
    end
  end
end
