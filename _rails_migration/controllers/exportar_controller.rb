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

    # GET /api/exportar/recaudos?desde=&hasta=&pais=&tipo=picash|ida_y_vuelta
    # Recaudos v2 — exporta detalle por booking. Si no se pasa `tipo`, genera 2 hojas
    # (Picash + Ida y Vuelta). Si se especifica, solo esa hoja.
    def recaudos
      desde, hasta = desde_param, hasta_param
      pais  = params[:pais].to_s.strip
      tipo  = params[:tipo].to_s.strip.downcase   # picash | ida_y_vuelta | (vacío = ambas)
      tipo  = "" unless %w[picash ida_y_vuelta ida_vuelta].include?(tipo)

      esc = ->(v) { v.to_s.gsub("'", "''") }
      filtro_pais = pais.empty? ? "" : "AND b.g_country = '#{esc.(pais[0,2].upcase)}'"

      sql = QueriesService.format(
        QueriesService::Q_RECAUDOS_DETALLE,
        desde: desde, hasta: hasta,
        filtro_pais: filtro_pais,
        limit_filas: 20_000,
      )
      rows = ch.query(sql, timeout: 300)

      # Enriquecer con balance Picash actual + balance fin de mes + estado_real
      driver_ids = rows.map { |r| r["driver_id"].to_s }.uniq.reject(&:empty?)
      balances   = recaudos_balances_picash(driver_ids, hasta)
      rows = rows.map do |r|
        b = balances[r["driver_id"].to_s] || {}
        r["balance_actual"]  = b[:actual]
        r["balance_fin_mes"] = b[:fin_mes]
        r["estado_real"]     = recaudos_estado_real(r["debe"].to_s, r["balance_actual"])
        r
      end

      picash_rows     = rows.select { |r| r["tipo_deuda"].to_s == "PICASH" }
      idayvuelta_rows = rows.select { |r| r["tipo_deuda"].to_s == "IDA Y VUELTA" }

      sheets = case tipo
      when "picash"                    then [["Recaudos Picash",       picash_rows]]
      when "ida_y_vuelta", "ida_vuelta" then [["Recaudos Ida y Vuelta", idayvuelta_rows]]
      else
        [["Recaudos Picash", picash_rows], ["Recaudos Ida y Vuelta", idayvuelta_rows]]
      end

      fname_suffix = case tipo
      when "picash"                    then "Picash"
      when "ida_y_vuelta", "ida_vuelta" then "IdaVuelta"
      else "Todos"
      end

      # v3: calcular recuperación del mes anterior para el resumen ejecutivo.
      # Definición acordada con DP: bookings con debe=DEBE del mes anterior cuyo
      # piloto HOY tiene balance Picash >= 0 → suma de recaudo_neto.abs de esos.
      mes_ant_desde, mes_ant_hasta = recuperacion_rango_mes_anterior(desde, hasta)
      recuperacion_data = recuperacion_calcular(mes_ant_desde, mes_ant_hasta, filtro_pais)

      xlsx = ExcelExportService.build("Picap_Recaudos_#{fname_suffix}") do |x|
        # Hoja 1+: detalle por sub-tab (Picash / Ida y Vuelta o ambas).
        sheets.each do |(sheet_name, sheet_rows)|
          x.add_sheet(sheet_name) do |s|
            s.banner(sheet_name,
                     "Período: #{desde} → #{hasta}  ·  Registros: #{sheet_rows.size}", 15)
            s.headers([
              "Fecha servicio", "Booking ID", "Piloto ID", "Piloto Nombre",
              "Comercio ID", "Comercio Nombre", "Ciudad", "Moneda",
              "Valor servicio", "Recaudo +", "Recaudo −", "Recaudo neto",
              "Saldo actual", "Saldo fin de mes", "Estado booking", "Estado real",
            ])
            sheet_rows.each do |r|
              ba = r["balance_actual"]
              bf = r["balance_fin_mes"]
              s.data_row([
                r["fecha_servicio"].to_s[0, 19],
                r["booking_id"].to_s,
                r["driver_id"].to_s,
                r["nombre_piloto"].to_s,
                r["company_id"].to_s,
                r["comercio"].to_s,
                r["ciudad"].to_s,
                r["moneda"].to_s,
                r["valor_servicio"].to_f.round(2),
                r["total_positivo"].to_f.round(2),
                r["total_negativo"].to_f.round(2),
                r["recaudo_neto"].to_f.round(2),
                ba.nil? ? "" : ba.to_f.round(2),
                bf.nil? ? "" : bf.to_f.round(2),
                r["debe"].to_s,
                r["estado_real"].to_s,
              ], right_align: [9, 10, 11, 12, 13, 14])
            end
            s.finalize(freeze_row: 4)
          end
        end

        # Hoja final: Resumen Ejecutivo (estilo Pibox).
        # Toma TODAS las filas (no separa por sub-tab) — el informe se calcula
        # consolidado para el rango seleccionado.
        x.add_sheet("Resumen Ejecutivo", tab_color: ExcelExportService::COLORS[:red]) do |s|
          resumen_ejecutivo_render(s, rows, desde, hasta, recuperacion_data)
        end
      end

      send_xlsx(xlsx)
    rescue => e
      handle_error(e, "recaudos")
    end

    private

    # ── Resumen Ejecutivo (estilo Pibox) ─────────────────────────────────────

    # Devuelve [mes_ant_desde, mes_ant_hasta] como YYYY-MM-DD.
    # Si el rango actual cubre todo un mes (ej. 2026-04-01..2026-04-30), devuelve
    # el mes anterior completo (2026-03-01..2026-03-31). Si es un rango parcial,
    # devuelve el mismo rango pero corrido 1 mes para atrás.
    def recuperacion_rango_mes_anterior(desde, hasta)
      d = Date.parse(desde.to_s)
      h = Date.parse(hasta.to_s)
      # Si cubre todo un mes natural, usar mes anterior natural completo.
      if d.day == 1 && h == Date.new(d.year, d.month, -1)
        prev = d.prev_month
        return [prev.strftime("%Y-%m-%d"), Date.new(prev.year, prev.month, -1).strftime("%Y-%m-%d")]
      end
      [d.prev_month.strftime("%Y-%m-%d"), h.prev_month.strftime("%Y-%m-%d")]
    rescue
      # Fallback: 30 días antes del rango actual.
      [(Date.today - 60).strftime("%Y-%m-%d"), (Date.today - 30).strftime("%Y-%m-%d")]
    end

    # Calcula la recuperación del mes anterior:
    # - Corre Q_RECAUDOS_DETALLE para el rango del mes anterior.
    # - Filtra bookings con debe == "DEBE".
    # - De esos pilotos, los que HOY tienen balance Picash >= 0 → suma de
    #   recaudo_neto.abs es "recuperación" (la deuda del mes anterior ya se saldó).
    # Devuelve { recuperacion: Float, bookings_recuperados: Int, periodo: "..." }.
    def recuperacion_calcular(desde, hasta, filtro_pais)
      sql = QueriesService.format(
        QueriesService::Q_RECAUDOS_DETALLE,
        desde: desde, hasta: hasta,
        filtro_pais: filtro_pais,
        limit_filas: 20_000,
      )
      ant_rows = ch.query(sql, timeout: 300)

      debe_rows = ant_rows.select { |r| r["debe"].to_s == "DEBE" && r["tipo_deuda"].to_s == "PICASH" }
      driver_ids = debe_rows.map { |r| r["driver_id"].to_s }.uniq.reject(&:empty?)
      return { recuperacion: 0.0, bookings_recuperados: 0, periodo: "#{desde} → #{hasta}", total_perdidas_mes_ant: 0.0 } if driver_ids.empty?

      balances = recaudos_balances_picash(driver_ids, Date.today.strftime("%Y-%m-%d"))

      recuperacion = 0.0
      bookings_recuperados = 0
      total_perdidas_mes_ant = 0.0
      debe_rows.each do |r|
        valor = r["recaudo_neto"].to_f.abs
        total_perdidas_mes_ant += valor
        bal = (balances[r["driver_id"].to_s] || {})[:actual]
        next if bal.nil?
        if bal >= 0
          recuperacion += valor
          bookings_recuperados += 1
        end
      end

      {
        recuperacion:           recuperacion.round(2),
        bookings_recuperados:   bookings_recuperados,
        total_perdidas_mes_ant: total_perdidas_mes_ant.round(2),
        periodo:                "#{desde} → #{hasta}",
      }
    rescue => e
      Rails.logger.warn("[ExportarController#recuperacion_calcular] #{e.message}")
      { recuperacion: 0.0, bookings_recuperados: 0, total_perdidas_mes_ant: 0.0, periodo: "#{desde} → #{hasta}" }
    end

    # Nombre del mes en español (es-CO) — usado para los headers del resumen.
    MESES_ES = %w[ENERO FEBRERO MARZO ABRIL MAYO JUNIO JULIO AGOSTO SEPTIEMBRE OCTUBRE NOVIEMBRE DICIEMBRE].freeze

    def mes_label(desde)
      d = Date.parse(desde.to_s)
      MESES_ES[d.month - 1] || d.strftime("%B").upcase
    rescue
      "PERÍODO"
    end

    # Renderiza la hoja "Resumen Ejecutivo" con plantilla Pibox.
    # @param s [ExcelExportService::SheetHelper]
    # @param rows [Array<Hash>] todas las filas del rango (Picash + Ida y Vuelta)
    # @param desde, hasta [String] rango del filtro
    # @param recup [Hash] resultado de recuperacion_calcular
    def resumen_ejecutivo_render(s, rows, desde, hasta, recup)
      mes_actual_lbl = mes_label(desde)
      mes_ant_d = Date.parse(desde) rescue Date.today
      mes_ant_lbl = MESES_ES[mes_ant_d.prev_month.month - 1] || ""

      # Métricas del rango actual
      total_recaudo  = rows.sum { |r| r["total_positivo"].to_f }.round(2)
      perdidas       = rows.select { |r| %w[DEBE SIN\ RECAUDO].include?(r["estado_real"].to_s) }
                           .sum { |r| r["recaudo_neto"].to_f.abs }.round(2)
      pct_perdidas   = total_recaudo > 0 ? -(perdidas / total_recaudo) : 0.0  # negativo por convención

      # Pivot por compañía (sólo las que tienen pérdidas pendientes)
      pendientes_por_cia = rows
        .select { |r| %w[DEBE SIN\ RECAUDO].include?(r["estado_real"].to_s) }
        .group_by { |r| [r["company_id"].to_s, r["comercio"].to_s, r["ciudad"].to_s] }
        .map do |(cid, nombre, ciudad), grupo|
          {
            comercio: nombre.empty? ? cid : nombre,
            ciudad:   ciudad,
            pendiente: -grupo.sum { |r| r["recaudo_neto"].to_f.abs }.round(2),  # negativo
          }
        end
        .sort_by { |h| h[:pendiente] }  # más negativo primero

      total_pendientes = pendientes_por_cia.sum { |h| h[:pendiente] }
      pendientes_con_pct = pendientes_por_cia.map do |h|
        h.merge(pct: total_pendientes != 0 ? (h[:pendiente] / total_pendientes) : 0.0)
      end

      # ── Layout ───────────────────────────────────────────────────────────
      s.set_column_widths(22, 18, 18, 18, 16)

      # Logo Pibox — si existe el PNG en public/images, lo embebe. Si no,
      # cae a placeholder de texto morado "pibox".
      # Cuando DP pase el PNG, guardarlo como public/images/pibox_logo.png
      # y se carga automáticamente sin tocar código.
      logo_path = (defined?(Rails) ? Rails.root.join("public/images/pibox_logo.png").to_s : nil)
      if logo_path && File.exist?(logo_path)
        s.add_image(logo_path, row: 1, col: 1, width: 160, height: 64)
        s.blank_rows(3)  # reservar espacio del logo
      else
        s.ws.add_row(["pibox"], height: 40)
        s.ws.merge_cells("A1:B2")
        s.instance_variable_set(:@current_row, 4)
        s.blank_rows(1)
      end

      # Título principal
      s.report_main_title("INFORME DE PÉRDIDAS EN LOS RECAUDOS", span: 5)

      # Tabla 1: PERÍODO | RECAUDO | PERDIDAS | % PERDIDAS
      s.report_table(
        ["PERÍODO", "RECAUDO", "PERDIDAS", "% PERDIDAS"],
        [[mes_actual_lbl, total_recaudo, -perdidas, pct_perdidas]],
        value_styles: [:text, :money, :money_neg, :pct],
      )

      # Tabla 2: PERDIDA [MES] | RECUPERACIÓN [MES ANT] | TOTAL PERDIDAS
      total_neto = -perdidas + recup[:recuperacion]
      s.report_table(
        ["PERDIDA #{mes_actual_lbl}", "RECUPERACIÓN #{mes_ant_lbl}", "TOTAL PERDIDAS"],
        [[-perdidas, recup[:recuperacion], total_neto]],
        value_styles: [:money_neg, :money, :money_neg],
      )

      # Tabla 3: pivot por compañía (sólo con pendientes)
      if pendientes_con_pct.any?
        s.report_table(
          ["COMPAÑÍA", "Ciudad", "Suma de PENDIENTE", "PORCENTAJE"],
          pendientes_con_pct.map { |h| [h[:comercio], h[:ciudad], h[:pendiente], h[:pct]] } +
            [["Total general", "", total_pendientes, 1.0]],
          value_styles: [:text, :text, :money_neg, :pct],
        )
      else
        s.report_table(
          ["COMPAÑÍA", "Ciudad", "Suma de PENDIENTE", "PORCENTAJE"],
          [["— Sin pendientes —", "", 0, 0]],
          value_styles: [:text, :text, :money_neg, :pct],
        )
      end

      s.ws.sheet_view.show_grid_lines = false
      s
    end

    # Balance Picash por piloto: { driver_id => {actual: Float, fin_mes: Float} }
    # - actual: latest amount_after_transaction sin límite de fecha (HOY)
    # - fin_mes: latest amount_after_transaction con created_at <= hasta (cierre del rango)
    def recaudos_balances_picash(driver_ids, hasta)
      return {} if driver_ids.empty?
      esc = ->(v) { v.to_s.gsub("'", "''") }
      ids_csv   = driver_ids.map { |id| "'#{esc.(id)}'" }.join(",")
      hasta_esc = esc.(hasta.to_s)
      sql = <<~SQL
        WITH
            picash_wallets AS (
                SELECT _id AS account_id, passenger_id AS driver_id
                FROM picapmongoprod.wallet_accounts
                WHERE type_cd = 0 AND passenger_id IN (#{ids_csv})
            ),
            latest_actual AS (
                SELECT account_id,
                       argMax(toFloat64OrNull(JSONExtractString(amount_after_transaction, 'cents'))/100, created_at) AS balance
                FROM picapmongoprod.wallet_account_transactions
                WHERE account_id IN (SELECT account_id FROM picash_wallets)
                  AND length(amount_after_transaction) > 2
                GROUP BY account_id
            ),
            latest_fin_mes AS (
                SELECT account_id,
                       argMax(toFloat64OrNull(JSONExtractString(amount_after_transaction, 'cents'))/100, created_at) AS balance
                FROM picapmongoprod.wallet_account_transactions
                WHERE account_id IN (SELECT account_id FROM picash_wallets)
                  AND length(amount_after_transaction) > 2
                  AND created_at <= toDateTime('#{hasta_esc} 23:59:59')
                GROUP BY account_id
            )
        SELECT pw.driver_id AS driver_id,
               sum(la.balance) AS balance_actual,
               sum(lf.balance) AS balance_fin_mes
        FROM picash_wallets pw
        LEFT JOIN latest_actual la  ON la.account_id = pw.account_id
        LEFT JOIN latest_fin_mes lf ON lf.account_id = pw.account_id
        GROUP BY pw.driver_id
      SQL
      ch.query(sql, timeout: 120).each_with_object({}) do |r, h|
        h[r["driver_id"]] = {
          actual:  r["balance_actual"].nil?  ? nil : r["balance_actual"].to_f,
          fin_mes: r["balance_fin_mes"].nil? ? nil : r["balance_fin_mes"].to_f,
        }
      end
    rescue => e
      Rails.logger.warn("[ExportarController#recaudos_balances_picash] #{e.message}")
      {}
    end

    def recaudos_estado_real(debe, balance)
      return debe if debe != "DEBE"
      return "DEBE" if balance.nil?
      balance >= 0 ? "NO DEBE (saldado)" : "DEBE"
    end

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
