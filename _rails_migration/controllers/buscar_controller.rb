module Api
  class BuscarController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: { ok: true, resultados: [], q: params[:q].to_s,
                     nota: "Buscar global: pendiente" }
    end
  end
end
