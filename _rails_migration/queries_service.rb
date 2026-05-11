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
  # STUBS — queries placeholder (se reescribirán en bloques B-F con queries
  # correctas de Python). Por ahora existen para que los controllers no
  # rompan con NameError. Pueden devolver datos incorrectos hasta entonces.
  # ════════════════════════════════════════════════════════════════════════

  # Pagos TC — usado por pagos_controller#tc (stub simple)
  TC_BASE_CTE = <<~'SQL'
    WITH pagos_tc AS (
        SELECT
            b._id              AS booking_id,
            b.driver_id,
            b.passenger_id,
            toDate(toTimeZone(b.created_at, 'America/Bogota')) AS fecha,
            b.g_adm_area_lv_1  AS ciudad,
            b.g_country,
            b.status_cd,
            b.payment_method_cd,
            toFloat64OrNull(JSONExtractString(b.final_cost,'cents')) / 100 AS monto,
            b.created_at
        FROM picapmongoprod.bookings b
        WHERE toString(b.payment_method_cd) = '3'
          AND b.status_cd IN (4, 107, 108)
          AND b.created_at >= toDateTime('%{desde} 00:00:00')
          AND b.created_at <= toDateTime('%{hasta} 23:59:59')
          %{filtro}
    )
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
