# Stubs para features recientes (cronograma, recursos, audit logs, resumen 360).
# Devuelven estructuras vacías VÁLIDAS para que el frontend no muestre
# "Ruta no encontrada" sino "sin datos". Se reemplazarán con la
# implementación completa en el Bloque I.

# ─── app/controllers/api/recursos_controller.rb ────────────────────────
module Api
  class RecursosController < ApplicationController
    before_action :authenticate_user!

    # GET /api/recursos
    def index
      render json: {
        ok: true,
        recursos: [],
        categorias: [],
        yo: { usuario: current_usuario, email: "", rol: current_rol },
      }
    end

    # POST /api/recursos
    def create
      render json: { ok: false, error: "Recursos: pendiente de migrar a Rails (Bloque I)" },
             status: :service_unavailable
    end

    # PUT /api/recursos/:id
    def update
      render json: { ok: false, error: "Recursos update: pendiente" },
             status: :service_unavailable
    end

    # DELETE /api/recursos/:id
    def destroy
      render json: { ok: false, error: "Recursos delete: pendiente" },
             status: :service_unavailable
    end

    # GET /api/recursos/usuarios-portal
    def usuarios_portal
      render json: { ok: true, usuarios: [] }
    end

    # POST /api/recursos/share-bulk
    def share_bulk
      render json: { ok: false, error: "Compartir múltiple: pendiente" },
             status: :service_unavailable
    end

    # POST /api/recursos/:id/share
    def share
      render json: { ok: false, error: "Compartir: pendiente" },
             status: :service_unavailable
    end
  end
end

# ─── app/controllers/api/cronograma_controller.rb ──────────────────────
module Api
  class CronogramaController < ApplicationController
    before_action :authenticate_user!

    # GET /api/cronograma
    def index
      render json: { ok: true, tareas: [] }
    end

    # POST /api/cronograma
    def create
      render json: { ok: false, error: "Cronograma: pendiente de migrar (Bloque I)" },
             status: :service_unavailable
    end

    # PUT /api/cronograma/:id
    def update
      render json: { ok: false, error: "Cronograma update: pendiente" },
             status: :service_unavailable
    end

    # DELETE /api/cronograma/:id
    def destroy
      render json: { ok: false, error: "Cronograma delete: pendiente" },
             status: :service_unavailable
    end

    # POST /api/cronograma/:id/marcar-hecho
    def marcar_hecho
      render json: { ok: false, error: "Marcar hecho: pendiente" },
             status: :service_unavailable
    end

    # POST /api/cronograma/:id/test
    def test
      render json: { ok: false, error: "Test cronograma: pendiente" },
             status: :service_unavailable
    end
  end
end

# ─── app/controllers/api/audit_controller.rb ───────────────────────────
# Logs de seguridad/auditoría (distinto de AuditoriaController que es de
# auditorías comerciales de Pibox)
module Api
  class AuditController < ApplicationController
    before_action :authenticate_user!

    # POST /api/audit/log
    def log
      # No-op silencioso para no llenar pantallas con errores. Cuando
      # implementemos audit log real, este endpoint guarda el evento.
      render json: { ok: true }
    end

    # GET /api/audit/logs
    def logs
      require_admin!
      return if performed?
      render json: {
        ok: true,
        eventos: [],
        resumen: {
          total: 0, usuarios_unicos: 0, logins: 0,
          logins_fallidos: 0, exports: 0, view_opens: 0,
        },
        top_usuarios: [],
        top_modulos: [],
        filtros: { desde: desde_param, hasta: hasta_param },
      }
    end

    # GET /api/audit/export
    def export
      require_admin!
      return if performed?
      render json: { ok: false, error: "Audit export Excel: pendiente (Bloque I)" },
             status: :service_unavailable
    end
  end
end

# ─── app/controllers/api/resumen_general_controller.rb ─────────────────
module Api
  class ResumenGeneralController < ApplicationController
    before_action :authenticate_user!

    # GET /api/resumen-general
    # Devuelve estructura vacía pero válida con las áreas definidas, para
    # que el frontend renderice las tarjetas sin errores hasta que
    # implementemos el cálculo real en el Bloque I.
    def index
      render json: {
        ok: true,
        filtros: {
          desde: desde_param, hasta: hasta_param,
          pais: pais_param, pais_iso: iso_pais,
        },
        modulos: {},
        areas: {
          "monitoreo"   => { "nombre" => "Monitoreo",               "color" => "#1d4ed8", "icono" => "🔵" },
          "sac_recl"    => { "nombre" => "SAC / Reclamaciones",     "color" => "#7c3aed", "icono" => "🟣" },
          "comercial"   => { "nombre" => "Comercial",               "color" => "#16a34a", "icono" => "🟢" },
          "operaciones" => { "nombre" => "Operaciones",             "color" => "#ea580c", "icono" => "🟠" },
          "sac_act"     => { "nombre" => "SAC / Activaciones",      "color" => "#ca8a04", "icono" => "🟡" },
        },
        generado_en: Time.now.utc.strftime("%Y-%m-%d %H:%M:%S"),
        mensaje: "Resumen 360 pendiente de migrar a Rails (Bloque I)",
      }
    end
  end
end
