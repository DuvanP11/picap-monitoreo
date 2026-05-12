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

    # GET /api/pibox/export — pendiente Excel (Bloque H)
    def export
      render json: { ok: false, error: "Pibox export: pendiente (Bloque H)" },
             status: :service_unavailable
    end

    private

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
  end
end
