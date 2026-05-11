# app/services/queries_service.rb
# Queries SQL — paridad EXACTA con api.py de Python
# Métodos públicos:
#   QueriesService.format(sql, fecha_desde:, fecha_hasta:)
#   QueriesService.cte_con_pais(iso_pais)
#   QueriesService::Q_KPIS, Q_TENDENCIA, Q_CIUDADES, Q_TOP_DRIVERS

module QueriesService

  PAIS_A_ISO = {
    "Colombia"  => "CO",
    "Mexico"    => "MX",
    "México"    => "MX",
    "Nicaragua" => "NI",
    "Guatemala" => "GT",
    "Peru"      => "PE",
    "Perú"      => "PE",
    "Ecuador"   => "EC",
    "CO"        => "CO",
    "MX"        => "MX",
    "NI"        => "NI",
    "GT"        => "GT",
    "PE"        => "PE",
    "EC"        => "EC",
  }.freeze

  TASAS_PAIS = {
    "Colombia"  => 0.12,
    "Mexico"    => 0.10,
    "Nicaragua" => 0.10,
    "Guatemala" => 0.15,
    "CO"        => 0.12,
    "MX"        => 0.10,
    "NI"        => 0.10,
    "GT"        => 0.15,
  }.freeze
  TASA_DEFAULT = 0.15

  # Reemplaza %{key} por valor usando gsub manual (no usa Kernel#format
  # para evitar problemas con % en patrones LIKE de SQL).
  def self.format(sql, **vars)
    result = sql.dup
    vars.each { |k, v| result.gsub!("%{#{k}}", v.to_s) }
    result
  end

  # Inyecta filtro de país en BASE_CTE haciendo replace en el WHERE.
  # Replica exactamente lo que hace cargar_datos() del api.py de Python.
  def self.cte_con_pais(iso_pais, moneda = nil)
    extra = ""
    if iso_pais && !iso_pais.to_s.strip.empty?
      extra += " AND b.g_country = '#{iso_pais}'"
    end
    if moneda && !moneda.to_s.strip.empty?
      extra += " AND JSONExtractString(b.final_cost, 'currency_iso') = '#{moneda}'"
    end
    return BASE_CTE if extra.empty?
    BASE_CTE.gsub(
      "AND b.status_cd IN (100, 102)",
      "AND b.status_cd IN (100, 102)#{extra}"
    )
  end

  def self.tasa_para(pais = nil, _moneda = nil)
    return TASAS_PAIS[pais] || TASA_DEFAULT if pais
    TASA_DEFAULT
  end

  # ══════════════════════════════════════════════════════════════════════
  # BASE_CTE — paridad EXACTA con api.py Python (líneas 94-165)
  # NO usa columnas b.cancel_lat/b.end_lat (no existen en ClickHouse).
  # Las calcula con extract() regex sobre b.events y JSONExtractString
  # sobre b.end_geojson.
  # Single-quoted heredoc para evitar interpolación accidental Ruby.
  # ══════════════════════════════════════════════════════════════════════
  BASE_CTE = <<~'SQL'
    WITH base AS (
        SELECT
            toTimeZone(b.created_at, 'America/Bogota') AS creacion_servicio,
            b._id              AS booking_id,
            b.driver_id        AS id_driver,
            pd.name            AS name_driver,
            CASE
                WHEN b.g_adm_area_lv_1 = 'MN' THEN 'Managua'
                WHEN b.g_adm_area_lv_1 = 'Guatemala Department' THEN 'Guatemala'
                WHEN b.g_adm_area_lv_1 = '' THEN 'Sin ciudad'
                ELSE b.g_adm_area_lv_1
            END AS ciudad,
            JSONExtractString(b.final_cost, 'currency_iso') AS moneda,
            CASE
                WHEN b.g_country = 'CO' THEN 'Colombia'
                WHEN b.g_country = 'MX' THEN 'Mexico'
                WHEN b.g_country = 'NI' THEN 'Nicaragua'
                WHEN b.g_country = 'GT' THEN 'Guatemala'
                ELSE 'Otro'
            END AS pais,
            toFloat64OrNull(JSONExtractString(b.estimated_cost, 'cents')) / 100 AS costo_estimado,
            extract(ifNull(b.events,''), 'event_cd":26.*?coordinates":\[\s*([+-]?\d+\.\d+)')     AS ev_cancel_lon_str,
            extract(ifNull(b.events,''), 'event_cd":26.*?coordinates":\[.*?,\s*([+-]?\d+\.\d+)') AS ev_cancel_lat_str,
            extract(ifNull(b.events,''), 'event_cd":20.*?created_at":"([^"]+)')                  AS ev_accept,
            extract(ifNull(b.events,''), 'event_cd":26.*?created_at":"([^"]+)')                  AS ev_cancel,
            toFloat64OrNull(ev_cancel_lon_str) AS cancel_lon,
            toFloat64OrNull(ev_cancel_lat_str) AS cancel_lat,
            toFloat64(JSONExtractString(b.end_geojson, 'coordinates', 1)) AS end_lon,
            toFloat64(JSONExtractString(b.end_geojson, 'coordinates', 2)) AS end_lat,
            dateDiff('minute',
                parseDateTimeBestEffortOrNull(ev_accept),
                parseDateTimeBestEffortOrNull(ev_cancel)
            ) AS minutos_entre_eventos,
            JSONExtractString(st.name, 'es') AS type_service,
            b.company_id AS id_company,
            ROW_NUMBER() OVER (PARTITION BY b._id ORDER BY b.created_at DESC) AS rn
        FROM picapmongoprod.bookings b
        LEFT JOIN picapmongoprod.passengers pd ON b.driver_id = pd._id
        LEFT JOIN picapmongoprod.service_types st ON st._id = b.requested_service_type_id
        WHERE
            NOT empty(b.origin_geojson)
            AND NOT empty(b.end_geojson)
            AND b.status_cd IN (100, 102)
            AND b.created_at >= toDateTime('%{fecha_desde} 00:00:00')
            AND b.created_at <= toDateTime('%{fecha_hasta} 23:59:59')
    ),
    clasificado AS (
        SELECT *,
            round(geoDistance(cancel_lon, cancel_lat, end_lon, end_lat), 2) AS distancia_cancel_destino,
            (cancel_lon IS NULL OR cancel_lat IS NULL) AS sin_gps,
            (minutos_entre_eventos > 5)                AS flag_tiempo,
            multiIf(
                pais = 'Colombia',              geoDistance(cancel_lon, cancel_lat, end_lon, end_lat) <= 450,
                pais IN ('Mexico','Nicaragua'),  geoDistance(cancel_lon, cancel_lat, end_lon, end_lat) <= 280,
                geoDistance(cancel_lon, cancel_lat, end_lon, end_lat) <= 450
            ) AS flag_distancia,
            multiIf(
                (minutos_entre_eventos > 5) AND multiIf(pais='Colombia',geoDistance(cancel_lon,cancel_lat,end_lon,end_lat)<=450,pais IN ('Mexico','Nicaragua'),geoDistance(cancel_lon,cancel_lat,end_lon,end_lat)<=280,geoDistance(cancel_lon,cancel_lat,end_lon,end_lat)<=450), 3,
                (minutos_entre_eventos > 5) AND (cancel_lon IS NULL OR cancel_lat IS NULL), 2,
                (minutos_entre_eventos > 5) OR  multiIf(pais='Colombia',geoDistance(cancel_lon,cancel_lat,end_lon,end_lat)<=450,pais IN ('Mexico','Nicaragua'),geoDistance(cancel_lon,cancel_lat,end_lon,end_lat)<=280,geoDistance(cancel_lon,cancel_lat,end_lon,end_lat)<=450), 2,
                0
            ) AS nivel,
            multiIf(pais='Colombia', costo_estimado*0.12, pais IN ('Mexico','Nicaragua'), costo_estimado*0.10, pais='Guatemala', costo_estimado*0.15, costo_estimado*0.15) AS comision_servicio,
            multiIf(pais='Colombia', costo_estimado*0.12*1.05, pais IN ('Mexico','Nicaragua'), costo_estimado*0.10*1.05, pais='Guatemala', costo_estimado*0.15*1.05, costo_estimado*0.15*1.05) AS comision_mas_penalizacion
        FROM base
        WHERE rn = 1
          AND (type_service != 'Mensajería' OR type_service = '' OR type_service IS NULL)
          AND (id_company IS NULL OR id_company = '')
    )
  SQL

  # ══════════════════════════════════════════════════════════════════════
  # Sufijos por query — se combinan con BASE_CTE
  # ══════════════════════════════════════════════════════════════════════
  KPIS_SUFFIX = <<~'SQL'
    SELECT
        count()                                              AS total,
        countIf(nivel = 3)                                   AS confirmadas,
        countIf(nivel = 2)                                   AS probables,
        countIf(nivel = 0)                                   AS ok,
        countIf(sin_gps = 1)                                 AS sin_gps,
        countIf(flag_tiempo = 1)                             AS flag_tiempo,
        countIf(flag_distancia = 1)                          AS flag_distancia,
        round(sumIf(comision_servicio,        nivel >= 2), 0) AS comision_evadida,
        round(sumIf(comision_mas_penalizacion, nivel = 3),  0) AS penalizacion_evadida,
        round(avgIf(minutos_entre_eventos,    nivel >= 2), 1) AS prom_minutos,
        round(avgIf(distancia_cancel_destino, nivel >= 2), 1) AS prom_distancia,
        uniqExact(id_driver)                                 AS pilotos_auditados,
        uniqExactIf(id_driver, nivel = 3)                    AS pilotos_evadieron
    FROM clasificado
  SQL

  TENDENCIA_SUFFIX = <<~'SQL'
    SELECT
        toDate(creacion_servicio) AS fecha,
        countIf(nivel = 3)        AS conf,
        countIf(nivel = 2)        AS prob,
        countIf(nivel = 0)        AS ok
    FROM clasificado
    GROUP BY fecha ORDER BY fecha
  SQL

  CIUDADES_SUFFIX = <<~'SQL'
    SELECT
        if(ciudad = '' OR ciudad IS NULL, 'Sin ciudad', ciudad) AS ciudad,
        countIf(nivel >= 2) AS evasiones
    FROM clasificado
    WHERE nivel >= 2
    GROUP BY ciudad ORDER BY evasiones DESC LIMIT 8
  SQL

  TOP_DRIVERS_SUFFIX = <<~'SQL'
    SELECT
        id_driver,
        any(name_driver)   AS nombre,
        countIf(nivel = 3) AS conf,
        countIf(nivel = 2) AS prob,
        count()            AS total,
        countIf(nivel = 3 AND toDate(creacion_servicio) <  toDate(toDateTime('%{fecha_desde}') + INTERVAL toUInt32(dateDiff('day', toDate('%{fecha_desde}'), toDate('%{fecha_hasta}'))/2) DAY)) AS conf_primera,
        countIf(nivel = 3 AND toDate(creacion_servicio) >= toDate(toDateTime('%{fecha_desde}') + INTERVAL toUInt32(dateDiff('day', toDate('%{fecha_desde}'), toDate('%{fecha_hasta}'))/2) DAY)) AS conf_segunda
    FROM clasificado
    WHERE nivel >= 2
    GROUP BY id_driver ORDER BY conf DESC, total DESC LIMIT 10
  SQL

  # Queries completas pre-armadas (mismo patrón que api.py Python)
  Q_KPIS        = BASE_CTE + KPIS_SUFFIX
  Q_TENDENCIA   = BASE_CTE + TENDENCIA_SUFFIX
  Q_CIUDADES    = BASE_CTE + CIUDADES_SUFFIX
  Q_TOP_DRIVERS = BASE_CTE + TOP_DRIVERS_SUFFIX
end
