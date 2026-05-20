# app/controllers/api/auditoria_controller.rb
# Auditoría comercial — Comisiones + Créditos (api.py 4047-4395).
# Comparte la query Q_AUDITORIA_BASE (companies × fare_configs).
# Diferencia: cada endpoint clasifica con reglas distintas.

module Api
  class AuditoriaController < ApplicationController
    before_action :authenticate_user!

    # GET /api/auditoria/comisiones
    def comisiones
      rows = run_auditoria
      filtrar_por_id!(rows, "company")
      resumen = resumen_alertas(rows, :alertas_comision)
      alertas = rows.reject { |r| r[:ok_comision] }.sort_by { |r| -r[:alertas_comision].size }
      render json: limpiar({
        ok: true,
        desde: desde_param, hasta: hasta_param,
        resumen: resumen,
        alertas: alertas.first(500),
        total_filas: rows.size,
      })
    rescue => e
      Rails.logger.error("[AuditoriaController#comisiones] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/auditoria/creditos
    def creditos
      rows = run_auditoria
      filtrar_por_id!(rows, "company")
      resumen = resumen_alertas(rows, :alertas_credito)
      alertas = rows.reject { |r| r[:ok_credito] }.sort_by { |r| -(r[:credit] || 0).abs }
      dist = {
        credit_9999: rows.count { |r| r[:credit] == 9999 },
        credit_0:    rows.count { |r| r[:credit] == 0 },
        credit_pos:  rows.count { |r| (r[:credit] || 0) > 0 && r[:credit] != 9999 },
        v_total_credito: rows.reject { |r| [0, 9999].include?(r[:credit]) }.sum { |r| r[:credit] || 0 }.round(2),
      }
      render json: limpiar({
        ok: true,
        desde: desde_param, hasta: hasta_param,
        resumen: resumen,
        alertas: alertas.first(500),
        dist_credito: dist,
        total_filas: rows.size,
      })
    rescue => e
      Rails.logger.error("[AuditoriaController#creditos] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/auditoria/exportar?desde=&hasta=&moneda=&company_id=&tarifa_id=&last_desde=&last_hasta=
    # Puerto del Python api.py:4751-4841 (auditoria_exportar). 2 hojas: Comisiones + Créditos.
    def exportar
      rows = run_auditoria
      filtrar_por_id!(rows, "company")
      desde = desde_param
      hasta = hasta_param

      xlsx = ExcelExportService.build("Auditoria_Pibox") do |x|
        # ── Hoja 1: Comisiones ──
        x.add_sheet("Comisiones") do |s|
          s.banner("Auditoría Pibox — Comisiones",
                   "#{desde} → #{hasta}  ·  Total filas: #{rows.size}", 13)
          s.headers([
            "Estado", "Company ID", "Tarifa ID", "Línea de negocio", "KAM",
            "Tipo servicio", "Ciudad", "Moneda", "Comisión (%)",
            "Utilidad corp. (%)", "Crédito", "Alertas", "Último servicio",
          ])

          wb = s.ws.workbook
          style_alerta = wb.styles.add_style(
            b: true, sz: 10, fg_color: "991B1B", bg_color: "FEE2E2",
            alignment: { horizontal: :center, vertical: :center, wrap_text: true },
            border: { style: :thin, color: "EEEEEE" }
          )
          style_ok = wb.styles.add_style(
            b: true, sz: 10, fg_color: "166534", bg_color: "DCFCE7",
            alignment: { horizontal: :center, vertical: :center },
            border: { style: :thin, color: "EEEEEE" }
          )

          rows.each do |r|
            alertas_txt = r[:alertas_comision].join(", ")
            s.data_row(
              [
                r[:estado], r[:id_company], r[:tarifa_id], r[:linea_de_negocio],
                r[:name_manager], r[:type_service], r[:ciudad], r[:moneda],
                r[:comission], r[:utilidad_corporativa], r[:credit],
                alertas_txt, r[:last_service],
              ],
              cell_styles: { 12 => (r[:ok_comision] ? style_ok : style_alerta) },
              right_align: [9, 10, 11],
            )
          end
          s.finalize(freeze_row: 4)
        end

        # ── Hoja 2: Créditos ──
        x.add_sheet("Créditos", tab_color: "7C3AED") do |s|
          s.banner("Auditoría Pibox — Créditos",
                   "#{desde} → #{hasta}  ·  Total filas: #{rows.size}", 13)
          s.headers([
            "Estado", "Company ID", "Tarifa ID", "Línea de negocio", "KAM",
            "Tipo servicio", "Ciudad", "Moneda", "Crédito",
            "Utilidad corp. (%)", "Comisión (%)", "Alertas crédito", "Último servicio",
          ])

          wb = s.ws.workbook
          style_alerta = wb.styles.add_style(
            b: true, sz: 10, fg_color: "991B1B", bg_color: "FEE2E2",
            alignment: { horizontal: :center, vertical: :center, wrap_text: true },
            border: { style: :thin, color: "EEEEEE" }
          )
          style_ok = wb.styles.add_style(
            b: true, sz: 10, fg_color: "166534", bg_color: "DCFCE7",
            alignment: { horizontal: :center, vertical: :center },
            border: { style: :thin, color: "EEEEEE" }
          )

          rows.each do |r|
            alertas_txt = r[:alertas_credito].join(", ")
            s.data_row(
              [
                r[:estado], r[:id_company], r[:tarifa_id], r[:linea_de_negocio],
                r[:name_manager], r[:type_service], r[:ciudad], r[:moneda],
                r[:credit], r[:utilidad_corporativa], r[:comission],
                alertas_txt, r[:last_service],
              ],
              cell_styles: { 12 => (r[:ok_credito] ? style_ok : style_alerta) },
              right_align: [9, 10, 11],
            )
          end
          s.finalize(freeze_row: 4)
        end
      end

      send_xlsx(xlsx)
    rescue => e
      Rails.logger.error("[AuditoriaController#exportar] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def send_xlsx(xlsx)
      send_data xlsx[:data], type: xlsx[:mimetype],
                filename: xlsx[:filename], disposition: "attachment"
    end

    def run_auditoria
      filtros = QueriesService.auditoria_filtros(
        company_id: params[:company_id].to_s.strip,
        tarifa_id:  params[:tarifa_id].to_s.strip,
        moneda:     params[:moneda].to_s,
        anti_test:  true,
        last_desde: params[:last_desde].to_s,
        last_hasta: params[:last_hasta].to_s,
      )
      sql = QueriesService.format(
        QueriesService::Q_AUDITORIA_BASE,
        desde: desde_param, hasta: hasta_param, **filtros
      )
      raw_rows = ch.query(sql)

      raw_rows.map do |r|
        row = {}
        # Numéricos
        %w[base_fare minimum_fare distance_fare hour_fare extra_stop_fare package_fare
           hour_base_fare hour_standby_fare comission utilidad_corporativa credit
           valor_declarado].each do |k|
          row[k.to_sym] = (r[k] || 0).to_f.round(4)
        end
        # Strings
        %w[estado id_company linea_de_negocio commercial_manager name_manager
           tarifa_id type_service ciudad moneda].each do |k|
          row[k.to_sym] = r[k].to_s
        end
        row[:last_service] = r["last_service"].to_s[0, 16]
        row[:name_manager] = "Sin comercial" if row[:name_manager].strip.empty?

        row[:alertas_comision] = clasificar_comision(row)
        row[:alertas_credito]  = clasificar_credito(row)
        row[:ok_comision]      = row[:alertas_comision] == ["Correcto"]
        row[:ok_credito]       = row[:alertas_credito]  == ["Correcto"]
        row
      end
    end

    # Reglas de comisiones (paridad Python _clasificar_comision)
    def clasificar_comision(r)
      comision = r[:comission].to_f
      utilidad = r[:utilidad_corporativa].to_f
      credit   = r[:credit].to_f
      alertas  = []
      return ["Correcto"] if comision == 0 && utilidad == 0 && credit == 0
      alertas << "Utilidad errada"             if comision > 0 && comision < 2
      alertas << "Sin crédito y con utilidad"  if credit == 0 && utilidad > 0
      alertas << "Con crédito y sin utilidad"  if credit > 0 && utilidad == 0
      alertas << "Utilidades diferentes"       if (comision - utilidad).abs > 0.01 && comision > 0 && utilidad > 0
      alertas.empty? ? ["Correcto"] : alertas
    end

    # Reglas de créditos (paridad Python _clasificar_credito)
    def clasificar_credito(r)
      credit   = r[:credit].to_f
      utilidad = r[:utilidad_corporativa].to_f
      alertas  = []
      alertas << "Validación de crédito"      if credit == 9999
      alertas << "Sin crédito con utilidad"   if credit == 0 && utilidad > 0
      alertas << "Con crédito sin utilidad"   if credit > 0 && utilidad == 0
      alertas.empty? ? ["Correcto"] : alertas
    end

    # Resumen estadístico (replica _resumen_alertas del Python)
    def resumen_alertas(rows, campo)
      total    = rows.size
      correct  = rows.count { |r| r[campo] == ["Correcto"] }
      con_err  = total - correct

      dist = Hash.new(0)
      rows.each { |r| r[campo].each { |a| dist[a] += 1 unless a == "Correcto" } }

      kam_map = Hash.new { |h, k| h[k] = { total: 0, error: 0, correctos: 0 } }
      rows.each do |r|
        kam = r[:name_manager].to_s.empty? ? "Sin comercial" : r[:name_manager]
        kam_map[kam][:total] += 1
        if r[campo] == ["Correcto"]
          kam_map[kam][:correctos] += 1
        else
          kam_map[kam][:error] += 1
        end
      end
      por_kam = kam_map.sort_by { |_, v| -v[:error] }.first(20).map { |k, v| v.merge(kam: k) }

      ciudad_map       = Hash.new(0)
      ciudad_error_map = Hash.new(0)
      rows.each do |r|
        c = r[:ciudad].to_s.empty? ? "Sin ciudad" : r[:ciudad]
        ciudad_map[c] += 1
        ciudad_error_map[c] += 1 if r[campo] != ["Correcto"]
      end
      por_ciudad = ciudad_map.sort_by { |_, n| -n }.first(20).map do |c, n|
        { ciudad: c, total: n, error: ciudad_error_map[c], correctos: n - ciudad_error_map[c] }
      end

      {
        total:        total,
        correctos:    correct,
        con_error:    con_err,
        pct_error:    total > 0 ? (con_err.to_f / total * 100).round(1) : 0,
        distribucion: dist.sort_by { |_, v| -v }.map { |k, v| { alerta: k, count: v } },
        por_kam:      por_kam,
        por_ciudad:   por_ciudad,
      }
    end

    def filtrar_por_id!(rows, default_tipo)
      q_id   = params[:q].to_s.strip
      return if q_id.length < 4
      q_low  = q_id.downcase
      q_tipo = params[:tipo].to_s.strip
      q_tipo = default_tipo unless %w[booking company tarifa].include?(q_tipo)
      campo = { "booking" => :id_company, "company" => :id_company, "tarifa" => :tarifa_id }[q_tipo]
      rows.select! { |r| r[campo].to_s.downcase.include?(q_low) }
    end
  end
end
