# app/controllers/api/pagos_controller.rb
# Replica los endpoints /api/pagos/{tc,promo} y /api/pagos_stats.
#
# Shape EXACTO que el frontend espera (visto en dashboard.html):
#   kpis:     { total, ok, mala_practica, fraude, monto_mp, monto_fraude, monto_total }
#   trend:    [{ fecha, ok, mala_practica, fraude }]
#   ciudades: [{ ciudad, pais, total, mala_practica, fraude }]
#   duo:      [{ driver_id, passenger_id, servicios, monto_total, n_fraude, n_mp }]
#
# IMPORTANTE: el frontend hace d.driver_id.slice(0,12) — necesita driver_id
# como string. Si devolvemos {id:...} el .slice() crashea.

module Api
  class PagosController < ApplicationController
    before_action :authenticate_user!

    # GET /api/pagos/tc?desde=&hasta=&pais=
    def tc
      render_pagos(:tc)
    end

    # GET /api/pagos/promo?desde=&hasta=&pais=
    def promo
      render_pagos(:promo)
    end

    # GET /api/pagos_stats?desde=&hasta=
    def stats
      sql = QueriesService.format(
        QueriesService::Q_PAGOS_STATS,
        desde: desde_param, hasta: hasta_param
      )
      rows = ch.query(sql)
      total  = rows.sum { |r| r["total_servicios"].to_i }
      monto  = rows.sum { |r| r["monto_total_cop"].to_f }
      render json: limpiar({
        ok: true,
        desde: desde_param, hasta: hasta_param,
        resumen: { total: total, monto: monto },
        por_pais_medio: rows,
      })
    rescue => e
      Rails.logger.error("[PagosController#stats] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def render_pagos(tipo)
      pais_iso = iso_pais
      filtro = pais_iso.present? ? " AND b.g_country = '#{pais_iso}'" : ""
      ciudad = params[:ciudad].to_s.strip
      filtro += " AND b.g_adm_area_lv_1 = '#{ciudad.gsub("'","''")}'" if ciudad.present?

      # Por ahora usamos status_cd como proxy. En Bloque C lo reemplazamos
      # con la lógica GPS-based del Python (mucho más precisa).
      base_filter = tipo == :promo \
        ? "b.payment_method_cd = 5 AND b.status_cd IN (4, 100, 102, 107, 108)" \
        : "toString(b.payment_method_cd) = '3' AND b.status_cd IN (4, 100, 102, 107, 108)"

      where_clause = <<~SQL.strip
        WHERE #{base_filter}
          AND b.created_at >= toDateTime('#{desde_param} 00:00:00')
          AND b.created_at <= toDateTime('#{hasta_param} 23:59:59')
          #{filtro}
      SQL

      # KPIs globales
      kpis_sql = <<~SQL
        SELECT
            count()                                                                        AS total,
            countIf(b.status_cd IN (4, 100, 102))                                          AS ok,
            countIf(b.status_cd = 107)                                                     AS mala_practica,
            countIf(b.status_cd = 108)                                                     AS fraude,
            round(sumIf(toFloat64OrNull(JSONExtractString(b.final_cost,'cents'))/100,
                        b.status_cd = 107), 0)                                             AS monto_mp,
            round(sumIf(toFloat64OrNull(JSONExtractString(b.final_cost,'cents'))/100,
                        b.status_cd = 108), 0)                                             AS monto_fraude,
            round(sum(toFloat64OrNull(JSONExtractString(b.final_cost,'cents'))/100), 0)    AS monto_total
        FROM picapmongoprod.bookings b
        #{where_clause}
      SQL

      # Tendencia por día
      trend_sql = <<~SQL
        SELECT
            toDate(toTimeZone(b.created_at, 'America/Bogota')) AS fecha,
            countIf(b.status_cd IN (4, 100, 102)) AS ok,
            countIf(b.status_cd = 107)            AS mala_practica,
            countIf(b.status_cd = 108)            AS fraude
        FROM picapmongoprod.bookings b
        #{where_clause}
        GROUP BY fecha ORDER BY fecha
      SQL

      # Por ciudad+país
      ciudades_sql = <<~SQL
        SELECT
            if(b.g_adm_area_lv_1='' OR b.g_adm_area_lv_1 IS NULL, 'Sin ciudad', b.g_adm_area_lv_1) AS ciudad,
            CASE
                WHEN b.g_country = 'CO' THEN 'Colombia'
                WHEN b.g_country = 'MX' THEN 'Mexico'
                WHEN b.g_country = 'NI' THEN 'Nicaragua'
                WHEN b.g_country = 'GT' THEN 'Guatemala'
                ELSE b.g_country
            END                                  AS pais,
            count()                              AS total,
            countIf(b.status_cd = 107)           AS mala_practica,
            countIf(b.status_cd = 108)           AS fraude
        FROM picapmongoprod.bookings b
        #{where_clause}
        GROUP BY ciudad, pais
        ORDER BY total DESC
        LIMIT 10
      SQL

      # Pares dúo (driver + pasajero recurrentes con anomalías)
      duo_sql = <<~SQL
        SELECT
            toString(b.driver_id)                                  AS driver_id,
            toString(b.passenger_id)                               AS passenger_id,
            count()                                                AS servicios,
            round(sum(toFloat64OrNull(JSONExtractString(b.final_cost,'cents'))/100), 0) AS monto_total,
            countIf(b.status_cd = 108)                             AS n_fraude,
            countIf(b.status_cd = 107)                             AS n_mp
        FROM picapmongoprod.bookings b
        #{where_clause}
          AND b.driver_id IS NOT NULL AND b.driver_id != ''
          AND b.passenger_id IS NOT NULL AND b.passenger_id != ''
          AND b.status_cd IN (107, 108)
        GROUP BY b.driver_id, b.passenger_id
        HAVING servicios >= 2
        ORDER BY servicios DESC, monto_total DESC
        LIMIT 20
      SQL

      k = ch.query(kpis_sql).first || {}

      render json: limpiar({
        ok: true,
        desde: desde_param, hasta: hasta_param,
        pais_filtro: pais_param,
        kpis: {
          total:         k["total"].to_i,
          ok:            k["ok"].to_i,
          mala_practica: k["mala_practica"].to_i,
          fraude:        k["fraude"].to_i,
          monto_mp:      k["monto_mp"].to_f,
          monto_fraude:  k["monto_fraude"].to_f,
          monto_total:   k["monto_total"].to_f,
        },
        trend: ch.query(trend_sql).map { |r|
          { fecha: r["fecha"].to_s, ok: r["ok"].to_i,
            mala_practica: r["mala_practica"].to_i, fraude: r["fraude"].to_i }
        },
        ciudades: ch.query(ciudades_sql).map { |r|
          { ciudad: r["ciudad"], pais: r["pais"],
            total: r["total"].to_i,
            mala_practica: r["mala_practica"].to_i,
            fraude: r["fraude"].to_i }
        },
        duo: ch.query(duo_sql).map { |r|
          { driver_id:    r["driver_id"].to_s,
            passenger_id: r["passenger_id"].to_s,
            servicios:    r["servicios"].to_i,
            monto_total:  r["monto_total"].to_f,
            n_fraude:     r["n_fraude"].to_i,
            n_mp:         r["n_mp"].to_i }
        },
      })
    rescue => e
      Rails.logger.error("[PagosController##{tipo}] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message, type: e.class.name },
             status: :internal_server_error
    end
  end
end
