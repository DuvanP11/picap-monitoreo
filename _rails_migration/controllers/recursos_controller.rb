# app/controllers/api/recursos_controller.rb
# Biblioteca interna de recursos compartidos del equipo.
# Tabla: picapmongoprod.dashboard_recursos
# Lectura: cualquier sesión válida (con filtro de visibilidad).
# Escritura (POST/PUT/DELETE/share): solo admins.

module Api
  class RecursosController < ApplicationController
    before_action :authenticate_user!

    TIPOS    = %w[query enlace excel nota].freeze
    SUBTIPOS = %w[
      clickhouse bigquery snowflake mysql postgres sql_server otro_query
      drive sheets docs notion confluence web otro_enlace
      excel_local excel_drive csv
      nota procedimiento contacto
    ].freeze

    # GET /api/recursos?tipo=&categoria=&q=
    def index
      filtro_tipo = params[:tipo].to_s.strip.downcase
      filtro_cat  = params[:categoria].to_s.strip
      filtro_q    = params[:q].to_s.strip

      where = ["activo = 1"]
      where << "tipo = '#{filtro_tipo.gsub("'", "''")}'" if TIPOS.include?(filtro_tipo)
      where << "categoria = '#{filtro_cat.gsub("'", "''")}'" if filtro_cat.present?
      if filtro_q.present?
        q = filtro_q.gsub("'", "''").downcase
        where << "(positionCaseInsensitive(titulo,'#{q}')>0 " \
                 "OR positionCaseInsensitive(descripcion,'#{q}')>0 " \
                 "OR positionCaseInsensitive(tags,'#{q}')>0 " \
                 "OR positionCaseInsensitive(contenido,'#{q}')>0)"
      end

      sql = <<~SQL
        SELECT id, titulo, descripcion, tipo, subtipo, categoria,
               contenido, url, tags, creado_por,
               formatDateTime(creado_en,      '%Y-%m-%d %H:%M') AS creado_en,
               formatDateTime(actualizado_en, '%Y-%m-%d %H:%M') AS actualizado_en,
               activo, visibilidad, compartido_con
        FROM picapmongoprod.dashboard_recursos FINAL
        WHERE #{where.join(' AND ')}
        ORDER BY actualizado_en DESC
        LIMIT 1000
      SQL

      rows = ch.query(sql)
      email_actual = obtener_email_usuario(current_usuario)

      recursos   = []
      categorias = Set.new
      rows.each do |r|
        next unless puede_ver?(r, email_actual)
        compartidos = (r["compartido_con"] || "").to_s.split(",").map(&:strip).map(&:downcase).reject(&:empty?).uniq
        r["compartido_emails"] = compartidos
        r["es_propio"]         = (r["creado_por"] == current_usuario)
        categorias << r["categoria"] if r["categoria"].to_s.strip.present?
        recursos << r
      end

      render json: limpiar({
        ok: true,
        recursos:   recursos,
        categorias: categorias.to_a.sort,
        yo:         { usuario: current_usuario, email: email_actual, rol: current_rol },
      })
    rescue => e
      Rails.logger.error("[RecursosController] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/recursos/visibilidad — ¿el usuario tiene al menos 1 recurso accesible?
    # v3.3.16: usado por el frontend para decidir si mostrar 'Biblioteca de Recursos'
    # en el home y sidebar. Si el user no tiene NADA compartido, no aparece el botón.
    def visibilidad
      if current_rol == "admin"
        # Admin ve todo
        row = ch.query(
          "SELECT count() AS c FROM picapmongoprod.dashboard_recursos FINAL WHERE activo = 1"
        ).first
        total = (row && row["c"]).to_i
      else
        email_actual = obtener_email_usuario(current_usuario)
        e_safe = email_actual.gsub("'", "''")
        u_safe = current_usuario.to_s.gsub("'", "''")
        sql = <<~SQL
          SELECT count() AS c
          FROM picapmongoprod.dashboard_recursos FINAL
          WHERE activo = 1
            AND (visibilidad != 'privado'
                 OR creado_por = '#{u_safe}'
                 OR (notEmpty('#{e_safe}') AND positionCaseInsensitive(compartido_con, '#{e_safe}') > 0))
        SQL
        row = ch.query(sql).first
        total = (row && row["c"]).to_i
      end
      render json: { ok: true, tiene_acceso: total > 0, total: total }
    rescue => e
      Rails.logger.warn("[RecursosController#visibilidad] #{e.class}: #{e.message}")
      # En caso de error, dejamos visible (fail-open conservador). El usuario
      # podrá entrar y ver 'no hay recursos' que es claro.
      render json: { ok: true, tiene_acceso: true, total: 0, error: e.message }
    end

    # GET /api/recursos/usuarios-portal — selector de usuarios para compartir
    def usuarios_portal
      require_admin!
      return if performed?
      rows = ch.query(<<~SQL)
        SELECT usuario, nombre, email, rol
        FROM picapmongoprod.dashboard_users FINAL
        WHERE activo = 1 AND rol != 'pendiente'
        ORDER BY nombre
      SQL
      lista = rows.reject { |u|
        u["usuario"] == current_usuario || u["email"].to_s.strip.empty?
      }.map { |u|
        { usuario: u["usuario"], nombre: u["nombre"] || u["usuario"],
          email:   u["email"].to_s.strip.downcase, rol: u["rol"] }
      }
      render json: { ok: true, usuarios: lista }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/recursos — crear
    def create
      require_admin!
      return if performed?
      data, err = normalizar_payload(params.to_unsafe_h)
      return render json: { ok: false, error: err }, status: :bad_request if err

      rid = SecureRandom.uuid
      ahora_iso = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")
      ch.query(insert_sql(rid, data, ahora_iso, ahora_iso, current_usuario))
      render json: { ok: true, id: rid }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # PUT /api/recursos/:id — editar
    def update
      require_admin!
      return if performed?
      rid = params[:id].to_s
      return render json: { ok: false, error: "ID inválido" }, status: :bad_request unless rid.match?(/\A[0-9a-f-]+\z/i)
      data, err = normalizar_payload(params.to_unsafe_h)
      return render json: { ok: false, error: err }, status: :bad_request if err

      existente = ch.query(<<~SQL).first
        SELECT creado_por, creado_en, activo, visibilidad, compartido_con
        FROM picapmongoprod.dashboard_recursos FINAL WHERE id = '#{rid}' LIMIT 1
      SQL
      return render json: { ok: false, error: "Recurso no encontrado" }, status: :not_found unless existente

      vis_final  = params.key?(:visibilidad)    ? data[:visibilidad]    : (existente["visibilidad"] || "publico")
      comp_final = params.key?(:compartido_con) ? data[:compartido_con] : (existente["compartido_con"] || "")
      data = data.merge(visibilidad: vis_final, compartido_con: comp_final)

      ahora_iso = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")
      creado_en = existente["creado_en"].to_s
      creado_en = ahora_iso if creado_en.empty?
      ch.query(insert_sql(rid, data, creado_en, ahora_iso, existente["creado_por"] || current_usuario))
      render json: { ok: true }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # DELETE /api/recursos/:id
    def destroy
      require_admin!
      return if performed?
      rid = params[:id].to_s
      return render json: { ok: false, error: "ID inválido" }, status: :bad_request unless rid.match?(/\A[0-9a-f-]+\z/i)
      ch.query("ALTER TABLE picapmongoprod.dashboard_recursos DELETE WHERE id = '#{rid}'")
      render json: { ok: true }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/recursos/:id/share — cambia visibilidad y emails compartidos
    def share
      require_admin!
      return if performed?
      rid = params[:id].to_s
      return render json: { ok: false, error: "ID inválido" }, status: :bad_request unless rid.match?(/\A[0-9a-f-]+\z/i)

      vis = params[:visibilidad].to_s.downcase
      vis = "privado" unless %w[publico privado].include?(vis)
      raw_emails = Array(params[:emails])
      raw_emails = raw_emails.first.to_s.split(",") if raw_emails.size == 1 && raw_emails.first.to_s.include?(",")
      emails_validos = raw_emails.map { |e| e.to_s.strip.downcase }.reject(&:empty?).select { |e| e.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) }.uniq
      compartido_csv = emails_validos.join(",")[0, 2000]

      r = ch.query(<<~SQL).first
        SELECT titulo, descripcion, tipo, subtipo, categoria, contenido, url, tags,
               creado_por, formatDateTime(creado_en,'%Y-%m-%d %H:%M:%S') AS creado_en, activo
        FROM picapmongoprod.dashboard_recursos FINAL WHERE id = '#{rid}' LIMIT 1
      SQL
      return render json: { ok: false, error: "Recurso no encontrado" }, status: :not_found unless r

      data = {
        titulo: r["titulo"], descripcion: r["descripcion"],
        tipo: r["tipo"], subtipo: r["subtipo"], categoria: r["categoria"],
        contenido: r["contenido"], url: r["url"], tags: r["tags"],
        visibilidad: vis, compartido_con: compartido_csv,
      }
      ahora_iso = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")
      ch.query(insert_sql(rid, data, r["creado_en"], ahora_iso, r["creado_por"], r["activo"].to_i))
      # v3.3.17: notificación por email a los NUEVOS destinatarios
      emails_previos = (r["compartido_con"] || "").to_s.split(",").map(&:strip).map(&:downcase).reject(&:empty?)
      nuevos = emails_validos - emails_previos
      notificar_compartido(r["titulo"], r["tipo"], r["categoria"], r["url"], nuevos) if nuevos.any?
      render json: { ok: true, visibilidad: vis, compartido_con: emails_validos }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/recursos/share-bulk
    def share_bulk
      require_admin!
      return if performed?
      email = params[:email].to_s.strip.downcase
      rids  = Array(params[:recurso_ids]).map(&:to_s)
      return render json: { ok: false, error: "Email inválido" }, status: :bad_request unless email.include?("@")
      return render json: { ok: false, error: "Debe enviar al menos un recurso_ids" }, status: :bad_request if rids.empty?

      # Validar que el email pertenezca a un usuario activo
      e_safe = email.gsub("'", "''")
      u = ch.query("SELECT usuario, nombre FROM picapmongoprod.dashboard_users FINAL WHERE lower(email)='#{e_safe}' AND activo=1 LIMIT 1").first
      return render json: { ok: false, error: "No hay usuario activo con email #{email}" }, status: :not_found unless u

      forzar_privado = !!params[:forzar_privado]
      afectados = 0
      recursos_nuevos = []  # v3.3.17: lista de recursos donde ESTE email es nuevo destinatario
      ahora_iso = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")
      rids.each do |rid|
        next unless rid.match?(/\A[0-9a-f-]+\z/i)
        r = ch.query(<<~SQL).first
          SELECT titulo, descripcion, tipo, subtipo, categoria, contenido, url, tags,
                 creado_por, formatDateTime(creado_en,'%Y-%m-%d %H:%M:%S') AS creado_en,
                 activo, visibilidad, compartido_con
          FROM picapmongoprod.dashboard_recursos FINAL WHERE id = '#{rid}' LIMIT 1
        SQL
        next unless r
        actuales = (r["compartido_con"] || "").to_s.split(",").map(&:strip).map(&:downcase).reject(&:empty?)
        es_nuevo = !actuales.include?(email)
        actuales << email if es_nuevo
        vis = forzar_privado ? "privado" : (r["visibilidad"] || "publico")
        data = {
          titulo: r["titulo"], descripcion: r["descripcion"],
          tipo: r["tipo"], subtipo: r["subtipo"], categoria: r["categoria"],
          contenido: r["contenido"], url: r["url"], tags: r["tags"],
          visibilidad: vis, compartido_con: actuales.uniq.join(","),
        }
        ch.query(insert_sql(rid, data, r["creado_en"], ahora_iso, r["creado_por"], r["activo"].to_i))
        afectados += 1
        recursos_nuevos << r if es_nuevo
      end
      # v3.3.17: una sola notificación con los N recursos nuevos compartidos
      notificar_compartido_bulk(email, u["nombre"], recursos_nuevos) if recursos_nuevos.any?
      render json: { ok: true, afectados: afectados,
                     destinatario: { email: email, usuario: u["usuario"], nombre: u["nombre"] } }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def normalizar_payload(p)
      titulo = p["titulo"].to_s.strip
      return [nil, "El título es obligatorio"] if titulo.empty?
      tipo = p["tipo"].to_s.strip.downcase
      return [nil, "Tipo inválido"] unless TIPOS.include?(tipo)
      subtipo = p["subtipo"].to_s.strip.downcase
      return [nil, "Subtipo inválido"] if !subtipo.empty? && !SUBTIPOS.include?(subtipo)
      vis = (p["visibilidad"] || "publico").to_s.downcase
      vis = "publico" unless %w[publico privado].include?(vis)
      raw_comp = p["compartido_con"]
      raw_comp = raw_comp.join(",") if raw_comp.is_a?(Array)
      compartidos = raw_comp.to_s.split(",").map { |e| e.strip.downcase }.reject(&:empty?).uniq.join(",")[0, 2000]
      [{
        titulo:         titulo[0, 200],
        descripcion:    p["descripcion"].to_s.strip[0, 2000],
        tipo:           tipo,
        subtipo:        subtipo,
        categoria:      p["categoria"].to_s.strip[0, 100],
        contenido:      p["contenido"].to_s,
        url:            p["url"].to_s.strip[0, 1000],
        tags:           p["tags"].to_s.strip[0, 500],
        visibilidad:    vis,
        compartido_con: compartidos,
      }, nil]
    end

    def insert_sql(rid, data, creado_en, actualizado_en, creado_por, activo = 1)
      esc = ->(v) { v.to_s.gsub("\\", "\\\\\\\\").gsub("'", "''") }
      <<~SQL
        INSERT INTO picapmongoprod.dashboard_recursos
        (id, titulo, descripcion, tipo, subtipo, categoria, contenido, url, tags,
         creado_por, creado_en, actualizado_en, activo, visibilidad, compartido_con)
        VALUES
        ('#{rid}', '#{esc.(data[:titulo])}', '#{esc.(data[:descripcion])}',
         '#{data[:tipo]}', '#{data[:subtipo]}', '#{esc.(data[:categoria])}',
         '#{esc.(data[:contenido])}', '#{esc.(data[:url])}', '#{esc.(data[:tags])}',
         '#{esc.(creado_por.to_s)}', toDateTime('#{creado_en}'), toDateTime('#{actualizado_en}'),
         #{activo.to_i}, '#{data[:visibilidad]}', '#{esc.(data[:compartido_con])}')
      SQL
    end

    def obtener_email_usuario(usuario)
      return "" if usuario.to_s.empty?
      u_safe = usuario.to_s.gsub("'", "''")
      r = ch.query("SELECT email FROM picapmongoprod.dashboard_users FINAL WHERE usuario='#{u_safe}' LIMIT 1").first
      (r && r["email"] || "").to_s.strip.downcase
    rescue
      ""
    end

    def puede_ver?(recurso, email_actual)
      return true if current_rol == "admin"
      vis = (recurso["visibilidad"] || "publico").to_s.downcase
      return true if vis != "privado"
      return true if recurso["creado_por"] == current_usuario
      emails = (recurso["compartido_con"] || "").to_s.split(",").map(&:strip).map(&:downcase)
      email_actual.present? && emails.include?(email_actual)
    end

    # v3.3.17: notifica vía email a los nuevos destinatarios de UN recurso.
    # Cada email es independiente — usa Thread para no bloquear el response.
    def notificar_compartido(titulo, tipo, categoria, url, emails)
      compartido_por = current_usuario.to_s
      Thread.new do
        begin
          html = construir_html_share_uno(titulo, tipo, categoria, url, compartido_por)
          subject = "📚 Picap Monitoreo · Te compartieron un recurso: #{titulo}"
          emails.each do |to|
            begin
              ResendMailerService.send_email(to: to, subject: subject, html: html)
            rescue => e
              Rails.logger.warn("[RecursosController] no se pudo enviar a #{to}: #{e.message}")
            end
          end
        rescue => e
          Rails.logger.error("[RecursosController#notificar_compartido] #{e.class}: #{e.message}")
        end
      end
    end

    # v3.3.17: notifica una sola vez con la lista de N recursos compartidos.
    def notificar_compartido_bulk(email, nombre, recursos)
      compartido_por = current_usuario.to_s
      Thread.new do
        begin
          html = construir_html_share_bulk(nombre, recursos, compartido_por)
          subject = recursos.size == 1 \
            ? "📚 Picap Monitoreo · Te compartieron un recurso: #{recursos.first['titulo']}" \
            : "📚 Picap Monitoreo · Te compartieron #{recursos.size} recursos"
          ResendMailerService.send_email(to: email, subject: subject, html: html)
        rescue => e
          Rails.logger.warn("[RecursosController#notificar_compartido_bulk] #{e.class}: #{e.message}")
        end
      end
    end

    def construir_html_share_uno(titulo, tipo, categoria, url, compartido_por)
      tipo_emoji = { "query" => "🔍", "enlace" => "🔗", "excel" => "📊", "nota" => "📝" }[tipo.to_s] || "📄"
      url_html = (url.to_s.empty? || tipo.to_s == "nota") ? "" :
        %Q(<a href="#{ERB::Util.h(url)}" style="display:inline-block;background:#7c3aed;color:#fff;padding:10px 22px;border-radius:6px;text-decoration:none;font-weight:600;margin-top:14px">🔗 Abrir recurso</a>)
      portal_url = "https://monitoring.picap.io"
      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#F5F3FF;color:#1F2937;">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F5F3FF;padding:20px 0">
            <tr><td align="center">
              <table cellpadding="0" cellspacing="0" border="0" width="600" style="background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
                <tr><td style="background:linear-gradient(90deg,#7c3aed,#5b21b6);padding:24px 28px;color:#fff">
                  <div style="font-size:20px;font-weight:700">📚 Te compartieron un recurso</div>
                  <div style="font-size:12px;opacity:0.92;margin-top:4px">Biblioteca de Recursos · Picap Monitoreo</div>
                </td></tr>
                <tr><td style="padding:28px">
                  <p style="margin:0 0 16px;font-size:14px">Hola,</p>
                  <p style="margin:0 0 16px;font-size:14px;line-height:1.5"><strong>#{ERB::Util.h(compartido_por)}</strong> te compartió un nuevo recurso en la Biblioteca de Recursos del portal de monitoreo:</p>
                  <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F5F3FF;border-left:4px solid #7c3aed;padding:16px;border-radius:4px;margin:12px 0">
                    <tr><td>
                      <div style="font-size:16px;font-weight:700;color:#1F2937">#{tipo_emoji} #{ERB::Util.h(titulo)}</div>
                      #{categoria.to_s.empty? ? "" : %Q(<div style="font-size:12px;color:#6B7280;margin-top:4px">Categoría: <strong>#{ERB::Util.h(categoria)}</strong></div>)}
                    </td></tr>
                  </table>
                  #{url_html}
                  <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">También podés verlo entrando al portal en <a href="#{portal_url}" style="color:#7c3aed">monitoring.picap.io</a> → Biblioteca de Recursos.</p>
                </td></tr>
                <tr><td style="background:#F9FAFB;padding:12px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                  Notificación automática · <strong style="color:#7c3aed">Picap Monitoreo</strong>
                </td></tr>
              </table>
            </td></tr>
          </table>
        </body></html>
      HTML
    end

    def construir_html_share_bulk(nombre, recursos, compartido_por)
      portal_url = "https://monitoring.picap.io"
      filas = recursos.map { |r|
        tipo = r["tipo"].to_s
        tipo_emoji = { "query" => "🔍", "enlace" => "🔗", "excel" => "📊", "nota" => "📝" }[tipo] || "📄"
        url_link = (r["url"].to_s.empty? || tipo == "nota") ? "" :
          %Q(<a href="#{ERB::Util.h(r['url'])}" style="color:#7c3aed;text-decoration:none">↗ Abrir</a>)
        <<~ROW
          <tr>
            <td style="padding:10px 12px;border-bottom:1px solid #E5E7EB">
              <div style="font-size:14px;font-weight:700;color:#1F2937">#{tipo_emoji} #{ERB::Util.h(r['titulo'])}</div>
              <div style="font-size:11px;color:#6B7280;margin-top:2px">#{ERB::Util.h(r['categoria'].to_s)} · #{tipo}</div>
            </td>
            <td style="padding:10px 12px;border-bottom:1px solid #E5E7EB;text-align:right;font-size:12px">#{url_link}</td>
          </tr>
        ROW
      }.join

      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#F5F3FF;color:#1F2937;">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F5F3FF;padding:20px 0">
            <tr><td align="center">
              <table cellpadding="0" cellspacing="0" border="0" width="640" style="background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
                <tr><td style="background:linear-gradient(90deg,#7c3aed,#5b21b6);padding:24px 28px;color:#fff">
                  <div style="font-size:20px;font-weight:700">📚 Te compartieron #{recursos.size} recurso#{recursos.size == 1 ? '' : 's'}</div>
                  <div style="font-size:12px;opacity:0.92;margin-top:4px">Biblioteca de Recursos · Picap Monitoreo</div>
                </td></tr>
                <tr><td style="padding:28px">
                  <p style="margin:0 0 12px;font-size:14px">Hola #{ERB::Util.h(nombre || '')},</p>
                  <p style="margin:0 0 16px;font-size:14px;line-height:1.5"><strong>#{ERB::Util.h(compartido_por)}</strong> te compartió #{recursos.size} recurso#{recursos.size == 1 ? '' : 's'} en la Biblioteca del portal de monitoreo:</p>
                  <table cellpadding="0" cellspacing="0" border="0" width="100%" style="border:1px solid #E5E7EB;border-radius:6px;border-collapse:separate;border-spacing:0;margin:12px 0">
                    #{filas}
                  </table>
                  <a href="#{portal_url}" style="display:inline-block;background:#7c3aed;color:#fff;padding:10px 22px;border-radius:6px;text-decoration:none;font-weight:600;margin-top:14px">📚 Ver en el portal</a>
                  <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">Tip: en el portal podés filtrar la biblioteca por tipo, categoría o buscar por nombre.</p>
                </td></tr>
                <tr><td style="background:#F9FAFB;padding:12px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                  Notificación automática · <strong style="color:#7c3aed">Picap Monitoreo</strong>
                </td></tr>
              </table>
            </td></tr>
          </table>
        </body></html>
      HTML
    end
  end
end
