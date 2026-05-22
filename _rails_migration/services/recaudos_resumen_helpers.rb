# app/services/recaudos_resumen_helpers.rb
# Helpers compartidos para el "Resumen Ejecutivo" de Recaudos.
# Usado por:
#   - Api::ExportarController#recaudos     (descarga directa del xlsx)
#   - Api::RecaudosController#enviar_email (xlsx + HTML por mail)
#
# Mantiene la lógica pura (no toca ClickHouse ni ActionController). El cálculo
# que requiere queries CH (recuperacion_calcular) se hace en el controller y
# se le pasa las filas + balances ya cargados.

module RecaudosResumenHelpers
  MESES_ES = %w[
    ENERO FEBRERO MARZO ABRIL MAYO JUNIO
    JULIO AGOSTO SEPTIEMBRE OCTUBRE NOVIEMBRE DICIEMBRE
  ].freeze

  CON_DIFERENCIA_STATES = ["DEBE", "SIN RECAUDO"].freeze

  module_function

  # Devuelve [mes_ant_desde, mes_ant_hasta] como YYYY-MM-DD.
  # - Si el rango actual cubre un mes natural completo, devuelve el mes anterior
  #   natural completo (1° al último día).
  # - Si es un rango parcial, corre el mismo rango 1 mes atrás.
  def rango_mes_anterior(desde, hasta)
    d = Date.parse(desde.to_s)
    h = Date.parse(hasta.to_s)
    if d.day == 1 && h == Date.new(d.year, d.month, -1)
      prev = d.prev_month
      return [prev.strftime("%Y-%m-%d"), Date.new(prev.year, prev.month, -1).strftime("%Y-%m-%d")]
    end
    [d.prev_month.strftime("%Y-%m-%d"), h.prev_month.strftime("%Y-%m-%d")]
  rescue
    [(Date.today - 60).strftime("%Y-%m-%d"), (Date.today - 30).strftime("%Y-%m-%d")]
  end

  # Nombre del mes en español para `desde` (YYYY-MM-DD).
  def mes_label(desde)
    d = Date.parse(desde.to_s)
    MESES_ES[d.month - 1] || d.strftime("%B").upcase
  rescue
    "PERÍODO"
  end

  # Nombre del mes ANTERIOR al rango (para la celda "RECUPERACIÓN <MES>").
  def mes_anterior_label(desde)
    d = Date.parse(desde.to_s)
    MESES_ES[d.prev_month.month - 1] || ""
  rescue
    ""
  end

  # Cálculo puro de recuperación a partir de filas del mes anterior + balances
  # de pilotos. NO consulta ClickHouse — eso es responsabilidad del controller.
  #
  # @param ant_rows [Array<Hash>] filas de Q_RECAUDOS_DETALLE del mes anterior
  # @param balances [Hash{String=>Hash}] { driver_id => {actual: Float, ...} }
  # @return [Hash] { recuperacion:, bookings_recuperados:, total_perdidas_mes_ant: }
  def calcular_recuperacion(ant_rows, balances)
    debe_rows = ant_rows.select { |r| r["debe"].to_s == "DEBE" && r["tipo_deuda"].to_s == "PICASH" }
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
    }
  end

  # Renderiza la hoja "Resumen Ejecutivo" en un SheetHelper de ExcelExportService.
  # Genera: logo Pibox + título + 3 tablas (período/recaudo/pérdidas, perdida-
  # recuperacion-total, pivot por compañía).
  #
  # @param s [ExcelExportService::SheetHelper]
  # @param rows [Array<Hash>] todas las filas del rango (Picash + Ida y Vuelta enriquecidas)
  # @param desde, hasta [String]
  # @param recup [Hash] resultado de calcular_recuperacion
  # @param logo_path [String, nil] ruta absoluta al PNG del logo
  def render_resumen_ejecutivo(s, rows, desde, hasta, recup, logo_path: nil)
    mes_actual_lbl = mes_label(desde)
    mes_ant_lbl    = mes_anterior_label(desde)

    total_recaudo = rows.sum { |r| r["total_positivo"].to_f }.round(2)
    perdidas      = rows.select { |r| CON_DIFERENCIA_STATES.include?(r["estado_real"].to_s) }
                       .sum { |r| r["recaudo_neto"].to_f.abs }.round(2)
    pct_perdidas  = total_recaudo > 0 ? -(perdidas / total_recaudo) : 0.0

    pendientes_por_cia = rows
      .select { |r| CON_DIFERENCIA_STATES.include?(r["estado_real"].to_s) }
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
    pendientes_con_pct = pendientes_por_cia.map do |h|
      h.merge(pct: total_pendientes != 0 ? (h[:pendiente] / total_pendientes) : 0.0)
    end

    s.set_column_widths(22, 18, 18, 18, 16)

    if logo_path && File.exist?(logo_path)
      s.add_image(logo_path, row: 1, col: 1, width: 160, height: 64)
      s.blank_rows(3)
    else
      s.ws.add_row(["pibox"], height: 40)
      s.ws.merge_cells("A1:B2")
      s.instance_variable_set(:@current_row, 4)
      s.blank_rows(1)
    end

    s.report_main_title("INFORME DE PÉRDIDAS EN LOS RECAUDOS", span: 5)

    s.report_table(
      ["PERÍODO", "RECAUDO", "PERDIDAS", "% PERDIDAS"],
      [[mes_actual_lbl, total_recaudo, -perdidas, pct_perdidas]],
      value_styles: [:text, :money, :money_neg, :pct],
    )

    total_neto = -perdidas + recup[:recuperacion]
    s.report_table(
      ["PERDIDA #{mes_actual_lbl}", "RECUPERACIÓN #{mes_ant_lbl}", "TOTAL PERDIDAS"],
      [[-perdidas, recup[:recuperacion], total_neto]],
      value_styles: [:money_neg, :money, :money_neg],
    )

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

  # Hoja "Detalle" estándar (Picash o Ida y Vuelta). Comparte el formato entre
  # el export directo y el adjunto del email.
  DETALLE_HEADERS = [
    "Fecha servicio", "Booking ID", "Piloto ID", "Piloto Nombre",
    "Comercio ID", "Comercio Nombre", "Ciudad", "Moneda",
    "Valor servicio", "Recaudo +", "Recaudo −", "Recaudo neto",
    "Saldo actual", "Saldo fin de mes", "Estado booking", "Estado real",
  ].freeze
  DETALLE_RIGHT_ALIGN = [9, 10, 11, 12, 13, 14].freeze

  def render_detalle_sheet(s, sheet_name, sheet_rows, desde, hasta)
    s.banner(sheet_name, "Período: #{desde} → #{hasta}  ·  Registros: #{sheet_rows.size}", 15)
    s.headers(DETALLE_HEADERS)
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
      ], right_align: DETALLE_RIGHT_ALIGN)
    end
    s.finalize(freeze_row: 4)
    s
  end
end
