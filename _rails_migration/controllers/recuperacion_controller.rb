# app/controllers/api/recuperacion_controller.rb
# Replica /api/recuperacion (api.py 736-827).
# Top 10 evasores confirmados (nivel=3) + estado de cobro en wallet por driver.
# Para cada top10 cruza Q_WALLET_BY_DRIVER y devuelve: penalidad esperada,
# cobrada en wallet, deuda, % recuperado, estado (AL DÍA / PARCIAL / SIN PAGO).

module Api
  class RecuperacionController < ApplicationController
    before_action :authenticate_user!

    # GET /api/recuperacion?desde=&hasta=&pais=
    def index
      desde = desde_param
      hasta = hasta_param
      iso   = iso_pais

      # 1) Top 10 evasores confirmados — BASE_CTE con filtro de país inyectado
      cte = QueriesService.cte_con_pais(iso)
      sql_top = QueriesService.format(cte + Q_TOP_SUFFIX, fecha_desde: desde, fecha_hasta: hasta)
      top_rows = ch.query(sql_top)

      if top_rows.empty?
        return render(json: {
          ok: true, top: [], resumen: {}, tendencia: [],
          desde: desde, hasta: hasta, pais: pais_param,
        })
      end

      # 2) Wallet por driver (los 10 ids)
      ids = top_rows.map { |r| "'#{r["id_driver"].to_s.gsub("'", "''")}'" }.join(",")
      wallet_rows = ch.query(QueriesService.format(
        QueriesService::Q_WALLET_BY_DRIVER,
        ids: ids, desde: desde, hasta: hasta
      ))
      wallet_map = wallet_rows.each_with_object({}) do |r, h|
        h[r["driver_id"].to_s] = {
          penalidad: r["penalidad_conf"].to_f,
          pagado:    r["pagado"].to_f,
          deuda:     r["deuda"].to_f,
        }
      end

      total_pen = 0.0
      total_pag = 0.0
      top_final = top_rows.map do |r|
        did       = r["id_driver"].to_s
        nombre    = r["nombre"].to_s.empty? ? "Sin nombre" : r["nombre"]
        conf      = r["conf"].to_i
        pen_top10 = r["penalidad_total"].to_f
        w         = wallet_map[did] || { penalidad: pen_top10, pagado: 0.0, deuda: pen_top10 }
        pen       = w[:penalidad] > 0 ? w[:penalidad] : pen_top10
        pag       = w[:pagado]
        deu       = w[:deuda]
        pct       = pen > 0 ? (pag / pen * 100).round(1) : 0
        total_pen += pen
        total_pag += pag
        estado = if deu <= 0 then "AL DÍA"
                 elsif pag > 0 then "PARCIAL"
                 else "SIN PAGO"
                 end
        {
          id: did, nombre: nombre, conf: conf,
          penalidad: pen.round, pagado: pag.round, deuda: deu.round,
          pct: pct, estado: estado,
        }
      end

      # 3) Tendencia diaria de cobros en wallet
      tend = ch.query(QueriesService.format(
        QueriesService::Q_RESUMEN_PERIODO, desde: desde, hasta: hasta
      )).map { |r| { dia: r["dia"].to_s, cobrado: r["cobrado_dia"].to_f } }

      pct_global = total_pen > 0 ? (total_pag / total_pen * 100).round(1) : 0
      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta, pais: pais_param,
        top: top_final,
        resumen: {
          total_penalidad: total_pen.round,
          total_pagado:    total_pag.round,
          total_deuda:     (total_pen - total_pag).round,
          pct_recuperado:  pct_global,
        },
        tendencia: tend,
      })
    rescue => e
      Rails.logger.error("[RecuperacionController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    # Sufijo de la query top10 (se concatena con BASE_CTE)
    Q_TOP_SUFFIX = <<~'SQL'
      SELECT
          id_driver,
          any(name_driver)                          AS nombre,
          countIf(nivel = 3)                        AS conf,
          round(sum(comision_mas_penalizacion), 0)  AS penalidad_total
      FROM clasificado
      WHERE nivel = 3
      GROUP BY id_driver
      ORDER BY conf DESC, penalidad_total DESC
      LIMIT 10
    SQL
  end
end
