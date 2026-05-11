module Api
  class RecuperacionController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: {
        ok: true,
        desde: desde_param, hasta: hasta_param,
        pais_filtro: pais_param,
        kpis: {
          total_penalidad: 0, total_pagado: 0, total_deuda: 0,
          pct_recuperado: 0,
        },
        drivers: [], trend: [],
        nota: "Recuperación Top 10: pendiente (Bloque G)",
      }
    end
  end
end
