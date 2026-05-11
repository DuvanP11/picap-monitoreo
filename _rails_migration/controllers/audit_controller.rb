module Api
  class AuditController < ApplicationController
    before_action :authenticate_user!
    # POST /api/audit/log — no-op silencioso (no llena pantallas con errores)
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
