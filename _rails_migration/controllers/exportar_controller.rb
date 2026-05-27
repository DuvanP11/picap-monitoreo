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
    # v2: ahora genera 4 hojas (Alertas / Bloqueados Actuales / Reactivaciones /
    # Estadística General) e incluye la columna "Tipo de Cuenta" derivada de
    # suspended_service_types. Reutilizado por BloqueosController#enviar_email.
    def bloqueos
      desde, hasta = desde_param, hasta_param
      send_xlsx(self.class.build_bloqueos_xlsx(desde, hasta, ch))
    rescue => e
      handle_error(e, "bloqueos")
    end

    # Builder centralizado del xlsx de Bloqueos. Recibe `ch` como dependencia
    # explícita para que pueda ser llamado desde otro controller sin
    # instanciar ExportarController.
    #
    # Genera 4 hojas:
    #   1. Alertas (filas con veredicto != TODO OK)
    #   2. Bloqueados Actuales (esta_activo = bloqueado)
    #   3. Reactivaciones (esta_activo = activo)
    #   4. Estadística General (resumen + breakdown por tipo_cuenta)
    def self.build_bloqueos_xlsx(desde, hasta, ch)
      rows = ch.query(QueriesService.format(QueriesService::Q_BLOQUEOS,
                                             fecha_desde: desde, fecha_hasta: hasta), timeout: 300)

      # Enrich con país + motivo + veredicto (igual que bloqueos_controller)
      rows = rows.map do |r|
        r["pais_nombre"] = MotivoMapper::PAISES_MAP[r["pais_codigo"]] || r["pais_codigo"]
        # v2.1: normalizar ciudad (Bogotá variants → "Bogotá")
        r["ciudad"] = MotivoMapper.normalizar_ciudad(r["ciudad"])
        # v2.5: motivo desde `message` per-suspensión, fallback estricto a user-level
        raw_message = r["message_suspension"].to_s.strip
        r["motivo_mapeado"] = if !raw_message.empty?
          MotivoMapper.mapear(raw_message)
        else
          MotivoMapper.mapear_estricto(
            r["quien_suspende"],
            comentario_driver: r["comentario_driver"],
            comentario_user:   r["comentario_user"],
            comentario_expulsion_user: r["comentario_expulsion_user"],
          )
        end
        # v2.6: override quien_suspende y tipo_cuenta si el motivo es inequívoco
        cfg = MotivoMapper.inferir_lado_y_servicio(r["motivo_mapeado"])
        case cfg[:lado]
        when :prestador
          r["quien_suspende"] = "USUARIO PRESTADOR"
          r["tipo_cuenta"] = case cfg[:servicio]
                             when :pibox then "Piloto Pibox"
                             when :rent  then "Piloto Rent"
                             else
                               # v2.7: service_types raw contiene 'picap' para Rent
                               st = r["service_types"].to_s.downcase
                               has_rent  = st.include?("rent") || st.include?("picap")
                               has_pibox = st.include?("pibox")
                               if has_pibox && has_rent
                                 "Piloto Pibox+Rent"
                               elsif has_rent
                                 "Piloto Rent"
                               else
                                 "Piloto Pibox"
                               end
                             end
        when :consumidor
          r["quien_suspende"] = "USUARIO CONSUMIDOR"
          r["tipo_cuenta"]    = "Pasajero"
        end
        dias = r["dias_bloqueado_total"].to_i
        tipo_blq = r["tipo_bloqueo"].to_s
        if tipo_blq == "EXPULSADO"
          r["veredicto"] = "EXPULSIÓN PERMANENTE"
        else
          r["veredicto"] = dias > 30 ? "ALERTA DE TIEMPO" : "TODO OK"
        end
        r
      end

      # Clasificar
      alertas     = rows.select { |r| r["veredicto"] != "TODO OK" }
      bloqueados  = rows.select { |r| r["esta_activo"] == "bloqueado" }
      reactivados = rows.select { |r| r["esta_activo"] == "activo" }

      # v2.5: incluye Permanente (per-suspension) y Mensaje (raw from suspension table)
      headers_detalle = [
        "Suspensión ID", "Fecha", "ID Usuario", "Nombre",
        "A Quien Suspende", "Tipo Usuario", "Tipo de Cuenta",
        "Service Types", "País", "Ciudad", "Tipo Bloqueo", "Permanente", "Veredicto",
        "Días bloqueado", "Motivo", "Mensaje (raw)", "Comentario driver", "Comentario user",
        "Expulsado (user)", "Activo",
      ].freeze

      build_data_row = ->(r) {
        [
          r["suspension_id"].to_s,
          r["fecha_ultima_suspension"].to_s,
          r["id_usuario"].to_s,
          r["nombre"].to_s,
          r["quien_suspende"].to_s,
          r["tipo_usuario"].to_s,
          r["tipo_cuenta"].to_s,
          r["service_types"].to_s,
          r["pais_nombre"].to_s,
          r["ciudad"].to_s,
          r["tipo_bloqueo"].to_s,
          r["permanent_flag"].to_i == 1 ? "Sí" : "No",
          r["veredicto"].to_s,
          r["dias_bloqueado_total"].to_i,
          r["motivo_mapeado"].to_s,
          r["message_suspension"].to_s[0, 300],
          r["comentario_driver"].to_s[0, 300],
          r["comentario_user"].to_s[0, 300],
          r["expulsado"].to_s,
          r["esta_activo"].to_s,
        ]
      }

      ExcelExportService.build("Picap_Bloqueos") do |x|
        # ── Hoja 1: Alertas ───────────────────────────────────────────────
        x.add_sheet("Alertas") do |s|
          s.banner("Alertas de Bloqueo",
                   "Período: #{desde} → #{hasta}  ·  Registros: #{alertas.size}", 16)
          s.headers(headers_detalle)
          alertas.each { |r| s.data_row(build_data_row.(r), right_align: [14]) }
          s.finalize(freeze_row: 4)
        end

        # ── Hoja 2: Bloqueados Actuales ────────────────────────────────────
        x.add_sheet("Bloqueados Actuales") do |s|
          s.banner("Cuentas Actualmente Bloqueadas",
                   "Período: #{desde} → #{hasta}  ·  Registros: #{bloqueados.size}", 16)
          s.headers(headers_detalle)
          bloqueados.each { |r| s.data_row(build_data_row.(r), right_align: [14]) }
          s.finalize(freeze_row: 4)
        end

        # ── Hoja 3: Reactivaciones ────────────────────────────────────────
        x.add_sheet("Reactivaciones") do |s|
          s.banner("Cuentas Reactivadas",
                   "Período: #{desde} → #{hasta}  ·  Registros: #{reactivados.size}", 16)
          s.headers(headers_detalle)
          reactivados.each { |r| s.data_row(build_data_row.(r), right_align: [14]) }
          s.finalize(freeze_row: 4)
        end

        # ── Hoja 4: Estadística General ───────────────────────────────────
        x.add_sheet("Estadística General") do |s|
          s.banner("Estadística General de Bloqueos",
                   "Período: #{desde} → #{hasta}", 4)
          s.headers(["Métrica", "Total", "% del total", "Detalle"])
          total = rows.size.to_f
          pct = ->(n) { total > 0 ? "#{(n.to_f / total * 100).round(1)}%" : "0%" }

          # Cross-stats: tipo_bloqueo × tipo_cuenta
          counts = {
            "Total cuentas en período"            => rows.size,
            "Bloqueados (suspendidos + expulsados)" => bloqueados.size,
            "  - Expulsados (permanentes)"        => rows.count { |r| r["tipo_bloqueo"] == "EXPULSADO" },
            "  - Suspendidos"                     => rows.count { |r| r["tipo_bloqueo"] == "SUSPENDIDO" },
            "Reactivados"                         => reactivados.size,
            "Alertas (>30 días bloqueados)"       => alertas.count { |r| r["veredicto"] == "ALERTA DE TIEMPO" },
          }
          counts.each do |label, n|
            s.data_row([label, n, label.start_with?("  ") ? "" : pct.(n), ""], right_align: [2])
          end
          # Por tipo de cuenta
          s.data_row(["", "", "", ""])  # separator
          s.data_row(["── Por Tipo de Cuenta ──", "", "", ""])
          %w[Pasajero Piloto\ Pibox Piloto\ Rent Piloto\ Pibox+Rent].each do |tc|
            n = rows.count { |r| r["tipo_cuenta"] == tc }
            next if n.zero?
            s.data_row([tc, n, pct.(n), ""], right_align: [2])
          end
          # Por tipo de bloqueo cruzado con tipo de cuenta
          s.data_row(["", "", "", ""])
          s.data_row(["── Expulsados × Tipo de Cuenta ──", "", "", ""])
          exp_pibox  = rows.count { |r| r["tipo_bloqueo"] == "EXPULSADO" && r["tipo_cuenta"].to_s.include?("Pibox") }
          exp_rent   = rows.count { |r| r["tipo_bloqueo"] == "EXPULSADO" && r["tipo_cuenta"].to_s.include?("Rent") }
          exp_pasaj  = rows.count { |r| r["tipo_bloqueo"] == "EXPULSADO" && r["tipo_cuenta"] == "Pasajero" }
          s.data_row(["Pilotos Pibox expulsados",   exp_pibox,  pct.(exp_pibox),  ""], right_align: [2])
          s.data_row(["Pilotos Rent expulsados",    exp_rent,   pct.(exp_rent),   ""], right_align: [2])
          s.data_row(["Pasajeros expulsados",       exp_pasaj,  pct.(exp_pasaj),  ""], right_align: [2])
          s.data_row(["", "", "", ""])
          s.data_row(["── Suspendidos × Tipo de Cuenta ──", "", "", ""])
          sus_pibox  = rows.count { |r| r["tipo_bloqueo"] == "SUSPENDIDO" && r["tipo_cuenta"].to_s.include?("Pibox") }
          sus_rent   = rows.count { |r| r["tipo_bloqueo"] == "SUSPENDIDO" && r["tipo_cuenta"].to_s.include?("Rent") }
          sus_pasaj  = rows.count { |r| r["tipo_bloqueo"] == "SUSPENDIDO" && r["tipo_cuenta"] == "Pasajero" }
          s.data_row(["Pilotos Pibox suspendidos",  sus_pibox,  pct.(sus_pibox),  ""], right_align: [2])
          s.data_row(["Pilotos Rent suspendidos",   sus_rent,   pct.(sus_rent),   ""], right_align: [2])
          s.data_row(["Pasajeros suspendidos",      sus_pasaj,  pct.(sus_pasaj),  ""], right_align: [2])
          # Top 10 ciudades
          s.data_row(["", "", "", ""])
          s.data_row(["── Top 10 Ciudades con Más Bloqueos ──", "", "", ""])
          ciudades = bloqueados.group_by { |r| r["ciudad"].to_s.empty? ? "(sin ciudad)" : r["ciudad"] }
                               .map { |c, v| [c, v.size] }
                               .sort_by { |_, n| -n }
                               .first(10)
          ciudades.each { |c, n| s.data_row([c, n, "#{(bloqueados.size > 0 ? n.to_f / bloqueados.size * 100 : 0).round(1)}% (de bloqueados)", ""], right_align: [2]) }

          # v2.1: Top 10 motivos por tipo de cuenta (Piloto Pibox / Piloto Rent / Pasajero)
          ["Piloto Pibox", "Piloto Rent", "Piloto Pibox+Rent", "Pasajero"].each do |tc|
            subset = bloqueados.select { |r| r["tipo_cuenta"] == tc }
            next if subset.empty?
            s.data_row(["", "", "", ""])
            s.data_row(["── Top 10 Motivos · #{tc} (#{subset.size} bloqueados) ──", "", "", ""])
            motivos = Hash.new(0)
            subset.each do |r|
              m = r["motivo_mapeado"].to_s.strip
              motivos[m] += 1 unless m.empty?
            end
            motivos.sort_by { |_, v| -v }.first(10).each do |motivo, count|
              pct_tc = subset.size > 0 ? (count.to_f / subset.size * 100).round(1) : 0
              s.data_row([motivo, count, "#{pct_tc}% (de #{tc})", ""], right_align: [2])
            end
          end

          s.finalize(freeze_row: 4)
        end
      end
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
      # v3.1: el param `tipo` se ignora — el export SIEMPRE devuelve el xlsx
      # completo con 3 hojas: Picash + Ida y Vuelta + Resumen Ejecutivo.
      # Antes filtrabamos por sub-tab activo, pero acordamos con DP que el
      # archivo descargado es el mismo que el enviado por email.

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
        # v3.10: usar balance al cierre del período (no balance_actual) para
        # determinar estado_real. Si el piloto cerró el período saldado, no
        # debía nada en ese momento aunque hoy tenga deuda nueva.
        r["estado_real"]     = recaudos_estado_real(r["debe"].to_s, r["balance_fin_mes"])
        r
      end

      picash_rows     = rows.select { |r| r["tipo_deuda"].to_s == "PICASH" }
      idayvuelta_rows = rows.select { |r| r["tipo_deuda"].to_s == "IDA Y VUELTA" }
      sheets = [["Recaudos Picash", picash_rows], ["Recaudos Ida y Vuelta", idayvuelta_rows]]

      # Calcular recuperación del mes anterior para el resumen ejecutivo.
      # Bookings con debe=DEBE del mes anterior cuyo piloto HOY tiene balance
      # Picash >= 0 → suma de recaudo_neto.abs de esos. La lógica pura vive en
      # RecaudosResumenHelpers; acá hacemos el wiring con CH.
      recuperacion_data = cargar_recuperacion_mes_anterior(desde, hasta, filtro_pais)

      xlsx = ExcelExportService.build("Picap_Recaudos") do |x|
        # v3.6: hojas detalle INLINE (igual que Evasión/Bloqueos/etc.).
        # Antes pasábamos por RecaudosResumenHelpers.render_detalle_sheet pero
        # ese wrapping rompía la aplicación de estilos en caxlsx — aunque el
        # código se ejecutaba, los styles no se vinculaban a las celdas.
        # Patrón confirmado funcionando en Evasión (commit 9fe9ffa).
        sheets.each do |(sheet_name, sheet_rows)|
          x.add_sheet(sheet_name) do |s|
            s.banner(sheet_name,
                     "v3.6 · Período: #{desde} → #{hasta}  ·  Registros: #{sheet_rows.size}", 16)
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
                r["valor_servicio"].to_f,
                r["total_positivo"].to_f,
                r["total_negativo"].to_f,
                r["recaudo_neto"].to_f,
                ba.nil? ? nil : ba.to_f,
                bf.nil? ? nil : bf.to_f,
                r["debe"].to_s,
                r["estado_real"].to_s,
              ], money_cols: [9, 10, 11, 12, 13, 14])
            end
            s.finalize(freeze_row: 4)
          end
        end

        # Hoja final: Resumen Ejecutivo (estilo Pibox) INLINE.
        # v3.7: Replicado exacto del diseño del archivo de muestra del usuario
        # (Picap_Recaudos_2026-05-22.xlsx). Color morado #7030A0, formato
        # COP regional, headers blancos sobre morado, fila Total general en
        # morado pleno con texto blanco. Inline para evitar el wrapping
        # problemático que rompía los styles en v3.5 y anteriores.
        x.add_sheet("Resumen Ejecutivo", tab_color: ExcelExportService::PIBOX_PURPLE) do |s|
          ws = s.ws

          # Anchos de columnas (matchea el archivo del usuario)
          ws.column_widths(10, 17, 22, 20, 12, 10)

          # Filas 1-3: reservadas para el logo (se agrega al final)
          3.times { ws.add_row([]) }

          # Fila 4: banner morado con título centrado, mergeado A4:F4
          banner_row = ws.add_row(["INFORME DE PÉRDIDAS EN LOS RECAUDOS", nil, nil, nil, nil, nil], height: 28)
          banner_row.cells.each { |c| c.style = s.s_pibox_banner }
          ws.merge_cells "A4:F4"

          # Fila 5: vacía
          ws.add_row([])

          # ── Calcular datos ──────────────────────────────────────────────
          mes_actual_lbl = RecaudosResumenHelpers.mes_label(desde)
          mes_ant_lbl    = RecaudosResumenHelpers.mes_anterior_label(desde)

          total_recaudo = rows.sum { |r| r["total_positivo"].to_f }.round(2)
          perdidas      = rows.select { |r| %w[DEBE SIN\ RECAUDO].include?(r["estado_real"].to_s) }
                              .sum { |r| r["recaudo_neto"].to_f.abs }.round(2)
          pct_perdidas  = total_recaudo > 0 ? -(perdidas / total_recaudo) : 0.0
          total_neto    = -perdidas + recuperacion_data[:recuperacion]

          pendientes_por_cia = rows
            .select { |r| %w[DEBE SIN\ RECAUDO].include?(r["estado_real"].to_s) }
            .group_by { |r| [r["company_id"].to_s, r["comercio"].to_s, r["ciudad"].to_s] }
            .map do |(cid, nombre, ciudad), grupo|
              {
                comercio:  nombre.empty? ? cid : nombre,
                ciudad:    ciudad,
                pendiente: -grupo.sum { |r| r["recaudo_neto"].to_f.abs }.round(2),
              }
            end
            .sort_by { |h| h[:pendiente] }
          total_pendientes = pendientes_por_cia.sum { |h| h[:pendiente] }

          # ── Tabla 1: PERÍODO | RECAUDO | PERDIDAS | % PERDIDAS ─────────
          hdr1 = ws.add_row([nil, "PERÍODO", "RECAUDO", "PERDIDAS", "% PERDIDAS"], height: 24)
          [1, 2, 3, 4].each { |i| hdr1.cells[i].style = s.s_pibox_header }

          data1 = ws.add_row([nil, mes_actual_lbl, total_recaudo, -perdidas, pct_perdidas], height: 22)
          data1.cells[1].style = s.s_pibox_cell
          data1.cells[2].style = s.s_pibox_cell_cop
          data1.cells[3].style = s.s_pibox_cell_cop
          data1.cells[4].style = s.s_pibox_cell_pct

          ws.add_row([])  # separador

          # ── Tabla 2: PERDIDA [MES] | RECUPERACIÓN [MES ANT] | TOTAL ──────
          hdr2 = ws.add_row([nil, "PERDIDA #{mes_actual_lbl}", "RECUPERACIÓN #{mes_ant_lbl}", "TOTAL PERDIDAS"], height: 24)
          [1, 2, 3].each { |i| hdr2.cells[i].style = s.s_pibox_header }

          data2 = ws.add_row([nil, -perdidas, recuperacion_data[:recuperacion], total_neto], height: 22)
          data2.cells[1].style = s.s_pibox_cell_cop
          data2.cells[2].style = s.s_pibox_cell_cop
          data2.cells[3].style = s.s_pibox_cell_cop

          ws.add_row([])  # separador

          # ── Tabla 3: pivot por compañía + Total general ─────────────────
          hdr3 = ws.add_row([nil, "COMPAÑÍA", "Ciudad", "Suma de PENDIENTE", "PORCENTAJE"], height: 24)
          [1, 2, 3, 4].each { |i| hdr3.cells[i].style = s.s_pibox_header }

          if pendientes_por_cia.any?
            pendientes_por_cia.each do |h|
              pct = total_pendientes != 0 ? (h[:pendiente] / total_pendientes) : 0.0
              dr = ws.add_row([nil, h[:comercio], h[:ciudad], h[:pendiente], pct], height: 22)
              dr.cells[1].style = s.s_pibox_cell
              dr.cells[2].style = s.s_pibox_cell
              dr.cells[3].style = s.s_pibox_cell_cop
              dr.cells[4].style = s.s_pibox_cell_pct
            end
          else
            dr = ws.add_row([nil, "— Sin pendientes —", "", 0, 0], height: 22)
            dr.cells[1].style = s.s_pibox_cell
            dr.cells[2].style = s.s_pibox_cell
            dr.cells[3].style = s.s_pibox_cell_cop
            dr.cells[4].style = s.s_pibox_cell_pct
          end

          # Fila Total general (morado pleno + texto blanco)
          tot = ws.add_row([nil, "Total general", "", total_pendientes, total_pendientes != 0 ? 1.0 : 0.0], height: 22)
          tot.cells[1].style = s.s_pibox_total
          tot.cells[2].style = s.s_pibox_total
          tot.cells[3].style = s.s_pibox_total_cop
          tot.cells[4].style = s.s_pibox_total_pct

          ws.sheet_view.show_grid_lines = false

          # Logo Pibox al final (sobre las 3 filas reservadas arriba)
          logo_path = Rails.root.join("public/images/pibox_logo.png").to_s
          if File.exist?(logo_path)
            ws.add_image(image_src: logo_path) do |i|
              i.width  = 140
              i.height = 56
              i.start_at(1, 0)  # col B (col 1, 0-indexed), row 1 (0-indexed)
            end
          end
        end
      end

      send_xlsx(xlsx)
    rescue => e
      handle_error(e, "recaudos")
    end

    # GET /api/exportar/moviired?desde=&hasta=&ref=&user=
    # Devuelve CSV (no Excel — es el formato regulatorio que pidió MoviiRed).
    # Acceso restringido a admin/monitoreo/financiero (validación inline ya que
    # este controller no tiene before_action de rol globalmente).
    def moviired
      unless Api::MoviiredController::ROLES_PERMITIDOS.include?(current_rol.to_s)
        return render(json: {
          ok: false,
          error: "Acceso restringido — solo roles: admin, monitoreo, financiero",
        }, status: :forbidden)
      end

      desde = desde_param
      hasta = hasta_param
      ref   = params[:ref].to_s.strip
      user  = params[:user].to_s.strip

      esc = ->(v) { v.to_s.gsub("'", "''") }
      filtro_ref  = ref.length  >= 3 ? "AND e.id_tx ILIKE '%#{esc.(ref)}%'"    : ""
      filtro_user = user.length >= 3 ? "AND e.id_user ILIKE '%#{esc.(user)}%'" : ""

      sql = QueriesService.format(
        QueriesService::Q_MOVIIRED,
        desde: desde, hasta: hasta,
        filtro_ref: filtro_ref,
        filtro_user: filtro_user,
        limit_filas: 50_000,
      )
      rows = ch.query(sql, timeout: 300)

      require "csv"
      # v3.10: CSV con las 8 columnas regulatorias que pidió el equipo MoviiRed.
      # v3.11: separador ';' (punto y coma) — Excel en es-CO usa ';' por
      # default, con ',' todo el CSV cae en una sola columna. VALOR TX como
      # entero (sin decimales).
      csv_str = CSV.generate(col_sep: ";", force_quotes: true) do |csv|
        csv << [
          "CODIGO_SERVICE_TYPE", "FECHA_HORA", "NUMERO MOVIIRED", "VALOR TX",
          "NUMERO REFERENCIA TRANSACCION", "NUMERO TX MAHINDRA",
          "DANE", "CODIGO PUNTO",
        ]
        rows.each do |r|
          csv << [
            r["codigo_service_type"].to_s,
            r["fecha_hora"].to_s,
            r["numero_moviired"].to_s,
            r["valor_tx"].to_f.round,  # entero, sin decimales
            r["numero_referencia_transaccion"].to_s,
            r["numero_tx_mahindra"].to_s,
            r["dane"].to_s,
            r["codigo_punto"].to_s,
          ]
        end
      end

      ts       = Time.now.strftime("%Y%m%d_%H%M%S")
      filename = "Picap_MoviiRed_#{desde}_#{hasta}_#{ts}.csv"
      send_data csv_str, filename: filename, type: "text/csv; charset=utf-8",
                disposition: "attachment"
    rescue => e
      handle_error(e, "moviired")
    end

    # GET /api/exportar/dispersiones?desde=&hasta=&company=&tipo=
    # Devuelve Excel con 2 hojas (BD Dispersiones + TD Dispersiones pivot).
    # Acceso restringido a admin/monitoreo/financiero.
    def dispersiones
      unless Api::DispersionesController::ROLES_PERMITIDOS.include?(current_rol.to_s)
        return render(json: {
          ok: false,
          error: "Acceso restringido — solo roles: admin, monitoreo, financiero",
        }, status: :forbidden)
      end
      send_xlsx(self.class.build_dispersiones_xlsx(
        desde_param, hasta_param, ch,
        company: params[:company].to_s.strip,
        tipo:    params[:tipo].to_s.strip,
      ))
    rescue => e
      handle_error(e, "dispersiones")
    end

    # Builder centralizado del xlsx de Dispersiones. Recibe `ch` como
    # dependencia para reuso desde DispersionesController#enviar_email.
    #
    # Estructura del libro (espejada al Excel de referencia del cliente):
    #   Hoja 1 "BD Dispersiones" — datos crudos, 1 fila por tx.
    #     Columnas: id_Tx, Fecha_Tx, Valor, Tipo_Tx, Company Id, Company Name, Tipo Dispersion
    #   Hoja 2 "TD Dispersiones" — pivot agrupado por (Company Name, Tipo Dispersion).
    #     Columnas: Company Name, Tipo Dispersion, Valor (sum)
    #     + fila Total general al final.
    def self.build_dispersiones_xlsx(desde, hasta, ch, company: "", tipo: "")
      rows = ch.query(QueriesService.format(QueriesService::Q_DISPERSIONES,
                                             fecha_desde: desde, fecha_hasta: hasta), timeout: 300)
      # Filtros opcionales en memoria
      unless company.empty?
        c_low = company.downcase
        rows = rows.select { |r| r["company_name"].to_s.downcase.include?(c_low) }
      end
      unless tipo.empty?
        t_low = tipo.downcase
        rows = rows.select { |r| r["tipo_dispersion"].to_s.downcase.include?(t_low) }
      end

      ExcelExportService.build("Picap_Dispersiones") do |x|
        # ── Hoja 1: BD Dispersiones (raw data) ────────────────────────────
        x.add_sheet("BD Dispersiones") do |s|
          s.banner("Base de Datos · Dispersiones",
                   "Período: #{desde} → #{hasta}  ·  Registros: #{rows.size}", 7)
          headers = ["id_Tx", "Fecha_Tx", "Valor", "Tipo_Tx", "Company Id", "Company Name", "Tipo Dispersion"]
          s.headers(headers)
          rows.each do |r|
            s.data_row([
              r["id_tx"].to_s,
              r["fecha_tx"].to_s,
              r["valor"].to_f.round(2),
              r["tipo_tx"].to_s,
              r["company_id"].to_s,
              r["company_name"].to_s,
              r["tipo_dispersion"].to_s,
            ], right_align: [3])
          end
          s.finalize(freeze_row: 4)
        end

        # ── Hoja 2: TD Dispersiones (pivot) ───────────────────────────────
        x.add_sheet("TD Dispersiones") do |s|
          s.banner("Tabla Dinámica · Dispersiones",
                   "Período: #{desde} → #{hasta}  ·  Total agrupado por Company × Tipo", 3)
          s.headers(["Company Name", "Tipo Dispersion", "Valor"])
          # Group rows by (company_name, tipo_dispersion), sum valor
          pivot = rows.group_by { |r| [r["company_name"].to_s, r["tipo_dispersion"].to_s] }
                      .map { |(cname, ttipo), grp| [cname, ttipo, grp.sum { |g| g["valor"].to_f }.round(2)] }
                      .sort_by { |row| [row[0].downcase, row[1]] }
          pivot.each do |row|
            s.data_row(row, right_align: [3])
          end
          # Total general
          total = pivot.sum { |row| row[2].to_f }.round(2)
          s.data_row(["Total general", "", total], right_align: [3])
          s.finalize(freeze_row: 4)
        end
      end
    end

    # GET /api/exportar/reporte_ops_cv?desde=&hasta=&estado=&next_day=&ciudad=
    # Devuelve Excel con 1 hoja "Data" (37 columnas — espejo del archivo
    # de referencia del cliente). Acceso restringido a admin/monitoreo/financiero.
    def reporte_ops_cv
      unless Api::ReporteOpsCvController::ROLES_PERMITIDOS.include?(current_rol.to_s)
        return render(json: {
          ok: false,
          error: "Acceso restringido — solo roles: admin, monitoreo, financiero",
        }, status: :forbidden)
      end
      send_xlsx(self.class.build_reporte_ops_cv_xlsx(
        desde_param, hasta_param, ch,
        estado:   params[:estado].to_s.strip,
        next_day: params[:next_day].to_s.strip,
        ciudad:   params[:ciudad].to_s.strip,
      ))
    rescue => e
      handle_error(e, "reporte_ops_cv")
    end

    # Builder centralizado del xlsx de Reporte OPS CV. 1 hoja "Data" con
    # las 37 columnas exactas que pidió el cliente (espejo del Excel original).
    # Reusado desde ReporteOpsCvController#enviar_email.
    def self.build_reporte_ops_cv_xlsx(desde, hasta, ch, estado: "", next_day: "", ciudad: "")
      rows = ch.query(QueriesService.format(QueriesService::Q_REPORTE_OPS_CV,
                                             fecha_desde: desde, fecha_hasta: hasta), timeout: 600)
      # Filtros opcionales en memoria
      rows = rows.select { |r| r["estado"].to_s == estado }     unless estado.empty?
      rows = rows.select { |r| r["next_day"].to_s == next_day } unless next_day.empty?
      unless ciudad.empty?
        c_low = ciudad.downcase
        rows = rows.select { |r| r["ciudad"].to_s.downcase.include?(c_low) }
      end

      headers = %w[
        uuid_booking id_parada iniciado asignado llego_al_origen salio_de_origen
        llego_donde_el_cliente id_paquete fecha_entrega_paquete descripcion
        fecha_devolucion_paquete fecha_cancelacion_paquete fecha_paquete_no_recibido
        estado programado next_day finalizado_fallido finalizo_servicio
        num_orden nombre_usuario ciudad direccion_origen direccion_de_destino
        parada_de_regreso nombre_cliente telefono_cliente duracion_espera
        duracion_servicio_copy min_tiempo_de_relanzamiento_min min_tiempo_de_servicio
        latitud longitud recuento_definido_de_uuid costo_servicio distancia_km
        llegada_a_origen_min orden_parada valor_declarado
      ].freeze

      ExcelExportService.build("Picap_Reporte_OPS_CV") do |x|
        x.add_sheet("Data") do |s|
          s.banner("Reporte Operaciones CV — Cruz Verde Pibox",
                   "Período: #{desde} → #{hasta}  ·  Registros: #{rows.size}", 37)
          s.headers(headers)
          rows.each do |r|
            s.data_row([
              r["uuid_booking"].to_s,
              r["id_parada"].to_s,
              r["iniciado"].to_s,
              r["asignado"].to_s,
              r["llego_al_origen"].to_s,
              r["salio_de_origen"].to_s,
              r["llego_donde_el_cliente"].to_s,
              r["id_paquete"].to_s,
              r["fecha_entrega_paquete"].to_s,
              r["descripcion"].to_s,
              r["fecha_devolucion_paquete"].to_s,
              r["fecha_cancelacion_paquete"].to_s,
              r["fecha_paquete_no_recibido"].to_s,
              r["estado"].to_s,
              r["programado"].to_s,
              r["next_day"].to_s,
              r["finalizado_fallido"].to_s,
              r["finalizo_servicio"].to_s,
              r["num_orden"].to_s,
              r["nombre_usuario"].to_s,
              r["ciudad"].to_s,
              r["direccion_origen"].to_s,
              r["direccion_de_destino"].to_s,
              r["parada_de_regreso"].to_s,
              r["nombre_cliente"].to_s,
              r["telefono_cliente"].to_s,
              r["duracion_espera"].to_i,
              r["duracion_servicio_copy"].to_i,
              r["min_tiempo_de_relanzamiento_min"].to_f.round(2),
              r["min_tiempo_de_servicio"].to_f.round(2),
              r["latitud"].to_f.round(3),
              r["longitud"].to_f.round(3),
              r["recuento_definido_de_uuid"].to_i,
              r["costo_servicio"].to_f.round(2),
              r["distancia_km"].to_f.round(2),
              r["llegada_a_origen_min"].to_f.round(2),
              r["orden_parada"].to_i,
              r["valor_declarado"].to_f.round(2),
            ], right_align: [27, 28, 29, 30, 33, 34, 35, 36, 37])
          end
          s.finalize(freeze_row: 4)
        end
      end
    end

    private

    # Carga la recuperación del mes anterior desde CH y delega el cálculo puro a
    # RecaudosResumenHelpers.calcular_recuperacion (que no consulta CH).
    def cargar_recuperacion_mes_anterior(desde, hasta, filtro_pais)
      mes_ant_desde, mes_ant_hasta = RecaudosResumenHelpers.rango_mes_anterior(desde, hasta)
      sql = QueriesService.format(
        QueriesService::Q_RECAUDOS_DETALLE,
        desde: mes_ant_desde, hasta: mes_ant_hasta,
        filtro_pais: filtro_pais,
        limit_filas: 20_000,
      )
      ant_rows = ch.query(sql, timeout: 300)
      driver_ids = ant_rows
        .select { |r| r["debe"].to_s == "DEBE" && r["tipo_deuda"].to_s == "PICASH" }
        .map { |r| r["driver_id"].to_s }.uniq.reject(&:empty?)
      balances = driver_ids.empty? ? {} : recaudos_balances_picash(driver_ids, Date.today.strftime("%Y-%m-%d"))
      RecaudosResumenHelpers.calcular_recuperacion(ant_rows, balances)
        .merge(periodo: "#{mes_ant_desde} → #{mes_ant_hasta}")
    rescue => e
      Rails.logger.warn("[ExportarController#cargar_recuperacion_mes_anterior] #{e.message}")
      { recuperacion: 0.0, bookings_recuperados: 0, total_perdidas_mes_ant: 0.0, periodo: "" }
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
