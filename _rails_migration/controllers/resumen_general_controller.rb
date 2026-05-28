# app/controllers/api/resumen_general_controller.rb
# Replica /api/resumen-general del api.py Python (líneas 8011-8068).
# Consolida KPIs de los 10 módulos en un solo endpoint, agrupados por área.
# Cada módulo se ejecuta dentro de un rescue aislado: si uno falla, los demás
# siguen y el módulo roto sólo registra su error.
#
# Query params:
#   - desde, hasta: rango de fecha (default últimos 30 días — heredado de App)
#   - pais:         ISO o nombre largo (CO, MX, NI, Colombia,...). Vacío = todos.
#   - modulos:      CSV opcional para limitar qué módulos calcular.
#                   Ej: modulos=evasion,estafa,bloqueos

module Api
  class ResumenGeneralController < ApplicationController
    before_action :authenticate_user!

    AREAS = {
      "evasion"       => { "area" => "monitoreo",   "nombre" => "Evasión de Comisión",        "icono" => "💰", "color" => "#1d4ed8", "ir_a" => "monitoreo" },
      "estafa"        => { "area" => "monitoreo",   "nombre" => "Servicios Estafa",           "icono" => "🚨", "color" => "#1d4ed8", "ir_a" => "estafa" },
      "pagos_tc"      => { "area" => "monitoreo",   "nombre" => "Pagos Tarjeta de Crédito",   "icono" => "💳", "color" => "#1d4ed8", "ir_a" => "pagos" },
      "pagos_promo"   => { "area" => "monitoreo",   "nombre" => "Pagos PromoCode",            "icono" => "🎟️", "color" => "#1d4ed8", "ir_a" => "pagos" },
      "facial"        => { "area" => "monitoreo",   "nombre" => "Reconocimiento Facial",      "icono" => "👤", "color" => "#1d4ed8", "ir_a" => "rf" },
      "bloqueos"      => { "area" => "sac_recl",    "nombre" => "Bloqueos y Reactivaciones",  "icono" => "🚫", "color" => "#7c3aed", "ir_a" => "bloqueos" },
      "auditoria_com" => { "area" => "comercial",   "nombre" => "Auditorías Comerciales",     "icono" => "📋", "color" => "#16a34a", "ir_a" => "auditoria" },
      "pibox"         => { "area" => "operaciones", "nombre" => "Auditorías Pibox B2B",       "icono" => "📦", "color" => "#ea580c", "ir_a" => "pibox-alertas" },
      "recaudos"      => { "area" => "operaciones", "nombre" => "Recaudos",                   "icono" => "💵", "color" => "#ea580c", "ir_a" => "recaudos" },
      "cedula"        => { "area" => "sac_act",     "nombre" => "Alertas de Cédula",          "icono" => "🪪", "color" => "#ca8a04", "ir_a" => "cedula" },
    }.freeze

    AREAS_META = {
      "monitoreo"   => { "nombre" => "Monitoreo",                "color" => "#1d4ed8", "icono" => "🔵" },
      "sac_recl"    => { "nombre" => "SAC / Reclamaciones",      "color" => "#7c3aed", "icono" => "🟣" },
      "comercial"   => { "nombre" => "Comercial",                "color" => "#16a34a", "icono" => "🟢" },
      "operaciones" => { "nombre" => "Operaciones",              "color" => "#ea580c", "icono" => "🟠" },
      "sac_act"     => { "nombre" => "SAC / Activaciones",       "color" => "#ca8a04", "icono" => "🟡" },
    }.freeze

    # GET /api/resumen-general
    def index
      desde     = desde_param
      hasta     = hasta_param
      pais_in   = pais_param
      pais_iso  = iso_pais
      seleccion = params[:modulos].to_s.strip
      modulos_pedidos = seleccion.empty? ? nil : seleccion.split(",").map(&:strip).reject(&:empty?).to_set

      modulos_out = {}
      AREAS.each do |mod_id, meta|
        next if modulos_pedidos && !modulos_pedidos.include?(mod_id)
        bloque = meta.merge("kpis" => [], "tip" => "", "error" => nil)
        begin
          datos = case mod_id
                  when "evasion"       then resumen_evasion(desde, hasta, pais_iso)
                  when "estafa"        then resumen_estafa(desde, hasta, pais_iso)
                  when "pagos_tc"      then resumen_pagos_tc(desde, hasta, pais_iso)
                  when "pagos_promo"   then resumen_pagos_promo(desde, hasta, pais_iso)
                  when "facial"        then resumen_facial(desde, hasta, pais_iso)
                  when "bloqueos"      then resumen_bloqueos(desde, hasta, pais_iso)
                  when "auditoria_com" then resumen_auditoria_com(desde, hasta, pais_iso)
                  when "pibox"         then resumen_pibox(desde, hasta, pais_iso)
                  when "recaudos"      then resumen_recaudos(desde, hasta, pais_iso)
                  when "cedula"        then resumen_cedula(desde, hasta, pais_iso)
                  end
          if datos
            bloque["kpis"] = datos[:kpis] || []
            bloque["tip"]  = datos[:tip].to_s
          end
        rescue => e
          bloque["error"] = e.message.to_s[0, 300]
          Rails.logger.warn("[ResumenGeneral##{mod_id}] #{e.class}: #{e.message}")
        end
        modulos_out[mod_id] = bloque
      end

      render json: limpiar({
        ok: true,
        filtros: { desde: desde, hasta: hasta, pais: pais_in, pais_iso: pais_iso },
        modulos: modulos_out,
        areas:   AREAS_META,
        generado_en: Time.now.utc.strftime("%Y-%m-%d %H:%M:%S"),
      })
    rescue => e
      Rails.logger.error("[ResumenGeneralController] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    # Helper para construir KPIs (replica _kpi() del Python)
    def kpi(label, valor, fmt = "numero", sub: nil, color: nil)
      { label: label, valor: valor, fmt: fmt, sub: sub, color: color }
    end

    # ── EVASIÓN ─────────────────────────────────────────────────────────
    # Reutiliza la CTE oficial (BASE_CTE + KPIS_SUFFIX) con filtro de país.
    def resumen_evasion(desde, hasta, pais_iso)
      cte = QueriesService.cte_con_pais(pais_iso)
      sql = QueriesService.format(cte + QueriesService::KPIS_SUFFIX,
                                  fecha_desde: desde, fecha_hasta: hasta)
      k = ch.query(sql).first
      return nil unless k
      total = k["total"].to_i
      conf  = k["confirmadas"].to_i
      prob  = k["probables"].to_i
      com   = k["comision_evadida"].to_i
      pt    = k["pilotos_auditados"].to_i
      pe    = k["pilotos_evadieron"].to_i
      tasa  = total > 0 ? ((conf + prob).to_f / total * 100).round(1) : 0
      {
        kpis: [
          kpi("Total servicios analizados", total, "numero"),
          kpi("Evasiones confirmadas",      conf,  "numero", color: "#dc2626"),
          kpi("Tasa de evasión",            tasa,  "porcentaje"),
          kpi("Comisión evadida (confirm.)",com,   "moneda"),
          kpi("Pilotos auditados",          pt,    "numero"),
          kpi("Pilotos con evasión",        pe,    "numero", color: "#dc2626"),
        ],
        tip: "Una evasión es 'confirmada' cuando hay 2 banderas simultáneas: tiempo > 5 min y distancia ≤ radio del país. La penalidad cobrada agrega 5% a la comisión evadida.",
      }
    end

    # ── ESTAFA ──────────────────────────────────────────────────────────
    def resumen_estafa(desde, hasta, pais_iso)
      extra = pais_iso.to_s.empty? ? "" : " AND b.g_country = '#{pais_iso}'"
      sql = <<~SQL
        SELECT
            count()                                                        AS total_serv,
            countIf(b.status_cd IN (100, 102))                             AS finalizados,
            countIf(toInt64OrZero(b.cancelation_reason_cd) IN (21, 13))    AS estafa_total,
            countIf(toInt64OrZero(b.cancelation_reason_cd) = 21)           AS estafa_pasajero,
            countIf(toInt64OrZero(b.cancelation_reason_cd) = 13)           AS estafa_sistema
        FROM picapmongoprod.bookings b
        WHERE b.created_at >= toDateTime('#{desde} 00:00:00')
          AND b.created_at <= toDateTime('#{hasta} 23:59:59')#{extra}
      SQL
      r = ch.query(sql).first || {}
      total = r["total_serv"].to_i
      fin   = r["finalizados"].to_i
      est   = r["estafa_total"].to_i
      est_p = r["estafa_pasajero"].to_i
      est_s = r["estafa_sistema"].to_i
      pct    = total > 0 ? (est.to_f / total * 100).round(2) : 0
      pct_p  = est   > 0 ? (est_p.to_f / est * 100).round(1) : 0
      pct_s  = est   > 0 ? (est_s.to_f / est * 100).round(1) : 0
      pct_ok = total > 0 ? (fin.to_f / total * 100).round(1) : 0
      {
        kpis: [
          kpi("Total servicios revisados", total, "numero"),
          kpi("Servicios finalizados OK",  fin,   "numero", sub: "#{pct_ok}% del total"),
          kpi("Estafa total",              est,   "numero", color: "#dc2626", sub: "#{pct}% del total"),
          kpi("• Estafa pasajero (cod 21)",est_p, "numero", color: "#dc2626", sub: "#{pct_p}% de estafas"),
          kpi("• Estafa sistema (cod 13)", est_s, "numero", color: "#dc2626", sub: "#{pct_s}% de estafas"),
        ],
        tip: "Cód 21: el pasajero declaró estafa. Cód 13: el sistema detectó patrón. Tasa de estafa esperada < 0,5%; si supera 1% conviene revisar zonas o pilotos concretos en el módulo Estafa.",
      }
    end

    # ── PAGOS TC ────────────────────────────────────────────────────────
    def resumen_pagos_tc(desde, hasta, pais_iso)
      extra = pais_iso.to_s.empty? ? "" : " AND b.g_country = '#{pais_iso}'"
      sql = <<~SQL
        SELECT
            count()                                                                AS total,
            round(sum(toInt64(JSONExtractFloat(b.final_cost, 'cents')) / 100), 0)  AS monto
        FROM picapmongoprod.bookings b
        WHERE b.payment_method_cd = '3'
          AND b.status_cd IN (4, 107, 108)
          AND b.created_at >= toDateTime('#{desde} 00:00:00')
          AND b.created_at <= toDateTime('#{hasta} 23:59:59')
          AND toInt64(JSONExtractFloat(b.final_cost,'cents')) > 0#{extra}
      SQL
      r = ch.query(sql).first || {}
      {
        kpis: [
          kpi("Servicios pagados con TC", r["total"].to_i, "numero"),
          kpi("Monto total facturado",    r["monto"].to_i, "moneda"),
        ],
        tip: "Servicios donde el pasajero pagó con tarjeta. Para detección de fraude (cancelados con cobro) abre el módulo Pagos → TC.",
      }
    end

    # ── PAGOS PROMO ─────────────────────────────────────────────────────
    def resumen_pagos_promo(desde, hasta, _pais_iso)
      sql = <<~SQL
        SELECT
            countDistinct(booking_id)                                                AS bookings,
            round(sum(abs(toFloat64OrNull(JSONExtractString(amount,'cents'))/100)),0) AS monto
        FROM picapmongoprod.wallet_account_transactions
        WHERE _type IN (
                'WalletAccountTransactionPromoCodeMultipleUse',
                'WalletAccountTransactionPromoCodeReferral',
                'WalletAccountTransactionExpirePromoBalance'
              )
          AND created_at >= toDateTime('#{desde} 00:00:00')
          AND created_at <= toDateTime('#{hasta} 23:59:59')
      SQL
      r = ch.query(sql).first || {}
      {
        kpis: [
          kpi("Servicios con promo aplicada", r["bookings"].to_i, "numero"),
          kpi("Descuento total otorgado",     r["monto"].to_i,    "moneda"),
        ],
        tip: "Cada redención es un código aplicado en un servicio. Picos repentinos pueden indicar abuso o filtración del código.",
      }
    end

    # ── FACIAL (RF) ─────────────────────────────────────────────────────
    # Replica la lógica del módulo /api/reconocimiento en modo Confianza Alta
    # con filtro de apellido coincidente.
    def resumen_facial(desde, hasta, _pais_iso)
      tok = ->(col) {
        "arrayFilter(tk -> length(tk) >= 3, " \
        "arrayMap(s -> lowerUTF8(s), splitByChar(' ', toString(#{col}))))"
      }
      apellido_ok = "(length(#{tok.call('nombre_a')}) > 0 " \
                    "AND length(#{tok.call('nombre_b')}) > 0 " \
                    "AND arrayCount(t -> has(#{tok.call('nombre_b')}, t), " \
                    "#{tok.call('nombre_a')}) > 0)"
      r = {}
      begin
        sql = <<~SQL
          SELECT
              count()                                                              AS total,
              countIf(
                  (toFloat64(similitud) >= 0.96 AND #{apellido_ok})
                  OR ifNull(mismo_imei,'NO') = 'SÍ'
              )                                                                    AS alerta,
              countIf(
                  toFloat64(similitud) >= 0.93 AND toFloat64(similitud) < 0.96
                  AND #{apellido_ok}
              )                                                                    AS revisar,
              countIf(
                  toFloat64(similitud) >= 0.85 AND toFloat64(similitud) < 0.93
                  AND #{apellido_ok}
              )                                                                    AS posible,
              round(maxIf(similitud, toFloat64(similitud) > 0), 4)                 AS sim_max,
              round(avgIf(similitud, toFloat64(similitud) > 0), 4)                 AS sim_avg
          FROM picapmongoprod.alertas_reconocimiento
          WHERE procesado_en >= toDateTime('#{desde} 00:00:00')
            AND procesado_en <= toDateTime('#{hasta} 23:59:59')
        SQL
        r = ch.query(sql).first || {}
      rescue => e
        Rails.logger.warn("[ResumenGeneral#facial] #{e.message}")
        r = {}
      end
      total   = r["total"].to_i
      alerta  = r["alerta"].to_i
      revisar = r["revisar"].to_i
      posible = r["posible"].to_i
      sim_max = r["sim_max"].to_f
      sim_avg = r["sim_avg"].to_f
      pct_a = total > 0 ? (alerta.to_f  / total * 100).round(3) : 0
      pct_r = total > 0 ? (revisar.to_f / total * 100).round(3) : 0
      pct_p = total > 0 ? (posible.to_f / total * 100).round(3) : 0
      {
        kpis: [
          kpi("Pares analizados",                          total,   "numero"),
          kpi("Alertas reales · Confianza alta (≥0.96)",   alerta,  "numero", color: "#dc2626", sub: "#{pct_a}% del total"),
          kpi("Para revisar · Equilibrado (0.93–0.96)",    revisar, "numero", color: "#ca8a04", sub: "#{pct_r}% del total"),
          kpi("Posibles · Auditoría (0.85–0.93)",          posible, "numero",                   sub: "#{pct_p}% del total"),
          kpi("Similitud máxima",                          sim_max, "decimal"),
          kpi("Similitud promedio",                        sim_avg, "decimal"),
        ],
        tip: "Cada categoría replica lo que ves al elegir ese modo en el módulo RF (con filtro de apellido activado). Los conteos cuadran con 'Alertas reales' del módulo. Si querés ver TODAS las comparaciones sin filtro, abrí el módulo Facial.",
      }
    end

    # ── BLOQUEOS ────────────────────────────────────────────────────────
    def resumen_bloqueos(desde, hasta, pais_iso)
      join_country = pais_iso.to_s.empty? ? "" : "AND p.g_country = '#{pais_iso}'"
      sql = <<~SQL
        WITH ds_periodo AS (
            SELECT driver_id AS uid, starts_at, ends_at, created_at, updated_at
            FROM picapmongoprod.driver_suspensions
            WHERE starts_at >= toDateTime('#{desde} 00:00:00')
              AND starts_at <= toDateTime('#{hasta} 23:59:59')
        ),
        ps_periodo AS (
            SELECT passenger_id AS uid, starts_at, ends_at, created_at, updated_at
            FROM picapmongoprod.passenger_suspensions
            WHERE starts_at >= toDateTime('#{desde} 00:00:00')
              AND starts_at <= toDateTime('#{hasta} 23:59:59')
        ),
        todos AS (
            SELECT * FROM ds_periodo
            UNION ALL
            SELECT * FROM ps_periodo
        )
        SELECT
            count()                                                                  AS total,
            countIf(t.ends_at IS NULL OR t.ends_at > now())                          AS activos,
            countIf(lower(ifNull(toString(p.expelled),'')) = 'true')                 AS expulsados,
            countIf(
                (lower(ifNull(toString(p.suspended),''))           = 'true'
                 OR lower(ifNull(toString(p.is_driver_suspended),'')) = 'true')
                AND dateDiff('day', t.starts_at, ifNull(t.ends_at, now())) > 30
            ) AS suspendidos_mas30
        FROM todos t
        LEFT JOIN picapmongoprod.passengers p ON p._id = t.uid #{join_country}
      SQL
      r = ch.query(sql).first || {}
      {
        kpis: [
          kpi("Bloqueos creados en el período", r["total"].to_i,            "numero"),
          kpi("Aún activos hoy",                r["activos"].to_i,          "numero", color: "#dc2626"),
          kpi("Expulsiones permanentes",        r["expulsados"].to_i,       "numero", color: "#dc2626"),
          kpi("Suspendidos > 30 días",          r["suspendidos_mas30"].to_i,"numero", color: "#ca8a04"),
        ],
        tip: "Suspendidos con más de 30 días son la prioridad: SAC debe contactarlos para definir reactivación o expulsión definitiva.",
      }
    end

    # ── AUDITORÍA COMERCIAL ─────────────────────────────────────────────
    def resumen_auditoria_com(desde, hasta, pais_iso)
      extra = pais_iso.to_s.empty? ? "" : " AND b.g_country = '#{pais_iso}'"
      sql = <<~SQL
        SELECT
            count()                                                                  AS total,
            countIf(b.events LIKE '%"event_cd":24%')                                  AS finalizados_ok,
            countIf(NOT (b.events LIKE '%"event_cd":24%'))                            AS sin_finalizar,
            round(sum(toFloat64OrNull(JSONExtractString(b.final_cost,'cents'))/100), 0) AS monto,
            uniqExact(b.company_id)                                                   AS empresas
        FROM picapmongoprod.bookings b
        WHERE b.created_at >= toDateTime('#{desde} 00:00:00')
          AND b.created_at <= toDateTime('#{hasta} 23:59:59')
          AND b.status_cd IN (4, 100, 102, 107, 108)
          AND b.company_id IS NOT NULL AND b.company_id != ''#{extra}
      SQL
      r = ch.query(sql).first || {}
      total   = r["total"].to_i
      ok      = r["finalizados_ok"].to_i
      sin_fin = r["sin_finalizar"].to_i
      pct_ok    = total > 0 ? (ok.to_f / total * 100).round(1) : 0
      pct_alert = total > 0 ? (sin_fin.to_f / total * 100).round(1) : 0
      {
        kpis: [
          kpi("Empresas auditadas",        r["empresas"].to_i, "numero"),
          kpi("Servicios B2B totales",     total, "numero"),
          kpi("Finalizados correctamente", ok,    "numero",                  sub: "#{pct_ok}% del total"),
          kpi("Alertas (sin finalizar)",   sin_fin,"numero", color: "#dc2626", sub: "#{pct_alert}% del total"),
          kpi("Monto facturado",           r["monto"].to_i, "moneda"),
        ],
        tip: "Las auditorías comerciales revisan que los servicios facturados cumplan tarifa y SLA. Las 'alertas' aquí son servicios sin evento de finalización registrado (event_cd 24). Detalle completo y tarifa por empresa en el módulo Auditorías.",
      }
    end

    # ── PIBOX B2B ───────────────────────────────────────────────────────
    def resumen_pibox(desde, hasta, pais_iso)
      extra = pais_iso.to_s.empty? ? "" : " AND b.g_country = '#{pais_iso}'"
      sql = <<~SQL
        WITH base AS (
            SELECT
                b._id,
                b.company_id,
                toFloat64OrNull(JSONExtractString(b.final_cost,'cents'))/100 AS monto,
                parseDateTimeBestEffortOrNull(
                    extract(COALESCE(b.events,''), 'event_cd":22.*?created_at":"([^"]+)')
                ) AS ev_recogido,
                parseDateTimeBestEffortOrNull(
                    extract(COALESCE(b.events,''), 'event_cd":24.*?created_at":"([^"]+)')
                ) AS ev_finalizado
            FROM picapmongoprod.bookings b
            WHERE b.created_at >= toDateTime('#{desde} 00:00:00')
              AND b.created_at <= toDateTime('#{hasta} 23:59:59')
              AND b.status_cd IN (4, 107, 108)
              AND b.company_id IS NOT NULL AND b.company_id != ''#{extra}
        )
        SELECT
            count() AS total,
            countIf(
                ev_recogido IS NOT NULL
                AND ev_finalizado IS NOT NULL
                AND dateDiff('minute', ev_recogido, ev_finalizado) < 5
            ) AS muy_cortos,
            countIf(ev_recogido IS NULL OR ev_finalizado IS NULL) AS sin_eventos,
            round(sum(monto), 0) AS monto_total
        FROM base
      SQL
      r = ch.query(sql).first || {}
      total   = r["total"].to_i
      cortos  = r["muy_cortos"].to_i
      sin_ev  = r["sin_eventos"].to_i
      medidos = total - sin_ev
      pct_cortos = medidos > 0 ? (cortos.to_f / medidos * 100).round(2) : 0
      pct_sin    = total   > 0 ? (sin_ev.to_f / total   * 100).round(2) : 0
      {
        kpis: [
          kpi("Servicios Pibox B2B totales",  total,   "numero"),
          kpi("Con tiempo medible",           medidos, "numero"),
          kpi("Anormalmente cortos (<5 min)", cortos,  "numero", color: "#dc2626", sub: "#{pct_cortos}% de los medibles"),
          kpi("Sin eventos completos",        sin_ev,  "numero", color: "#ca8a04", sub: "#{pct_sin}% del total"),
          kpi("Monto facturado",              r["monto_total"].to_i, "moneda"),
        ],
        tip: "Servicios menores a 5 minutos entre 'recogido' (event 22) y 'finalizado' (event 24) son señal de fraude (el piloto no recogió ni entregó realmente). Los 'sin eventos completos' deben revisarse aparte; el módulo Pibox valida con foto y GPS.",
      }
    end

    # ── RECAUDOS ────────────────────────────────────────────────────────
    def resumen_recaudos(desde, hasta, _pais_iso)
      sql = <<~SQL
        WITH agregado AS (
            SELECT
                booking_id,
                sumIf(toFloat64OrNull(JSONExtractString(amount,'cents'))/100,
                      toFloat64OrNull(JSONExtractString(amount,'cents')) < 0) AS suma_neg,
                sumIf(toFloat64OrNull(JSONExtractString(amount,'cents'))/100,
                      toFloat64OrNull(JSONExtractString(amount,'cents')) > 0) AS suma_pos,
                countIf(toFloat64OrNull(JSONExtractString(amount,'cents')) < 0) AS cnt_neg,
                countIf(toFloat64OrNull(JSONExtractString(amount,'cents')) > 0) AS cnt_pos,
                count() AS cnt_total
            FROM picapmongoprod.wallet_account_transactions
            WHERE _type = 'WalletAccountCounterDeliveryTransaction'
              AND created_at >= toDateTime('#{desde} 00:00:00')
              AND created_at <= toDateTime('#{hasta} 23:59:59')
            GROUP BY booking_id
        )
        SELECT
            count() AS total,
            countIf(cnt_pos > 0 AND cnt_neg > 0
                    AND abs(suma_pos + suma_neg) < 0.01
                    AND cnt_total > 2)                                              AS revisar,
            countIf(NOT (cnt_pos > 0 AND cnt_neg > 0
                         AND abs(suma_pos + suma_neg) < 0.01
                         AND cnt_total > 2)
                    AND (suma_pos + suma_neg) = 0)                                  AS correcto,
            countIf(NOT (cnt_pos > 0 AND cnt_neg > 0
                         AND abs(suma_pos + suma_neg) < 0.01
                         AND cnt_total > 2)
                    AND (suma_pos + suma_neg) > 0)                                  AS pagado_demas,
            countIf(NOT (cnt_pos > 0 AND cnt_neg > 0
                         AND abs(suma_pos + suma_neg) < 0.01
                         AND cnt_total > 2)
                    AND (suma_pos + suma_neg) < 0)                                  AS debe,
            round(sumIf(suma_pos + suma_neg, (suma_pos + suma_neg) > 0), 0)         AS valor_pagado_demas,
            round(sumIf(abs(suma_pos + suma_neg), (suma_pos + suma_neg) < 0), 0)    AS valor_debe
        FROM agregado
      SQL
      r = ch.query(sql).first || {}
      total   = r["total"].to_i
      rev     = r["revisar"].to_i
      ok      = r["correcto"].to_i
      demas   = r["pagado_demas"].to_i
      debe    = r["debe"].to_i
      v_demas = r["valor_pagado_demas"].to_i
      v_debe  = r["valor_debe"].to_i
      pct_ok    = total > 0 ? (ok.to_f    / total * 100).round(1) : 0
      pct_demas = total > 0 ? (demas.to_f / total * 100).round(1) : 0
      pct_debe  = total > 0 ? (debe.to_f  / total * 100).round(1) : 0
      pct_rev   = total > 0 ? (rev.to_f   / total * 100).round(1) : 0
      alertas   = demas + debe + rev
      pct_alert = total > 0 ? (alertas.to_f / total * 100).round(1) : 0
      fmt_money = ->(n) { "$#{n.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}" }
      {
        kpis: [
          kpi("Bookings auditados",           total,   "numero"),
          kpi("Correctos (balance = 0)",      ok,      "numero",                  sub: "#{pct_ok}% del total"),
          kpi("Total con alertas",            alertas, "numero", color: "#dc2626", sub: "#{pct_alert}% del total"),
          kpi("• Pagado de más (Picap debe)", demas,   "numero", color: "#ca8a04", sub: "#{pct_demas}% · #{fmt_money.call(v_demas)}"),
          kpi("• Debe dinero (piloto debe)",  debe,    "numero", color: "#dc2626", sub: "#{pct_debe}% · #{fmt_money.call(v_debe)}"),
          kpi("• Revisar manual",             rev,     "numero", color: "#ca8a04", sub: "#{pct_rev}% del total"),
        ],
        tip: "Cada booking con recaudo tiene transacciones positivas (recaudo del cliente) y negativas (abono al piloto). Si la suma neta es 0 está correcto; si > 0 Picap le debe al piloto, si < 0 el piloto debe pagar a Picap. Los 'Revisar' son casos atípicos con muchas transacciones.",
      }
    end

    # ── CÉDULA ──────────────────────────────────────────────────────────
    # Replica _Q_CEDULA_AGG: compara CC del Rekognition (foto) vs CC del
    # texto de antecedentes policiales. Si difieren → 'alerta'.
    def resumen_cedula(desde, hasta, pais_iso)
      filtro_pais = pais_iso.to_s.empty? ? "" : "AND p.g_country = '#{pais_iso}'"
      total = 0
      alertas = 0
      begin
        sql = <<~SQL
          SELECT
              toDate(creacion_cuenta)               AS dia,
              count()                               AS total_dia,
              countIf(cc_igual = 'alerta')          AS alertas_dia
          FROM (
              SELECT
                  toTimeZone(p.created_at, 'America/Bogota') AS creacion_cuenta,
                  CASE
                      WHEN JSONExtractString(pwd.rekognition_metadata, 'fiscal_number')
                         = extract(pwd.people_police_records, 'Cédula de Ciudadanía Nº\\s*([0-9]+)')
                      THEN 'ok' ELSE 'alerta'
                  END                                          AS cc_igual,
                  JSONExtractString(pwd.rekognition_metadata, 'fiscal_number') AS rk_cc,
                  extract(pwd.people_police_records, 'Cédula de Ciudadanía Nº\\s*([0-9]+)') AS pr_cc,
                  ROW_NUMBER() OVER (PARTITION BY p._id ORDER BY p.created_at DESC) AS rn
              FROM picapmongoprod.passengers_w_data pwd
              LEFT JOIN picapmongoprod.passengers p ON pwd._id = p._id
              WHERE p.created_at BETWEEN toDateTime('#{desde} 00:00:00')
                                     AND toDateTime('#{hasta} 23:59:59')
                #{filtro_pais}
          )
          WHERE rn = 1
            AND rk_cc != ''
            AND pr_cc != ''
          GROUP BY dia
          ORDER BY dia
        SQL
        rows = ch.query(sql)
        rows.each do |row|
          total   += row["total_dia"].to_i
          alertas += row["alertas_dia"].to_i
        end
      rescue => e
        Rails.logger.warn("[ResumenGeneral#cedula] #{e.message}")
      end
      ok     = [0, total - alertas].max
      pct_a  = total > 0 ? (alertas.to_f / total * 100).round(2) : 0
      pct_ok = total > 0 ? (ok.to_f      / total * 100).round(1) : 0
      {
        kpis: [
          kpi("Cuentas con cédula validada", total,   "numero"),
          kpi("Coinciden (foto = registro)", ok,      "numero",                  sub: "#{pct_ok}% del total"),
          kpi("Alertas (no coinciden)",      alertas, "numero", color: "#dc2626", sub: "#{pct_a}% del total"),
        ],
        tip: "Compara la cédula extraída con OCR de la foto vs la cédula registrada en antecedentes policiales. Una diferencia indica suplantación o cuenta falsa. SAC + Activaciones deben validar las alertas en menos de 24h.",
      }
    end

    public

    # POST /api/resumen-general/enviar_email — v3.3.21
    # Envía xlsx con el snapshot del Resumen 360 (todos los módulos consolidados).
    def enviar_email
      to_list  = BackgroundMailerHelper.parse_email_list(params[:email] || params[:to])
      cc_list  = BackgroundMailerHelper.parse_email_list(params[:cc])
      bcc_list = BackgroundMailerHelper.parse_email_list(params[:bcc])
      asunto   = params[:asunto].to_s.strip
      mensaje  = params[:mensaje].to_s.strip[0, 1000]
      desde    = desde_param
      hasta    = hasta_param
      pais     = pais_param
      pais_iso = iso_pais
      usuario  = current_usuario.to_s

      return render(json: { ok: false, error: "Tenés que ingresar al menos un destinatario en 'Para'." }, status: :bad_request) if to_list.empty?
      _v, invalids = BackgroundMailerHelper.split_validos(to_list + cc_list + bcc_list)
      return render(json: { ok: false, error: "Email(s) inválido(s): #{invalids.join(', ')}" }, status: :bad_request) if invalids.any?

      BackgroundMailerHelper.run("Resumen360") do
        xlsx = build_resumen_360_xlsx(desde, hasta, pais, pais_iso)
        filename = "Picap_Resumen360_#{desde}_#{hasta}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.xlsx"
        ResendMailerService.send_email(
          to: to_list, cc: cc_list, bcc: bcc_list,
          subject: asunto.empty? ? "Resumen 360 · #{desde} → #{hasta}" : asunto,
          html: html_email_resumen_360(desde, hasta, pais, mensaje, usuario),
          attachment_bytes: xlsx[:data], attachment_filename: filename,
        )
      end

      render json: { ok: true, queued: true, destinatarios: to_list, cc: cc_list, bcc: bcc_list,
                     mensaje: "Resumen 360 en proceso. El email con el xlsx llegará en unos minutos." }, status: :accepted
    rescue => e
      Rails.logger.error("[ResumenGeneralController#enviar_email] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    # Genera 1 hoja por módulo con los KPIs del resumen.
    def build_resumen_360_xlsx(desde, hasta, pais, pais_iso)
      modulos = AREAS.keys
      ExcelExportService.build("Picap_Resumen_360") do |x|
        x.add_sheet("Portada") do |s|
          s.banner("Resumen General 360°",
                   "Período: #{desde} → #{hasta}  ·  País: #{pais.to_s.empty? ? 'Todos' : pais}", 2)
          s.kpi_section("Información", [
            ["Período",  "#{desde} → #{hasta}"],
            ["País",     pais.to_s.empty? ? "Todos los países" : pais],
            ["Generado", Time.now.strftime("%Y-%m-%d %H:%M")],
            ["Módulos",  modulos.size.to_s],
            ["Nota",     "Cada hoja siguiente muestra los KPIs del módulo correspondiente."],
          ], ncols: 2)
          s.finalize
        end

        modulos.each do |mod_id|
          meta = AREAS[mod_id]
          bloque = begin
            datos = case mod_id
                    when "evasion"       then resumen_evasion(desde, hasta, pais_iso)
                    when "estafa"        then resumen_estafa(desde, hasta, pais_iso)
                    when "pagos_tc"      then resumen_pagos_tc(desde, hasta, pais_iso)
                    when "pagos_promo"   then resumen_pagos_promo(desde, hasta, pais_iso)
                    when "facial"        then resumen_facial(desde, hasta, pais_iso)
                    when "bloqueos"      then resumen_bloqueos(desde, hasta, pais_iso)
                    when "auditoria_com" then resumen_auditoria_com(desde, hasta, pais_iso)
                    when "pibox"         then resumen_pibox(desde, hasta, pais_iso)
                    when "recaudos"      then resumen_recaudos(desde, hasta, pais_iso)
                    when "cedula"        then resumen_cedula(desde, hasta, pais_iso)
                    end
            datos || { kpis: [], tip: "" }
          rescue => e
            Rails.logger.warn("[Resumen360##{mod_id}] #{e.message}")
            { kpis: [{ label: "Error", valor: e.message[0, 100] }], tip: "" }
          end

          x.add_sheet("#{meta['icono']} #{meta['nombre']}"[0, 28]) do |s|
            s.banner("#{meta['icono']} #{meta['nombre']}", "Período: #{desde} → #{hasta}", 2)
            s.kpi_section("KPIs", bloque[:kpis].map { |k| [k[:label], k[:valor]] }, ncols: 2)
            if bloque[:tip].to_s.strip.length > 0
              s.kpi_section("Tip", [["", bloque[:tip][0, 800]]], ncols: 2)
            end
            s.finalize
          end
        end
      end
    end

    def html_email_resumen_360(desde, hasta, pais, mensaje_usuario, usuario)
      msj_html = mensaje_usuario.to_s.empty? ? "" :
        %Q(<p style="background:#FFFBEB;border-left:4px solid #F59E0B;padding:12px 16px;margin:16px 0;border-radius:4px;color:#78350F"><strong>Mensaje:</strong> #{ERB::Util.h(mensaje_usuario)}</p>)
      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#F5F3FF;color:#1F2937">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F5F3FF;padding:20px 0"><tr><td align="center">
            <table cellpadding="0" cellspacing="0" border="0" width="640" style="background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
              <tr><td style="background:linear-gradient(90deg,#1d4ed8,#5b21b6);padding:24px 28px;color:#fff">
                <div style="font-size:22px;font-weight:700">📊 Resumen 360°</div>
                <div style="font-size:13px;opacity:0.92;margin-top:4px">Período: #{desde} → #{hasta} · País: #{pais.to_s.empty? ? 'Todos' : pais}</div>
              </td></tr>
              <tr><td style="padding:28px">
                <p style="margin:0 0 12px;font-size:14px">Hola,</p>
                <p style="margin:0 0 16px;font-size:14px;line-height:1.5">Te compartimos el reporte consolidado de los <strong>10 módulos</strong> del portal de monitoreo: Evasión, Estafa, Pagos TC, Pagos Promo, Facial, Bloqueos, Auditorías Comerciales, Pibox B2B, Recaudos y Cédula.</p>
                #{msj_html}
                <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">📎 Excel adjunto con 1 hoja por módulo. Detalle interactivo y filtros en <a href="https://monitoring.picap.io" style="color:#5b21b6">monitoring.picap.io</a> → Resumen 360°.</p>
              </td></tr>
              <tr><td style="background:#F9FAFB;padding:12px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                <strong style="color:#5b21b6">Picap Monitoreo</strong> · #{Time.now.strftime('%d/%m/%Y %H:%M')} · Por: #{ERB::Util.h(usuario)}
              </td></tr>
            </table>
          </td></tr></table>
        </body></html>
      HTML
    end
  end
end
