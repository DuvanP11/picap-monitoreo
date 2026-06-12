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

  # v3.3.13: lectura aislada de foto_perfil. Está separada de Q_USER_BY_USUARIO
  # para que un fallo (columna inexistente) no rompa el login completo.
  # AuthController#leer_foto_perfil tiene rescue → devuelve '' si falla.
  Q_USER_FOTO = <<~'SQL'
    SELECT foto_perfil
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
  # ── Reporte OPS CV ────────────────────────────────────────────────────────
  # Reporte operativo de bookings Pibox para companies CV (Cruz Verde):
  #   '60bfe7d575970c0108014b12' y '624dd6cdac8991004cafc881'.
  # Trae 37 columnas: timestamps de booking + booking_stops + packages
  # + costos + distancias + tiempos calculados + evidencias.
  # Roles permitidos: admin, monitoreo, financiero.
  #
  # Placeholders:
  #   %{fecha_desde}, %{fecha_hasta}   YYYY-MM-DD (rango scheduled_at/created_at)
  Q_REPORTE_OPS_CV = <<~'SQL'
    WITH
        toDate('%{fecha_desde}') AS dat_inicio,
        toDate('%{fecha_hasta}') AS dat_fin,

        q_service_types AS (
            SELECT
                _id,
                multiIf(
                    JSONExtractString(name, 'es') IN (
                        'Pibox (Mensajería)', 'Mensajería en bicicleta', 'Moto Favor', 'Moto favor',
                        'Carga', 'Carga Carry', 'Carga Moto-Vagón', 'Carga NHR', 'Carga NKR', 'Carga NPR',
                        'Mensajería', 'Carro Mensajeria', 'Carga Trailer', 'NHR Refrigerada', 'Pidelo'
                    ), 'Pibox',
                    'Other'
                ) AS type
            FROM picapmongoprod.service_types FINAL
            WHERE JSONExtractString(name, 'es') IN (
                'Pibox (Mensajería)', 'Mensajería en bicicleta', 'Moto Favor', 'Moto favor',
                'Carga', 'Carga Carry', 'Carga Moto-Vagón', 'Carga NHR', 'Carga NKR', 'Carga NPR',
                'Mensajería', 'Carro Mensajeria', 'Carga Trailer', 'NHR Refrigerada', 'Pidelo'
            )
        ),

        -- v3.3.10: filter early - solo pasajeros Cruz Verde (~decenas de IDs)
        -- Esto reduce el universo de bookings de millones a miles ANTES del FINAL
        cv_passengers AS (
            SELECT _id AS _id, name AS name, company_id AS company_id
            FROM picapmongoprod.passengers FINAL
            WHERE company_id IN ('60bfe7d575970c0108014b12', '624dd6cdac8991004cafc881')
        ),

        cv_passenger_ids AS (
            SELECT _id FROM cv_passengers
        ),

        pibox_service_type_ids AS (
            SELECT _id FROM q_service_types
        ),

        -- bookings con filter early via INNER JOIN ANTES del FINAL pesado
        raw_bookings_filtered AS (
            SELECT
                b._id                          AS _id,
                b.requested_service_type_id    AS requested_service_type_id,
                b.country_id                   AS country_id,
                b.passenger_id                 AS passenger_id,
                b.city_id                      AS city_id,
                b.relaunched_to_id             AS relaunched_to_id,
                b.scheduled_at                 AS scheduled_at,
                b.created_at                   AS created_at,
                b.status_cd                    AS status_cd,
                b.express_service              AS express_service,
                b.address                      AS address,
                b.events                       AS events,
                b.accepted_time                AS accepted_time,
                b.total_company_final_cost     AS total_company_final_cost,
                b.total_final_cost             AS total_final_cost,
                b.final_cost                   AS final_cost,
                b.estimated_traveled_distance  AS estimated_traveled_distance
            FROM picapmongoprod.bookings AS b FINAL
            INNER JOIN cv_passenger_ids        AS cvp ON cvp._id = b.passenger_id
            INNER JOIN pibox_service_type_ids  AS pst ON pst._id = b.requested_service_type_id
            WHERE toDate(toTimeZone(ifNull(b.scheduled_at, b.created_at), 'America/Bogota'))
                BETWEEN dat_inicio AND dat_fin
                AND nullIf(trim(toString(b.relaunched_to_id)), '') IS NULL
        ),

        raw_countries  AS (SELECT _id, name FROM picapmongoprod.countries FINAL),
        raw_companies  AS (SELECT _id, name FROM picapmongoprod.companies FINAL),

        q_filtered_bookings_full AS (
            SELECT
                b._id                          AS _id,
                b.requested_service_type_id    AS requested_service_type_id,
                b.country_id                   AS country_id,
                b.passenger_id                 AS passenger_id,
                b.city_id                      AS city_id,
                b.relaunched_to_id             AS relaunched_to_id,
                b.scheduled_at                 AS scheduled_at,
                b.created_at                   AS created_at,
                b.status_cd                    AS status_cd,
                b.express_service              AS express_service,
                b.address                      AS address,
                b.events                       AS events,
                b.accepted_time                AS accepted_time,
                b.total_company_final_cost     AS total_company_final_cost,
                b.total_final_cost             AS total_final_cost,
                b.final_cost                   AS final_cost,
                b.estimated_traveled_distance  AS estimated_traveled_distance,
                st.type                        AS service_type,
                c.name                         AS country_name,
                p.name                         AS passenger_name,
                p.company_id                   AS passenger_company_id,
                compp.name                     AS company_name
            FROM raw_bookings_filtered b
            INNER JOIN q_service_types st   ON st._id    = b.requested_service_type_id
            INNER JOIN raw_countries c      ON c._id     = b.country_id
            INNER JOIN cv_passengers p      ON p._id     = b.passenger_id
            INNER JOIN raw_companies compp  ON compp._id = p.company_id
            WHERE st.type = 'Pibox'
        ),

        -- v3.3.6: vista delgada para los JOINs intermedios (solo _id)
        -- Esto reduce la hash table de 22 columnas → 1 columna, evitando OOM
        -- y permitiendo usar parallel_hash en lugar de grace_hash.
        q_filtered_bookings AS (
            SELECT _id FROM q_filtered_bookings_full
        ),

        -- v3.3.8: FINAL + INNER JOIN filter. FINAL hace merge streaming (low RAM),
        -- INNER JOIN limita scan a solo booking_ids relevantes.
        q_filtered_booking_stops AS (
            SELECT
                bs._id                AS _id,
                bs.booking_id         AS booking_id,
                bs.created_at         AS created_at,
                bs.updated_at         AS updated_at,
                bs.address            AS address,
                bs.address_geojson    AS address_geojson,
                bs.rend_geojson       AS rend_geojson,
                bs.is_return_stop     AS is_return_stop,
                bs.finished           AS finished,
                bs.rend_at            AS rend_at,
                bs.started_at         AS started_at,
                bs.g_country          AS g_country,
                bs.g_adm_area_lv_1    AS g_adm_area_lv_1,
                bs.g_adm_area_lv_2    AS g_adm_area_lv_2,
                bs.g_locality         AS g_locality,
                bs.g_neighborhood     AS g_neighborhood,
                bs.g_sublocality_lv_1 AS g_sublocality_lv_1
            FROM picapmongoprod.booking_stops AS bs FINAL
            INNER JOIN q_filtered_bookings AS qfb ON qfb._id = bs.booking_id
        ),

        q_filtered_packages AS (
            SELECT
                pk._id                       AS _id,
                pk.booking_id                AS booking_id,
                pk.booking_stop_id           AS booking_stop_id,
                pk.passenger_id              AS passenger_id,
                pk.company_id                AS company_id,
                pk.counter_delivery          AS counter_delivery,
                pk.created_at                AS created_at,
                pk.updated_at                AS updated_at,
                pk.indications               AS indications,
                pk.reference                 AS reference,
                pk.status_cd                 AS status_cd,
                pk.size_cd                   AS size_cd,
                pk.not_received_reason_cd    AS not_received_reason_cd,
                pk.canceled_pickup_reason_cd AS canceled_pickup_reason_cd,
                pk.picked_up                 AS picked_up,
                pk.rating_by_customer        AS rating_by_customer,
                pk.stop_before_return_id     AS stop_before_return_id,
                pk.declared_value            AS declared_value,
                pk.events                    AS events
            FROM picapmongoprod.packages AS pk FINAL
            INNER JOIN q_filtered_bookings AS qfb ON qfb._id = pk.booking_id
        ),

        q_filtered_dm_processed_events AS (
            SELECT
                dpe.booking_id             AS booking_id,
                dpe.tms_accepted           AS tms_accepted,
                dpe.tms_arrived            AS tms_arrived,
                dpe.tms_picked_up          AS tms_picked_up,
                dpe.tms_arrived_to_deliver AS tms_arrived_to_deliver,
                dpe.tms_dropped_off        AS tms_dropped_off
            FROM picapmongoprod.dm_processed_events AS dpe FINAL
            INNER JOIN q_filtered_bookings AS qfb ON qfb._id = dpe.booking_id
        ),

        q_booking_stops_precoord AS (
            SELECT
                bs._id AS booking_stop_raw_id,
                bs.booking_id, bs.created_at, bs.updated_at, bs.address,
                bs.is_return_stop, bs.finished, bs.rend_at, bs.started_at,
                bs.g_country, bs.g_adm_area_lv_1, bs.g_adm_area_lv_2,
                bs.g_locality, bs.g_neighborhood, bs.g_sublocality_lv_1,
                ifNull(arrayElement(JSONExtract(ifNull(bs.address_geojson, '{"coordinates":[0,0]}'), 'coordinates', 'Array(Float64)'), 2), 0) AS num_latitude,
                ifNull(arrayElement(JSONExtract(ifNull(bs.address_geojson, '{"coordinates":[0,0]}'), 'coordinates', 'Array(Float64)'), 1), 0) AS num_longitude,
                ifNull(arrayElement(JSONExtract(ifNull(bs.rend_geojson,    '{"coordinates":[0,0]}'), 'coordinates', 'Array(Float64)'), 2), 0) AS num_end_latitude,
                ifNull(arrayElement(JSONExtract(ifNull(bs.rend_geojson,    '{"coordinates":[0,0]}'), 'coordinates', 'Array(Float64)'), 1), 0) AS num_end_longitude,
                parseDateTimeBestEffortOrNull(nullIf(trim(toString(bs.rend_at)),    '')) AS parsed_rend_at,
                parseDateTimeBestEffortOrNull(nullIf(trim(toString(bs.started_at)),'')) AS parsed_started_at
            FROM q_filtered_booking_stops bs
        ),

        q_booking_stops AS (
            SELECT
                bs.booking_stop_raw_id AS booking_stop_id,
                bs.booking_id,
                toDate(toTimeZone(bs.created_at, 'America/Bogota'))   AS dat_created,
                toTimeZone(bs.created_at, 'America/Bogota')           AS tms_created,
                toTimeZone(bs.updated_at, 'America/Bogota')           AS tms_updated,
                bs.address                                             AS str_address,
                bs.num_latitude, bs.num_longitude,
                bs.num_end_latitude, bs.num_end_longitude,
                (toString(bs.is_return_stop) = 'true')                 AS flg_return_stop,
                (toString(bs.finished)       = 'true')                 AS flg_service_finished,
                if(
                    ifNull(bs.parsed_rend_at, be.tms_picked_up) IS NOT NULL
                    AND ifNull(bs.parsed_rend_at, be.tms_picked_up) >= toDateTime('1971-01-01'),
                    toTimeZone(ifNull(bs.parsed_rend_at, ifNull(be.tms_picked_up, bs.created_at)), 'America/Bogota'),
                    NULL
                ) AS tms_ended,
                if(
                    ifNull(
                        bs.parsed_started_at,
                        leadInFrame(ifNull(bs.parsed_rend_at, ifNull(be.tms_picked_up, bs.created_at)))
                        OVER (PARTITION BY bs.booking_id ORDER BY bs.created_at ASC)
                    ) IS NOT NULL
                    AND ifNull(
                        bs.parsed_started_at,
                        leadInFrame(ifNull(bs.parsed_rend_at, ifNull(be.tms_picked_up, bs.created_at)))
                        OVER (PARTITION BY bs.booking_id ORDER BY bs.created_at ASC)
                    ) >= toDateTime('1971-01-01'),
                    toTimeZone(
                        ifNull(
                            bs.parsed_started_at,
                            leadInFrame(ifNull(bs.parsed_rend_at, ifNull(be.tms_picked_up, bs.created_at)))
                            OVER (PARTITION BY bs.booking_id ORDER BY bs.created_at ASC)
                        ),
                        'America/Bogota'
                    ),
                    NULL
                ) AS tms_started,
                NULL AS booking_event_id,
                row_number() OVER (PARTITION BY bs.booking_id ORDER BY bs.created_at ASC) AS num_sequence,
                count(*)     OVER (PARTITION BY bs.booking_id)                            AS num_total_stops,
                bs.g_country, bs.g_adm_area_lv_1, bs.g_adm_area_lv_2,
                bs.g_locality, bs.g_neighborhood, bs.g_sublocality_lv_1
            FROM q_booking_stops_precoord bs
            LEFT JOIN q_filtered_dm_processed_events be ON be.booking_id = bs.booking_id
        ),

        -- v3.3.7: mini-CTE para filtrar vw_dim_customers_pibox por booking_stop_id
        q_booking_stop_ids AS (
            SELECT booking_stop_id FROM q_booking_stops
        ),

        q_packages_with_events AS (
            SELECT _id AS package_id, events
            FROM q_filtered_packages
            WHERE events IS NOT NULL
                AND nullIf(trim(toString(events)), '') IS NOT NULL
        ),

        parsed_events AS (
            SELECT
                p.package_id,
                raw_event
            FROM q_packages_with_events p
            ARRAY JOIN JSONExtractArrayRaw(assumeNotNull(toString(p.events))) AS raw_event
            WHERE raw_event != ''
        ),

        final_events_collapsed AS (
            SELECT
                package_id,
                if(dt_created IS NOT NULL AND dt_created >= toDateTime('1971-01-01'),
                   toTimeZone(dt_created, 'America/Bogota'), NULL) AS tms_created,
                if(dt_updated IS NOT NULL AND dt_updated >= toDateTime('1971-01-01'),
                   toTimeZone(dt_updated, 'America/Bogota'), NULL) AS tms_updated,
                toFloat64OrZero(JSONExtractString(raw_event, 'status_cd')) AS status_cd
            FROM (
                SELECT
                    package_id, raw_event,
                    ifNull(
                        parseDateTimeBestEffortOrNull(nullIf(trim(JSONExtractString(raw_event, 'created_at')), '')),
                        parseDateTimeBestEffortOrNull(nullIf(trim(JSONExtractString(raw_event, 'updated_at')), ''))
                    ) AS dt_created,
                    parseDateTimeBestEffortOrNull(nullIf(trim(JSONExtractString(raw_event, 'updated_at')), '')) AS dt_updated
                FROM parsed_events
            )
        ),

        package_events_pivot AS (
            SELECT
                package_id,
                maxIf(tms_created, status_cd = 1) AS tms_picked_up,
                maxIf(tms_created, status_cd = 2) AS tms_delivered,
                maxIf(tms_created, status_cd = 3) AS tms_canceled,
                maxIf(tms_created, status_cd = 4) AS tms_not_received,
                maxIf(tms_created, status_cd = 5) AS tms_returned
            FROM final_events_collapsed
            GROUP BY package_id
        ),

        fs_solutions AS (
            SELECT
                ss._id        AS _id,
                ss.booking_id AS booking_id,
                ss.package_id AS package_id
            FROM picapmongoprod.service_type_specification_form_solutions AS ss FINAL
            INNER JOIN q_filtered_bookings AS qfb ON qfb._id = ss.booking_id
            WHERE nullIf(trim(toString(ss.package_id)), '') IS NOT NULL
        ),
        ff_field_solutions AS (
            SELECT
                fld.solution_form_id AS solution_form_id,
                fld.field_key        AS field_key,
                fld.photo_url        AS photo_url,
                fld.created_at       AS created_at
            FROM picapmongoprod.service_type_specification_form_field_solutions AS fld FINAL
            INNER JOIN fs_solutions AS fss ON fss._id = fld.solution_form_id
            WHERE fld.field_key IN ('destination_package_image', 'origin_package_image')
                AND nullIf(trim(toString(fld.photo_url)), '') IS NOT NULL
        ),
        qry_package_evidence_ranked AS (
            SELECT
                fs.booking_id, fs.package_id, ff.field_key, ff.photo_url,
                row_number() OVER (
                    PARTITION BY fs.booking_id, fs.package_id, ff.field_key
                    ORDER BY ff.created_at DESC
                ) AS rn
            FROM fs_solutions fs
            INNER JOIN ff_field_solutions ff ON fs._id = ff.solution_form_id
        ),

        qry_package_evidence AS (
            SELECT booking_id, package_id, field_key, photo_url
            FROM qry_package_evidence_ranked
            WHERE rn = 1
        ),

        q_packages AS (
            SELECT
                fc._id                                                    AS package_id,
                fc.booking_id,
                row_number() OVER (PARTITION BY fc.booking_id      ORDER BY fc.created_at) AS seq_booking,
                fc.booking_stop_id,
                row_number() OVER (PARTITION BY fc.booking_stop_id ORDER BY fc.created_at) AS seq_booking_stop,
                fc.passenger_id,
                ifNull(toString(fc.counter_delivery), 'false')            AS flg_is_counter_delivery_paid,
                toDate(toTimeZone(fc.created_at, 'America/Bogota'))       AS dat_created,
                toTimeZone(fc.created_at, 'America/Bogota')               AS tms_created,
                toTimeZone(fc.updated_at, 'America/Bogota')               AS tms_updated,
                pe.tms_picked_up,
                pe.tms_delivered,
                pe.tms_canceled,
                pe.tms_not_received,
                pe.tms_returned,
                fc.indications                                            AS str_indications,
                fc.reference,
                ifNull(fc.status_cd, -1)                                  AS package_status_cd,
                ifNull(toInt64OrZero(toString(fc.size_cd)), -1)           AS package_size_cd,
                ifNull(toInt64OrZero(toString(fc.not_received_reason_cd)), -1)   AS not_received_reason_cd,
                ifNull(toInt64OrZero(toString(fc.canceled_pickup_reason_cd)),-1) AS canceled_pickup_reason_cd,
                ifNull(toString(fc.picked_up), 'true')                    AS flg_picked_up,
                fc.company_id,
                toFloat64OrZero(toString(fc.rating_by_customer))          AS num_rating_by_customer,
                fc.stop_before_return_id,
                toFloat64OrZero(JSONExtractString(fc.declared_value, 'cents')) / 100        AS declared_value_amount,
                ifNull(upper(JSONExtractString(fc.declared_value, 'currency_iso')), 'N/A')  AS cur_declared_value,
                eori.photo_url                                            AS url_origin_package_image,
                edst.photo_url                                            AS url_destination_package_image,
                fc.events                                                 AS jsn_events
            FROM q_filtered_packages fc
            LEFT JOIN package_events_pivot pe
                ON fc._id = pe.package_id
            LEFT JOIN qry_package_evidence eori
                ON fc._id = eori.package_id AND fc.booking_id = eori.booking_id
                AND eori.field_key = 'origin_package_image'
            LEFT JOIN qry_package_evidence edst
                ON fc._id = edst.package_id AND fc.booking_id = edst.booking_id
                AND edst.field_key = 'destination_package_image'
        ),

        q_tiempos AS (
            SELECT
                b._id AS _id,
                toFloat64(multiIf(
                    be.tms_accepted IS NULL AND b.accepted_time > 0, toFloat64(b.accepted_time),
                    be.tms_accepted IS NOT NULL
                        AND be.tms_accepted <= toTimeZone(b.created_at, 'America/Bogota')
                        AND b.accepted_time > 0, toFloat64(b.accepted_time),
                    be.tms_accepted IS NOT NULL
                        AND be.tms_accepted >= toTimeZone(b.created_at, 'America/Bogota'),
                        toFloat64(greatest(0, dateDiff('second',
                            greatest(
                                ifNull(toTimeZone(b.scheduled_at, 'America/Bogota'), toTimeZone(b.created_at, 'America/Bogota')),
                                toTimeZone(b.created_at, 'America/Bogota')
                            ),
                            be.tms_accepted
                        ))),
                    toFloat64(0)
                )) AS bkn_tiempo_aceptacion,
                toFloat64(if(be.tms_accepted IS NOT NULL AND be.tms_arrived IS NOT NULL
                    AND be.tms_arrived >= be.tms_accepted,
                    dateDiff('second', be.tms_accepted, be.tms_arrived), 0)) AS bkn_tiempo_llegada,
                toFloat64(if(be.tms_accepted IS NOT NULL AND be.tms_arrived IS NOT NULL
                    AND be.tms_picked_up IS NOT NULL AND be.tms_picked_up >= be.tms_arrived,
                    dateDiff('second', be.tms_arrived, be.tms_picked_up), 0)) AS bkn_tiempo_recogida,
                toFloat64(if(be.tms_picked_up IS NOT NULL AND be.tms_arrived_to_deliver IS NOT NULL
                    AND be.tms_arrived_to_deliver >= be.tms_picked_up,
                    dateDiff('second', be.tms_picked_up, be.tms_arrived_to_deliver), 0)) AS bkn_tiempo_final_llegada_destino,
                toFloat64(if(be.tms_arrived_to_deliver IS NOT NULL AND be.tms_dropped_off IS NOT NULL
                    AND be.tms_dropped_off >= be.tms_arrived_to_deliver,
                    dateDiff('second', be.tms_arrived_to_deliver, be.tms_dropped_off), 0)) AS bkn_tiempo_final_entrega
            FROM q_filtered_bookings_full b
            LEFT JOIN q_filtered_dm_processed_events be ON be.booking_id = b._id
        ),

        base_final AS (
            SELECT
                b._id                                                AS uuid_booking,
                bs.booking_stop_id                                   AS id_parada,
                toTimeZone(b.created_at, 'America/Bogota')           AS iniciado,
                if(be.tms_accepted           >= toDateTime('1971-01-01'), be.tms_accepted,           NULL) AS asignado,
                if(be.tms_arrived            >= toDateTime('1971-01-01'), be.tms_arrived,            NULL) AS llego_al_origen,
                if(be.tms_picked_up          >= toDateTime('1971-01-01'), be.tms_picked_up,          NULL) AS salio_de_origen,
                if(be.tms_arrived_to_deliver >= toDateTime('1971-01-01'), be.tms_arrived_to_deliver, NULL) AS llego_donde_el_cliente,
                pck.package_id                                       AS id_paquete,
                if(pck.tms_delivered         >= toDateTime('1971-01-01'), pck.tms_delivered,         NULL) AS fecha_entrega_paquete,
                multiIf(
                    (if(b.status_cd IN (4, 107, 108) AND pck.package_status_cd != 2, 'SI', 'NO')) = 'SI',
                        coalesce(
                            nullIf(pnr.txt_package_received_status, 'Without Issues'),
                            concat(pst.txt_package_status, ifNull(concat(': ', pcp.txt_package_pickup_status), ''))
                        ),
                    b.status_cd IN (100, 102, 103, 104, 105),
                        caseWithExpression(b.status_cd,
                            100, 'Canceled By Driver',
                            102, 'Canceled By Passenger',
                            103, 'Canceled By Store',
                            104, 'Canceled By Ops',
                            105, 'Canceled By Insufficient Funds',
                            'Other'),
                    ''
                ) AS descripcion,
                if(pck.tms_returned     >= toDateTime('1971-01-01'), pck.tms_returned,     NULL) AS fecha_devolucion_paquete,
                if(pck.tms_canceled     >= toDateTime('1971-01-01'), pck.tms_canceled,     NULL) AS fecha_cancelacion_paquete,
                if(pck.tms_not_received >= toDateTime('1971-01-01'), pck.tms_not_received, NULL) AS fecha_paquete_no_recibido,
                multiIf(
                    b.status_cd IN (4, 107, 108),             'Finalizado',
                    b.status_cd IN (100, 102, 103, 104, 105), 'Cancelado',
                    b.status_cd = 101,                        'Expirado',
                    concat('Status [', toString(b.status_cd), '] - Sin clasificar')
                ) AS estado,
                'NO' AS programado,
                multiIf(
                    toString(b.express_service) = 'true',  'Same Day',
                    toString(b.express_service) = 'false', 'Next Day',
                    'Other'
                ) AS next_day,
                if(b.status_cd IN (4, 107, 108) AND pck.package_status_cd != 2, 'SI', 'NO') AS finalizado_fallido,
                if(be.tms_dropped_off >= toDateTime('1971-01-01'), be.tms_dropped_off, NULL) AS finalizo_servicio,
                replaceRegexpAll(pck.reference,             '[\\n\\r]', ' ') AS num_orden,
                replaceRegexpAll(b.passenger_name,          '[\\n\\r]', ' ') AS nombre_usuario,
                JSONExtractString(cty.name, 'es')                            AS ciudad,
                replaceRegexpAll(b.address,                 '[\\n\\r]', ' ') AS direccion_origen,
                replaceRegexpAll(trimRight(bs.str_address), '[\\n\\r]', ' ') AS direccion_de_destino,
                bs.flg_return_stop                                            AS parada_de_regreso,
                replaceRegexpAll(
                    ifNull(cus.txt_name,  trim(assumeNotNull(splitByString('-', ifNull(pck.str_indications, '')))[1])),
                    '[\\n\\r]', ' '
                ) AS nombre_cliente,
                replaceRegexpAll(
                    ifNull(cus.txt_phone, trim(assumeNotNull(splitByString('-', ifNull(pck.str_indications, '')))[2])),
                    '[\\n\\r]', ' '
                ) AS telefono_cliente,
                0 AS duracion_espera,
                0 AS duracion_servicio_copy,
                toFloat64(0) / 60 AS min_tiempo_de_relanzamiento_min,
                (
                    toFloat64(t.bkn_tiempo_aceptacion) +
                    toFloat64(t.bkn_tiempo_llegada)    +
                    toFloat64(t.bkn_tiempo_recogida)   +
                    toFloat64(t.bkn_tiempo_final_llegada_destino)
                ) / 60 AS min_tiempo_de_servicio,
                round(bs.num_latitude,  3) AS latitud,
                round(bs.num_longitude, 3) AS longitud,
                1 AS recuento_definido_de_uuid,
                ifNull(
                    toFloat64OrZero(JSONExtractString(b.total_company_final_cost, 'cents')) / 100,
                    ifNull(
                        toFloat64OrZero(JSONExtractString(b.total_final_cost,     'cents')) / 100,
                        toFloat64OrZero(JSONExtractString(b.final_cost,           'cents')) / 100
                    )
                ) AS costo_servicio,
                toFloat64OrZero(toString(b.estimated_traveled_distance)) / 1000 AS distancia_km,
                toFloat64(t.bkn_tiempo_llegada) / 60 AS llegada_a_origen_min,
                bs.num_sequence AS orden_parada,
                pck.declared_value_amount AS valor_declarado
            FROM q_booking_stops bs
            INNER JOIN q_filtered_bookings_full b ON b._id = bs.booking_id
            LEFT JOIN (
                SELECT cus_v.id_booking_stop AS id_booking_stop,
                       cus_v.txt_name        AS txt_name,
                       cus_v.txt_phone       AS txt_phone
                FROM picapmongoprod.vw_dim_customers_pibox AS cus_v FINAL
                INNER JOIN q_booking_stop_ids AS bsids
                    ON bsids.booking_stop_id = cus_v.id_booking_stop
                WHERE cus_v.seq_booking_stop = 1
            ) cus ON bs.booking_stop_id = cus.id_booking_stop
            LEFT JOIN q_packages pck ON pck.booking_stop_id = bs.booking_stop_id
            LEFT JOIN (SELECT _id, name FROM picapmongoprod.cities FINAL) cty ON b.city_id = cty._id
            LEFT JOIN (SELECT cod_package_status, txt_package_status FROM picapmongoprod.vw_dim_st_package FINAL) pst
                ON pst.cod_package_status = pck.package_status_cd
            LEFT JOIN (SELECT cod_package_pickup_status, txt_package_pickup_status FROM picapmongoprod.vw_dim_st_package_canceled_pickup FINAL) pcp
                ON pck.package_status_cd = pcp.cod_package_pickup_status
            LEFT JOIN (SELECT cod_package_received_status, txt_package_received_status FROM picapmongoprod.vw_dim_st_package_not_received FINAL) pnr
                ON pck.not_received_reason_cd = pnr.cod_package_received_status
            LEFT JOIN q_filtered_dm_processed_events be ON be.booking_id = b._id
            LEFT JOIN q_tiempos t ON t._id = b._id
        ),

        base_final_ranked AS (
            SELECT
                *,
                row_number() OVER (
                    PARTITION BY id_paquete
                    ORDER BY
                        if(finalizo_servicio IS NULL, 1, 0) ASC,
                        finalizo_servicio DESC,
                        fecha_entrega_paquete DESC,
                        iniciado DESC
                ) AS rn_dedup
            FROM base_final
            WHERE id_paquete IS NOT NULL
        )
    SELECT
        uuid_booking, id_parada, iniciado, asignado, llego_al_origen,
        salio_de_origen, llego_donde_el_cliente, id_paquete,
        fecha_entrega_paquete, descripcion, fecha_devolucion_paquete,
        fecha_cancelacion_paquete, fecha_paquete_no_recibido, estado,
        programado, next_day, finalizado_fallido, finalizo_servicio,
        num_orden, nombre_usuario, ciudad, direccion_origen,
        direccion_de_destino, parada_de_regreso, nombre_cliente,
        telefono_cliente, duracion_espera, duracion_servicio_copy,
        min_tiempo_de_relanzamiento_min, min_tiempo_de_servicio,
        latitud, longitud, recuento_definido_de_uuid, costo_servicio,
        distancia_km, llegada_a_origen_min, orden_parada, valor_declarado
    FROM base_final_ranked
    WHERE rn_dedup = 1
    ORDER BY iniciado, uuid_booking
    SETTINGS join_algorithm = 'parallel_hash', max_threads = 8, max_bytes_before_external_sort = 4000000000, max_bytes_before_external_group_by = 4000000000
  SQL

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

  # v3.3.23: Bonos de Ayuda Voluntaria
  # WalletAccountTransactionBookingHelpBonus = "bono de ayuda" entre passenger.
  # UNION ALL de 2 sub-queries: masivo (wallet_accounts.company_id vacío) y
  # corporativo (con company_id). Devuelve 1 fila por transacción con campos
  # para clasificarla y detectar incoherencias.
  Q_BONOS_AYUDA_VOLUNTARIA = <<~'SQL'
    WITH
        q_wat_base AS (
            SELECT
                _id, booking_id, account_id, _type, created_at,
                description, daviplata_response, from_trump, reverted_to_id,
                custom_message, amount
            FROM picapmongoprod.wallet_account_transactions FINAL
            WHERE toDate(toTimeZone(created_at, 'America/Bogota'))
                  BETWEEN toDate('%{fecha_desde}') AND toDate('%{fecha_hasta}')
              AND _type IN ('WalletAccountTransactionBookingHelpBonus')
              AND JSONExtractString(amount, 'currency_iso') = 'COP'
        ),
        q_account_ids AS (
            SELECT DISTINCT account_id FROM q_wat_base
        ),
        q_wallet_accounts AS (
            SELECT _id, type_cd, passenger_id, company_id
            FROM picapmongoprod.wallet_accounts FINAL
            WHERE _id IN (SELECT account_id FROM q_account_ids)
        ),
        q_passengers AS (
            SELECT _id, g_country FROM picapmongoprod.passengers_w_data FINAL
        ),
        q_companies AS (
            SELECT _id, name FROM picapmongoprod.companies FINAL
        )
    SELECT
        wat._id                                                              AS id_transaccion,
        p._id                                                                AS id_passenger,
        toDate(toTimeZone(wat.created_at, 'America/Bogota'))                 AS fecha,
        ''                                                                   AS company_id,
        ''                                                                   AS company_name,
        wa.type_cd                                                           AS type_cd,
        wat._type                                                            AS tipo_tx,
        CAST(JSONExtractString(wat.amount, 'cents') AS Float64) / 100        AS monto_cop,
        wat.description                                                      AS descripcion,
        multiIf(
            wat.description IN (
                'Has recibido una ayuda por mensajería!',
                'Reverso de Has recibido una ayuda por mensajería!'
            ),
            'masivo pibox',
            'masivo picap'
        )                                                                    AS wallet_type,
        wat.daviplata_response                                               AS daviplata_response,
        ifNull(p.g_country, '')                                              AS pais,
        ifNull(toString(wat.from_trump), '')                                 AS from_trump,
        ifNull(toString(wat.reverted_to_id), '')                             AS reverted_to_id,
        ifNull(wat.custom_message, '')                                       AS custom_message
    FROM q_wat_base AS wat
    INNER JOIN q_wallet_accounts AS wa ON wa._id = wat.account_id
    INNER JOIN q_passengers      AS p  ON p._id  = wa.passenger_id
    WHERE wa.company_id = ''

    UNION ALL

    SELECT
        wat._id                                                              AS id_transaccion,
        wa.passenger_id                                                      AS id_passenger,
        toDate(toTimeZone(wat.created_at, 'America/Bogota'))                 AS fecha,
        comp._id                                                             AS company_id,
        comp.name                                                            AS company_name,
        wa.type_cd                                                           AS type_cd,
        wat._type                                                            AS tipo_tx,
        CAST(JSONExtractString(wat.amount, 'cents') AS Float64) / 100        AS monto_cop,
        wat.description                                                      AS descripcion,
        'corporativo pibox'                                                  AS wallet_type,
        wat.daviplata_response                                               AS daviplata_response,
        ''                                                                   AS pais,
        ''                                                                   AS from_trump,
        ''                                                                   AS reverted_to_id,
        ''                                                                   AS custom_message
    FROM q_wat_base AS wat
    INNER JOIN q_wallet_accounts AS wa  ON wa._id    = wat.account_id
    INNER JOIN q_companies       AS comp ON comp._id = wa.company_id
    WHERE wa.company_id != ''

    ORDER BY fecha DESC, id_transaccion
    SETTINGS join_algorithm = 'parallel_hash', max_threads = 8, max_memory_usage = 12000000000
  SQL

  # v3.3.24: MINTIC — reporte trimestral de bookings B2B Pibox.
  # v3.3.24-rc3: OPTIMIZACIÓN — push-down de filtros de fecha antes de FINAL,
  # remoción de envoltorios `(SELECT * FROM ... FINAL)` que forzaban full-scan,
  # grace_hash en vez de parallel_hash (menos memoria, spill a disco).
  # Devuelve todas las columnas necesarias para construir el Informe General
  # (cruce con facturas extraídas del Drive vía NIT + período de fechas).
  # Parámetros: %{fecha_desde}, %{fecha_hasta} (formato YYYY-MM-DD).
  Q_MINTIC = <<~'SQL'
    WITH q_service_types AS (
      SELECT
        _id,
        CASE
          WHEN name_es IN (
            'Pibox (Mensajería)', 'Mensajería en bicicleta', 'Moto Favor
', 'Moto favor',
            'Carga', 'Carga Carry', 'Carga Moto-Vagón', 'Carga NHR', 'Carga NKR', 'Carga NPR',
            'Mensajería', 'Carro Mensajeria', 'Carga Trailer', 'NHR Refrigerada'
          ) THEN 'Pibox'
          ELSE 'Other'
        END AS type
      FROM picapmongoprod.service_types
      WHERE name_es != 'Test'
    ),
    q_country_co AS (
      SELECT _id FROM picapmongoprod.countries
      WHERE JSONExtractString(name, 'es') = 'Colombia'
    ),
    -- 1 solo scan de bookings con TODOS los filtros aplicados. La operacion
    -- mas cara — solo se hace una vez. Las CTEs hijas referencian q_bookings_full.
    q_bookings_full AS (
      SELECT
        b._id, b.company_id, b.country_id, b.requested_service_type_id,
        b.passenger_id, b.driver_id, b.served_vehicle_type_id, b.city_id,
        b.cost_center_id, b.payment_method_cd,
        b.scheduled_at, b.created_at, b.status_cd,
        b.address, b.end_address,
        b.estimated_traveled_distance, b.traveled_distance, b.traveled_time,
        b.company_final_cost, b.total_company_final_cost,
        b.final_cost, b.additional_final_cost, b.dispute_final_cost, b.total_final_cost,
        b.additional_company_final_cost, b.dispute_company_final_cost,
        b.amount_charged_to_company_wallet,
        b.express_service, b.return_to_origin
      FROM picapmongoprod.bookings AS b FINAL
      WHERE b.status_cd IN (4, 107, 108)
        AND nullIf(trim(b.relaunched_to_id), '') IS NULL
        AND b.company_id IS NOT NULL AND b.company_id != ''
        AND toDate(toTimeZone(coalesce(b.scheduled_at, b.created_at), 'America/Bogota'))
            BETWEEN toDate('%{fecha_desde}') AND toDate('%{fecha_hasta}')
        AND b.requested_service_type_id IN (SELECT _id FROM q_service_types WHERE type = 'Pibox')
        AND b.country_id IN (SELECT _id FROM q_country_co)
    ),
    -- alias para compatibilidad con el SELECT final.
    q_filtered_bookings AS (
      SELECT b._id AS booking_id, b.* FROM q_bookings_full AS b
    ),
    q_transactions AS (
      SELECT
        wat.booking_id,
        JSONExtractString(wat.amount, 'currency_iso') AS currency,
        SUM(if(wat._type = 'WalletAccountTransactionCommissionDriverPayment', -toFloat64OrZero(JSONExtractString(wat.amount, 'cents')) / 100, 0)) AS driver,
        SUM(if(wat._type = 'WalletAccountTransactionCommissionCompanyPayment', -toFloat64OrZero(JSONExtractString(wat.amount, 'cents')) / 100, 0)) AS company,
        SUM(if(wat._type = 'WalletAccountTransactionBookingDriverPayment', toFloat64OrZero(JSONExtractString(wat.amount, 'cents')) / 100, 0)) AS booking_driver_payment
      FROM picapmongoprod.wallet_account_transactions AS wat FINAL
      WHERE wat.booking_id IN (SELECT _id FROM q_bookings_full)
        AND wat._type IN (
          'WalletAccountTransactionCommissionDriverPayment',
          'WalletAccountTransactionCommissionCompanyPayment',
          'WalletAccountTransactionBookingDriverPayment')
      GROUP BY wat.booking_id, currency
    ),
    q_packages AS (
      SELECT DISTINCT
        pck._id, pck.booking_id, pck.reference, pck.declared_value,
        pck.status_cd, pck.counter_delivery
      FROM picapmongoprod.packages AS pck FINAL
      WHERE pck.booking_id IN (SELECT _id FROM q_bookings_full)
    ),
    -- 1 scan de passengers_w_data filtrando por (passenger_id ∪ driver_id).
    q_passengers_all AS (
      SELECT DISTINCT p._id, p.name, p.company_id, p.document_type, p.cod_identification
      FROM picapmongoprod.passengers_w_data AS p FINAL
      WHERE p._id IN (
        SELECT passenger_id FROM q_bookings_full
        UNION DISTINCT
        SELECT driver_id    FROM q_bookings_full WHERE driver_id IS NOT NULL
      )
    ),
    q_passengers_p AS (
      SELECT _id, name, company_id FROM q_passengers_all
    ),
    q_passengers_d AS (
      SELECT _id, name, document_type, cod_identification FROM q_passengers_all
    ),
    q_passengers_k AS (
      SELECT DISTINCT k._id, k.name
      FROM picapmongoprod.passengers_w_data AS k FINAL
      WHERE k._id IN (
        SELECT commercial_manager_id
        FROM picapmongoprod.companies
        WHERE _id IN (SELECT company_id FROM q_bookings_full WHERE company_id != '')
          AND commercial_manager_id IS NOT NULL
      )
    )
    SELECT DISTINCT
      b._id AS Booking_ID,
      ifNull(b.company_id, p.company_id) AS Company_ID,
      toDate(toTimeZone(coalesce(b.scheduled_at, b.created_at), 'America/Bogota')) AS Fecha_VERDADERA,
      toTimeZone(b.created_at, 'America/Bogota') AS Date_Time,
      toTimeZone(b.scheduled_at, 'America/Bogota') AS Scheduled_Time,
      JSONExtractString(cit.name, 'es') AS Ciudad,
      comp.name AS Nombre_Compania,
      p.name AS Usuario_Tienda,
      replaceAll(pck.reference, '\n', '-') AS Package_Reference_Numbers,
      toString(toFloat64OrZero(JSONExtractString(pck.declared_value, 'cents')) / 100) AS Package_Declared_Value,
      CASE pck.status_cd
        WHEN -1 THEN 'Pending_Status'
        WHEN 0  THEN 'Waiting_For_Pick-Up'
        WHEN 1  THEN 'Picked-Up'
        WHEN 2  THEN 'Delivered'
        WHEN 3  THEN 'Canceled'
        WHEN 4  THEN 'Not_Received'
        WHEN 5  THEN 'Returned'
        WHEN 15 THEN 'No_visitado'
        ELSE 'Other'
      END AS Estado_Paquete,
      CASE WHEN lower(pck.counter_delivery) = 'true' THEN 'SI' ELSE 'NO' END AS Contraentrega,
      replaceAll(b.address, '\n', '-') AS Direccion_Salida,
      replaceAll(b.end_address, '\n', '-') AS Direccion_Entrega,
      if(b.estimated_traveled_distance <> 0, b.estimated_traveled_distance, b.traveled_distance) AS Distancia_Recorrida,
      b.traveled_time AS Traveled_Time,
      ifNull(toFloat64OrZero(JSONExtractString(b.company_final_cost, 'cents')), 0) / 100 AS Final_Service_Cost,
      if(t.booking_driver_payment != 0,
         t.booking_driver_payment + t.company,
         toFloat64OrZero(JSONExtractString(b.total_company_final_cost, 'cents')) / 100) AS Valor_final_con_Ajuste,
      (ifNull(toFloat64OrZero(JSONExtractString(b.company_final_cost, 'cents')) / 100,
              ifNull(toFloat64OrZero(JSONExtractString(b.final_cost, 'cents')) / 100, 0)) +
       ifNull(toFloat64OrZero(JSONExtractString(b.additional_company_final_cost, 'cents')) / 100, 0) +
       ifNull(toFloat64OrZero(JSONExtractString(b.dispute_company_final_cost, 'cents')) / 100, 0)) AS GMV,
      comp.name AS Company,
      t.driver AS Ganancia_piloto,
      t.company AS Ganancia_Corporativo,
      (t.driver + t.company) AS Ganancia_Total,
      k.name AS KAM,
      b.driver_id AS Driver_ID,
      d.name AS Nombre_Driver,
      d.document_type AS Document_Type,
      d.cod_identification AS COD_Identification,
      ifNull(JSONExtractString(vt.name, 'es'), '') AS vt_name_es,
      if(b.company_id IS NOT NULL, 'B2B', 'B2C') AS business_type,
      pck._id AS id_paquete,
      comp.tax_id AS NIT,
      cs.name AS cost_center
    FROM q_filtered_bookings b
      INNER JOIN q_passengers_p   p  ON p._id  = b.passenger_id
      INNER JOIN q_passengers_d   d  ON d._id  = b.driver_id
      LEFT  JOIN picapmongoprod.companies comp ON comp._id = b.company_id
      LEFT  JOIN q_transactions   t  ON t.booking_id = b._id
      LEFT  JOIN q_packages       pck ON pck.booking_id = b._id
      LEFT  JOIN picapmongoprod.vehicle_types vt ON vt._id = b.served_vehicle_type_id
      LEFT  JOIN picapmongoprod.cities        cit ON cit._id = b.city_id
      LEFT  JOIN picapmongoprod.cost_centers  cs  ON cs._id  = b.cost_center_id
      LEFT  JOIN q_passengers_k   k  ON k._id  = comp.commercial_manager_id
    SETTINGS
      enable_analyzer = 0,
      join_algorithm = 'grace_hash',
      max_bytes_in_join = 4000000000,
      max_threads = 12,
      max_memory_usage = 12000000000,
      max_execution_time = 240,
      optimize_read_in_order = 1,
      optimize_skip_unused_shards = 1
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # SALDO RECAUDOS — Reporte mensual del balance Recaudos vs Servicios B2B.
  # Paridad EXACTA con recaudos_bi/generar_recaudos.py (validado abril 2026
  # cuadra centavo a centavo: $414,712,527 total, Surtitodo -$33,910.04).
  # ════════════════════════════════════════════════════════════════════════

  # Hoja 1: detalle por booking con contraentrega cobrada (data cruda).
  # Variables: %{fecha_desde}, %{fecha_hasta}
  Q_SALDO_RECAUDOS_RECAUDOS = <<~'SQL'
    WITH
      q_service_types AS (
        SELECT
          _id,
          name_es AS name,
          CASE
            WHEN name_es IN (
              'Pibox (Mensajería)', 'Mensajería en bicicleta', 'Moto Favor', 'Moto favor',
              'Carga', 'Carga Carry', 'Carga Moto-Vagón', 'Carga NHR', 'Carga NKR', 'Carga NPR',
              'Mensajería', 'Carro Mensajeria', 'Carga Trailer', 'NHR Refrigerada'
            ) THEN 'Pibox'
            WHEN name_es IN (
              'Moto', 'Mototaxi', 'Moto sin conductor', 'Subasta','Carro Subasta','Taxi', 'Carro',
              'Carro sin conductor', 'Moto VIP', 'Moto Económica', 'Carro Queen','Rapidín','Espero tranqui',
              'Moto lite', 'Moto Queen', 'Picap Carro', 'Picap Moto', 'Grúa Carro', 'Grúa Moto'
            ) THEN 'Picap'
            ELSE 'Other'
          END AS type
        FROM (SELECT * FROM picapmongoprod.service_types FINAL)
      ),
      q_wat_filtered AS (
        SELECT
          wat._id AS transaction_id,
          wat.booking_id AS booking_id,
          wat.package_id AS package_id,
          wat.account_id AS account_id,
          wat.amount AS amount,
          wat.normalized_amount_after_transaction AS normalized_amount_after_transaction,
          wat.transaction_state_cd AS transaction_state_cd,
          wat._type AS tx_type,
          wat.created_at AS created_at,
          b.created_at AS booking_created_at,
          pck.reference AS package_reference,
          pck.declared_value AS package_declared_value,
          pck.counter_delivery AS package_counter_delivery,
          b.passenger_id AS passenger_id,
          b.driver_id AS driver_id,
          b.served_vehicle_type_id AS served_vehicle_type_id,
          b.city_id AS city_id,
          b.requested_service_type_id AS requested_service_type_id,
          b.country_id AS country_id,
          wa._id AS wallet_account_id,
          p.company_id AS passenger_company_id,
          p.name AS passenger_name,
          d.name AS driver_name
        FROM picapmongoprod.wallet_account_transactions AS wat FINAL
        INNER JOIN picapmongoprod.packages AS pck FINAL ON pck._id = wat.package_id
        INNER JOIN picapmongoprod.bookings AS b FINAL ON b._id = wat.booking_id
        INNER JOIN picapmongoprod.wallet_accounts AS wa FINAL ON wa._id = wat.account_id
        INNER JOIN picapmongoprod.passengers AS p FINAL ON p._id = b.passenger_id
        INNER JOIN picapmongoprod.passengers AS d FINAL ON d._id = b.driver_id
        INNER JOIN picapmongoprod.countries AS c FINAL ON c._id = b.country_id
        WHERE
          JSONExtractString(c.name, 'es') = 'Colombia'
          AND JSONExtractString(wat.amount, 'currency_iso') = 'COP'
          AND pck.counter_delivery = 'true'
          AND wat._type = 'WalletAccountCounterDeliveryPaymentTransaction'
          AND toDate(toTimeZone(wat.created_at, 'America/Bogota'))
              BETWEEN toDate('%{fecha_desde}') AND toDate('%{fecha_hasta}')
      )
    SELECT
      toDate(toTimeZone(qtf.created_at, 'America/Bogota'))                        AS Date_transaction,
      JSONExtractString(qtf.amount, 'currency_iso')                               AS Transaction_currency,
      toFloat64OrZero(JSONExtractString(qtf.amount, 'cents')) / 100               AS Transaction_amount,
      qtf.transaction_id                                                          AS Transaction_ID,
      toFloat64OrZero(JSONExtractString(qtf.normalized_amount_after_transaction, 'cents')) / 100 AS Normalized_Amount_After_Transaction,
      toDate(toTimeZone(qtf.booking_created_at, 'America/Bogota'))                AS Date_booking,
      qtf.booking_id                                                              AS ID_Booking,
      qtf.package_id                                                              AS ID_Package,
      qtf.package_reference                                                       AS Reference,
      qtf.passenger_id                                                            AS ID_User,
      compp.name                                                                  AS User_Company,
      qtf.passenger_name                                                          AS User_Name,
      toFloat64OrZero(JSONExtractString(qtf.package_declared_value, 'cents')) / 100 AS Declared_Value,
      qtf.transaction_state_cd                                                    AS transaction_state_cd,
      qtf.driver_id                                                               AS ID_Driver,
      qtf.driver_name                                                             AS Driver_Name,
      st.type                                                                     AS type,
      st.name                                                                     AS service_type_name,
      JSONExtractString(cit.name, 'es')                                           AS Ciudad,
      JSONExtractString(vt.name, 'es')                                            AS name_vehicle,
      qtf.passenger_company_id                                                    AS company_id
    FROM q_wat_filtered qtf
    LEFT JOIN picapmongoprod.companies      AS compp FINAL ON compp._id = qtf.passenger_company_id
    LEFT JOIN picapmongoprod.vehicle_types  AS vt    FINAL ON vt._id    = qtf.served_vehicle_type_id
    LEFT JOIN picapmongoprod.cities         AS cit   FINAL ON cit._id   = qtf.city_id
    LEFT JOIN q_service_types               AS st          ON st._id    = qtf.requested_service_type_id
    ORDER BY Date_transaction ASC
  SQL

  # Hoja 3: detalle de transacciones (3 tipos) — alimenta cols Recaudos + Servicios.
  # Variables: %{fecha_desde}, %{fecha_hasta}
  Q_SALDO_RECAUDOS_TRANSACCIONES = <<~'SQL'
    WITH q_service_types AS (
      SELECT
        _id,
        any(name_es) AS name,
        any(multiIf(
          name_es IN (
            'Pibox (Mensajería)', 'Mensajería en bicicleta', 'Moto Favor',
            'Moto favor', 'Carga', 'Carga Carry', 'Carga Moto-Vagón',
            'Carga NHR', 'Carga NKR', 'Carga NPR', 'Mensajería',
            'Carro Mensajeria', 'Carga Trailer', 'NHR Refrigerada'
          ), 'Pibox',
          name_es IN (
            'Moto', 'Mototaxi', 'Moto sin conductor', 'Subasta', 'Taxi',
            'Carro', 'Rapidín', 'Carro sin conductor', 'Moto VIP',
            'Moto Económica', 'Carro Queen', 'Espero tranqui',
            'Moto lite', 'Moto Queen', 'Picap Carro', 'Picap Moto',
            'Grúa Carro', 'Grúa Moto'
          ), 'Picap',
          'Other'
        )) AS type
      FROM picapmongoprod.service_types
      GROUP BY _id
    ),
    q_transactions_filtered AS (
      SELECT
        wat._id AS _id,
        wat.booking_id,
        wat.account_id,
        wat._type AS txt_type,
        wat.created_at AS created_at,
        wat.amount,
        s.payment_method_cd,
        toFloat64OrZero(JSONExtractString(s.amount_charged_to_passenger_wallet, 'cents')) / 100 AS amount_charged_to_passenger_wallet,
        toFloat64OrZero(JSONExtractString(s.amount_charged_to_company_wallet, 'cents')) / 100   AS amount_charged_to_company_wallet,
        wa.passenger_id AS passenger_id,
        comp._id   AS company_id,
        comp.name  AS company_name,
        st.type    AS service_type
      FROM picapmongoprod.wallet_account_transactions wat FINAL
      ANY LEFT JOIN picapmongoprod.bookings        s    FINAL ON s._id    = wat.booking_id
      ANY LEFT JOIN q_service_types                st         ON st._id   = s.requested_service_type_id
      ANY LEFT JOIN picapmongoprod.wallet_accounts wa   FINAL ON wa._id   = wat.account_id
      ANY LEFT JOIN picapmongoprod.companies       comp FINAL ON comp._id = s.company_id
      WHERE
        wat._type IN (
          'WalletAccountCounterDeliveryPaymentTransaction',
          'WalletAccountTransactionBookingCompanyCharge',
          'WalletAccountTransactionCommissionCompanyPayment'
        )
        AND JSONExtractString(wat.amount, 'currency_iso') = 'COP'
        AND st.type = 'Pibox'
        AND toDate(toTimeZone(wat.created_at, 'America/Bogota'))
            BETWEEN toDate('%{fecha_desde}') AND toDate('%{fecha_hasta}')
    ),
    q_transactions AS (
      SELECT
        t.booking_id,
        JSONExtractString(t.amount, 'currency_iso') AS currency,
        SUM(IF(t._type = 'WalletAccountTransactionBookingDriverPayment',
               JSONExtractFloat(t.amount, 'cents') / 100, 0)) AS booking_driver_payment
      FROM picapmongoprod.wallet_account_transactions t FINAL
      INNER JOIN (SELECT DISTINCT booking_id FROM q_transactions_filtered) qtf ON t.booking_id = qtf.booking_id
      GROUP BY t.booking_id, currency
    ),
    q_payment_methods AS (
      SELECT
        b._id AS booking_id,
        multiIf(
          b.payment_method_cd = '1', 'Cash',
          b.payment_method_cd = '2', 'Voucher',
          b.payment_method_cd = '3', 'Credit Card',
          'Other'
        ) AS txt_payment_method
      FROM picapmongoprod.bookings b FINAL
      WHERE b._id IN (SELECT booking_id FROM q_transactions_filtered)
      GROUP BY b._id, b.payment_method_cd
    )
    SELECT
      qtf.passenger_id,
      qtf.company_id,
      qtf.company_name                                                     AS Company_name,
      qtf.txt_type                                                         AS TXT_TYPE,
      toDate(toTimeZone(qtf.created_at, 'America/Bogota'))                 AS TMS_CREATED,
      qtf.booking_id,
      toFloat64OrZero(JSONExtractString(qtf.amount, 'cents')) / 100        AS VAL_AMOUNT,
      qtf._id,
      ifNull(t.booking_driver_payment, 0)                                  AS VAL_AMOUNT_BOOKING_DRIVER_PAYMENT,
      multiIf(
        (pm.txt_payment_method = 'Cash') AND (t.booking_driver_payment != 0), 'Company Wallet',
        pm.txt_payment_method != 'Cash', pm.txt_payment_method,
        qtf.amount_charged_to_company_wallet > 0, 'Company Wallet',
        'Cash'
      ) AS Payment_Type
    FROM q_transactions_filtered qtf
    LEFT JOIN q_transactions  t  ON t.booking_id  = qtf.booking_id
    LEFT JOIN q_payment_methods pm ON pm.booking_id = qtf.booking_id
    ORDER BY TMS_CREATED, qtf.booking_id
  SQL

  # Auxiliar: collection_fee por company_id (porcentaje de comisión por
  # pago contra-entrega). Variables: %{ids} (string CSV de IDs entre comillas).
  Q_SALDO_RECAUDOS_COMMISSION = <<~'SQL'
    SELECT _id, toFloat64OrZero(collection_fee) / 100.0 AS fee
    FROM picapmongoprod.companies FINAL
    WHERE _id IN (%{ids})
      AND collection_fee IS NOT NULL AND collection_fee != ''
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # COMISIONES RECAUDO — Informe automatizado de 9 hojas (validado abril 2026
  # cuadra centavo a centavo contra plantilla del usuario).
  # Replica recaudos_bi/generar_comisiones.py.
  # ════════════════════════════════════════════════════════════════════════

  # Query A: data para Hoja 2 (Recaudos) — txt_type = CounterDelivery.
  # Variables: %{fecha_desde}, %{fecha_hasta}
  Q_COMISIONES_RECAUDO_A = <<~'SQL'
    WITH q_service_types AS (
      SELECT _id, any(name_es) AS name,
        any(multiIf(
          name_es IN ('Pibox (Mensajería)', 'Mensajería en bicicleta', 'Moto Favor', 'Moto favor',
                      'Carga', 'Carga Carry', 'Carga Moto-Vagón', 'Carga NHR', 'Carga NKR', 'Carga NPR',
                      'Mensajería', 'Carro Mensajeria', 'Carga Trailer', 'NHR Refrigerada'), 'Pibox',
          name_es IN ('Moto', 'Mototaxi', 'Moto sin conductor', 'Subasta', 'Taxi',
                      'Carro', 'Rapidín', 'Carro sin conductor', 'Moto VIP',
                      'Moto Económica', 'Carro Queen', 'Espero tranqui',
                      'Moto lite', 'Moto Queen', 'Picap Carro', 'Picap Moto',
                      'Grúa Carro', 'Grúa Moto'), 'Picap',
          'Other'
        )) AS type
      FROM picapmongoprod.service_types GROUP BY _id
    ),
    q_transactions_filtered AS (
      SELECT
        wat._id AS _id, wat.booking_id, wat.account_id,
        wat._type AS txt_type, wat.created_at AS created_at, wat.amount,
        s.payment_method_cd,
        toFloat64OrZero(JSONExtractString(s.amount_charged_to_passenger_wallet, 'cents')) / 100 AS amount_charged_to_passenger_wallet,
        toFloat64OrZero(JSONExtractString(s.amount_charged_to_company_wallet, 'cents')) / 100   AS amount_charged_to_company_wallet,
        wa.passenger_id AS passenger_id,
        comp._id AS company_id, comp.name AS company_name,
        st.type AS service_type
      FROM picapmongoprod.wallet_account_transactions wat FINAL
      ANY LEFT JOIN picapmongoprod.bookings        s    FINAL ON s._id    = wat.booking_id
      ANY LEFT JOIN q_service_types                st         ON st._id   = s.requested_service_type_id
      ANY LEFT JOIN picapmongoprod.wallet_accounts wa   FINAL ON wa._id   = wat.account_id
      ANY LEFT JOIN picapmongoprod.companies       comp FINAL ON comp._id = s.company_id
      WHERE wat._type = 'WalletAccountCounterDeliveryPaymentTransaction'
        AND JSONExtractString(wat.amount, 'currency_iso') = 'COP'
        AND st.type = 'Pibox'
        AND toDate(toTimeZone(wat.created_at, 'America/Bogota'))
            BETWEEN toDate('%{fecha_desde}') AND toDate('%{fecha_hasta}')
    ),
    q_transactions AS (
      SELECT t.booking_id,
        JSONExtractString(t.amount, 'currency_iso') AS currency,
        SUM(IF(t._type = 'WalletAccountTransactionBookingDriverPayment',
               JSONExtractFloat(t.amount, 'cents') / 100, 0)) AS booking_driver_payment
      FROM picapmongoprod.wallet_account_transactions t FINAL
      INNER JOIN (SELECT DISTINCT booking_id FROM q_transactions_filtered) qtf ON t.booking_id = qtf.booking_id
      GROUP BY t.booking_id, currency
    ),
    q_payment_methods AS (
      SELECT b._id AS booking_id,
        multiIf(b.payment_method_cd = '1', 'Cash',
                b.payment_method_cd = '2', 'Voucher',
                b.payment_method_cd = '3', 'Credit Card',
                'Other') AS txt_payment_method
      FROM picapmongoprod.bookings b FINAL
      WHERE b._id IN (SELECT booking_id FROM q_transactions_filtered)
      GROUP BY b._id, b.payment_method_cd
    )
    SELECT
      qtf.passenger_id AS passenger_id,
      qtf.company_id   AS company_id,
      qtf.company_name AS Company_name,
      qtf.txt_type     AS TXT_TYPE,
      toDate(toTimeZone(qtf.created_at, 'America/Bogota')) AS TMS_CREATED,
      qtf.booking_id   AS booking_id,
      toFloat64OrZero(JSONExtractString(qtf.amount, 'cents')) / 100 AS VAL_AMOUNT,
      qtf._id          AS _id,
      ifNull(t.booking_driver_payment, 0) AS VAL_AMOUNT_BOOKING_DRIVER_PAYMENT,
      multiIf((pm.txt_payment_method = 'Cash') AND (t.booking_driver_payment != 0), 'Company Wallet',
              pm.txt_payment_method != 'Cash', pm.txt_payment_method,
              qtf.amount_charged_to_company_wallet > 0, 'Company Wallet',
              'Cash') AS Payment_Type
    FROM q_transactions_filtered qtf
    LEFT JOIN q_transactions   t  ON t.booking_id  = qtf.booking_id
    LEFT JOIN q_payment_methods pm ON pm.booking_id = qtf.booking_id
    ORDER BY TMS_CREATED, qtf.booking_id
  SQL

  # Query B: data para Hoja 1 (Comisión Recaudo) — txt_type = BookingCompanyCollectionFee.
  # Misma estructura que Q_COMISIONES_RECAUDO_A pero con otro _type.
  Q_COMISIONES_RECAUDO_B = Q_COMISIONES_RECAUDO_A.gsub(
    "WalletAccountCounterDeliveryPaymentTransaction",
    "WalletAccountTransactionBookingCompanyCollectionFee",
  )

  # Query C: collection_fee de companies (Hoja 3 → Porcentaje Real).
  # Devuelve fee_decimal ya dividido por 100 (0.01 = 1%).
  Q_COMISIONES_RECAUDO_FEE = <<~'SQL'
    SELECT _id, name,
      toFloat64OrZero(collection_fee) / 100.0 AS fee_decimal
    FROM picapmongoprod.companies FINAL
    WHERE collection_fee IS NOT NULL AND collection_fee != ''
  SQL

  # Query D: Resumen Recaudo por User_Company (Hoja 5).
  # Variables: %{fecha_desde}, %{fecha_hasta}
  Q_COMISIONES_RECAUDO_RESUMEN = <<~'SQL'
    WITH q_wat_filtered AS (
      SELECT wat.amount AS amount, p.company_id AS passenger_company_id
      FROM picapmongoprod.wallet_account_transactions AS wat FINAL
      INNER JOIN picapmongoprod.packages   AS pck FINAL ON pck._id = wat.package_id
      INNER JOIN picapmongoprod.bookings   AS b   FINAL ON b._id   = wat.booking_id
      INNER JOIN picapmongoprod.passengers AS p   FINAL ON p._id   = b.passenger_id
      INNER JOIN picapmongoprod.countries  AS c   FINAL ON c._id   = b.country_id
      WHERE JSONExtractString(c.name, 'es') = 'Colombia'
        AND JSONExtractString(wat.amount, 'currency_iso') = 'COP'
        AND pck.counter_delivery = 'true'
        AND wat._type = 'WalletAccountCounterDeliveryPaymentTransaction'
        AND toDate(toTimeZone(wat.created_at, 'America/Bogota'))
            BETWEEN toDate('%{fecha_desde}') AND toDate('%{fecha_hasta}')
    )
    SELECT
      compp.name AS User_Company,
      SUM(toFloat64OrZero(JSONExtractString(qtf.amount, 'cents')) / 100) AS Suma_Transaction_amount
    FROM q_wat_filtered qtf
    LEFT JOIN picapmongoprod.companies AS compp FINAL ON compp._id = qtf.passenger_company_id
    GROUP BY compp.name
    ORDER BY Suma_Transaction_amount DESC
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # RECAUDOS Y DISPERSIONES — informe mensual de 7 hojas.
  # Validado contra plantilla "Recaudos y Dispersiones Abril 2026.xlsx" (100%).
  # Replica recaudos_dispersiones_bi/generar_recaudos_dispersiones.py.
  # ════════════════════════════════════════════════════════════════════════

  # Query A: Dispersiones Daviplata CashOut (sólo "Dispersión Recaudo").
  # Variables: %{fecha_desde}, %{fecha_hasta}
  Q_DISPERSIONES_DAVIPLATA = <<~'SQL'
    WITH filtered_wat AS (
        SELECT * FROM picapmongoprod.wallet_account_transactions FINAL
        WHERE _type = 'WalletAccountDriverBalanceTransactionDaviplataCashOut'
          AND toDate(toTimeZone(created_at, 'America/Bogota'))
              BETWEEN toDate('%{fecha_desde}') AND toDate('%{fecha_hasta}')
    )
    SELECT DISTINCT
        wat._id AS _id,
        toDate(toTimeZone(wat.created_at, 'America/Bogota')) AS created_at,
        ifNull(JSONExtractFloat(wat.amount, 'cents') / 100, 0) AS amount_cents,
        wat._type AS _type,
        comp._id AS company_id,
        comp.name AS Company_name,
        CASE
            WHEN comp._id IN (
                '5f9b1847dc3d1101c7ece86c',
                '5e908acb4f75ba007912a4fd'
            ) THEN 'Dispersión Recaudo'
            ELSE 'Dispersión Garantía'
        END AS tipo_dispersion
    FROM filtered_wat wat
    INNER JOIN picapmongoprod.wallet_accounts wa   ON wa._id   = wat.account_id
    INNER JOIN picapmongoprod.companies      comp ON comp._id = wa.company_id
    WHERE tipo_dispersion = 'Dispersión Recaudo'
    ORDER BY created_at ASC
  SQL

  # Query B: Recaudos (22 cols, CounterDelivery).
  # Variables: %{fecha_desde}, %{fecha_hasta}
  Q_DISPERSIONES_RECAUDOS = <<~'SQL'
    WITH
    q_service_types AS (
      SELECT
        _id,
        name_es AS name,
        CASE
          WHEN name_es IN (
            'Pibox (Mensajería)', 'Mensajería en bicicleta', 'Moto Favor', 'Moto favor',
            'Carga', 'Carga Carry', 'Carga Moto-Vagón', 'Carga NHR', 'Carga NKR', 'Carga NPR',
            'Mensajería', 'Carro Mensajeria', 'Carga Trailer', 'NHR Refrigerada'
          ) THEN 'Pibox'
          WHEN name_es IN (
            'Moto', 'Mototaxi', 'Moto sin conductor', 'Subasta','Carro Subasta','Taxi', 'Carro',
            'Carro sin conductor', 'Moto VIP', 'Moto Económica', 'Carro Queen','Rapidín','Espero tranqui',
            'Moto lite', 'Moto Queen', 'Picap Carro', 'Picap Moto', 'Grúa Carro', 'Grúa Moto'
          ) THEN 'Picap'
          ELSE 'Other'
        END AS type
      FROM (SELECT * FROM picapmongoprod.service_types FINAL)
    ),
    q_wat_filtered AS (
      SELECT
        wat._id          AS transaction_id,
        wat.booking_id   AS booking_id,
        wat.package_id   AS package_id,
        wat.account_id   AS account_id,
        wat.amount       AS amount,
        wat.normalized_amount_after_transaction AS normalized_amount_after_transaction,
        wat.transaction_state_cd AS transaction_state_cd,
        wat._type        AS tx_type,
        wat.created_at   AS created_at,
        b.created_at     AS booking_created_at,
        pck.reference    AS package_reference,
        pck.declared_value AS package_declared_value,
        pck.counter_delivery AS package_counter_delivery,
        b.passenger_id   AS passenger_id,
        b.driver_id      AS driver_id,
        b.served_vehicle_type_id AS served_vehicle_type_id,
        b.city_id        AS city_id,
        b.requested_service_type_id AS requested_service_type_id,
        b.country_id     AS country_id,
        wa._id           AS wallet_account_id,
        p.company_id     AS passenger_company_id,
        p.name           AS passenger_name,
        d.name           AS driver_name
      FROM picapmongoprod.wallet_account_transactions AS wat FINAL
      INNER JOIN picapmongoprod.packages AS pck FINAL ON pck._id = wat.package_id
      INNER JOIN picapmongoprod.bookings AS b   FINAL ON b._id   = wat.booking_id
      INNER JOIN picapmongoprod.wallet_accounts AS wa FINAL ON wa._id = wat.account_id
      INNER JOIN picapmongoprod.passengers AS p FINAL ON p._id = b.passenger_id
      INNER JOIN picapmongoprod.passengers AS d FINAL ON d._id = b.driver_id
      INNER JOIN picapmongoprod.countries AS c FINAL ON c._id = b.country_id
      WHERE
        JSONExtractString(c.name, 'es') = 'Colombia'
        AND JSONExtractString(wat.amount, 'currency_iso') = 'COP'
        AND pck.counter_delivery = 'true'
        AND wat._type = 'WalletAccountCounterDeliveryPaymentTransaction'
        AND toDate(toTimeZone(wat.created_at, 'America/Bogota'))
            BETWEEN toDate('%{fecha_desde}') AND toDate('%{fecha_hasta}')
    )
    SELECT
      toDate(toTimeZone(qtf.created_at, 'America/Bogota')) AS Date_transaction,
      JSONExtractString(qtf.amount, 'currency_iso') AS Transaction_currency,
      toFloat64OrZero(JSONExtractString(qtf.amount, 'cents')) / 100 AS Transaction_amount,
      qtf.transaction_id AS Transaction_ID,
      toFloat64OrZero(JSONExtractString(qtf.normalized_amount_after_transaction, 'cents')) / 100 AS Normalized_Amount_After_Transaction,
      toDate(toTimeZone(qtf.booking_created_at, 'America/Bogota')) AS Date_booking,
      qtf.booking_id AS ID_Booking,
      qtf.package_id AS ID_Package,
      qtf.package_reference AS Reference,
      qtf.passenger_id AS ID_User,
      compp.name AS User_Company,
      qtf.passenger_name AS User_Name,
      toFloat64OrZero(JSONExtractString(qtf.package_declared_value, 'cents')) / 100 AS Declared_Value,
      qtf.transaction_state_cd AS transaction_state_cd,
      qtf.driver_id AS ID_Driver,
      qtf.driver_name AS Driver_Name,
      st.type AS type,
      st.name AS service_type_name,
      JSONExtractString(cit.name, 'es') AS Ciudad,
      JSONExtractString(vt.name, 'es') AS name_vehicle,
      multiIf(sf.new_final_score_rent < 0, 0,
              sf.new_final_score_rent >= 5, 5,
              sf.new_final_score_rent) AS score_rent_fixed,
      multiIf(sf.new_final_score_pibox < 0, 0,
              sf.new_final_score_pibox >= 5, 5,
              sf.new_final_score_pibox) AS score_pibox_fixed
    FROM q_wat_filtered qtf
    LEFT JOIN picapmongoprod.companies     AS compp FINAL ON compp._id = qtf.passenger_company_id
    LEFT JOIN picapmongoprod.vehicle_types AS vt    FINAL ON vt._id    = qtf.served_vehicle_type_id
    LEFT JOIN picapmongoprod.cities        AS cit   FINAL ON cit._id   = qtf.city_id
    LEFT JOIN q_service_types              AS st          ON st._id    = qtf.requested_service_type_id
    LEFT JOIN picapmongoprod.vw_atr_driver_scoring_with_frauds AS sf FINAL ON sf.driver_id = qtf.driver_id
    ORDER BY Date_transaction ASC
  SQL

  # ════════════════════════════════════════════════════════════════════════
  # ESTADO DE CUENTA SURTITODO — informe mensual 3 hojas (con logo Pibox).
  # Replica estado_cuenta_bi/generar_estado_cuenta.py (validado abril 2026).
  # ════════════════════════════════════════════════════════════════════════

  # Query A: Recaudos (CounterDelivery filtrado por Surtitodo). 4 cols.
  # Variables: %{fecha_desde}, %{fecha_hasta}
  Q_ESTADO_CUENTA_RECAUDOS = <<~'SQL'
    WITH
    q_service_types AS (
      SELECT
        _id,
        name_es AS name,
        CASE
          WHEN name_es IN (
            'Pibox (Mensajería)', 'Mensajería en bicicleta', 'Moto Favor', 'Moto favor',
            'Carga', 'Carga Carry', 'Carga Moto-Vagón', 'Carga NHR', 'Carga NKR', 'Carga NPR',
            'Mensajería', 'Carro Mensajeria', 'Carga Trailer', 'NHR Refrigerada'
          ) THEN 'Pibox'
          WHEN name_es IN (
            'Moto', 'Mototaxi', 'Moto sin conductor', 'Subasta','Carro Subasta','Taxi', 'Carro',
            'Carro sin conductor', 'Moto VIP', 'Moto Económica', 'Carro Queen','Rapidín','Espero tranqui',
            'Moto lite', 'Moto Queen', 'Picap Carro', 'Picap Moto', 'Grúa Carro', 'Grúa Moto'
          ) THEN 'Picap'
          ELSE 'Other'
        END AS type
      FROM (SELECT * FROM picapmongoprod.service_types FINAL)
    ),
    q_wat_filtered AS (
      SELECT
        wat._id          AS transaction_id,
        wat.booking_id   AS booking_id,
        wat.amount       AS amount,
        wat.created_at   AS created_at,
        b.created_at     AS booking_created_at,
        pck.reference    AS package_reference,
        compp.name       AS company_name
      FROM picapmongoprod.wallet_account_transactions AS wat FINAL
      INNER JOIN picapmongoprod.packages       AS pck   FINAL ON pck._id   = wat.package_id
      INNER JOIN picapmongoprod.bookings       AS b     FINAL ON b._id     = wat.booking_id
      INNER JOIN picapmongoprod.wallet_accounts AS wa   FINAL ON wa._id    = wat.account_id
      INNER JOIN picapmongoprod.passengers     AS p     FINAL ON p._id     = b.passenger_id
      INNER JOIN picapmongoprod.countries      AS c     FINAL ON c._id     = b.country_id
      INNER JOIN picapmongoprod.companies      AS compp FINAL ON compp._id = p.company_id
      WHERE
        JSONExtractString(c.name, 'es') = 'Colombia'
        AND JSONExtractString(wat.amount, 'currency_iso') = 'COP'
        AND pck.counter_delivery = 'true'
        AND wat._type = 'WalletAccountCounterDeliveryPaymentTransaction'
        AND lowerUTF8(compp.name) LIKE '%surtitodo%'
        AND toDate(toTimeZone(wat.created_at, 'America/Bogota'))
            BETWEEN toDate('%{fecha_desde}') AND toDate('%{fecha_hasta}')
    )
    SELECT
      qtf.transaction_id                                            AS ID_TRANSACCION,
      toDate(toTimeZone(qtf.booking_created_at, 'America/Bogota'))  AS FECHA,
      qtf.package_reference                                         AS DESCRIPCION,
      toFloat64OrZero(JSONExtractString(qtf.amount, 'cents')) / 100 AS MONTO
    FROM q_wat_filtered qtf
    ORDER BY FECHA ASC
  SQL

  # Query B: Valor Mensajería (BookingCompanyCharge + Commission). 5 cols.
  # Variables: %{fecha_desde}, %{fecha_hasta}
  Q_ESTADO_CUENTA_VALOR_MENSAJERIA = <<~'SQL'
    WITH q_service_types AS (
      SELECT
        _id,
        any(name_es) AS name,
        any(
          multiIf(
            name_es IN (
              'Pibox (Mensajería)', 'Mensajería en bicicleta', 'Moto Favor',
              'Moto favor', 'Carga', 'Carga Carry', 'Carga Moto-Vagón',
              'Carga NHR', 'Carga NKR', 'Carga NPR', 'Mensajería',
              'Carro Mensajeria', 'Carga Trailer', 'NHR Refrigerada'
            ), 'Pibox',
            name_es IN (
              'Moto', 'Mototaxi', 'Moto sin conductor', 'Subasta', 'Taxi',
              'Carro', 'Rapidín', 'Carro sin conductor', 'Moto VIP',
              'Moto Económica', 'Carro Queen', 'Espero tranqui',
              'Moto lite', 'Moto Queen', 'Picap Carro', 'Picap Moto',
              'Grúa Carro', 'Grúa Moto'
            ), 'Picap',
            'Other'
          )
        ) AS type
      FROM picapmongoprod.service_types
      GROUP BY _id
    ),
    q_transactions_filtered AS (
      SELECT
        wat._id          AS _id,
        wat.booking_id   AS booking_id,
        wat._type        AS txt_type,
        wat.created_at   AS created_at,
        wat.amount       AS amount,
        s.served_vehicle_type_id AS served_vehicle_type_id,
        comp.name        AS company_name,
        st.type          AS service_type
      FROM picapmongoprod.wallet_account_transactions wat FINAL
      ANY LEFT JOIN picapmongoprod.bookings        s    FINAL ON s._id    = wat.booking_id
      ANY LEFT JOIN q_service_types                st         ON st._id   = s.requested_service_type_id
      ANY LEFT JOIN picapmongoprod.wallet_accounts wa   FINAL ON wa._id   = wat.account_id
      ANY LEFT JOIN picapmongoprod.companies       comp FINAL ON comp._id = s.company_id
      WHERE
        wat._type IN (
          'WalletAccountTransactionBookingCompanyCharge',
          'WalletAccountTransactionCommissionCompanyPayment'
        )
        AND JSONExtractString(wat.amount, 'currency_iso') = 'COP'
        AND st.type = 'Pibox'
        AND lowerUTF8(comp.name) LIKE '%surtitodo%'
        AND toDate(toTimeZone(wat.created_at, 'America/Bogota'))
            BETWEEN toDate('%{fecha_desde}') AND toDate('%{fecha_hasta}')
    )
    SELECT
      qtf.booking_id                                                AS ID_SERVICIO,
      toDate(toTimeZone(qtf.created_at, 'America/Bogota'))          AS FECHA,
      qtf.company_name                                              AS EMPRESA,
      JSONExtractString(vt.name, 'es')                              AS TIPO_VEHICULO,
      toFloat64OrZero(JSONExtractString(qtf.amount, 'cents')) / 100 AS MONTO
    FROM q_transactions_filtered qtf
    LEFT JOIN picapmongoprod.vehicle_types AS vt FINAL ON vt._id = qtf.served_vehicle_type_id
    ORDER BY FECHA ASC, qtf.booking_id
  SQL

  # ═══════════════════════════════════════════════════════════════════════════
  # v3.3.52: Validador de Dispersiones — submódulo de Cash Out.
  # Muestra transacciones de dispersión (wallet_account_transactions) con su
  # estado real (Pago exitoso / Aprobado / Reembolso / Pendiente / Otro).
  #
  # Variables placeholder:
  #   %{fecha_desde}    requerido (date_time YYYY-MM-DD HH:MM:SS, America/Bogota)
  #   %{fecha_hasta}    requerido
  #   %{filtro_extra}   opcional - bloque AND ... AND ... ya sanitizado en Ruby.
  # ═══════════════════════════════════════════════════════════════════════════
  # ═══════════════════════════════════════════════════════════════════════════
  # v3.3.56: Consolidado Cash Out — informe mensual de retiros por jornada,
  # tipo de usuario y categoría. Construido sobre la misma base que el
  # Validador pero clasificando además clientes (company_id NOT NULL).
  #
  # Devuelve: Fecha, Jornada, Tipo_de_Usuario, Tipo, Tipo_de_Desglosado,
  #           Valor, Es_Cliente (UInt8), Cliente_Nombre.
  # ═══════════════════════════════════════════════════════════════════════════
  Q_CONSOLIDADO_CASH_OUT = <<~'SQL'
    WITH base AS (
      SELECT
          formatDateTime(toTimeZone(wat.created_at, 'America/Bogota'), '%d/%m/%Y %H:%i:%S') AS Fecha,
          toTimeZone(wat.created_at, 'America/Bogota')                                       AS _ts_bog,
          wat._type                                                                          AS _wat_type,
          lower(JSONExtractString(st.name, 'es'))                                            AS _svc_name,
          p.driver_enrollment_status_cd                                                      AS _driver_status,
          toFloat64OrNull(JSONExtractString(wat.amount, 'cents')) / 100                      AS Valor,
          wa.company_id                                                                      AS _company_id,
          if(notEmpty(toString(wa.company_id)) AND wa.company_id != '', comp.name, '')       AS Cliente_Nombre
      FROM picapmongoprod.wallet_account_transactions       AS wat FINAL
      INNER JOIN picapmongoprod.wallet_accounts             AS wa   FINAL ON wa._id   = wat.account_id
      LEFT  JOIN picapmongoprod.passengers                  AS p    FINAL ON p._id    = wa.passenger_id
      LEFT  JOIN picapmongoprod.bookings                    AS b    FINAL ON b._id    = wat.booking_id
      LEFT  JOIN picapmongoprod.service_types               AS st   FINAL ON st._id   = b.requested_service_type_id
      LEFT  JOIN picapmongoprod.companies                   AS comp FINAL ON comp._id = wa.company_id
      WHERE wat.created_at BETWEEN toDateTime('%{fecha_desde}', 'America/Bogota')
                               AND toDateTime('%{fecha_hasta}', 'America/Bogota')
        AND JSONExtractString(wat.amount, 'currency_iso') = 'COP'
        AND wat.status_cd IN (0, 1, 2)
        AND lower(wat._type) NOT IN (
            'walletaccounttransactionpocketconciliation',
            'walletaccounttransactionpenaltycancelpayment',
            'walletaccounttransactioncommissiondriverpayment',
            'walletaccounttransactiondirectpayment',
            'walletaccounttransactionexpirepromobalance',
            'walletaccounttransactionpromocodemultipleuse',
            'walletaccounttransactionpenaltycancelrefund',
            'walletaccountdriverbalancetransactiondaviplatacashout',
            'walletaccounttransactiondriverproplancheckout',
            'walletaccounttransactionpiboxpenalty',
            'walletaccounttransactioncompanyinvoiceadjustment',
            'walletaccounttransactionpinpurchase',
            'walletaccounttransactionbookingcompanycharge',
            'walletaccounttransactionextracharge',
            'walletaccounttransactioncommissioncompanypayment',
            'walletaccounttransactionbookingcompanycollectionfee',
            'walletaccounttransactionbookingcompanyivacharge',
            'walletaccounttransactionbookingpassengercharge',
            'walletaccounttransactionpenaltycancel',
            'walletaccounttransactionpenaltycancelpaymentcommission',
            'walletaccounttransactionfraudcommission',
            'walletaccounttransactionbookingdriverretention'
        )
    ),
    classified AS (
      SELECT
          Fecha,
          multiIf(
            (toHour(_ts_bog) * 60 + toMinute(_ts_bog)) BETWEEN 481 AND 720, 'Bolsa Tarde',
            (toHour(_ts_bog) * 60 + toMinute(_ts_bog)) >= 721
              OR (toHour(_ts_bog) * 60 + toMinute(_ts_bog)) <= 480,          'Bolsa Mañana',
            'Otro'
          ) AS Jornada,
          multiIf(
            lower(_wat_type) = 'walletaccounttransactionbatchdispersion', 'Empleado',
            _driver_status = 3,                                            'Piloto',
            'Pasajero'
          ) AS Tipo_de_Usuario,
          CASE
            WHEN lower(_wat_type) = 'walletaccounttransactionbookingdriverpayment' AND _svc_name IN ('mensajería','mensajeria','delivery')                                            THEN 'Pibox Moto'
            WHEN lower(_wat_type) = 'walletaccounttransactionbookingdriverpayment' AND _svc_name IN ('moto','moto vip','rapidín','rapidin','espero tranqui','carro','picap moto','picap carro','subasta') THEN 'Rent'
            WHEN lower(_wat_type) = 'walletaccounttransactionbookingdriverpayment' AND _svc_name IN ('carga','carga carry','carga nhr','carga moto-vagón','carga moto-vagon','carga npr','carga nkr','carro mensajeria','carga trailer','nhr refrigerada','mensajería en bicicleta','moto favor') THEN 'Mensajería Pibox'
            WHEN lower(_wat_type) IN ('walletaccountcounterdeliverytransaction','walletaccountcounterdeliverypaymenttransaction')                                                      THEN 'Pago contraentrega Pibox'
            WHEN lower(_wat_type) = 'walletaccounttransactiondriverrecharge'                  THEN 'Recarga'
            WHEN lower(_wat_type) = 'walletaccounttransactionbookingpssgretentiondiscount'    THEN 'Motor de Retención'
            WHEN lower(_wat_type) = 'walletaccounttransactioncreditinstalmentpayment'         THEN 'Crédito Pibank'
            WHEN lower(_wat_type) = 'walletaccountsendmoneytransaction'                       THEN 'Envío'
            WHEN lower(_wat_type) = 'walletaccounttransactionbookingdriverincentive'          THEN 'Pago de Incentivo'
            WHEN lower(_wat_type) = 'walletaccounttransactiondriverstreak'                    THEN 'Bono de Racha'
            WHEN lower(_wat_type) = 'walletaccounttransactionchargemoney'                     THEN 'Recarga TC'
            WHEN lower(_wat_type) = 'walletaccounttransactionbatchdispersion'                 THEN 'Bono Pibox'
            WHEN lower(_wat_type) = 'walletaccounttransactionpromocampaign'                   THEN 'Pago de Campaña'
            WHEN lower(_wat_type) = 'walletaccounttransactionbookinghelpbonus'                THEN 'Inmovilizaciones'
            WHEN lower(_wat_type) = 'walletaccounttransactionrefacilnequipayment'             THEN 'Recarga Refacilpay'
            WHEN lower(_wat_type) = 'walletaccounttransactionsacrequest'                      THEN 'SAC Reclamaciones'
            ELSE 'Otro'
          END AS Tipo_de_Desglosado,
          if(notEmpty(toString(_company_id)) AND _company_id != '', 1, 0) AS Es_Cliente,
          Cliente_Nombre,
          Valor,
          _ts_bog
      FROM base
    )
    SELECT
        Fecha,
        Jornada,
        Tipo_de_Usuario,
        multiIf(
          -- v3.3.57: Bono Pibox entra en Mensajería Pibox
          Tipo_de_Desglosado IN ('Pibox Moto','Pago contraentrega Pibox','Mensajería Pibox','Bono Pibox'), 'Mensajería Pibox',
          Tipo_de_Desglosado = 'Rent',                                                                     'Rent',
          Tipo_de_Desglosado IN ('Inmovilizaciones','SAC Reclamaciones'),                                  'Pago Reclamaciones',
          Tipo_de_Desglosado
        ) AS Tipo,
        Tipo_de_Desglosado,
        Valor,
        Es_Cliente,
        Cliente_Nombre
    FROM classified
    -- v3.3.57: solo entradas a la Picash (positivas) y sin 'Otro' (catch-all sin clasificar)
    WHERE Valor > 0
      AND Tipo_de_Desglosado != 'Otro'
    ORDER BY _ts_bog DESC
    SETTINGS join_use_nulls = 0
  SQL

  Q_VALIDADOR_DISPERSIONES = <<~'SQL'
    SELECT * EXCEPT rn
    FROM (
      SELECT
        wat.created_at                                                AS creacion_tx,
        wat._id                                                       AS id_tx,
        wa.passenger_id                                               AS id_user,
        p.name                                                        AS name_user,
        JSONExtractString(wat.amount, 'currency_iso')                 AS moneda,
        toFloat64OrNull(JSONExtractString(wat.amount, 'cents')) / 100 AS valor,
        bk.name                                                       AS name_bank,
        wat.consecutive                                               AS consecutivo,
        wat.daviplata_response                                        AS daviplata_response,
        wat.status_cd                                                 AS status_cd,
        CASE
          WHEN (wat.daviplata_response = '' OR wat.daviplata_response IS NULL)
               AND wat.status_cd = 2 THEN 'Reembolso'
          WHEN wat.status_cd = 2 THEN 'Aprobado'
          WHEN wat.status_cd = 0 THEN 'Pendiente'
          WHEN wat.status_cd = 1 THEN 'Pago exitoso'
          ELSE 'Otro'
        END                                                           AS estado,
        ROW_NUMBER() OVER (PARTITION BY wat._id ORDER BY wat.created_at DESC) AS rn
      FROM picapmongoprod.wallet_account_transactions wat
      LEFT JOIN picapmongoprod.wallet_accounts wa  ON wat.account_id = wa._id
      LEFT JOIN picapmongoprod.passengers     p   ON wa.passenger_id = p._id
      LEFT JOIN picapmongoprod.bank_accounts  ba  ON ba.passenger_id = wa.passenger_id
      LEFT JOIN picapmongoprod.bank_account_types bat ON ba.bank_id = bat._id
      LEFT JOIN picapmongoprod.banks          bk  ON ba.bank_id     = bk._id
      WHERE
        wat.created_at BETWEEN toDateTime('%{fecha_desde}', 'America/Bogota')
                           AND toDateTime('%{fecha_hasta}', 'America/Bogota')
        AND notEmpty(wat.consecutive)
        AND wat.consecutive != ''
        %{filtro_extra}
      GROUP BY ALL
    )
    WHERE rn = 1
    ORDER BY creacion_tx DESC
  SQL

  # ╔══════════════════════════════════════════════════════════════════════════╗
  # ║ Q_CAMPAIGN_VALIDATOR  v1.0                                               ║
  # ║ Endpoint: GET /api/campaign_validator/cargar_async?desde=&hasta=         ║
  # ║ NOTAS DE SCHEMA:                                                         ║
  # ║   • campaign_id: columna directa en wallet_account_transactions.         ║
  # ║     Si no existe usar: toString(JSONExtractString(metadata,'campaign_id'))║
  # ║   • picapmongoprod.campaigns: si no existe, reemplazar el CTE camp       ║
  # ║     con '' AS nombre_camp, '' AS tyc en el SELECT final.                 ║
  # ║   • monitoreo / trump / fraude: se añaden en v1.1 vía bookings+trump.   ║
  # ╚══════════════════════════════════════════════════════════════════════════╝
  Q_CAMPAIGN_VALIDATOR = <<~'SQL'
    WITH
    /* 1. Transacciones de pago de campaña en el rango */
    wat_raw AS (
        SELECT
            _id,
            account_id,
            toTimeZone(created_at, 'America/Bogota')                         AS fecha_tx,
            toFloat64OrNull(JSONExtractString(amount, 'cents')) / 100        AS valor,
            JSONExtractString(amount, 'currency_iso')                        AS moneda,
            toString(campaign_id)                                            AS campaign_id,
            ROW_NUMBER() OVER (
                PARTITION BY _id
                ORDER BY ifNull(_sdc_batched_at, created_at) DESC
            ) AS rn
        FROM picapmongoprod.wallet_account_transactions
        WHERE lower(_type) = 'walletaccounttransactionpromocampaign'
          AND created_at BETWEEN toDateTime('%{fecha_desde}', 'America/Bogota')
                             AND toDateTime('%{fecha_hasta}', 'America/Bogota')
    ),
    wat AS (SELECT * FROM wat_raw WHERE rn = 1),

    /* 2. Wallet accounts → passenger_id del piloto */
    wa AS (
        SELECT _id,
               argMax(passenger_id, ifNull(_sdc_batched_at, created_at)) AS passenger_id
        FROM picapmongoprod.wallet_accounts
        WHERE _id IN (SELECT DISTINCT account_id FROM wat WHERE notEmpty(account_id))
        GROUP BY _id
    ),

    /* 3. Nombre, país y ciudad del piloto */
    drv AS (
        SELECT
            _id,
            argMax(
                trim(CONCAT(name,
                     if(notEmpty(ifNull(last_name, '')), CONCAT(' ', last_name), ''))),
                _sdc_batched_at
            )                                                        AS nombre,
            argMax(g_country,       _sdc_batched_at)                 AS pais,
            argMax(g_adm_area_lv_1, _sdc_batched_at)                 AS ciudad
        FROM picapmongoprod.passengers
        WHERE _id IN (SELECT DISTINCT passenger_id FROM wa WHERE notEmpty(passenger_id))
        GROUP BY _id
    ),

    /* 4. Nombre de la campaña. v3.3.62: terms_url no existe en picapmongoprod.campaigns.
       v3.3.67: campaigns.name suele ser string plano (no JSON). Defensivo:
       intentar JSON con clave 'es'; si no aplica, usar name crudo. */
    camp AS (
        SELECT
            _id,
            argMax(
                coalesce(
                    nullIf(JSONExtractString(name, 'es'), ''),
                    name
                ),
                updated_at
            ) AS nombre_camp
        FROM picapmongoprod.campaigns
        WHERE notEmpty(_id)
          AND _id IN (SELECT DISTINCT campaign_id FROM wat WHERE notEmpty(campaign_id))
        GROUP BY _id
    )

    SELECT
        w._id                          AS id_tx,
        w.fecha_tx,
        wa.passenger_id                AS driver_id,
        ifNull(drv.nombre, '')         AS nombre,
        ifNull(drv.pais,   '')         AS pais,
        ifNull(drv.ciudad, '')         AS ciudad,
        w.campaign_id                  AS id_camp,
        ifNull(camp.nombre_camp, '')   AS nombre_camp,
        w.valor,
        w.moneda,
        ''                             AS tyc,
        0                              AS servicios,
        ''                             AS monitoreo,
        '(sin alerta)'                 AS trump,
        0                              AS fraud_suspect
    -- v3.3.63: INNER → LEFT en wa (no perder tx cuando wallet_account no está en CH).
    FROM wat w
    LEFT  JOIN wa   ON wa._id    = w.account_id
    LEFT  JOIN drv  ON drv._id   = wa.passenger_id
    LEFT  JOIN camp ON camp._id  = w.campaign_id
    ORDER BY w.fecha_tx DESC
    SETTINGS join_use_nulls = 1
  SQL

  # ╔══════════════════════════════════════════════════════════════════════════╗
  # ║ Q_CAMPAIGN_VALIDATOR_DETALLE  v3.3.72                                    ║
  # ║ Query rica que pobla la tab "Detallado" con info por servicio:           ║
  # ║   id_booking, timestamps (aceptado/llegó/finalizado/fecha),              ║
  # ║   nombres conductor/pasajero, empresa/país/ciudad, IMEI driver+passenger,║
  # ║   status_carrera, valor_campana/tyc, revision_imei (mismo IMEI / multi), ║
  # ║   reason_text (Regla Trump), regla_distancia (Monitoreo: geoDistance     ║
  # ║   con umbral 450m COL / 280m MX,NI), service_type.                       ║
  # ║                                                                          ║
  # ║ NO afecta tab Estadística (esa usa Q_CAMPAIGN_VALIDATOR v1).             ║
  # ║ Filtros: PromoCampaign en rango + bookings status_cd=4 (finalizados).    ║
  # ╚══════════════════════════════════════════════════════════════════════════╝
  Q_CAMPAIGN_VALIDATOR_DETALLE = <<~'SQL'
    WITH
    q_wat AS (
        SELECT
            wat._id,
            toTimeZone(wat.created_at, 'America/Bogota')                         AS created_at,
            intDiv(toInt64OrZero(JSONExtractString(wat.amount, 'cents')), 100)   AS amount,
            wat.confirmed_booking_cycle_campaign_cycle_id                        AS cycle_id
        FROM (SELECT * FROM picapmongoprod.wallet_account_transactions FINAL) wat
        WHERE toTimeZone(wat.created_at, 'America/Bogota')
              BETWEEN toDateTime('%{fecha_desde}', 'America/Bogota')
              AND     toDateTime('%{fecha_hasta}', 'America/Bogota')
          AND wat._type = 'WalletAccountTransactionPromoCampaign'
    ),
    q_cycles AS (
        SELECT cc._id, cc.confirmed_booking_cycle_campaign_id, cc.booking_ids
        FROM picapmongoprod.confirmed_booking_cycle_campaign_cycles AS cc FINAL
        INNER JOIN (SELECT DISTINCT cycle_id FROM q_wat WHERE notEmpty(toString(cycle_id))) cid
            ON cc._id = cid.cycle_id
    ),
    q_camp AS (
        SELECT
            c._id,
            coalesce(nullIf(JSONExtractString(c.name, 'es'), ''), c.name) AS campaign_name,
            c.terms_conditions                                            AS tyc
        FROM picapmongoprod.campaigns AS c FINAL
        INNER JOIN (
            SELECT DISTINCT confirmed_booking_cycle_campaign_id AS id
            FROM q_cycles WHERE notEmpty(toString(confirmed_booking_cycle_campaign_id))
        ) cid ON c._id = cid.id
    ),
    campaign_data_expanded AS (
        SELECT
            trimBoth(replaceAll(flattened, '"', '')) AS booking_id,
            cc._id                                   AS cycle_id,
            cc.confirmed_booking_cycle_campaign_id   AS campaign_id,
            w.created_at, w._id AS transaction_id, w.amount
        FROM q_cycles cc
        INNER JOIN q_wat w ON w.cycle_id = cc._id
        ARRAY JOIN assumeNotNull(splitByString(
            '","',
            replaceAll(replaceAll(assumeNotNull(ifNull(cc.booking_ids, '[]')), '["', ''), '"]', '')
        )) AS flattened
        WHERE flattened != ''
    ),
    campaign_data AS (
        SELECT
            cde.booking_id,
            min(cde.created_at) AS dat_created,
            c.campaign_name,
            c._id AS campaign_id,
            c.tyc,
            cde.transaction_id,
            cde.amount AS valor_bono
        FROM campaign_data_expanded cde
        LEFT JOIN q_camp c ON c._id = cde.campaign_id
        GROUP BY cde.booking_id, c.campaign_name, c._id, c.tyc, cde.transaction_id, cde.amount
    ),
    q_bookings AS (
        SELECT
            b._id, b.driver_id, b.passenger_id, b.passenger_session_id, b.driver_session_id,
            b.status_cd, b.requested_service_type_id, b.company_id, b.country_id, b.city_id,
            intDiv(toInt64OrZero(JSONExtractString(b.final_cost, 'cents')), 100) AS final_cost,
            b.is_campaign_fraud_suspect,
            b.reasons_to_verify,
            toFloat64OrNull(extract(ifNull(b.events, ''), 'event_cd":24.?coordinates":\[\s([+-]?\d+\.\d+)')) AS drop_lon,
            toFloat64OrNull(extract(ifNull(b.events, ''), 'event_cd":24.?coordinates":\[.?,\s*([+-]?\d+\.\d+)')) AS drop_lat,
            toFloat64OrNull(JSONExtractString(b.end_geojson, 'coordinates', 1)) AS end_lon,
            toFloat64OrNull(JSONExtractString(b.end_geojson, 'coordinates', 2)) AS end_lat,
            JSONExtractString(b.final_cost, 'currency_iso') AS currency_iso
        FROM (SELECT * FROM picapmongoprod.bookings FINAL) b
        INNER JOIN (SELECT DISTINCT booking_id AS id FROM campaign_data_expanded WHERE notEmpty(booking_id)) bid
            ON b._id = bid.id
        WHERE b.status_cd = 4
    ),
    q_passengers AS (
        SELECT DISTINCT p._id, p.name
        FROM (SELECT * FROM picapmongoprod.passengers FINAL) p
        INNER JOIN (
            SELECT driver_id AS id FROM q_bookings WHERE notEmpty(toString(driver_id))
            UNION DISTINCT
            SELECT passenger_id AS id FROM q_bookings WHERE notEmpty(toString(passenger_id))
        ) pn ON p._id = pn.id
    ),
    q_sessions AS (
        SELECT DISTINCT s._id, s.imei
        FROM (SELECT * FROM picapmongoprod.sessions FINAL) s
        INNER JOIN (
            SELECT passenger_session_id AS id FROM q_bookings WHERE notEmpty(toString(passenger_session_id))
            UNION DISTINCT
            SELECT driver_session_id AS id FROM q_bookings WHERE notEmpty(toString(driver_session_id))
        ) sn ON s._id = sn.id
    ),
    q_events AS (
        SELECT
            booking_id,
            max(tms_accepted)        AS tms_accepted,
            max(tms_arrived)         AS tms_arrived,
            max(tms_dropped_off)     AS tms_dropped_off,
            max(tms_created_parent)  AS tms_created_parent
        FROM (SELECT * FROM picapmongoprod.dm_processed_events FINAL)
        WHERE booking_id IN (SELECT _id FROM q_bookings)
        GROUP BY booking_id
    ),
    imei_counts AS (
        SELECT sp.imei AS imei_user, uniqExact(b.passenger_id) AS user_count
        FROM q_bookings b
        LEFT JOIN q_sessions sp ON sp._id = b.passenger_session_id
        GROUP BY sp.imei
    ),
    q_revision_imei AS (
        SELECT
            b._id AS id_booking,
            multiIf(
                sd.imei = sp.imei,     'Mismo IMEI entre usuarios',
                ic.user_count >= 2,    'IMEI con dos o más cuentas',
                'OK'
            ) AS revision_imei
        FROM q_bookings b
        LEFT JOIN q_sessions sd ON sd._id = b.driver_session_id
        LEFT JOIN q_sessions sp ON sp._id = b.passenger_session_id
        LEFT JOIN imei_counts ic ON sp.imei = ic.imei_user
    )

    SELECT
        cd.booking_id                                  AS id_booking,
        be.tms_accepted                                AS aceptado,
        be.tms_arrived                                 AS conductor_llego,
        be.tms_dropped_off                             AS finalizado,
        be.tms_created_parent                          AS fecha,
        ifNull(d.name, '')                             AS driver_name,
        ifNull(p.name, '')                             AS passenger_name,
        sn.driver_id                                   AS driver_id,
        sn.passenger_id                                AS passenger_id,
        JSONExtractString(comp.name, 'en')             AS company_name,
        JSONExtractString(coun.name, 'en')             AS country_name,
        JSONExtractString(cit.name, 'en')              AS city_name,
        ifNull(sed.imei, '')                           AS imei_driver,
        ifNull(sep.imei, '')                           AS imei_passenger,
        caseWithExpression(
            sn.status_cd,
            102, 'Cancelado Por Pasajero',
            4,   'Finalizado Por Conductor',
            1,   'Conductor En Ruta',
            3,   'Pasajero A Bordo',
            101, 'Expirado',
            100, 'Cancelado Por Conductor',
            0,   'Esperando Pasajero',
            2,   'Cancelado Por Pasajero',
            ''
        )                                              AS status_carrera,
        cd.campaign_id                                 AS id_campana,
        cd.campaign_name                               AS nombre_campana,
        cd.dat_created                                 AS fecha_bono,
        cd.valor_bono                                  AS valor_campana,
        ifNull(cd.tyc, '')                             AS tyc,
        ifNull(ri.revision_imei, 'OK')                 AS revision_imei,
        cd.transaction_id                              AS id_tx,
        sn.final_cost                                  AS valor,
        sn.is_campaign_fraud_suspect                   AS fraud_suspect,
        if(
            sn.reasons_to_verify IS NOT NULL
            AND length(JSONExtractArrayRaw(assumeNotNull(sn.reasons_to_verify))) > 0,
            arrayElement(JSONExtractArrayRaw(assumeNotNull(sn.reasons_to_verify)), 1),
            ''
        )                                              AS reason_text,
        multiIf(
            sn.drop_lon IS NULL OR sn.drop_lat IS NULL OR sn.end_lon IS NULL OR sn.end_lat IS NULL,
            'SIN_COORDENADAS',
            geoDistance(
                assumeNotNull(sn.drop_lon), assumeNotNull(sn.drop_lat),
                assumeNotNull(sn.end_lon),  assumeNotNull(sn.end_lat)
            ) <= if(sn.currency_iso = 'COP', 450, 280),
            'LLEGO_AL_DESTINO',
            'NO_LLEGO_AL_DESTINO'
        )                                              AS regla_distancia,
        ifNull(st.svc_name, '')                        AS service_type,
        sn.currency_iso                                AS currency_iso
    FROM campaign_data cd
    LEFT JOIN q_bookings sn   ON sn._id  = cd.booking_id
    LEFT JOIN q_events    be  ON be.booking_id = sn._id
    LEFT JOIN q_passengers d  ON d._id   = sn.driver_id
    LEFT JOIN q_passengers p  ON p._id   = sn.passenger_id
    LEFT JOIN (SELECT _id, name FROM picapmongoprod.companies FINAL) comp ON comp._id = sn.company_id
    LEFT JOIN (SELECT _id, name FROM picapmongoprod.countries FINAL) coun ON coun._id = sn.country_id
    LEFT JOIN (SELECT _id, name FROM picapmongoprod.cities    FINAL) cit  ON cit._id  = sn.city_id
    LEFT JOIN q_sessions sed  ON sed._id = sn.driver_session_id
    LEFT JOIN q_sessions sep  ON sep._id = sn.passenger_session_id
    LEFT JOIN (SELECT _id, JSONExtractString(name, 'en') AS svc_name FROM picapmongoprod.service_types FINAL) st
           ON st._id = sn.requested_service_type_id
    LEFT JOIN q_revision_imei ri ON ri.id_booking = sn._id
    WHERE sn._id IS NOT NULL
    ORDER BY be.tms_created_parent DESC
    /* v3.3.74: SETTINGS minimos. join_use_nulls=1 (preserva NULL en LEFT JOINs);
       grace_hash spill a disco para joins grandes sin OOM. */
    SETTINGS
        join_use_nulls    = 1,
        join_algorithm    = 'grace_hash',
        max_bytes_in_join = 5000000000
  SQL
end
