module Api
  class RecursosController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: {
        ok: true,
        recursos: [], categorias: [],
        yo: { usuario: current_usuario, email: "", rol: current_rol },
        nota: "Recursos: pendiente de migrar (Bloque I)",
      }
    end
    def create;     render_pending; end
    def update;     render_pending; end
    def destroy;    render_pending; end
    def share;      render_pending; end
    def share_bulk; render_pending; end
    def usuarios_portal
      render json: { ok: true, usuarios: [] }
    end
    private
    def render_pending
      render json: { ok: false, error: "Recursos: pendiente (Bloque I)" },
             status: :service_unavailable
    end
  end
end
