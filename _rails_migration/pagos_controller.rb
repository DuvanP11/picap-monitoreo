# app/controllers/api/pagos_controller.rb
# Replica /api/pagos/{tc,promo} con clasificación GPS-based (api.py 3066-3302):
#   OK             → driver recibió pago wallet (pd.pagado > 0)
#   Mala práctica  → pagado=0 AND geoDistance(cancel → dest) ≤ radio país
#   Fraude         → pagado=0 AND (sin GPS OR geoDistance > radio)
# Radio: CO 450m | MX/NI 280m | resto 450m
#
# Shape EXACTO que el frontend espera:
#   kpis:     { total, ok, mala_practica, fraude, monto_mp, monto_fraude, monto_total }
#   trend:    [{ fecha, ok, mala_practica, fraude }]
#   ciudades: [{ ciudad, pais, total, mala_practica, fraude }]
#   duo:      [{ driver_id, passenger_id, servicios, monto_total, n_fraude, n_mp }]

module Api
  class PagosController < ApplicationController
    before_action :authenticate_user!

    # GET /api/pagos/tc?desde=&hasta=&pais=&ciudad=
    def tc
      render_pagos(:tc)
    end

    # GET /api/pagos/promo?desde=&hasta=&pais=&ciudad=
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
      desde    = desde_param
      hasta    = hasta_param
      pais_iso = iso_pais
      ciudad   = params[:ciudad].to_s.strip
      filtro   = QueriesService.pagos_filtro(pais_iso, ciudad)

      queries = if tipo == :tc
        {
          kpis:     QueriesService::Q_TC_KPIS,
          trend:    QueriesService::Q_TC_TREND,
          ciudades: QueriesService::Q_TC_CIUDADES,
          duo:      QueriesService::Q_TC_DUO,
        }
      else
        {
          kpis:     QueriesService::Q_PROMO_KPIS,
          trend:    QueriesService::Q_PROMO_TREND,
          ciudades: QueriesService::Q_PROMO_CIUDADES,
          duo:      QueriesService::Q_PROMO_DUO,
        }
      end

      # Ejecuta cada query con rescue aislado — si una rompe, el panel sigue
      data = {}
      queries.each do |key, sql_tpl|
        begin
          sql = QueriesService.format(sql_tpl, desde: desde, hasta: hasta, filtro: filtro)
          data[key] = ch.query(sql)
        rescue => e
          Rails.logger.warn("[PagosController##{tipo}/#{key}] #{e.message[0,200]}")
          data[key] = []
        end
      end

      kpi_row = data[:kpis].first || {}

      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta,
        pais_filtro: pais_param,
        kpis: {
          total:         kpi_row["total"].to_i,
          ok:            kpi_row["ok"].to_i,
          mala_practica: kpi_row["mala_practica"].to_i,
          fraude:        kpi_row["fraude"].to_i,
          monto_mp:      kpi_row["monto_mp"].to_f,
          monto_fraude:  kpi_row["monto_fraude"].to_f,
          monto_total:   kpi_row["monto_total"].to_f,
        },
        trend: data[:trend].map { |r|
          { fecha:         r["fecha"].to_s[0, 10],
            ok:            r["ok"].to_i,
            mala_practica: r["mala_practica"].to_i,
            fraude:        r["fraude"].to_i }
        },
        ciudades: data[:ciudades].map { |r|
          { ciudad:        r["ciudad"].to_s,
            pais:          r["pais"].to_s,
            total:         r["total"].to_i,
            mala_practica: r["mala_practica"].to_i,
            fraude:        r["fraude"].to_i }
        },
        duo: data[:duo].map { |r|
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
