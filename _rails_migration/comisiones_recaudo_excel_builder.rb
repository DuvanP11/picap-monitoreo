# app/services/comisiones_recaudo_excel_builder.rb
# v3.3.29 — Generador del Excel "Comisiones Recaudo" con 9 hojas vía caxlsx.
#
# Replica EXACTAMENTE la salida de comisiones_bi/generar_comisiones.py (validado
# abril 2026 contra plantilla del usuario, cuadra centavo a centavo).
#
# 9 hojas:
#   1. "1. Comisión Recaudo"          — Query B (data cruda 10 cols).
#   2. "2. Recaudos"                  — Query A (10 cols + % + Comisión Manual).
#   3. "3. Cruce company"             — 2 pivotes lado a lado.
#   4. "4. Cruce Booking"             — 2 pivotes por booking_id.
#   5. "Resumen"                      — Cliente + Recaudo + % + Comisión + Anticipo + Estado.
#   6. "Comisión Recaudo ida y vuelta"— Hoja 1 sin exclusiones (Multipaquete/Surtitodo/Testeo/Pibox Admin).
#   7. "Recaudos ida y vuelta"        — Hoja 2 sin exclusiones + VAL_AMOUNT > 0.
#   8. "TD company ida y vuelta"      — 2 pivotes (Hoja 7 + Hoja 1).
#   9. "TD Bookings ida y vuelta"     — 2 pivotes (Hoja 7 + Hoja 1) por booking_id.

require "caxlsx"

class ComisionesRecaudoExcelBuilder
  COLORS = {
    hdr_blue:     "1F4E78",
    white:        "FFFFFF",
    pivot_hdr:    "D9E1F2",
    pivot_total:  "FFE699",
    red:          "C00000",
    border_gray:  "B0B0B0",
  }.freeze

  EXCLUSIONES_IDA_VUELTA = %w[
    multipaquete surtitodo pibox\ admin testeo test qa prueba
  ].freeze

  HEADERS_QUERY = [
    "passenger_id", "company_id", "Company_name", "TXT_TYPE", "TMS_CREATED",
    "qtf.booking_id", "VAL_AMOUNT", "_id", "VAL_AMOUNT_BOOKING_DRIVER_PAYMENT", "Payment_Type",
  ].freeze

  # Mapeo header CH → header Excel
  HEADER_CH_A_EXCEL = {
    "passenger_id" => "passenger_id",
    "company_id"   => "company_id",
    "Company_name" => "Company_name",
    "TXT_TYPE"     => "TXT_TYPE",
    "TMS_CREATED"  => "TMS_CREATED",
    "booking_id"   => "qtf.booking_id",
    "VAL_AMOUNT"   => "VAL_AMOUNT",
    "_id"          => "_id",
    "VAL_AMOUNT_BOOKING_DRIVER_PAYMENT" => "VAL_AMOUNT_BOOKING_DRIVER_PAYMENT",
    "Payment_Type" => "Payment_Type",
  }.freeze

  INT_FMT  = "#,##0".freeze
  DEC_FMT  = "#,##0.00".freeze
  PCT_FMT  = "0.00%".freeze
  XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze

  MESES_ES = {
    1 => "Enero", 2 => "Febrero", 3 => "Marzo", 4 => "Abril",
    5 => "Mayo", 6 => "Junio", 7 => "Julio", 8 => "Agosto",
    9 => "Septiembre", 10 => "Octubre", 11 => "Noviembre", 12 => "Diciembre",
  }.freeze

  def self.build(desde:, hasta:, recaudos:, comision:, fees:, resumen_user:)
    new(desde, hasta, recaudos, comision, fees, resumen_user).call
  end

  def initialize(desde, hasta, recaudos, comision, fees, resumen_user)
    @desde, @hasta = desde, hasta
    @recaudos = recaudos
    @comision = comision
    @fees     = fees
    @resumen_user = resumen_user
  end

  def call
    pkg = Axlsx::Package.new
    pkg.use_shared_strings = true
    wb  = pkg.workbook

    @styles = build_styles(wb)

    write_hoja1(wb)
    write_hoja2(wb)
    cruce_company = write_hoja3(wb)
    write_hoja4(wb)
    write_hoja5(wb, cruce_company)
    write_hoja6(wb)
    write_hoja7(wb)
    write_hoja8(wb)
    write_hoja9(wb)

    año, mes = @desde.split("-")
    nombre_mes = MESES_ES[mes.to_i]
    {
      data:     pkg.to_stream.read,
      filename: "Comisión Recaudos #{nombre_mes} #{año}.xlsx",
      mimetype: XLSX_MIME,
    }
  end

  private

  def build_styles(wb)
    s = wb.styles
    {
      header: s.add_style(
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
        format_code: DEC_FMT,
      ),
      pivot_total_label: s.add_style(
        bg_color: COLORS[:pivot_total], b: true,
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
      int: s.add_style(format_code: INT_FMT, border: { style: :thin, color: COLORS[:border_gray] }),
      dec: s.add_style(format_code: DEC_FMT, border: { style: :thin, color: COLORS[:border_gray] }),
      pct: s.add_style(format_code: PCT_FMT, border: { style: :thin, color: COLORS[:border_gray] }),
      bordered: s.add_style(border: { style: :thin, color: COLORS[:border_gray] }),
      bold:     s.add_style(b: true, border: { style: :thin, color: COLORS[:border_gray] }),
      money_neg_red: s.add_style(
        format_code: '#,##0.00;[Red]-#,##0.00',
        border: { style: :thin, color: COLORS[:border_gray] },
      ),
    }
  end

  # ──────────────────────────────────────────────────────────────────────
  # Helpers data
  # ──────────────────────────────────────────────────────────────────────

  def empresa_excluida?(nombre)
    return false if nombre.to_s.strip.empty?
    n = nombre.to_s.downcase.strip
    EXCLUSIONES_IDA_VUELTA.any? { |kw| n.include?(kw) }
  end

  def coerce(v)
    return nil if v.nil? || v == "" || v == '\\N'
    return v if v.is_a?(Numeric) || v.is_a?(Date) || v.is_a?(Time)
    s = v.to_s
    if s =~ /\A-?\d+\z/
      s.to_i
    elsif s =~ /\A-?\d+\.\d+\z/
      s.to_f
    else
      s
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hojas 1, 2, 6, 7: data cruda
  # ──────────────────────────────────────────────────────────────────────

  def write_data_sheet(wb, name, rows, extras: nil, filter_empresa_excluida: false, filter_val_amount_positivo: false)
    extras ||= []
    new_headers = HEADERS_QUERY.dup
    extras.each { |hdr, _| new_headers << hdr }

    wb.add_worksheet(name: name) do |ws|
      ws.add_row(new_headers, style: Array.new(new_headers.size, @styles[:header]))

      row_idx = 2
      rows.each do |r|
        emp = r["Company_name"].to_s
        next if filter_empresa_excluida && empresa_excluida?(emp)
        if filter_val_amount_positivo
          val = r["VAL_AMOUNT"].to_f
          next if val <= 0
        end

        # Mapear cada header Excel a su valor desde CH
        values = HEADERS_QUERY.map do |hdr_excel|
          hdr_ch = HEADER_CH_A_EXCEL.find { |_k, v| v == hdr_excel }&.first || hdr_excel
          coerce(r[hdr_ch])
        end
        # Cols extra calculadas
        extras.each do |_hdr, fn|
          values << fn.call(row_idx)
        end

        row_styles = Array.new(HEADERS_QUERY.size, nil)
        row_styles[HEADERS_QUERY.index("VAL_AMOUNT")] = @styles[:dec]
        row_styles[HEADERS_QUERY.index("VAL_AMOUNT_BOOKING_DRIVER_PAYMENT")] = @styles[:dec]
        extras.size.times { row_styles << @styles[:dec] }
        # Si extras incluye "%", aplicar PCT_FMT
        extras.each_with_index do |(hdr, _), idx|
          row_styles[HEADERS_QUERY.size + idx] = @styles[:pct] if hdr == "%"
        end

        ws.add_row(values, style: row_styles)
        row_idx += 1
      end

      # Auto-filter
      last_row = row_idx - 1
      if last_row > 1
        last_col_letter = Axlsx.col_ref(new_headers.size - 1)
        begin
          ws.auto_filter = "A1:#{last_col_letter}#{last_row}"
        rescue
        end
      end

      # Anchos
      [22, 22, 28, 35, 12, 22, 14, 22, 14, 16].each_with_index do |w, i|
        ws.column_widths(*Array.new(HEADERS_QUERY.size + extras.size) { |idx| idx < 10 ? [22, 22, 28, 35, 12, 22, 14, 22, 14, 16][idx] : 16 })
        break
      end
      ws.sheet_view.pane do |p|
        p.state = :frozen
        p.y_split = 1
        p.top_left_cell = "A2"
      end
    end
  end

  def write_hoja1(wb)
    write_data_sheet(wb, "1. Comisión Recaudo", @comision)
  end

  def write_hoja2(wb)
    extras = [
      ["%",               ->(r) { "=IFERROR(VLOOKUP(C#{r},'3. Cruce company'!A:C,3,0),0)" }],
      ["Comisión Manual", ->(r) { "=K#{r}*G#{r}" }],
    ]
    write_data_sheet(wb, "2. Recaudos", @recaudos, extras: extras)
  end

  def write_hoja6(wb)
    write_data_sheet(wb, "Comisión Recaudo ida y vuelta", @comision, filter_empresa_excluida: true)
  end

  def write_hoja7(wb)
    extras = [
      ["%",               ->(r) { "=IFERROR(VLOOKUP(C#{r},'3. Cruce company'!A:C,3,0),0)" }],
      ["Comisión Manual", ->(r) { "=K#{r}*G#{r}" }],
    ]
    write_data_sheet(wb, "Recaudos ida y vuelta", @recaudos,
                     extras: extras,
                     filter_empresa_excluida: true,
                     filter_val_amount_positivo: true)
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 3: Cruce company (2 pivotes)
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja3(wb)
    # Pivote Hoja 2 (Recaudos)
    sumas_rec = Hash.new(0.0)
    company_id_por_name = {}
    @recaudos.each do |r|
      emp = r["Company_name"].to_s.strip
      next if emp.empty?
      sumas_rec[emp] += r["VAL_AMOUNT"].to_f
      company_id_por_name[emp] ||= r["company_id"].to_s
    end
    sorted_rec = sumas_rec.sort_by { |emp, _| emp.downcase }

    # Pivote Hoja 1 (Comisión)
    sumas_com = Hash.new(0.0)
    @comision.each do |r|
      emp = r["Company_name"].to_s.strip
      next if emp.empty?
      sumas_com[emp] += r["VAL_AMOUNT"].to_f
    end
    sorted_com = sumas_com.sort_by { |emp, _| emp.downcase }

    cruce_company_data = {}

    wb.add_worksheet(name: "3. Cruce company") do |ws|
      # Fila 2: títulos
      ws.add_row([])
      ws.add_row(["Query 2 Recaudos", nil, nil, nil, nil, nil, nil, nil, "1. Comisión Recaudo"],
                 style: [@styles[:bold], nil, nil, nil, nil, nil, nil, nil, @styles[:bold]])

      # Fila 3: headers
      hdrs_left  = ["CLIENTE", "Suma de VAL_AMOUNT", "Porcentaje Real", "Comisión Real",
                    "Comisión Trump", "Dif", "id company"]
      hdrs_right = ["Etiquetas de fila", "Suma de VAL_AMOUNT"]
      row3 = hdrs_left + [nil] + hdrs_right
      row3_styles = Array.new(row3.size, nil)
      hdrs_left.size.times { |i| row3_styles[i] = @styles[:pivot_hdr] }
      row3_styles[8] = @styles[:pivot_hdr]
      row3_styles[9] = @styles[:pivot_hdr]
      ws.add_row(row3, style: row3_styles)

      # Data izquierda (fila 4 en adelante)
      sorted_rec.each_with_index do |(emp, monto), i|
        r = i + 4
        cid = company_id_por_name[emp].to_s
        pct = @fees[cid].to_f

        values = [emp, monto.round(2), pct,
                  "=B#{r}*C#{r}",                        # Comisión Real
                  "=IFERROR(VLOOKUP(A#{r},I:J,2,0),0)",  # Comisión Trump
                  "=E#{r}-D#{r}",                        # Dif
                  cid]
        styles = [@styles[:bordered], @styles[:int], @styles[:pct],
                  @styles[:dec], @styles[:dec], @styles[:dec], @styles[:bordered]]
        ws.add_row(values, style: styles)

        cruce_company_data[emp] = {
          recaudos: monto.round(2),
          pct: pct,
          company_id: cid,
        }
      end

      total_left_row = 4 + sorted_rec.size
      total_row_left = ["Total general",
                       "=SUM(B4:B#{total_left_row - 1})",
                       nil,
                       "=SUM(D4:D#{total_left_row - 1})",
                       "=SUM(E4:E#{total_left_row - 1})",
                       "=SUM(F4:F#{total_left_row - 1})",
                       nil]
      total_styles = [@styles[:pivot_total_label],
                      @styles[:pivot_total], nil,
                      @styles[:pivot_total], @styles[:pivot_total],
                      @styles[:pivot_total], nil]
      ws.add_row(total_row_left, style: total_styles)

      # Data derecha — fila 4 en adelante en cols I:J
      sorted_com.each_with_index do |(emp, monto), i|
        r = i + 4
        if r <= ws.rows.size
          row_obj = ws.rows[r - 1]
          # Asignar valor a I y J via rangos manuales
          ws[r - 1, 8] = emp if ws.respond_to?(:[])
        end
      end

      # Workaround: caxlsx no permite asignar celdas individuales después. Vamos a
      # reescribir las hojas con un approach distinto: usar add_row con cols nil
      # y luego pasar el array completo.
      ws.column_widths(35, 18, 14, 18, 18, 18, 24, 4, 35, 18)
    end

    # caxlsx no soporta bien edición de celdas post-add_row.
    # Estrategia: reescribir esta hoja con un array de filas combinado.
    wb.sheet_by_name("3. Cruce company")&.tap { |old| }
    # OK, en lugar de eso, regeneramos correctamente abajo:
    _hoja3_regenerate(wb, sorted_rec, sorted_com, cruce_company_data, company_id_por_name)

    cruce_company_data
  end

  # Regeneración limpia de Hoja 3 (caxlsx requiere armar todas las filas a la vez).
  def _hoja3_regenerate(wb, sorted_rec, sorted_com, cruce_company_data, company_id_por_name)
    # Borrar la versión preliminar
    wb.worksheets.delete_if { |w| w.name == "3. Cruce company" }

    wb.add_worksheet(name: "3. Cruce company") do |ws|
      # Fila 1: vacía
      ws.add_row([])
      # Fila 2: títulos
      row2 = ["Query 2 Recaudos"] + Array.new(7, nil) + ["1. Comisión Recaudo"]
      row2_styles = Array.new(row2.size, nil)
      row2_styles[0] = @styles[:bold]
      row2_styles[8] = @styles[:bold]
      ws.add_row(row2, style: row2_styles)

      # Fila 3: headers
      hdrs_left  = ["CLIENTE", "Suma de VAL_AMOUNT", "Porcentaje Real", "Comisión Real",
                    "Comisión Trump", "Dif", "id company"]
      hdrs_right = ["Etiquetas de fila", "Suma de VAL_AMOUNT"]
      row3 = hdrs_left + [nil] + hdrs_right
      row3_styles = Array.new(row3.size, nil)
      hdrs_left.size.times { |i| row3_styles[i] = @styles[:pivot_hdr] }
      row3_styles[8] = @styles[:pivot_hdr]
      row3_styles[9] = @styles[:pivot_hdr]
      ws.add_row(row3, style: row3_styles)

      # Generar filas combinando los dos pivots por índice
      max_rows = [sorted_rec.size, sorted_com.size].max
      max_rows.times do |i|
        r = i + 4

        # Lado izquierdo
        if i < sorted_rec.size
          emp_l, monto_l = sorted_rec[i]
          cid = company_id_por_name[emp_l].to_s
          pct = @fees[cid].to_f
          left = [emp_l, monto_l.round(2), pct,
                  "=B#{r}*C#{r}",
                  "=IFERROR(VLOOKUP(A#{r},I:J,2,0),0)",
                  "=E#{r}-D#{r}",
                  cid]
        else
          left = Array.new(7, nil)
        end

        # Lado derecho
        if i < sorted_com.size
          emp_r, monto_r = sorted_com[i]
          right = [emp_r, monto_r.round(2)]
        else
          right = [nil, nil]
        end

        row = left + [nil] + right
        styles = [
          @styles[:bordered], @styles[:int], @styles[:pct],
          @styles[:dec], @styles[:dec], @styles[:dec], @styles[:bordered],
          nil, @styles[:bordered], @styles[:dec],
        ]
        ws.add_row(row, style: styles)
      end

      # Totales (al final de la sección más larga)
      r_total_l = 4 + sorted_rec.size
      r_total_r = 4 + sorted_com.size
      r_total = [r_total_l, r_total_r].max

      total_row = Array.new(10, nil)
      if sorted_rec.size > 0
        total_row[0] = "Total general"
        total_row[1] = "=SUM(B4:B#{r_total_l - 1})"
        total_row[3] = "=SUM(D4:D#{r_total_l - 1})"
        total_row[4] = "=SUM(E4:E#{r_total_l - 1})"
        total_row[5] = "=SUM(F4:F#{r_total_l - 1})"
      end
      if sorted_com.size > 0
        total_row[8] = "Total general"
        total_row[9] = "=SUM(J4:J#{r_total_r - 1})"
      end
      total_styles = [
        @styles[:pivot_total_label], @styles[:pivot_total], nil,
        @styles[:pivot_total], @styles[:pivot_total], @styles[:pivot_total], nil,
        nil, @styles[:pivot_total_label], @styles[:pivot_total],
      ]
      # Si los totales caen en filas distintas, hay que rellenar — para simplificar,
      # los pongo en la fila r_total (puede que el lado izquierdo o derecho quede
      # con su fila Total general "saltada" pero los SUM son correctos).
      ws.add_row(total_row, style: total_styles)

      ws.column_widths(35, 18, 14, 18, 18, 18, 24, 4, 35, 18)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 4: Cruce Booking (2 pivotes)
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja4(wb)
    # Pivote izquierdo (Hoja 2)
    sumas_book = Hash.new(0.0)
    comp_por_book = {}
    @recaudos.each do |r|
      bid = r["booking_id"].to_s
      next if bid.empty?
      sumas_book[bid] += r["VAL_AMOUNT"].to_f
      comp_por_book[bid] ||= r["Company_name"].to_s
    end
    sorted_book = sumas_book.sort_by { |bid, _| comp_por_book[bid].to_s.downcase }

    # Pivote derecho (Hoja 1)
    sumas_book_com = Hash.new(0.0)
    @comision.each do |r|
      bid = r["booking_id"].to_s
      next if bid.empty?
      sumas_book_com[bid] += r["VAL_AMOUNT"].to_f
    end
    sorted_book_com = sumas_book_com.sort_by { |bid, _| bid }

    wb.add_worksheet(name: "4. Cruce Booking") do |ws|
      ws.add_row([])
      ws.add_row([])
      # Fila 3: títulos
      row3 = ["Query 2 Recaudos"] + Array.new(8, nil) + ["1. Comisión Recaudo"]
      row3_styles = Array.new(row3.size, nil)
      row3_styles[0] = @styles[:bold]
      row3_styles[9] = @styles[:bold]
      ws.add_row(row3, style: row3_styles)

      # Fila 4: headers
      hdrs_left  = ["qtf.booking_id", "Company_name", "Suma de VAL_AMOUNT", "%",
                    "Comisión Manual", "Cruce", "Diferencia", "Comentario"]
      hdrs_right = ["Etiquetas de fila", "Suma de VAL_AMOUNT"]
      row4 = hdrs_left + [nil] + hdrs_right
      row4_styles = Array.new(row4.size, nil)
      hdrs_left.size.times { |i| row4_styles[i] = @styles[:pivot_hdr] }
      row4_styles[9] = @styles[:pivot_hdr]
      row4_styles[10] = @styles[:pivot_hdr]
      ws.add_row(row4, style: row4_styles)

      max_rows = [sorted_book.size, sorted_book_com.size].max
      max_rows.times do |i|
        r = i + 5
        if i < sorted_book.size
          bid, monto = sorted_book[i]
          comp = comp_por_book[bid].to_s
          left = [bid, comp, monto.round(2),
                  "=IFERROR(VLOOKUP(A#{r},'2. Recaudos'!F:K,6,0),0)",
                  "=C#{r}*D#{r}",
                  "=IFERROR(VLOOKUP(A#{r},J:K,2,0),0)",
                  "=E#{r}+F#{r}",
                  nil]
        else
          left = Array.new(8, nil)
        end
        if i < sorted_book_com.size
          bid_r, monto_r = sorted_book_com[i]
          right = [bid_r, monto_r.round(2)]
        else
          right = [nil, nil]
        end
        row = left + [nil] + right
        styles = [
          @styles[:bordered], @styles[:bordered], @styles[:int], @styles[:pct],
          @styles[:dec], @styles[:dec], @styles[:dec], @styles[:bordered],
          nil, @styles[:bordered], @styles[:dec],
        ]
        ws.add_row(row, style: styles)
      end

      # Auto-filter sobre tabla izquierda
      last_row = 4 + sorted_book.size
      begin
        ws.auto_filter = "A4:H#{last_row}"
      rescue
      end

      ws.column_widths(28, 28, 18, 12, 16, 16, 16, 16, 4, 28, 18)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 5: Resumen final
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja5(wb, cruce_company)
    año, mes = @desde.split("-")
    last_day = Date.new(año.to_i, mes.to_i, -1).day rescue 30
    periodo_txt = "1 al #{last_day} #{MESES_ES[mes.to_i]} #{año}"

    clientes = cruce_company.values
      .reject { |info| info[:pct] <= 0 }
      .reject do |info|
        # encontrar el emp_name para filtrar Cruz Verde
        false # filtramos después con el iter completo
      end

    # Iterar el hash completo para conservar el nombre
    filtered = cruce_company.select do |emp, info|
      info[:pct] > 0 && !emp.downcase.include?("cruz verde")
    end.sort_by { |_, info| -info[:recaudos] }

    wb.add_worksheet(name: "Resumen") do |ws|
      # Fila 1: vacía
      ws.add_row([])
      # Fila 2: headers (empiezan en B)
      headers = [nil, "N°", "Cliente", "Recaudo", "%", "Comisión", "Periodo",
                 "Anticipo", "Pendiente", "Estado", "Comentario"]
      header_styles = [nil] + Array.new(10, @styles[:header])
      ws.add_row(headers, style: header_styles)

      filtered.each_with_index do |(emp, info), i|
        r = i + 3
        recaudo_real = @resumen_user[emp].to_f
        row = [
          nil,                                  # col A vacía
          i + 1,                                # B: N°
          emp,                                  # C
          recaudo_real.round(2),                # D: Recaudo
          info[:pct],                           # E: %
          "=D#{r}*-E#{r}",                      # F: Comisión
          periodo_txt,                          # G: Periodo
          "=F#{r}*-1",                          # H: Anticipo
          "=H#{r}+F#{r}",                       # I: Pendiente
          "=IF(I#{r}=0,\"Pagada\",\"Pendiente\")", # J: Estado
          "=IF(J#{r}=\"Pendiente\",\"Cliente con deuda vigente\",\"\")", # K
        ]
        styles = [
          nil, @styles[:bordered], @styles[:bordered], @styles[:int],
          @styles[:pct], @styles[:money_neg_red], @styles[:bordered],
          @styles[:money_neg_red], @styles[:money_neg_red], @styles[:bordered],
          @styles[:bordered],
        ]
        ws.add_row(row, style: styles)
      end

      ws.column_widths(2, 6, 32, 16, 8, 16, 22, 16, 16, 12, 30)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 8: TD company ida y vuelta
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja8(wb)
    # Izquierda: Hoja 7 (filtered + > 0)
    sumas_left = Hash.new(0.0)
    @recaudos.each do |r|
      emp = r["Company_name"].to_s.strip
      next if emp.empty? || empresa_excluida?(emp)
      val = r["VAL_AMOUNT"].to_f
      next if val <= 0
      sumas_left[emp] += val
    end
    sorted_left = sumas_left.sort_by { |emp, _| emp.downcase }

    # Derecha: Hoja 1 COMPLETA (con Surtitodo)
    sumas_right = Hash.new(0.0)
    @comision.each do |r|
      emp = r["Company_name"].to_s.strip
      next if emp.empty?
      sumas_right[emp] += r["VAL_AMOUNT"].to_f
    end
    sorted_right = sumas_right.sort_by { |emp, _| emp.downcase }

    wb.add_worksheet(name: "TD company ida y vuelta") do |ws|
      ws.add_row([])
      # Fila 2: títulos
      row2 = ["2. Recaudos"] + Array.new(6, nil) + ["1. Comisión Recaudo"]
      row2_styles = [@styles[:bold]] + Array.new(6, nil) + [@styles[:bold]]
      ws.add_row(row2, style: row2_styles)

      # Fila 3: headers
      hdrs_left  = ["Etiquetas de fila", "Suma de VAL_AMOUNT", "Porcentaje Real",
                    "Comisión Real", "Comisión Trump", "Dif"]
      hdrs_right = ["Etiquetas de fila", "Suma de VAL_AMOUNT"]
      row3 = hdrs_left + [nil] + hdrs_right
      row3_styles = Array.new(row3.size, nil)
      hdrs_left.size.times { |i| row3_styles[i] = @styles[:pivot_hdr] }
      row3_styles[7] = @styles[:pivot_hdr]
      row3_styles[8] = @styles[:pivot_hdr]
      ws.add_row(row3, style: row3_styles)

      max_rows = [sorted_left.size, sorted_right.size].max
      max_rows.times do |i|
        r = i + 4
        if i < sorted_left.size
          emp, monto = sorted_left[i]
          left = [emp, monto.round(2),
                  "=IFERROR(VLOOKUP(A#{r},'3. Cruce company'!A:C,3,0),0)",
                  "=B#{r}*C#{r}",
                  "=IFERROR(VLOOKUP(A#{r},H:I,2,0),0)",
                  "=D#{r}+E#{r}"]
        else
          left = Array.new(6, nil)
        end
        if i < sorted_right.size
          emp_r, monto_r = sorted_right[i]
          right = [emp_r, monto_r.round(2)]
        else
          right = [nil, nil]
        end
        row = left + [nil] + right
        styles = [
          @styles[:bordered], @styles[:int], @styles[:pct],
          @styles[:dec], @styles[:dec], @styles[:dec],
          nil, @styles[:bordered], @styles[:dec],
        ]
        ws.add_row(row, style: styles)
      end

      # Auto-filter sobre tabla izquierda
      last_row = 3 + sorted_left.size
      begin
        ws.auto_filter = "A3:F#{last_row}"
      rescue
      end

      ws.column_widths(35, 18, 14, 18, 18, 18, 4, 35, 18)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 9: TD Bookings ida y vuelta
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja9(wb)
    # Izquierda: Hoja 7 (Recaudos Ida y Vuelta, filtered)
    sumas_left = Hash.new(0.0)
    comp_por_book = {}
    @recaudos.each do |r|
      bid = r["booking_id"].to_s
      next if bid.empty?
      emp = r["Company_name"].to_s
      next if empresa_excluida?(emp)
      val = r["VAL_AMOUNT"].to_f
      next if val <= 0
      sumas_left[bid] += val
      comp_por_book[bid] ||= emp
    end
    sorted_left = sumas_left.sort_by { |bid, _| comp_por_book[bid].to_s.downcase }

    # Derecha: Hoja 1 completa
    sumas_right = Hash.new(0.0)
    @comision.each do |r|
      bid = r["booking_id"].to_s
      next if bid.empty?
      sumas_right[bid] += r["VAL_AMOUNT"].to_f
    end
    sorted_right = sumas_right.sort_by { |bid, _| bid }

    wb.add_worksheet(name: "TD Bookings ida y vuelta") do |ws|
      ws.add_row([])
      # Fila 2: títulos
      row2 = ["recaudos", "comision manual"] + Array.new(7, nil) + ["comision trump"]
      row2_styles = [@styles[:bold], @styles[:bold]] + Array.new(7, nil) + [@styles[:bold]]
      ws.add_row(row2, style: row2_styles)

      # Fila 3: headers
      hdrs_left  = ["booking_id", "Company_name", "Valor Recaudo", "%",
                    "Comision manual", "cruce % en sistema", "dif"]
      hdrs_right = ["Etiquetas de fila", "Suma de VAL_AMOUNT", "A", "B"]
      row3 = hdrs_left + [nil, nil] + hdrs_right
      row3_styles = Array.new(row3.size, nil)
      hdrs_left.size.times { |i| row3_styles[i] = @styles[:pivot_hdr] }
      hdrs_right.size.times { |i| row3_styles[9 + i] = @styles[:pivot_hdr] }
      ws.add_row(row3, style: row3_styles)

      max_rows = [sorted_left.size, sorted_right.size].max
      max_rows.times do |i|
        r = i + 4
        if i < sorted_left.size
          bid, monto = sorted_left[i]
          comp = comp_por_book[bid].to_s
          left = [bid, comp, monto.round(2),
                  "=IFERROR(VLOOKUP(A#{r},'Recaudos ida y vuelta'!F:K,6,0),0)",
                  "=(C#{r}*D#{r})*-1",
                  "=IFERROR(VLOOKUP(A#{r},J:K,2,0),0)",
                  "=F#{r}-E#{r}"]
        else
          left = Array.new(7, nil)
        end
        if i < sorted_right.size
          bid_r, monto_r = sorted_right[i]
          right = [bid_r, monto_r.round(2),
                   "=IFERROR(VLOOKUP(J#{r},A:D,4,0),0)",
                   "=K#{r}+L#{r}"]
        else
          right = [nil, nil, nil, nil]
        end
        row = left + [nil, nil] + right
        styles = [
          @styles[:bordered], @styles[:bordered], @styles[:int], @styles[:pct],
          @styles[:dec], @styles[:dec], @styles[:dec],
          nil, nil, @styles[:bordered], @styles[:dec], @styles[:pct], @styles[:dec],
        ]
        ws.add_row(row, style: styles)
      end

      # Auto-filter
      last_row = 3 + sorted_left.size
      begin
        ws.auto_filter = "A3:G#{last_row}"
      rescue
      end

      ws.column_widths(28, 28, 18, 12, 16, 16, 16, 4, 4, 28, 18, 12, 14)
    end
  end
end
