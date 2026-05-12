# app/controllers/api/recaudos_controller.rb
# Validación de recaudos (api.py 3866-4044).
# Basado en WalletAccountCounterDeliveryTransaction:
#   Correcto      → balance_neto = 0 (recaudó del cliente = abonó al piloto)
#   Pagado_demas  → balance_neto > 0 (Picap le debe al piloto)
#   Debe_dinero   → balance_neto < 0 (piloto debe a Picap)
#   Revisar       → balance_neto IS NULL OR muchas tx con neto ≈ 0

module Api
  class RecaudosController < ApplicationController
    before_action :authenticate_user!

    # GET /api/recaudos?desde=&hasta=&moneda=&q=&tipo=
    def index
      desde   = desde_param
      hasta   = hasta_param
      moneda  = params[:moneda].to_s.strip
      q_id    = params[:q].to_s.strip
      q_tipo  = params[:tipo].to_s.strip
      q_tipo  = "booking" unless %w[booking driver].include?(q_tipo)

      filtro_moneda = moneda.empty? ? "" : "AND JSONExtractString(wat.amount,'currency_iso')='#{moneda.gsub("'", "''")}'"

      sql = QueriesService.format(
        QueriesService::Q_RECAUDOS,
        desde: desde, hasta: hasta, filtro_moneda: filtro_moneda
      )
      rows = ch.query(sql)

      # Normalizar tipos y formatear fecha
      rows = rows.map do |r|
        {
          "id_booking"     => r["id_booking"].to_s,
          "fecha_tx"       => r["fecha_tx"].to_s[0, 16],
          "tipo_tx"        => r["tipo_tx"].to_s,
          "moneda"         => r["moneda"].to_s,
          "suma_negativos" => r["suma_negativos"].to_f.round(2),
          "suma_positivos" => r["suma_positivos"].to_f.round(2),
          "balance_neto"   => r["balance_neto"].to_f.round(2),
          "cnt_negativos"  => r["cnt_negativos"].to_i,
          "cnt_positivos"  => r["cnt_positivos"].to_i,
          "cnt_total"      => r["cnt_total"].to_i,
          "clasificacion"  => r["clasificacion"].to_s,
        }
      end

      # Filtro por ID (client-side sobre el sample)
      if q_id.length >= 4
        q_low = q_id.downcase
        campo = q_tipo == "driver" ? "id_booking" : "id_booking" # solo booking en CTE
        rows = rows.select { |r| r[campo].to_s.downcase.include?(q_low) }
      end

      # Agregados
      total     = rows.size
      n_corr    = rows.count { |r| r["clasificacion"] == "Correcto" }
      n_demas   = rows.count { |r| r["clasificacion"] == "Pagado_demas" }
      n_deuda   = rows.count { |r| r["clasificacion"] == "Debe_dinero" }
      n_rev     = rows.count { |r| r["clasificacion"] == "Revisar" }

      v_corr  = rows.select { |r| r["clasificacion"] == "Correcto"    }.sum { |r| r["balance_neto"].abs }
      v_demas = rows.select { |r| r["clasificacion"] == "Pagado_demas" }.sum { |r| r["balance_neto"]      }
      v_deuda = rows.select { |r| r["clasificacion"] == "Debe_dinero"  }.sum { |r| r["balance_neto"].abs }
      v_rev   = rows.select { |r| r["clasificacion"] == "Revisar"      }.sum { |r| r["balance_neto"].abs }

      # Tendencia diaria
      trend_map = Hash.new { |h, k| h[k] = { correcto: 0, demas: 0, deuda: 0, revisar: 0 } }
      rows.each do |r|
        fecha = r["fecha_tx"][0, 10]
        next if fecha.empty? || fecha == "—"
        case r["clasificacion"]
        when "Correcto"     then trend_map[fecha][:correcto] += 1
        when "Pagado_demas" then trend_map[fecha][:demas]    += 1
        when "Debe_dinero"  then trend_map[fecha][:deuda]    += 1
        else                     trend_map[fecha][:revisar]  += 1
        end
      end
      trend = trend_map.sort.map { |fecha, v| v.merge(fecha: fecha) }

      # Distribución por moneda
      monedas = Hash.new { |h, k| h[k] = { total: 0, correcto: 0, demas: 0, deuda: 0, revisar: 0, v_demas: 0.0, v_deuda: 0.0 } }
      rows.each do |r|
        m = r["moneda"].to_s.empty? ? "N/A" : r["moneda"]
        monedas[m][:total] += 1
        case r["clasificacion"]
        when "Correcto"
          monedas[m][:correcto] += 1
        when "Pagado_demas"
          monedas[m][:demas]    += 1
          monedas[m][:v_demas]  += r["balance_neto"]
        when "Debe_dinero"
          monedas[m][:deuda]    += 1
          monedas[m][:v_deuda]  += r["balance_neto"].abs
        else
          monedas[m][:revisar]  += 1
        end
      end
      por_moneda = monedas.sort_by { |_, v| -v[:total] }.map { |m, v| v.merge(moneda: m) }

      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta,
        resumen: {
          total:        total,
          correcto:     n_corr,
          pagado_demas: n_demas,
          debe_dinero:  n_deuda,
          revisar:      n_rev,
          v_correcto:   v_corr.round(2),
          v_demas:      v_demas.round(2),
          v_deuda:      v_deuda.round(2),
          v_revisar:    v_rev.round(2),
          pct_correcto: total > 0 ? (n_corr.to_f  / total * 100).round(1) : 0,
          pct_demas:    total > 0 ? (n_demas.to_f / total * 100).round(1) : 0,
          pct_deuda:    total > 0 ? (n_deuda.to_f / total * 100).round(1) : 0,
          pct_revisar:  total > 0 ? (n_rev.to_f   / total * 100).round(1) : 0,
        },
        trend:      trend,
        por_moneda: por_moneda,
        filas:      rows,
      })
    rescue => e
      Rails.logger.error("[RecaudosController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end
  end
end
