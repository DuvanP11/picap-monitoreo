module Api
  class CronogramaController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: { ok: true, tareas: [],
                     nota: "Cronograma: pendiente (Bloque I)" }
    end
    def create;       render_pending; end
    def update;       render_pending; end
    def destroy;      render_pending; end
    def marcar_hecho; render_pending; end
    def test;         render_pending; end
    private
    def render_pending
      render json: { ok: false, error: "Cronograma: pendiente (Bloque I)" },
             status: :service_unavailable
    end
  end
end
