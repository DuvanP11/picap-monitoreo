module Api
  class RecaudosController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: {
        ok: true,
        desde: desde_param, hasta: hasta_param,
        resumen: {
          total: 0, correcto: 0, demas: 0, deuda: 0, revisar: 0,
          v_correcto: 0, v_demas: 0, v_deuda: 0, v_revisar: 0,
        },
        trend: [], por_moneda: [], filas: [],
        nota: "Recaudos: pendiente de migrar (Bloque E)",
      }
    end
  end
end
