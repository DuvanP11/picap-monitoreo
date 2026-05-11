# app/controllers/api/audit_controller.rb
# Logs de seguridad/auditoría.
# Tabla: picapmongoprod.dashboard_audit_log (TTL 365 días)

module Api
  class AuditController < ApplicationController
    before_action :authenticate_user!

    TIPOS_VALIDOS = %w[login logout login_failed view_open export button filter api_call other].freeze

    # POST /api/audit/log — registra un evento (best-effort, nunca falla)
    def log
      data = params.to_unsafe_h
      tipo = data["tipo"].to_s.downcase
      tipo = "other" unless TIPOS_VALIDOS.include?(tipo)
      det = data["detalles"]
      det_json = det.is_a?(String) ? det : det.to_json
      esc = ->(v) { v.to_s.gsub("\\", "\\\\\\\\").gsub("'", "''") }
      ip = (request.headers["X-Forwarded-For"] || request.remote_addr || "").to_s.split(",").first.to_s.strip
      ua = request.headers["User-Agent"].to_s[0, 300]
      sql = <<~SQL
        INSERT INTO picapmongoprod.dashboard_audit_log
        (id, ts, usuario, rol, tipo, modulo, accion, detalles, ip, user_agent)
        VALUES
        ('#{SecureRandom.uuid}', now(),
         '#{esc.(current_usuario)}', '#{esc.(current_rol)}',
         '#{tipo}', '#{esc.(data["modulo"].to_s[0,80])}',
         '#{esc.(data["accion"].to_s[0,200])}', '#{esc.(det_json.to_s[0,4000])}',
         '#{esc.(ip[0,64])}', '#{esc.(ua)}')
      SQL
      begin
        ch.query(sql)
      rescue => e
        Rails.logger.warn("[audit#log] #{e.message}")
      end
      render json: { ok: true }
    end

    # GET /api/audit/logs — listar eventos (solo admin)
    def logs
      require_admin!
      return if performed?
      desde   = desde_param
      hasta   = hasta_param
      usuario = params[:usuario].to_s.strip
      tipo    = params[:tipo].to_s.strip.downcase
      modulo  = params[:modulo].to_s.strip
      q       = params[:q].to_s.strip
      limit   = [[params[:limit].to_i, 1].max, 5000].min
      limit   = 500 if limit == 0

      where = [
        "ts >= toDateTime('#{desde} 00:00:00')",
        "ts <= toDateTime('#{hasta} 23:59:59')",
      ]
      if usuario.present?
        u_safe = usuario.gsub("'", "''")
        where << "positionCaseInsensitive(usuario, '#{u_safe}') > 0"
      end
      where << "tipo = '#{tipo}'" if TIPOS_VALIDOS.include?(tipo)
      if modulo.present?
        m_safe = modulo.gsub("'", "''")
        where << "modulo = '#{m_safe}'"
      end
      if q.present?
        q_safe = q.gsub("'", "''")
        where << "(positionCaseInsensitive(accion,'#{q_safe}')>0 OR positionCaseInsensitive(detalles,'#{q_safe}')>0 OR positionCaseInsensitive(modulo,'#{q_safe}')>0 OR positionCaseInsensitive(usuario,'#{q_safe}')>0)"
      end
      w = where.join(" AND ")

      eventos = ch.query(<<~SQL)
        SELECT id, formatDateTime(ts,'%Y-%m-%d %H:%M:%S') AS ts,
               usuario, rol, tipo, modulo, accion,
               substring(detalles, 1, 1000) AS detalles, ip, user_agent
        FROM picapmongoprod.dashboard_audit_log
        WHERE #{w}
        ORDER BY ts DESC
        LIMIT #{limit}
      SQL

      resumen = ch.query(<<~SQL).first || {}
        SELECT
          count()                          AS total,
          count(DISTINCT usuario)          AS usuarios_unicos,
          countIf(tipo='login')            AS logins,
          countIf(tipo='login_failed')     AS logins_fallidos,
          countIf(tipo='export')           AS exports,
          countIf(tipo='view_open')        AS view_opens
        FROM picapmongoprod.dashboard_audit_log
        WHERE #{w}
      SQL

      top_u = ch.query(<<~SQL)
        SELECT usuario, count() AS n FROM picapmongoprod.dashboard_audit_log
        WHERE #{w} AND usuario != ''
        GROUP BY usuario ORDER BY n DESC LIMIT 5
      SQL
      top_m = ch.query(<<~SQL)
        SELECT modulo, count() AS n FROM picapmongoprod.dashboard_audit_log
        WHERE #{w} AND modulo != ''
        GROUP BY modulo ORDER BY n DESC LIMIT 5
      SQL

      render json: limpiar({
        ok: true,
        eventos: eventos,
        resumen: resumen.transform_values(&:to_i),
        top_usuarios: top_u.map { |r| { usuario: r["usuario"], eventos: r["n"].to_i } },
        top_modulos:  top_m.map { |r| { modulo:  r["modulo"],  eventos: r["n"].to_i } },
        filtros: { desde: desde, hasta: hasta },
      })
    rescue => e
      Rails.logger.error("[AuditController#logs] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/audit/export — pendiente de Excel (Bloque H)
    def export
      require_admin!
      return if performed?
      render json: { ok: false, error: "Excel export: pendiente (Bloque H — openpyxl-equiv)" },
             status: :service_unavailable
    end
  end
end
