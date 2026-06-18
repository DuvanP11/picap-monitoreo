# app/services/tyc_auditor_service.rb
# v3.3.94 — Auditor de TyC: recibe estructura del TyC + driver_id, genera SQL
# dinámica que aplica las reglas, ejecuta contra ClickHouse y devuelve veredicto.
#
# Input esperado:
#   tyc = {
#     "nombre"                  => "VUELVE Y LLEVATE ...",
#     "id_campana"              => "6a243cba677d7f15633561f4" (opcional, para cruzar pago real),
#     "pais"                    => "Colombia",
#     "fecha_inicio"            => "2026-06-06 00:00:00",
#     "fecha_fin"               => "2026-06-12 23:59:59",
#     "tiers"                   => [{count: 20, bono: 50000}, ...],
#     "servicios_validos"       => ["Espero tranqui", "Mensajería", ...],
#     "requiere_inactividad"    => false,
#     "dias_inactividad"        => 60,
#     "excluye_picap_max"       => false,
#     "distancia_minima_m"      => 0,
#     "anula_pasajero_repetido" => true,
#     "mensajeria_no_corp"      => true
#   }
#   driver_id     = "66b2ea967cf9fb0454ca066e" (24 hex chars)
#   ignored_rules = ["pasajero_repetido", "distancia", "inactividad", ...] (opcional)
#
# Output:
#   {
#     veredicto: "GANA" | "NO GANA",
#     razon_veredicto: "Tier 50v alcanzado" | "Pasajero repetido",
#     tier_alcanzado: "Tier 50v · $400.000",
#     bono_que_deberia_recibir: 400000,
#     valor_efectivamente_pagado: 400000,
#     conteos: { ... }
#   }

class TycAuditorService
  IGNORABLES = %w[inactividad distancia mensajeria_no_corp pasajero_repetido picap_max].freeze

  def self.auditar(tyc:, driver_id:, ch:, ignored_rules: [])
    new(tyc, driver_id, ch, ignored_rules).call
  end

  def initialize(tyc, driver_id, ch, ignored_rules)
    @tyc       = tyc.is_a?(String) ? JSON.parse(tyc) : tyc.deep_stringify_keys
    @driver_id = driver_id.to_s.strip
    @ch        = ch
    @ignored   = (ignored_rules || []).map(&:to_s) & IGNORABLES
    # v3.3.97: override manual de ID/slug de campaña (si el frontend lo pasa)
    @campaign_override = @tyc["campaign_id_override"].to_s.strip
    validate!
  end

  def call
    sql = build_query
    Rails.logger.info("[TycAuditor] SQL generado (#{sql.length} chars), driver=#{@driver_id}")
    rows = @ch.query(sql, timeout: 60)
    build_result(rows.first || {})
  end

  private

  def validate!
    raise ArgumentError, "driver_id inválido (hex 24 chars)" unless @driver_id =~ /\A[a-fA-F0-9]{24}\z/
    raise ArgumentError, "TyC sin fecha_inicio"              if @tyc["fecha_inicio"].to_s.strip.empty?
    raise ArgumentError, "TyC sin fecha_fin"                  if @tyc["fecha_fin"].to_s.strip.empty?
    tiers = @tyc["tiers"]
    raise ArgumentError, "TyC sin tiers"                      unless tiers.is_a?(Array) && tiers.any?
  end

  def ignored?(rule)
    @ignored.include?(rule.to_s)
  end

  def fmt_money(n)
    n.to_i.to_s.reverse.scan(/.{1,3}/).join('.').reverse
  end

  # Asegura formato 'YYYY-MM-DD HH:MM:SS'. Acepta 'YYYY-MM-DD' (le agrega 00:00:00).
  def normalize_dt(s)
    s = s.to_s.strip
    s = s + " 00:00:00" unless s.match?(/\d{2}:\d{2}/)
    s
  end

  def build_query
    fecha_ini = normalize_dt(@tyc["fecha_inicio"])
    fecha_fin = normalize_dt(@tyc["fecha_fin"])
    pais      = @tyc["pais"].to_s.downcase

    # Reglas activas (no ignoradas)
    inactividad_sql = if @tyc["requiere_inactividad"] && !ignored?("inactividad")
      dias  = (@tyc["dias_inactividad"] || 60).to_i
      ini   = (Date.parse(fecha_ini[0..9]) - dias).strftime("%Y-%m-%d")
      hasta = (Date.parse(fecha_ini[0..9]) - 1   ).strftime("%Y-%m-%d")
      <<~SQL
        (SELECT count() FROM picapmongoprod.bookings b
         WHERE toString(b.driver_id) = '#{@driver_id}'
           AND b.status_cd = 4
           AND b.created_at BETWEEN toDateTime('#{ini} 00:00:00', 'America/Bogota')
                                AND toDateTime('#{hasta} 23:59:59', 'America/Bogota'))
      SQL
    else
      "0"
    end

    distancia_filter = if @tyc["distancia_minima_m"].to_i > 0 && !ignored?("distancia")
      "AND distancia_m IS NOT NULL AND distancia_m > #{@tyc["distancia_minima_m"].to_i}"
    else
      ""
    end

    mensajeria_filter = if @tyc["mensajeria_no_corp"] && !ignored?("mensajeria_no_corp")
      "AND (positionCaseInsensitive(nombre_st, 'mensajer') = 0 OR empty(company_id_str))"
    else
      ""
    end

    # Filtro de tipos de servicio (LIKE por primera palabra de cada nombre)
    service_name_clauses = (@tyc["servicios_validos"] || []).map do |s|
      key = s.to_s.downcase.split.first.to_s.gsub(/[^a-záéíóúñ]/, '')
      next nil if key.length < 3
      "positionCaseInsensitive(JSONExtractString(name, 'es'), '#{key}') > 0"
    end.compact.join(" OR ")
    service_name_clauses = "true" if service_name_clauses.empty?

    # País — bd es alias en bookings_con_tipo (no b)
    pais_filter = pais.include?("colombia") ? "AND upper(bd.g_country) = 'CO'" :
                  pais.include?("mexic")    ? "AND upper(bd.g_country) = 'MX'" :
                  pais.include?("nicaragua")? "AND upper(bd.g_country) = 'NI'" : ""

    # multiIf de tier alcanzado (orden descendente)
    tiers_sorted = @tyc["tiers"].sort_by { |t| -t["count"].to_i }
    multiif_tier = tiers_sorted.map { |t|
      "(SELECT count() FROM bookings_validos) >= #{t["count"].to_i}, " \
      "'Tier #{t["count"]}v · $#{fmt_money(t["bono"])}'"
    }.join(",\n            ")
    multiif_bono = tiers_sorted.map { |t|
      "(SELECT count() FROM bookings_validos) >= #{t["count"].to_i}, #{t["bono"].to_i}"
    }.join(",\n            ")

    pasajero_check_sql = if @tyc["anula_pasajero_repetido"] && !ignored?("pasajero_repetido")
      <<~SQL
        (SELECT countIf(rep > 1) FROM (
            SELECT passenger_id, count() AS rep FROM bookings_validos
            WHERE notEmpty(passenger_id) GROUP BY passenger_id
        ))
      SQL
    else
      "0"
    end

    # v3.3.97: filtro de familia de campañas — busca en picapmongoprod.campaigns
    # por hex (si el TyC trae id_campana o el user pasó override) o por palabras
    # clave del nombre del TyC (matchea "VUELVE Y LLEVATE EL BONO" → todos los escalones).
    campanas_filter = build_campanas_filter

    <<~SQL
      WITH
      campanas_familia AS (
          SELECT toString(_id)              AS campaign_id,
                 any(name)                  AS campaign_name
          FROM picapmongoprod.campaigns
          WHERE 1=1 #{campanas_filter}
          GROUP BY _id
      ),
      pagos_piloto AS (
          SELECT toString(wat.campaign_id) AS campaign_id,
                 intDiv(toInt64OrZero(JSONExtractString(wat.amount, 'cents')), 100) AS amount_cop,
                 wat.created_at
          FROM picapmongoprod.wallet_account_transactions AS wat
          INNER JOIN picapmongoprod.wallet_accounts AS wa ON wa._id = wat.account_id
          WHERE lower(wat._type) = 'walletaccounttransactionpromocampaign'
            AND toString(wa.passenger_id) = '#{@driver_id}'
            AND toString(wat.campaign_id) IN (SELECT campaign_id FROM campanas_familia)
      ),
      service_types_validos AS (
          SELECT _id FROM picapmongoprod.service_types FINAL
          WHERE #{service_name_clauses}
      ),
      bookings_periodo AS (
          SELECT
              b._id AS booking_id,
              toString(b.driver_id) AS driver_id,
              toString(b.passenger_id) AS passenger_id,
              toString(b.requested_service_type_id) AS service_type_id,
              ifNull(toString(b.company_id), '') AS company_id_str,
              JSONExtractString(b.final_cost, 'currency_iso') AS currency_iso,
              b.g_country,
              toFloat64OrNull(JSONExtractString(b.origin_geojson, 'coordinates', 1)) AS origin_lon,
              toFloat64OrNull(JSONExtractString(b.origin_geojson, 'coordinates', 2)) AS origin_lat,
              toFloat64OrNull(JSONExtractString(b.end_geojson,    'coordinates', 1)) AS end_lon,
              toFloat64OrNull(JSONExtractString(b.end_geojson,    'coordinates', 2)) AS end_lat,
              ROW_NUMBER() OVER (PARTITION BY b._id ORDER BY b.created_at DESC) AS rn
          FROM picapmongoprod.bookings b
          WHERE toString(b.driver_id) = '#{@driver_id}'
            AND b.status_cd = 4
            AND b.created_at >= toDateTime('#{fecha_ini}', 'America/Bogota')
            AND b.created_at <= toDateTime('#{fecha_fin}', 'America/Bogota')
      ),
      bookings_dedup AS (SELECT * FROM bookings_periodo WHERE rn = 1),
      bookings_con_tipo AS (
          SELECT bd.*,
                 JSONExtractString(st.name, 'es') AS nombre_st,
                 if(bd.origin_lon IS NOT NULL AND bd.origin_lat IS NOT NULL
                    AND bd.end_lon IS NOT NULL AND bd.end_lat IS NOT NULL,
                    round(geoDistance(bd.origin_lon, bd.origin_lat, bd.end_lon, bd.end_lat), 0),
                    NULL) AS distancia_m
          FROM bookings_dedup AS bd
          INNER JOIN picapmongoprod.service_types AS st FINAL
              ON st._id = bd.service_type_id
          INNER JOIN service_types_validos AS sv ON sv._id = bd.service_type_id
          WHERE 1=1
            #{pais_filter}
            AND bd.currency_iso = 'COP'
      ),
      bookings_validos AS (
          SELECT * FROM bookings_con_tipo
          WHERE 1=1
            #{distancia_filter}
            #{mensajeria_filter}
      )

      SELECT
          (SELECT count() FROM bookings_dedup)         AS total_servicios_status4_en_periodo,
          (SELECT count() FROM bookings_con_tipo)      AS servicios_tipo_pais_validos,
          (SELECT count() FROM bookings_validos)       AS servicios_validos_finales,
          #{inactividad_sql}                            AS servicios_en_inactividad_previa,
          #{pasajero_check_sql}                         AS pasajeros_repetidos,
          multiIf(#{multiif_tier},
                  'NO ALCANZÓ TIER MÍNIMO')             AS tier_alcanzado,
          multiIf(#{multiif_bono}, 0)                   AS bono_que_deberia_recibir,

          -- v3.3.97: campañas conectadas al TyC
          (SELECT count() FROM campanas_familia)        AS campanas_familia_count,
          (SELECT arrayStringConcat(
                    arrayMap(x -> concat(x.1, '|', x.2),
                             groupArray((campaign_id, campaign_name))),
                    '\\n')
             FROM campanas_familia)                     AS campanas_familia_raw,

          -- v3.3.97: pagos del piloto a la familia
          (SELECT count() FROM pagos_piloto)            AS pagos_count,
          (SELECT ifNull(sum(amount_cop), 0) FROM pagos_piloto) AS valor_efectivamente_pagado,
          (SELECT arrayStringConcat(
                    arrayMap(x -> concat(x.1, '|', toString(x.2), '|', toString(x.3)),
                             groupArray((campaign_id, amount_cop, created_at))),
                    '\\n')
             FROM pagos_piloto)                         AS pagos_raw
    SQL
  end

  # v3.3.97: construye el filtro WHERE para campanas_familia.
  # Estrategia:
  #   1) Si user pasó override hex 24 → match exacto por _id
  #   2) Si user pasó slug → LIKE por nombre/slug
  #   3) Si TyC trae id_campana hex 24 → match exacto
  #   4) Si TyC trae slug → LIKE por nombre/slug
  #   5) Fallback: 2-3 palabras clave del nombre del TyC
  def build_campanas_filter
    override = @campaign_override
    return "AND toString(_id) = '#{override}'" if override =~ /\A[a-fA-F0-9]{24}\z/

    slug = override.presence ||
           (@tyc["id_campana"].to_s if @tyc["id_campana"].to_s !~ /\A[a-fA-F0-9]{24}\z/)

    if slug && slug.length > 8
      slug_root = slug.gsub(/-target\d+$/, '')   # 'vuelve-y-...-target40' → 'vuelve-y-...'
      return "AND positionCaseInsensitive(name, '#{slug_root}') > 0"
    end

    if @tyc["id_campana"].to_s =~ /\A[a-fA-F0-9]{24}\z/
      return "AND toString(_id) = '#{@tyc["id_campana"]}'"
    end

    # Fallback: 2-3 palabras significativas del nombre
    stop = %w[para con sobre como solo bono campana campaña the and los las del]
    words = @tyc["nombre"].to_s.downcase
                              .gsub(/[¡!¿?·\.\,]/, ' ')
                              .split(/\s+/)
                              .map { |w| w.gsub(/[^a-záéíóúñ]/i, '') }
                              .reject { |w| w.length < 4 || stop.include?(w) }
                              .first(3)
    return "AND 1 = 0" if words.empty?

    # v3.3.98: no filtramos por begin_at (no existe en el schema de campaigns)
    # Si hay falsos positivos por palabras genéricas, el user puede usar override.
    words.map { |w| "AND positionCaseInsensitive(name, '#{w}') > 0" }.join("\n        ")
  end

  def build_result(row)
    r = row.respond_to?(:transform_keys) ? row.transform_keys(&:to_s) : row

    inact   = r["servicios_en_inactividad_previa"].to_i
    pasrep  = r["pasajeros_repetidos"].to_i
    val_ok  = r["servicios_validos_finales"].to_i
    tier    = r["tier_alcanzado"].to_s
    bono    = r["bono_que_deberia_recibir"].to_i
    pagado  = r["valor_efectivamente_pagado"].to_i

    veredicto, razon =
      if @tyc["requiere_inactividad"] && !ignored?("inactividad") && inact > 0
        ["NO GANA", "No era elegible — tuvo actividad en periodo de inactividad (#{inact} servicios previos)"]
      elsif @tyc["anula_pasajero_repetido"] && !ignored?("pasajero_repetido") && pasrep > 0
        ["NO GANA", "Anulado por TyC — repitió pasajero (#{pasrep} casos)"]
      elsif bono == 0
        ["NO GANA", "No alcanzó el tier mínimo (#{val_ok} servicios válidos)"]
      else
        ["GANA", "#{tier} con #{val_ok} servicios válidos"]
      end

    # v3.3.97: parse de listas codificadas como string (CH no devuelve arrays directos)
    campanas_list = parse_pipe_list(r["campanas_familia_raw"], 2)
      .map { |c| { campaign_id: c[0], campaign_name: c[1] } }
    pagos_list = parse_pipe_list(r["pagos_raw"], 3)
      .map { |p| { campaign_id: p[0], amount_cop: p[1].to_i, fecha: p[2] } }

    tiers_sorted_asc = @tyc["tiers"].sort_by { |t| t["count"].to_i }
    tier_min = tiers_sorted_asc.first
    tier_max = tiers_sorted_asc.last

    # v3.3.97: comparación pago debido vs pago real
    diferencia    = pagado - bono
    estado_pago = if pagado == 0 && bono > 0
                    "Sin pago aún"
                  elsif pagado == 0 && bono == 0
                    "No aplica (no ganó)"
                  elsif diferencia == 0
                    "Pagado correcto"
                  elsif diferencia > 0
                    "Sobrepago de $#{fmt_money(diferencia)}"
                  else
                    "Subpago de $#{fmt_money(-diferencia)}"
                  end

    {
      veredicto:                  veredicto,
      razon_veredicto:            razon,
      tier_alcanzado:             tier,
      bono_que_deberia_recibir:   bono,
      valor_efectivamente_pagado: pagado,
      pago_comparacion: {
        debido:      bono,
        pagado:      pagado,
        diferencia:  diferencia,
        estado:      estado_pago,
        pagos_count: r["pagos_count"].to_i,
        pagos_list:  pagos_list,
      },
      campanas_asociadas: {
        count: r["campanas_familia_count"].to_i,
        list:  campanas_list,
      },
      tiers_resumen: {
        tier_minimo: tier_min ? { count: tier_min["count"].to_i, bono: tier_min["bono"].to_i } : nil,
        tier_maximo: tier_max ? { count: tier_max["count"].to_i, bono: tier_max["bono"].to_i } : nil,
      },
      reglas_aplicadas: {
        inactividad_check:        @tyc["requiere_inactividad"]    && !ignored?("inactividad"),
        distancia_check:          @tyc["distancia_minima_m"].to_i > 0 && !ignored?("distancia"),
        mensajeria_no_corp_check: @tyc["mensajeria_no_corp"]      && !ignored?("mensajeria_no_corp"),
        pasajero_repetido_check:  @tyc["anula_pasajero_repetido"] && !ignored?("pasajero_repetido"),
      },
      reglas_ignoradas: @ignored,
      conteos: {
        total_servicios_status4_en_periodo: r["total_servicios_status4_en_periodo"].to_i,
        servicios_tipo_pais_validos:        r["servicios_tipo_pais_validos"].to_i,
        servicios_validos_finales:          val_ok,
        servicios_en_inactividad_previa:    inact,
        pasajeros_repetidos:                pasrep,
      }
    }
  end

  # v3.3.97: parsea "v1|v2\nv1|v2\n…" en arreglo de arreglos
  def parse_pipe_list(raw, fields)
    return [] if raw.to_s.empty?
    raw.to_s.split("\n").map { |line| line.split("|", fields) }.reject { |a| a.empty? || a.first.to_s.empty? }
  end
end
