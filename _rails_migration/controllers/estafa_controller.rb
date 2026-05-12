# app/controllers/api/estafa_controller.rb
# Detección de estafa con keywords financieras (api.py 3406-3863).
# Categorías: ESTAFA (denuncia 21/13 + evento 26 confirmado, O mensajería con
#             keywords del patrón financiero KW_ESTAFA en pd.indications)
#             OK (todo lo demás)
#
# Endpoint /api/estafa:
#   - resumen: total/estafa/ok + cuentas únicas
#   - trend: por día
#   - top_kw: top 15 palabras detectadas (del sample)
#   - alertas: hasta 5000 filas enriquecidas

module Api
  class EstafaController < ApplicationController
    before_action :authenticate_user!

    LIMIT_DETALLE = 5000

    # Palabras clave del patrón financiero (51 keywords, paridad Python KW_ESTAFA)
    KW_ESTAFA = [
      "abono", "administracion", "administración", "bancaria", "bancario",
      "bono", "cajero multifuncional", "compra", "con base", "con una base",
      "conbase", "convenio", "copago", "cuota moderadora", "datafono",
      "despacho", "disponibilidad", "disponible", "económica", "farmaceutica",
      "farmacéutica", "farmacéutico", "farmacia", "fotocopia", "fotocopias",
      "gratifica", "gratificación", "insulina", "mande", "multifuncional",
      "multifuncional de bogotá", "multivitaminicos", "orden medica", "picap",
      "plante", "reembolsado", "sancion", "sanción", "serio",
      "servicio al cliente", "soporte picap", "soporte tecnico de picap",
      "soporte técnico de picap", "soporte tecnico pibox",
      "sporte tecnico de pibox", "tirilla", "transaccion", "transacción",
      "transfiera el dinero", "transfiere", "vase", "wasab",
    ].freeze

    # Array SQL literal para multiSearchAnyCaseInsensitive
    KW_ESTAFA_SQL = "[" + KW_ESTAFA.map { |k| "'#{k.gsub("'", "''")}'" }.join(",") + "]"

    # GET /api/estafa?desde=&hasta=&pais=&q=&tipo=
    def index
      desde   = desde_param
      hasta   = hasta_param
      pais_iso = iso_pais
      q_id    = params[:q].to_s.strip
      q_tipo  = params[:tipo].to_s.strip
      q_tipo  = "booking" unless %w[booking driver user].include?(q_tipo)
      filtro_pais = pais_iso.to_s.empty? ? "" : "AND b.g_country = '#{pais_iso}'"

      # 1) Agregado diario (total real sin LIMIT)
      sql_agg = QueriesService.format(
        QueriesService::Q_ESTAFA_AGREGADO,
        desde: desde, hasta: hasta,
        filtro_pais: filtro_pais,
        kws_estafa:  KW_ESTAFA_SQL,
      )
      agg_rows = ch.query(sql_agg)
      total_real  = agg_rows.sum { |r| r["total_dia"].to_i }
      estafa_real = agg_rows.sum { |r| r["estafa_dia"].to_i }
      ok_real     = total_real - estafa_real

      trend = agg_rows.map do |r|
        td = r["total_dia"].to_i
        ed = r["estafa_dia"].to_i
        { fecha: r["dia"].to_s, estafa: ed, ok: td - ed }
      end

      # 1.5) Conteo de cuentas únicas
      total_cuentas = cuentas_estafa = cuentas_ok = 0
      begin
        sql_cuentas = QueriesService.format(
          QueriesService::Q_ESTAFA_CUENTAS,
          desde: desde, hasta: hasta,
          filtro_pais: filtro_pais,
          kws_estafa:  KW_ESTAFA_SQL,
        )
        cu = ch.query(sql_cuentas).first || {}
        total_cuentas  = cu["total_cuentas"].to_i
        cuentas_estafa = cu["cuentas_estafa"].to_i
        cuentas_ok     = cu["cuentas_ok"].to_i
      rescue => e
        Rails.logger.warn("[EstafaController#cuentas] #{e.message[0,200]}")
      end

      # 2) Sample detallado (LIMIT_DETALLE filas)
      sql_det = QueriesService.format(
        QueriesService::Q_ESTAFA_BASE,
        desde: desde, hasta: hasta,
        filtro_pais: filtro_pais,
        kws_estafa:  KW_ESTAFA_SQL,
        limit_filas: LIMIT_DETALLE,
      )
      rows_raw = ch.query(sql_det)

      # Dedup defensivo por booking_id (LEFT JOIN packages puede repetir)
      seen = {}
      rows_raw.each do |r|
        bid = r["booking_id"].to_s
        next if bid.empty? || seen.key?(bid)
        seen[bid] = r
      end

      rows = seen.values.map { |row| procesar_fila(row) }

      # Filtro por ID (client-side sobre sample)
      if q_id.length >= 4
        q_low = q_id.downcase
        campo = { "booking" => "booking_id", "driver" => "driver_id", "user" => "user_id" }[q_tipo]
        rows = rows.select { |r| r[campo].to_s.downcase.include?(q_low) }
      end

      # Top palabras detectadas (sobre sample)
      kw_count = Hash.new(0)
      rows.each { |r| (r["palabras_detectadas"] || []).each { |kw| kw_count[kw] += 1 } }
      top_kw = kw_count.sort_by { |_, v| -v }.first(15).map { |kw, n| { kw: kw, count: n } }

      muestra_truncada = total_real > rows.size

      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta,
        resumen: {
          total:        total_real,
          estafa:       estafa_real,
          ok:           ok_real,
          pct_estafa:   total_real > 0 ? (estafa_real.to_f / total_real * 100).round(1) : 0,
          pct_ok:       total_real > 0 ? (ok_real.to_f     / total_real * 100).round(1) : 0,
          total_cuentas:        total_cuentas,
          cuentas_estafa:       cuentas_estafa,
          cuentas_ok:           cuentas_ok,
          pct_cuentas_estafa:   total_cuentas > 0 ? (cuentas_estafa.to_f / total_cuentas * 100).round(1) : 0,
          muestra_size:         rows.size,
          muestra_truncada:     muestra_truncada,
        },
        trend:   trend,
        top_kw:  top_kw,
        alertas: rows,
      })
    rescue => e
      Rails.logger.error("[EstafaController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message, type: e.class.name },
             status: :internal_server_error
    end

    private

    # Clasifica una fila como ESTAFA u OK según keywords en indications
    def procesar_fila(row)
      indications = row["indications"].to_s
      clasificacion, kws = detectar_palabras(indications)
      fs = row["fecha_servicio"].to_s
      {
        "booking_id"             => row["booking_id"].to_s,
        "driver_id"              => row["driver_id"].to_s,
        "user_id"                => row["user_id"].to_s,
        "name_user"              => row["name_user"].to_s,
        "pais"                   => row["pais"].to_s,
        "departamento"           => row["departamento"].to_s,
        "city"                   => row["city"].to_s,
        "fecha_servicio"         => fs.empty? ? "—" : fs[0, 16],
        "cancelation_reason"     => row["cancelation_reason"].to_s,
        "status_driver_suspend"  => row["status_driver_suspend"].to_s,
        "status_user_suspend"    => row["status_user_suspend"].to_s,
        "status_expelled"        => row["status_expelled"].to_s,
        "imei_sesion"            => row["imei_sesion"].to_s,
        "indications"            => indications[0, 500],
        "clasificacion"          => clasificacion,
        "palabras_detectadas"    => kws.first(10),
      }
    end

    def detectar_palabras(texto)
      return ["OK", []] if texto.nil? || %w[ None null].include?(texto.to_s.strip)
      t = texto.to_s.downcase
      hits = KW_ESTAFA.select { |kw| t.include?(kw) }
      hits.empty? ? ["OK", []] : ["ESTAFA", hits]
    end
  end
end
