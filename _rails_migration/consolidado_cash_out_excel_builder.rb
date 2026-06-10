# app/services/consolidado_cash_out_excel_builder.rb
# v3.3.56 — Excel "Consolidado Cash Out" con 6 hojas:
#   1. Resumen Total       — KPI cards: Pilotos, Pasajeros, Empleados, Clientes, GRAN TOTAL
#   2. Resumen Tipo        — pivot Tipo × Jornada
#   3. Resumen Desglosado  — pivot Tipo_de_Desglosado × Jornada
#   4. Resumen Clientes    — pivot Cliente × Jornada
#   5. Detallado           — Pilotos / Pasajeros / Empleados (sin clientes)
#   6. Clientes Detalle    — solo retiros de compañías

require "caxlsx"

class ConsolidadoCashOutExcelBuilder
  COLORS = {
    morado:    "5B21B6",
    morado_dk: "3B0764",
    morado_lt: "EDE9F5",
    white:     "FFFFFF",
    azul:      "3B82F6",
    azul_lt:   "DBEAFE",
    verde:     "16A34A",
    verde_lt:  "DCFCE7",
    naranja:   "F97316",
    naranja_lt:"FED7AA",
    violeta:   "7C3AED",
    violeta_lt:"E9D5FF",
    gris_hdr:  "4B5563",
    border:    "B0B0B0",
  }.freeze

  COP_FMT = '_-"$"* #,##0_-;[Red]-"$"* #,##0_-;_-"$"* "-"_-;_-@_-'.freeze

  def self.build(desde:, hasta:, result:, rows:)
    new(desde, hasta, result, rows).call
  end

  def initialize(desde, hasta, result, rows)
    @desde, @hasta = desde, hasta
    @result = result
    @rows = rows
  end

  def call
    pkg = Axlsx::Package.new
    pkg.use_shared_strings = true
    wb = pkg.workbook
    init_styles(wb)

    write_resumen_total(wb)
    write_pivot_sheet(wb, "Resumen Tipo",       @result[:resumen_tipo],       "Tipo")
    write_pivot_sheet(wb, "Resumen Desglosado", @result[:resumen_desglosado], "Tipo Desglosado")
    write_pivot_sheet(wb, "Resumen Clientes",   @result[:resumen_clientes],   "Cliente / Compañía")
    write_detallado(wb, "Detallado",        @result[:detallado],        cols_detallado)
    write_detallado(wb, "Clientes Detalle", @result[:clientes_detalle], cols_clientes)

    pkg.to_stream.read
  end

  private

  def init_styles(wb)
    s = wb.styles
    @s = {
      titulo:    s.add_style(b: true, sz: 16, fg_color: COLORS[:white], bg_color: COLORS[:morado],     alignment: { horizontal: :left, vertical: :center, indent: 1 }),
      subtitulo: s.add_style(sz: 11, fg_color: COLORS[:white], bg_color: COLORS[:morado_dk], alignment: { horizontal: :left, vertical: :center, indent: 1 }),
      hdr:       s.add_style(b: true, fg_color: COLORS[:white], bg_color: COLORS[:gris_hdr], alignment: { horizontal: :center, vertical: :center, wrap_text: true }, border: { style: :thin, color: COLORS[:border] }),
      label:     s.add_style(alignment: { horizontal: :left, vertical: :center, indent: 1 }, border: { style: :thin, color: COLORS[:border] }),
      money:     s.add_style(format_code: COP_FMT, alignment: { horizontal: :right, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      total_label: s.add_style(b: true, bg_color: COLORS[:morado_lt], alignment: { horizontal: :left, vertical: :center, indent: 1 }, border: { style: :thin, color: COLORS[:border] }),
      total_money: s.add_style(b: true, bg_color: COLORS[:morado_lt], format_code: COP_FMT, alignment: { horizontal: :right, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),

      # Resumen Total KPI cards
      card_pilotos:   s.add_style(b: true, sz: 14, bg_color: COLORS[:azul_lt],    fg_color: "1E3A8A", alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      card_pasajero:  s.add_style(b: true, sz: 14, bg_color: COLORS[:verde_lt],   fg_color: "065F46", alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      card_empleado:  s.add_style(b: true, sz: 14, bg_color: COLORS[:naranja_lt], fg_color: "9A3412", alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      card_cliente:   s.add_style(b: true, sz: 14, bg_color: COLORS[:violeta_lt], fg_color: "5B21B6", alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      card_total:     s.add_style(b: true, sz: 16, bg_color: COLORS[:morado],     fg_color: COLORS[:white], alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      card_money_b:   s.add_style(b: true, sz: 14, format_code: COP_FMT, bg_color: COLORS[:azul_lt],    alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      card_money_g:   s.add_style(b: true, sz: 14, format_code: COP_FMT, bg_color: COLORS[:verde_lt],   alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      card_money_o:   s.add_style(b: true, sz: 14, format_code: COP_FMT, bg_color: COLORS[:naranja_lt], alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      card_money_v:   s.add_style(b: true, sz: 14, format_code: COP_FMT, bg_color: COLORS[:violeta_lt], alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      card_money_p:   s.add_style(b: true, sz: 16, format_code: COP_FMT, bg_color: COLORS[:morado],     fg_color: COLORS[:white], alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
    }
  end

  def cols_detallado
    [["Fecha", 20], ["Jornada", 14], ["Tipo Usuario", 14], ["Tipo", 22], ["Tipo Desglosado", 24], ["Valor", 16]]
  end

  def cols_clientes
    [["Fecha", 20], ["Jornada", 14], ["Cliente / Compañía", 32], ["Tipo", 22], ["Tipo Desglosado", 24], ["Valor", 16]]
  end

  def write_resumen_total(wb)
    wb.add_worksheet(name: "Resumen Total") do |ws|
      ws.column_widths(28, 28, 28, 28, 28)

      ws.add_row(["Consolidado Cash Out — Resumen Total", nil, nil, nil, nil],
                 style: Array.new(5, @s[:titulo]))
      ws.rows.last.height = 30
      ws.merge_cells("A1:E1")

      ws.add_row(["Período: #{@desde} → #{@hasta}", nil, nil, nil, nil],
                 style: Array.new(5, @s[:subtitulo]))
      ws.rows.last.height = 22
      ws.merge_cells("A2:E2")

      ws.add_row([])

      t = @result[:totales]
      ws.add_row(["🛵 PILOTOS", "🚕 PASAJEROS", "👤 EMPLEADOS", "🏢 CLIENTES", "💰 GRAN TOTAL"],
                 style: [@s[:card_pilotos], @s[:card_pasajero], @s[:card_empleado], @s[:card_cliente], @s[:card_total]])
      ws.rows.last.height = 28
      ws.add_row([t[:pilotos], t[:pasajeros], t[:empleados], t[:clientes], t[:gran_total]],
                 style: [@s[:card_money_b], @s[:card_money_g], @s[:card_money_o], @s[:card_money_v], @s[:card_money_p]])
      ws.rows.last.height = 32
    end
  end

  def write_pivot_sheet(wb, sheet_name, pivot, label_header)
    wb.add_worksheet(name: sheet_name) do |ws|
      headers   = [label_header] + (pivot[:jornadas] || []) + ["Total"]
      ws.column_widths(*([32] + Array.new(headers.size - 1, 18)))

      ws.add_row(["#{sheet_name} — #{@desde} → #{@hasta}"] + Array.new(headers.size - 1, nil),
                 style: Array.new(headers.size, @s[:titulo]))
      ws.rows.last.height = 28
      ws.merge_cells(ws.rows.last.cells.first, ws.rows.last.cells.last)

      ws.add_row([])

      ws.add_row(headers, style: Array.new(headers.size, @s[:hdr]))
      ws.rows.last.height = 24

      pivot[:rows].each do |r|
        ws.add_row(
          [r["label"]] + (pivot[:jornadas].map { |j| r[j] }) + [r["Total"]],
          style: [@s[:label]] + Array.new(headers.size - 1, @s[:money]),
        )
      end

      total = pivot[:totals]
      ws.add_row(
        [total["label"]] + (pivot[:jornadas].map { |j| total[j] }) + [total["Total"]],
        style: [@s[:total_label]] + Array.new(headers.size - 1, @s[:total_money]),
      )
    end
  end

  def write_detallado(wb, sheet_name, rows_data, cols)
    wb.add_worksheet(name: sheet_name) do |ws|
      ws.column_widths(*cols.map { |_, w| w })
      ws.add_row(cols.map { |c, _| c }, style: Array.new(cols.size, @s[:hdr]))
      ws.rows.last.height = 24

      rows_data.each do |r|
        cells = cols.map { |c, _| c == "Valor" ? r["Valor"].to_f : r[map_col(c)].to_s }
        styles = cols.map { |c, _| c == "Valor" ? @s[:money] : @s[:label] }
        ws.add_row(cells, style: styles)
      end

      ws.auto_filter = "A1:#{('A'.ord + cols.size - 1).chr}#{rows_data.size + 1}" if rows_data.any?
      ws.sheet_view.pane do |pane|
        pane.state       = :frozen
        pane.y_split     = 1
        pane.active_pane = :bottom_right
      end
    end
  end

  def map_col(header)
    {
      "Fecha"               => "Fecha",
      "Jornada"             => "Jornada",
      "Tipo Usuario"        => "Tipo_de_Usuario",
      "Tipo"                => "Tipo",
      "Tipo Desglosado"     => "Tipo_de_Desglosado",
      "Valor"               => "Valor",
      "Cliente / Compañía"  => "Cliente_Nombre",
    }[header] || header
  end
end
