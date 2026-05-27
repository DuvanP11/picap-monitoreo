# app/services/queries_service.rb
# Queries SQL — paridad con api.py Python + auxiliares para Rails.
#
# Módulos cubiertos en este archivo:
#   ✅ Evasión:      BASE_CTE + Q_KPIS + Q_TENDENCIA + Q_CIUDADES + Q_TOP_DRIVERS (paridad EXACTA Python)
#   ✅ Auth:         Q_USER_BY_USUARIO, Q_ALL_USERS
#   ✅ Wallet:       Q_WALLET (paridad Python, usa WalletAccountTransactionFraudCommission)
#   ✅ Recuperación: Q_WALLET_BY_DRIVER, Q_RESUMEN_PERIODO
#   ✅ RF:           Q_RF_RESUMEN, Q_RF_DETALLE
#   ⚠️  Stubs (se reescribirán en sus bloques): Q_ESTAFA, Q_BLOQUEOS, Q_RECAUDOS,
#       Q_PAGOS_STATS, TC_BASE_CTE, Q_AUDITORIA_COMISIONES
#
# Helpers públicos:
#   QueriesService.format(sql, **vars)
#   QueriesService.cte_con_pais(iso_pais, moneda = nil)
#   QueriesService.tasa_para(pais = nil)

module QueriesService

  # ════════════════════════════════════════════════════════════════════════
  # Configuración de país y tasas
  # ════════════════════════════════════════════════════════════════════════
  PAIS_A_ISO = {
    "Colombia"  => "CO", "Mexico" => "MX", "México" => "MX",
    "Nicaragua" => "NI", "Guatemala" => "GT", "Peru" => "PE",
    "Perú"      => "PE", "Ecuador" => "EC",
    "CO" => "CO", "MX" => "MX", "NI" => "NI", "GT" => "GT", "PE" => "PE", "EC" => "EC",
  }.freeze

  TASAS_PAIS = {
    "Colombia"  => 0.12, "Mexico" => 0.10, "Nicaragua" => 0.10, "Guatemala" => 0.15,
    "CO" => 0.12, "MX" => 0.10, "NI" => 0.10, "GT" => 0.15,
  }.freeze
  TASA_DEFAULT = 0.15

  # ════════════════════════════════════════════════════════════════════════
  # Helpers
  # ════════════════════════════════════════════════════════════════════════

  # Reemplaza %{key} por valor con gsub manual (evita Kernel#format que
  # se rompe con % en patrones LIKE de SQL).
  def self.format(sql, **vars)
    result = sql.dup
    vars.each { |k, v| result.gsub!("%{#{k}}", v.to_s) }
    result
  end

  # Inyecta filtro de país/moneda en BASE_CTE (replica .replace() de Python).
  def self.cte_con_pais(iso_pais, moneda = nil)
    extra = ""
    extra += " AND b.g_country = '#{iso_pais}'" if iso_pais && !iso_pais.to_s.strip.empty?
    extra += " AND JSONExtractString(b.final_cost, 'currency_iso') = '#{moneda}'" if moneda && !moneda.to_s.strip.empty?
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

  # ════════════════════════════════════════════════════════════════════════
  # EVASIÓN — BASE_CTE con paridad EXACTA al api.py Python (líneas 94-165)
  # NO usa columnas inexistentes (b.cancel_lat, b.end_lat, b.driver_lat).
  # Las extrae con extract() regex sobre b.events y JSONExtractString sobre
  # b.end_geojson.
  # ════════════════════════════════════════════════════════════════════════
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
                WHEN b.g_adm_area_lv_1 = '' OR b.g_adm_area_lv_1 IS NULL THEN 'Sin ciudad'
                -- Normalización de variantes (bookings.g_adm_area_lv_1 tiene
                -- mayúsculas/acentos/abreviaciones distintas para la misma ciudad).
                WHEN lowerUTF8(trim(b.g_adm_area_lv_1)) IN (
                    'bogotá d.c', 'bogota d.c', 'bogotá d.c.', 'bogota d.c.',
                    'bogotá dc', 'bogota dc', 'bogotá', 'bogota',
                    'd.c.', 'd. c.', 'dc'
                ) THEN 'Bogotá D.C.'
                WHEN lowerUTF8(trim(b.g_adm_area_lv_1)) IN (
                    'cdmx', 'ciudad de méxico', 'ciudad de mexico',
                    'distrito federal', 'df', 'mexico city'
                ) THEN 'Ciudad de México'
                WHEN lowerUTF8(trim(b.g_adm_area_lv_1)) IN ('medellín', 'medellin') THEN 'Medellín'
                WHEN lowerUTF8(trim(b.g_adm_area_lv_1)) IN ('cali', 'santiago de cali') THEN 'Cali'
                WHEN lowerUTF8(trim(b.g_adm_area_lv_1)) IN ('barranquilla') THEN 'Barranquilla'
                WHEN lowerUTF8(trim(b.g_adm_area_lv_1)) IN ('monterrey') THEN 'Monterrey'
                WHEN lowerUTF8(trim(b.g_adm_area_lv_1)) IN ('guadalajara') THEN 'Guadalajara'
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

  Q_KPIS        = BASE_CTE + KPIS_SUFFIX
  Q_TENDENCIA   = BASE_CTE + TENDENCIA_SUFFIX
  Q_CIUDADES    = BASE_CTE + CIUDADES_SUFFIX
  Q_TOP_DRIVERS = BASE_CTE + TOP_DRIVERS_SUFFIX

  # ════════════════════════════════════════════════════════════════════════
  # AUTH — gestión de usuarios del portal (tabla dashboard_users)
  # ════════════════════════════════════════════════════════════════════════
  Q_USER_BY_USUARIO = <<~'SQL'
    SELECT usuario, password_hash, nombre, email, rol, activo
    FROM picapmongoprod.dashboard_users FINAL
    WHERE usuario = '%{usuario}' AND activo = 1
    LIMIT 1
  SQL

  Q_ALL_USERS = <<~'SQL'
    SELECT usuario, nombre, email, rol,
           formatDateTime(creado_en, '%Y-%m-%d %H:%M') AS creado_en
    FROM picapmongoprod.dashboard_users FINAL
    WHERE activo = 1
    ORDER BY creado_en DESC
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # WALLET — paridad Python (api.py Q_WALLET, líneas 220-313)
  # Usa WalletAccountTransactionFraudCommission, NO wallet_accounts.balance_cents
  # Acepta filtro de país por %{filtro_pais} (insertado por el controller).
  # ════════════════════════════════════════════════════════════════════════
  Q_WALLET = <<~'SQL'
    WITH evasores AS (
        SELECT
            b._id AS booking_id,
            b.driver_id,
            CASE
                WHEN b.g_country = 'CO' THEN 'Colombia'
                WHEN b.g_country = 'MX' THEN 'Mexico'
                WHEN b.g_country = 'NI' THEN 'Nicaragua'
                WHEN b.g_country = 'GT' THEN 'Guatemala'
                ELSE 'Otro'
            END AS pais,
            toFloat64OrNull(JSONExtractString(b.estimated_cost,'cents')) / 100 AS costo_estimado,
            dateDiff('minute',
                parseDateTimeBestEffortOrNull(extract(ifNull(b.events,''), 'event_cd":20.*?created_at":"([^"]+)')),
                parseDateTimeBestEffortOrNull(extract(ifNull(b.events,''), 'event_cd":26.*?created_at":"([^"]+)'))
            ) AS minutos,
            geoDistance(
                toFloat64OrNull(extract(ifNull(b.events,''), 'event_cd":26.*?coordinates":\[\s*([+-]?\d+\.\d+)')),
                toFloat64OrNull(extract(ifNull(b.events,''), 'event_cd":26.*?coordinates":\[.*?,\s*([+-]?\d+\.\d+)')),
                toFloat64(JSONExtractString(b.end_geojson,'coordinates',1)),
                toFloat64(JSONExtractString(b.end_geojson,'coordinates',2))
            ) AS distancia
        FROM picapmongoprod.bookings b
        WHERE b.status_cd IN (100, 102)
          AND b.g_country IN ('CO','MX','NI','GT')%{filtro_pais}
          AND b.created_at >= toDateTime('%{fecha_desde} 00:00:00')
          AND b.created_at <= toDateTime('%{fecha_hasta} 23:59:59')
          AND NOT empty(b.origin_geojson)
          AND NOT empty(b.end_geojson)
    ),
    confirmados AS (
        SELECT
            e.booking_id,
            e.driver_id,
            multiIf(
                e.pais = 'Colombia',             e.costo_estimado * 0.12 * 1.05,
                e.pais IN ('Mexico','Nicaragua'), e.costo_estimado * 0.10 * 1.05,
                e.costo_estimado * 0.15 * 1.05
            ) AS comision_esperada
        FROM evasores e
        WHERE e.minutos > 5
          AND multiIf(
                e.pais = 'Colombia',             e.distancia <= 450,
                e.pais IN ('Mexico','Nicaragua'), e.distancia <= 280,
                e.distancia <= 450
              )
    ),
    cobros AS (
        SELECT
            w.booking_id,
            abs(toFloat64OrNull(JSONExtractString(w.amount,'cents')) / 100)          AS cobrado,
            toFloat64OrNull(JSONExtractString(w.amount_after_transaction,'cents')) / 100 AS saldo_post
        FROM picapmongoprod.wallet_account_transactions w
        WHERE w._type = 'WalletAccountTransactionFraudCommission'
          AND w.created_at >= toDateTime('%{fecha_desde} 00:00:00')
          AND w.created_at <= toDateTime('%{fecha_hasta} 23:59:59')
          AND w.booking_id IN (SELECT booking_id FROM confirmados)
    ),
    por_driver AS (
        SELECT
            c.driver_id,
            count()                                    AS n_evasiones,
            round(sum(c.comision_esperada), 0)         AS esperada,
            round(sum(ifNull(w.cobrado, 0)), 0)        AS cobrado,
            round(sum(c.comision_esperada) - sum(ifNull(w.cobrado, 0)), 0) AS deuda,
            countIf(ifNull(w.saldo_post, 0) >= 0)      AS n_pago,
            countIf(ifNull(w.saldo_post, -1) < 0)      AS n_negativo,
            multiIf(
                countIf(ifNull(w.saldo_post,-1) < 0) = 0, 'AL DÍA',
                countIf(ifNull(w.saldo_post, 0) >= 0) = 0, 'DEUDA TOTAL',
                'DEUDA PARCIAL'
            ) AS estado
        FROM confirmados c
        LEFT JOIN cobros w ON c.booking_id = w.booking_id
        GROUP BY c.driver_id
    )
    SELECT
        count()                                                      AS total_conductores,
        countIf(estado = 'AL DÍA')                                  AS conductores_pagaron,
        countIf(estado != 'AL DÍA')                                 AS conductores_no_pagaron,
        countIf(estado = 'DEUDA PARCIAL')                           AS deuda_parcial,
        countIf(estado = 'DEUDA TOTAL')                             AS deuda_total,
        round(sum(esperada), 0)                                      AS comision_esperada,
        round(sum(cobrado), 0)                                       AS cobrado_wallet,
        round(sum(deuda), 0)                                         AS brecha_no_cobrada,
        round(sumIf(cobrado, estado = 'AL DÍA'), 0)                 AS monto_pagado,
        round(sumIf(cobrado, estado != 'AL DÍA'), 0)                AS monto_cobrado_en_negativo,
        round(sumIf(deuda,   estado != 'AL DÍA'), 0)                AS monto_pendiente,
        round(sum(cobrado) / greatest(sum(esperada), 1) * 100, 1)   AS pct_recuperado
    FROM por_driver
  SQL

  # Recuperación: penalidad cobrada por día (para tendencia del panel 3)
  Q_RESUMEN_PERIODO = <<~'SQL'
    SELECT
        toDate(w.created_at)                                                       AS dia,
        round(sum(abs(toFloat64OrNull(JSONExtractString(w.amount,'cents'))/100)),0) AS cobrado_dia
    FROM picapmongoprod.wallet_account_transactions w
    WHERE w._type = 'WalletAccountTransactionFraudCommission'
      AND w.created_at >= toDateTime('%{desde} 00:00:00')
      AND w.created_at <= toDateTime('%{hasta} 23:59:59')
    GROUP BY dia
    ORDER BY dia
  SQL

  # Recuperación: penalidad por driver (top 10 evasores)
  Q_WALLET_BY_DRIVER = <<~'SQL'
    WITH confirmados AS (
        SELECT
            b._id AS booking_id, b.driver_id, b.g_country,
            toFloat64OrNull(JSONExtractString(b.estimated_cost,'cents')) / 100 AS costo_est
        FROM picapmongoprod.bookings b
        WHERE b.status_cd IN (100, 102)
          AND b.driver_id IN (%{ids})
          AND b.created_at >= toDateTime('%{desde} 00:00:00')
          AND b.created_at <= toDateTime('%{hasta} 23:59:59')
    ),
    cobros AS (
        SELECT w.booking_id,
               abs(toFloat64OrNull(JSONExtractString(w.amount,'cents')) / 100) AS cobrado
        FROM picapmongoprod.wallet_account_transactions w
        WHERE w._type = 'WalletAccountTransactionFraudCommission'
          AND w.booking_id IN (SELECT booking_id FROM confirmados)
    )
    SELECT
        c.driver_id,
        round(sum(multiIf(c.g_country='CO', c.costo_est*0.12*1.05,
                          c.g_country IN ('MX','NI'), c.costo_est*0.10*1.05,
                          c.costo_est*0.15*1.05)), 0)          AS penalidad_conf,
        round(sum(ifNull(w.cobrado, 0)), 0)                    AS pagado,
        round(sum(multiIf(c.g_country='CO', c.costo_est*0.12*1.05,
                          c.g_country IN ('MX','NI'), c.costo_est*0.10*1.05,
                          c.costo_est*0.15*1.05))
              - sum(ifNull(w.cobrado, 0)), 0)                  AS deuda
    FROM confirmados c
    LEFT JOIN cobros w ON c.booking_id = w.booking_id
    GROUP BY c.driver_id
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # RECONOCIMIENTO FACIAL
  # ════════════════════════════════════════════════════════════════════════
  Q_RF_RESUMEN = <<~'SQL'
    SELECT
        count()                                AS total_alertas,
        countIf(tipo_alerta = 'RF + IMEI')     AS total_rf_imei,
        countIf(tipo_alerta = 'RF')            AS total_rf,
        countIf(tipo_alerta = 'IMEI')          AS total_imei,
        countIf(nivel = 'FOTO_DUPLICADA')      AS total_duplicada,
        countIf(nivel = 'ALERTA')              AS total_alerta,
        countIf(nivel = 'REVISAR')             AS total_revisar,
        countIf(nivel = 'POSIBLE')             AS total_posible,
        round(maxIf(similitud, similitud > 0), 4) AS sim_max,
        round(avgIf(similitud, similitud > 0), 4) AS sim_avg,
        count(DISTINCT user_id_a)              AS pilotos
    FROM picapmongoprod.alertas_reconocimiento
    WHERE procesado_en >= toDateTime('%{desde} 00:00:00')
      AND procesado_en <= toDateTime('%{hasta} 23:59:59')
  SQL

  Q_RF_DETALLE = <<~'SQL'
    SELECT
        ifNull(tipo_alerta, 'RF')   AS tipo_alerta,
        nivel,
        toFloat64(similitud)        AS similitud,
        ifNull(mismo_imei, 'NO')    AS mismo_imei,
        toString(nombre_a)          AS nombre_a,
        toString(user_id_a)         AS user_id_a,
        toString(url_a)             AS url_a,
        toString(created_at_a)      AS created_at_a,
        toString(nombre_b)          AS nombre_b,
        toString(user_id_b)         AS user_id_b,
        toString(url_b)             AS url_b,
        toString(created_at_b)      AS created_at_b,
        procesado_en
    FROM picapmongoprod.alertas_reconocimiento
    WHERE procesado_en >= toDateTime('%{desde} 00:00:00')
      AND procesado_en <= toDateTime('%{hasta} 23:59:59')
    ORDER BY
        multiIf(tipo_alerta='RF + IMEI', 0, tipo_alerta='RF', 1, 2),
        similitud DESC
    LIMIT 300
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # PAGOS — TC + PromoCode (Bloque C, paridad api.py líneas 3066-3302)
  # Clasificación GPS:
  #   OK            → driver recibió pago wallet (pd.pagado > 0)
  #   Mala práctica → pagado=0 AND geoDistance(cancel → dest) ≤ radio país
  #   Fraude        → pagado=0 AND (sin GPS OR geoDistance > radio)
  # Radio: CO 450m | MX/NI 280m | resto 450m
  # ════════════════════════════════════════════════════════════════════════

  # CTE base TC: bookings con payment_method_cd='3', verification_required=false,
  # finalizados (4/107/108), con monto > 0, eventos y destino. Deduplica por _id.
  # Cruza con wallet_account_transactions para saber si el driver cobró.
  TC_BASE_CTE = <<~'SQL'
    WITH b_raw AS (
        SELECT
            b._id AS booking_id,
            b.driver_id,
            b.passenger_id,
            b.status_cd,
            b.g_country,
            b.g_adm_area_lv_1 AS ciudad_raw,
            toDate(toTimeZone(b.created_at,'America/Bogota')) AS fecha,
            toInt64(JSONExtractFloat(b.final_cost,'cents'))/100 AS monto,
            toFloat64OrNull(extract(ifNull(b.events,''), 'event_cd":26.*?coordinates":\[\s*([+-]?\d+\.\d+)')) AS cancel_lon,
            toFloat64OrNull(extract(ifNull(b.events,''), 'event_cd":26.*?coordinates":\[.*?,\s*([+-]?\d+\.\d+)')) AS cancel_lat,
            toFloat64(JSONExtractString(b.end_geojson,'coordinates',1)) AS end_lon,
            toFloat64(JSONExtractString(b.end_geojson,'coordinates',2)) AS end_lat,
            multiIf(b.g_country='CO',450,b.g_country IN ('MX','NI'),280,450) AS radio,
            ROW_NUMBER() OVER (PARTITION BY b._id ORDER BY b.created_at DESC) AS rn
        FROM picapmongoprod.bookings b
        WHERE b.payment_method_cd='3'
          AND b.verification_required='false'
          AND b.status_cd IN (4,107,108)
          AND b.created_at>=toDateTime('%{desde} 00:00:00')
          AND b.created_at<=toDateTime('%{hasta} 23:59:59')
          AND toInt64(JSONExtractFloat(b.final_cost,'cents'))>0
          AND b.events IS NOT NULL
          AND b.end_geojson IS NOT NULL
          %{filtro}
    ),
    b AS (SELECT * FROM b_raw WHERE rn=1),
    pd AS (
        SELECT booking_id,
               sum(toInt64(JSONExtractFloat(amount,'cents'))) AS pagado
        FROM picapmongoprod.wallet_account_transactions
        WHERE _type='WalletAccountTransactionBookingDriverPayment'
          AND toInt64(JSONExtractFloat(amount,'cents'))>0
          AND created_at>=toDateTime('%{desde} 00:00:00')
          AND created_at<=toDateTime('%{hasta} 23:59:59')
        GROUP BY booking_id
    )
  SQL

  # CTE base Promo: bookings finalizados que tienen al menos una transacción
  # de promoción (Multiple/Referral/ExpirePromo). Mismo set de campos que TC.
  PROMO_BASE_CTE = <<~'SQL'
    WITH promo AS (
        SELECT DISTINCT booking_id
        FROM picapmongoprod.wallet_account_transactions
        WHERE _type IN (
            'WalletAccountTransactionPromoCodeMultipleUse',
            'WalletAccountTransactionPromoCodeReferral',
            'WalletAccountTransactionExpirePromoBalance'
        )
        AND created_at>=toDateTime('%{desde} 00:00:00')
        AND created_at<=toDateTime('%{hasta} 23:59:59')
    ),
    b_raw AS (
        SELECT
            b._id AS booking_id,
            b.driver_id,
            b.passenger_id,
            b.status_cd,
            b.g_country,
            b.g_adm_area_lv_1 AS ciudad_raw,
            toDate(toTimeZone(b.created_at,'America/Bogota')) AS fecha,
            toInt64(JSONExtractFloat(b.final_cost,'cents'))/100 AS monto,
            toFloat64OrNull(extract(ifNull(b.events,''), 'event_cd":26.*?coordinates":\[\s*([+-]?\d+\.\d+)')) AS cancel_lon,
            toFloat64OrNull(extract(ifNull(b.events,''), 'event_cd":26.*?coordinates":\[.*?,\s*([+-]?\d+\.\d+)')) AS cancel_lat,
            toFloat64(JSONExtractString(b.end_geojson,'coordinates',1)) AS end_lon,
            toFloat64(JSONExtractString(b.end_geojson,'coordinates',2)) AS end_lat,
            multiIf(b.g_country='CO',450,b.g_country IN ('MX','NI'),280,450) AS radio,
            ROW_NUMBER() OVER (PARTITION BY b._id ORDER BY b.created_at DESC) AS rn
        FROM picapmongoprod.bookings b
        INNER JOIN promo ON b._id=promo.booking_id
        WHERE b.status_cd IN (4,107,108)
          AND b.created_at>=toDateTime('%{desde} 00:00:00')
          AND b.created_at<=toDateTime('%{hasta} 23:59:59')
          AND toInt64(JSONExtractFloat(b.final_cost,'cents'))>0
          AND b.events IS NOT NULL
          AND b.end_geojson IS NOT NULL
          %{filtro}
    ),
    b AS (SELECT * FROM b_raw WHERE rn=1),
    pd AS (
        SELECT booking_id,
               sum(toInt64(JSONExtractFloat(amount,'cents'))) AS pagado
        FROM picapmongoprod.wallet_account_transactions
        WHERE _type='WalletAccountTransactionBookingDriverPayment'
          AND toInt64(JSONExtractFloat(amount,'cents'))>0
          AND created_at>=toDateTime('%{desde} 00:00:00')
          AND created_at<=toDateTime('%{hasta} 23:59:59')
        GROUP BY booking_id
    )
  SQL

  # ── Sufijos clasificación + JOIN comunes para TC y Promo ──────────────
  # Cada SELECT usa: count(), ${PAGOS_CLS}, ${PAGOS_MONTO} sobre el JOIN.
  PAGOS_CLS = <<~'SQL'.strip
    countIf(coalesce(pd.pagado,0)>0) AS ok,
    countIf(coalesce(pd.pagado,0)=0
        AND b.cancel_lon IS NOT NULL AND b.cancel_lat IS NOT NULL
        AND geoDistance(b.cancel_lon,b.cancel_lat,b.end_lon,b.end_lat)<=b.radio) AS mala_practica,
    countIf(coalesce(pd.pagado,0)=0
        AND (b.cancel_lon IS NULL OR b.cancel_lat IS NULL
             OR geoDistance(b.cancel_lon,b.cancel_lat,b.end_lon,b.end_lat)>b.radio)) AS fraude
  SQL

  PAGOS_MONTO = <<~'SQL'.strip
    round(sumIf(b.monto, coalesce(pd.pagado,0)=0
        AND b.cancel_lon IS NOT NULL AND b.cancel_lat IS NOT NULL
        AND geoDistance(b.cancel_lon,b.cancel_lat,b.end_lon,b.end_lat)<=b.radio),0) AS monto_mp,
    round(sumIf(b.monto, coalesce(pd.pagado,0)=0
        AND (b.cancel_lon IS NULL OR b.cancel_lat IS NULL
             OR geoDistance(b.cancel_lon,b.cancel_lat,b.end_lon,b.end_lat)>b.radio)),0) AS monto_fraude,
    round(sum(b.monto),0) AS monto_total
  SQL

  PAGOS_JOIN = "FROM b LEFT JOIN pd ON b.booking_id=pd.booking_id".freeze

  PAGOS_PAIS_CASE   = "CASE b.g_country WHEN 'CO' THEN 'Colombia' WHEN 'MX' THEN 'Mexico' WHEN 'NI' THEN 'Nicaragua' WHEN 'GT' THEN 'Guatemala' ELSE b.g_country END".freeze
  PAGOS_CIUDAD_CASE = "multiIf(b.ciudad_raw='' OR b.ciudad_raw IS NULL,'Sin ciudad',b.ciudad_raw='MN','Managua',b.ciudad_raw='Guatemala Department','Guatemala',b.ciudad_raw)".freeze

  # ── Sufijos por tipo (KPIS / TREND / CIUDADES / DUO) ──────────────────
  KPIS_SUFFIX_PAGOS = <<~SQL
    SELECT count() AS total, #{PAGOS_CLS}, #{PAGOS_MONTO}
    #{PAGOS_JOIN}
  SQL

  TREND_SUFFIX_PAGOS = <<~SQL
    SELECT b.fecha AS fecha, #{PAGOS_CLS}
    #{PAGOS_JOIN}
    GROUP BY b.fecha ORDER BY b.fecha
  SQL

  CIUDADES_SUFFIX_PAGOS = <<~SQL
    SELECT #{PAGOS_CIUDAD_CASE} AS ciudad,
           #{PAGOS_PAIS_CASE}   AS pais,
           count() AS total, #{PAGOS_CLS}
    #{PAGOS_JOIN}
    GROUP BY ciudad, pais ORDER BY total DESC LIMIT 10
  SQL

  DUO_SUFFIX_PAGOS = <<~SQL
    SELECT b.driver_id, b.passenger_id,
           count() AS servicios,
           round(sum(b.monto),0) AS monto_total,
           countIf(coalesce(pd.pagado,0)=0
               AND (b.cancel_lon IS NULL OR b.cancel_lat IS NULL
                    OR geoDistance(b.cancel_lon,b.cancel_lat,b.end_lon,b.end_lat)>b.radio)) AS n_fraude,
           countIf(coalesce(pd.pagado,0)=0
               AND b.cancel_lon IS NOT NULL AND b.cancel_lat IS NOT NULL
               AND geoDistance(b.cancel_lon,b.cancel_lat,b.end_lon,b.end_lat)<=b.radio) AS n_mp
    #{PAGOS_JOIN}
    WHERE coalesce(pd.pagado,0)=0
    GROUP BY b.driver_id, b.passenger_id
    HAVING servicios >= 2
    ORDER BY servicios DESC, monto_total DESC LIMIT 20
  SQL

  # ── 8 queries finales (4 TC + 4 Promo) ────────────────────────────────
  Q_TC_KPIS     = TC_BASE_CTE + KPIS_SUFFIX_PAGOS
  Q_TC_TREND    = TC_BASE_CTE + TREND_SUFFIX_PAGOS
  Q_TC_CIUDADES = TC_BASE_CTE + CIUDADES_SUFFIX_PAGOS
  Q_TC_DUO      = TC_BASE_CTE + DUO_SUFFIX_PAGOS

  Q_PROMO_KPIS     = PROMO_BASE_CTE + KPIS_SUFFIX_PAGOS
  Q_PROMO_TREND    = PROMO_BASE_CTE + TREND_SUFFIX_PAGOS
  Q_PROMO_CIUDADES = PROMO_BASE_CTE + CIUDADES_SUFFIX_PAGOS
  Q_PROMO_DUO      = PROMO_BASE_CTE + DUO_SUFFIX_PAGOS

  # Helper: filtro adicional por país/ciudad (replica _pagos_filtro Python)
  def self.pagos_filtro(pais_iso, ciudad = nil)
    parts = []
    parts << "AND b.g_country='#{pais_iso}'" if pais_iso && !pais_iso.to_s.strip.empty?
    parts << "AND b.g_adm_area_lv_1='#{ciudad.to_s.gsub("'", "''")}'" if ciudad && !ciudad.to_s.strip.empty?
    parts.join(" ")
  end

  # ════════════════════════════════════════════════════════════════════════
  # ESTAFA (Bloque D, paridad api.py 3406-3863)
  # Detecta servicios con patrón financiero de estafa:
  #   Vía A: bookings cancelados por denuncia (cancelation_reason_cd=21) o
  #          seguridad (cd=13) Y con evento 26 confirmado.
  #   Vía B: servicios de mensajería (requested_service_type_id =
  #          '5c71b03a58b9ba10fa6393cf'), cualquier estado, cuyas pd.indications
  #          contengan al menos una palabra de KW_ESTAFA (51 keywords del
  #          EstafaController).
  # Para no traer millones de mensajerías limpias, se pre-filtra en SQL con
  # multiSearchAnyCaseInsensitive(indications, %{kws_estafa}).
  # ════════════════════════════════════════════════════════════════════════

  # Detalle: hasta %{limit_filas} filas enriquecidas con país, ciudad, IMEI,
  # nombre, estado de suspensión, etc. Una fila por booking (LIMIT 1 BY _id).
  Q_ESTAFA_BASE = <<~'SQL'
    WITH
    mensajeria_type AS (SELECT '5c71b03a58b9ba10fa6393cf' AS id),
    bk_raw AS (
        SELECT
            b._id,
            b.driver_id,
            b.passenger_id,
            b.company_id,
            toString(b.requested_service_type_id) AS service_type_id,
            toTimeZone(coalesce(b.scheduled_at, b.created_at), 'America/Bogota') AS fecha_servicio,
            CASE toInt64OrZero(b.cancelation_reason_cd)
                WHEN 21 THEN 'user_denounce'
                WHEN 13 THEN 'Security_issues'
                WHEN 0  THEN 'completed/active'
                ELSE concat('other_cancel_', toString(toInt64OrZero(b.cancelation_reason_cd)))
            END AS cancelation_reason,
            JSONExtractInt(
                arrayFirst(
                    x -> JSONExtractInt(x, 'event_cd') = 26,
                    JSONExtract(ifNull(b.events, '[]'), 'Array(String)')
                ),
                'event_cd'
            ) AS estado_cancelacion,
            toInt64OrZero(b.cancelation_reason_cd) AS cancel_reason_cd,
            ROW_NUMBER() OVER (PARTITION BY b._id ORDER BY b.created_at DESC) AS rn
        FROM picapmongoprod.bookings b
        WHERE (
            toInt64OrZero(b.cancelation_reason_cd) IN (21, 13)
            OR toString(b.requested_service_type_id) = (SELECT id FROM mensajeria_type)
        )
          AND b.created_at >= toDateTime('%{desde} 00:00:00')
          AND b.created_at <= toDateTime('%{hasta} 23:59:59')
          %{filtro_pais}
    ),
    bk AS (
        SELECT * FROM bk_raw
        WHERE rn = 1
          AND (
              (cancel_reason_cd IN (21, 13) AND estado_cancelacion = 26)
              OR service_type_id = (SELECT id FROM mensajeria_type)
          )
    ),
    pax AS (
        SELECT
            p._id AS id_user,
            p.name AS name_user,
            toString(p.is_driver_suspended) AS status_driver_suspend,
            toString(p.suspended)           AS status_user_suspend,
            toString(p.expelled)            AS status_expelled,
            p.g_country AS pais,
            p.g_adm_area_lv_1 AS departamento,
            p.g_adm_area_lv_2 AS city
        FROM picapmongoprod.passengers p
        WHERE p._id IN (SELECT passenger_id FROM bk)
    ),
    sess AS (
        SELECT
            passenger_id AS id_user,
            imei,
            active AS status_imei,
            ROW_NUMBER() OVER (PARTITION BY passenger_id ORDER BY created_at DESC) AS rn
        FROM picapmongoprod.sessions
        WHERE passenger_id IN (SELECT passenger_id FROM bk)
        QUALIFY rn = 1
    )
    SELECT
        bk.fecha_servicio,
        bk._id          AS booking_id,
        bk.driver_id,
        bk.passenger_id AS user_id,
        bk.service_type_id,
        bk.cancel_reason_cd,
        c.name          AS name_company,
        pax.name_user,
        pax.status_driver_suspend,
        pax.status_user_suspend,
        pax.status_expelled,
        sess.status_imei,
        sess.imei       AS imei_sesion,
        pax.pais,
        pax.departamento,
        pax.city,
        bk.cancelation_reason,
        pd.indications
    FROM bk
    LEFT JOIN pax  ON bk.passenger_id = pax.id_user
    LEFT JOIN sess ON bk.passenger_id = sess.id_user
    LEFT JOIN picapmongoprod.companies c ON bk.company_id = c._id
    INNER JOIN picapmongoprod.packages pd ON pd.booking_id = bk._id
    WHERE (
        bk.cancel_reason_cd IN (21, 13)
        OR multiSearchAnyCaseInsensitive(coalesce(pd.indications, ''), %{kws_estafa}) > 0
    )
    ORDER BY bk.fecha_servicio DESC
    LIMIT 1 BY bk._id
    LIMIT %{limit_filas}
  SQL

  # Agregado por día — total real sin LIMIT
  Q_ESTAFA_AGREGADO = <<~'SQL'
    WITH
    mensajeria_type AS (SELECT '5c71b03a58b9ba10fa6393cf' AS id),
    bk_raw AS (
        SELECT
            b._id,
            b.passenger_id,
            toTimeZone(coalesce(b.scheduled_at, b.created_at), 'America/Bogota') AS fecha_servicio,
            toString(b.requested_service_type_id) AS service_type_id,
            toInt64OrZero(b.cancelation_reason_cd) AS cancel_reason_cd,
            JSONExtractInt(
                arrayFirst(
                    x -> JSONExtractInt(x, 'event_cd') = 26,
                    JSONExtract(ifNull(b.events, '[]'), 'Array(String)')
                ),
                'event_cd'
            ) AS estado_cancelacion,
            ROW_NUMBER() OVER (PARTITION BY b._id ORDER BY b.created_at DESC) AS rn
        FROM picapmongoprod.bookings b
        WHERE (
            toInt64OrZero(b.cancelation_reason_cd) IN (21, 13)
            OR toString(b.requested_service_type_id) = (SELECT id FROM mensajeria_type)
        )
          AND b.created_at >= toDateTime('%{desde} 00:00:00')
          AND b.created_at <= toDateTime('%{hasta} 23:59:59')
          %{filtro_pais}
    ),
    bk AS (
        SELECT * FROM bk_raw
        WHERE rn = 1
          AND (
              (cancel_reason_cd IN (21, 13) AND estado_cancelacion = 26)
              OR service_type_id = (SELECT id FROM mensajeria_type)
          )
    )
    SELECT
        dia,
        count() AS total_dia,
        countIf(has_kw) AS estafa_dia
    FROM (
        SELECT
            bk._id AS booking_id,
            toDate(bk.fecha_servicio) AS dia,
            multiSearchAnyCaseInsensitive(coalesce(pd.indications, ''), %{kws_estafa}) > 0 AS has_kw
        FROM bk
        INNER JOIN picapmongoprod.packages pd ON pd.booking_id = bk._id
        WHERE (
            bk.cancel_reason_cd IN (21, 13)
            OR multiSearchAnyCaseInsensitive(coalesce(pd.indications, ''), %{kws_estafa}) > 0
        )
        LIMIT 1 BY bk._id
    )
    GROUP BY dia
    ORDER BY dia
  SQL

  # Cuentas (passenger_id) únicas con / sin servicio clasificado como estafa
  Q_ESTAFA_CUENTAS = <<~'SQL'
    WITH
    mensajeria_type AS (SELECT '5c71b03a58b9ba10fa6393cf' AS id),
    bk_raw AS (
        SELECT
            b._id,
            b.passenger_id,
            toString(b.requested_service_type_id) AS service_type_id,
            toInt64OrZero(b.cancelation_reason_cd) AS cancel_reason_cd,
            JSONExtractInt(
                arrayFirst(
                    x -> JSONExtractInt(x, 'event_cd') = 26,
                    JSONExtract(ifNull(b.events, '[]'), 'Array(String)')
                ),
                'event_cd'
            ) AS estado_cancelacion,
            ROW_NUMBER() OVER (PARTITION BY b._id ORDER BY b.created_at DESC) AS rn
        FROM picapmongoprod.bookings b
        WHERE (
            toInt64OrZero(b.cancelation_reason_cd) IN (21, 13)
            OR toString(b.requested_service_type_id) = (SELECT id FROM mensajeria_type)
        )
          AND b.created_at >= toDateTime('%{desde} 00:00:00')
          AND b.created_at <= toDateTime('%{hasta} 23:59:59')
          %{filtro_pais}
    ),
    bk AS (
        SELECT * FROM bk_raw
        WHERE rn = 1
          AND (
              (cancel_reason_cd IN (21, 13) AND estado_cancelacion = 26)
              OR service_type_id = (SELECT id FROM mensajeria_type)
          )
    ),
    booking_user AS (
        SELECT
            bk._id AS booking_id,
            bk.passenger_id AS user_id,
            multiSearchAnyCaseInsensitive(coalesce(pd.indications, ''), %{kws_estafa}) > 0 AS has_kw
        FROM bk
        INNER JOIN picapmongoprod.packages pd ON pd.booking_id = bk._id
        WHERE (
            bk.cancel_reason_cd IN (21, 13)
            OR multiSearchAnyCaseInsensitive(coalesce(pd.indications, ''), %{kws_estafa}) > 0
        )
        LIMIT 1 BY bk._id
    ),
    por_user AS (
        SELECT
            user_id,
            max(has_kw) AS user_has_estafa
        FROM booking_user
        WHERE user_id != ''
        GROUP BY user_id
    )
    SELECT
        count()                            AS total_cuentas,
        countIf(user_has_estafa)           AS cuentas_estafa,
        count() - countIf(user_has_estafa) AS cuentas_ok
    FROM por_user
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # RECAUDOS (Bloque E, paridad api.py 3866-3942)
  # Audita WalletAccountCounterDeliveryTransaction — el piloto recauda al
  # cliente y abona a Picap. Si la suma negativa (recaudo) + positiva (abono)
  # cuadran a 0, está OK. Diferencia → deuda en alguna dirección.
  # Clasificación:
  #   Correcto      → balance_neto = 0
  #   Pagado_demas  → balance_neto > 0 (Picap le debe al piloto)
  #   Debe_dinero   → balance_neto < 0 (piloto debe a Picap)
  #   Revisar       → balance_neto IS NULL OR (pos>0 AND neg>0 AND neto ≈ 0
  #                   AND cnt_total > 2 → mucha actividad neta cero, atípico)
  # ════════════════════════════════════════════════════════════════════════
  Q_RECAUDOS = <<~'SQL'
    WITH deduplicated AS (
        SELECT
            toTimeZone(wat.created_at, 'America/Bogota') AS fecha_tx,
            wat.booking_id AS id_booking,
            wat._id,
            wat._type AS tipo_tx,
            JSONExtractString(wat.amount, 'currency_iso') AS moneda,
            toFloat64OrNull(JSONExtractString(wat.amount, 'cents')) / 100 AS valor,
            ROW_NUMBER() OVER (PARTITION BY wat._id ORDER BY wat.created_at DESC) AS rn
        FROM picapmongoprod.wallet_account_transactions wat
        WHERE wat._type = 'WalletAccountCounterDeliveryTransaction'
          AND wat.created_at >= toDateTime('%{desde} 00:00:00')
          AND wat.created_at <= toDateTime('%{hasta} 23:59:59')
          %{filtro_moneda}
    ),
    base AS (
        SELECT fecha_tx, id_booking, _id, tipo_tx, moneda, valor
        FROM deduplicated
        WHERE rn = 1
    ),
    bookings_en_rango AS (
        SELECT DISTINCT id_booking
        FROM base
        WHERE fecha_tx >= toDateTime('%{desde} 00:00:00')
          AND fecha_tx <= toDateTime('%{hasta} 23:59:59')
    ),
    agregado AS (
        SELECT
            b.id_booking,
            any(b.fecha_tx)                                              AS fecha_tx,
            b.tipo_tx,
            b.moneda,
            sumIf(b.valor, b.valor < 0)                                  AS suma_negativos,
            sumIf(b.valor, b.valor > 0)                                  AS suma_positivos,
            sumIf(b.valor, b.valor > 0) + sumIf(b.valor, b.valor < 0)    AS balance_neto,
            countIf(b.valor < 0)                                         AS cnt_negativos,
            countIf(b.valor > 0)                                         AS cnt_positivos,
            count()                                                      AS cnt_total
        FROM base b
        INNER JOIN bookings_en_rango br ON b.id_booking = br.id_booking
        GROUP BY b.id_booking, b.tipo_tx, b.moneda
    )
    SELECT
        id_booking,
        toString(fecha_tx) AS fecha_tx,
        tipo_tx,
        moneda,
        round(suma_negativos, 2)  AS suma_negativos,
        round(suma_positivos, 2)  AS suma_positivos,
        round(balance_neto, 2)    AS balance_neto,
        cnt_negativos,
        cnt_positivos,
        cnt_total,
        CASE
            WHEN balance_neto IS NULL OR (cnt_positivos > 0 AND cnt_negativos > 0
                 AND abs(suma_positivos + suma_negativos) < 0.01
                 AND cnt_total > 2)                          THEN 'Revisar'
            WHEN balance_neto = 0                            THEN 'Correcto'
            WHEN balance_neto > 0                            THEN 'Pagado_demas'
            WHEN balance_neto < 0                            THEN 'Debe_dinero'
            ELSE 'Revisar'
        END AS clasificacion
    FROM agregado
    ORDER BY abs(balance_neto) DESC
    LIMIT 3000
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # RECAUDOS V2 — Detalle por booking (reemplaza Q_RECAUDOS para v2 del módulo)
  # Una fila por booking con: piloto, comercio, valor svc, recaudos +/-, neto,
  # clasificación (DEBE/AL DIA/PAGADO DE MAS/SIN RECAUDO) y tipo_deuda
  # (PICASH | IDA Y VUELTA según return_to_origin).
  # ════════════════════════════════════════════════════════════════════════
  Q_RECAUDOS_DETALLE = <<~'SQL'
    WITH
        bookings_periodo AS (
            SELECT *
            FROM (
                SELECT
                    b._id, b.driver_id, b.company_id,
                    b.return_to_origin, b.created_at, b.final_cost,
                    b.g_country, b.g_adm_area_lv_1,
                    ROW_NUMBER() OVER (PARTITION BY b._id ORDER BY b._sdc_batched_at DESC) AS rn
                FROM picapmongoprod.bookings b
                WHERE b.created_at >= toDateTime('%{desde} 00:00:00')
                  AND b.created_at <= toDateTime('%{hasta} 23:59:59')
                  %{filtro_pais}
            )
            WHERE rn = 1
        ),
        wat_servicio AS (
            SELECT *
            FROM (
                SELECT
                    wat._id, wat.booking_id, wat.created_at,
                    toFloat64OrNull(JSONExtractString(wat.amount, 'cents')) / 100 AS monto,
                    JSONExtractString(wat.amount, 'currency_iso') AS moneda,
                    ROW_NUMBER() OVER (PARTITION BY wat._id ORDER BY wat._sdc_batched_at DESC) AS rn
                FROM picapmongoprod.wallet_account_transactions wat
                WHERE wat._type = 'WalletAccountCounterDeliveryTransaction'
                  AND wat.booking_id IN (SELECT _id FROM bookings_periodo)
            )
            WHERE rn = 1
        ),
        recaudo_booking AS (
            SELECT
                booking_id,
                any(moneda)                       AS moneda,
                round(sum(monto), 2)              AS recaudo_neto,
                round(sumIf(monto, monto > 0), 2) AS total_positivo,
                round(sumIf(monto, monto < 0), 2) AS total_negativo,
                count()                           AS n_recaudos,
                countIf(monto > 0)                AS n_recaudos_positivos,
                countIf(monto < 0)                AS n_recaudos_negativos
            FROM wat_servicio
            GROUP BY booking_id
        ),
        passengers_dedup AS (
            SELECT _id,
                   argMax(name, _sdc_batched_at)      AS name,
                   argMax(last_name, _sdc_batched_at) AS last_name
            FROM picapmongoprod.passengers
            WHERE _id IN (SELECT driver_id FROM bookings_periodo WHERE driver_id != '')
            GROUP BY _id
        ),
        companies_dedup AS (
            SELECT _id, argMax(name, _sdc_batched_at) AS name
            FROM picapmongoprod.companies
            WHERE _id IN (SELECT company_id FROM bookings_periodo WHERE company_id != '')
            GROUP BY _id
        )
    SELECT
        bk.driver_id                                                                AS driver_id,
        bk._id                                                                       AS booking_id,
        bk.company_id                                                                AS company_id,
        trim(concat(coalesce(pd.name, ''), ' ', coalesce(pd.last_name, '')))         AS nombre_piloto,
        coalesce(co.name, '')                                                        AS comercio,
        toString(toTimeZone(bk.created_at, 'America/Bogota'))                        AS fecha_servicio,
        bk.g_country                                                                 AS pais,
        coalesce(nullIf(bk.g_adm_area_lv_1, ''), 'Sin ciudad')                       AS ciudad,
        rb.moneda                                                                    AS moneda,
        round(toFloat64OrNull(JSONExtractString(bk.final_cost, 'cents')) / 100, 2)   AS valor_servicio,
        rb.total_positivo                                                            AS total_positivo,
        rb.total_negativo                                                            AS total_negativo,
        rb.recaudo_neto                                                              AS recaudo_neto,
        rb.n_recaudos                                                                AS n_recaudos,
        rb.n_recaudos_positivos                                                      AS n_recaudos_positivos,
        rb.n_recaudos_negativos                                                      AS n_recaudos_negativos,
        CASE WHEN lower(coalesce(toString(bk.return_to_origin), '')) IN ('true','1','t') THEN 'SI' ELSE 'NO' END AS ida_y_vuelta,
        multiIf(
            rb.n_recaudos = 0 OR rb.n_recaudos IS NULL, 'SIN RECAUDO',
            rb.recaudo_neto < -0.01,                    'DEBE',
            rb.recaudo_neto >  0.01,                    'PAGADO DE MAS',
                                                        'AL DIA'
        )                                                                            AS debe,
        CASE
            WHEN lower(coalesce(toString(bk.return_to_origin), '')) IN ('true','1','t') THEN 'IDA Y VUELTA'
            ELSE 'PICASH'
        END                                                                          AS tipo_deuda
    FROM recaudo_booking rb
    INNER JOIN bookings_periodo bk ON bk._id = rb.booking_id
    LEFT  JOIN passengers_dedup pd ON pd._id = bk.driver_id
    LEFT  JOIN companies_dedup  co ON co._id = bk.company_id
    ORDER BY bk.created_at DESC
    LIMIT %{limit_filas}
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # AUDITORÍA COMERCIAL (Bloque F, paridad api.py 4047-4395)
  # Auditoría de tarifas/comisiones/créditos de empresas (companies + fare_configs).
  # Solo Colombia, solo bookings status_cd=4 (finalizados). Filtra opcional por
  # company_id, tarifa_id, moneda, último servicio en rango, anti-test.
  # ════════════════════════════════════════════════════════════════════════
  Q_AUDITORIA_BASE = <<~'SQL'
    WITH bookings_filtered AS (
        SELECT
            company_id,
            created_at,
            _id AS booking_id,
            toFloat64OrNull(JSONExtractString(final_cost,'cents')) / 100 AS final_cost
        FROM picapmongoprod.bookings
        WHERE status_cd = 4
          AND g_country = 'CO'
          AND created_at >= toDateTime('%{desde} 00:00:00')
          AND created_at <= toDateTime('%{hasta} 23:59:59')
    ),
    last_booking AS (
        SELECT company_id, max(created_at) AS last_created_at
        FROM bookings_filtered
        GROUP BY company_id
    ),
    fare_configs_ext AS (
        SELECT DISTINCT
            _id,
            company_parent_id  AS company_parent_id_extracted,
            service_type_id    AS service_type_id_extracted,
            geo_fence_id       AS geo_fence_id_extracted,
            toFloat64OrNull(JSONExtractString(base_fare,'cents'))         / 100 AS base_fare,
            toFloat64OrNull(JSONExtractString(minimum_fare,'cents'))       / 100 AS minimum_fare,
            toFloat64OrNull(JSONExtractString(distance_fare,'cents'))      / 100 AS distance_fare,
            toFloat64OrNull(JSONExtractString(hour_fare,'cents'))          / 100 AS hour_fare,
            toFloat64OrNull(JSONExtractString(extra_stop_fare,'cents'))    / 100 AS extra_stop_fare,
            toFloat64OrNull(JSONExtractString(package_fare,'cents'))       / 100 AS package_fare,
            toFloat64OrNull(JSONExtractString(hour_base_fare,'cents'))     / 100 AS hour_base_fare,
            toFloat64OrNull(JSONExtractString(hour_standby_fare,'cents'))  / 100 AS hour_standby_fare,
            company_commission_percentage AS utilidad_corporativa
        FROM picapmongoprod.fare_configs FINAL
        %{filtro_tarifa}
    ),
    company_auth_ext AS (
        SELECT company_id AS company_id_extracted,
               active     AS active_extracted
        FROM picapmongoprod.company_authorization_logs
    ),
    base AS (
        SELECT
            CASE
                WHEN a.active_extracted = 'false' THEN 'inactivo'
                ELSE 'activo'
            END AS estado,
            com._id                                                       AS id_company,
            lb.last_created_at                                            AS last_service,
            com.name                                                      AS linea_de_negocio,
            com.commercial_manager_id                                     AS commercial_manager,
            d.name                                                        AS name_manager,
            fc._id                                                        AS tarifa_id,
            JSONExtractString(tst.name,'es')                              AS type_service,
            if(JSONExtractString(ci.name,'es') IS NULL,'Colombia',
               JSONExtractString(ci.name,'es'))                           AS ciudad,
            JSONExtractString(com.max_wallet_negative,'currency_iso')     AS moneda,
            fc.base_fare, fc.minimum_fare, fc.distance_fare,
            fc.hour_fare, fc.extra_stop_fare, fc.package_fare,
            fc.hour_base_fare, fc.hour_standby_fare,
            toFloat64OrNull(com.commission_percentage)                    AS comission,
            fc.utilidad_corporativa,
            toFloat64OrNull(JSONExtractString(com.max_wallet_negative,'cents')) / 100 AS credit,
            toFloat64OrNull(JSONExtractString(com.max_declared_value,'cents'))  / 100 AS valor_declarado,
            ROW_NUMBER() OVER (PARTITION BY fc._id ORDER BY lb.last_created_at DESC) AS rn
        FROM picapmongoprod.companies com
        INNER JOIN picapmongoprod.countries co ON co._id = com.geo_fence_id
        LEFT JOIN fare_configs_ext fc ON fc.company_parent_id_extracted = com._id
        LEFT JOIN picapmongoprod.service_types tst ON tst._id = fc.service_type_id_extracted
        LEFT JOIN last_booking lb ON com._id = lb.company_id
        LEFT JOIN company_auth_ext a ON com._id = a.company_id_extracted
        LEFT JOIN picapmongoprod.cities ci ON ci._id = fc.geo_fence_id_extracted
        LEFT JOIN picapmongoprod.passengers d ON com.commercial_manager_id = d._id
        WHERE com._type = 'Company'
          AND fc._id IS NOT NULL
          %{filtro_company}
          %{filtro_moneda}
          %{anti_test}
    )
    SELECT
        estado, id_company, last_service, linea_de_negocio,
        commercial_manager, name_manager, tarifa_id, type_service,
        ciudad, moneda, base_fare, minimum_fare, distance_fare,
        hour_fare, extra_stop_fare, package_fare, hour_base_fare,
        hour_standby_fare, comission, utilidad_corporativa, credit,
        valor_declarado
    FROM base
    WHERE rn = 1
      %{filtro_last_service}
    ORDER BY last_service DESC, name_manager
    LIMIT 5000
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # PIBOX B2B — Alertas de fraude (Bloque F, paridad api.py 6770-7351)
  # Detecta servicios B2B con:
  #   - Tiempo < 5 min (no recogió/no entregó)
  #   - Mismo punto GPS sin retorno a origen ni reserva (fraude claro)
  #   - Montos excesivos por tipo servicio (Mensajería >400k, Carga Carry >800k,
  #     Carga Moto >600k, Cruz Verde Mostrador >80k)
  # Excluye clientes test/qa/onboarding/demo y TADA (con excepción Cruz Verde Integ.)
  # ════════════════════════════════════════════════════════════════════════
  Q_PIBOX_BASE = <<~'SQL'
    WITH
    /* 1) Companies: filtro anti-test EMPUJADO + dedup. Tabla chica. */
    companies_clean AS (
        SELECT
            _id,
            argMax(name, _sdc_batched_at) AS name
        FROM picapmongoprod.companies
        WHERE LOWER(name) NOT LIKE '%tada%'
          AND LOWER(name) NOT LIKE '%test%'
          AND LOWER(name) NOT LIKE '%prueba%'
          AND LOWER(name) NOT LIKE '%qa%'
          AND LOWER(name) NOT LIKE '%onboarding%'
          AND LOWER(name) NOT LIKE '%demo%'
        GROUP BY _id
    ),

    /* 2) Bookings: ROW_NUMBER en vez de FINAL.
          company_id IN (companies_clean) empujado → recorta bookings antes del merge.
          Alias b preservado para %{filtros_adicionales}. */
    bookings_dedup AS (
        SELECT
            _id, driver_id, passenger_id, company_id,
            created_at, status_cd, requested_service_type_id,
            g_country, g_adm_area_lv_1,
            company_final_cost, origin_geojson, end_geojson, events,
            return_to_origin, original_booking_reservation_id, updated_at
        FROM (
            SELECT
                b._id, b.driver_id, b.passenger_id, b.company_id,
                b.created_at, b.status_cd, b.requested_service_type_id,
                b.g_country, b.g_adm_area_lv_1,
                b.company_final_cost, b.origin_geojson, b.end_geojson, b.events,
                b.return_to_origin, b.original_booking_reservation_id, b.updated_at,
                ROW_NUMBER() OVER (PARTITION BY b._id ORDER BY b.created_at DESC) AS rn
            FROM picapmongoprod.bookings AS b
            WHERE b.status_cd IN (4, 107, 108)
              AND b.company_id IS NOT NULL
              AND b.company_id != ''
              AND toDate(b.created_at) BETWEEN '%{fecha_desde}' AND '%{fecha_hasta}'
              AND b.company_id IN (SELECT _id FROM companies_clean)
              AND NOT (b.events LIKE '%"event_cd":103%')
              %{filtros_adicionales}
        )
        WHERE rn = 1
    ),

    /* 3) Passengers: solo drivers de bookings_dedup; argMax por _sdc_batched_at. */
    passengers_dedup AS (
        SELECT
            _id,
            argMax(name,      _sdc_batched_at) AS name,
            argMax(last_name, _sdc_batched_at) AS last_name,
            argMax(email,     _sdc_batched_at) AS email,
            argMax(phone,     _sdc_batched_at) AS phone
        FROM picapmongoprod.passengers
        WHERE _id IN (SELECT DISTINCT driver_id FROM bookings_dedup WHERE driver_id != '')
        GROUP BY _id
    ),

    /* 4) DVE activos para esos drivers. ROW_NUMBER por _id para dedup
          (preserva semántica original: N vehículos activos → N filas). */
    dve_dedup AS (
        SELECT _id, driver_id, vehicle_id
        FROM (
            SELECT _id, driver_id, vehicle_id,
                   ROW_NUMBER() OVER (PARTITION BY _id ORDER BY _id) AS rn
            FROM picapmongoprod.driver_vehicle_enrollments
            WHERE enrollment_status_cd = 3
              AND driver_id IN (SELECT DISTINCT driver_id FROM bookings_dedup WHERE driver_id != '')
        )
        WHERE rn = 1
    ),

    /* 5) Vehicles solo de DVE activos */
    vehicles_dedup AS (
        SELECT _id, argMax(vehicle_type_id, _sdc_batched_at) AS vehicle_type_id
        FROM picapmongoprod.vehicles
        WHERE _id IN (SELECT vehicle_id FROM dve_dedup WHERE vehicle_id != '')
        GROUP BY _id
    ),

    /* 6) Vehicle types solo de los vehículos referenciados */
    vehicle_types_dedup AS (
        SELECT _id, argMax(name, _sdc_batched_at) AS name
        FROM picapmongoprod.vehicle_types
        WHERE _id IN (SELECT vehicle_type_id FROM vehicles_dedup WHERE vehicle_type_id != '')
        GROUP BY _id
    ),

    /* 7) Proyección de salida (idéntica al original) */
    servicios_pibox AS (
        SELECT
            b._id AS booking_id,
            b.driver_id,
            b.passenger_id,
            b.company_id,
            toTimeZone(b.created_at, 'America/Bogota') AS fecha_servicio,
            b.status_cd,
            b.requested_service_type_id,
            CONCAT(p.name, ' ', COALESCE(p.last_name, '')) AS piloto_nombre,
            p.email AS piloto_email,
            p.phone AS piloto_telefono,
            c.name AS cliente_nombre,
            JSONExtractString(vt.name, 'es') AS tipo_vehiculo,
            CASE b.g_country
                WHEN 'CO' THEN 'Colombia'
                WHEN 'MX' THEN 'México'
                WHEN 'NI' THEN 'Nicaragua'
                WHEN 'GT' THEN 'Guatemala'
                ELSE b.g_country
            END AS pais,
            CASE
                WHEN b.g_adm_area_lv_1 = 'MN' THEN 'Managua'
                WHEN b.g_adm_area_lv_1 = 'Guatemala Department' THEN 'Guatemala'
                WHEN b.g_adm_area_lv_1 = '' THEN 'Sin ciudad'
                ELSE b.g_adm_area_lv_1
            END AS ciudad,
            toFloat64OrZero(JSONExtractString(b.company_final_cost, 'cents')) / 100 AS monto_pagado,
            JSONExtractString(b.company_final_cost, 'currency_iso') AS moneda,
            JSONExtractFloat(b.origin_geojson, 'coordinates', 1) AS origin_longitude,
            JSONExtractFloat(b.origin_geojson, 'coordinates', 2) AS origin_latitude,
            JSONExtractFloat(b.end_geojson, 'coordinates', 1) AS destination_longitude,
            JSONExtractFloat(b.end_geojson, 'coordinates', 2) AS destination_latitude,
            extract(COALESCE(b.events,''), 'event_cd":22.*?created_at":"([^"]+)') AS ev_recogido,
            extract(COALESCE(b.events,''), 'event_cd":24.*?created_at":"([^"]+)') AS ev_finalizado,
            IF(
                lower(COALESCE(toString(b.return_to_origin), '')) IN ('true', '1', 't'),
                1, 0
            ) AS return_to_origin,
            COALESCE(toString(b.original_booking_reservation_id), '') AS original_booking_reservation_id,
            IF(COALESCE(toString(b.original_booking_reservation_id), '') = '', 0, 1) AS tiene_reserva,
            b.updated_at,
            1 AS rn
        FROM bookings_dedup        AS b
        INNER JOIN companies_clean       AS c   ON c._id = b.company_id
        LEFT  JOIN passengers_dedup      AS p   ON p._id = b.driver_id
        LEFT  JOIN dve_dedup             AS dve ON dve.driver_id = b.driver_id
        LEFT  JOIN vehicles_dedup        AS v   ON v._id = dve.vehicle_id
        LEFT  JOIN vehicle_types_dedup   AS vt  ON vt._id = v.vehicle_type_id
    ),

    con_tiempos AS (
        SELECT
            sp.*,
            dateDiff('minute',
                parseDateTimeBestEffortOrNull(ev_recogido),
                parseDateTimeBestEffortOrNull(ev_finalizado)
            ) AS minutos_servicio,
            IF(
                abs(origin_latitude - destination_latitude) < %{tolerancia_gps}
                AND abs(origin_longitude - destination_longitude) < %{tolerancia_gps},
                1, 0
            ) AS flag_mismo_punto,
            IF(
                abs(origin_latitude - destination_latitude) < %{tolerancia_gps}
                AND abs(origin_longitude - destination_longitude) < %{tolerancia_gps}
                AND return_to_origin = 0
                AND tiene_reserva = 0,
                1, 0
            ) AS flag_alerta_mismo_punto,
            round(geoDistance(origin_longitude, origin_latitude,
                             destination_longitude, destination_latitude), 2) AS distancia_recorrido
        FROM servicios_pibox sp
    )
    SELECT * FROM con_tiempos
  SQL

  # Anti-test expr para auditoría (replica _ANTI_TEST_EXPR del Python)
  AUDITORIA_ANTI_TEST_EXPR = <<~'SQL'.gsub("\n", " ").strip
    NOT multiSearchAnyCaseInsensitive(
        lowerUTF8(concat(
            ifNull(com.name,''), ' ',
            ifNull(d.name,''), ' ',
            ifNull(com.commercial_manager_id,'')
        )),
        ['test','testeo','pruebas','qa','dummy','sandbox',
         'demo','ejemplo','testing','user test','internal',
         'liliana peña','liliana pena',
         'pibox admin']
    )
  SQL

  # Helper auditoría: construye los 5 filtros dinámicos
  def self.auditoria_filtros(company_id: "", tarifa_id: "", moneda: "",
                             anti_test: true, last_desde: "", last_hasta: "")
    fc = company_id.to_s.empty? ? "" : "AND com._id = '#{company_id.gsub("'", "''")}'"
    ft = tarifa_id.to_s.empty? ? "" : "WHERE _id = '#{tarifa_id.gsub("'", "''")}'"
    fm = moneda.to_s.empty?    ? "" : "AND JSONExtractString(com.max_wallet_negative,'currency_iso') = '#{moneda.gsub("'", "''")}'"
    at = anti_test ? "AND #{AUDITORIA_ANTI_TEST_EXPR}" : ""
    fls = []
    fls << "AND toTimeZone(last_service,'America/Bogota') >= '#{last_desde} 00:00:00'" unless last_desde.to_s.empty?
    fls << "AND toTimeZone(last_service,'America/Bogota') <= '#{last_hasta} 23:59:59'" unless last_hasta.to_s.empty?
    {
      filtro_company:      fc,
      filtro_tarifa:       ft,
      filtro_moneda:       fm,
      anti_test:           at,
      filtro_last_service: fls.join(" "),
    }
  end

  # ════════════════════════════════════════════════════════════════════════
  # BLOQUEOS — Estadística General (api.py 5677-5751)
  # Diferente de Q_BLOQUEOS (que devuelve filas individuales para tablas).
  # Estos 2 queries dan el resumen agregado + breakdown por país que la
  # pestaña "Estadística General" del frontend usa.
  # ════════════════════════════════════════════════════════════════════════
  Q_STATS_BLOQUEOS_RESUMEN = <<~'SQL'
    SELECT
        count()                                                        AS total_bloqueados,
        countIf(driver_enrollment_status_cd = 3)                       AS pilotos_bloqueados,
        countIf(driver_enrollment_status_cd != 3)                      AS usuarios_bloqueados,
        countIf(lower(ifNull(toString(expelled),'')) != 'true')        AS total_suspendidos,
        countIf(lower(ifNull(toString(expelled),'')) = 'true')         AS total_expulsados,
        countIf(
            lower(ifNull(toString(expelled),'')) != 'true'
            AND lower(ifNull(toString(suspended),'')) = 'false'
            AND lower(ifNull(toString(expelled),''))  = 'false'
            AND ifNull(is_driver_suspended, 0) = 0
        )                                                              AS reactivados,
        countIf(
            lower(ifNull(toString(expelled),'')) != 'true'
            AND NOT (
                lower(ifNull(toString(suspended),'')) = 'false'
                AND lower(ifNull(toString(expelled),''))  = 'false'
                AND ifNull(is_driver_suspended, 0) = 0
            )
        )                                                              AS siguen_bloqueados
    FROM picapmongoprod.passengers p
    WHERE p._id IN (
        SELECT passenger_id FROM picapmongoprod.passenger_suspensions
        WHERE created_at IS NOT NULL
          AND created_at >= toDateTime('%{desde} 00:00:00')
          AND created_at <= toDateTime('%{hasta} 23:59:59')
        UNION DISTINCT
        SELECT driver_id FROM picapmongoprod.driver_suspensions
        WHERE created_at IS NOT NULL
          AND created_at >= toDateTime('%{desde} 00:00:00')
          AND created_at <= toDateTime('%{hasta} 23:59:59')
    )
  SQL

  Q_STATS_BLOQUEOS_PAIS = <<~'SQL'
    SELECT
        CASE
            WHEN p.g_country = 'CO' THEN 'Colombia'
            WHEN p.g_country = 'MX' THEN 'Mexico'
            WHEN p.g_country = 'NI' THEN 'Nicaragua'
            WHEN p.g_country = 'GT' THEN 'Guatemala'
            ELSE ifNull(p.g_country, 'Otro')
        END                                                            AS pais,
        count()                                                        AS total,
        countIf(p.driver_enrollment_status_cd = 3)                     AS pilotos,
        countIf(p.driver_enrollment_status_cd != 3)                    AS usuarios,
        countIf(lower(ifNull(toString(p.expelled),'')) != 'true')      AS suspendidos,
        countIf(lower(ifNull(toString(p.expelled),'')) = 'true')       AS expulsados,
        countIf(
            lower(ifNull(toString(p.suspended),'')) = 'false'
            AND lower(ifNull(toString(p.expelled),''))  = 'false'
            AND ifNull(p.is_driver_suspended, 0) = 0
        )                                                              AS reactivados,
        round(countIf(
            lower(ifNull(toString(p.suspended),'')) = 'false'
            AND lower(ifNull(toString(p.expelled),''))  = 'false'
            AND ifNull(p.is_driver_suspended, 0) = 0
        ) / count() * 100, 1)                                          AS pct_reactivados
    FROM picapmongoprod.passengers p
    WHERE p._id IN (
        SELECT passenger_id FROM picapmongoprod.passenger_suspensions
        WHERE created_at IS NOT NULL
          AND created_at >= toDateTime('%{desde} 00:00:00')
          AND created_at <= toDateTime('%{hasta} 23:59:59')
        UNION DISTINCT
        SELECT driver_id FROM picapmongoprod.driver_suspensions
        WHERE created_at IS NOT NULL
          AND created_at >= toDateTime('%{desde} 00:00:00')
          AND created_at <= toDateTime('%{hasta} 23:59:59')
    )
    %{filtro_driver}
    GROUP BY pais
    ORDER BY total DESC
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # CÉDULA (Bloque G, paridad api.py 2794-2878)
  # Compara fiscal_number (OCR) vs CC extraída del texto de antecedentes
  # ════════════════════════════════════════════════════════════════════════
  Q_CEDULA_AGG = <<~'SQL'
    SELECT
        toDate(creacion_cuenta)         AS dia,
        count()                         AS total_dia,
        countIf(cc_igual = 'alerta')    AS alertas_dia
    FROM (
        SELECT
            toTimeZone(p.created_at, 'America/Bogota') AS creacion_cuenta,
            CASE
                WHEN JSONExtractString(pwd.rekognition_metadata, 'fiscal_number')
                   = extract(pwd.people_police_records, 'Cédula de Ciudadanía Nº\s*([0-9]+)')
                THEN 'ok' ELSE 'alerta'
            END                                          AS cc_igual,
            JSONExtractString(pwd.rekognition_metadata, 'fiscal_number') AS rk_cc,
            extract(pwd.people_police_records, 'Cédula de Ciudadanía Nº\s*([0-9]+)') AS pr_cc,
            ROW_NUMBER() OVER (PARTITION BY p._id ORDER BY p.created_at DESC) AS rn
        FROM picapmongoprod.passengers_w_data pwd
        LEFT JOIN picapmongoprod.passengers p ON pwd._id = p._id
        WHERE p.created_at BETWEEN toDateTime('%{desde} 00:00:00')
                               AND toDateTime('%{hasta} 23:59:59')
          %{filtro_pais}
    )
    WHERE rn = 1 AND rk_cc != '' AND pr_cc != ''
    GROUP BY dia
    ORDER BY dia
  SQL

  # OJO BACKSLASHES: en Ruby `<<~'SQL'` (single-quoted heredoc), `\\` se
  # convierte a `\`. Por eso `[^\\\\]` (4 backslashes) produce `[^\\]` (2 en SQL)
  # que es lo que CH necesita para "cualquier char que no sea backslash".
  # Igualmente `\s` se preserva literal (no es una secuencia de escape Ruby).
  Q_CEDULA_DETALLE = <<~'SQL'
    SELECT
        creacion_cuenta, id_user, name_user, pais_codigo,
        rekognition_cc, cc_antecedentes, nombre_antecedentes, cc_igual
    FROM (
        SELECT
            toTimeZone(p.created_at, 'America/Bogota') AS creacion_cuenta,
            toString(pwd._id)                          AS id_user,
            toString(p.name)                           AS name_user,
            toString(p.g_country)                      AS pais_codigo,
            JSONExtractString(pwd.rekognition_metadata, 'fiscal_number') AS rekognition_cc,
            extract(pwd.people_police_records, 'Cédula de Ciudadanía Nº\s*([0-9]+)') AS cc_antecedentes,
            trim(extract(pwd.people_police_records, 'Apellidos y Nombres:\s*([^\\\\]+)')) AS nombre_antecedentes,
            CASE
                WHEN JSONExtractString(pwd.rekognition_metadata, 'fiscal_number')
                   = extract(pwd.people_police_records, 'Cédula de Ciudadanía Nº\s*([0-9]+)')
                THEN 'ok' ELSE 'alerta'
            END                                        AS cc_igual,
            ROW_NUMBER() OVER (PARTITION BY p._id ORDER BY p.created_at DESC) AS rn
        FROM picapmongoprod.passengers_w_data pwd
        LEFT JOIN picapmongoprod.passengers p ON pwd._id = p._id
        WHERE p.created_at BETWEEN toDateTime('%{desde} 00:00:00')
                               AND toDateTime('%{hasta} 23:59:59')
          %{filtro_pais}
    )
    WHERE rn = 1 AND rekognition_cc != '' AND cc_antecedentes != ''
    ORDER BY creacion_cuenta DESC
    LIMIT %{limit_filas}
  SQL

  # Pagos stats — global (stub)
  Q_PAGOS_STATS = <<~'SQL'
    SELECT
        CASE b.g_country
            WHEN 'CO' THEN 'Colombia'
            WHEN 'MX' THEN 'Mexico'
            WHEN 'NI' THEN 'Nicaragua'
            WHEN 'GT' THEN 'Guatemala'
            ELSE b.g_country
        END                                    AS pais,
        b.payment_method_cd                    AS medio_pago,
        count()                                AS total_servicios,
        round(sum(toFloat64OrNull(JSONExtractString(b.final_cost,'cents'))/100), 0) AS monto_total_cop
    FROM picapmongoprod.bookings b
    WHERE b.created_at >= toDateTime('%{desde} 00:00:00')
      AND b.created_at <= toDateTime('%{hasta} 23:59:59')
      AND b.payment_method_cd IS NOT NULL
    GROUP BY pais, medio_pago
    ORDER BY total_servicios DESC
    LIMIT 50
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # BLOQUEOS — paridad EXACTA con api.py Python (Q_BLOQUEOS, líneas 890-1045)
  # Cruza passenger_suspensions + driver_suspensions + passengers.
  # Calcula dias_bloqueo_real con lógica especial: si la cuenta fue reactivada
  # (suspended=false, expelled=false), usa updated_at del suspension; si no,
  # cuenta hasta today().
  # Filtra por fecha de la suspensión más reciente entre passenger y driver.
  # ════════════════════════════════════════════════════════════════════════
  # v2.2 (May 2026): RESTRUCTURED — 1 fila por SUSPENSIÓN (no por usuario).
  # Antes (v2.0/v2.1) hacíamos LEFT JOIN deduplicado por user_id → 1 row per
  # user con su suspensión más reciente. Eso sub-contaba vs el Excel del
  # cliente que cuenta 1 row por suspensión.
  #
  # Ahora UNION ALL de:
  #   - passenger_suspensions (quien_suspende = 'USUARIO CONSUMIDOR')
  #   - driver_suspensions    (quien_suspende = 'USUARIO PRESTADOR')
  # Resultado: si un piloto tuvo 3 suspensiones en el período, aparece 3 veces.
  # Esto alinea los conteos con el Excel pivot del cliente.
  #
  # Filtro temporal: created_at de la SUSPENSIÓN dentro del rango (no del user).
  Q_BLOQUEOS = <<~'SQL'
    WITH
    -- v2.5: incluye `message` (motivo de ESTA suspension), `permanent` (true=expulsion),
    -- `rule_id` (FK a regla). Antes usabamos comentarios del passengers table (user-level)
    -- y p.expelled global → ahora la clasificacion es per-suspension.
    ps_susp AS (
        SELECT
            toString(_id)                                    AS suspension_id,
            toString(passenger_id)                           AS user_id,
            created_at                                       AS fecha_suspension_dt,
            starts_at                                        AS starts_block,
            ends_at                                          AS ends_block,
            updated_at                                       AS reactivado_en,
            ''                                               AS service_types_raw,
            'USUARIO CONSUMIDOR'                             AS quien_suspende_origen,
            ifNull(message, '')                              AS message,
            multiIf(
                lower(ifNull(permanent, '')) IN ('true', '1'), 1,
                0
            )                                                AS permanent_flag,
            ifNull(rule_id, '')                              AS rule_id
        FROM picapmongoprod.passenger_suspensions
        WHERE created_at BETWEEN toDateTime('%{fecha_desde} 00:00:00')
                             AND toDateTime('%{fecha_hasta} 23:59:59')
    ),
    ds_susp AS (
        SELECT
            toString(_id)                                    AS suspension_id,
            toString(driver_id)                              AS user_id,
            created_at                                       AS fecha_suspension_dt,
            starts_at                                        AS starts_block,
            ends_at                                          AS ends_block,
            updated_at                                       AS reactivado_en,
            ifNull(toString(suspended_service_types), '')    AS service_types_raw,
            'USUARIO PRESTADOR'                              AS quien_suspende_origen,
            ifNull(message, '')                              AS message,
            multiIf(
                ifNull(permanent, false) = true, 1,
                0
            )                                                AS permanent_flag,
            ifNull(rule_id, '')                              AS rule_id
        FROM picapmongoprod.driver_suspensions
        WHERE created_at BETWEEN toDateTime('%{fecha_desde} 00:00:00')
                             AND toDateTime('%{fecha_hasta} 23:59:59')
    ),
    todas_susp AS (
        SELECT * FROM ps_susp
        UNION ALL
        SELECT * FROM ds_susp
    )
    SELECT
        s.suspension_id                                  AS suspension_id,
        s.user_id                                        AS id_usuario,
        p.name                                           AS nombre,
        p.g_country                                      AS pais_codigo,
        p.g_adm_area_lv_1                                AS ciudad,
        s.starts_block                                   AS starts_block_user,
        s.ends_block                                     AS ends_block_user,
        ifNull(toString(p.suspended), '')                AS suspendido,
        ifNull(p.passenger_suspension_comment, '')       AS comentario_user,
        ifNull(p.passenger_expulsion_comment, '')        AS comentario_expulsion_user,
        dateDiff('day', toDate(s.fecha_suspension_dt), today()) AS dias_suspension_user,
        s.starts_block                                   AS starts_block_driver,
        s.ends_block                                     AS ends_block_driver,
        ifNull(toString(p.is_driver_suspended), '')      AS driver_suspendido,
        ifNull(p.driver_suspension_comment, '')          AS comentario_driver,
        dateDiff('day', toDate(s.fecha_suspension_dt), today()) AS dias_suspension_driver,
        ifNull(toString(p.expelled), '')                 AS expulsado,
        -- v2.5: tipo_bloqueo ahora a nivel de SUSPENSION (no de USER):
        --   permanent=true → EXPULSADO (la suspensión específica es permanente)
        --   permanent=false → SUSPENDIDO (temporal)
        -- Antes (v2.4) usábamos p.expelled global, que marcaba como EXPULSADO
        -- TODAS las suspensiones de un user actualmente expulsado, incluso
        -- las suspensiones temporales históricas.
        multiIf(
            s.permanent_flag = 1, 'EXPULSADO',
            'SUSPENDIDO'
        ) AS tipo_bloqueo,
        CASE
            WHEN p.driver_enrollment_status_cd = 3 THEN 'PILOTO'
            ELSE 'USUARIO'
        END AS tipo_usuario,
        -- v2.4: quien_suspende deriva del ENROLLMENT del user, no de la tabla
        -- origen de la suspensión (data dirty en Mongo).
        CASE
            WHEN p.driver_enrollment_status_cd = 3 THEN 'USUARIO PRESTADOR'
            ELSE 'USUARIO CONSUMIDOR'
        END AS quien_suspende,
        -- quien_suspende_origen: indicador "raw" de la tabla de origen (ps/ds).
        s.quien_suspende_origen                          AS quien_suspende_tabla,
        -- v2.5: nuevos campos per-suspensión
        s.message                                        AS message_suspension,
        s.permanent_flag                                 AS permanent_flag,
        s.rule_id                                        AS rule_id,
        s.service_types_raw                              AS service_types,
        -- tipo_cuenta basado en quien_suspende (enrollment-based) + service_types.
        -- v2.7: el campo suspended_service_types contiene 'picap' (no 'rent') para
        -- pilotos Rent. Buscamos ambos por compatibilidad pero el display es "Piloto Rent".
        multiIf(
            p.driver_enrollment_status_cd != 3,
            'Pasajero',
            positionCaseInsensitive(s.service_types_raw, 'pibox') > 0
              AND (positionCaseInsensitive(s.service_types_raw, 'rent') > 0
                   OR positionCaseInsensitive(s.service_types_raw, 'picap') > 0),
            'Piloto Pibox+Rent',
            positionCaseInsensitive(s.service_types_raw, 'rent') > 0
              OR positionCaseInsensitive(s.service_types_raw, 'picap') > 0,
            'Piloto Rent',
            positionCaseInsensitive(s.service_types_raw, 'pibox') > 0,
            'Piloto Pibox',
            'Piloto Pibox'
        ) AS tipo_cuenta,
        formatDateTime(toTimeZone(s.fecha_suspension_dt, 'America/Bogota'), '%Y-%m-%d %H:%M') AS fecha_ultima_suspension,
        dateDiff('day', toDate(s.fecha_suspension_dt), today()) AS dias_bloqueado_total,
        greatest(0, dateDiff('day',
            toDate(s.starts_block),
            if(
                s.reactivado_en IS NOT NULL
                  AND s.reactivado_en > s.starts_block
                  AND s.reactivado_en <= now()
                  AND lower(ifNull(toString(p.expelled),'')) != 'true'
                  AND lower(ifNull(toString(p.suspended),'')) IN ('false','0','')
                  AND lower(ifNull(toString(p.is_driver_suspended),'')) IN ('false','0',''),
                toDate(s.reactivado_en),
                today()
            )
        )) AS dias_bloqueo_real,
        CASE
            WHEN lower(ifNull(toString(p.expelled),'')) = 'true' THEN 'Permanente (expulsión)'
            WHEN dateDiff('day', toDate(s.fecha_suspension_dt), today()) > 30 THEN 'Más de 30 días'
            ELSE 'Menos de 30 días'
        END AS estado_suspension,
        -- esta_activo a nivel de USER (no de suspensión individual): si el user
        -- está actualmente bloqueado, TODAS sus suspensiones aparecen como
        -- 'bloqueado'. Si está reactivado, TODAS como 'activo'. Esto preserva
        -- la semántica original de las tabs Bloqueados/Reactivados del frontend.
        CASE
            WHEN lower(ifNull(toString(p.expelled),'')) = 'true'
              OR lower(ifNull(toString(p.suspended),'')) = 'true'
              OR lower(ifNull(toString(p.is_driver_suspended),'')) = 'true' THEN 'bloqueado'
            ELSE 'activo'
        END AS esta_activo
    FROM todas_susp AS s
    LEFT JOIN picapmongoprod.passengers AS p ON s.user_id = toString(p._id)
    ORDER BY s.fecha_suspension_dt DESC
    LIMIT 50000
  SQL

  # Estafa — stub simple (se reescribirá en bloque D con la query agregada del Python)
  Q_ESTAFA = <<~'SQL'
    SELECT
        b._id                                          AS booking_id,
        b.driver_id,
        pd.name                                        AS nombre_piloto,
        b.passenger_id,
        toTimeZone(b.created_at, 'America/Bogota')     AS creado_en,
        b.cancelation_reason_cd,
        b.g_country,
        b.g_adm_area_lv_1                              AS ciudad,
        toFloat64OrNull(JSONExtractString(b.final_cost,'cents')) / 100 AS monto
    FROM picapmongoprod.bookings b
    LEFT JOIN picapmongoprod.passengers pd ON pd._id = b.driver_id
    WHERE toInt64OrZero(b.cancelation_reason_cd) IN (21, 13)
      AND b.created_at >= toDateTime('%{desde} 00:00:00')
      AND b.created_at <= toDateTime('%{hasta} 23:59:59')
    ORDER BY b.created_at DESC
    LIMIT 500
  SQL

  # ── MoviiRed ───────────────────────────────────────────────────────────────
  # Transacciones MoviiRed (WalletAccountTransactionPinPurchase) — usadas por
  # equipos Admin/Monitoreo/Financiero para reportes regulatorios.
  #
  # Optimizaciones aplicadas vs la query original del usuario:
  # - Reemplazo de `FINAL` por dedup con ROW_NUMBER OVER PARTITION BY _id
  #   (FINAL recorre toda la partición; con ROW_NUMBER es mucho más liviano).
  # - Pushdown de WHERE _type/created_at antes del JOIN para reducir filas.
  # - La normalización de ciudad (replaceRegexpAll anidado) se hace UNA sola
  #   vez en un CTE auxiliar `city_norm`, no en cada uso.
  # - SELECT * → columnas explícitas para evitar leer columnas innecesarias.
  #
  # Placeholders:
  #   %{desde}, %{hasta}              YYYY-MM-DD (rango created_at de wat)
  #   %{filtro_ref}                   AND wat._id ILIKE '%xxx%' (opcional)
  #   %{filtro_user}                  AND wa.passenger_id ILIKE '%xxx%' (opcional)
  #   %{limit_filas}                  LIMIT N (default 20_000 desde el controller)
  Q_MOVIIRED = <<~'SQL'
    WITH
      wat_filtered AS (
        SELECT *
        FROM (
          SELECT
            _id, _type, created_at, amount, account_id, movii_operation_id,
            ROW_NUMBER() OVER (PARTITION BY _id ORDER BY created_at DESC) AS rn
          FROM picapmongoprod.wallet_account_transactions
          WHERE _type = 'WalletAccountTransactionPinPurchase'
            AND toDate(created_at) BETWEEN '%{desde}' AND '%{hasta}'
        )
        WHERE rn = 1
      ),
      wallets AS (
        SELECT *
        FROM (
          SELECT _id, passenger_id,
                 ROW_NUMBER() OVER (PARTITION BY _id ORDER BY _id) AS rn
          FROM picapmongoprod.wallet_accounts
          WHERE _id IN (SELECT account_id FROM wat_filtered)
        )
        WHERE rn = 1
      ),
      passengers_data AS (
        SELECT *
        FROM (
          SELECT _id, g_adm_area_lv_1, g_adm_area_lv_2,
                 ROW_NUMBER() OVER (PARTITION BY _id ORDER BY _id) AS rn
          FROM picapmongoprod.passengers_w_data
          WHERE _id IN (SELECT passenger_id FROM wallets)
        )
        WHERE rn = 1
      ),
      movii_ops AS (
        SELECT *
        FROM (
          SELECT _id, transaction_id,
                 ROW_NUMBER() OVER (PARTITION BY _id ORDER BY _id) AS rn
          FROM picapmongoprod.movii_operations
          WHERE _id IN (SELECT movii_operation_id FROM wat_filtered)
        )
        WHERE rn = 1
      ),
      dane_codes AS (
        SELECT *
        FROM (
          SELECT nombre_municipio, codigo_municipio,
                 ROW_NUMBER() OVER (PARTITION BY nombre_municipio ORDER BY nombre_municipio) AS rn
          FROM picapmongoprod.codigos_dane
        )
        WHERE rn = 1
      ),
      enriched AS (
        SELECT
          wat._id                                    AS id_tx,
          wa.passenger_id                            AS id_user,
          'Incomm'                                   AS codigo_service_type,
          formatDateTime(toTimeZone(wat.created_at, 'America/Bogota'),
                         '%Y-%m-%d %H:%i:%S') AS fecha_hora,
          '3000000231'                               AS numero_moviired,
          ABS(JSONExtractFloat(wat.amount, 'cents') / 100) AS valor_tx,
          wat._id                                    AS numero_referencia_transaccion,
          mii.transaction_id                         AS numero_tx_mahindra,
          '096436'                                   AS codigo_punto,
          -- City normalization (sin acentos, BOGOTA D.C. unificada)
          replaceRegexpAll(
            replaceRegexpAll(
              replaceRegexpAll(
                replaceRegexpAll(
                  replaceRegexpAll(
                    upper(COALESCE(pa.g_adm_area_lv_2, pa.g_adm_area_lv_1)),
                    '[ÁÀÂÃÄáàâãä]', 'A'),
                  '[ÉÈÊËéèêë]', 'E'),
                '[ÍÌÎÏíìîï]', 'I'),
              '[ÓÒÔÕÖóòôõö]', 'O'),
            '[ÚÙÛÜúùûü]', 'U'
          ) AS ciudad_raw
        FROM wat_filtered wat
        INNER JOIN wallets wa             ON wa._id = wat.account_id
        LEFT  JOIN passengers_data pa     ON pa._id = wa.passenger_id
        LEFT  JOIN movii_ops mii          ON mii._id = wat.movii_operation_id
      ),
      with_city AS (
        SELECT
          *,
          IF(ciudad_raw IN ('BOGOTA','BOGOTA D.C.'), 'BOGOTA, D.C.', ciudad_raw) AS ciudad_norm
        FROM enriched
      )
    SELECT
      e.id_tx                                            AS id_tx,
      e.id_user                                          AS id_user,
      e.codigo_service_type                              AS codigo_service_type,
      e.fecha_hora                                       AS fecha_hora,
      e.numero_moviired                                  AS numero_moviired,
      e.valor_tx                                         AS valor_tx,
      e.numero_referencia_transaccion                    AS numero_referencia_transaccion,
      e.numero_tx_mahindra                               AS numero_tx_mahindra,
      IF(cd.codigo_municipio IS NULL OR cd.codigo_municipio = '' OR trim(cd.codigo_municipio) = '',
         '11001', cd.codigo_municipio)                   AS dane,
      e.codigo_punto                                     AS codigo_punto,
      e.ciudad_norm                                      AS ciudad,
      cd.nombre_municipio                                AS nombre_municipio
    FROM with_city e
    LEFT JOIN dane_codes cd ON cd.nombre_municipio = e.ciudad_norm
    WHERE 1=1 %{filtro_ref} %{filtro_user}
    ORDER BY e.fecha_hora DESC
    LIMIT %{limit_filas}
  SQL

  # ── Dispersiones ──────────────────────────────────────────────────────────
  # Transacciones WalletAccountDriverBalanceTransactionDaviplataCashOut —
  # dispersiones de Picap hacia cuentas Daviplata de las companies.
  # Se categorizan en:
  #   - Dispersión Recaudo: company_id IN ('5f9b1847dc3d1101c7ece86c', '5e908acb4f75ba007912a4fd')
  #   - Dispersión Garantía: resto
  # Valores negativos = dispersión efectiva; positivos = reversión.
  #
  # Placeholders:
  #   %{fecha_desde}, %{fecha_hasta}  YYYY-MM-DD (rango created_at en zona Bogotá)
  Q_DISPERSIONES = <<~'SQL'
    WITH filtered_wat AS (
        SELECT *
        FROM picapmongoprod.wallet_account_transactions FINAL
        WHERE _type = 'WalletAccountDriverBalanceTransactionDaviplataCashOut'
          AND toDate(toTimeZone(created_at, 'America/Bogota'))
              BETWEEN toDate('%{fecha_desde}') AND toDate('%{fecha_hasta}')
    )
    SELECT DISTINCT
        toString(wat._id)                                                 AS id_tx,
        toString(toDate(toTimeZone(wat.created_at, 'America/Bogota')))    AS fecha_tx,
        ifNull(JSONExtractFloat(wat.amount, 'cents') / 100, 0)            AS valor,
        wat._type                                                         AS tipo_tx,
        toString(comp._id)                                                AS company_id,
        comp.name                                                         AS company_name,
        CASE
            WHEN toString(comp._id) IN (
                '5f9b1847dc3d1101c7ece86c',
                '5e908acb4f75ba007912a4fd'
            ) THEN 'Dispersión Recaudo'
            ELSE 'Dispersión Garantía'
        END                                                               AS tipo_dispersion
    FROM filtered_wat wat
    INNER JOIN picapmongoprod.wallet_accounts wa ON wa._id = wat.account_id
    INNER JOIN picapmongoprod.companies comp     ON comp._id = wa.company_id
    ORDER BY fecha_tx DESC, id_tx
    LIMIT 50000
  SQL
end
