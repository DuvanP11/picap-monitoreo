# app/services/validador_dispersiones_excel_builder.rb
# v3.3.52 — Excel "Validador de Dispersiones" (2 hojas).
#
# Hojas:
#   1. "Resumen"    — KPIs por estado + filtros aplicados.
#   2. "Detalle"    — todas las transacciones (sin LIMIT 5k del UI).

require "caxlsx"

class ValidadorDispersionesExcelBuilder
  COLORS = {
    morado:        "5B21B6",
    morado_dk:     "3B0764",
    morado_lt:     "EDE9F5",
    white:         "FFFFFF",
    verde:         "16A34A",
    rojo:          "DC2626",
    amber:         "F59E0B",
    gris_hdr:      "4B5563",
    border:        "B0B0B0",
    bg_pago:       "DCFCE7",
    bg_aprobado:   "DCFCE7",
    bg_reembolso:  "FEE2E2",
    bg_pendiente:  "FEF3C7",
    bg_otro:       "F3F4F6",
  }.freeze

  COP_FMT = '_-"$"* #,##0_-;[Red]-"$"* #,##0_-;_-"$"* "-"_-;_-@_-'.freeze
  DT_FMT  = "yyyy-mm-dd hh:mm:ss".freeze

  def self.build(desde:, hasta:, filtros:, rows:, stats:)
    new(desde, hasta, filtros, rows, stats).call
  end

  def initialize(desde, hasta, filtros, rows, stats)
    @desde, @hasta = desde, hasta
    @filtros = filtros
    @rows = rows
    @stats = stats
  end

  def call
    pkg = Axlsx::Package.new
    pkg.use_shared_strings = true
    wb = pkg.workbook

    init_styles(wb)

    write_resumen(wb)
    write_detalle(wb)

    pkg.to_stream.read
  end

  private

  def init_styles(wb)
    s = wb.styles
    @s = {
      titulo: s.add_style(
        b: true, sz: 16, fg_color: COLORS[:white], bg_color: COLORS[:morado],
        alignment: { horizontal: :left, vertical: :center, indent: 1 },
      ),
      subtitulo: s.add_style(
        sz: 11, fg_color: COLORS[:white], bg_color: COLORS[:morado_dk],
        alignment: { horizontal: :left, vertical: :center, indent: 1 },
      ),
      label_filter: s.add_style(b: true, sz: 11, alignment: { horizontal: :right, vertical: :center }),
      value_filter: s.add_style(sz: 11, alignment: { horizontal: :left, vertical: :center }),
      kpi_label: s.add_style(b: true, sz: 11, alignment: { horizontal: :left, vertical: :center }),
      kpi_cnt:   s.add_style(b: true, sz: 12, format_code: "#,##0", alignment: { horizontal: :right, vertical: :center }),
      kpi_val:   s.add_style(b: true, sz: 12, format_code: COP_FMT, alignment: { horizontal: :right, vertical: :center }),
      kpi_pago_bg:      s.add_style(bg_color: COLORS[:bg_pago],      border: { style: :thin, color: COLORS[:border] }),
      kpi_aprobado_bg:  s.add_style(bg_color: COLORS[:bg_aprobado],  border: { style: :thin, color: COLORS[:border] }),
      kpi_reembolso_bg: s.add_style(bg_color: COLORS[:bg_reembolso], border: { style: :thin, color: COLORS[:border] }),
      kpi_pendiente_bg: s.add_style(bg_color: COLORS[:bg_pendiente], border: { style: :thin, color: COLORS[:border] }),
      kpi_otro_bg:      s.add_style(bg_color: COLORS[:bg_otro],      border: { style: :thin, color: COLORS[:border] }),
      total_label:      s.add_style(b: true, sz: 13, bg_color: COLORS[:morado_lt], alignment: { horizontal: :left, vertical: :center, indent: 1 }, border: { style: :thin, color: COLORS[:border] }),
      total_cnt:        s.add_style(b: true, sz: 13, format_code: "#,##0", bg_color: COLORS[:morado_lt], alignment: { horizontal: :right, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      total_val:        s.add_style(b: true, sz: 13, format_code: COP_FMT, bg_color: COLORS[:morado_lt], alignment: { horizontal: :right, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),

      hdr_data: s.add_style(
        b: true, fg_color: COLORS[:white], bg_color: COLORS[:gris_hdr],
        alignment: { horizontal: :center, vertical: :center, wrap_text: true },
        border: { style: :thin, color: COLORS[:border] },
      ),
      cell_str:  s.add_style(alignment: { vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      cell_dt:   s.add_style(format_code: DT_FMT, alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      cell_num:  s.add_style(format_code: COP_FMT, alignment: { horizontal: :right, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      cell_int:  s.add_style(format_code: "0", alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      estado_pago:      s.add_style(b: true, fg_color: "065F46", bg_color: COLORS[:bg_pago],      alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      estado_aprobado:  s.add_style(b: true, fg_color: "065F46", bg_color: COLORS[:bg_aprobado],  alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      estado_reembolso: s.add_style(b: true, fg_color: "991B1B", bg_color: COLORS[:bg_reembolso], alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      estado_pendiente: s.add_style(b: true, fg_color: "92400E", bg_color: COLORS[:bg_pendiente], alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
      estado_otro:      s.add_style(b: true, fg_color: "4B5563", bg_color: COLORS[:bg_otro],      alignment: { horizontal: :center, vertical: :center }, border: { style: :thin, color: COLORS[:border] }),
    }
  end

  def write_resumen(wb)
    wb.add_worksheet(name: "Resumen") do |ws|
      ws.column_widths(28, 18, 22, 22, 22, 22)

      ws.add_row(["Validador de Dispersiones", nil, nil, nil, nil, nil],
                 style: [@s[:titulo], @s[:titulo], @s[:titulo], @s[:titulo], @s[:titulo], @s[:titulo]])
      ws.rows.last.height = 28
      ws.merge_cells("A1:F1")

      ws.add_row(["Período: #{@desde} → #{@hasta}", nil, nil, nil, nil, nil],
                 style: [@s[:subtitulo], @s[:subtitulo], @s[:subtitulo], @s[:subtitulo], @s[:subtitulo], @s[:subtitulo]])
      ws.rows.last.height = 22
      ws.merge_cells("A2:F2")

      ws.add_row([])

      # Filtros aplicados
      filt_pares = [
        ["Moneda",            @filtros[:moneda].to_s.empty? ? "(todas)" : @filtros[:moneda]],
        ["Banco",             @filtros[:banco].to_s.empty?  ? "(todos)" : @filtros[:banco]],
        ["Filtro búsqueda",   @filtros[:buscar_por].to_s.empty? ? "(ninguno)" : "#{@filtros[:buscar_por]} = #{@filtros[:q]}"],
      ]
      filt_pares.each do |label, val|
        ws.add_row([label, val, nil, nil, nil, nil],
                   style: [@s[:label_filter], @s[:value_filter], nil, nil, nil, nil])
      end

      ws.add_row([])

      # Headers de KPIs
      ws.add_row(["Estado", "Cantidad", "Valor total", nil, nil, nil],
                 style: [@s[:hdr_data], @s[:hdr_data], @s[:hdr_data], nil, nil, nil])
      ws.rows.last.height = 24

      kpi_rows = [
        ["✅ Pago exitoso", @stats[:pago_exitoso], @stats[:pago_exitoso_valor], :kpi_pago_bg],
        ["✅ Aprobado",     @stats[:aprobado],     @stats[:aprobado_valor],     :kpi_aprobado_bg],
        ["⚠️ Reembolso",   @stats[:reembolso],    @stats[:reembolso_valor],    :kpi_reembolso_bg],
        ["⏳ Pendiente",    @stats[:pendiente],    @stats[:pendiente_valor],    :kpi_pendiente_bg],
        ["📋 Otro",         @stats[:otro],         @stats[:otro_valor],         :kpi_otro_bg],
      ]
      kpi_rows.each do |label, cnt, val, bg|
        ws.add_row([label, cnt, val, nil, nil, nil],
                   style: [@s[bg], @s[:kpi_cnt], @s[:kpi_val], nil, nil, nil])
      end

      ws.add_row(["TOTAL", @stats[:total], @stats[:total_valor], nil, nil, nil],
                 style: [@s[:total_label], @s[:total_cnt], @s[:total_val], nil, nil, nil])
    end
  end

  def write_detalle(wb)
    wb.add_worksheet(name: "Detalle") do |ws|
      headers = [
        "Creación TX", "ID TX", "ID User", "Nombre",
        "Moneda", "Valor", "Banco", "Consecutivo",
        "Estado", "status_cd", "Daviplata Response",
      ]
      widths = [20, 28, 28, 28, 8, 18, 22, 16, 16, 10, 30]
      ws.column_widths(*widths)

      ws.add_row(headers, style: Array.new(headers.size, @s[:hdr_data]))
      ws.rows.last.height = 28

      @rows.each do |r|
        estado_str  = r["estado"].to_s
        estado_style = case estado_str
                       when "Pago exitoso" then @s[:estado_pago]
                       when "Aprobado"     then @s[:estado_aprobado]
                       when "Reembolso"    then @s[:estado_reembolso]
                       when "Pendiente"    then @s[:estado_pendiente]
                       else @s[:estado_otro]
                       end

        creacion_str = r["creacion_tx"].to_s
        creacion_val =
          begin
            DateTime.parse(creacion_str)
          rescue
            creacion_str
          end

        ws.add_row(
          [
            creacion_val,
            r["id_tx"].to_s,
            r["id_user"].to_s,
            r["name_user"].to_s,
            r["moneda"].to_s,
            r["valor"].to_f,
            r["name_bank"].to_s,
            r["consecutivo"].to_s,
            estado_str,
            r["status_cd"].to_i,
            r["daviplata_response"].to_s,
          ],
          style: [
            @s[:cell_dt], @s[:cell_str], @s[:cell_str], @s[:cell_str],
            @s[:cell_str], @s[:cell_num], @s[:cell_str], @s[:cell_str],
            estado_style, @s[:cell_int], @s[:cell_str],
          ],
        )
      end

      # Auto-filter sobre headers
      ws.auto_filter = "A1:K#{@rows.size + 1}" if @rows.any?

      # Freeze panes para que los headers no se muevan al scrollear
      ws.sheet_view.pane do |pane|
        pane.state         = :frozen
        pane.y_split       = 1
        pane.active_pane   = :bottom_right
      end
    end
  end
end
