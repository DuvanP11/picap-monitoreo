# v3.3.58: PICAP CAMPAIGN VALIDATOR — pagos de campaña con datos reales de ClickHouse.
# Endpoint: GET /api/campaign_validator/cargar_async?desde=&hasta=
#           GET /api/campaign_validator/cargar_status/:job_id
# Roles permitidos: admin, monitoreo, financiero, operaciones
module Api
  class CampaignValidatorController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol

    # v3.3.112: + sac + marketing
    ROLES_PERMITIDOS = %w[admin monitoreo financiero operaciones sac marketing].freeze

    @@load_jobs       = {}
    @@load_jobs_mutex = Mutex.new
    LOAD_JOB_TTL_SEC  = 600

    # GET /api/campaign_validator/cargar_async?desde=YYYY-MM-DD&hasta=YYYY-MM-DD
    def cargar_async
      desde = params[:desde].to_s.strip.presence || Date.today.beginning_of_month.to_s
      hasta  = params[:hasta].to_s.strip.presence || Date.today.to_s

      # v3.3.76: swap defensivo si el cliente manda rango invertido (sintoma: 0 datos
      # aunque la query corra OK). Log para diagnostico futuro.
      Rails.logger.info("[CampaignValidator] Recibido desde=#{desde} hasta=#{hasta}")
      if desde > hasta
        Rails.logger.warn("[CampaignValidator] Rango invertido — swap: #{desde} ↔ #{hasta}")
        desde, hasta = hasta, desde
      end

      cache_key = "cv_#{desde}_#{hasta}"
      hit = @@load_jobs_mutex.synchronize do
        @@load_jobs.find { |_, j| j[:cache_key] == cache_key && j[:status] == :done }
      end
      if hit
        job_id, job = hit
        return render(json: limpiar(job[:result].merge(cached: true, status: "done", ok: true, job_id: job_id)))
      end

      job_id = SecureRandom.hex(16)
      @@load_jobs_mutex.synchronize do
        @@load_jobs[job_id] = { status: :running, cache_key: cache_key, t0: Time.now, desde: desde, hasta: hasta }
      end

      Thread.new do
        begin
          Rails.logger.info("[CampaignValidator #{job_id}] START desde=#{desde} hasta=#{hasta}")

          # v3.3.72: dos queries en paralelo. Q_CAMPAIGN_VALIDATOR llena Estadística;
          # Q_CAMPAIGN_VALIDATOR_DETALLE llena Detallado. Si la 2a falla, Estadística sigue OK.
          rows_seg = nil; rows_det = []; err_det = nil
          t_seg = Thread.new { rows_seg = ejecutar_query(desde, hasta) }
          t_det = Thread.new do
            begin
              rows_det = ejecutar_query_detalle(desde, hasta)
            rescue => e
              err_det = "#{e.class}: #{e.message}"
              Rails.logger.error("[CampaignValidator #{job_id}] DETALLE FALLO: #{err_det}")
            end
          end
          t_seg.join; t_det.join

          result = procesar_data(rows_seg, rows_det, desde, hasta)
          result[:warn_detalle] = err_det if err_det

          @@load_jobs_mutex.synchronize do
            @@load_jobs[job_id][:status]    = :done
            @@load_jobs[job_id][:result]    = result
            @@load_jobs[job_id][:t_elapsed] = (Time.now - @@load_jobs[job_id][:t0]).round(1)
          end
          Rails.logger.info("[CampaignValidator #{job_id}] DONE seg=#{rows_seg.size} det=#{rows_det.size}")
        rescue => e
          Rails.logger.error("[CampaignValidator #{job_id}] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
          @@load_jobs_mutex.synchronize do
            @@load_jobs[job_id][:status] = :error
            @@load_jobs[job_id][:error]  = e.message
          end
        end
      end

      render json: { ok: true, async: true, status: "queued", job_id: job_id }, status: :accepted
    end

    # GET /api/campaign_validator/cargar_status/:job_id
    def cargar_status
      job_id = params[:job_id].to_s
      _cleanup_load_jobs
      @@load_jobs_mutex.synchronize do
        job = @@load_jobs[job_id]
        return render(json: { ok: false, error: "Job no encontrado o expirado" }, status: :not_found) if job.nil?
        case job[:status]
        when :done
          render json: limpiar(job[:result].merge(ok: true, status: "done", t_elapsed: job[:t_elapsed]))
        when :error
          render json: { ok: false, status: "error", error: job[:error] }, status: :internal_server_error
        else
          render json: { ok: true, status: "running", elapsed_sec: (Time.now - job[:t0]).round(1) }, status: :accepted
        end
      end
    end

    # v3.3.89: GET /api/campaign_validator/servicios_piloto
    # Consulta sincrónica de servicios finalizados con regla_trump + regla_monitoreo.
    # Params: desde, hasta (obligatorios), driver_id (opcional para filtrar 1 piloto).
    def consulta_servicios
      desde      = params[:desde].to_s.strip.presence || (Date.today - 7).to_s
      hasta      = params[:hasta].to_s.strip.presence || Date.today.to_s
      driver_id  = params[:driver_id].to_s.strip
      # whitelist: solo hex de Mongo (24 chars) para evitar SQL injection
      driver_id  = driver_id =~ /\A[a-fA-F0-9]{24}\z/ ? driver_id : ""

      filtro = driver_id.present? ? "AND b.driver_id = '#{driver_id}'" : ""

      sql = QueriesService.format(
        QueriesService::Q_CV_SERVICIOS_PILOTO,
        fecha_desde:    "#{desde} 00:00:00",
        fecha_hasta:    "#{hasta} 23:59:59",
        filtro_driver:  filtro
      )

      t0 = Time.now
      begin
        rows = ch.query(sql, timeout: 120)
        Rails.logger.info("[CV servicios_piloto] #{rows.size} filas en #{(Time.now - t0).round(1)}s (driver=#{driver_id.presence || '*todos*'})")
        render json: { ok: true, rows: rows.size, data: rows, desde: desde, hasta: hasta, driver_id: driver_id }
      rescue => e
        Rails.logger.error("[CV servicios_piloto] #{e.class}: #{e.message}")
        render json: { ok: false, error: e.message }, status: :internal_server_error
      end
    end

    # v3.3.94: POST /api/campaign_validator/auditar_tyc
    # Recibe estructura del TyC (parseada en frontend desde el PDF) + driver_id,
    # genera SQL dinámica y devuelve veredicto GANA/NO GANA con detalles.
    # Params:
    #   tyc            -> hash con fecha_inicio, fecha_fin, tiers, servicios_validos, etc.
    #   driver_id      -> hex 24 chars
    #   ignored_rules  -> [] de strings (reglas a IGNORAR para el veredicto)
    def auditar_tyc
      tyc       = params[:tyc].respond_to?(:to_unsafe_h) ? params[:tyc].to_unsafe_h : params[:tyc].to_h
      driver_id = params[:driver_id].to_s.strip
      ignored   = Array(params[:ignored_rules]).map(&:to_s)

      result = TycAuditorService.auditar(
        tyc:           tyc,
        driver_id:     driver_id,
        ch:            ch,
        ignored_rules: ignored
      )
      render json: { ok: true, **result }
    rescue ArgumentError => e
      render json: { ok: false, error: e.message }, status: :bad_request
    rescue => e
      Rails.logger.error("[CV auditar_tyc] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def validar_rol
      return if ROLES_PERMITIDOS.include?(current_rol.to_s)
      render json: { ok: false, error: "Acceso restringido — roles: #{ROLES_PERMITIDOS.join(', ')}" }, status: :forbidden
    end

    def ejecutar_query(desde, hasta)
      sql = QueriesService.format(
        QueriesService::Q_CAMPAIGN_VALIDATOR,
        fecha_desde: "#{desde} 00:00:00",
        fecha_hasta:  "#{hasta} 23:59:59"
      )
      t0 = Time.now
      rows = ch.query(sql, timeout: 300)
      Rails.logger.info("[CampaignValidator] CH SEG OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    # v3.3.72: Q_CAMPAIGN_VALIDATOR_DETALLE pobla la tab Detallado (1 fila por
    # booking finalizado, con timestamps, IMEI, regla_distancia, reason_text).
    # v3.3.75: timeout 300 → 600 (query con muchos FINAL + joins).
    def ejecutar_query_detalle(desde, hasta)
      sql = QueriesService.format(
        QueriesService::Q_CAMPAIGN_VALIDATOR_DETALLE,
        fecha_desde: "#{desde} 00:00:00",
        fecha_hasta:  "#{hasta} 23:59:59"
      )
      t0 = Time.now
      rows = ch.query(sql, timeout: 600)
      Rails.logger.info("[CampaignValidator] CH DET OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    def procesar_data(rows, rows_det, desde, hasta)
      pais_map = { 'CO' => 'COL', 'MX' => 'MEX', 'NI' => 'NIC' }
      cur_map  = { 'COP' => 'COL', 'MXN' => 'MEX', 'NIO' => 'NIC' }

      buckets = {}
      %w[COL MEX NIC].each do |cc|
        buckets[cc] = {
          seg:         [],
          det:         [],
          kpi:         { total_txs: 0, total_valor: 0.0, total_pilots: Set.new,
                         affected_zero: 0, fraud_pilots: Set.new, fraud_services: 0 },
          cities:      Hash.new { |h, k| h[k] = { ciudad: k, campanas: 0, valor: 0.0, pilotos: Set.new } },
          camps:       Hash.new { |h, k| h[k] = { rank: 0, id: k, nombre: '', pagos: 0, valor: 0.0 } },
          pilots_acc:  Hash.new { |h, k| h[k] = { rank: 0, id: k, nombre: '', campanas: 0, valor: 0.0, ultimo: '' } },
        }
      end

      rows.each do |r|
        cc = pais_map[r['pais'].to_s] || cur_map[r['moneda'].to_s] || next
        next unless buckets.key?(cc)

        valor  = r['valor'].to_f
        fraude = r['fraud_suspect'].to_s == '1' || r['fraude'].to_s.downcase == 'true'

        buckets[cc][:seg] << {
          fecha_tx:    r['fecha_tx'].to_s,
          driver_id:   r['driver_id'].to_s,
          nombre:      r['nombre'].to_s.strip,
          ciudad:      r['ciudad'].to_s,                        # v3.3.69: necesario para tabla Estadistica por Ciudad
          id_camp:     r['id_camp'].to_s,
          nombre_camp: r['nombre_camp'].to_s,
          servicios:   r['servicios'].to_i,
          valor:       valor,
          tyc:         r['tyc'].to_s,
          monitoreo:   r['monitoreo'].to_s.presence || '(sin regla)',  # v3.3.69: default visible
          trump:       r['trump'].to_s.presence || '(sin alerta)',
          fraude:      fraude,
        }

        k = buckets[cc][:kpi]
        k[:total_txs]    += 1
        k[:total_valor]  += valor
        k[:total_pilots].add(r['driver_id'])
        k[:affected_zero] += 1 if valor.zero?
        if fraude
          k[:fraud_pilots].add(r['driver_id'])
          k[:fraud_services] += 1
        end

        city = r['ciudad'].to_s.presence || '(sin ciudad)'
        buckets[cc][:cities][city][:campanas] += 1
        buckets[cc][:cities][city][:valor]    += valor
        buckets[cc][:cities][city][:pilotos].add(r['driver_id'])

        ic = r['id_camp'].to_s
        buckets[cc][:camps][ic][:nombre] = r['nombre_camp'].to_s
        buckets[cc][:camps][ic][:pagos]  += 1
        buckets[cc][:camps][ic][:valor]  += valor

        did = r['driver_id'].to_s
        buckets[cc][:pilots_acc][did][:nombre]   = r['nombre'].to_s.strip
        buckets[cc][:pilots_acc][did][:campanas] += 1
        buckets[cc][:pilots_acc][did][:valor]    += valor
        ult = r['fecha_tx'].to_s[0, 10]
        buckets[cc][:pilots_acc][did][:ultimo] = ult if ult > buckets[cc][:pilots_acc][did][:ultimo].to_s
      end

      # v3.3.72: poblar buckets[cc][:det] desde Q_CAMPAIGN_VALIDATOR_DETALLE.
      # Solo trae bookings finalizados (status_cd=4); puede tener menos filas que seg.
      # v3.3.74: bucketing defensivo — si currency_iso vacio, intentar mapear por country_name.
      country_map = { 'Colombia' => 'COL', 'Mexico' => 'MEX', 'Nicaragua' => 'NIC' }
      (rows_det || []).each do |r|
        cc = cur_map[r['currency_iso'].to_s] ||
             country_map[r['country_name'].to_s] ||
             'COL'  # default a Colombia si todo vacio (mejor mostrar fila que descartarla)
        next unless buckets.key?(cc)
        buckets[cc][:det] << {
          id_booking:      r['id_booking'].to_s,
          aceptado:        r['aceptado'].to_s,
          conductor_llego: r['conductor_llego'].to_s,
          finalizado:      r['finalizado'].to_s,
          fecha:           r['fecha'].to_s,
          driver_name:     r['driver_name'].to_s,
          passenger_name:  r['passenger_name'].to_s,
          driver_id:       r['driver_id'].to_s,
          passenger_id:    r['passenger_id'].to_s,
          company_name:    r['company_name'].to_s,
          country_name:    r['country_name'].to_s,
          city_name:       r['city_name'].to_s,
          imei_driver:     r['imei_driver'].to_s,
          imei_passenger:  r['imei_passenger'].to_s,
          status_carrera:  r['status_carrera'].to_s,
          id_campana:      r['id_campana'].to_s,
          nombre_campana:  r['nombre_campana'].to_s,
          fecha_bono:      r['fecha_bono'].to_s,
          valor_campana:   r['valor_campana'].to_f,
          tyc:             r['tyc'].to_s,
          revision_imei:   r['revision_imei'].to_s,
          id_tx:           r['id_tx'].to_s,
          valor:           r['valor'].to_f,
          fraud_suspect:   r['fraud_suspect'].to_s == '1' || r['fraud_suspect'].to_s.downcase == 'true',
          reason_text:     r['reason_text'].to_s.presence || '(sin alerta)',
          regla_distancia: r['regla_distancia'].to_s.presence || 'SIN_COORDENADAS',
          service_type:    r['service_type'].to_s,
        }
      end

      data = {}
      %w[COL MEX NIC].each_with_index do |cc, _|
        b = buckets[cc]
        currency = { 'COL' => 'COP', 'MEX' => 'MXN', 'NIC' => 'NIO' }[cc]

        b[:kpi][:total_pilots]  = b[:kpi][:total_pilots].size
        b[:kpi][:fraud_pilots]  = b[:kpi][:fraud_pilots].size
        b[:kpi][:total_valor]   = b[:kpi][:total_valor].round(0)

        cities = b[:cities].values
                           .map  { |c| c.merge(pilotos: c[:pilotos].size) }
                           .sort_by { |c| -c[:valor] }

        top_camps = b[:camps].values
                             .sort_by { |c| -c[:valor] }
                             .first(10)
                             .each_with_index { |c, i| c[:rank] = i + 1 }

        top_pilots = b[:pilots_acc].values
                                   .sort_by { |p| -p[:valor] }
                                   .first(10)
                                   .each_with_index { |p, i| p[:rank] = i + 1 }

        data[cc] = {
          kpi:        b[:kpi],
          currency:   currency,
          cities:     cities,
          top_camps:  top_camps,
          top_pilots: top_pilots,
          monitoreo:  [],
          trump:      [],
          seg:        b[:seg],
          det:        b[:det],
        }
      end

      { desde: desde, hasta: hasta, data: data }
    end

    def _cleanup_load_jobs
      now = Time.now
      @@load_jobs_mutex.synchronize { @@load_jobs.delete_if { |_, j| (now - j[:t0]) > LOAD_JOB_TTL_SEC } }
    end

    def limpiar(obj) = ClickhouseClient.limpiar(obj)
  end
end
