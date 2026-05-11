# Stubs para los controllers todavía no migrados.
# Devuelven 503 (Service Unavailable) con mensaje claro.
# Se reemplazarán uno por uno con la implementación real.

# ─── app/controllers/api/bloqueos_controller.rb ───────────────────────
module Api
  class BloqueosController < ApplicationController
    before_action :authenticate_user!
    def index;        render_pending; end
    def estadisticas; render_pending; end
    private
    def render_pending
      render json: { ok: false, error: "Bloqueos: pendiente de migrar a Rails", code: 503,
                     desde: desde_param, hasta: hasta_param,
                     alertas: [], bloqueados: [], reactivados: [],
                     resumen: { total:0, alerta:0, ok:0, bloqueados:0, reactivados:0,
                                expulsados:0, suspendidos:0, susp_mas30:0,
                                pct_alerta:0, pct_ok:0 } },
             status: :service_unavailable
    end
  end
end

# ─── app/controllers/api/recaudos_controller.rb ───────────────────────
module Api
  class RecaudosController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: { ok: false, error: "Recaudos: pendiente", desde: desde_param, hasta: hasta_param,
                     resumen: {}, trend: [], por_moneda: [], filas: [] },
             status: :service_unavailable
    end
  end
end

# ─── app/controllers/api/auditoria_controller.rb ──────────────────────
module Api
  class AuditoriaController < ApplicationController
    before_action :authenticate_user!
    def comisiones; render_pending; end
    def creditos;   render_pending; end
    def exportar;   render_pending; end
    private
    def render_pending
      render json: { ok: false, error: "Auditoría: pendiente",
                     desde: desde_param, hasta: hasta_param,
                     resumen: {}, alertas: [], total_filas: 0 },
             status: :service_unavailable
    end
  end
end

# ─── app/controllers/api/pibox_controller.rb ──────────────────────────
module Api
  class PiboxController < ApplicationController
    before_action :authenticate_user!
    def servicios; render json: { ok: false, error: "Pibox: pendiente", servicios: [] }, status: :service_unavailable; end
    def alertas;   render json: { ok: false, error: "Pibox: pendiente", total: 0, alertas: [] }, status: :service_unavailable; end
    def export;    render json: { ok: false, error: "Pibox export: pendiente" }, status: :service_unavailable; end
  end
end

# ─── app/controllers/api/exportar_controller.rb ───────────────────────
module Api
  class ExportarController < ApplicationController
    before_action :authenticate_user!
    def evasion;  render_pending; end
    def estafa;   render_pending; end
    def bloqueos; render_pending; end
    def pagos;    render_pending; end
    def recaudos; render_pending; end
    private
    def render_pending
      render json: { ok: false, error: "Exportar Excel: pendiente de migrar" }, status: :service_unavailable
    end
  end
end

# ─── app/controllers/api/buscar_controller.rb ─────────────────────────
module Api
  class BuscarController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: { ok: false, error: "Buscar: pendiente", resultados: [] }, status: :service_unavailable
    end
  end
end

# ─── app/controllers/api/console_controller.rb ────────────────────────
module Api
  class ConsoleController < ApplicationController
    before_action :authenticate_user!
    before_action :require_admin!
    def run
      render json: { ok: false, error: "Consola admin: pendiente de migrar" }, status: :service_unavailable
    end
  end
end

# ─── app/controllers/api/recuperacion_controller.rb ───────────────────
module Api
  class RecuperacionController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: { ok: false, error: "Recuperación: pendiente",
                     desde: desde_param, hasta: hasta_param,
                     kpis: {}, drivers: [], trend: [] },
             status: :service_unavailable
    end
  end
end
