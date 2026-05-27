# app/controllers/api/bloqueos_controller.rb
# Replica /api/bloqueos del api.py Python.
# Ejecuta Q_BLOQUEOS (passenger_suspensions + driver_suspensions + passengers),
# enriquece cada fila (país, motivo_mapeado, veredicto), clasifica en
# alertas/bloqueados/reactivados y calcula top10 stats por PILOTO/USUARIO/TODOS.

module Api
  class BloqueosController < ApplicationController
    before_action :authenticate_user!

    SAMPLE_SIZE = 3000

    # GET /api/bloqueos?desde=&hasta=&tipo_cuenta=
    # v2 (May 2026): nuevo filtro `tipo_cuenta` (Piloto Pibox | Piloto Rent |
    # Pasajero). El campo viene en cada fila desde Q_BLOQUEOS basado en
    # `suspended_service_types` de driver_suspensions.
    def index
      sql = QueriesService.format(
        QueriesService::Q_BLOQUEOS,
        fecha_desde: desde_param, fecha_hasta: hasta_param
      )
      rows = ch.query(sql)

      # Filtro opcional por tipo_cuenta (case insensitive, partial match)
      tipo_cuenta_filter = params[:tipo_cuenta].to_s.strip
      unless tipo_cuenta_filter.empty?
        tc_low = tipo_cuenta_filter.downcase
        rows = rows.select { |r| r["tipo_cuenta"].to_s.downcase.include?(tc_low) }
      end

      # 1. Enriquecer cada fila: país, motivo, veredicto
      rows.each do |r|
        # Mapear país
        r["pais_nombre"] = MotivoMapper::PAISES_MAP[r["pais_codigo"]] || r["pais_codigo"]

        # v2.1: normalizar ciudad (Bogotá D.C / Bogotá / Bogotá, D.C. → "Bogotá")
        r["ciudad"] = MotivoMapper.normalizar_ciudad(r["ciudad"])

        # v2.5: motivo desde el campo `message` de la SUSPENSIÓN específica
        # (no del passengers table user-level). Si message está vacío, fallback
        # ESTRICTO a los comentarios user-level del lado correcto.
        raw_message = r["message_suspension"].to_s.strip
        r["motivo_mapeado"] = if !raw_message.empty?
          MotivoMapper.mapear(raw_message)
        else
          MotivoMapper.mapear_estricto(
            r["quien_suspende"],
            comentario_driver: r["comentario_driver"],
            comentario_user:   r["comentario_user"],
            comentario_expulsion_user: r["comentario_expulsion_user"],
          )
        end

        # Veredicto: EXPULSADO es permanente, SUSPENDIDO se evalúa con regla 30 días
        dias       = r["dias_bloqueado_total"].to_i
        tipo_blq   = r["tipo_bloqueo"].to_s
        if tipo_blq == "EXPULSADO"
          r["veredicto"]     = "EXPULSIÓN PERMANENTE"
          r["alerta_30dias"] = false
        else
          r["veredicto"]     = dias > 30 ? "ALERTA DE TIEMPO" : "TODO OK"
          r["alerta_30dias"] = dias > 30
        end
      end

      # 2. Clasificar en alertas / bloqueados / reactivados
      alertas      = rows.dup
      bloqueados   = rows.select { |r| r["esta_activo"] == "bloqueado" }
      reactivados  = rows.select { |r| r["esta_activo"] == "activo" }

      n_alerta      = alertas.count    { |x| x["veredicto"] == "ALERTA DE TIEMPO" }
      n_ok          = alertas.count    { |x| x["veredicto"] == "TODO OK" }
      n_expulsados  = bloqueados.count { |x| x["tipo_bloqueo"] == "EXPULSADO" }
      n_suspendidos = bloqueados.count { |x| x["tipo_bloqueo"] == "SUSPENDIDO" }
      n_susp_30     = bloqueados.count { |x|
        x["tipo_bloqueo"] == "SUSPENDIDO" && x["dias_bloqueado_total"].to_i > 30
      }
      total = alertas.size

      # 3. Ordenar por días DESC (la métrica que el frontend muestra)
      sort_key = ->(x) {
        -((x["dias_bloqueo_real"] || x["dias_bloqueado_total"]).to_i)
      }
      bloqueados.sort_by!(&sort_key)
      reactivados.sort_by!(&sort_key)

      muestra_truncada = [alertas, bloqueados, reactivados].any? { |a| a.size > SAMPLE_SIZE }

      # v2: breakdowns por tipo_cuenta para alertas / bloqueados / reactivados
      breakdowns = {
        alertas:     breakdown_por_tipo_cuenta(alertas),
        bloqueados:  breakdown_por_tipo_cuenta(bloqueados),
        reactivados: breakdown_por_tipo_cuenta(reactivados),
      }

      # v2.1: top 10 motivos segmentados por tipo_cuenta (sobre bloqueados)
      motivos_por_tc = motivos_por_tipo_cuenta(bloqueados)

      # v2.2: breakdown por quien_suspende (alinea con columna "A QUIEN SE SUSPENDERÁ"
      # del Excel del cliente). Cuenta SUSPENSIONES (no usuarios) — un usuario
      # con N suspensiones aparece N veces.
      por_quien_susp = quien_suspende_breakdown(alertas)
      # USUARIOS únicos (por id_usuario) para reportes operativos
      usuarios_unicos = {
        total_suspensiones:   alertas.size,
        usuarios_unicos:      alertas.map { |r| r["id_usuario"] }.uniq.size,
        bloq_suspensiones:    bloqueados.size,
        bloq_usuarios_unicos: bloqueados.map { |r| r["id_usuario"] }.uniq.size,
      }

      render json: limpiar({
        ok: true,
        desde: desde_param, hasta: hasta_param,
        alertas:     alertas.first(SAMPLE_SIZE),
        bloqueados:  bloqueados.first(SAMPLE_SIZE),
        reactivados: reactivados.first(SAMPLE_SIZE),
        resumen: {
          total:            total,
          alerta:           n_alerta,
          ok:               n_ok,
          bloqueados:       bloqueados.size,
          reactivados:      reactivados.size,
          expulsados:       n_expulsados,
          suspendidos:      n_suspendidos,
          susp_mas30:       n_susp_30,
          pct_alerta:       total > 0 ? (n_alerta.to_f / total * 100).round : 0,
          pct_ok:           total > 0 ? (n_ok.to_f / total * 100).round : 0,
          muestra_size:     SAMPLE_SIZE,
          muestra_truncada: muestra_truncada,
          # v2: nuevos campos
          por_tipo_cuenta:        breakdowns,
          # v2.1: top motivos por tipo de cuenta
          motivos_por_tipo_cuenta: motivos_por_tc,
          # v2.2: nuevos campos (1-fila-por-suspension)
          por_quien_suspende:     por_quien_susp,
          conteos_unicos:         usuarios_unicos,
        },
        stats_bloqueados:  top10_stats(bloqueados),
        stats_reactivados: top10_stats(reactivados),
      })
    rescue => e
      Rails.logger.error("[BloqueosController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message, type: e.class.name },
             status: :internal_server_error
    end

    # GET /api/estadisticas_bloqueos?desde=&hasta=&pais=&driver_id=
    # Devuelve el resumen agregado + breakdown por país para la pestaña
    # "Estadística General" del frontend. Shape específica:
    #   resumen: { total_bloqueados, pilotos_bloqueados, usuarios_bloqueados,
    #              total_suspendidos, total_expulsados, reactivados,
    #              siguen_bloqueados, pct_reactivados, pct_pilotos, pct_usuarios }
    #   por_pais: [{ pais, total, pilotos, usuarios, suspendidos, expulsados,
    #                reactivados, pct_reactivados }, ...]
    def estadisticas
      desde     = desde_param
      hasta     = hasta_param
      pais_fil  = pais_param
      driver_id = params[:driver_id].to_s.strip

      # 1) Resumen global
      res = ch.query(QueriesService.format(
        QueriesService::Q_STATS_BLOQUEOS_RESUMEN, desde: desde, hasta: hasta
      )).first || {}

      total       = res["total_bloqueados"].to_i
      suspendidos = res["total_suspendidos"].to_i
      reactiv     = res["reactivados"].to_i
      pilotos     = res["pilotos_bloqueados"].to_i
      usuarios    = res["usuarios_bloqueados"].to_i
      div         = total > 0 ? total : 1   # evita / 0

      resumen = {
        total_bloqueados:     total,
        pilotos_bloqueados:   pilotos,
        usuarios_bloqueados:  usuarios,
        total_suspendidos:    suspendidos,
        total_expulsados:     res["total_expulsados"].to_i,
        reactivados:          reactiv,
        siguen_bloqueados:    res["siguen_bloqueados"].to_i,
        pct_reactivados:      suspendidos > 0 ? (reactiv.to_f / suspendidos * 100).round(1) : 0,
        pct_pilotos:          (pilotos.to_f  / div * 100).round(1),
        pct_usuarios:         (usuarios.to_f / div * 100).round(1),
      }

      # 2) Por país (con filtro opcional driver_id)
      filtro_driver = driver_id.empty? ? "" : "AND p._id = '#{driver_id.gsub("'", "''")}'"
      paises = ch.query(QueriesService.format(
        QueriesService::Q_STATS_BLOQUEOS_PAIS,
        desde: desde, hasta: hasta, filtro_driver: filtro_driver
      ))

      # Normalizar tipos numéricos (CH puede devolver como string)
      paises = paises.map do |p|
        {
          pais:            p["pais"].to_s,
          total:           p["total"].to_i,
          pilotos:         p["pilotos"].to_i,
          usuarios:        p["usuarios"].to_i,
          suspendidos:     p["suspendidos"].to_i,
          expulsados:      p["expulsados"].to_i,
          reactivados:     p["reactivados"].to_i,
          pct_reactivados: p["pct_reactivados"].to_f,
        }
      end

      # Filtro client-side por país (si llegó ?pais=Colombia)
      paises = paises.select { |p| p[:pais] == pais_fil } if pais_fil.present?

      render json: limpiar({
        desde: desde, hasta: hasta,
        resumen:  resumen,
        por_pais: paises,
      })
    rescue => e
      Rails.logger.error("[BloqueosController#estadisticas] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { error: e.message, detalle: e.backtrace.first(5).join("\n") },
             status: :internal_server_error
    end

    # POST /api/bloqueos/enviar_email
    # Body: { email | to (str|array), cc?, bcc?, asunto?, mensaje?,
    #         desde, hasta, tipo_cuenta? }
    # Genera el xlsx de Bloqueos (mismas hojas que el export directo) y lo
    # envía por email vía Resend. Mismo patrón que MoviiRed.
    def enviar_email
      to_list  = parse_email_list(params[:email] || params[:to])
      cc_list  = parse_email_list(params[:cc])
      bcc_list = parse_email_list(params[:bcc])
      asunto   = params[:asunto].to_s.strip
      mensaje  = params[:mensaje].to_s.strip[0, 1000]
      desde    = desde_param
      hasta    = hasta_param

      if to_list.empty?
        return render(json: { ok: false, error: "Tenés que ingresar al menos un destinatario en 'Para'." }, status: :bad_request)
      end
      invalid = (to_list + cc_list + bcc_list).reject { |e| e.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/) }
      if invalid.any?
        return render(json: { ok: false, error: "Email(s) inválido(s): #{invalid.join(', ')}" }, status: :bad_request)
      end

      # Reusa el builder centralizado del ExportarController (mismo xlsx que
      # se descarga manualmente). El método es estático y recibe ch como
      # parámetro para no depender de instancia.
      xlsx = Api::ExportarController.build_bloqueos_xlsx(desde, hasta, ch)

      filename = "Picap_Bloqueos_#{desde}_#{hasta}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.xlsx"
      subject_default = "Reporte de Bloqueos · #{desde} → #{hasta}"
      html = construir_html_email_bloqueos(desde, hasta, mensaje, current_usuario)

      result = ResendMailerService.send_email(
        to:                  to_list,
        cc:                  cc_list,
        bcc:                 bcc_list,
        subject:             asunto.empty? ? subject_default : asunto,
        html:                html,
        attachment_bytes:    xlsx[:data],
        attachment_filename: filename,
      )

      render json: {
        ok: true,
        destinatarios: to_list,
        cc: cc_list,
        bcc: bcc_list,
        filename: filename,
        resend_id: result[:id],
      }
    rescue ResendMailerService::ConfigError, ResendMailerService::AuthError => e
      Rails.logger.error("[BloqueosController#enviar_email] Resend: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    rescue ResendMailerService::ValidationError => e
      Rails.logger.error("[BloqueosController#enviar_email] Validation: #{e.message}")
      render json: { ok: false, error: e.message }, status: :bad_request
    rescue ResendMailerService::NetworkError => e
      Rails.logger.error("[BloqueosController#enviar_email] Network: #{e.message}")
      render json: { ok: false, error: e.message }, status: :bad_gateway
    rescue => e
      Rails.logger.error("[BloqueosController#enviar_email] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def parse_email_list(val)
      return [] if val.nil?
      raw = val.is_a?(Array) ? val.join(",") : val.to_s
      raw.split(/[,;\s\n]+/).map(&:strip).reject(&:empty?).uniq
    end

    def construir_html_email_bloqueos(desde, hasta, mensaje, usuario)
      msj_html = mensaje.to_s.empty? ? "" : %Q(<p style="background:#FFFBEB;border-left:4px solid #F59E0B;padding:12px 16px;margin:16px 0;border-radius:4px;color:#78350F"><strong>Mensaje:</strong> #{ERB::Util.h(mensaje)}</p>)
      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#F5F3FF;color:#1F2937;">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F5F3FF;padding:20px 0">
            <tr><td align="center">
              <table cellpadding="0" cellspacing="0" border="0" width="640" style="background:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
                <tr><td style="background:linear-gradient(90deg,#6B21A8 0%,#7C3AED 100%);padding:24px 28px;color:#ffffff">
                  <div style="font-size:22px;font-weight:700;letter-spacing:-0.5px">🛡️ Reporte de Bloqueos</div>
                  <div style="font-size:13px;margin-top:6px;opacity:0.92">Período: #{desde} → #{hasta}</div>
                </td></tr>
                <tr><td style="padding:28px">
                  <p style="margin:0 0 12px;font-size:14px">Hola,</p>
                  <p style="margin:0 0 12px;font-size:14px;line-height:1.5">Te compartimos el reporte de bloqueos del período indicado. El archivo Excel adjunto incluye <strong>4 hojas</strong>: Alertas, Bloqueos Actuales, Reactivaciones y Estadística General, todas con la columna <strong>Tipo de Cuenta</strong> (Piloto Pibox / Piloto Rent / Pasajero).</p>
                  #{msj_html}
                  <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">📎 <strong>Adjunto:</strong> archivo Excel (.xlsx) con el detalle completo del módulo Bloqueos.</p>
                </td></tr>
                <tr><td style="background:#F9FAFB;padding:16px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                  Generado automáticamente · <strong style="color:#6B21A8">Picap Monitoreo</strong> · #{Time.now.strftime('%d/%m/%Y %H:%M')}<br>
                  Por: #{ERB::Util.h(usuario || 'sistema')}
                </td></tr>
              </table>
            </td></tr>
          </table>
        </body></html>
      HTML
    end

    # v2 (May 2026): breakdown por tipo_cuenta (Pasajero / Piloto Pibox /
    # Piloto Rent / Piloto Pibox+Rent / Piloto). Devuelve counts y % cruzados
    # con tipo_bloqueo (expulsado vs suspendido) para que el frontend muestre
    # las cards "X% de los expulsados son pilotos" / "X% son pasajeros".
    def breakdown_por_tipo_cuenta(rows)
      total = rows.size
      result = {
        total: total,
        # counts por tipo_cuenta
        pasajero:           rows.count { |r| r["tipo_cuenta"] == "Pasajero" },
        piloto_pibox:       rows.count { |r| r["tipo_cuenta"] == "Piloto Pibox" },
        piloto_rent:        rows.count { |r| r["tipo_cuenta"] == "Piloto Rent" },
        piloto_pibox_rent:  rows.count { |r| r["tipo_cuenta"] == "Piloto Pibox+Rent" },
        piloto_otro:        rows.count { |r| r["tipo_cuenta"] == "Piloto" },
        # cross-stats: expulsados vs suspendidos × pibox/rent/pasajero
        expulsados_pibox:   rows.count { |r| r["tipo_bloqueo"] == "EXPULSADO"   && r["tipo_cuenta"].to_s.include?("Pibox") },
        expulsados_rent:    rows.count { |r| r["tipo_bloqueo"] == "EXPULSADO"   && r["tipo_cuenta"].to_s.include?("Rent") },
        expulsados_pasajero:rows.count { |r| r["tipo_bloqueo"] == "EXPULSADO"   && r["tipo_cuenta"] == "Pasajero" },
        suspendidos_pibox:  rows.count { |r| r["tipo_bloqueo"] == "SUSPENDIDO" && r["tipo_cuenta"].to_s.include?("Pibox") },
        suspendidos_rent:   rows.count { |r| r["tipo_bloqueo"] == "SUSPENDIDO" && r["tipo_cuenta"].to_s.include?("Rent") },
        suspendidos_pasajero: rows.count { |r| r["tipo_bloqueo"] == "SUSPENDIDO" && r["tipo_cuenta"] == "Pasajero" },
      }
      # Porcentajes (sobre total, evita /0)
      div = total > 0 ? total.to_f : 1.0
      result[:pct_pasajero]            = (result[:pasajero] / div * 100).round(1)
      result[:pct_piloto_pibox]        = (result[:piloto_pibox] / div * 100).round(1)
      result[:pct_piloto_rent]         = (result[:piloto_rent]  / div * 100).round(1)
      result[:pct_piloto_pibox_rent]   = (result[:piloto_pibox_rent] / div * 100).round(1)
      # Top ciudades segmentado por tipo_cuenta
      result[:top_ciudades_piloto] = top_ciudades(rows.select { |r| r["tipo_cuenta"].to_s.start_with?("Piloto") }, 8)
      result[:top_ciudades_pasajero] = top_ciudades(rows.select { |r| r["tipo_cuenta"] == "Pasajero" }, 8)
      # Top tipos de servicio (Pibox / Rent / Pibox+Rent / Pasajero)
      tipos = rows.group_by { |r| r["tipo_cuenta"].to_s.empty? ? "(sin tipo)" : r["tipo_cuenta"] }
                  .map { |k, v| { tipo: k, count: v.size, pct: total > 0 ? (v.size.to_f / total * 100).round(1) : 0 } }
                  .sort_by { |h| -h[:count] }
      result[:top_servicios] = tipos
      result
    end

    def top_ciudades(rows, n = 8)
      rows.group_by { |r| r["ciudad"].to_s.empty? ? "(sin ciudad)" : r["ciudad"] }
          .map { |c, v| { ciudad: c, count: v.size } }
          .sort_by { |h| -h[:count] }
          .first(n)
    end

    # v2.2: breakdown por quien_suspende (PRESTADOR vs CONSUMIDOR) — alinea con
    # la columna "A QUIEN SE SUSPENDERÁ" del Excel del cliente. Devuelve también
    # el cruce con tipo_bloqueo (Expulsión/Suspensión) y service_types para
    # replicar exactamente el pivot del Excel.
    def quien_suspende_breakdown(rows)
      total = rows.size
      prestador = rows.count { |r| r["quien_suspende"] == "USUARIO PRESTADOR" }
      consumidor = rows.count { |r| r["quien_suspende"] == "USUARIO CONSUMIDOR" }
      # Cross: quien_suspende × tipo_bloqueo
      pres_exp = rows.count { |r| r["quien_suspende"] == "USUARIO PRESTADOR" && r["tipo_bloqueo"] == "EXPULSADO" }
      pres_sus = rows.count { |r| r["quien_suspende"] == "USUARIO PRESTADOR" && r["tipo_bloqueo"] == "SUSPENDIDO" }
      cons_exp = rows.count { |r| r["quien_suspende"] == "USUARIO CONSUMIDOR" && r["tipo_bloqueo"] == "EXPULSADO" }
      cons_sus = rows.count { |r| r["quien_suspende"] == "USUARIO CONSUMIDOR" && r["tipo_bloqueo"] == "SUSPENDIDO" }
      div = total > 0 ? total.to_f : 1.0
      {
        total:               total,
        prestador:           prestador,
        consumidor:          consumidor,
        pct_prestador:       (prestador / div * 100).round(1),
        pct_consumidor:      (consumidor / div * 100).round(1),
        prestador_expulsion: pres_exp,
        prestador_suspension: pres_sus,
        consumidor_expulsion: cons_exp,
        consumidor_suspension: cons_sus,
      }
    end

    # v2.1: Top 10 motivos de bloqueo SEGMENTADOS por tipo_cuenta.
    # Devuelve hash con claves "Piloto Pibox" / "Piloto Rent" / "Piloto Pibox+Rent"
    # / "Pasajero", cada una con array de {motivo, count, pct} (pct calculado
    # sobre el total de bloqueados de ESE tipo, no del total global, para que
    # las cifras tengan sentido al leer "X% de los pasajeros bloqueados").
    def motivos_por_tipo_cuenta(rows, n = 10)
      result = {}
      tipos = ["Piloto Pibox", "Piloto Rent", "Piloto Pibox+Rent", "Pasajero"]
      tipos.each do |tc|
        subset = rows.select { |r| r["tipo_cuenta"] == tc }
        total = subset.size
        motivos = Hash.new(0)
        subset.each do |r|
          m = r["motivo_mapeado"].to_s.strip
          motivos[m] += 1 unless m.empty?
        end
        top = motivos.sort_by { |_, v| -v }.first(n).map { |motivo, count|
          { motivo: motivo, count: count, pct: total > 0 ? (count.to_f / total * 100).round(1) : 0 }
        }
        result[tc] = { total: total, top: top }
      end
      result
    end

    # Replica top10_stats() del Python. Segmenta por PILOTO/USUARIO/TODOS.
    def top10_stats(rows)
      result = {}
      %w[PILOTO USUARIO TODOS].each do |tipo|
        subset = tipo == "TODOS" ? rows : rows.select { |r| r["tipo_usuario"] == tipo }
        total  = subset.size

        motivos     = Hash.new(0)
        paises      = Hash.new(0)
        ciudades    = Hash.new(0)
        por_tipo    = Hash.new(0)

        subset.each do |r|
          # Motivo: usar el ya calculado, si no, intentar mapear comentarios
          m = r["motivo_mapeado"].to_s.strip
          if m.empty?
            [r["comentario_driver"], r["comentario_user"], r["comentario_expulsion_user"]].each do |c|
              next if c.nil? || c.to_s.strip.empty?
              candidato = MotivoMapper.mapear(c.strip)
              if candidato && !candidato.to_s.strip.empty?
                m = candidato
                break
              end
            end
          end
          motivos[m] += 1 unless m.empty?

          p = r["pais_nombre"].to_s
          paises[p] += 1 unless p.empty?

          c = r["ciudad"].to_s
          ciudades[c] += 1 unless c.empty?

          tb = r["tipo_bloqueo"].to_s
          por_tipo[tb] += 1 unless tb.empty?
        end

        pct = ->(v) { total > 0 ? (v.to_f / total * 100).round(1) : 0 }
        result[tipo] = {
          total: total,
          top_motivos:      motivos.sort_by   { |_, v| -v }.first(10).map { |k, v| { motivo: k, count: v, pct: pct.call(v) } },
          top_paises:       paises.sort_by    { |_, v| -v }.first(5).map  { |k, v| { pais:   k, count: v, pct: pct.call(v) } },
          top_ciudades:     ciudades.sort_by  { |_, v| -v }.first(10).map { |k, v| { ciudad: k, count: v, pct: pct.call(v) } },
          por_tipo_bloqueo: por_tipo.sort_by  { |_, v| -v }.map           { |k, v| { tipo:   k, count: v, pct: pct.call(v) } },
        }
      end
      result
    end
  end
end
