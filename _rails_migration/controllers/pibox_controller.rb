# app/controllers/api/pibox_controller.rb
# Auditoría Pibox B2B — Alertas de fraude (api.py 6770-7351).
# Robot que detecta:
#   - Tiempo < 5 min (no recogió/no entregó)
#   - Mismo punto GPS sin retorno a origen ni reserva
#   - Montos excesivos por tipo de servicio (CO)
# Excluye clientes test/qa/demo/onboarding (con excepción Cruz Verde Integración).

module Api
  class PiboxController < ApplicationController
    before_action :authenticate_user!

    # Config (paridad PIBOX_CONFIG Python)
    TIEMPO_MINIMO       = 5      # minutos
    TOLERANCIA_GPS      = 0.001  # grados (≈ 100m)
    MONTOS_ALERTA = {
      "mensajeria"             => 400_000,
      "carga_carry"            => 800_000,
      "carga_moto"             => 600_000,
      "cruz_verde_mostrador"   => 80_000,
    }.freeze
    SERVICE_TYPE_IDS = {
      "mensajeria"  => "5c71b03a58b9ba10fa6393cf",
      "carga_carry" => "62e2ae08790a6a0004ab0a3b",
      "carga_moto"  => "62e2ae08790a6a0004ab0a3a",
    }.freeze
    SERVICE_TYPE_NAMES = {
      "5c71b03a58b9ba10fa6393cf" => "Mensajería",
      "62e2ae08790a6a0004ab0a3b" => "Carga Carry",
      "62e2ae08790a6a0004ab0a3a" => "Carga Moto-Vagón",
      "57b28033f0350b00035d0ade" => "Moto Mensajería",
      "62e2ae08790a6a0004ab0a3c" => "Carga NHR",
      "57b27f84f0350b00035d0ad9" => "Otro tipo",
    }.freeze
    CLIENTES_EXCLUIDOS  = ["tada"].freeze
    KEYWORDS_EXCLUIR    = %w[test prueba qa onboarding demo].freeze
    EXCEPCION_CLIENTE   = "cruz verde integración"
    PILOTOS_REVISION = {
      "67bb692f4623a92a61b4e1c1" => "Guilio Rene Velandia Suarez",
      "597c0cbc53bd7c0004e5d58f" => "Yonattan Camilo Galeano Moreno",
      "64c3e4891262d800573e6b12" => "Jairo Reyes",
      "634cb1add50da600442ea6f7" => "Anderson Gutierrez Mendez",
      "5c2723e43eb16b0030a160fd" => "Miguel Angel Galvis Guerrero",
      "65f4d3619b0bac0062fa0277" => "Carlos Augusto Hernandez Higuita",
      "64b2b4999bef87004d5ea234" => "Anyelo David Mendoza",
      "67899fc21ed419d3cb491b76" => "Alfredo Goez Ibarra",
      "662087a3ee8f1f0046b398b2" => "Ender Armando Pinzon Gonzalez",
      "6610408315a5e60062358606" => "Heber Méndez Santos",
    }.freeze

    # GET /api/pibox/servicios?desde=&hasta=&pais=&cliente_id=&piloto_id=
    def servicios
      servicios = cargar_servicios
      render json: limpiar({
        ok: true,
        desde: desde_param, hasta: hasta_param,
        total: servicios.size,
        servicios: servicios.first(2000),
      })
    rescue => e
      Rails.logger.error("[PiboxController#servicios] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/pibox/alertas?desde=&hasta=&pais=&cliente_id=&piloto_id=
    def alertas
      servicios = cargar_servicios
      alertas_out = []
      stats = {
        total_servicios:           0,
        total_alertas:             0,
        alertas_tiempo:            0,
        alertas_recorrido:         0,
        alertas_evidencia:         0,
        alertas_pago:              0,
        tipos_alerta:              {},
        descartados_retorno_origen: 0,
        descartados_con_reserva:    0,
      }

      servicios.each do |servicio|
        next if debe_excluirse?(servicio)
        stats[:total_servicios] += 1

        # Descartes por reglas de negocio sobre "mismo punto"
        if servicio["flag_mismo_punto"].to_i == 1 && servicio["flag_alerta_mismo_punto"].to_i != 1
          if servicio["return_to_origin"].to_i == 1
            stats[:descartados_retorno_origen] += 1
          elsif servicio["tiene_reserva"].to_i == 1
            stats[:descartados_con_reserva] += 1
          end
        end

        analizar_servicio(servicio).each do |alerta|
          alertas_out << alerta
          tipo = alerta[:tipo_alerta]
          case tipo
          when "Tiempo" then stats[:alertas_tiempo]    += 1
          when "GPS"    then stats[:alertas_recorrido] += 1
          when "Fotos"  then stats[:alertas_evidencia] += 1
          when "Pagos"  then stats[:alertas_pago]      += 1
          end
          stats[:tipos_alerta][tipo] = (stats[:tipos_alerta][tipo] || 0) + 1
        end
      end
      stats[:total_alertas] = alertas_out.size

      render json: limpiar({
        ok: true,
        fecha_desde: desde_param,
        fecha_hasta: hasta_param,
        alertas: alertas_out,
        estadisticas: stats,
      })
    rescue => e
      Rails.logger.error("[PiboxController#alertas] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # GET /api/pibox/export?desde=&hasta=&pais=&cliente_id=&piloto_id=
    # Puerto del Python api.py:7356-7471 (pibox_export). 1 hoja con alertas detectadas.
    def export
      servicios = cargar_servicios
      alertas_out = []
      servicios.each do |servicio|
        next if debe_excluirse?(servicio)
        analizar_servicio(servicio).each { |alerta| alertas_out << alerta }
      end

      if alertas_out.empty?
        render json: { ok: false, error: "No hay alertas para exportar en este período" },
               status: :not_found
        return
      end

      xlsx = ExcelExportService.build("alertas_pibox") do |x|
        x.add_sheet("Alertas Pibox") do |s|
          s.banner("Alertas Pibox B2B — Auditoría de Fraude",
                   "#{desde_param} → #{hasta_param}  ·  Alertas: #{alertas_out.size}", 12)
          s.headers([
            "Booking ID", "Fecha", "País", "Ciudad", "Piloto", "Piloto ID",
            "Cliente", "Tipo servicio", "Tipo vehículo", "Tipo alerta",
            "Severidad", "Observación",
          ])

          wb = s.ws.workbook
          style_alta = wb.styles.add_style(
            b: true, sz: 10, fg_color: "991B1B", bg_color: "FEE2E2",
            alignment: { horizontal: :center, vertical: :center },
            border: { style: :thin, color: "EEEEEE" }
          )
          style_media = wb.styles.add_style(
            b: true, sz: 10, fg_color: "92400E", bg_color: "FEF3C7",
            alignment: { horizontal: :center, vertical: :center },
            border: { style: :thin, color: "EEEEEE" }
          )

          alertas_out.each do |a|
            sev = a[:severidad].to_s
            sev_style = sev == "ALTA" ? style_alta : style_media
            s.data_row(
              [
                a[:booking_id], a[:fecha_servicio].to_s[0, 16],
                a[:pais], a[:ciudad], a[:piloto_nombre], a[:piloto_id],
                a[:cliente_nombre], a[:tipo_servicio_nombre], a[:tipo_vehiculo],
                a[:tipo_alerta], sev, a[:observacion],
              ],
              cell_styles: { 11 => sev_style },
            )
          end
          s.finalize(freeze_row: 4)
        end
      end

      send_xlsx(xlsx)
    rescue => e
      Rails.logger.error("[PiboxController#export] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # v3.3.114: Verificación de Servicios Pibox B2B
    # Devuelve 1 fila por servicio (no por alerta) con datos de wallet,
    # Llegó/No llegó (perímetro 450m), Tipo de alerta combinado.
    # GET /api/pibox/verificacion_b2b?desde=&hasta=&pais=&ciudad=&severidad=&tipo_obs=&q=
    def verificacion_b2b
      servicios = cargar_servicios

      # Resumen wallet por booking (1 query batch)
      booking_ids = servicios.map { |s| s["booking_id"].to_s }.reject(&:empty?).uniq
      wallet = resumen_wallet_por_bookings(booking_ids)

      # Coordenadas del cliente (drop-off) por booking — para calcular Llegó/No llegó
      coords = coords_destino_por_bookings(booking_ids)

      severidad_filter = params[:severidad].to_s.strip.upcase
      tipo_obs_filter  = params[:tipo_obs].to_s.strip.upcase
      q_search         = params[:q].to_s.strip.downcase
      ciudad_filter    = params[:ciudad].to_s.strip.downcase

      filas = []
      servicios.each do |s|
        next if debe_excluirse?(s)

        bid       = s["booking_id"].to_s
        ciudad    = s["ciudad"].to_s
        next if !ciudad_filter.empty? && !ciudad.downcase.include?(ciudad_filter)

        minutos = s["minutos_servicio"].to_i
        alertas_tipos = []
        alertas_tipos << "Tiempo" if minutos.positive? && minutos < TIEMPO_MINIMO
        alertas_tipos << "GPS"    if s["flag_alerta_mismo_punto"].to_i == 1

        # Filtros de severidad / tipo de observación
        severidad = alertas_tipos.any? ? "ALTA" : "—"
        next if !severidad_filter.empty? && severidad != severidad_filter
        next if !tipo_obs_filter.empty?  && !alertas_tipos.any? { |t| t.upcase == tipo_obs_filter }

        # Llegó/No llegó (450m desde drop-off del cliente)
        co = coords[bid] || {}
        llego = if co[:dist_destino_m] && co[:dist_destino_m] > 0
                  co[:dist_destino_m] <= 450 ? "Llegó" : "No Llegó"
                else
                  "N/A"
                end

        wbal = wallet[bid] || {}
        type_id = s["requested_service_type_id"].to_s
        tipo_alerta = alertas_tipos.empty? ? "Sin alerta" : alertas_tipos.join("+")
        revisar = alertas_tipos.any? ? "Sí — revisar evidencias" : "No"

        fila = {
          fecha_servicio:         s["fecha_servicio"].to_s,
          id_booking:             bid,
          id_piloto:              s["driver_id"].to_s,
          name_piloto:            s["piloto_nombre"].to_s.presence || "N/A",
          id_comercio:            s["company_id"].to_s,
          name_comercio:          s["cliente_nombre"].to_s.presence || "N/A",
          tipo_servicio:          SERVICE_TYPE_NAMES[type_id] || "Desconocido",
          valor_pagado_piloto:    wbal[:pagado_piloto].to_f.round(0),
          valor_cobrado_comercio: wbal[:cobrado_comercio].to_f.round(0),
          duracion_minutos:       minutos,
          llego_al_punto:         llego,
          tipo_alerta:            tipo_alerta,
          revisar_evidencias:     revisar,
          severidad:              severidad,
          pais:                   s["pais"].to_s,
          ciudad:                 ciudad,
          moneda:                 s["moneda"].to_s,
        }

        # Filtro de búsqueda libre (id_comercio, id_booking o id_piloto)
        if !q_search.empty?
          haystack = [bid, fila[:id_piloto], fila[:id_comercio], fila[:name_piloto].to_s.downcase, fila[:name_comercio].to_s.downcase].join(" ").downcase
          next unless haystack.include?(q_search)
        end

        filas << fila
      end

      render json: { ok: true, fecha_desde: desde_param, fecha_hasta: hasta_param, filas: filas, total: filas.size }
    rescue => e
      Rails.logger.error("[PiboxController#verificacion_b2b] #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    # v3.3.115: batch en chunks de 500 ids para no superar max_query_size de CH
    BATCH_SIZE = 500

    # Resumen wallet por booking_id. Devuelve { booking_id => { pagado_piloto:, cobrado_comercio: } }
    def resumen_wallet_por_bookings(ids)
      return {} if ids.empty?
      result = {}
      ids.each_slice(BATCH_SIZE) do |chunk|
        ids_sql = chunk.map { |i| "'#{i.gsub("'", "''")}'" }.join(",")
        sql = <<~SQL
          SELECT
            toString(booking_id) AS bid,
            sumIf(intDiv(toInt64OrZero(JSONExtractString(amount,'cents')),100), _type = 'WalletAccountTransactionBookingDriverPayment')  AS pagado_piloto,
            sumIf(intDiv(toInt64OrZero(JSONExtractString(amount,'cents')),100), _type = 'WalletAccountTransactionBookingCompanyCharge') AS cobrado_comercio
          FROM picapmongoprod.wallet_account_transactions
          WHERE toString(booking_id) IN (#{ids_sql})
          GROUP BY booking_id
        SQL
        ch.query(sql, timeout: 60).each do |r|
          result[r["bid"]] = { pagado_piloto: r["pagado_piloto"].to_f, cobrado_comercio: r["cobrado_comercio"].to_f }
        end
      end
      result
    end

    # Coords drop-off + distancia entre piloto-final y destino-cliente
    def coords_destino_por_bookings(ids)
      return {} if ids.empty?
      result = {}
      ids.each_slice(BATCH_SIZE) do |chunk|
        ids_sql = chunk.map { |i| "'#{i.gsub("'", "''")}'" }.join(",")
        sql = <<~SQL
          SELECT
            toString(_id) AS bid,
            if(end_geojson IS NOT NULL AND end_geojson != '' AND destination_geojson IS NOT NULL AND destination_geojson != '',
               round(geoDistance(
                 toFloat64OrZero(JSONExtractString(end_geojson, 'coordinates', 1)),
                 toFloat64OrZero(JSONExtractString(end_geojson, 'coordinates', 2)),
                 toFloat64OrZero(JSONExtractString(destination_geojson, 'coordinates', 1)),
                 toFloat64OrZero(JSONExtractString(destination_geojson, 'coordinates', 2))
               ), 0), 0) AS dist_destino_m
          FROM picapmongoprod.bookings FINAL
          WHERE toString(_id) IN (#{ids_sql})
        SQL
        ch.query(sql, timeout: 60).each do |r|
          result[r["bid"]] = { dist_destino_m: r["dist_destino_m"].to_i }
        end
      end
      result
    end

    def send_xlsx(xlsx)
      send_data xlsx[:data], type: xlsx[:mimetype],
                filename: xlsx[:filename], disposition: "attachment"
    end

    def cargar_servicios
      pais       = params[:pais].to_s.strip
      cliente_id = params[:cliente_id].to_s.strip
      piloto_id  = params[:piloto_id].to_s.strip
      filtros = []
      filtros << "AND b.g_country = '#{pais[0,2].upcase}'"                              if pais.length >= 2
      filtros << "AND b.company_id = '#{cliente_id.gsub("'", "''")}'"                  unless cliente_id.empty?
      filtros << "AND b.driver_id = '#{piloto_id.gsub("'", "''")}'"                    unless piloto_id.empty?

      sql = QueriesService.format(
        QueriesService::Q_PIBOX_BASE,
        fecha_desde:         desde_param,
        fecha_hasta:         hasta_param,
        tolerancia_gps:      TOLERANCIA_GPS,
        filtros_adicionales: filtros.join(" "),
      )
      # Pibox usa FINAL en 6 tablas (bookings + passengers + companies +
      # driver_vehicle_enrollments + vehicles + vehicle_types) sobre 30 días
      # de bookings B2B — costoso. 600s para tener margen.
      ch.query(sql, timeout: 600)
    end

    # Lógica de exclusión por nombre de cliente (paridad _pibox_debe_excluirse)
    def debe_excluirse?(servicio)
      nombre = servicio["cliente_nombre"].to_s.downcase
      return false if nombre.include?(EXCEPCION_CLIENTE)
      return true  if CLIENTES_EXCLUIDOS.any? { |c| nombre.include?(c) }
      return true  if KEYWORDS_EXCLUIR.any?    { |k| nombre.include?(k) }
      false
    end

    # Analiza un servicio y genera las alertas (paridad _pibox_analizar_servicio)
    def analizar_servicio(servicio)
      out = []
      type_id   = servicio["requested_service_type_id"].to_s
      tipo_nbr  = SERVICE_TYPE_NAMES[type_id] || "Desconocido"
      driver_id = servicio["driver_id"].to_s
      revision  = PILOTOS_REVISION.key?(driver_id) ? "Sí" : "No"
      monto     = servicio["monto_pagado"].to_f
      moneda    = servicio["moneda"].to_s
      cliente   = servicio["cliente_nombre"].to_s.downcase

      base = {
        booking_id:            servicio["booking_id"].to_s,
        piloto_nombre:         (servicio["piloto_nombre"].to_s.empty? ? "N/A" : servicio["piloto_nombre"]),
        piloto_id:             driver_id,
        cliente_nombre:        (servicio["cliente_nombre"].to_s.empty? ? "N/A" : servicio["cliente_nombre"]),
        tipo_servicio:         type_id,
        tipo_servicio_nombre:  tipo_nbr,
        tipo_vehiculo:         (servicio["tipo_vehiculo"].to_s.empty? ? "N/A" : servicio["tipo_vehiculo"]),
        monto:                 monto,
        fecha_servicio:        servicio["fecha_servicio"].to_s,
        pais:                  servicio["pais"].to_s,
        ciudad:                servicio["ciudad"].to_s,
        posible_revision:      revision,
      }

      # 1. Tiempo
      minutos = servicio["minutos_servicio"]
      if minutos && minutos.to_i.positive? && minutos.to_i < TIEMPO_MINIMO
        out << base.merge(
          tipo_alerta: "Tiempo",
          observacion: "Servicio completado en #{minutos.to_i} minutos (menos de #{TIEMPO_MINIMO} min)",
          severidad:   "ALTA",
        )
      end

      # 2. GPS — mismo punto sin retorno a origen ni reserva
      if servicio["flag_alerta_mismo_punto"].to_i == 1
        out << base.merge(
          tipo_alerta:      "GPS",
          observacion:      "Mismo punto de inicio y finalización (sin retorno a origen ni reserva asociada)",
          severidad:        "ALTA",
          return_to_origin: servicio["return_to_origin"].to_i == 1,
          tiene_reserva:    servicio["tiene_reserva"].to_i == 1,
        )
      end

      # 3. Pagos (solo COP)
      if moneda == "COP"
        # Mensajería > 400k
        if type_id == SERVICE_TYPE_IDS["mensajeria"] && monto > MONTOS_ALERTA["mensajeria"]
          out << base.merge(
            tipo_alerta: "Pagos",
            observacion: "Monto excesivo $#{fmt_money(monto)} COP para Mensajería (umbral $#{fmt_money(MONTOS_ALERTA["mensajeria"])})",
            severidad:   "MEDIA",
          )
        end
        # Carga Carry > 800k
        if type_id == SERVICE_TYPE_IDS["carga_carry"] && monto > MONTOS_ALERTA["carga_carry"]
          out << base.merge(
            tipo_alerta: "Pagos",
            observacion: "Monto excesivo $#{fmt_money(monto)} COP para Carga Carry (umbral $#{fmt_money(MONTOS_ALERTA["carga_carry"])})",
            severidad:   "MEDIA",
          )
        end
        # Carga Moto > 600k
        if type_id == SERVICE_TYPE_IDS["carga_moto"] && monto > MONTOS_ALERTA["carga_moto"]
          out << base.merge(
            tipo_alerta: "Pagos",
            observacion: "Monto excesivo $#{fmt_money(monto)} COP para Carga Moto (umbral $#{fmt_money(MONTOS_ALERTA["carga_moto"])})",
            severidad:   "MEDIA",
          )
        end
        # Cruz Verde Mostrador > 80k
        if cliente.include?("cruz verde mostrador") && monto > MONTOS_ALERTA["cruz_verde_mostrador"]
          out << base.merge(
            tipo_alerta: "Pagos",
            observacion: "Monto excesivo $#{fmt_money(monto)} COP para Cruz Verde Mostrador (umbral $#{fmt_money(MONTOS_ALERTA["cruz_verde_mostrador"])})",
            severidad:   "MEDIA",
          )
        end
      end

      out
    end

    def fmt_money(n)
      n.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    public

    # POST /api/pibox/enviar_email — v3.3.21
    def enviar_email
      to_list  = BackgroundMailerHelper.parse_email_list(params[:email] || params[:to])
      cc_list  = BackgroundMailerHelper.parse_email_list(params[:cc])
      bcc_list = BackgroundMailerHelper.parse_email_list(params[:bcc])
      asunto   = params[:asunto].to_s.strip
      mensaje  = params[:mensaje].to_s.strip[0, 1000]
      desde    = desde_param
      hasta    = hasta_param
      usuario  = current_usuario.to_s

      return render(json: { ok: false, error: "Tenés que ingresar al menos un destinatario en 'Para'." }, status: :bad_request) if to_list.empty?
      _v, invalids = BackgroundMailerHelper.split_validos(to_list + cc_list + bcc_list)
      return render(json: { ok: false, error: "Email(s) inválido(s): #{invalids.join(', ')}" }, status: :bad_request) if invalids.any?

      BackgroundMailerHelper.run("PiboxB2B") do
        xlsx = ExcelExportService.build("Picap_Pibox_B2B") do |x|
          x.add_sheet("Resumen") do |s|
            s.banner("Auditorías Servicios Pibox B2B", "Período: #{desde} → #{hasta}", 2)
            s.kpi_section("Datos del período", [
              ["Período", "#{desde} → #{hasta}"],
              ["Generado", Time.now.strftime("%Y-%m-%d %H:%M")],
              ["Nota", "Detalle interactivo (alertas + GPS + fotos) en monitoring.picap.io → Pibox"],
            ], ncols: 2)
            s.finalize
          end
        end
        filename = "Picap_Pibox_B2B_#{desde}_#{hasta}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.xlsx"
        ResendMailerService.send_email(
          to: to_list, cc: cc_list, bcc: bcc_list,
          subject: asunto.empty? ? "Reporte Pibox B2B · #{desde} → #{hasta}" : asunto,
          html: html_email_simple_v321("📦 Auditorías Servicios Pibox B2B", "linear-gradient(90deg,#ea580c,#9a3412)", "#ea580c", "#FFF7ED",
                                       desde, hasta, mensaje, usuario,
                                       "Te compartimos el resumen de auditorías Pibox B2B del período. Para alertas/GPS/fotos, abrí el módulo en el portal."),
          attachment_bytes: xlsx[:data], attachment_filename: filename,
        )
      end

      render json: { ok: true, queued: true, destinatarios: to_list, cc: cc_list, bcc: bcc_list,
                     mensaje: "Reporte en proceso. El email llegará en unos minutos." }, status: :accepted
    rescue => e
      Rails.logger.error("[PiboxController#enviar_email] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    # v3.3.21: template HTML genérico inline (no compartido para evitar Module dependencies).
    def html_email_simple_v321(titulo, gradient, color_main, bg_color, desde, hasta, mensaje_usuario, usuario, descripcion)
      msj_html = mensaje_usuario.to_s.empty? ? "" :
        %Q(<p style="background:#FFFBEB;border-left:4px solid #F59E0B;padding:12px 16px;margin:16px 0;border-radius:4px;color:#78350F"><strong>Mensaje:</strong> #{ERB::Util.h(mensaje_usuario)}</p>)
      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#{bg_color};color:#1F2937">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#{bg_color};padding:20px 0"><tr><td align="center">
            <table cellpadding="0" cellspacing="0" border="0" width="620" style="background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
              <tr><td style="background:#{gradient};padding:24px 28px;color:#fff">
                <div style="font-size:20px;font-weight:700">#{titulo}</div>
                <div style="font-size:12px;opacity:0.92;margin-top:4px">Período: #{desde} → #{hasta}</div>
              </td></tr>
              <tr><td style="padding:28px">
                <p style="margin:0 0 16px;font-size:14px">Hola,</p>
                <p style="margin:0 0 16px;font-size:14px;line-height:1.5">#{descripcion}</p>
                #{msj_html}
                <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">📎 Excel adjunto. Detalle en <a href="https://monitoring.picap.io" style="color:#{color_main}">monitoring.picap.io</a>.</p>
              </td></tr>
              <tr><td style="background:#F9FAFB;padding:12px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                <strong style="color:#{color_main}">Picap Monitoreo</strong> · #{Time.now.strftime('%d/%m/%Y %H:%M')} · Por: #{ERB::Util.h(usuario)}
              </td></tr>
            </table>
          </td></tr></table>
        </body></html>
      HTML
    end
  end
end
