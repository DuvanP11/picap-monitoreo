# app/controllers/api/cronograma_controller.rb
# Tareas recurrentes (envío de email a una hora fija según frecuencia).
# Tabla: picapmongoprod.cronograma_tareas
# El scheduler real corre en /lib/tasks o un job background (futuro).

module Api
  class CronogramaController < ApplicationController
    before_action :authenticate_user!

    FRECUENCIAS = %w[diaria semanal mensual trimestral semestral anual unica].freeze
    DIAS_VALIDOS = %w[lun mar mie jue vie sab dom].freeze

    # GET /api/cronograma?scope=mias|todas
    # v3.3.14: cada usuario ve solo sus tareas (creado_por). Admin con
    # scope=todas ve todas (vista de equipo). Default: mias.
    def index
      # NOTA: las columnas *_en y ultima_ejecucion están como String en la tabla
      # (Python clickhouse_connect lo toleraba, ClickHouse directo no). Por eso
      # usamos parseDateTimeBestEffortOrNull(toString(...)) — funciona para
      # columnas String o DateTime.
      # OJO: en CH formatDateTime, %M = nombre del mes (May, Jun...). Para
      # minutos hay que usar %i. (Python usaba strftime nativo donde %M sí
      # era minutos — por eso el bug no aparecía en producción.)
      scope = params[:scope].to_s.strip.downcase
      es_admin = current_rol.to_s == "admin"
      ver_todas = es_admin && scope == "todas"
      usuario_safe = current_usuario.to_s.gsub("'", "''")
      filtro_usuario = ver_todas ? "" : "WHERE creado_por = '#{usuario_safe}'"

      rows = ch.query(<<~SQL)
        SELECT id, titulo, descripcion, dias_semana, hora, email, creado_por,
               activo,
               formatDateTime(parseDateTimeBestEffortOrNull(toString(ultima_ejecucion)), '%Y-%m-%d %H:%i') AS ultima_ejecucion,
               formatDateTime(parseDateTimeBestEffortOrNull(toString(creado_en)),        '%Y-%m-%d %H:%i') AS creado_en,
               formatDateTime(parseDateTimeBestEffortOrNull(toString(actualizado_en)),   '%Y-%m-%d %H:%i') AS actualizado_en,
               frecuencia, dia_mes, mes_referencia, fecha_ejecucion,
               marcado_hecho_periodo
        FROM picapmongoprod.cronograma_tareas FINAL
        #{filtro_usuario}
        ORDER BY hora, titulo
      SQL
      ahora = Time.now
      tareas = rows.map do |t|
        mhp = t["marcado_hecho_periodo"].to_s.strip
        t["marcado_hecho_periodo"] = mhp
        t["hecho_en_periodo_actual"] = mhp.present? && mhp == periodo_actual(t["frecuencia"], ahora)
        t["activo"] = t["activo"].to_i
        t["es_propia"] = t["creado_por"].to_s == current_usuario.to_s
        t
      end
      render json: {
        ok: true, tareas: tareas,
        usuario_actual: current_usuario,
        rol_actual: current_rol,
        scope: ver_todas ? "todas" : "mias",
        es_admin: es_admin,
      }
    rescue => e
      Rails.logger.error("[CronogramaController] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/cronograma
    # v3.3.14: cualquier usuario autenticado puede crear sus propias tareas.
    def create
      data, err = normalizar_payload(params.to_unsafe_h)
      return render json: { ok: false, error: err }, status: :bad_request if err
      tid = SecureRandom.uuid
      ahora_iso = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")
      ch.query(insert_sql(tid, data, ahora_iso, ahora_iso, current_usuario))
      render json: { ok: true, id: tid }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # PUT /api/cronograma/:id
    def update
      tid = params[:id].to_s
      return render json: { ok: false, error: "ID inválido" }, status: :bad_request unless tid.match?(/\A[0-9a-f-]+\z/i)
      data, err = normalizar_payload(params.to_unsafe_h)
      return render json: { ok: false, error: err }, status: :bad_request if err
      existente = ch.query(<<~SQL).first
        SELECT creado_por,
               formatDateTime(parseDateTimeBestEffortOrNull(toString(creado_en)),       '%Y-%m-%d %H:%i:%S') AS creado_en,
               marcado_hecho_periodo,
               formatDateTime(parseDateTimeBestEffortOrNull(toString(ultima_ejecucion)),'%Y-%m-%d %H:%i:%S') AS ultima_ejecucion
        FROM picapmongoprod.cronograma_tareas FINAL WHERE id = '#{tid}' LIMIT 1
      SQL
      return render json: { ok: false, error: "Tarea no encontrada" }, status: :not_found unless existente
      return if deny_si_no_es_dueno!(existente["creado_por"])
      ahora_iso = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")
      ch.query(insert_sql(tid, data, existente["creado_en"], ahora_iso, existente["creado_por"] || current_usuario,
                          marcado: existente["marcado_hecho_periodo"], ultima: existente["ultima_ejecucion"]))
      render json: { ok: true }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # DELETE /api/cronograma/:id
    def destroy
      tid = params[:id].to_s
      return render json: { ok: false, error: "ID inválido" }, status: :bad_request unless tid.match?(/\A[0-9a-f-]+\z/i)
      existente = ch.query("SELECT creado_por FROM picapmongoprod.cronograma_tareas FINAL WHERE id = '#{tid}' LIMIT 1").first
      return render json: { ok: false, error: "Tarea no encontrada" }, status: :not_found unless existente
      return if deny_si_no_es_dueno!(existente["creado_por"])
      ch.query("ALTER TABLE picapmongoprod.cronograma_tareas DELETE WHERE id = '#{tid}'")
      render json: { ok: true }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/cronograma/:id/marcar-hecho
    # Body: {hecho: true|false}
    def marcar_hecho
      tid = params[:id].to_s
      return render json: { ok: false, error: "ID inválido" }, status: :bad_request unless tid.match?(/\A[0-9a-f-]+\z/i)
      hecho = params.fetch(:hecho, true).to_s != "false"
      existente = ch.query(<<~SQL).first
        SELECT titulo, descripcion, dias_semana, hora, email, creado_por,
               activo,
               formatDateTime(parseDateTimeBestEffortOrNull(toString(ultima_ejecucion)),'%Y-%m-%d %H:%i:%S') AS ultima_ejecucion,
               formatDateTime(parseDateTimeBestEffortOrNull(toString(creado_en)),       '%Y-%m-%d %H:%i:%S') AS creado_en,
               frecuencia, dia_mes, mes_referencia, fecha_ejecucion
        FROM picapmongoprod.cronograma_tareas FINAL WHERE id = '#{tid}' LIMIT 1
      SQL
      return render json: { ok: false, error: "Tarea no encontrada" }, status: :not_found unless existente
      return if deny_si_no_es_dueno!(existente["creado_por"])
      nuevo = hecho ? periodo_actual(existente["frecuencia"], Time.now) : ""
      data = {
        titulo:          existente["titulo"],          descripcion:    existente["descripcion"],
        dias_semana:     existente["dias_semana"],     hora:           existente["hora"],
        email:           existente["email"],
        frecuencia:      existente["frecuencia"],      dia_mes:        existente["dia_mes"].to_i,
        mes_referencia:  existente["mes_referencia"].to_i,
        fecha_ejecucion: existente["fecha_ejecucion"],
      }
      ahora_iso = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")
      ch.query(insert_sql(tid, data, existente["creado_en"], ahora_iso, existente["creado_por"] || current_usuario,
                          marcado: nuevo, ultima: existente["ultima_ejecucion"], activo: existente["activo"].to_i))
      render json: { ok: true, marcado_hecho_periodo: nuevo }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/cronograma/:id/test — envía email de prueba (placeholder)
    def test
      tid = params[:id].to_s
      r = ch.query("SELECT titulo, email, creado_por FROM picapmongoprod.cronograma_tareas FINAL WHERE id='#{tid}' LIMIT 1").first
      return render json: { ok: false, error: "Tarea no encontrada" }, status: :not_found unless r
      return if deny_si_no_es_dueno!(r["creado_por"])
      Rails.logger.info("[Cronograma test] enviar a #{r['email']} — #{r['titulo']}")
      render json: { ok: true, mensaje: "Email de prueba encolado para #{r['email']}",
                     nota: "Envío SMTP pendiente de integración EmailService" }
    rescue => e
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    # v3.3.14: ownership check. Admin puede editar/borrar/marcar cualquier
    # tarea. El resto solo las propias. Render 403 + true si se denegó.
    def deny_si_no_es_dueno!(creado_por)
      return false if current_rol.to_s == "admin"
      return false if creado_por.to_s == current_usuario.to_s
      render json: {
        ok: false,
        error: "No puedes modificar tareas de otros usuarios. Crea las tuyas con el botón 'Nueva tarea recurrente'.",
      }, status: :forbidden
      true
    end

    # Identificador único del período actual según la frecuencia.
    # Mientras coincida con marcado_hecho_periodo, la tarea se considera hecha.
    def periodo_actual(freq, ahora = Time.now)
      f = freq.to_s.downcase
      case f
      when "diaria"     then ahora.strftime("%Y-%m-%d")
      when "semanal"
        # ISO week (G = ISO year, V = ISO week)
        "#{ahora.strftime('%G')}-W#{format('%02d', ahora.strftime('%V').to_i)}"
      when "mensual"    then ahora.strftime("%Y-%m")
      when "trimestral" then "#{ahora.year}-Q#{((ahora.month - 1) / 3) + 1}"
      when "semestral"  then "#{ahora.year}-S#{ahora.month <= 6 ? 1 : 2}"
      when "anual"      then ahora.strftime("%Y")
      when "unica"      then ahora.strftime("%Y-%m-%d")
      else ahora.strftime("%Y-%m-%d")
      end
    end

    def normalizar_payload(p)
      titulo = p["titulo"].to_s.strip
      return [nil, "Título obligatorio"] if titulo.empty?
      email = p["email"].to_s.strip
      return [nil, "Email obligatorio"] if email.empty?
      hora = p["hora"].to_s.strip
      return [nil, "Hora obligatoria (HH:MM)"] unless hora.match?(/\A\d{2}:\d{2}\z/)
      freq = p["frecuencia"].to_s.downcase
      freq = "semanal" unless FRECUENCIAS.include?(freq)
      dias = p["dias_semana"].to_s.strip
      dia_mes        = p["dia_mes"].to_i
      mes_referencia = p["mes_referencia"].to_i
      [{
        titulo:          titulo[0, 200],
        descripcion:     p["descripcion"].to_s[0, 2000],
        dias_semana:     dias[0, 100],
        hora:            hora,
        email:           email[0, 200],
        frecuencia:      freq,
        dia_mes:         dia_mes.between?(0, 31) ? dia_mes : 0,
        mes_referencia:  mes_referencia.between?(0, 12) ? mes_referencia : 0,
        fecha_ejecucion: p["fecha_ejecucion"].to_s.strip[0, 20],
      }, nil]
    end

    def insert_sql(tid, data, creado_en, actualizado_en, creado_por, activo: 1, marcado: "", ultima: "")
      esc = ->(v) { v.to_s.gsub("\\", "\\\\\\\\").gsub("'", "''") }
      ultima_sql = ultima.to_s.empty? ? "toDateTime(0)" : "toDateTime('#{ultima}')"
      <<~SQL
        INSERT INTO picapmongoprod.cronograma_tareas
        (id, titulo, descripcion, dias_semana, hora, email, creado_por,
         activo, ultima_ejecucion, creado_en, actualizado_en,
         frecuencia, dia_mes, mes_referencia, fecha_ejecucion, marcado_hecho_periodo)
        VALUES
        ('#{tid}', '#{esc.(data[:titulo])}', '#{esc.(data[:descripcion])}',
         '#{esc.(data[:dias_semana])}', '#{data[:hora]}', '#{esc.(data[:email])}',
         '#{esc.(creado_por.to_s)}', #{activo.to_i}, #{ultima_sql},
         toDateTime('#{creado_en}'), toDateTime('#{actualizado_en}'),
         '#{data[:frecuencia]}', #{data[:dia_mes].to_i}, #{data[:mes_referencia].to_i},
         '#{esc.(data[:fecha_ejecucion])}', '#{esc.(marcado)}')
      SQL
    end
  end
end
