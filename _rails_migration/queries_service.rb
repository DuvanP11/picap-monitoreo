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
  Q_BLOQUEOS = <<~'SQL'
    WITH ultimos_ps AS (
        SELECT
            starts_at   AS starts_block_p,
            ends_at     AS ends_block_p,
            passenger_id,
            created_at,
            updated_at  AS reactivado_en_p,
            ROW_NUMBER() OVER (
                PARTITION BY passenger_id
                ORDER BY created_at DESC NULLS LAST
            ) AS rn
        FROM picapmongoprod.passenger_suspensions
        WHERE created_at IS NOT NULL
    ),
    ultimos_ds AS (
        SELECT
            starts_at   AS starts_block_d,
            ends_at     AS ends_block_d,
            driver_id,
            created_at,
            updated_at  AS reactivado_en_d,
            ROW_NUMBER() OVER (
                PARTITION BY driver_id
                ORDER BY created_at DESC NULLS LAST
            ) AS rn
        FROM picapmongoprod.driver_suspensions
        WHERE created_at IS NOT NULL
    ),
    ps_final AS (SELECT * FROM ultimos_ps WHERE rn = 1),
    ds_final AS (SELECT * FROM ultimos_ds WHERE rn = 1)
    SELECT
        p._id                                        AS id_usuario,
        p.name                                       AS nombre,
        p.g_country                                  AS pais_codigo,
        p.g_adm_area_lv_1                            AS ciudad,
        ps.starts_block_p                            AS starts_block_user,
        ps.ends_block_p                              AS ends_block_user,
        ifNull(toString(p.suspended), '')            AS suspendido,
        ifNull(p.passenger_suspension_comment, '')   AS comentario_user,
        ifNull(p.passenger_expulsion_comment, '')    AS comentario_expulsion_user,
        dateDiff('day', toDate(ps.created_at), today()) AS dias_suspension_user,
        ds.starts_block_d                            AS starts_block_driver,
        ds.ends_block_d                              AS ends_block_driver,
        ifNull(toString(p.is_driver_suspended), '')  AS driver_suspendido,
        ifNull(p.driver_suspension_comment, '')      AS comentario_driver,
        dateDiff('day', toDate(ds.created_at), today()) AS dias_suspension_driver,
        ifNull(toString(p.expelled), '')             AS expulsado,
        CASE
            WHEN lower(ifNull(toString(p.expelled),'')) = 'true' THEN 'EXPULSADO'
            WHEN lower(ifNull(toString(p.suspended),'')) = 'true'
              OR lower(ifNull(toString(p.is_driver_suspended),'')) = 'true' THEN 'SUSPENDIDO'
            ELSE 'ACTIVO'
        END AS tipo_bloqueo,
        CASE
            WHEN p.driver_enrollment_status_cd = 3 THEN 'PILOTO'
            ELSE 'USUARIO'
        END AS tipo_usuario,
        formatDateTime(
            toTimeZone(
                coalesce(
                    if(ps.created_at IS NOT NULL AND ds.created_at IS NOT NULL,
                       greatest(ps.created_at, ds.created_at), NULL),
                    ps.created_at, ds.created_at
                ), 'America/Bogota'
            ), '%Y-%m-%d %H:%M'
        ) AS fecha_ultima_suspension,
        dateDiff('day', toDate(coalesce(
            if(ps.created_at IS NOT NULL AND ds.created_at IS NOT NULL,
               greatest(ps.created_at, ds.created_at), NULL),
            ps.created_at, ds.created_at
        )), today()) AS dias_bloqueado_total,
        multiIf(
            ds.starts_block_d IS NOT NULL
                AND (ps.created_at IS NULL OR ds.created_at >= ps.created_at),
            greatest(0, dateDiff('day',
                toDate(ds.starts_block_d),
                if(
                    ds.reactivado_en_d IS NOT NULL
                    AND ds.reactivado_en_d > ds.starts_block_d
                    AND ds.reactivado_en_d <= now()
                    AND lower(ifNull(toString(p.expelled),'')) != 'true'
                    AND lower(ifNull(toString(p.suspended),'')) IN ('false','0','')
                    AND lower(ifNull(toString(p.is_driver_suspended),'')) IN ('false','0',''),
                    toDate(ds.reactivado_en_d),
                    today()
                )
            )),
            ps.starts_block_p IS NOT NULL,
            greatest(0, dateDiff('day',
                toDate(ps.starts_block_p),
                if(
                    ps.reactivado_en_p IS NOT NULL
                    AND ps.reactivado_en_p > ps.starts_block_p
                    AND ps.reactivado_en_p <= now()
                    AND lower(ifNull(toString(p.expelled),'')) != 'true'
                    AND lower(ifNull(toString(p.suspended),'')) IN ('false','0','')
                    AND lower(ifNull(toString(p.is_driver_suspended),'')) IN ('false','0',''),
                    toDate(ps.reactivado_en_p),
                    today()
                )
            )),
            dateDiff('day', toDate(coalesce(
                if(ps.created_at IS NOT NULL AND ds.created_at IS NOT NULL,
                   greatest(ps.created_at, ds.created_at), NULL),
                ps.created_at, ds.created_at
            )), today())
        ) AS dias_bloqueo_real,
        CASE
            WHEN lower(ifNull(toString(p.expelled),'')) = 'true' THEN 'Permanente (expulsión)'
            WHEN dateDiff('day', toDate(coalesce(
                if(ps.created_at IS NOT NULL AND ds.created_at IS NOT NULL,
                   greatest(ps.created_at, ds.created_at), NULL),
                ps.created_at, ds.created_at
            )), today()) > 30 THEN 'Más de 30 días'
            ELSE 'Menos de 30 días'
        END AS estado_suspension,
        CASE
            WHEN lower(ifNull(toString(p.expelled),'')) = 'true'
              OR lower(ifNull(toString(p.suspended),'')) = 'true' THEN 'bloqueado'
            WHEN lower(ifNull(toString(p.expelled),'')) = 'false'
             AND lower(ifNull(toString(p.suspended),'')) = 'false' THEN 'activo'
            ELSE ''
        END AS esta_activo
    FROM picapmongoprod.passengers AS p
    LEFT JOIN ps_final AS ps ON p._id = ps.passenger_id
    LEFT JOIN ds_final AS ds ON p._id = ds.driver_id
    WHERE coalesce(
        if(ps.created_at IS NOT NULL AND ds.created_at IS NOT NULL,
           greatest(ps.created_at, ds.created_at), NULL),
        ps.created_at, ds.created_at
    ) BETWEEN toDateTime('%{fecha_desde} 00:00:00')
          AND toDateTime('%{fecha_hasta} 23:59:59')
    ORDER BY fecha_ultima_suspension DESC
    LIMIT 10000
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
end
