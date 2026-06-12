# v3.3.58: PICAP CAMPAIGN VALIDATOR — pagos de campaña con datos reales de ClickHouse.
# Endpoint: GET /api/campaign_validator/cargar_async?desde=&hasta=
#           GET /api/campaign_validator/cargar_status/:job_id
# Roles permitidos: admin, monitoreo, financiero, operaciones
module Api
  class CampaignValidatorController < ApplicationController
    before_action :authenticate_user!
    before_action :validar_rol

    ROLES_PERMITIDOS = %w[admin monitoreo financiero operaciones].freeze

    @@load_jobs       = {}
    @@load_jobs_mutex = Mutex.new
    LOAD_JOB_TTL_SEC  = 600

    # GET /api/campaign_validator/cargar_async?desde=YYYY-MM-DD&hasta=YYYY-MM-DD
    def cargar_async
      desde = params[:desde].to_s.strip.presence || Date.today.beginning_of_month.to_s
      hasta  = params[:hasta].to_s.strip.presence || Date.today.to_s

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
          rows   = ejecutar_query(desde, hasta)
          result = procesar_data(rows, desde, hasta)
          @@load_jobs_mutex.synchronize do
            @@load_jobs[job_id][:status]    = :done
            @@load_jobs[job_id][:result]    = result
            @@load_jobs[job_id][:t_elapsed] = (Time.now - @@load_jobs[job_id][:t0]).round(1)
          end
          Rails.logger.info("[CampaignValidator #{job_id}] DONE #{rows.size} filas")
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
      Rails.logger.info("[CampaignValidator] CH OK: #{rows.size} filas en #{(Time.now - t0).round(1)}s")
      rows
    end

    # v3.3.70: nueva query devuelve 1 fila por (tx × booking). Construimos:
    #   seg = 1 fila por TX (deduplicado, ciudad/monitoreo/trump del primer booking)
    #   det = 1 fila por (tx × booking) con detalle completo del servicio
    def procesar_data(rows, desde, hasta)
      cur_map = { 'COP' => 'COL', 'MXN' => 'MEX', 'NIO' => 'NIC' }

      buckets = {}
      %w[COL MEX NIC].each do |cc|
        buckets[cc] = {
          seg_by_tx:  {},     # id_tx => fila agregada
          det:        [],
          kpi:        { total_valor: 0.0, total_pilots: Set.new,
                        affected_zero: 0, fraud_pilots: Set.new, fraud_services: 0 },
          cities:     Hash.new { |h, k| h[k] = { ciudad: k, campanas: 0, valor: 0.0, pilotos: Set.new } },
          camps:      Hash.new { |h, k| h[k] = { rank: 0, id: k, nombre: '', pagos: 0, valor: 0.0 } },
          pilots_acc: Hash.new { |h, k| h[k] = { rank: 0, id: k, nombre: '', campanas: 0, valor: 0.0, ultimo: '' } },
        }
      end

      rows.each do |r|
        cc = cur_map[r['moneda'].to_s] || cur_map[r['currency_iso'].to_s] || next
        next unless buckets.key?(cc)

        b = buckets[cc]

        id_tx       = r['id_tx'].to_s
        id_booking  = r['id_booking'].to_s
        valor_bono  = r['valor_bono'].to_f
        valor_svc   = r['valor_servicio'].to_f
        driver_id   = r['driver_id'].to_s
        nombre      = r['nombre'].to_s.strip
        ciudad      = r['ciudad'].to_s.presence || '(sin ciudad)'
        id_camp     = r['id_camp'].to_s
        nombre_camp = r['nombre_camp'].to_s
        monitoreo   = r['monitoreo'].to_s.presence || 'SIN_COORDENADAS'
        trump       = r['trump'].to_s.presence || '(sin alerta)'
        fraude      = r['fraud_suspect'].to_s == '1' || r['fraud_suspect'].to_s.downcase == 'true'

        # det = 1 fila por booking (para distribución de reglas)
        b[:det] << {
          id_tx:          id_tx,
          id_booking:     id_booking,
          fecha_tx:       r['fecha_tx'].to_s,
          fecha_servicio: r['fecha_servicio'].to_s,
          tms_aceptado:   r['tms_aceptado'].to_s,
          tms_finalizado: r['tms_finalizado'].to_s,
          driver_id:      driver_id,
          nombre:         nombre,
          passenger_id:   r['passenger_id'].to_s,
          passenger_name: r['passenger_name'].to_s,
          ciudad:         ciudad,
          empresa:        r['empresa'].to_s,
          id_camp:        id_camp,
          nombre_camp:    nombre_camp,
          valor_bono:     valor_bono,
          valor_servicio: valor_svc,
          tyc:            r['tyc'].to_s,
          service_type:   r['service_type'].to_s,
          imei_driver:    r['imei_driver'].to_s,
          imei_passenger: r['imei_passenger'].to_s,
          revision_imei:  r['revision_imei'].to_s,
          monitoreo:      monitoreo,
          trump:          trump,
          fraude:         fraude,
        }

        # seg = 1 fila por TX (primera vez que la vemos, persiste ciudad/monitoreo/trump del 1er booking)
        unless b[:seg_by_tx].key?(id_tx)
          b[:seg_by_tx][id_tx] = {
            id_tx:       id_tx,
            fecha_tx:    r['fecha_tx'].to_s,
            driver_id:   driver_id,
            nombre:      nombre,
            ciudad:      ciudad,
            id_camp:     id_camp,
            nombre_camp: nombre_camp,
            servicios:   0,
            valor:       valor_bono,
            tyc:         r['tyc'].to_s,
            monitoreo:   monitoreo,
            trump:       trump,
            fraude:      fraude,
          }
        end
        b[:seg_by_tx][id_tx][:servicios] += 1
        b[:seg_by_tx][id_tx][:fraude]    ||= fraude
      end

      data = {}
      %w[COL MEX NIC].each do |cc|
        b = buckets[cc]
        currency = { 'COL' => 'COP', 'MEX' => 'MXN', 'NIC' => 'NIO' }[cc]

        seg = b[:seg_by_tx].values

        # KPIs sobre seg (TX-level: $ no se infla)
        seg.each do |s|
          k = b[:kpi]
          k[:total_valor]  += s[:valor]
          k[:total_pilots].add(s[:driver_id])
          k[:affected_zero] += 1 if s[:valor].zero?
          if s[:fraude]
            k[:fraud_pilots].add(s[:driver_id])
            k[:fraud_services] += 1
          end

          b[:cities][s[:ciudad]][:campanas] += 1
          b[:cities][s[:ciudad]][:valor]    += s[:valor]
          b[:cities][s[:ciudad]][:pilotos].add(s[:driver_id])

          b[:camps][s[:id_camp]][:nombre] = s[:nombre_camp]
          b[:camps][s[:id_camp]][:pagos]  += 1
          b[:camps][s[:id_camp]][:valor]  += s[:valor]

          b[:pilots_acc][s[:driver_id]][:nombre]   = s[:nombre]
          b[:pilots_acc][s[:driver_id]][:campanas] += 1
          b[:pilots_acc][s[:driver_id]][:valor]    += s[:valor]
          ult = s[:fecha_tx][0, 10]
          b[:pilots_acc][s[:driver_id]][:ultimo] = ult if ult > b[:pilots_acc][s[:driver_id]][:ultimo].to_s
        end

        b[:kpi][:total_pilots] = b[:kpi][:total_pilots].size
        b[:kpi][:fraud_pilots] = b[:kpi][:fraud_pilots].size
        b[:kpi][:total_valor]  = b[:kpi][:total_valor].round(0)
        b[:kpi][:total_txs]    = seg.size

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
          seg:        seg,
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
