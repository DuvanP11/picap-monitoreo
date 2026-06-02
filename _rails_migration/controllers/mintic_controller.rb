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

    # Storage en memoria de jobs async. Persiste mientras vive el proceso del
    # Rails (suficiente para queries de 1-5 min). Cleanup automático a los 30 min.
    # En producción con múltiples workers cada uno tiene su propio @@jobs, pero
    # como ArgoCD usa típicamente 1-2 réplicas la chance de "mismatch" es baja.
    @@jobs = {}
    @@jobs_mutex = Mutex.new

    JOB_TTL_SEC = 1_800  # 30 min — después se descartan automáticamente

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
    # ASYNC: devuelve 202 + job_id. Thread ejecuta la query en background.
    # Frontend hace polling vía GET /api/mintic/job_status/:job_id.
    def detallado_query
      desde, hasta = trimestre_a_fechas(trimestre_param, anio_param)
      kind  = "detallado_query"
      cache_key = "#{kind}_#{trimestre_param}_#{anio_param}"

      # Si ya hay un job done para esta combinación, devolverlo directo.
      hit = buscar_job_done(cache_key)
      return render(json: hit[:result]) if hit

      job_id = lanzar_job(cache_key, kind, trimestre_param, anio_param) do
        rows = ejecutar_query(desde, hasta)
        limpiar({
          ok: true, async: false,
          trimestre: trimestre_param, anio: anio_param,
          desde: desde, hasta: hasta,
          total: rows.size,
          filas: rows.first(LIMIT_UI),
          stats: stats_query(rows),
        })
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[MinticController#detallado_query] #{e.class}: #{e.message}")
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
    # ASYNC: devuelve 202 + job_id (corre la Q_MINTIC en background + match facturas).
    def informe_general
      desde, hasta = trimestre_a_fechas(trimestre_param, anio_param)
      kind  = "informe_general"
      cache_key = "#{kind}_#{trimestre_param}_#{anio_param}"

      hit = buscar_job_done(cache_key)
      return render(json: hit[:result]) if hit

      job_id = lanzar_job(cache_key, kind, trimestre_param, anio_param) do
        _informe_general_compute(desde, hasta)
      end

      render json: { ok: true, async: true, job_id: job_id, status: "queued" }, status: :accepted
    rescue => e
      Rails.logger.error("[MinticController#informe_general] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/mintic/job_status/:job_id
    # Polling del estado de un job lanzado por detallado_query / informe_general.
    # Devuelve:
    #   - 202 + {status: 'running', elapsed: Xs}      → aún corriendo
    #   - 200 + {ok: true, ...resultado...}           → terminado OK
    #   - 500 + {ok: false, error: msg}               → falló
    #   - 404 + {ok: false, error: 'job no existe'}   → no encontrado o expirado
    def job_status
      job_id = params[:job_id].to_s
      cleanup_old_jobs
      @@jobs_mutex.synchronize do
        job = @@jobs[job_id]
        return render(json: { ok: false, error: "Job no encontrado o expirado (>30 min)" }, status: :not_found) if job.nil?
        case job[:status]
        when :done
          render json: job[:result]
        when :error
          render json: { ok: false, error: job[:error], job_id: job_id }, status: :internal_server_error
        else
          elapsed = (Time.now - job[:t0]).round(1)
          render json: {
            ok: true, async: true, status: "running",
            elapsed_sec: elapsed, job_id: job_id,
            kind: job[:kind], trimestre: job[:trimestre], anio: job[:anio],
          }, status: :accepted
        end
      end
    end

    private

    # Helper: lanza un job en background. Devuelve job_id.
    def lanzar_job(cache_key, kind, trimestre, anio, &block)
      job_id = SecureRandom.hex(16)
      @@jobs_mutex.synchronize do
        @@jobs[job_id] = {
          status: :running,
          kind: kind, trimestre: trimestre, anio: anio,
          cache_key: cache_key,
          t0: Time.now,
        }
      end
      Thread.new do
        begin
          result = block.call
          @@jobs_mutex.synchronize do
            @@jobs[job_id][:status] = :done
            @@jobs[job_id][:result] = result
            @@jobs[job_id][:t_elapsed] = Time.now - @@jobs[job_id][:t0]
          end
          Rails.logger.info("[MinticJob #{job_id}] #{kind} OK en #{@@jobs[job_id][:t_elapsed].round(1)}s")
        rescue => e
          Rails.logger.error("[MinticJob #{job_id}] #{e.class}: #{e.message}")
          Rails.logger.error(e.backtrace.first(8).join("\n"))
          @@jobs_mutex.synchronize do
            @@jobs[job_id][:status] = :error
            @@jobs[job_id][:error] = e.message
          end
        end
      end
      job_id
    end

    # Si existe un job done para esta cache_key (≤30 min) lo devuelve para reuso.
    def buscar_job_done(cache_key)
      @@jobs_mutex.synchronize do
        @@jobs.values.find { |j| j[:cache_key] == cache_key && j[:status] == :done }
      end
    end

    def cleanup_old_jobs
      now = Time.now
      @@jobs_mutex.synchronize do
        @@jobs.delete_if { |_id, job| now - job[:t0] > JOB_TTL_SEC }
      end
    end

    # Lógica original de informe_general extraída para reuso desde el Thread.
    def _informe_general_compute(desde, hasta)
      bookings = ejecutar_query(desde, hasta)
      facturas = cargar_facturas_xlsx

      # Index facturas por NIT normalizado para lookup O(1) por booking.
      facturas_por_nit = facturas.group_by { |f| nit_normalizar(f["NIT_Cliente"]) }

      # Pre-cómputo: paquetes por booking.
      paquetes_por_booking = bookings.group_by { |b| b["Booking_ID"] }
                                     .transform_values(&:size)

      # PASO 1: pre-asignar factura a cada booking + calcular ΣGMV por factura.
      # La invariante MINTIC pide que ΣVALOR_COBRADO por factura = Total_Pagar
      # de esa factura. Para que cuadre, distribuimos el Total_Pagar entre
      # los bookings de la factura PROPORCIONAL al GMV de cada booking, y luego
      # entre sus paquetes en partes iguales:
      #
      #   ΣGMV_factura  = Σ_bookings_de_la_factura (GMV_booking)
      #   % booking     = GMV_booking / ΣGMV_factura
      #   valor_cobr_pq = (% booking) × Total_Pagar_factura / n_paquetes_booking
      #
      # Eso garantiza Σ_paquetes_factura (valor_cobr_pq) = Total_Pagar_factura.
      bookings_unicos = bookings.uniq { |b| b["Booking_ID"] }
      factura_por_booking = {}  # booking_id => factura_match (o nil)
      gmv_por_factura     = Hash.new(0.0)  # numero_factura => ΣGMV

      bookings_unicos.each do |b|
        nit_b   = nit_normalizar(b["NIT"])
        fecha_b = parse_fecha(b["Fecha_VERDADERA"])
        cand    = facturas_por_nit[nit_b] || []
        f_match = cand.find do |f|
          fi = parse_fecha_dmy(f["Fecha_Inicio_Periodo"])
          ff = parse_fecha_dmy(f["Fecha_Fin_Periodo"])
          fecha_b && fi && ff && fecha_b.between?(fi, ff)
        end
        factura_por_booking[b["Booking_ID"]] = f_match
        if f_match
          gmv_por_factura[f_match["Numero_Factura"]] += b["GMV"].to_f
        end
      end

      # PASO 2: armar las filas con el VALOR COBRADO ya derivado.
      filas = bookings.map do |b|
        f_match = factura_por_booking[b["Booking_ID"]]
        ciudad_pibox = b["Ciudad"].to_s
        ciudad_real  = mapear_ciudad_real(ciudad_pibox)
        cod_postal   = codigo_postal_para(ciudad_pibox)
        n_paquetes   = [paquetes_por_booking[b["Booking_ID"]] || 1, 1].max
        gmv          = b["GMV"].to_f

        # Calcular VALOR COBRADO según la fórmula proporcional. Sin factura
        # matcheada, fallback al cálculo bruto (GMV / n_paquetes) y se marca
        # como "(sin factura)" en el campo Factura.
        if f_match
          sum_gmv_fac  = gmv_por_factura[f_match["Numero_Factura"]]
          total_pagar  = f_match["Total_Pagar"].to_f
          pct          = sum_gmv_fac > 0 ? (gmv / sum_gmv_fac) : 0.0
          valor_cobr   = ((pct * total_pagar) / n_paquetes).round(2)
        else
          valor_cobr   = (gmv / n_paquetes).round(2)
        end

        {
          "ID SERVICIO"             => b["Booking_ID"],
          "ID PAQUETE"              => b["id_paquete"],
          "Factura"                 => f_match ? f_match["Numero_Factura"] : "",
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
          "FECHA FACTURACION"       => f_match ? f_match["Fecha_Emision"] : "",
        }
      end

      # Dedup paquetes únicos (por ID PAQUETE) — para evitar duplicar filas de
      # un mismo booking que aparecen varias veces (1 booking puede tener N paquetes).
      filas_unicas = filas.uniq { |f| [f["ID SERVICIO"], f["ID PAQUETE"]] }

      limpiar({
        ok: true,
        trimestre: trimestre_param,
        anio: anio_param,
        desde: desde, hasta: hasta,
        total: filas_unicas.size,
        con_factura: filas_unicas.count { |f| f["Factura"].present? },
        sin_factura: filas_unicas.count { |f| f["Factura"].blank? },
        filas: filas_unicas.first(LIMIT_UI),
        stats: stats_informe(filas_unicas, facturas),
      })
    end

    public

    # POST /api/mintic/upload_facturas
    # Recibe el JSON de facturas (generado por mintic_facturas/procesar_facturas_mintic.py)
    # y lo guarda en storage/mintic/facturas.json para uso del controller.
    def upload_facturas
      archivo = params[:archivo] || params[:file]
      contenido = nil
      if archivo.respond_to?(:read)
        contenido = archivo.read
      elsif params[:json].is_a?(String) && params[:json].present?
        contenido = params[:json]
      elsif request.body.respond_to?(:read)
        request.body.rewind rescue nil
        contenido = request.body.read
      end

      if contenido.blank?
        return render(json: { ok: false, error: "Falta el archivo. Subí el JSON en el campo 'archivo' (multipart) o como body JSON." }, status: :bad_request)
      end

      begin
        data = JSON.parse(contenido)
        raise "Esperaba un array de facturas" unless data.is_a?(Array)
        raise "Array vacío" if data.empty?
        primera = data.first
        %w[Numero_Factura NIT_Cliente Cliente Total_Pagar Fecha_Inicio_Periodo Fecha_Fin_Periodo Fecha_Emision].each do |campo|
          raise "Falta el campo '#{campo}' en las facturas (la primera tiene: #{primera.keys.join(', ')})" unless primera.key?(campo)
        end
      rescue JSON::ParserError => e
        return render(json: { ok: false, error: "JSON inválido: #{e.message}" }, status: :bad_request)
      rescue => e
        return render(json: { ok: false, error: e.message }, status: :bad_request)
      end

      # tmp/ siempre es escribible en Rails (el código en /app/ es read-only
      # en el contenedor k8s, así que /app/storage NO se puede escribir).
      path = mintic_facturas_path
      FileUtils.mkdir_p(path.dirname)
      File.write(path, contenido)

      # Pre-cómputo de stats útiles para mostrar al usuario.
      total_pagar = data.sum { |f| f["Total_Pagar"].to_f }.round(2)
      clientes_uniques = data.map { |f| f["Cliente"] }.uniq.compact.size
      facturas_min = data.map { |f| f["Numero_Factura"] }.compact.min
      facturas_max = data.map { |f| f["Numero_Factura"] }.compact.max

      render json: {
        ok: true,
        total_cargadas: data.size,
        total_pagar_acumulado: total_pagar,
        clientes_distintos: clientes_uniques,
        rango_facturas: "#{facturas_min} → #{facturas_max}",
        guardado_en: "tmp/mintic/facturas.json",
        mensaje: "✓ facturas.json cargado. Recargá la tab 'Detallado Facturas' o 'Informe General' para ver el match. NOTA: el archivo se pierde si el pod reinicia — re-subilo después de cada deploy.",
      }
    rescue => e
      Rails.logger.error("[MinticController#upload_facturas] #{e.class}: #{e.message}")
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
      t0 = Time.now
      Rails.logger.info("[MinticController] Q_MINTIC inicio (desde=#{desde} hasta=#{hasta})")
      rows = ch.query(sql, timeout: 600)
      Rails.logger.info("[MinticController] Q_MINTIC OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    # Lee facturas extraídas (JSON) del directorio tmp/mintic/.
    # El archivo es generado por el extractor Python (mintic_facturas/procesar_facturas_mintic.py)
    # que escribe un .json paralelo al .xlsx con los mismos campos.
    # Convención: tmp/mintic/facturas.json (acumulativo — el usuario lo sube vía /upload_facturas).
    # OJO: en k8s el directorio /app/storage es read-only, por eso usamos tmp/
    # (Rails.root.join("tmp") siempre es escribible). Trade-off: se pierde
    # al reiniciar el pod — el operador re-sube el JSON.
    # Cada elemento del array tiene los 11 campos del dataclass FacturaExtraida:
    #   Archivo, Numero_Factura, NIT_Cliente, Cliente, Ciudad,
    #   Fecha_Emision, Fecha_Vencimiento, Total_Pagar,
    #   Fecha_Inicio_Periodo, Fecha_Fin_Periodo, Periodo_Completo.
    def cargar_facturas_xlsx
      path = mintic_facturas_path
      return [] unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue => e
      Rails.logger.error("[MinticController] Error leyendo facturas.json: #{e.message}")
      []
    end

    def mintic_facturas_path
      Rails.root.join("tmp", "mintic", "facturas.json")
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

    def stats_informe(filas, facturas_disponibles = [])
      # Index de facturas por número para poder mostrar el Total_Pagar real.
      facturas_idx = facturas_disponibles.index_by { |f| f["Numero_Factura"].to_s }

      por_factura = filas.group_by { |f| f["Factura"].to_s }
                         .map { |k, g|
                           total_pagar_real = facturas_idx[k] ? facturas_idx[k]["Total_Pagar"].to_f : nil
                           suma_calc        = g.sum { |f| f["VALOR COBRADO"].to_f }.round(2)
                           diff             = total_pagar_real ? (suma_calc - total_pagar_real).round(2) : nil
                           {
                             factura: k.presence || "(sin factura)",
                             paquetes: g.size,
                             valor_cobrado_query: suma_calc,
                             total_pagar_factura: total_pagar_real,
                             diff: diff,
                             cuadra: diff.nil? ? nil : diff.abs < 0.5,  # tolerancia 0.5 COP
                           }
                         }
                         .sort_by { |h| -h[:paquetes] }
      por_empresa = filas.group_by { |f| f["EMPRESA"].to_s }
                         .map { |k, g| {
                           empresa: k,
                           paquetes: g.size,
                           valor_cobrado: g.sum { |f| f["VALOR COBRADO"].to_f }.round(2),
                         } }
                         .sort_by { |h| -h[:paquetes] }

      # Reconciliación global: cuántas facturas cuadran exacto, cuántas no.
      cuadran      = por_factura.count { |h| h[:cuadra] == true }
      no_cuadran   = por_factura.count { |h| h[:cuadra] == false }
      sin_factura  = por_factura.count { |h| h[:cuadra].nil? }

      {
        total:                   filas.size,
        valor_total:             filas.sum { |f| f["VALOR COBRADO"].to_f }.round(2),
        por_factura:             por_factura.first(50),
        por_empresa:             por_empresa.first(30),
        total_facturas:          (por_factura.map { |h| h[:factura] } - ["(sin factura)"]).size,
        total_empresas:          por_empresa.size,
        reconciliacion: {
          facturas_cuadran:      cuadran,
          facturas_no_cuadran:   no_cuadran,
          filas_sin_factura:     sin_factura,
        },
      }
    end

    def limpiar(obj)
      ClickhouseClient.limpiar(obj)
    end
  end
end
