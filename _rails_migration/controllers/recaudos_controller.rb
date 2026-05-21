# app/controllers/api/recaudos_controller.rb
# Validación de Recaudos v2 — Split en Picash | Ida y Vuelta.
# Una fila por booking, con detalle de piloto, comercio, moneda, valor servicio,
# recaudos +/-, recaudo_neto, clasificación (DEBE/AL DIA/PAGADO DE MAS/SIN RECAUDO).

module Api
  class RecaudosController < ApplicationController
    before_action :authenticate_user!

    # GET /api/recaudos?desde=&hasta=&pais=&company_id=&piloto_id=
    def index
      desde      = desde_param
      hasta      = hasta_param
      pais       = params[:pais].to_s.strip
      company_id = params[:company_id].to_s.strip
      piloto_id  = params[:piloto_id].to_s.strip

      esc = ->(v) { v.to_s.gsub("'", "''") }
      filtro_pais = pais.empty? ? "" : "AND b.g_country = '#{esc.(pais[0,2].upcase)}'"

      sql = QueriesService.format(
        QueriesService::Q_RECAUDOS_DETALLE,
        desde: desde, hasta: hasta,
        filtro_pais: filtro_pais,
        limit_filas: 20_000,
      )
      rows = ch.query(sql, timeout: 300)

      # Normalizar tipos + búsqueda opcional por company_id / piloto_id
      rows = rows.map { |r| normalizar(r) }
      if company_id.length >= 4
        cid_low = company_id.downcase
        rows = rows.select { |r| r["company_id"].to_s.downcase.include?(cid_low) }
      end
      if piloto_id.length >= 4
        pid_low = piloto_id.downcase
        rows = rows.select { |r| r["driver_id"].to_s.downcase.include?(pid_low) }
      end

      # Split por tipo_deuda
      picash      = rows.select { |r| r["tipo_deuda"] == "PICASH" }
      idayvuelta  = rows.select { |r| r["tipo_deuda"] == "IDA Y VUELTA" }

      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta, pais: pais,
        picash:        { stats: calc_stats(picash),     filas: picash.first(5000) },
        ida_y_vuelta:  { stats: calc_stats(idayvuelta), filas: idayvuelta.first(5000) },
      })
    rescue => e
      Rails.logger.error("[RecaudosController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def normalizar(r)
      {
        "driver_id"            => r["driver_id"].to_s,
        "booking_id"           => r["booking_id"].to_s,
        "company_id"           => r["company_id"].to_s,
        "nombre_piloto"        => r["nombre_piloto"].to_s,
        "comercio"             => r["comercio"].to_s,
        "fecha_servicio"       => r["fecha_servicio"].to_s[0, 19],
        "pais"                 => r["pais"].to_s,
        "ciudad"               => r["ciudad"].to_s,
        "moneda"               => r["moneda"].to_s,
        "valor_servicio"       => r["valor_servicio"].to_f.round(2),
        "total_positivo"       => r["total_positivo"].to_f.round(2),
        "total_negativo"       => r["total_negativo"].to_f.round(2),
        "recaudo_neto"         => r["recaudo_neto"].to_f.round(2),
        "n_recaudos"           => r["n_recaudos"].to_i,
        "n_recaudos_positivos" => r["n_recaudos_positivos"].to_i,
        "n_recaudos_negativos" => r["n_recaudos_negativos"].to_i,
        "ida_y_vuelta"         => r["ida_y_vuelta"].to_s,
        "debe"                 => r["debe"].to_s,
        "tipo_deuda"           => r["tipo_deuda"].to_s,
      }
    end

    def calc_stats(rows)
      total       = rows.size
      n_debe      = rows.count { |r| r["debe"] == "DEBE" }
      n_demas     = rows.count { |r| r["debe"] == "PAGADO DE MAS" }
      n_al_dia    = rows.count { |r| r["debe"] == "AL DIA" }
      n_sin       = rows.count { |r| r["debe"] == "SIN RECAUDO" }
      v_deuda     = rows.select { |r| r["debe"] == "DEBE" }.sum { |r| r["recaudo_neto"].abs }
      v_demas     = rows.select { |r| r["debe"] == "PAGADO DE MAS" }.sum { |r| r["recaudo_neto"] }
      v_recaudado = rows.sum { |r| r["total_positivo"] }
      v_servicios = rows.sum { |r| r["valor_servicio"] }
      moneda_top  = rows.group_by { |r| r["moneda"] }.max_by { |_, v| v.size }&.first || ""

      {
        total:        total,
        moneda:       moneda_top,
        debe:         n_debe,
        pagado_demas: n_demas,
        al_dia:       n_al_dia,
        sin_recaudo:  n_sin,
        v_deuda:      v_deuda.round(2),
        v_demas:      v_demas.round(2),
        v_recaudado:  v_recaudado.round(2),
        v_servicios:  v_servicios.round(2),
        pct_debe:     total > 0 ? (n_debe.to_f    / total * 100).round(1) : 0,
        pct_al_dia:   total > 0 ? (n_al_dia.to_f  / total * 100).round(1) : 0,
        pct_demas:    total > 0 ? (n_demas.to_f   / total * 100).round(1) : 0,
        pct_sin:      total > 0 ? (n_sin.to_f     / total * 100).round(1) : 0,
      }
    end
  end
end
