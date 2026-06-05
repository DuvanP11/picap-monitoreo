# app/services/recaudos_dispersiones_excel_builder.rb
# v3.3.30 — Generador Excel "Recaudos y Dispersiones" (7 hojas) con caxlsx.
#
# Replica EXACTAMENTE recaudos_dispersiones_bi/generar_recaudos_dispersiones.py
# (validado contra plantilla del usuario abril 2026 al 100%).
#
# 7 hojas:
#   1. "Dispersiones 1 al {N} {mes}"   — Query A data cruda 7 cols.
#   2. "Dispersion 1 al {N} {mes}"     — Pivote Company + tipo + Σ.
#   3. "Acumulado Dispersion"          — Tabla manual con corte (header morado).
#   4. "Data Recaudos"                 — Query B 22 cols.
#   5. "TD Recaudos"                   — Pivote User_Company + Σ + Tipo de cliente.
#   6. "Recaudo 1 al {N} {MES}"        — Surtitodo (header morado).
#   7. "Acumulado R"                   — Surtitodo + corte (header morado).

require "caxlsx"

class RecaudosDispersionesExcelBuilder
  COLORS = {
    hdr_blue:    "1F4E78",
    morado:      "5B2169",
    white:       "FFFFFF",
    pivot_hdr:   "D9E1F2",
    pivot_total: "FFE699",
    border_gray: "B0B0B0",
  }.freeze

  HEADERS_DISPERSIONES = [
    "wat._id", "created_at", "amount_cents", "wat._type",
    "company_id", "Company_name", "tipo_dispersion",
  ].freeze

  HEADERS_RECAUDOS = [
    "Date_transaction", "Transaction_currency", "Transaction_amount", "Transaction_ID",
    "Normalized_Amount_After_Transaction", "Date_booking", "ID_Booking", "ID_Package",
    "Reference", "ID_User", "User_Company", "User_Name", "Declared_Value",
    "transaction_state_cd", "ID_Driver", "Driver_Name", "type", "service_type_name",
    "Ciudad", "name_vehicle", "score_rent_fixed", "score_pibox_fixed",
  ].freeze

  # Mapeo CH → Hoja 1 (algunos campos vienen con underscore desde CH)
  MAP_DISPERSIONES = {
    "_id"              => "wat._id",
    "created_at"       => "created_at",
    "amount_cents"     => "amount_cents",
    "_type"            => "wat._type",
    "company_id"       => "company_id",
    "Company_name"     => "Company_name",
    "tipo_dispersion"  => "tipo_dispersion",
  }.freeze

  PRUEBA_KEYWORDS = %w[pibox\ admin testeo prueba qa test].freeze

  INT_FMT  = "#,##0".freeze
  XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze

  MESES_ES = {
    1 => "Enero", 2 => "Febrero", 3 => "Marzo", 4 => "Abril",
    5 => "Mayo", 6 => "Junio", 7 => "Julio", 8 => "Agosto",
    9 => "Septiembre", 10 => "Octubre", 11 => "Noviembre", 12 => "Diciembre",
  }.freeze

  def self.build(desde:, hasta:, dispersiones:, recaudos:)
    new(desde, hasta, dispersiones, recaudos).call
  end

  def initialize(desde, hasta, dispersiones, recaudos)
    @desde, @hasta = desde, hasta
    @dispersiones = dispersiones
    @recaudos = recaudos
    @info = mes_a_info(desde)
  end

  def call
    pkg = Axlsx::Package.new
    pkg.use_shared_strings = true
    wb = pkg.workbook

    @styles = build_styles(wb)

    write_hoja1(wb)
    por_empresa_disp = write_hoja2(wb)
    write_hoja3(wb, por_empresa_disp)
    write_hoja4(wb)
    pivot_recaudos = write_hoja5(wb)
    write_hoja6(wb, pivot_recaudos)
    write_hoja7(wb, pivot_recaudos)

    {
      data:     pkg.to_stream.read,
      filename: "Recaudos y Dispersiones #{@info[:mes_nombre]} #{@info[:anio]}.xlsx",
      mimetype: XLSX_MIME,
    }
  end

  private

  def build_styles(wb)
    s = wb.styles
    {
      header_blue: s.add_style(
        bg_color: COLORS[:hdr_blue], fg_color: COLORS[:white], b: true, sz: 11,
        alignment: { horizontal: :left, vertical: :center },
      ),
      header_morado: s.add_style(
        bg_color: COLORS[:morado], fg_color: COLORS[:white], b: true, sz: 11,
        alignment: { horizontal: :left, vertical: :center },
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
      int: s.add_style(format_code: INT_FMT, border: { style: :thin, color: COLORS[:border_gray] }),
      bordered: s.add_style(border: { style: :thin, color: COLORS[:border_gray] }),
    }
  end

  def mes_a_info(desde)
    año, mes = desde.split("-")
    año_i, mes_i = año.to_i, mes.to_i
    last_day = Date.new(año_i, mes_i, -1).day
    mes_nombre = MESES_ES[mes_i]
    {
      last_day:    last_day,
      mes_nombre:  mes_nombre,
      mes_minus:   mes_nombre.downcase,
      mes_mayus:   mes_nombre.upcase,
      anio:        año_i,
      hoja_dispersiones:    "Dispersiones 1 al #{last_day} #{mes_nombre.downcase}",
      hoja_dispersion_pivot: "Dispersion 1 al #{last_day} #{mes_nombre.downcase}",
      hoja_recaudo:         "Recaudo 1 al #{last_day} #{mes_nombre.upcase}",
      corte:                "1 TO #{last_day} #{mes_nombre.upcase}",
    }
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

  def es_surtitodo?(empresa)
    empresa.to_s.downcase.strip.include?("surtitodo")
  end

  def tipo_cliente(empresa)
    return "ida y vuelta" if empresa.to_s.strip.empty?
    n = empresa.to_s.downcase.strip
    return "Reportar" if n.include?("surtitodo")
    return "prueba" if PRUEBA_KEYWORDS.any? { |kw| n.include?(kw) }
    "ida y vuelta"
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 1: Dispersiones (data cruda)
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja1(wb)
    wb.add_worksheet(name: @info[:hoja_dispersiones]) do |ws|
      ws.add_row(HEADERS_DISPERSIONES, style: Array.new(HEADERS_DISPERSIONES.size, @styles[:header_blue]))
      @dispersiones.each do |r|
        values = HEADERS_DISPERSIONES.map do |hdr_excel|
          hdr_ch = MAP_DISPERSIONES.find { |_k, v| v == hdr_excel }&.first || hdr_excel
          coerce(r[hdr_ch])
        end
        row_styles = Array.new(HEADERS_DISPERSIONES.size, nil)
        row_styles[2] = @styles[:int]  # amount_cents
        ws.add_row(values, style: row_styles)
      end
      ws.column_widths(28, 14, 16, 50, 26, 26, 24)
      ws.sheet_view.pane do |p|
        p.state = :frozen
        p.y_split = 1
        p.top_left_cell = "A2"
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 2: Pivote dispersiones
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja2(wb)
    pivot_kv = Hash.new(0.0)
    @dispersiones.each do |r|
      emp = r["Company_name"].to_s.strip
      tip = r["tipo_dispersion"].to_s
      next if emp.empty?
      pivot_kv[[emp, tip]] += r["amount_cents"].to_f
    end
    sorted = pivot_kv.sort_by { |(emp, _), _| emp.downcase }

    # Por empresa (sumando todos los tipos), para hoja 3
    por_empresa = Hash.new(0.0)
    pivot_kv.each { |(emp, _), m| por_empresa[emp] += m }

    wb.add_worksheet(name: @info[:hoja_dispersion_pivot]) do |ws|
      ws.add_row(["Company_name", "tipo_dispersion", "Suma de amount_cents"],
                 style: [@styles[:pivot_hdr], @styles[:pivot_hdr], @styles[:pivot_hdr]])
      sorted.each do |(emp, tip), monto|
        ws.add_row([emp, tip, monto.round(2)],
                   style: [@styles[:bordered], @styles[:bordered], @styles[:int]])
      end
      total = sorted.sum { |_, m| m }
      ws.add_row(["Total general", nil, total.round(2)],
                 style: [@styles[:pivot_total_label], @styles[:pivot_total_label], @styles[:pivot_total]])
      ws.column_widths(30, 22, 22)
    end

    por_empresa
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 3: Acumulado Dispersion (con corte)
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja3(wb, por_empresa_disp)
    wb.add_worksheet(name: "Acumulado Dispersion") do |ws|
      ws.add_row(["Company_name", "MONTO", "CORTE"],
                 style: [@styles[:header_morado], @styles[:header_morado], @styles[:header_morado]])
      por_empresa_disp.sort_by { |emp, _| emp.downcase }.each do |emp, monto|
        ws.add_row([emp, monto.round(2), @info[:corte]],
                   style: [@styles[:bordered], @styles[:int], @styles[:bordered]])
      end
      ws.column_widths(28, 18, 22)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 4: Data Recaudos (22 cols)
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja4(wb)
    wb.add_worksheet(name: "Data Recaudos") do |ws|
      ws.add_row(HEADERS_RECAUDOS, style: Array.new(HEADERS_RECAUDOS.size, @styles[:header_blue]))
      @recaudos.each do |r|
        values = HEADERS_RECAUDOS.map { |h| coerce(r[h]) }
        row_styles = Array.new(HEADERS_RECAUDOS.size, nil)
        row_styles[2] = @styles[:int]   # Transaction_amount
        row_styles[4] = @styles[:int]   # Normalized
        row_styles[12] = @styles[:int]  # Declared_Value
        ws.add_row(values, style: row_styles)
      end
      ws.column_widths(*Array.new(HEADERS_RECAUDOS.size, 18))
      ws.sheet_view.pane do |p|
        p.state = :frozen
        p.y_split = 1
        p.top_left_cell = "A2"
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 5: TD Recaudos (pivote + tipología)
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja5(wb)
    pivot = Hash.new(0.0)
    @recaudos.each do |r|
      emp = r["User_Company"].to_s.strip
      next if emp.empty?
      pivot[emp] += r["Transaction_amount"].to_f
    end
    sorted = pivot.sort_by { |_, m| -m }

    wb.add_worksheet(name: "TD Recaudos") do |ws|
      # Filas 1-2 vacías (mimic pivot layout), headers en fila 3
      ws.add_row([])
      ws.add_row([])
      ws.add_row(["Etiquetas de fila", "Suma de Transaction_amount", "Tipo de cliente"],
                 style: [@styles[:pivot_hdr], @styles[:pivot_hdr], @styles[:pivot_hdr]])
      sorted.each do |emp, monto|
        ws.add_row([emp, monto.round(2), tipo_cliente(emp)],
                   style: [@styles[:bordered], @styles[:int], @styles[:bordered]])
      end
      total = sorted.sum { |_, m| m }
      ws.add_row(["Total general", total.round(2), nil],
                 style: [@styles[:pivot_total_label], @styles[:pivot_total], @styles[:pivot_total_label]])
      ws.column_widths(34, 24, 18)
    end

    pivot
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 6: Recaudo {periodo} — Surtitodo
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja6(wb, pivot_recaudos)
    surt_monto = pivot_recaudos
      .select { |emp, _| es_surtitodo?(emp) }
      .values
      .sum

    wb.add_worksheet(name: @info[:hoja_recaudo]) do |ws|
      ws.add_row(["cliente", "MONTO"],
                 style: [@styles[:header_morado], @styles[:header_morado]])
      ws.add_row(["Surtitodo", surt_monto.round(2)],
                 style: [@styles[:bordered], @styles[:int]])
      ws.column_widths(24, 22)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 7: Acumulado R — Surtitodo + corte
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja7(wb, pivot_recaudos)
    surt_monto = pivot_recaudos
      .select { |emp, _| es_surtitodo?(emp) }
      .values
      .sum

    wb.add_worksheet(name: "Acumulado R") do |ws|
      ws.add_row(["cliente", "MONTO", "CORTE"],
                 style: [@styles[:header_morado], @styles[:header_morado], @styles[:header_morado]])
      ws.add_row(["Surtitodo", surt_monto.round(2), @info[:corte]],
                 style: [@styles[:bordered], @styles[:int], @styles[:bordered]])
      ws.column_widths(24, 22, 22)
    end
  end
end
