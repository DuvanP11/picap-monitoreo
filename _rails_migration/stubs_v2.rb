# Stubs v2 — devuelven 200 OK con estructuras vacías VÁLIDAS.
# Mejor UX que 503: el frontend muestra "sin datos" en vez de error rojo.
# Estos controllers se reescriben con queries reales en sus bloques (B-I).

# ─── app/controllers/api/bloqueos_controller.rb ────────────────────────
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

# ─── app/controllers/api/recaudos_controller.rb ────────────────────────
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

# ─── app/controllers/api/auditoria_controller.rb ───────────────────────
module Api
  class AuditoriaController < ApplicationController
    before_action :authenticate_user!
    def comisiones; render_pending; end
    def creditos;   render_pending; end
    def exportar
      render json: { ok: false, error: "Auditoría export: pendiente (Bloque F)" },
             status: :service_unavailable
    end
    private
    def render_pending
      render json: {
        ok: true,
        desde: desde_param, hasta: hasta_param,
        resumen: {
          total: 0, con_error: 0, correctos: 0,
          por_tipo: {}, por_kam: [], por_ciudad: [],
        },
        alertas: [], total_filas: 0,
        nota: "Auditoría Pibox: pendiente de migrar (Bloque F)",
      }
    end
  end
end

# ─── app/controllers/api/pibox_controller.rb ───────────────────────────
module Api
  class PiboxController < ApplicationController
    before_action :authenticate_user!
    def servicios
      render json: { ok: true, desde: desde_param, hasta: hasta_param,
                     servicios: [], total: 0,
                     nota: "Pibox B2B: pendiente (Bloque G)" }
    end
    def alertas
      render json: { ok: true, total: 0, alertas: [],
                     resumen: { criticas: 0, altas: 0, medias: 0 },
                     nota: "Pibox alertas: pendiente (Bloque G)" }
    end
    def export
      render json: { ok: false, error: "Pibox export: pendiente (Bloque G)" },
             status: :service_unavailable
    end
  end
end

# ─── app/controllers/api/exportar_controller.rb ────────────────────────
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

# ─── app/controllers/api/buscar_controller.rb ──────────────────────────
module Api
  class BuscarController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: { ok: true, resultados: [], q: params[:q].to_s,
                     nota: "Buscar global: pendiente" }
    end
  end
end

# ─── app/controllers/api/console_controller.rb ─────────────────────────
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

# ─── app/controllers/api/recuperacion_controller.rb ────────────────────
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

# ─── app/controllers/api/cedula_alertas_controller.rb (NUEVO) ──────────
module Api
  class CedulaAlertasController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: {
        ok: true,
        desde: desde_param, hasta: hasta_param,
        pais_filtro: pais_param,
        resumen: {
          total: 0, ok: 0, alerta: 0, pct_alerta: 0,
        },
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

# ─── app/controllers/api/calendario_controller.rb (GET listar) ─────────
# El controller ya existe (con POST notificar). Solo agregamos el método
# index. Si el archivo se reemplaza, asegurar que ambos métodos están.
module Api
  class CalendarioController < ApplicationController
    before_action :authenticate_user!

    # GET /api/calendario — lista de tareas guardadas (vacía por ahora,
    # el frontend usa localStorage para guardarlas en el cliente)
    def index
      render json: { ok: true, tareas: [] }
    end

    # POST /api/calendario/notificar — envía email de la tarea
    def notificar
      data = params.permit(:titulo, :hora, :fecha, :email, :detalle).to_h
      email = data["email"].to_s.strip
      return render json: { ok: false, error: "Email requerido" }, status: :bad_request if email.blank?

      # TODO: integrar con EmailService cuando se complete Bloque I
      Rails.logger.info("[Calendario] notificación a #{email}: #{data.inspect}")
      render json: { ok: true, mensaje: "Notificación encolada para #{email}",
                     nota: "Email real pendiente de Bloque I" }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end
  end
end

# ─── app/controllers/api/recursos_controller.rb (NUEVO - features) ─────
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
    def create;        render_pending; end
    def update;        render_pending; end
    def destroy;       render_pending; end
    def share;         render_pending; end
    def share_bulk;    render_pending; end
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

# ─── app/controllers/api/cronograma_controller.rb (NUEVO - features) ───
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

# ─── app/controllers/api/audit_controller.rb (NUEVO - features) ────────
module Api
  class AuditController < ApplicationController
    before_action :authenticate_user!
    # POST /api/audit/log — no-op silencioso para no llenar de errores
    def log
      render json: { ok: true }
    end
    def logs
      return render json: { ok: false, error: "Solo admin" }, status: :forbidden unless current_rol == "admin"
      render json: {
        ok: true,
        eventos: [],
        resumen: { total: 0, usuarios_unicos: 0, logins: 0,
                   logins_fallidos: 0, exports: 0, view_opens: 0 },
        top_usuarios: [], top_modulos: [],
        filtros: { desde: desde_param, hasta: hasta_param },
        nota: "Audit logs: pendiente (Bloque I)",
      }
    end
    def export
      return render json: { ok: false, error: "Solo admin" }, status: :forbidden unless current_rol == "admin"
      render json: { ok: false, error: "Audit export: pendiente (Bloque I)" },
             status: :service_unavailable
    end
  end
end

# ─── app/controllers/api/resumen_general_controller.rb (NUEVO) ─────────
module Api
  class ResumenGeneralController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: {
        ok: true,
        filtros: { desde: desde_param, hasta: hasta_param,
                   pais: pais_param, pais_iso: iso_pais },
        modulos: {},
        areas: {
          "monitoreo"   => { "nombre" => "Monitoreo",                "color" => "#1d4ed8", "icono" => "🔵" },
          "sac_recl"    => { "nombre" => "SAC / Reclamaciones",      "color" => "#7c3aed", "icono" => "🟣" },
          "comercial"   => { "nombre" => "Comercial",                "color" => "#16a34a", "icono" => "🟢" },
          "operaciones" => { "nombre" => "Operaciones",              "color" => "#ea580c", "icono" => "🟠" },
          "sac_act"     => { "nombre" => "SAC / Activaciones",       "color" => "#ca8a04", "icono" => "🟡" },
        },
        generado_en: Time.now.utc.strftime("%Y-%m-%d %H:%M:%S"),
        nota: "Resumen 360: pendiente de migrar (Bloque I)",
      }
    end
  end
end
