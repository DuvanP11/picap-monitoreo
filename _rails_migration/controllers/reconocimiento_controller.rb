# app/controllers/api/reconocimiento_controller.rb
# Replica /api/reconocimiento (api.py 2580-2784).
# Detecta posibles cuentas duplicadas comparando rostros (embeddings cosine).
# Modos preset:
#   alta        → umbral 0.96 (defecto, casos muy seguros)
#   equilibrado → umbral 0.93 (balance)
#   auditoria   → umbral 0.85 (revisión amplia)
# Si solo_con_apellido=1, exige tokens (≥3 chars) compartidos entre nombre_a/b.
# IMEI compartido siempre dispara alerta (señal independiente del rostro).

module Api
  class ReconocimientoController < ApplicationController
    before_action :authenticate_user!

    PRESETS = { "alta" => 0.96, "equilibrado" => 0.93, "auditoria" => 0.85 }.freeze

    # GET /api/reconocimiento?desde=&hasta=&modo=&umbral=&solo_con_apellido=
    def index
      desde = params[:desde].presence || "2024-01-01"
      hasta = params[:hasta].presence || Date.today.strftime("%Y-%m-%d")
      modo  = params[:modo].to_s.downcase
      modo  = "alta" unless PRESETS.key?(modo)
      umbral_default = PRESETS[modo]
      umbral = (params[:umbral].to_f rescue umbral_default)
      umbral = umbral_default if umbral.zero?
      umbral = [[umbral, 0.50].max, 1.00].min
      solo_apellido = %w[1 true True].include?(params[:solo_con_apellido].to_s)

      # 1) Verificar existencia de tabla
      tabla_ok = ch.query(
        "SELECT count() AS n FROM system.tables WHERE database='picapmongoprod' AND name='alertas_reconocimiento'"
      ).first.to_h["n"].to_i.positive?

      unless tabla_ok
        return render(json: {
          tabla_existe: false, alertas: [],
          resumen: { total_alertas: 0, total_alerta: 0, total_revisar: 0,
                     total_posible: 0, pilotos_unicos: 0 },
        })
      end

      tokens_sql = ->(col) {
        "arrayFilter(tk -> length(tk) >= 3, " \
        "arrayMap(s -> lowerUTF8(s), splitByChar(' ', toString(#{col}))))"
      }
      apellido_ok_sql = "(length(#{tokens_sql.call('nombre_a')}) > 0 " \
                        "AND length(#{tokens_sql.call('nombre_b')}) > 0 " \
                        "AND arrayCount(t -> has(#{tokens_sql.call('nombre_b')}, t), " \
                        "#{tokens_sql.call('nombre_a')}) > 0)"
      filtro_alerta = if solo_apellido
        "((toFloat64(similitud) >= #{umbral} AND #{apellido_ok_sql}) " \
        "OR ifNull(mismo_imei,'NO')='SÍ')"
      else
        "(toFloat64(similitud) >= #{umbral} OR ifNull(mismo_imei,'NO')='SÍ')"
      end

      # 2) Resumen agregado
      sql_resumen = <<~SQL
        SELECT
            count()                                                AS total_filas,
            countIf(#{filtro_alerta})                              AS total_alertas,
            count() - countIf(#{filtro_alerta})                    AS total_descartadas,
            countIf(tipo_alerta='RF + IMEI' AND #{filtro_alerta})  AS n_rf_imei,
            countIf(tipo_alerta='RF'        AND #{filtro_alerta})  AS n_rf,
            countIf(tipo_alerta='IMEI'      AND ifNull(mismo_imei,'NO')='SÍ') AS n_imei,
            countIf(nivel='FOTO_DUPLICADA' AND #{filtro_alerta})   AS n_duplicada,
            countIf(nivel='ALERTA'         AND #{filtro_alerta})   AS n_alerta,
            countIf(nivel='REVISAR'        AND #{filtro_alerta})   AS n_revisar,
            countIf(nivel='POSIBLE'        AND #{filtro_alerta})   AS n_posible,
            round(maxIf(similitud, toFloat64(similitud) > 0), 4)   AS sim_max,
            round(avgIf(similitud, toFloat64(similitud) > 0), 4)   AS sim_avg,
            count(DISTINCT user_id_a)                              AS pilotos,
            countIf(NOT #{apellido_ok_sql} AND #{filtro_alerta})   AS n_apellido_distinto
        FROM picapmongoprod.alertas_reconocimiento
        WHERE procesado_en >= toDateTime('#{desde} 00:00:00')
          AND procesado_en <= toDateTime('#{hasta} 23:59:59')
      SQL
      res = ch.query(sql_resumen).first || {}

      # 3) Detalle (300 alertas top)
      sql_det = <<~SQL
        SELECT
            ifNull(tipo_alerta,'RF')   AS tipo_alerta,
            nivel,
            toFloat64(similitud)       AS similitud,
            ifNull(mismo_imei,'NO')    AS mismo_imei,
            toString(nombre_a)         AS nombre_a,
            toString(user_id_a)        AS user_id_a,
            toString(url_a)            AS url_a,
            toString(created_at_a)     AS created_at_a,
            toString(nombre_b)         AS nombre_b,
            toString(user_id_b)        AS user_id_b,
            toString(url_b)            AS url_b,
            toString(created_at_b)     AS created_at_b,
            procesado_en,
            IF(#{apellido_ok_sql}, 1, 0) AS apellido_coincide,
            multiIf(
                toFloat64(similitud) >= #{umbral}, 'MISMA_PERSONA',
                ifNull(mismo_imei,'NO') = 'SÍ', 'MISMO_DISPOSITIVO',
                'PERSONA_DIFERENTE'
            ) AS clasificacion_final
        FROM picapmongoprod.alertas_reconocimiento
        WHERE procesado_en >= toDateTime('#{desde} 00:00:00')
          AND procesado_en <= toDateTime('#{hasta} 23:59:59')
          AND #{filtro_alerta}
        ORDER BY
            multiIf(tipo_alerta='RF + IMEI', 0, tipo_alerta='RF', 1, 2),
            similitud DESC
        LIMIT 300
      SQL

      alertas = ch.query(sql_det).map do |row|
        row["similitud"] = row["similitud"].to_f.round(4)
        row
      end

      render json: limpiar({
        tabla_existe:      true,
        desde:             desde,
        hasta:             hasta,
        modo:              modo,
        umbral_aplicado:   umbral,
        solo_con_apellido: solo_apellido,
        resumen: {
          total_filas:             res["total_filas"].to_i,
          total_alertas:           res["total_alertas"].to_i,
          total_descartadas:       res["total_descartadas"].to_i,
          total_rf_imei:           res["n_rf_imei"].to_i,
          total_rf:                res["n_rf"].to_i,
          total_imei:              res["n_imei"].to_i,
          total_duplicada:         res["n_duplicada"].to_i,
          total_alerta:            res["n_alerta"].to_i,
          total_revisar:           res["n_revisar"].to_i,
          total_posible:           res["n_posible"].to_i,
          total_apellido_distinto: res["n_apellido_distinto"].to_i,
          sim_max:                 res["sim_max"].to_f,
          sim_avg:                 res["sim_avg"].to_f,
          pilotos_unicos:          res["pilotos"].to_i,
          umbral:                  umbral,
          modo:                    modo,
        },
        alertas: alertas,
      })
    rescue => e
      Rails.logger.error("[ReconocimientoController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: {
        error: e.message, detalle: e.backtrace.first(5).join("\n"),
        tabla_existe: false, alertas: [], resumen: { total_alertas: 0 },
      }, status: :internal_server_error
    end
  end
end
