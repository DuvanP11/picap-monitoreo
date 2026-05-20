# app/services/excel_export_service.rb
# Helpers para exportar a Excel con estilo corporativo Picap.
# Replica el flujo del openpyxl Python (_xl_make_workbook, _xl_banner, etc.).
#
# Uso típico:
#   ExcelExportService.build("Picap_Evasion") do |xlsx|
#     xlsx.add_sheet("Resumen") do |s|
#       s.banner("Título grande", "Subtítulo período · País", 4)
#       s.headers(["Col1","Col2","Col3","Col4"])
#       s.data_row(["a","b",123, "OK"])
#       s.finalize(freeze_row: 4)
#     end
#   end
#   # → returns hash {data:, filename:, mimetype:}

require "caxlsx"

class ExcelExportService
  # Paleta corporativa Picap (igual que api.py)
  COLORS = {
    purple:    "6B21A8",
    purple_lt: "EDE9F5",
    green:     "16A34A",
    green_lt:  "DCFCE7",
    red:       "DC2626",
    red_lt:    "FEE2E2",
    amber:     "D97706",
    amber_lt:  "FEF9C3",
    gray_lt:   "F3F0FA",
    white:     "FFFFFF",
    dark:      "1E1333",
  }.freeze

  XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  def self.build(filename_base)
    pkg = Axlsx::Package.new
    pkg.use_shared_strings = true
    wb  = pkg.workbook
    helper = Helper.new(wb)
    yield helper
    bytes = pkg.to_stream.read
    ts = Time.now.strftime("%Y%m%d_%H%M%S")
    {
      data:     bytes,
      filename: "#{filename_base}_#{ts}.xlsx",
      mimetype: XLSX_MIME,
    }
  end

  class Helper
    def initialize(wb)
      @wb = wb
    end

    def add_sheet(name, tab_color: COLORS[:purple], &block)
      ws = @wb.add_worksheet(name: name)
      sheet_helper = SheetHelper.new(@wb, ws, tab_color: tab_color)
      yield sheet_helper
      sheet_helper
    end
  end

  class SheetHelper
    attr_reader :ws, :current_row

    def initialize(wb, ws, tab_color: COLORS[:purple])
      @wb           = wb
      @ws           = ws
      @current_row  = 1
      @tab_color    = tab_color

      # Estilos pre-creados (cacheados)
      @s_title    = wb.styles.add_style(b: true, sz: 16, fg_color: COLORS[:purple], alignment: { horizontal: :left, vertical: :center })
      @s_subtitle = wb.styles.add_style(b: false, sz: 10, fg_color: "555555", alignment: { horizontal: :left })
      @s_header   = wb.styles.add_style(b: true, sz: 10, fg_color: COLORS[:white],
                                        bg_color: COLORS[:purple],
                                        alignment: { horizontal: :center, vertical: :center, wrap_text: true },
                                        border:    { style: :thin, color: "CCCCCC" })
      @s_data     = wb.styles.add_style(sz: 10, alignment: { vertical: :center },
                                        border: { style: :thin, color: "EEEEEE" })
      @s_data_right = wb.styles.add_style(sz: 10, alignment: { horizontal: :right, vertical: :center },
                                          border: { style: :thin, color: "EEEEEE" })
      @s_kpi_label = wb.styles.add_style(b: true, sz: 9, fg_color: COLORS[:dark],
                                         bg_color: COLORS[:purple_lt],
                                         alignment: { horizontal: :left })
      @s_kpi_val   = wb.styles.add_style(b: true, sz: 11, alignment: { horizontal: :right })
      @s_section   = wb.styles.add_style(b: true, sz: 12, fg_color: COLORS[:purple],
                                         alignment: { horizontal: :left })
    end

    def banner(title, subtitle, n_cols)
      @ws.add_row([title]    + Array.new(n_cols - 1), style: @s_title,    height: 24)
      @ws.add_row([subtitle] + Array.new(n_cols - 1), style: @s_subtitle, height: 16)
      @ws.add_row(Array.new(n_cols, nil))
      @ws.merge_cells "A1:#{cell_ref(1, n_cols)}"
      @ws.merge_cells "A2:#{cell_ref(2, n_cols)}"
      @current_row = 4
      self
    end

    def section_title(title, n_cols = 4)
      @ws.add_row([title] + Array.new(n_cols - 1), style: @s_section, height: 20)
      @ws.merge_cells "A#{@current_row}:#{cell_ref(@current_row, n_cols)}"
      @current_row += 1
      @ws.add_row(Array.new(n_cols, nil))
      @current_row += 1
      self
    end

    # KPI grid: pares [label, value]. ncols = columnas (2/3/4).
    def kpi_section(title, kpis, ncols: 4)
      section_title(title, ncols * 2)
      kpis.each_slice(ncols) do |slice|
        labels = []
        vals   = []
        slice.each do |kpi|
          labels << kpi[0]
          vals   << kpi[1]
        end
        labels.fill(nil, labels.size...ncols)
        vals.fill(nil, vals.size...ncols)
        row_vals = labels.zip(vals).flatten
        styles   = Array.new(ncols) { [@s_kpi_label, @s_kpi_val] }.flatten
        @ws.add_row(row_vals, style: styles, height: 22)
        @current_row += 1
      end
      @ws.add_row([])
      @current_row += 1
      self
    end

    def headers(cols)
      @header_count = cols.size
      @ws.add_row(cols, style: @s_header, height: 28)
      @current_row += 1
      self
    end

    # @param vals [Array] valores en orden de columnas
    # @param right_align [Array<Integer>] índices (1-based) de columnas a alinear derecha
    # @param cell_styles [Hash{Integer=>Object}] override de estilo por columna (1-based);
    #        tiene prioridad sobre right_align. Útil para colorear celdas individuales
    #        (ej. "Resultado": rojo si alerta, verde si OK).
    def data_row(vals, right_align: [], cell_styles: {})
      styles = vals.each_index.map do |i|
        col = i + 1
        next cell_styles[col] if cell_styles.key?(col)
        right_align.include?(col) ? @s_data_right : @s_data
      end
      @ws.add_row(vals, style: styles)
      @current_row += 1
      self
    end

    # Cierra hoja: autofit, freeze, oculta gridlines
    def finalize(freeze_row: nil)
      @ws.sheet_view.show_grid_lines = false
      @ws.sheet_view.pane do |p|
        if freeze_row
          p.state       = :frozen
          p.y_split     = freeze_row - 1
          p.top_left_cell = "A#{freeze_row}"
          p.active_pane = :bottom_left
        end
      end
      # Auto-fit aproximado por longitud
      autofit_columns
      self
    end

    private

    def autofit_columns
      return unless @header_count
      widths = Array.new(@header_count, 10)
      @ws.rows.each do |row|
        row.cells.each_with_index do |cell, i|
          next unless i < @header_count
          v = cell.value.to_s
          widths[i] = [widths[i], [v.length + 2, 50].min].max
        end
      end
      @ws.column_widths(*widths)
    end

    def cell_ref(row, col_index)
      col_letters = ""
      n = col_index
      while n > 0
        n, rem = (n - 1).divmod(26)
        col_letters = (rem + "A".ord).chr + col_letters
      end
      "#{col_letters}#{row}"
    end
  end
end
