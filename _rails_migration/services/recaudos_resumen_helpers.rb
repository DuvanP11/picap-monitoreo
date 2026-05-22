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
  # Genera: título morado + 3 tablas (período/recaudo/pérdidas, perdida-
  # recuperacion-total, pivot por compañía) + logo Pibox sobre el título.
  #
  # v3.2 (May 2026): rediseño visual completo. Banner morado, headers blancos
  # bold sobre fondo morado, valores monetarios en formato COP sin decimales,
  # fila de total destacada en morado pleno. El logo se agrega AL FINAL del
  # render para evitar interferencias con los estilos de celdas.
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

    total_pendientes   = pendientes_por_cia.sum { |h| h[:pendiente] }
    pendientes_con_pct = pendientes_por_cia.map do |h|
      h.merge(pct: total_pendientes != 0 ? (h[:pendiente] / total_pendientes) : 0.0)
    end

    # Anchos: A más ancho (etiquetas largas + nombres de compañía), resto medianos.
    s.set_column_widths(32, 22, 22, 22, 18)

    # Reservar 3 filas en blanco arriba para colocar el logo al final.
    s.blank_rows(3)

    # Banner principal: "INFORME DE PÉRDIDAS EN LOS RECAUDOS"
    s.report_main_title("INFORME DE PÉRDIDAS EN LOS RECAUDOS", span: 5)

    # Tabla 1: período | recaudo | pérdidas | % pérdidas
    s.report_table(
      ["PERÍODO", "RECAUDO", "PERDIDAS", "% PERDIDAS"],
      [[mes_actual_lbl, total_recaudo, -perdidas, pct_perdidas]],
      value_styles: [:text, :money, :money_neg, :pct],
    )

    # Tabla 2: pérdida mes | recuperación mes ant | total
    total_neto = -perdidas + recup[:recuperacion]
    s.report_table(
      ["PERDIDA #{mes_actual_lbl}", "RECUPERACIÓN #{mes_ant_lbl}", "TOTAL PERDIDAS"],
      [[-perdidas, recup[:recuperacion], total_neto]],
      value_styles: [:money_neg, :money, :money_neg],
    )

    # Tabla 3: pivot por compañía (con fila de total destacada)
    if pendientes_con_pct.any?
      s.report_table_with_total(
        ["COMPAÑÍA", "Ciudad", "Suma de PENDIENTE", "PORCENTAJE"],
        pendientes_con_pct.map { |h| [h[:comercio], h[:ciudad], h[:pendiente], h[:pct]] },
        total_row: ["Total general", "", total_pendientes, 1.0],
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

    # Logo al final, sobre las filas vacías reservadas al inicio. Se agrega
    # acá (no al principio) para evitar que add_image interfiera con el
    # rendering de los estilos de las celdas.
    if logo_path && File.exist?(logo_path)
      s.add_image(logo_path, row: 1, col: 1, width: 160, height: 64)
    end

    s
  end

  # Hoja "Detalle" estándar (Picash o Ida y Vuelta). Comparte el formato entre
  # el export directo y el adjunto del email.
  # v3.2: columnas monetarias en formato COP ("$ #,##0", sin decimales).
  DETALLE_HEADERS = [
    "Fecha servicio", "Booking ID", "Piloto ID", "Piloto Nombre",
    "Comercio ID", "Comercio Nombre", "Ciudad", "Moneda",
    "Valor servicio", "Recaudo +", "Recaudo −", "Recaudo neto",
    "Saldo actual", "Saldo fin de mes", "Estado booking", "Estado real",
  ].freeze
  # Columnas monetarias (1-based): 9..14 = Valor servicio, Recaudo +, Recaudo −,
  # Recaudo neto, Saldo actual, Saldo fin de mes.
  DETALLE_MONEY_COLS = [9, 10, 11, 12, 13, 14].freeze

  def render_detalle_sheet(s, sheet_name, sheet_rows, desde, hasta)
    s.banner(sheet_name, "Período: #{desde} → #{hasta}  ·  Registros: #{sheet_rows.size}", 16)
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
        r["valor_servicio"].to_f,
        r["total_positivo"].to_f,
        r["total_negativo"].to_f,
        r["recaudo_neto"].to_f,
        ba.nil? ? nil : ba.to_f,
        bf.nil? ? nil : bf.to_f,
        r["debe"].to_s,
        r["estado_real"].to_s,
      ], money_cols: DETALLE_MONEY_COLS)
    end
    s.finalize(freeze_row: 4)
    s
  end
end
