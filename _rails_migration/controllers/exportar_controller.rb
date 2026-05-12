# app/controllers/api/exportar_controller.rb
# Exportaciones Excel para los 5 módulos principales (Bloque H).
# Cédula, Auditoría, Pibox y Audit-logs quedan como stubs (Bloque H.2).

module Api
  class ExportarController < ApplicationController
    before_action :authenticate_user!

    # GET /api/exportar/evasion?desde=&hasta=&pais=
    def evasion
      desde, hasta, pais = desde_param, hasta_param, pais_param
      iso = iso_pais

      cte = QueriesService.cte_con_pais(iso)
      # KPIs
      k = ch.query(QueriesService.format(cte + QueriesService::KPIS_SUFFIX,
                                          fecha_desde: desde, fecha_hasta: hasta)).first || {}
      # Detalle (hasta 5000 filas)
      sql_det = QueriesService.format(cte + DETALLE_SUFFIX_EVASION,
                                       fecha_desde: desde, fecha_hasta: hasta)
      rows = ch.query(sql_det, timeout: 300)

      xlsx = ExcelExportService.build("Picap_Evasion_Comisiones") do |x|
        # Hoja 1 — Resumen
        x.add_sheet("Resumen Ejecutivo") do |s|
          s.banner("Evasión de Comisiones — #{pais.empty? ? 'Todos los países' : pais}",
                   "Período: #{desde} → #{hasta}", 4)
          total = k["total"].to_i; conf = k["confirmadas"].to_i; prob = k["probables"].to_i
          tasa  = total > 0 ? ((conf + prob).to_f / total * 100).round(1) : 0
          s.kpi_section("Métricas generales", [
            ["Total servicios auditados",       total],
            ["Evasión confirmada (nivel 3)",    conf],
            ["Evasión probable (nivel 2)",      prob],
            ["OK — Sin evasión",                k["ok"].to_i],
            ["Sin GPS",                         k["sin_gps"].to_i],
            ["Tasa de evasión (%)",             "#{tasa}%"],
            ["Comisión evadida estimada (COP)", k["comision_evadida"].to_i],
            ["Penalización evadida (COP)",      k["penalizacion_evadida"].to_i],
          ], ncols: 2)
          s.finalize
        end

        # Hoja 2 — Detalle servicio por servicio
        x.add_sheet("Detalle", tab_color: ExcelExportService::COLORS[:purple]) do |s|
          s.banner("Detalle de Servicios — Evasión",
                   "Período: #{desde} → #{hasta}  ·  Registros: #{rows.size}", 16)
          s.headers([
            "Fecha", "Booking ID", "Driver ID", "Conductor",
            "Empresa", "Tipo servicio", "Moneda", "País", "Ciudad",
            "Costo Est.", "Min entre eventos", "Distancia (m)",
            "Veredicto", "Nivel", "Comisión svc", "Comisión + Pen.",
          ])
          rows.each do |r|
            nivel = r["nivel"].to_i
            veredicto = nivel == 3 ? "EVASION CONFIRMADA" : nivel == 2 ? "EVASION PROBABLE" : "OK"
            s.data_row([
              r["creacion_servicio"].to_s[0, 16],
              r["booking_id"].to_s,
              r["id_driver"].to_s,
              r["name_driver"].to_s,
              r["id_company"].to_s,
              r["type_service"].to_s,
              r["moneda"].to_s,
              r["pais"].to_s,
              r["ciudad"].to_s,
              r["costo_estimado"].to_f.round(2),
              r["minutos_entre_eventos"].to_i,
              r["distancia_cancel_destino"].to_f.round(1),
              veredicto,
              nivel,
              r["comision_servicio"].to_f.round(2),
              r["comision_mas_penalizacion"].to_f.round(2),
            ], right_align: [10, 11, 12, 14, 15, 16])
          end
          s.finalize(freeze_row: 4)
        end
      end

      send_xlsx(xlsx)
    rescue => e
      handle_error(e, "evasion")
    end

    # GET /api/exportar/estafa?desde=&hasta=&pais=
    def estafa
      desde, hasta, pais = desde_param, hasta_param, pais_param
      iso = iso_pais
      filtro_pais = iso.to_s.empty? ? "" : "AND b.g_country = '#{iso}'"

      sql = QueriesService.format(
        QueriesService::Q_ESTAFA_BASE,
        desde: desde, hasta: hasta,
        filtro_pais: filtro_pais,
        kws_estafa:  EstafaController::KW_ESTAFA_SQL,
        limit_filas: 20_000,
      )
      rows_raw = ch.query(sql, timeout: 300)
      seen = {}
      rows_raw.each { |r| seen[r["booking_id"]] ||= r }
      rows = seen.values

      n_estafa = 0
      enriched = rows.map do |r|
        ind = r["indications"].to_s.downcase
        hits = EstafaController::KW_ESTAFA.select { |kw| ind.include?(kw) }
        cls  = hits.empty? ? "OK" : "ESTAFA"
        n_estafa += 1 if cls == "ESTAFA"
        r.merge("clasificacion" => cls, "palabras" => hits.first(10))
      end
      total = enriched.size

      xlsx = ExcelExportService.build("Picap_Estafa") do |x|
        x.add_sheet("Estadística") do |s|
          s.banner("Servicios Estafa — Estadística",
                   "Período: #{desde} → #{hasta}  ·  País: #{pais.empty? ? 'Todos' : pais}", 3)
          s.kpi_section("Resumen de clasificación", [
            ["Total servicios analizados", total],
            ["Estafa confirmada",          n_estafa],
            ["OK — Sin indicadores",       total - n_estafa],
            ["% Estafa",                   total > 0 ? "#{(n_estafa.to_f / total * 100).round(1)}%" : "0%"],
          ], ncols: 2)
          s.finalize
        end

        x.add_sheet("Detalle") do |s|
          s.banner("Detalle de Servicios — Estafa",
                   "Período: #{desde} → #{hasta}  ·  Registros: #{total}", 11)
          s.headers([
            "Fecha", "Booking ID", "Driver ID", "User ID", "Usuario",
            "País", "Ciudad", "Razón cancelación", "Clasificación",
            "Palabras detectadas", "Indications (resumen)",
          ])
          enriched.each do |r|
            s.data_row([
              r["fecha_servicio"].to_s[0, 16],
              r["booking_id"].to_s,
              r["driver_id"].to_s,
              r["user_id"].to_s,
              r["name_user"].to_s,
              r["pais"].to_s,
              r["city"].to_s,
              r["cancelation_reason"].to_s,
              r["clasificacion"],
              r["palabras"].join(", "),
              r["indications"].to_s[0, 500],
            ])
          end
          s.finalize(freeze_row: 4)
        end
      end

      send_xlsx(xlsx)
    rescue => e
      handle_error(e, "estafa")
    end

    # GET /api/exportar/bloqueos?desde=&hasta=
    def bloqueos
      desde, hasta = desde_param, hasta_param
      rows = ch.query(QueriesService.format(QueriesService::Q_BLOQUEOS,
                                             fecha_desde: desde, fecha_hasta: hasta), timeout: 300)

      # Enrich con país + motivo + veredicto (igual que bloqueos_controller)
      rows = rows.map do |r|
        r["pais_nombre"] = MotivoMapper::PAISES_MAP[r["pais_codigo"]] || r["pais_codigo"]
        r["motivo_mapeado"] = MotivoMapper.mapear_segun_tipo(
          r["tipo_usuario"],
          comentario_driver: r["comentario_driver"],
          comentario_user:   r["comentario_user"],
          comentario_expulsion_user: r["comentario_expulsion_user"],
        )
        dias = r["dias_bloqueado_total"].to_i
        tipo_blq = r["tipo_bloqueo"].to_s
        if tipo_blq == "EXPULSADO"
          r["veredicto"] = "EXPULSIÓN PERMANENTE"
        else
          r["veredicto"] = dias > 30 ? "ALERTA DE TIEMPO" : "TODO OK"
        end
        r
      end

      xlsx = ExcelExportService.build("Picap_Bloqueos") do |x|
        x.add_sheet("Detalle") do |s|
          s.banner("Vista de Bloqueos — Detalle",
                   "Período: #{desde} → #{hasta}  ·  Registros: #{rows.size}", 14)
          s.headers([
            "Fecha", "ID Usuario", "Nombre", "Tipo Usuario", "País", "Ciudad",
            "Tipo Bloqueo", "Veredicto", "Días bloqueado", "Motivo",
            "Comentario driver", "Comentario user", "Expulsado", "Activo",
          ])
          rows.each do |r|
            s.data_row([
              r["fecha_bloqueo"].to_s,
              r["id_usuario"].to_s,
              r["nombre"].to_s,
              r["tipo_usuario"].to_s,
              r["pais_nombre"].to_s,
              r["ciudad"].to_s,
              r["tipo_bloqueo"].to_s,
              r["veredicto"].to_s,
              r["dias_bloqueado_total"].to_i,
              r["motivo_mapeado"].to_s,
              r["comentario_driver"].to_s[0, 300],
              r["comentario_user"].to_s[0, 300],
              r["expulsado"].to_s,
              r["esta_activo"].to_s,
            ], right_align: [9])
          end
          s.finalize(freeze_row: 4)
        end
      end

      send_xlsx(xlsx)
    rescue => e
      handle_error(e, "bloqueos")
    end

    # GET /api/exportar/pagos?desde=&hasta=&pais=&tipo=tc|promo
    def pagos
      desde, hasta = desde_param, hasta_param
      pais_iso = iso_pais
      ciudad   = params[:ciudad].to_s.strip
      tipo     = params[:tipo].to_s == "promo" ? :promo : :tc
      filtro   = QueriesService.pagos_filtro(pais_iso, ciudad)

      cte = tipo == :promo ? QueriesService::PROMO_BASE_CTE : QueriesService::TC_BASE_CTE
      # Trae las 4 datasets para el report
      kpis_sql  = QueriesService.format(cte + QueriesService::KPIS_SUFFIX_PAGOS,     desde: desde, hasta: hasta, filtro: filtro)
      trend_sql = QueriesService.format(cte + QueriesService::TREND_SUFFIX_PAGOS,    desde: desde, hasta: hasta, filtro: filtro)
      duo_sql   = QueriesService.format(cte + QueriesService::DUO_SUFFIX_PAGOS,      desde: desde, hasta: hasta, filtro: filtro)
      cd_sql    = QueriesService.format(cte + QueriesService::CIUDADES_SUFFIX_PAGOS, desde: desde, hasta: hasta, filtro: filtro)

      k     = ch.query(kpis_sql,  timeout: 300).first || {}
      trend = ch.query(trend_sql, timeout: 300)
      duo   = ch.query(duo_sql,   timeout: 300)
      cd    = ch.query(cd_sql,    timeout: 300)

      label = tipo == :promo ? "PromoCode" : "Tarjeta Crédito"
      xlsx = ExcelExportService.build("Picap_Pagos_#{tipo}") do |x|
        x.add_sheet("Resumen") do |s|
          s.banner("Pagos #{label} — Resumen", "Período: #{desde} → #{hasta}", 4)
          s.kpi_section("KPIs", [
            ["Total servicios",         k["total"].to_i],
            ["OK (driver cobró)",       k["ok"].to_i],
            ["Mala práctica",           k["mala_practica"].to_i],
            ["Fraude",                  k["fraude"].to_i],
            ["Monto Mala práctica COP", k["monto_mp"].to_i],
            ["Monto Fraude COP",        k["monto_fraude"].to_i],
            ["Monto total COP",         k["monto_total"].to_i],
          ], ncols: 2)
          s.finalize
        end

        x.add_sheet("Tendencia diaria") do |s|
          s.banner("Tendencia diaria — #{label}", desde + " → " + hasta, 4)
          s.headers(["Fecha", "OK", "Mala práctica", "Fraude"])
          trend.each do |r|
            s.data_row([r["fecha"].to_s[0, 10], r["ok"].to_i, r["mala_practica"].to_i, r["fraude"].to_i],
                       right_align: [2, 3, 4])
          end
          s.finalize(freeze_row: 4)
        end

        x.add_sheet("Top Ciudades") do |s|
          s.banner("Top ciudades — #{label}", "Top 10 por servicios", 5)
          s.headers(["Ciudad", "País", "Total", "Mala práctica", "Fraude"])
          cd.each do |r|
            s.data_row([r["ciudad"].to_s, r["pais"].to_s, r["total"].to_i,
                        r["mala_practica"].to_i, r["fraude"].to_i],
                       right_align: [3, 4, 5])
          end
          s.finalize(freeze_row: 4)
        end

        x.add_sheet("Pares Driver+Pasajero") do |s|
          s.banner("Pares con ≥2 servicios sin pago — #{label}", "Top 20 sospechosos", 6)
          s.headers(["Driver ID", "Passenger ID", "Servicios", "Monto total", "N Fraude", "N MP"])
          duo.each do |r|
            s.data_row([r["driver_id"].to_s, r["passenger_id"].to_s, r["servicios"].to_i,
                        r["monto_total"].to_f.round(0), r["n_fraude"].to_i, r["n_mp"].to_i],
                       right_align: [3, 4, 5, 6])
          end
          s.finalize(freeze_row: 4)
        end
      end

      send_xlsx(xlsx)
    rescue => e
      handle_error(e, "pagos")
    end

    # GET /api/exportar/recaudos?desde=&hasta=&moneda=
    def recaudos
      desde, hasta = desde_param, hasta_param
      moneda = params[:moneda].to_s.strip
      filtro_moneda = moneda.empty? ? "" : "AND JSONExtractString(wat.amount,'currency_iso')='#{moneda.gsub("'", "''")}'"

      sql = QueriesService.format(QueriesService::Q_RECAUDOS,
                                   desde: desde, hasta: hasta, filtro_moneda: filtro_moneda)
      rows = ch.query(sql, timeout: 300)

      xlsx = ExcelExportService.build("Picap_Recaudos") do |x|
        x.add_sheet("Detalle") do |s|
          s.banner("Recaudos — Detalle",
                   "Período: #{desde} → #{hasta}  ·  Registros: #{rows.size}", 11)
          s.headers([
            "Fecha tx", "Booking ID", "Tipo tx", "Moneda",
            "Suma negativos", "Suma positivos", "Balance neto",
            "Cnt negativos", "Cnt positivos", "Cnt total", "Clasificación",
          ])
          rows.each do |r|
            s.data_row([
              r["fecha_tx"].to_s[0, 16],
              r["id_booking"].to_s,
              r["tipo_tx"].to_s,
              r["moneda"].to_s,
              r["suma_negativos"].to_f.round(2),
              r["suma_positivos"].to_f.round(2),
              r["balance_neto"].to_f.round(2),
              r["cnt_negativos"].to_i,
              r["cnt_positivos"].to_i,
              r["cnt_total"].to_i,
              r["clasificacion"].to_s,
            ], right_align: [5, 6, 7, 8, 9, 10])
          end
          s.finalize(freeze_row: 4)
        end
      end

      send_xlsx(xlsx)
    rescue => e
      handle_error(e, "recaudos")
    end

    private

    # Sufijo para el detalle de evasión (similar a Q_KPIS pero columnas raw)
    DETALLE_SUFFIX_EVASION = <<~'SQL'
      SELECT
          creacion_servicio, booking_id, id_driver, name_driver,
          id_company, type_service, moneda, pais, ciudad,
          costo_estimado, minutos_entre_eventos,
          cancel_lon, cancel_lat, end_lon, end_lat,
          distancia_cancel_destino, nivel, comision_servicio,
          comision_mas_penalizacion
      FROM clasificado
      ORDER BY nivel DESC, creacion_servicio DESC
      LIMIT 5000
    SQL

    def send_xlsx(xlsx)
      send_data xlsx[:data], type: xlsx[:mimetype], filename: xlsx[:filename], disposition: "attachment"
    end

    def handle_error(e, modulo)
      Rails.logger.error("[ExportarController##{modulo}] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end
  end
end
