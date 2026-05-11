# app/controllers/api/wallet_controller.rb
# Replica el endpoint /api/wallet del api.py Python.
# Usa wallet_account_transactions tipo WalletAccountTransactionFraudCommission
# (NO usar wallet_accounts.balance_cents — esa columna no existe en CH).
module Api
  class WalletController < ApplicationController
    before_action :authenticate_user!

    # GET /api/wallet?desde=&hasta=&pais=
    def index
      iso = iso_pais  # CO, MX, NI, GT o ""
      # Filtro extra para inyectar en la query (igual que Python)
      filtro_pais = iso.present? ? " AND b.g_country = '#{iso}'" : ""

      sql = QueriesService.format(
        QueriesService::Q_WALLET,
        fecha_desde: desde_param,
        fecha_hasta: hasta_param,
        filtro_pais: filtro_pais
      )
      kpis = ch.query(sql).first || {}

      # Top conductores en deuda — reutiliza Q_WALLET_BY_DRIVER del Python.
      # Sacamos primero los IDs de los top evasores que tienen mayor deuda.
      top_ids = ch.query(<<~SQL).map { |r| r["driver_id"] }
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
                toFloat64OrNull(JSONExtractString(b.estimated_cost,'cents')) / 100 AS costo,
                dateDiff('minute',
                    parseDateTimeBestEffortOrNull(extract(ifNull(b.events,''), 'event_cd":20.*?created_at":"([^"]+)')),
                    parseDateTimeBestEffortOrNull(extract(ifNull(b.events,''), 'event_cd":26.*?created_at":"([^"]+)'))
                ) AS minutos,
                geoDistance(
                    toFloat64OrNull(extract(ifNull(b.events,''), 'event_cd":26.*?coordinates":\\[\\s*([+-]?\\d+\\.\\d+)')),
                    toFloat64OrNull(extract(ifNull(b.events,''), 'event_cd":26.*?coordinates":\\[.*?,\\s*([+-]?\\d+\\.\\d+)')),
                    toFloat64(JSONExtractString(b.end_geojson,'coordinates',1)),
                    toFloat64(JSONExtractString(b.end_geojson,'coordinates',2))
                ) AS distancia
            FROM picapmongoprod.bookings b
            WHERE b.status_cd IN (100, 102)
              AND b.g_country IN ('CO','MX','NI','GT')#{filtro_pais}
              AND b.created_at >= toDateTime('#{desde_param} 00:00:00')
              AND b.created_at <= toDateTime('#{hasta_param} 23:59:59')
              AND NOT empty(b.origin_geojson)
              AND NOT empty(b.end_geojson)
        )
        SELECT driver_id, count() AS n
        FROM evasores
        WHERE minutos > 5
          AND multiIf(pais='Colombia', distancia <= 450,
                      pais IN ('Mexico','Nicaragua'), distancia <= 280,
                      distancia <= 450)
        GROUP BY driver_id
        ORDER BY n DESC
        LIMIT 10
      SQL

      top_deuda = []
      if top_ids.any?
        ids_csv = top_ids.map { |x| "'#{x}'" }.join(",")
        rows = ch.query(QueriesService.format(QueriesService::Q_WALLET_BY_DRIVER,
          ids: ids_csv, desde: desde_param, hasta: hasta_param))
        # Nombres
        nombres = ch.query(
          "SELECT _id, name FROM picapmongoprod.passengers FINAL WHERE _id IN (#{ids_csv})"
        ).each_with_object({}) { |r, h| h[r["_id"]] = r["name"] }

        top_deuda = rows.map do |r|
          {
            id:         r["driver_id"],
            nombre:     nombres[r["driver_id"]] || "Sin nombre",
            penalidad:  r["penalidad_conf"].to_f,
            pagado:     r["pagado"].to_f,
            deuda:      r["deuda"].to_f,
            estado:     r["deuda"].to_f <= 0 ? "AL DÍA" :
                        r["pagado"].to_f > 0 ? "DEUDA PARCIAL" : "SIN PAGO",
          }
        end.sort_by { |x| -x[:deuda] }
      end

      render json: limpiar({
        ok: true,
        desde: desde_param, hasta: hasta_param,
        pais_filtro: pais_param,
        kpis: {
          total_conductores:        kpis["total_conductores"].to_i,
          conductores_pagaron:      kpis["conductores_pagaron"].to_i,
          conductores_no_pagaron:   kpis["conductores_no_pagaron"].to_i,
          deuda_parcial:            kpis["deuda_parcial"].to_i,
          deuda_total:              kpis["deuda_total"].to_i,
          comision_esperada:        kpis["comision_esperada"].to_f,
          cobrado_wallet:           kpis["cobrado_wallet"].to_f,
          brecha_no_cobrada:        kpis["brecha_no_cobrada"].to_f,
          monto_pagado:             kpis["monto_pagado"].to_f,
          monto_cobrado_en_negativo:kpis["monto_cobrado_en_negativo"].to_f,
          monto_pendiente:          kpis["monto_pendiente"].to_f,
          pct_recuperado:           kpis["pct_recuperado"].to_f,
        },
        top_deuda: top_deuda,
      })
    rescue => e
      Rails.logger.error("[WalletController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message, type: e.class.name },
             status: :internal_server_error
    end
  end
end
