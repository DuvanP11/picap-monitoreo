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

      # Formato moneda Colombia (COP): sin decimales, separador de miles, signo $.
      # caxlsx serializa el format_code tal cual; Excel/LibreOffice lo interpreta.
      MONEY_FMT      = '"$ "#,##0'.freeze
      MONEY_NEG_FMT  = '"$ "#,##0;[Red]"-$ "#,##0'.freeze

      # Estilos pre-creados (cacheados). El prefix "FF" en colores asegura
      # alpha=255 (opaco) — algunos renderers ignoran formatos sin alpha.
      purple   = "FF#{COLORS[:purple]}"
      purpleLt = "FF#{COLORS[:purple_lt]}"
      white    = "FF#{COLORS[:white]}"
      dark     = "FF#{COLORS[:dark]}"
      red      = "FF#{COLORS[:red]}"
      grayBd   = "FFCCCCCC"
      grayLt   = "FFF3F0FA"

      @s_title    = wb.styles.add_style(b: true, sz: 16, fg_color: purple,
                                        alignment: { horizontal: :left, vertical: :center })
      @s_subtitle = wb.styles.add_style(b: false, sz: 10, fg_color: "FF555555",
                                        alignment: { horizontal: :left })
      @s_header   = wb.styles.add_style(b: true, sz: 11, fg_color: white,
                                        bg_color: purple,
                                        alignment: { horizontal: :center, vertical: :center, wrap_text: true },
                                        border:    { style: :thin, color: purple })
      @s_data       = wb.styles.add_style(sz: 10, alignment: { vertical: :center },
                                          border: { style: :thin, color: grayBd })
      @s_data_right = wb.styles.add_style(sz: 10, alignment: { horizontal: :right, vertical: :center },
                                          border: { style: :thin, color: grayBd })
      # v3.2: estilo monetario para celdas de detalle (formato COP sin decimales).
      @s_data_money = wb.styles.add_style(b: true, sz: 10,
                                          alignment: { horizontal: :right, vertical: :center },
                                          border: { style: :thin, color: grayBd },
                                          format_code: MONEY_NEG_FMT)
      @s_kpi_label = wb.styles.add_style(b: true, sz: 9, fg_color: dark,
                                         bg_color: purpleLt,
                                         alignment: { horizontal: :left })
      @s_kpi_val   = wb.styles.add_style(b: true, sz: 11, alignment: { horizontal: :right })
      @s_section   = wb.styles.add_style(b: true, sz: 12, fg_color: purple,
                                         alignment: { horizontal: :left })

      # v3: estilos para reportes ejecutivos tipo Pibox (header morado pleno,
      # bordes morados, celdas con valores monetarios en rojo/negro).
      @s_report_title = wb.styles.add_style(
        b: true, sz: 14, fg_color: dark,
        bg_color: purpleLt,
        alignment: { horizontal: :center, vertical: :center },
        border: { style: :medium, color: purple },
      )
      @s_report_header = wb.styles.add_style(
        b: true, sz: 12, fg_color: white,
        bg_color: purple,
        alignment: { horizontal: :center, vertical: :center },
        border: { style: :thin, color: purple },
      )
      @s_report_cell = wb.styles.add_style(
        sz: 11, fg_color: dark,
        alignment: { horizontal: :center, vertical: :center },
        border: { style: :thin, color: purple },
      )
      @s_report_cell_alt = wb.styles.add_style(
        sz: 11, fg_color: dark,
        bg_color: grayLt,
        alignment: { horizontal: :center, vertical: :center },
        border: { style: :thin, color: purple },
      )
      @s_report_cell_money = wb.styles.add_style(
        b: true, sz: 11, fg_color: dark,
        alignment: { horizontal: :right, vertical: :center },
        border: { style: :thin, color: purple },
        format_code: MONEY_FMT,
      )
      @s_report_cell_money_neg = wb.styles.add_style(
        b: true, sz: 11, fg_color: red,
        alignment: { horizontal: :right, vertical: :center },
        border: { style: :thin, color: purple },
        format_code: MONEY_NEG_FMT,
      )
      @s_report_cell_pct = wb.styles.add_style(
        b: true, sz: 11, fg_color: red,
        alignment: { horizontal: :center, vertical: :center },
        border: { style: :thin, color: purple },
        format_code: '0.00%',
      )
      @s_report_total = wb.styles.add_style(
        b: true, sz: 11, fg_color: white,
        bg_color: purple,
        alignment: { horizontal: :center, vertical: :center },
        border: { style: :medium, color: purple },
      )
      @s_report_total_money = wb.styles.add_style(
        b: true, sz: 11, fg_color: white,
        bg_color: purple,
        alignment: { horizontal: :right, vertical: :center },
        border: { style: :medium, color: purple },
        format_code: MONEY_NEG_FMT,
      )
      @s_report_total_pct = wb.styles.add_style(
        b: true, sz: 11, fg_color: white,
        bg_color: purple,
        alignment: { horizontal: :center, vertical: :center },
        border: { style: :medium, color: purple },
        format_code: '0.00%',
      )
    end

    # Accessor para estilos pre-creados — usados por helpers externos
    # (ej. RecaudosResumenHelpers) que necesitan estilos especiales.
    attr_reader :s_data_money, :s_report_cell_alt, :s_report_total,
                :s_report_total_money, :s_report_total_pct

    # Banner de título grande para reportes ejecutivos (estilo Pibox).
    # Una sola celda mergeada de span columnas, con fondo morado claro y
    # texto bold morado oscuro centrado.
    def report_main_title(text, span: 5)
      @ws.add_row([text] + Array.new(span - 1), style: @s_report_title, height: 28)
      @ws.merge_cells "A#{@current_row}:#{cell_ref(@current_row, span)}"
      @current_row += 1
      @ws.add_row(Array.new(span, nil))
      @current_row += 1
      self
    end

    # Reportes ejecutivos (estilo Pibox): tablas con header morado + bordes.
    # Cada llamada agrega una mini-tabla. No actualiza header_count global porque
    # no participa del autofit estándar; los anchos se setean explícitamente
    # con set_column_widths.
    #
    # @param headers [Array<String>]
    # @param values [Array<Array>]
    # @param value_styles [Array<Symbol>] por celda en values[0] — tipo:
    #        :text (default), :money, :money_neg, :pct
    def report_table(headers, values, value_styles: nil, title: nil, title_span: nil)
      n_cols = headers.size
      span = title_span || n_cols

      if title
        @ws.add_row([title] + Array.new(n_cols - 1), style: @s_report_title, height: 26)
        @ws.merge_cells "A#{@current_row}:#{cell_ref(@current_row, span)}"
        @current_row += 1
      end

      @ws.add_row(headers, style: @s_report_header, height: 22)
      @current_row += 1

      values.each do |row|
        styles = row.each_index.map do |i|
          sym = value_styles ? value_styles[i] : :text
          case sym
          when :money     then @s_report_cell_money
          when :money_neg then @s_report_cell_money_neg
          when :pct       then @s_report_cell_pct
          else                 @s_report_cell
          end
        end
        @ws.add_row(row, style: styles, height: 20)
        @current_row += 1
      end

      # fila vacía separadora
      @ws.add_row(Array.new(n_cols, nil))
      @current_row += 1
      self
    end

    # Variante de report_table con FILA DE TOTAL destacada al final (fondo
    # morado pleno + texto blanco bold). Usado en tablas pivot por compañía.
    #
    # @param total_row [Array] fila de totales
    # @param total_styles [Array<Symbol>] estilos para cada celda del total
    #        (símbolos: :total, :total_money, :total_pct).
    def report_table_with_total(headers, values, total_row:, value_styles: nil,
                                 total_styles: [:total, :total, :total_money, :total_pct])
      n_cols = headers.size
      @ws.add_row(headers, style: @s_report_header, height: 22)
      @current_row += 1

      # Filas regulares con alternancia (lila claro / blanco)
      values.each_with_index do |row, idx|
        styles = row.each_index.map do |i|
          sym = value_styles ? value_styles[i] : :text
          base = case sym
                 when :money     then @s_report_cell_money
                 when :money_neg then @s_report_cell_money_neg
                 when :pct       then @s_report_cell_pct
                 else                 @s_report_cell
                 end
          # Para filas pares, usar variante con fondo lila claro (sólo para
          # estilos no monetarios — los monetarios mantienen su color por
          # legibilidad).
          if idx.odd? && sym == :text
            @s_report_cell_alt
          else
            base
          end
        end
        @ws.add_row(row, style: styles, height: 20)
        @current_row += 1
      end

      # Fila de TOTAL destacada (morado pleno + blanco bold)
      total_st = total_row.each_index.map do |i|
        sym = total_styles[i] || :total
        case sym
        when :total_money then @s_report_total_money
        when :total_pct   then @s_report_total_pct
        else                   @s_report_total
        end
      end
      @ws.add_row(total_row, style: total_st, height: 24)
      @current_row += 1

      # fila vacía separadora
      @ws.add_row(Array.new(n_cols, nil))
      @current_row += 1
      self
    end

    # Inserta una imagen (logo). file_path debe ser absoluta y existir.
    # row/col 1-based. width/height en píxeles.
    # caxlsx API: ws.add_image(image_src:) { |i| i.width/height/start_at }.
    # start_at usa coordenadas 0-based (col, row).
    def add_image(file_path, row: nil, col: nil, width: 120, height: 60)
      return self unless file_path && File.exist?(file_path)
      target_row = row || @current_row
      target_col = col || 1
      @ws.add_image(image_src: file_path) do |i|
        i.width  = width
        i.height = height
        i.start_at(target_col - 1, target_row - 1)
      end
      self
    rescue => e
      Rails.logger.warn("[ExcelExportService] add_image fallo: #{e.class}: #{e.message}") if defined?(Rails)
      self
    end

    # Avanza N filas en blanco (para spacing entre secciones).
    def blank_rows(n = 1)
      n.times do
        @ws.add_row([])
        @current_row += 1
      end
      self
    end

    # Setea anchos de columna explícitos (sin pasar por autofit_columns).
    def set_column_widths(*widths)
      @ws.column_widths(*widths)
      self
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
    # @param money_cols [Array<Integer>] (v3.2) índices (1-based) de columnas
    #        a formatear como moneda COP (formato "$ #,##0", bold, alineado
    #        derecha, números en rojo si son negativos).
    # @param cell_styles [Hash{Integer=>Object}] override de estilo por columna (1-based);
    #        tiene prioridad sobre money_cols y right_align. Útil para colorear celdas
    #        individuales (ej. "Resultado": rojo si alerta, verde si OK).
    def data_row(vals, right_align: [], money_cols: [], cell_styles: {})
      styles = vals.each_index.map do |i|
        col = i + 1
        next cell_styles[col] if cell_styles.key?(col)
        next @s_data_money if money_cols.include?(col)
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
