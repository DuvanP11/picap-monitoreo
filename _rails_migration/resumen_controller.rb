# app/controllers/api/resumen_controller.rb
# Replica cargar_datos() + endpoint /api/resumen del api.py Python (líneas 438-676)
module Api
  class ResumenController < ApplicationController
    before_action :authenticate_user!

    # GET /api/resumen?desde=YYYY-MM-DD&hasta=YYYY-MM-DD&pais=Colombia
    def index
      desde  = desde_param
      hasta  = hasta_param
      pais   = pais_param
      iso    = iso_pais  # ej: "CO", "MX", "" (vacío = todos)
      moneda = params[:moneda].to_s.strip
      tasa   = QueriesService.tasa_para(pais)

      # Construir CTE con filtro de país inyectado (replica .replace() del Python)
      cte = QueriesService.cte_con_pais(iso, moneda)

      # Componer las 4 queries y formatear con fechas
      q_kpis     = QueriesService.format(cte + QueriesService::KPIS_SUFFIX,        fecha_desde: desde, fecha_hasta: hasta)
      q_tend     = QueriesService.format(cte + QueriesService::TENDENCIA_SUFFIX,   fecha_desde: desde, fecha_hasta: hasta)
      q_ciudad   = QueriesService.format(cte + QueriesService::CIUDADES_SUFFIX,    fecha_desde: desde, fecha_hasta: hasta)
      q_drivers  = QueriesService.format(cte + QueriesService::TOP_DRIVERS_SUFFIX, fecha_desde: desde, fecha_hasta: hasta)

      k = (ch.query(q_kpis).first || {})
      t =  ch.query(q_tend)
      c =  ch.query(q_ciudad)
      d =  ch.query(q_drivers)

      total       = k["total"].to_i
      conf        = k["confirmadas"].to_i
      prob        = k["probables"].to_i
      tasa_evas   = total > 0 ? ((conf + prob).to_f / total * 100).round(1) : 0

      payload = {
        ok: true,
        loading: false,
        stale: false,
        cache_desde: desde,
        cache_hasta: hasta,
        updated_at: Time.now.iso8601,
        kpis: {
          total:                    total,
          confirmadas:              conf,
          probables:                prob,
          ok:                       k["ok"].to_i,
          tasa_evasion:             tasa_evas,
          comision_evadida_cop:     k["comision_evadida"].to_i,
          penalizacion_evadida_cop: k["penalizacion_evadida"].to_i,
          sin_gps:                  k["sin_gps"].to_i,
          tasa_comision_pct:        (tasa * 100).round,
          pais_filtro:              pais,
          moneda_filtro:            moneda,
          pilotos_auditados:        k["pilotos_auditados"].to_i,
          pilotos_evadieron:        k["pilotos_evadieron"].to_i,
        },
        operativo: {
          prom_minutos_evasion:   k["prom_minutos"].to_f,
          prom_distancia_evasion: k["prom_distancia"].to_f,
        },
        funnel: {
          total:          total,
          flag_tiempo:    k["flag_tiempo"].to_i,
          flag_distancia: k["flag_distancia"].to_i,
          confirmadas:    conf,
        },
        tendencia: t.map { |r|
          { fecha: r["fecha"].to_s[0,10], conf: r["conf"].to_i, prob: r["prob"].to_i, ok: r["ok"].to_i }
        },
        ciudades: c.map { |r|
          { ciudad: r["ciudad"], count: r["evasiones"].to_i }
        },
        top_drivers: d.map { |r|
          {
            id:           r["id_driver"],
            nombre:       (r["nombre"] && !r["nombre"].to_s.empty?) ? r["nombre"] : "Sin nombre",
            conf:         r["conf"].to_i,
            prob:         r["prob"].to_i,
            total:        r["total"].to_i,
            conf_primera: r["conf_primera"].to_i,
            conf_segunda: r["conf_segunda"].to_i,
          }
        },
      }

      render json: limpiar(payload)
    rescue => e
      Rails.logger.error("[ResumenController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message, type: e.class.name }, status: :internal_server_error
    end
  end
end
