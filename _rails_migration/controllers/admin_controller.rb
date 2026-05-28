# app/controllers/api/admin_controller.rb
module Api
  class AdminController < ApplicationController
    before_action :authenticate_user!
    before_action :require_admin!

    # GET /api/admin/usuarios
    # v3.3.17: agregamos foto_perfil. Si la columna no existe (deploy viejo),
    # caemos al fallback sin foto sin romper la pantalla.
    def usuarios
      rows = begin
        ch.query(<<~SQL)
          SELECT usuario, nombre, email, rol,
                 formatDateTime(creado_en, '%Y-%m-%d %H:%M') AS creado_en,
                 foto_perfil
          FROM picapmongoprod.dashboard_users FINAL
          WHERE activo = 1
          ORDER BY creado_en DESC
        SQL
      rescue => e
        Rails.logger.warn("[AdminController#usuarios] foto_perfil no disponible, fallback: #{e.message}")
        ch.query(QueriesService::Q_ALL_USERS).map { |r| r.merge("foto_perfil" => "") }
      end
      render json: { ok: true, usuarios: rows.map { |r|
        { usuario: r["usuario"], nombre: r["nombre"], email: r["email"],
          rol: r["rol"], creado_en: r["creado_en"].to_s,
          foto_perfil: r["foto_perfil"].to_s,
          tiene_foto: !r["foto_perfil"].to_s.strip.empty? }
      }}
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/admin/usuario/:usuario/perfil
    # v3.3.17: detalle de perfil de un usuario (para modal Ver Perfil).
    def usuario_perfil
      usuario_target = params[:usuario].to_s.strip
      return render json: { ok: false, error: "Usuario requerido" }, status: :bad_request if usuario_target.empty?

      u_safe = usuario_target.gsub("'", "''")
      r = begin
        ch.query(<<~SQL).first
          SELECT usuario, nombre, email, rol,
                 formatDateTime(creado_en, '%Y-%m-%d %H:%M') AS creado_en,
                 activo, foto_perfil
          FROM picapmongoprod.dashboard_users FINAL
          WHERE usuario = '#{u_safe}' LIMIT 1
        SQL
      rescue
        ch.query(QueriesService.format(QueriesService::Q_USER_BY_USUARIO, usuario: usuario_target)).first&.merge("foto_perfil" => "")
      end
      return render json: { ok: false, error: "Usuario no encontrado" }, status: :not_found unless r

      # Stats opcionales: nº de tareas en cronograma, recursos creados, etc.
      stats = { tareas_cronograma: 0, recursos_creados: 0 }
      begin
        stats[:tareas_cronograma] = ch.query(
          "SELECT count() AS c FROM picapmongoprod.cronograma_tareas FINAL WHERE creado_por='#{u_safe}'"
        ).first.to_h["c"].to_i
      rescue; end
      begin
        stats[:recursos_creados] = ch.query(
          "SELECT count() AS c FROM picapmongoprod.dashboard_recursos FINAL WHERE creado_por='#{u_safe}' AND activo=1"
        ).first.to_h["c"].to_i
      rescue; end

      render json: {
        ok: true,
        perfil: {
          usuario:    r["usuario"],
          nombre:     r["nombre"],
          email:      r["email"],
          rol:        r["rol"],
          creado_en:  r["creado_en"].to_s,
          activo:     r["activo"].to_i,
          foto_perfil: r["foto_perfil"].to_s,
          tiene_foto: !r["foto_perfil"].to_s.strip.empty?,
        },
        stats: stats,
      }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/admin/editar_usuario
    def editar_usuario
      usuario = params[:usuario].to_s.strip
      nombre  = params[:nombre].to_s.strip
      email   = params[:email].to_s.strip
      rol     = params[:rol].to_s.strip
      return render json: { ok: false, error: "Datos incompletos" } if [usuario, nombre, rol].any?(&:blank?)

      rows = ch.query(QueriesService.format(QueriesService::Q_USER_BY_USUARIO, usuario: usuario))
      return render json: { ok: false, error: "Usuario no encontrado" } if rows.empty?

      row = rows.first
      ch.query(<<~SQL)
        INSERT INTO picapmongoprod.dashboard_users
          (usuario, password_hash, nombre, email, rol, creado_en, activo)
        VALUES
          ('#{usuario}', '#{row["password_hash"]}', '#{nombre}', '#{email}', '#{rol}', now(), 1)
      SQL

      render json: { ok: true, mensaje: "Usuario actualizado correctamente" }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/admin/eliminar_usuario
    def eliminar_usuario
      usuario = params[:usuario].to_s.strip
      return render json: { ok: false, error: "No puedes eliminarte a ti mismo" } if usuario == current_usuario

      rows = ch.query(QueriesService.format(QueriesService::Q_USER_BY_USUARIO, usuario: usuario))
      return render json: { ok: false, error: "Usuario no encontrado" } if rows.empty?

      row = rows.first
      ch.query(<<~SQL)
        INSERT INTO picapmongoprod.dashboard_users
          (usuario, password_hash, nombre, email, rol, creado_en, activo)
        VALUES
          ('#{usuario}', '#{row["password_hash"]}', '#{row["nombre"]}', '#{row["email"]}', '#{row["rol"]}', now(), 0)
      SQL

      render json: { ok: true, mensaje: "Usuario eliminado correctamente" }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/admin/asignar_rol
    def asignar_rol
      usuario = params[:usuario].to_s.strip
      rol     = params[:rol].to_s.strip
      return render json: { ok: false, error: "Datos incompletos" } if usuario.blank? || rol.blank?

      rows = ch.query(QueriesService.format(QueriesService::Q_USER_BY_USUARIO, usuario: usuario))
      return render json: { ok: false, error: "Usuario no encontrado" } if rows.empty?

      row = rows.first
      ch.query(<<~SQL)
        INSERT INTO picapmongoprod.dashboard_users
          (usuario, password_hash, nombre, email, rol, creado_en, activo)
        VALUES
          ('#{usuario}', '#{row["password_hash"]}', '#{row["nombre"]}', '#{row["email"]}', '#{rol}', now(), 1)
      SQL

      render json: { ok: true, mensaje: "Rol actualizado a #{rol}" }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end
  end
end
