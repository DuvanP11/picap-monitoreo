# app/controllers/api/cedula_alertas_controller.rb
# Replica /api/cedula-alertas (api.py 2880-2956).
# Compara cédula de OCR (rekognition_metadata.fiscal_number) vs cédula del
# reporte de antecedentes (extract pwd.people_police_records). Si difieren,
# alerta — la persona registró documento ajeno.

module Api
  class CedulaAlertasController < ApplicationController
    before_action :authenticate_user!

    LIMIT_DETALLE = 5000

    PAIS_ISO = {
      "Colombia" => "CO", "Mexico" => "MX", "México" => "MX",
      "Nicaragua" => "NI", "Guatemala" => "GT",
      "Peru" => "PE", "Perú" => "PE", "Ecuador" => "EC",
    }.freeze
    PAIS_NOMBRE = {
      "CO" => "Colombia", "MX" => "México", "NI" => "Nicaragua",
      "GT" => "Guatemala", "PE" => "Perú", "EC" => "Ecuador",
    }.freeze

    # GET /api/cedula-alertas?desde=&hasta=&pais=
    def index
      desde = desde_param
      hasta = hasta_param
      pais  = pais_param
      iso   = PAIS_ISO[pais] || pais.to_s.upcase
      filtro_pais = iso.to_s.empty? ? "" : "AND p.g_country = '#{iso}'"

      # 1) Agregación: totales reales por día (sin LIMIT)
      sql_agg = QueriesService.format(
        QueriesService::Q_CEDULA_AGG,
        desde: desde, hasta: hasta, filtro_pais: filtro_pais
      )
      agg_rows = ch.query(sql_agg)
      total_real   = agg_rows.sum { |r| r["total_dia"].to_i }
      alertas_real = agg_rows.sum { |r| r["alertas_dia"].to_i }
      ok_real      = total_real - alertas_real

      trend = agg_rows.map do |r|
        td = r["total_dia"].to_i
        ad = r["alertas_dia"].to_i
        { fecha: r["dia"].to_s, alertas: ad, ok: td - ad }
      end

      # 2) Sample detallado (hasta LIMIT_DETALLE filas)
      sql_det = QueriesService.format(
        QueriesService::Q_CEDULA_DETALLE,
        desde: desde, hasta: hasta, filtro_pais: filtro_pais,
        limit_filas: LIMIT_DETALLE
      )
      rows = ch.query(sql_det).map do |r|
        fc = r["creacion_cuenta"].to_s
        r["creacion_cuenta"] = fc[0, 19]
        r["pais_nombre"] = PAIS_NOMBRE[r["pais_codigo"].to_s] || r["pais_codigo"].to_s
        r
      end

      muestra_truncada = total_real > rows.size

      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta, pais: pais,
        resumen: {
          total:            total_real,
          alertas:          alertas_real,
          ok:               ok_real,
          pct_alertas:      total_real > 0 ? (alertas_real.to_f / total_real * 100).round(1) : 0,
          pct_ok:           total_real > 0 ? (ok_real.to_f      / total_real * 100).round(1) : 0,
          muestra_size:     rows.size,
          muestra_truncada: muestra_truncada,
        },
        trend:   trend,
        alertas: rows,
      })
    rescue => e
      Rails.logger.error("[CedulaAlertasController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/cedula-alertas/exportar?desde=&hasta=&pais=
    # Puerto del Python api.py:2959-3063 (cedula_alertas_exportar).
    def exportar
      desde = desde_param
      hasta = hasta_param
      pais  = pais_param
      iso   = PAIS_ISO[pais] || pais.to_s.upcase
      filtro_pais = iso.to_s.empty? ? "" : "AND p.g_country = '#{iso}'"

      sql = QueriesService.format(
        QueriesService::Q_CEDULA_DETALLE,
        desde:       desde,
        hasta:       hasta,
        filtro_pais: filtro_pais,
        limit_filas: 20_000,
      )
      rows = ch.query(sql, timeout: 300)

      titulo_sub = "#{desde} → #{hasta}  ·  #{pais.empty? ? 'Todos los países' : pais}"
      filename_base = "alerta_cedula_#{desde}_#{hasta}"

      xlsx = ExcelExportService.build(filename_base) do |x|
        x.add_sheet("Alertas Cédula") do |s|
          s.banner("Alertas de Cédula", titulo_sub, 8)
          s.headers([
            "Creación cuenta", "ID Usuario", "Nombre", "País",
            "CC Rekognition", "CC Antecedentes", "Nombre antecedentes", "Resultado",
          ])

          # Estilos custom para la columna "Resultado"
          wb = s.ws.workbook
          style_alerta = wb.styles.add_style(
            b: true, sz: 10, fg_color: "991B1B", bg_color: "FEE2E2",
            alignment: { horizontal: :center, vertical: :center },
            border:    { style: :thin, color: "EEEEEE" },
          )
          style_ok = wb.styles.add_style(
            b: true, sz: 10, fg_color: "166534", bg_color: "DCFCE7",
            alignment: { horizontal: :center, vertical: :center },
            border:    { style: :thin, color: "EEEEEE" },
          )

          rows.each do |r|
            cc_igual    = r["cc_igual"].to_s
            pais_nombre = PAIS_NOMBRE[r["pais_codigo"].to_s] || r["pais_codigo"].to_s
            s.data_row(
              [
                r["creacion_cuenta"].to_s[0, 19],
                r["id_user"].to_s,
                r["name_user"].to_s,
                pais_nombre,
                r["rekognition_cc"].to_s,
                r["cc_antecedentes"].to_s,
                r["nombre_antecedentes"].to_s,
                cc_igual.upcase,
              ],
              cell_styles: { 8 => (cc_igual == "alerta" ? style_alerta : style_ok) },
            )
          end

          s.finalize(freeze_row: 4)
        end
      end

      send_xlsx(xlsx)
    rescue => e
      Rails.logger.error("[CedulaAlertasController#exportar] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def send_xlsx(xlsx)
      send_data xlsx[:data], type: xlsx[:mimetype],
                filename: xlsx[:filename], disposition: "attachment"
    end
  end
end
