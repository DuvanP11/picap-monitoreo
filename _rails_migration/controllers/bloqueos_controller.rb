module Api
  class BloqueosController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: {
        ok: true,
        desde: desde_param, hasta: hasta_param,
        alertas: [], bloqueados: [], reactivados: [],
        resumen: {
          total: 0, alerta: 0, ok: 0,
          bloqueados: 0, reactivados: 0,
          expulsados: 0, suspendidos: 0, susp_mas30: 0,
          pct_alerta: 0, pct_ok: 0,
          muestra_size: 0, muestra_truncada: false,
        },
        stats_bloqueados: { top10: { paises: [], ciudades: [], motivos: [] }, total: 0 },
        stats_reactivados: { top10: { paises: [], ciudades: [], motivos: [] }, total: 0 },
        nota: "Bloqueos: pendiente de migrar (Bloque B)",
      }
    end
    def estadisticas
      render json: { ok: true, desde: desde_param, hasta: hasta_param,
                     stats_bloqueados: {}, stats_reactivados: {},
                     nota: "Pendiente (Bloque B)" }
    end
  end
end
