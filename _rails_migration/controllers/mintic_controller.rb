# app/controllers/api/mintic_controller.rb
# v3.3.24 — Reporte MINTIC trimestral.
#
# Tres vistas:
#   • detallado_query     → filas crudas de la Q_MINTIC (bookings B2B Pibox CO del trimestre).
#   • detallado_facturas  → facturas PDF extraídas del Drive (vía mintic_facturas/procesar_facturas_mintic.py).
#                            Se leen de un xlsx subido al server por el usuario.
#   • informe_general     → cruce de query + facturas por NIT+período + columnas calculadas
#                            (CIUDAD REAL, CODIGO POSTAL, VALOR COBRADO = GMV / n_paquetes).
#
# El selector de período usa trimestres calendario:
#   1T: 01/01–31/03  |  2T: 01/04–30/06  |  3T: 01/07–30/09  |  4T: 01/10–31/12
#
# Permisos: admin / monitoreo / financiero.

module Api
  class MinticController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol_mintic

    ROLES_PERMITIDOS = %w[admin monitoreo financiero].freeze
    LIMIT_UI         = 5_000

    # Mapeo ciudad → código postal (según convención MINTIC).
    CIUDAD_A_CODIGO_POSTAL = {
      "bogota"        => "11001", "bogotá"   => "11001", "bogota d.c." => "11001", "bogotá d.c." => "11001",
      "envigado"      => "11001",
      "chia"          => "11001", "chía"     => "11001",
      "cali"          => "76001",
      "medellin"      => "5001",  "medellín" => "5001",
    }.freeze

    # Ciudades "alrededores" que se normalizan a Bogotá en la columna CIUDAD REAL.
    CIUDAD_REAL_BOGOTA = %w[
      bogota bogotá envigado chia chía soacha mosquera funza madrid facatativa facatativá
      zipaquira zipaquirá tocancipa tocancipá
    ].freeze

    CIUDAD_REAL_MEDELLIN = %w[
      medellin medellín bello itagui itagüí sabaneta rionegro
    ].freeze

    # GET /api/mintic/detallado_query?trimestre=2&anio=2026
    def detallado_query
      desde, hasta = trimestre_a_fechas(trimestre_param, anio_param)
      rows = ejecutar_query(desde, hasta)
      render json: limpiar({
        ok: true,
        trimestre: trimestre_param,
        anio: anio_param,
        desde: desde, hasta: hasta,
        total: rows.size,
        filas: rows.first(LIMIT_UI),
        stats: stats_query(rows),
      })
    rescue => e
      Rails.logger.error("[MinticController#detallado_query] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/mintic/detallado_facturas?trimestre=2&anio=2026
    def detallado_facturas
      desde, hasta = trimestre_a_fechas(trimestre_param, anio_param)
      facturas = cargar_facturas_xlsx
      filtradas = facturas.select do |f|
        fi = f["Fecha_Inicio_Periodo"]
        ff = f["Fecha_Fin_Periodo"]
        fi.present? && ff.present? &&
          fechas_se_solapan?(parse_fecha_dmy(fi), parse_fecha_dmy(ff), Date.parse(desde), Date.parse(hasta))
      end
      render json: limpiar({
        ok: true,
        trimestre: trimestre_param,
        anio: anio_param,
        desde: desde, hasta: hasta,
        total_disponibles: facturas.size,
        total_periodo: filtradas.size,
        filas: filtradas.first(LIMIT_UI),
        stats: stats_facturas(filtradas),
      })
    rescue => e
      Rails.logger.error("[MinticController#detallado_facturas] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/mintic/informe_general?trimestre=2&anio=2026
    def informe_general
      desde, hasta = trimestre_a_fechas(trimestre_param, anio_param)
      bookings = ejecutar_query(desde, hasta)
      facturas = cargar_facturas_xlsx

      # Index facturas por NIT normalizado para lookup O(1) por booking.
      facturas_por_nit = facturas.group_by { |f| nit_normalizar(f["NIT_Cliente"]) }

      # Pre-cómputo: paquetes por booking (para VALOR COBRADO = GMV / n_paquetes).
      paquetes_por_booking = bookings.group_by { |b| b["Booking_ID"] }
                                     .transform_values(&:size)

      filas = bookings.map do |b|
        nit_b   = nit_normalizar(b["NIT"])
        fecha_b = parse_fecha(b["Fecha_VERDADERA"])
        cand    = facturas_por_nit[nit_b] || []
        factura_match = cand.find do |f|
          fi = parse_fecha_dmy(f["Fecha_Inicio_Periodo"])
          ff = parse_fecha_dmy(f["Fecha_Fin_Periodo"])
          fecha_b && fi && ff && fecha_b.between?(fi, ff)
        end

        ciudad_pibox = b["Ciudad"].to_s
        ciudad_real  = mapear_ciudad_real(ciudad_pibox)
        cod_postal   = codigo_postal_para(ciudad_pibox)
        n_paquetes   = [paquetes_por_booking[b["Booking_ID"]] || 1, 1].max
        gmv          = b["GMV"].to_f
        valor_cobr   = (gmv / n_paquetes).round(2)

        {
          "ID SERVICIO"             => b["Booking_ID"],
          "ID PAQUETE"              => b["id_paquete"],
          "Factura"                 => factura_match ? factura_match["Numero_Factura"] : "",
          "NIT"                     => b["NIT"],
          "TIPO SERVICIO"           => "MASIVO",
          "codigo divipola origen"  => "",
          "codigo divipola destino" => "",
          "CIUDAD ORIGEN"           => ciudad_pibox,
          "CIUDAD DESTINO"          => ciudad_pibox,
          "CODIGO POSTAL ORIGEN"    => cod_postal,
          "CODIGO POSTAL DESTINO"   => cod_postal,
          "FECHA RECEPCIÓN"         => b["Fecha_VERDADERA"].to_s,
          "FECHA ENTREGA"           => b["Fecha_VERDADERA"].to_s,
          "PESO_KG"                 => "5KG",
          "EMPRESA"                 => b["Nombre_Compania"],
          "ESTADO PAQUETE"          => b["Estado_Paquete"],
          "VALOR COBRADO"           => valor_cobr,
          "CIUDAD REAL"             => ciudad_real,
          "FECHA FACTURACION"       => factura_match ? factura_match["Fecha_Emision"] : "",
        }
      end

      # Dedup paquetes únicos (por ID PAQUETE) — para evitar duplicar filas de
      # un mismo booking que aparecen varias veces (1 booking puede tener N paquetes).
      filas_unicas = filas.uniq { |f| [f["ID SERVICIO"], f["ID PAQUETE"]] }

      render json: limpiar({
        ok: true,
        trimestre: trimestre_param,
        anio: anio_param,
        desde: desde, hasta: hasta,
        total: filas_unicas.size,
        con_factura: filas_unicas.count { |f| f["Factura"].present? },
        sin_factura: filas_unicas.count { |f| f["Factura"].blank? },
        filas: filas_unicas.first(LIMIT_UI),
        stats: stats_informe(filas_unicas),
      })
    rescue => e
      Rails.logger.error("[MinticController#informe_general] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/mintic/enviar_email — pendiente Fase 3
    def enviar_email
      render json: { ok: false, error: "Email aún no implementado — pendiente Fase 3" }, status: :not_implemented
    end

    private

    def validar_rol_mintic
      return if ROLES_PERMITIDOS.include?(current_rol.to_s)
      render json: {
        ok: false,
        error: "Acceso restringido — solo roles: #{ROLES_PERMITIDOS.join(', ')}. Tu rol: #{current_rol || 'sin rol'}",
      }, status: :forbidden
    end

    def trimestre_param
      t = params[:trimestre].to_i
      [1, 2, 3, 4].include?(t) ? t : 2  # default 2T
    end

    def anio_param
      a = params[:anio].to_i
      a > 2020 ? a : Date.today.year
    end

    # Devuelve [desde, hasta] como strings "YYYY-MM-DD" para el trimestre dado.
    def trimestre_a_fechas(t, anio)
      ranges = {
        1 => [Date.new(anio,  1,  1), Date.new(anio,  3, 31)],
        2 => [Date.new(anio,  4,  1), Date.new(anio,  6, 30)],
        3 => [Date.new(anio,  7,  1), Date.new(anio,  9, 30)],
        4 => [Date.new(anio, 10,  1), Date.new(anio, 12, 31)],
      }
      d, h = ranges[t]
      [d.strftime("%Y-%m-%d"), h.strftime("%Y-%m-%d")]
    end

    def ejecutar_query(desde, hasta)
      sql = QueriesService.format(QueriesService::Q_MINTIC,
                                  fecha_desde: desde, fecha_hasta: hasta)
      ch.query(sql, timeout: 600)
    end

    # Lee facturas extraídas (JSON) del directorio storage/mintic/.
    # El archivo es generado por el extractor Python (mintic_facturas/procesar_facturas_mintic.py)
    # que escribe un .json paralelo al .xlsx con los mismos campos.
    # Convención: storage/mintic/facturas.json (acumulativo — el usuario lo mantiene).
    # Cada elemento del array tiene los 11 campos del dataclass FacturaExtraida:
    #   Archivo, Numero_Factura, NIT_Cliente, Cliente, Ciudad,
    #   Fecha_Emision, Fecha_Vencimiento, Total_Pagar,
    #   Fecha_Inicio_Periodo, Fecha_Fin_Periodo, Periodo_Completo.
    def cargar_facturas_xlsx
      path = Rails.root.join("storage", "mintic", "facturas.json")
      return [] unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue => e
      Rails.logger.error("[MinticController] Error leyendo facturas.json: #{e.message}")
      []
    end

    # Quita guiones, espacios, y opcionalmente el dígito de verificación (último).
    # Para match: comparar los primeros 9 dígitos del NIT (el DV no es estable).
    def nit_normalizar(nit)
      d = nit.to_s.gsub(/[^\d]/, "")
      return "" if d.empty?
      d.length >= 10 ? d[0..8] : d  # solo los primeros 9 dígitos
    end

    # Parsea "DD/MM/YYYY" → Date.
    def parse_fecha_dmy(s)
      return nil if s.nil? || s.to_s.strip.empty?
      partes = s.to_s.split("/")
      return nil unless partes.size == 3
      Date.new(partes[2].to_i, partes[1].to_i, partes[0].to_i)
    rescue
      nil
    end

    # Parsea "YYYY-MM-DD" o Date → Date.
    def parse_fecha(s)
      return s if s.is_a?(Date)
      Date.parse(s.to_s)
    rescue
      nil
    end

    def fechas_se_solapan?(a_ini, a_fin, b_ini, b_fin)
      return false unless a_ini && a_fin && b_ini && b_fin
      a_ini <= b_fin && b_ini <= a_fin
    end

    def codigo_postal_para(ciudad)
      CIUDAD_A_CODIGO_POSTAL[ciudad.to_s.strip.downcase] || ""
    end

    def mapear_ciudad_real(ciudad)
      c = ciudad.to_s.strip.downcase
      return "Medellin" if CIUDAD_REAL_MEDELLIN.include?(c)
      "Bogota"  # Bogotá + alrededores + cualquier otra
    end

    # Stats agregados sobre las filas crudas del query.
    def stats_query(rows)
      {
        total_bookings:  rows.uniq { |r| r["Booking_ID"] }.size,
        total_paquetes:  rows.size,
        gmv_total:       rows.sum { |r| r["GMV"].to_f }.round(2),
        por_empresa:     rows.group_by { |r| r["Nombre_Compania"].to_s }
                             .map { |k, g| { empresa: k, paquetes: g.size, gmv: g.sum { |r| r["GMV"].to_f }.round(2) } }
                             .sort_by { |h| -h[:paquetes] }
                             .first(20),
        por_ciudad:      rows.group_by { |r| r["Ciudad"].to_s }
                             .map { |k, g| { ciudad: k, paquetes: g.size } }
                             .sort_by { |h| -h[:paquetes] }
                             .first(15),
      }
    end

    def stats_facturas(filas)
      {
        total:        filas.size,
        monto_total:  filas.sum { |f| f["Total_Pagar"].to_f }.round(2),
        por_cliente:  filas.group_by { |f| f["Cliente"].to_s }
                           .map { |k, g| { cliente: k, cant: g.size, monto: g.sum { |f| f["Total_Pagar"].to_f }.round(2) } }
                           .sort_by { |h| -h[:monto] }
                           .first(20),
      }
    end

    def stats_informe(filas)
      por_factura = filas.group_by { |f| f["Factura"].to_s }
                         .map { |k, g| {
                           factura: k.presence || "(sin factura)",
                           paquetes: g.size,
                           valor_cobrado: g.sum { |f| f["VALOR COBRADO"].to_f }.round(2),
                         } }
                         .sort_by { |h| -h[:paquetes] }
      por_empresa = filas.group_by { |f| f["EMPRESA"].to_s }
                         .map { |k, g| {
                           empresa: k,
                           paquetes: g.size,
                           valor_cobrado: g.sum { |f| f["VALOR COBRADO"].to_f }.round(2),
                         } }
                         .sort_by { |h| -h[:paquetes] }
      {
        total:          filas.size,
        valor_total:    filas.sum { |f| f["VALOR COBRADO"].to_f }.round(2),
        por_factura:    por_factura.first(30),
        por_empresa:    por_empresa.first(30),
        total_facturas: (por_factura.map { |h| h[:factura] } - ["(sin factura)"]).size,
        total_empresas: por_empresa.size,
      }
    end

    def limpiar(obj)
      ClickhouseClient.limpiar(obj)
    end
  end
end
