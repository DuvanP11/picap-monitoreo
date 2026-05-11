module Api
  class ExportarController < ApplicationController
    before_action :authenticate_user!
    def evasion;  render_pending("Evasión"); end
    def estafa;   render_pending("Estafa"); end
    def bloqueos; render_pending("Bloqueos"); end
    def pagos;    render_pending("Pagos"); end
    def recaudos; render_pending("Recaudos"); end
    private
    def render_pending(modulo)
      render json: { ok: false, error: "Exportar #{modulo} Excel: pendiente (Bloque H)" },
             status: :service_unavailable
    end
  end
end
