module Api
  class ConsoleController < ApplicationController
    before_action :authenticate_user!
    before_action :require_admin!
    def run
      render json: { ok: false, error: "Consola admin: pendiente de migrar (Bloque I)" },
             status: :service_unavailable
    end
  end
end
