# app/controllers/api/bloqueos_controller.rb
# Replica /api/bloqueos del api.py Python.
# Ejecuta Q_BLOQUEOS (passenger_suspensions + driver_suspensions + passengers),
# enriquece cada fila (país, motivo_mapeado, veredicto), clasifica en
# alertas/bloqueados/reactivados y calcula top10 stats por PILOTO/USUARIO/TODOS.

module Api
  class BloqueosController < ApplicationController
    before_action :authenticate_user!

    SAMPLE_SIZE = 3000

    # GET /api/bloqueos?desde=&hasta=
    def index
      sql = QueriesService.format(
        QueriesService::Q_BLOQUEOS,
        fecha_desde: desde_param, fecha_hasta: hasta_param
      )
      rows = ch.query(sql)

      # 1. Enriquecer cada fila: país, motivo, veredicto
      rows.each do |r|
        # Mapear país
        r["pais_nombre"] = MotivoMapper::PAISES_MAP[r["pais_codigo"]] || r["pais_codigo"]

        # Motivo mapeado según tipo de usuario
        r["motivo_mapeado"] = MotivoMapper.mapear_segun_tipo(
          r["tipo_usuario"],
          comentario_driver: r["comentario_driver"],
          comentario_user:   r["comentario_user"],
          comentario_expulsion_user: r["comentario_expulsion_user"],
        )

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

    # GET /api/estadisticas_bloqueos?desde=&hasta=
    # Solo devuelve los stats agregados (sin las listas grandes)
    def estadisticas
      sql = QueriesService.format(
        QueriesService::Q_BLOQUEOS,
        fecha_desde: desde_param, fecha_hasta: hasta_param
      )
      rows = ch.query(sql)

      rows.each do |r|
        r["pais_nombre"] = MotivoMapper::PAISES_MAP[r["pais_codigo"]] || r["pais_codigo"]
        r["motivo_mapeado"] = MotivoMapper.mapear_segun_tipo(
          r["tipo_usuario"],
          comentario_driver: r["comentario_driver"],
          comentario_user:   r["comentario_user"],
          comentario_expulsion_user: r["comentario_expulsion_user"],
        )
      end

      bloqueados  = rows.select { |r| r["esta_activo"] == "bloqueado" }
      reactivados = rows.select { |r| r["esta_activo"] == "activo" }

      render json: limpiar({
        ok: true,
        desde: desde_param, hasta: hasta_param,
        stats_bloqueados:  top10_stats(bloqueados),
        stats_reactivados: top10_stats(reactivados),
        totales: {
          bloqueados: bloqueados.size,
          reactivados: reactivados.size,
        },
      })
    rescue => e
      Rails.logger.error("[BloqueosController#estadisticas] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

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
