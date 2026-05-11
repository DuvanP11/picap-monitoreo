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
        actuales << email unless actuales.include?(email)
        vis = forzar_privado ? "privado" : (r["visibilidad"] || "publico")
        data = {
          titulo: r["titulo"], descripcion: r["descripcion"],
          tipo: r["tipo"], subtipo: r["subtipo"], categoria: r["categoria"],
          contenido: r["contenido"], url: r["url"], tags: r["tags"],
          visibilidad: vis, compartido_con: actuales.uniq.join(","),
        }
        ch.query(insert_sql(rid, data, r["creado_en"], ahora_iso, r["creado_por"], r["activo"].to_i))
        afectados += 1
      end
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
  end
end
