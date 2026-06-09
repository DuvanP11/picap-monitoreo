# app/services/estado_cuenta_excel_builder.rb
# v3.3.31 — Generador Excel "Estado de cuenta SURTITODO" (3 hojas) con caxlsx.
#
# Replica estado_cuenta_bi/generar_estado_cuenta.py (validado abril 2026
# contra la plantilla manual del usuario).
#
# 3 hojas:
#   1. "Resumen"          — Logo Pibox (A1:B4) + título morado (C2:J2 merged)
#                            + SURTITODO header morado + tabla resumen 5 filas.
#   2. "Recaudos"         — Query A (4 cols): ID TRANSACCION, FECHA, DESCRIPCION, MONTO.
#   3. "Valor Mensajeria" — Query B (5 cols): ID SERVICIO, FECHA, EMPRESA, TIPO VEHICULO, MONTO.

require "caxlsx"

class EstadoCuentaExcelBuilder
  COLORS = {
    morado:     "5B21B6",
    morado_dk:  "3B0764",
    white:      "FFFFFF",
    hdr_blue:   "1F4E78",
    lila_lt:    "F3E8FF",
    border:     "B0B0B0",
  }.freeze

  COP_FMT = '_-"$"* #,##0_-;[Red]-"$"* #,##0_-;_-"$"* "-"_-;_-@_-'.freeze
  XLSX_MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze

  MESES_ES = {
    1 => "Enero",      2 => "Febrero", 3 => "Marzo",     4 => "Abril",
    5 => "Mayo",       6 => "Junio",   7 => "Julio",     8 => "Agosto",
    9 => "Septiembre", 10 => "Octubre", 11 => "Noviembre", 12 => "Diciembre",
  }.freeze

  MESES_LOW = MESES_ES.transform_values(&:downcase).freeze

  def self.build(desde:, hasta:, recaudos:, valor_mensajeria:)
    new(desde, hasta, recaudos, valor_mensajeria).call
  end

  def initialize(desde, hasta, recaudos, valor_mensajeria)
    @desde, @hasta = desde, hasta
    @recaudos = recaudos
    @valor_mensajeria = valor_mensajeria
    @info = mes_a_info(desde)
  end

  def call
    pkg = Axlsx::Package.new
    pkg.use_shared_strings = true
    wb = pkg.workbook
    @styles = build_styles(wb)

    write_hoja_resumen(wb)
    write_hoja_recaudos(wb)
    write_hoja_valor_mensajeria(wb)

    {
      data:     pkg.to_stream.read,
      filename: "Estado de cuenta SURTITODO #{@info[:mes_capi]} #{@info[:anio]}.xlsx",
      mimetype: XLSX_MIME,
    }
  end

  private

  def mes_a_info(desde)
    año, mes = desde.split("-")
    año_i, mes_i = año.to_i, mes.to_i
    last_day = Date.new(año_i, mes_i, -1).day
    {
      last_day:     last_day,
      mes_capi:     MESES_ES[mes_i],
      mes_minus:    MESES_LOW[mes_i],
      anio:         año_i,
      periodo_txt:  "Periodo del 01 al #{last_day.to_s.rjust(2, '0')} de #{MESES_LOW[mes_i]} #{año_i}",
    }
  end

  def build_styles(wb)
    s = wb.styles
    {
      titulo_morado: s.add_style(
        b: true, fg_color: COLORS[:morado], sz: 14,
        alignment: { horizontal: :center, vertical: :center, wrap_text: true },
      ),
      surtitodo_header: s.add_style(
        bg_color: COLORS[:morado], fg_color: COLORS[:white],
        b: true, i: true, sz: 14,
        alignment: { horizontal: :center, vertical: :center },
      ),
      periodo: s.add_style(
        b: true, bg_color: COLORS[:lila_lt],
        alignment: { horizontal: :center, vertical: :center },
        border: { style: :thin, color: COLORS[:border] },
      ),
      label_left: s.add_style(
        alignment: { horizontal: :left, vertical: :center },
        border: { style: :thin, color: COLORS[:border] },
      ),
      label_total: s.add_style(
        b: true, bg_color: COLORS[:lila_lt],
        alignment: { horizontal: :left, vertical: :center },
        border: { style: :thin, color: COLORS[:border] },
      ),
      money_value: s.add_style(
        format_code: COP_FMT,
        alignment: { horizontal: :right, vertical: :center },
        border: { style: :thin, color: COLORS[:border] },
      ),
      money_total: s.add_style(
        b: true, bg_color: COLORS[:lila_lt], format_code: COP_FMT,
        alignment: { horizontal: :right, vertical: :center },
        border: { style: :thin, color: COLORS[:border] },
      ),
      header_blue: s.add_style(
        bg_color: COLORS[:hdr_blue], fg_color: COLORS[:white], b: true,
        alignment: { horizontal: :center, vertical: :center },
        border: { style: :thin, color: COLORS[:border] },
      ),
      bordered: s.add_style(border: { style: :thin, color: COLORS[:border] }),
      money_data: s.add_style(
        format_code: COP_FMT,
        border: { style: :thin, color: COLORS[:border] },
      ),
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

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 1: Resumen (logo + título + tabla con fórmulas)
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja_resumen(wb)
    wb.add_worksheet(name: "Resumen") do |ws|
      # ── Anchos de columnas ──
      ws.column_widths(14, 32, 24, 14, 14, 14, 14, 14, 14, 14)

      # ── Alturas de filas ──
      ws.add_row([])  # F1 vacía (con altura para logo)
      ws.add_row([])  # F2: ahora vamos a agregar el título C2

      # Reescribir F1 y F2 — caxlsx no permite re-editar fácil después de add_row.
      # Mejor armar el flow completo de la hoja con add_row.

      # Voy a construir la hoja entera de nuevo para tener control fila a fila.
      ws.rows.clear if ws.respond_to?(:rows) && ws.rows.respond_to?(:clear)

      # F1 vacía
      ws.add_row([nil, nil, nil, nil, nil, nil, nil, nil, nil, nil])
      ws.rows.last.height = 28

      # F2: título morado en C2:J2 (merged después)
      titulo = "Informe recaudo (pagos contra entrega) y costo de la operación de mensajería"
      ws.add_row([nil, nil, titulo, nil, nil, nil, nil, nil, nil, nil],
                 style: [nil, nil, @styles[:titulo_morado], nil, nil, nil, nil, nil, nil, nil])
      ws.rows.last.height = 28
      ws.merge_cells("C2:J2")

      # F3, F4: vacías (para el logo)
      ws.add_row([])
      ws.rows.last.height = 28
      ws.add_row([])
      ws.rows.last.height = 28

      # F5: SURTITODO (B5:C5 merged) — morado fill, white bold italic
      ws.add_row([nil, "SURTITODO", nil],
                 style: [nil, @styles[:surtitodo_header], @styles[:surtitodo_header]])
      ws.rows.last.height = 28
      ws.merge_cells("B5:C5")

      # F6: Período (B6:C6 merged)
      ws.add_row([nil, @info[:periodo_txt], nil],
                 style: [nil, @styles[:periodo], @styles[:periodo]])
      ws.rows.last.height = 24
      ws.merge_cells("B6:C6")

      # v3.3.51: fórmulas con referencias CORREGIDAS según plantilla del usuario.
      # La plantilla original (ejemplo Mayo 2026.xlsx) usa:
      #   C9:  =SUM(Recaudos!D:D)
      #   C10: =SUM('Valor Mensajeria'!E:E)
      #   C11: =-(C9*1%)       ← referencia C9 (no C7)
      #   C12: =(-C10*9.66)/1000 ← referencia C10 (no C8)
      #   C13: =SUM(C9:C12)    ← rango C9:C12 (no C7:C10)
      # El bug original era off-by-2 en las referencias. v3.3.50 lo "arregló"
      # poniendo valores directos, pero el usuario prefiere las fórmulas
      # vivas para poder editar y recalcular. Volvemos a fórmulas, ahora
      # con las referencias correctas.

      # F9-F12: tabla resumen con fórmulas
      [
        ["Recaudos",          "=SUM(Recaudos!D:D)"],
        ["Pago Servicios",    "=SUM('Valor Mensajeria'!E:E)"],
        ["Comisión del 1%",   "=-(C9*1%)"],
        ["ICA",               "=(-C10*9.66)/1000"],
      ].each do |label, formula|
        ws.add_row([nil, label, formula],
                   style: [nil, @styles[:label_left], @styles[:money_value]])
        ws.rows.last.height = 22
      end

      # F13: total (resaltado morado claro)
      ws.add_row([nil, "valor a pagar despues del cruce:", "=SUM(C9:C12)"],
                 style: [nil, @styles[:label_total], @styles[:money_total]])
      ws.rows.last.height = 24

      # ── Imagen Pibox (A1:B4) ──
      logo_path = encontrar_logo_path
      if logo_path
        begin
          ws.add_image(image_src: logo_path, noSelect: true, noMove: false) do |img|
            img.width  = 140
            img.height = 100
            img.start_at(0, 0)  # A1 (col 0, row 0)
          end
        rescue => e
          Rails.logger.warn("[EstadoCuentaExcelBuilder] No se pudo insertar logo: #{e.message}")
        end
      end
    end
  end

  def encontrar_logo_path
    # Buscar el logo en orden de preferencia
    candidates = [
      Rails.root.join("public", "images", "pibox_logo.png"),
      Rails.root.join("app", "assets", "images", "pibox_logo.png"),
    ]
    candidates.find { |p| File.exist?(p) }&.to_s
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 2: Recaudos
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja_recaudos(wb)
    wb.add_worksheet(name: "Recaudos") do |ws|
      headers = ["ID TRANSACCION", "FECHA", "DESCRIPCION", "MONTO"]
      ws.add_row(headers, style: Array.new(headers.size, @styles[:header_blue]))

      @recaudos.each do |r|
        values = [
          coerce(r["ID_TRANSACCION"]),
          coerce(r["FECHA"]),
          coerce(r["DESCRIPCION"]),
          coerce(r["MONTO"]),
        ]
        ws.add_row(values, style: [@styles[:bordered], @styles[:bordered], @styles[:bordered], @styles[:money_data]])
      end

      ws.column_widths(28, 14, 18, 18)
      ws.sheet_view.pane do |p|
        p.state = :frozen
        p.y_split = 1
        p.top_left_cell = "A2"
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # Hoja 3: Valor Mensajeria
  # ──────────────────────────────────────────────────────────────────────

  def write_hoja_valor_mensajeria(wb)
    wb.add_worksheet(name: "Valor Mensajeria") do |ws|
      headers = ["ID SERVICIO", "FECHA", "EMPRESA", "TIPO VEHICULO", "MONTO"]
      ws.add_row(headers, style: Array.new(headers.size, @styles[:header_blue]))

      @valor_mensajeria.each do |r|
        values = [
          coerce(r["ID_SERVICIO"]),
          coerce(r["FECHA"]),
          coerce(r["EMPRESA"]),
          coerce(r["TIPO_VEHICULO"]),
          coerce(r["MONTO"]),
        ]
        ws.add_row(values, style: [@styles[:bordered], @styles[:bordered], @styles[:bordered],
                                    @styles[:bordered], @styles[:money_data]])
      end

      ws.column_widths(28, 14, 28, 22, 18)
      ws.sheet_view.pane do |p|
        p.state = :frozen
        p.y_split = 1
        p.top_left_cell = "A2"
      end
    end
  end
end
