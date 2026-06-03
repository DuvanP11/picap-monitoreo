# app/services/saldo_recaudos_excel_builder.rb
# v3.3.28 — Generador del Excel "Saldo Recaudos" con caxlsx.
#
# Replica EXACTAMENTE la salida de recaudos_bi/generar_recaudos.py (Python local
# validado con abril 2026: cuadra centavo a centavo $414M, Surtitodo -$33,910.04).
#
# 5 hojas:
#   1. Query Recaudos        — data cruda Q_SALDO_RECAUDOS_RECAUDOS
#   2. TD Recaudos           — pivote User_Company → Σ Transaction_amount
#   3. Query Transacciones   — data cruda Q_SALDO_RECAUDOS_TRANSACCIONES + cols
#                              calculadas DIA / Recaudos / Servicios (refs directas)
#   4. Mensual               — pivote por Company_name (Recaudos, Servicios, DIF,
#                              Comisión, Retenciones, TOTAL, % comisión)
#   5. Control               — User Company + tabla resumen Surtitodo al final
#                              (Recaudos / Servicios / Comisión / ICA / Total)

require "caxlsx"

class SaldoRecaudosExcelBuilder
  # Paleta consistente con la estética del script Python.
  COLORS = {
    purple_dark:  "5B2169",
    purple_light: "E8D7F0",
    hdr_blue:     "1F4E78",
    yellow:       "FFFF00",
    green_mint:   "D4EDDA",
    red:          "C00000",
    white:        "FFFFFF",
    pivot_hdr:    "D9E1F2",
    pivot_total:  "FFE699",
    border_gray:  "B0B0B0",
  }.freeze

  CLIENTES_PRUEBA = %w[PIBOX\ ADMIN TESTEO\ 2].freeze
  INT_FMT = "#,##0".freeze
  PCT_FMT = "0.00%".freeze
  XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze

  # API pública. Devuelve { data:, filename:, mimetype: }.
  def self.build(desde:, hasta:, recaudos:, transacciones:, comisiones: {})
    new(desde, hasta, recaudos, transacciones, comisiones).call
  end

  def initialize(desde, hasta, recaudos, transacciones, comisiones)
    @desde = desde
    @hasta = hasta
    @recaudos = recaudos
    @transacciones = transacciones
    @comisiones = comisiones
  end

  def call
    pkg = Axlsx::Package.new
    pkg.use_shared_strings = true
    wb  = pkg.workbook

    # Pre-construir estilos cacheados (caxlsx exige IDs).
    @styles = build_styles(wb)

    # Pre-calcular pivots (los reutilizamos en varias hojas).
    @td_recaudos       = build_td_recaudos
    @por_empresa_pivot = build_pivot_mensual

    write_query_recaudos_sheet(wb)
    write_td_recaudos_sheet(wb)
    write_query_transacciones_sheet(wb)
    write_mensual_sheet(wb)
    write_control_sheet(wb)

    {
      data:     pkg.to_stream.read,
      filename: "Saldo_Recaudos_#{@desde}_a_#{@hasta}.xlsx",
      mimetype: XLSX_MIME,
    }
  end

  private

  # ──────────────────────────────────────────────────────────────────────
  # Estilos cacheados
  # ──────────────────────────────────────────────────────────────────────

  def build_styles(wb)
    s = wb.styles
    {
      header_blue: s.add_style(
        bg_color: COLORS[:hdr_blue], fg_color: COLORS[:white], b: true,
        sz: 11, alignment: { horizontal: :left, vertical: :center },
      ),
      pivot_hdr: s.add_style(
        bg_color: COLORS[:pivot_hdr], b: true,
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
      pivot_total: s.add_style(
        bg_color: COLORS[:pivot_total], b: true,
        border: { style: :thin, color: COLORS[:border_gray] },
        format_code: INT_FMT,
      ),
      pivot_total_label: s.add_style(
        bg_color: COLORS[:pivot_total], b: true,
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
      money_int: s.add_style(
        format_code: INT_FMT,
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
      pct: s.add_style(
        format_code: PCT_FMT,
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
      bordered: s.add_style(border: { style: :thin, color: COLORS[:border_gray] }),
      bold:     s.add_style(b: true, border: { style: :thin, color: COLORS[:border_gray] }),

      # Surtitodo
      surt_header: s.add_style(
        bg_color: COLORS[:purple_dark], fg_color: COLORS[:white],
        b: true, sz: 12,
        alignment: { horizontal: :center, vertical: :center },
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
      surt_label: s.add_style(
        bg_color: COLORS[:purple_light], b: true,
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
      surt_recaudos_val: s.add_style(
        bg_color: COLORS[:yellow], format_code: INT_FMT,
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
      surt_servicios_val: s.add_style(
        bg_color: COLORS[:green_mint], format_code: INT_FMT,
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
      surt_red: s.add_style(
        fg_color: COLORS[:red], format_code: INT_FMT,
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
      surt_normal: s.add_style(
        format_code: INT_FMT,
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
      surt_total_label: s.add_style(
        bg_color: COLORS[:purple_dark], fg_color: COLORS[:white], b: true,
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
      surt_total_val: s.add_style(
        bg_color: COLORS[:purple_dark], fg_color: COLORS[:red], b: true,
        format_code: INT_FMT,
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
    }
  end

  # ──────────────────────────────────────────────────────────────────────
  # Pre-cómputos
  # ──────────────────────────────────────────────────────────────────────

  def build_td_recaudos
    @recaudos
      .group_by { |r| r["User_Company"].to_s }
      .reject   { |emp, _| emp.empty? }
      .map      { |emp, g| [emp, g.sum { |r| r["Transaction_amount"].to_f }] }
      .sort_by  { |_, m| -m }
  end

  def build_pivot_mensual
    pivot = Hash.new { |h, k| h[k] = { recaudos: 0.0, servicios: 0.0, company_id: "" } }
    @transacciones.each do |r|
      emp = r["Company_name"].to_s
      next if emp.empty?
      val   = r["VAL_AMOUNT"].to_f
      tipo  = r["TXT_TYPE"].to_s
      pivot[emp][:company_id] = r["company_id"].to_s if pivot[emp][:company_id].empty?
      case tipo
      when "WalletAccountCounterDeliveryPaymentTransaction"
        pivot[emp][:recaudos] += val
      when "WalletAccountTransactionBookingCompanyCharge",
           "WalletAccountTransactionTransactionCommissionCompanyPayment",
           "WalletAccountTransactionCommissionCompanyPayment"
        pivot[emp][:servicios] += val
      end
    end
    pivot.sort_by { |emp, _| emp.downcase }
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 1: Query Recaudos
  # ──────────────────────────────────────────────────────────────────────

  def write_query_recaudos_sheet(wb)
    headers = @recaudos.first&.keys || []
    wb.add_worksheet(name: "Query Recaudos") do |ws|
      ws.add_row(headers, style: Array.new(headers.size, @styles[:header_blue]))
      @recaudos.each do |r|
        ws.add_row(headers.map { |h| coerce(r[h]) })
      end
      ws.sheet_view.pane do |p|
        p.state = :frozen
        p.y_split = 1
        p.top_left_cell = "A2"
      end
      headers.size.times.each { |i| ws.column_widths[i] = 18 } if ws.respond_to?(:column_widths)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 2: TD Recaudos
  # ──────────────────────────────────────────────────────────────────────

  def write_td_recaudos_sheet(wb)
    wb.add_worksheet(name: "TD Recaudos") do |ws|
      # Filas 1-2 vacías para mimicear pivot layout original
      ws.add_row([])
      ws.add_row([])
      ws.add_row(
        ["Etiquetas de fila", "Suma de Transaction_amount"],
        style: [@styles[:pivot_hdr], @styles[:pivot_hdr]],
      )
      @td_recaudos.each do |emp, monto|
        ws.add_row([emp, monto.round(2)], style: [@styles[:bordered], @styles[:money_int]])
      end
      total = @td_recaudos.sum { |_, m| m }
      ws.add_row(
        ["Total general", total.round(2)],
        style: [@styles[:pivot_total_label], @styles[:pivot_total]],
      )
      ws.column_widths(40, 24) if ws.respond_to?(:column_widths)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 3: Query Transacciones + cols calculadas
  # ──────────────────────────────────────────────────────────────────────

  def write_query_transacciones_sheet(wb)
    return write_empty_tx_sheet(wb) if @transacciones.empty?

    orig_headers = @transacciones.first.keys
    # Limpiar puntos en headers (no afecta porque NO usamos Excel Tables, pero
    # buena práctica para mantener nombres parseables).
    clean_headers = orig_headers.map { |h| h.to_s.tr(".", "_") }

    # Reordenar: insertar DIA después de TMS_CREATED (índice 4 en headers).
    tms_idx = clean_headers.index("TMS_CREATED") || 4
    new_headers = clean_headers[0..tms_idx] + ["DIA"] + clean_headers[(tms_idx + 1)..] + ["Recaudos", "Servicios"]

    wb.add_worksheet(name: "Query Transacciones") do |ws|
      ws.add_row(new_headers, style: Array.new(new_headers.size, @styles[:header_blue]))

      @transacciones.each_with_index do |r, idx|
        row_excel = idx + 2  # fila 1 son headers
        values = []
        # Cols originales (1..tms_idx+1)
        clean_headers[0..tms_idx].each_with_index do |h, i|
          orig = orig_headers[i]
          values << coerce(r[orig])
        end
        # DIA = =DAY(E{row}) — la col TMS_CREATED es la 5ta (índice 4) por default
        e_col_letter = (?A.ord + tms_idx).chr  # E si tms_idx=4
        values << "=DAY(#{e_col_letter}#{row_excel})"
        # Resto de cols originales (después de TMS_CREATED)
        clean_headers[(tms_idx + 1)..].each_with_index do |h, i|
          orig = orig_headers[tms_idx + 1 + i]
          values << coerce(r[orig])
        end
        # Recaudos = IF(D="CounterDelivery", H, 0)
        d_col_letter = (?A.ord + clean_headers.index("TXT_TYPE")).chr
        # VAL_AMOUNT está después del DIA inserto, así que la columna en el Excel se corre +1
        val_idx_orig = clean_headers.index("VAL_AMOUNT")
        val_excel_idx = val_idx_orig > tms_idx ? val_idx_orig + 1 : val_idx_orig
        h_col_letter = (?A.ord + val_excel_idx).chr

        values << "=IF(#{d_col_letter}#{row_excel}=\"WalletAccountCounterDeliveryPaymentTransaction\",#{h_col_letter}#{row_excel},0)"
        # Servicios = IF anidado (3 casos)
        values << (
          "=IF(#{d_col_letter}#{row_excel}=\"WalletAccountTransactionBookingCompanyCharge\",#{h_col_letter}#{row_excel}," \
          "IF(#{d_col_letter}#{row_excel}=\"WalletAccountTransactionCommissionCompanyPayment\",#{h_col_letter}#{row_excel}," \
          "IF(#{d_col_letter}#{row_excel}=\"WalletAccountCounterDeliveryPaymentTransaction\",0,0)))"
        )

        # Aplicar estilos por columna: DIA (idx tms+1) → entero, Recaudos / Servicios → INT_FMT
        row_styles = Array.new(new_headers.size, nil)
        row_styles[tms_idx + 1] = @styles[:money_int]   # DIA
        row_styles[-2] = @styles[:money_int]            # Recaudos
        row_styles[-1] = @styles[:money_int]            # Servicios

        ws.add_row(values, style: row_styles)
      end

      ws.sheet_view.pane do |p|
        p.state = :frozen
        p.y_split = 1
        p.top_left_cell = "A2"
      end
      new_headers.size.times.each { |i| ws.column_widths[i] = 18 } if ws.respond_to?(:column_widths)
    end
  end

  def write_empty_tx_sheet(wb)
    wb.add_worksheet(name: "Query Transacciones") do |ws|
      ws.add_row(["(sin transacciones en el rango)"])
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 4: Mensual (pivote por Company_name)
  # ──────────────────────────────────────────────────────────────────────

  def write_mensual_sheet(wb)
    wb.add_worksheet(name: "Mensual") do |ws|
      # Filtros mock (display only — caxlsx no soporta filtros nativos de pivot)
      ws.add_row(["Payment_Type", "(Todas)"], style: [@styles[:bold], nil])
      ws.add_row(["DIA", "(Todas)"], style: [@styles[:bold], nil])
      ws.add_row([])

      headers = ["Etiquetas de fila", "Suma de Recaudos", "Suma de Servicios", "DIF",
                 "Comisión Recaudo", "Retenciones", "TOTAL", "Facturas pendientes", "Porcentaje comisión"]
      ws.add_row(headers, style: Array.new(headers.size, @styles[:pivot_hdr]))

      first_data_row = 5
      @por_empresa_pivot.each_with_index do |(emp, info), i|
        row = first_data_row + i
        pct = @comisiones[info[:company_id]].to_f
        values = [
          emp,
          info[:recaudos].round(2),
          info[:servicios].round(2),
          "=C#{row}+B#{row}",                            # DIF
          "=IFERROR(B#{row}*I#{row}*-1,0)",              # Comisión Recaudo
          "=IF(C#{row}<>0,(-(C#{row}*9.66)/1000),0)",    # Retenciones
          "=SUM(D#{row}:F#{row})",                       # TOTAL
          nil,                                            # Facturas pendientes
          pct,                                            # % comisión
        ]
        styles = [
          @styles[:bordered], @styles[:money_int], @styles[:money_int],
          @styles[:money_int], @styles[:money_int], @styles[:money_int],
          @styles[:bold], @styles[:bordered], @styles[:pct],
        ]
        ws.add_row(values, style: styles)
      end

      # Total general
      r_total = first_data_row + @por_empresa_pivot.size
      ws.add_row([
        "Total general",
        "=SUM(B#{first_data_row}:B#{r_total - 1})",
        "=SUM(C#{first_data_row}:C#{r_total - 1})",
        "=SUM(D#{first_data_row}:D#{r_total - 1})",
        "=SUM(E#{first_data_row}:E#{r_total - 1})",
        "=SUM(F#{first_data_row}:F#{r_total - 1})",
        "=SUM(G#{first_data_row}:G#{r_total - 1})",
        nil, nil,
      ], style: [
        @styles[:pivot_total_label],
        @styles[:pivot_total], @styles[:pivot_total], @styles[:pivot_total],
        @styles[:pivot_total], @styles[:pivot_total], @styles[:pivot_total],
        nil, nil,
      ])

      ws.column_widths(40, 18, 18, 18, 18, 18, 18, 18, 18) if ws.respond_to?(:column_widths)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 5: Control + tabla Resumen Surtitodo
  # ──────────────────────────────────────────────────────────────────────

  def write_control_sheet(wb)
    wb.add_worksheet(name: "Control") do |ws|
      ws.add_row(
        ["User Company", "Suma de $ Transaction", "Pendiente al 31", "TOTAL", "Comentario"],
        style: Array.new(5, @styles[:header_blue]),
      )

      surtitodo_row = nil
      @td_recaudos.each_with_index do |(emp, monto), idx|
        row_excel = idx + 2
        comentario = comentario_para(emp)
        surtitodo_row = row_excel if emp.downcase.strip == "surtitodo express"
        ws.add_row(
          [emp, monto.round(2), 0, 0, comentario],
          style: [@styles[:bordered], @styles[:money_int], @styles[:bordered],
                  @styles[:bordered], @styles[:bordered]],
        )
      end

      # ── Tabla Resumen Surtitodo ──
      if surtitodo_row
        # Espacio entre la tabla principal y la resumen
        table_start = [12, @td_recaudos.size + 4].max
        # Rellenar filas en blanco hasta table_start
        ((@td_recaudos.size + 2)...table_start).each { ws.add_row([]) }

        # Header merged (caxlsx: agregamos celda y mergeamos después no se puede
        # directamente — usamos merge_cells del worksheet).
        ws.add_row(["Surtitodo abril", nil], style: [@styles[:surt_header], @styles[:surt_header]])
        ws.merge_cells("A#{table_start}:B#{table_start}")
        ws.rows.last.height = 22

        rec_row  = table_start + 1
        serv_row = table_start + 2
        com_row  = table_start + 3
        ica_row  = table_start + 4
        tot_row  = table_start + 5

        ws.add_row(["Recaudos",  "=B#{surtitodo_row}"],                          style: [@styles[:surt_label], @styles[:surt_recaudos_val]])
        ws.add_row(["Servicios", '=VLOOKUP("Surtitodo express",Mensual!A:C,3,FALSE)'], style: [@styles[:surt_label], @styles[:surt_servicios_val]])
        ws.add_row(["Comisión",  "=-B#{rec_row}*1%"],                            style: [@styles[:surt_label], @styles[:surt_red]])
        ws.add_row(["ICA",       "=(-B#{serv_row}*9.66)/1000"],                   style: [@styles[:surt_label], @styles[:surt_normal]])
        ws.add_row(["Total",     "=SUM(B#{rec_row}:B#{ica_row})"],                style: [@styles[:surt_total_label], @styles[:surt_total_val]])
      end

      ws.column_widths(40, 22, 18, 14, 38) if ws.respond_to?(:column_widths)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────

  def comentario_para(emp)
    upper = emp.to_s.upcase.strip
    return "Pruebas" if CLIENTES_PRUEBA.include?(upper)
    return "Cero, más servicios que recaudo" if emp.to_s.downcase.strip == "surtitodo express"
    "Cliente ida y vuelta"
  end

  # Convierte strings de CH a tipos Excel-friendly cuando es posible.
  def coerce(v)
    return nil if v.nil? || v == "" || v == '\\N'
    return v if v.is_a?(Numeric)
    return v if v.is_a?(Date) || v.is_a?(Time)
    s = v.to_s
    if s =~ /\A-?\d+\z/
      return s.to_i
    elsif s =~ /\A-?\d+\.\d+\z/
      return s.to_f
    end
    s
  end
end
