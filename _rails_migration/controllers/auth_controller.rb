# app/controllers/api/auth_controller.rb
module Api
  class AuthController < ApplicationController

    # v3.0 (May 2026): tamaño máximo permitido para la foto de perfil base64.
    # 700_000 chars de base64 ≈ 525 KB raw. Suficiente para una foto 256x256
    # JPEG q=0.85 (típico ~40-100 KB). El frontend ya redimensiona, esto es
    # un límite defensivo.
    MAX_FOTO_B64_LEN = 700_000

    # POST /api/login
    def login
      usuario  = params[:usuario].to_s.strip.downcase
      password = params[:password].to_s.strip
      return render json: { ok: false, error: "Usuario y contraseña requeridos" } if usuario.blank? || password.blank?

      rows = ch.query(QueriesService.format(QueriesService::Q_USER_BY_USUARIO, usuario: usuario))
      return render json: { ok: false, error: "Usuario no encontrado" }, status: :unauthorized if rows.empty?

      row = rows.first
      hash_esperado = AuthService.hash_password(password)
      return render json: { ok: false, error: "Contraseña incorrecta" }, status: :unauthorized if row["password_hash"] != hash_esperado

      token = AuthService.crear_token(usuario, row["rol"])

      render json: {
        ok:      true,
        token:   token,
        usuario: usuario,
        nombre:  row["nombre"],
        email:   row["email"],
        rol:     row["rol"],
        acceso:  acceso_para_rol(row["rol"]),
        foto:    leer_foto_perfil(usuario),
      }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/logout
    def logout
      # Con HMAC stateless no hay nada que invalidar en el servidor.
      # El cliente borra el token de localStorage.
      render json: { ok: true }
    end

    # GET /api/me
    def me
      return unless authenticate_user!

      rows = ch.query(QueriesService.format(QueriesService::Q_USER_BY_USUARIO, usuario: current_usuario))
      return render json: { ok: false, error: "Usuario no encontrado" }, status: :not_found if rows.empty?

      row = rows.first
      render json: {
        ok:      true,
        usuario: current_usuario,
        nombre:  row["nombre"],
        email:   row["email"],
        rol:     row["rol"],
        acceso:  acceso_para_rol(row["rol"]),
        foto:    leer_foto_perfil(current_usuario),
      }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/me/foto — sube/actualiza la foto de perfil del user actual.
    # Body: { foto: 'data:image/jpeg;base64,...' }
    # Resp: { ok: true, foto: '...' }
    def subir_foto
      return unless authenticate_user!
      foto = params[:foto].to_s
      if foto.empty?
        return render json: { ok: false, error: "Falta el parámetro 'foto'" }, status: :bad_request
      end
      unless foto.start_with?("data:image/")
        return render json: { ok: false, error: "La foto debe ser una data URL de imagen (data:image/...)" }, status: :bad_request
      end
      if foto.length > MAX_FOTO_B64_LEN
        return render json: { ok: false, error: "La foto excede el tamaño máximo permitido (~525KB). Reduce su tamaño antes de subir." }, status: :payload_too_large
      end
      # Escape para SQL (CH usa '' para escapar '), y removemos backslashes peligrosos
      foto_safe = foto.gsub("\\", "\\\\\\\\").gsub("'", "''")
      ch.query(<<~SQL)
        ALTER TABLE picapmongoprod.dashboard_users
        UPDATE foto_perfil = '#{foto_safe}'
        WHERE usuario = '#{current_usuario.gsub("'", "''")}'
      SQL
      render json: { ok: true, foto: foto }
    rescue => e
      Rails.logger.error("[AuthController#subir_foto] #{e.class}: #{e.message}")
      # Si el error es por columna inexistente, dar hint claro
      msg = if e.message.to_s.include?("foto_perfil") || e.message.to_s.include?("Unknown identifier")
              "La columna 'foto_perfil' no existe aún en dashboard_users. Pide a Fernando ejecutar: ALTER TABLE picapmongoprod.dashboard_users ADD COLUMN foto_perfil String DEFAULT '';"
            else
              e.message
            end
      render json: { ok: false, error: msg }, status: :internal_server_error
    end

    # DELETE /api/me/foto — borra la foto de perfil del user actual.
    def eliminar_foto
      return unless authenticate_user!
      ch.query(<<~SQL)
        ALTER TABLE picapmongoprod.dashboard_users
        UPDATE foto_perfil = ''
        WHERE usuario = '#{current_usuario.gsub("'", "''")}'
      SQL
      render json: { ok: true, foto: "" }
    rescue => e
      Rails.logger.error("[AuthController#eliminar_foto] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    # Lee foto_perfil con rescue. Si la columna no existe aún (deploy nuevo
    # sin ALTER TABLE corrido), devuelve '' en vez de romper /me y /login.
    def leer_foto_perfil(usuario)
      rows = ch.query(QueriesService.format(QueriesService::Q_USER_FOTO, usuario: usuario))
      (rows.first || {})["foto_perfil"].to_s
    rescue => e
      Rails.logger.warn("[AuthController#leer_foto_perfil] foto_perfil no disponible: #{e.message}")
      ""
    end

    public

    # POST /api/register
    def register
      return unless authenticate_user!
      return unless require_admin!

      usuario  = params[:usuario].to_s.strip.downcase
      password = params[:password].to_s.strip
      nombre   = params[:nombre].to_s.strip
      email    = params[:email].to_s.strip
      rol      = params[:rol].to_s.strip

      return render json: { ok: false, error: "Todos los campos son requeridos" } if [usuario, password, nombre, rol].any?(&:blank?)

      # Verificar que no existe
      existente = ch.query(QueriesService.format(QueriesService::Q_USER_BY_USUARIO, usuario: usuario))
      return render json: { ok: false, error: "El usuario ya existe" } if existente.any?

      hash = AuthService.hash_password(password)
      ch.query(<<~SQL)
        INSERT INTO picapmongoprod.dashboard_users
          (usuario, password_hash, nombre, email, rol, creado_en, activo)
        VALUES
          ('#{usuario}', '#{hash}', '#{nombre}', '#{email}', '#{rol}', now(), 1)
      SQL

      # v3.3.17: notificar nuevo registro a equipo de verificaciones
      notificar_nuevo_registro(usuario: usuario, nombre: nombre, email: email, rol: rol, registrado_por: current_usuario)

      render json: { ok: true, mensaje: "Usuario #{usuario} creado correctamente" }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # v3.3.17: envía email a verificaciones@pibox.app y dperilla@pibox.app
    # cuando se crea un usuario nuevo. En Thread.new para no bloquear.
    def notificar_nuevo_registro(usuario:, nombre:, email:, rol:, registrado_por:)
      destinatarios = ["verificaciones@pibox.app", "dperilla@pibox.app"]
      Thread.new do
        begin
          subject = "🆕 Nuevo usuario en Picap Monitoreo: #{nombre} (#{rol})"
          html    = construir_html_nuevo_registro(usuario, nombre, email, rol, registrado_por)
          ResendMailerService.send_email(to: destinatarios, subject: subject, html: html)
        rescue => e
          Rails.logger.warn("[AuthController#notificar_nuevo_registro] #{e.class}: #{e.message}")
        end
      end
    end

    def construir_html_nuevo_registro(usuario, nombre, email, rol, registrado_por)
      portal_url = "https://monitoring.picap.io"
      rol_pill = %Q(<span style="background:#7c3aed;color:#fff;padding:3px 10px;border-radius:12px;font-size:11px;font-weight:700">#{ERB::Util.h(rol.upcase)}</span>)
      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#F5F3FF;color:#1F2937;">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F5F3FF;padding:20px 0">
            <tr><td align="center">
              <table cellpadding="0" cellspacing="0" border="0" width="620" style="background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
                <tr><td style="background:linear-gradient(90deg,#0e7490,#0369a1);padding:24px 28px;color:#fff">
                  <div style="font-size:20px;font-weight:700">🆕 Nuevo usuario registrado</div>
                  <div style="font-size:12px;opacity:0.92;margin-top:4px">Notificación de verificación · Picap Monitoreo</div>
                </td></tr>
                <tr><td style="padding:28px">
                  <p style="margin:0 0 16px;font-size:14px">Hola equipo,</p>
                  <p style="margin:0 0 16px;font-size:14px;line-height:1.5">Se acaba de registrar un nuevo usuario en el portal de monitoreo. Por favor, verifiquen que el rol asignado es el correcto:</p>
                  <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F5F3FF;border-left:4px solid #0e7490;padding:16px;border-radius:4px;margin:12px 0">
                    <tr><td style="font-size:13px;color:#374151">
                      <div style="margin-bottom:6px"><strong>👤 Nombre:</strong> #{ERB::Util.h(nombre)}</div>
                      <div style="margin-bottom:6px"><strong>🔑 Usuario:</strong> <code style="background:#fff;padding:2px 6px;border-radius:3px">#{ERB::Util.h(usuario)}</code></div>
                      <div style="margin-bottom:6px"><strong>📧 Email:</strong> #{ERB::Util.h(email.to_s.empty? ? '(sin email)' : email)}</div>
                      <div style="margin-bottom:6px"><strong>🎭 Rol:</strong> #{rol_pill}</div>
                      <div style="margin-bottom:0"><strong>✍️ Registrado por:</strong> #{ERB::Util.h(registrado_por)}</div>
                      <div style="margin-top:6px;font-size:11px;color:#6B7280">📅 #{Time.now.strftime('%d/%m/%Y %H:%M')}</div>
                    </td></tr>
                  </table>
                  <a href="#{portal_url}" style="display:inline-block;background:#0e7490;color:#fff;padding:10px 22px;border-radius:6px;text-decoration:none;font-weight:600;margin-top:14px">⚙️ Ir al Panel Admin</a>
                  <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">Si el rol asignado no es correcto, podés cambiarlo desde el Panel de Administración → Usuarios.</p>
                </td></tr>
                <tr><td style="background:#F9FAFB;padding:12px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                  Notificación automática · <strong style="color:#0e7490">Picap Monitoreo</strong>
                </td></tr>
              </table>
            </td></tr>
          </table>
        </body></html>
      HTML
    end

    # POST /api/cambiar_password
    def cambiar_password
      return unless authenticate_user!

      pwd_actual  = params[:password_actual].to_s.strip
      pwd_nueva   = params[:password_nueva].to_s.strip
      return render json: { ok: false, error: "La nueva contraseña debe tener al menos 6 caracteres" } if pwd_nueva.length < 6

      rows = ch.query(QueriesService.format(QueriesService::Q_USER_BY_USUARIO, usuario: current_usuario))
      return render json: { ok: false, error: "Usuario no encontrado" } if rows.empty?

      row = rows.first
      return render json: { ok: false, error: "La contraseña actual es incorrecta" } if row["password_hash"] != AuthService.hash_password(pwd_actual)

      hash_nueva = AuthService.hash_password(pwd_nueva)
      ch.query(<<~SQL)
        INSERT INTO picapmongoprod.dashboard_users
          (usuario, password_hash, nombre, email, rol, creado_en, activo)
        VALUES
          ('#{current_usuario}', '#{hash_nueva}', '#{row["nombre"]}', '#{row["email"]}', '#{row["rol"]}', now(), 1)
      SQL

      render json: { ok: true, mensaje: "Contraseña actualizada correctamente" }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/solicitar_reset
    def solicitar_reset
      usuario = params[:usuario].to_s.strip.downcase
      return render json: { ok: false, error: "Ingresa tu usuario" } if usuario.blank?

      rows = ch.query(QueriesService.format(QueriesService::Q_USER_BY_USUARIO, usuario: usuario))
      # Por seguridad, no revelar si el usuario existe o no
      return render json: { ok: true, mensaje: "Si el usuario existe, recibirás un correo en los próximos minutos." } if rows.empty?

      row   = rows.first
      email = row["email"].to_s
      return render json: { ok: false, error: "Este usuario no tiene email registrado. Contacta al administrador." } if email.blank?

      reset_token = AuthService.crear_reset_token(usuario, email)
      reset_url   = "#{EmailService::APP_URL}?reset_token=#{reset_token}"
      cuerpo      = EmailService.cuerpo_reset_password(nombre: row["nombre"], usuario: usuario, reset_url: reset_url)

      ok, err = EmailService.enviar(destinatario: email, asunto: "Restablece tu contraseña — Picap Monitoreo", cuerpo_html: cuerpo)
      email_masked = "#{email[0..1]}***#{email[email.index('@')..]}"
      render json: { ok: true, mensaje: ok ? "Correo enviado a #{email_masked}" : "Si el usuario existe, recibirás un correo en los próximos minutos." }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/reset_password
    def reset_password
      token     = params[:reset_token].to_s.strip
      pwd_nueva = params[:password_nueva].to_s.strip
      return render json: { ok: false, error: "Datos incompletos" } if token.blank? || pwd_nueva.blank?
      return render json: { ok: false, error: "La contraseña debe tener al menos 6 caracteres" } if pwd_nueva.length < 6

      payload = AuthService.verificar_reset_token(token)
      return render json: { ok: false, error: "El enlace expiró o es inválido. Solicita uno nuevo." } unless payload

      usuario = payload[:usuario]
      rows    = ch.query(QueriesService.format(QueriesService::Q_USER_BY_USUARIO, usuario: usuario))
      return render json: { ok: false, error: "Usuario no encontrado" } if rows.empty?

      row        = rows.first
      hash_nueva = AuthService.hash_password(pwd_nueva)
      ch.query(<<~SQL)
        INSERT INTO picapmongoprod.dashboard_users
          (usuario, password_hash, nombre, email, rol, creado_en, activo)
        VALUES
          ('#{usuario}', '#{hash_nueva}', '#{row["nombre"]}', '#{row["email"]}', '#{row["rol"]}', now(), 1)
      SQL

      render json: { ok: true, mensaje: "Contraseña restablecida. Ya puedes iniciar sesión." }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    ROLES_ACCESO = {
      "admin"      => %w[monitoreo conversor estafa bloqueos pagos recaudos retencion auditoria cashout rf pibox admin],
      "monitoreo"  => %w[monitoreo conversor estafa bloqueos recaudos retencion rf],
      "sac"        => %w[estafa bloqueos rf],
      "financiero" => %w[pagos recaudos retencion auditoria],
      "pibox"      => %w[recaudos auditoria pibox],
      "pendiente"  => [],
    }.freeze

    def acceso_para_rol(rol)
      ROLES_ACCESO[rol] || []
    end
  end
end
