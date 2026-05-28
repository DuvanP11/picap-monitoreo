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

    # POST /api/reconocimiento/enviar_email — v3.3.21
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

      BackgroundMailerHelper.run("RF") do
        xlsx = ExcelExportService.build("Picap_RF") do |x|
          x.add_sheet("Resumen RF") do |s|
            s.banner("Reconocimiento Facial — Alertas", "Período: #{desde} → #{hasta}", 2)
            s.kpi_section("Resumen", [
              ["Período", "#{desde} → #{hasta}"],
              ["Generado", Time.now.strftime("%Y-%m-%d %H:%M")],
              ["Nota", "Comparación de pares y umbrales en monitoring.picap.io → RF"],
            ], ncols: 2)
            s.finalize
          end
        end
        filename = "Picap_RF_#{desde}_#{hasta}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.xlsx"
        ResendMailerService.send_email(
          to: to_list, cc: cc_list, bcc: bcc_list,
          subject: asunto.empty? ? "Reporte Reconocimiento Facial · #{desde} → #{hasta}" : asunto,
          html: rf_email_html(desde, hasta, mensaje, usuario),
          attachment_bytes: xlsx[:data], attachment_filename: filename,
        )
      end

      render json: { ok: true, queued: true, destinatarios: to_list, cc: cc_list, bcc: bcc_list,
                     mensaje: "Reporte en proceso. El email llegará en unos minutos." }, status: :accepted
    rescue => e
      Rails.logger.error("[ReconocimientoController#enviar_email] #{e.class}: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    def rf_email_html(desde, hasta, mensaje_usuario, usuario)
      msj_html = mensaje_usuario.to_s.empty? ? "" :
        %Q(<p style="background:#FFFBEB;border-left:4px solid #F59E0B;padding:12px 16px;margin:16px 0;border-radius:4px;color:#78350F"><strong>Mensaje:</strong> #{ERB::Util.h(mensaje_usuario)}</p>)
      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#FAF5FF;color:#1F2937">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#FAF5FF;padding:20px 0"><tr><td align="center">
            <table cellpadding="0" cellspacing="0" border="0" width="620" style="background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
              <tr><td style="background:linear-gradient(90deg,#7c3aed,#5b21b6);padding:24px 28px;color:#fff">
                <div style="font-size:20px;font-weight:700">👤 Reconocimiento Facial</div>
                <div style="font-size:12px;opacity:0.92;margin-top:4px">Período: #{desde} → #{hasta}</div>
              </td></tr>
              <tr><td style="padding:28px">
                <p style="margin:0 0 16px;font-size:14px">Hola,</p>
                <p style="margin:0 0 16px;font-size:14px;line-height:1.5">Te compartimos el resumen de alertas del módulo de Reconocimiento Facial (detección de cuentas duplicadas por similitud de embeddings).</p>
                #{msj_html}
                <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">📎 Excel adjunto. Detalle en <a href="https://monitoring.picap.io" style="color:#7c3aed">monitoring.picap.io</a> → Reconocimiento Facial.</p>
              </td></tr>
              <tr><td style="background:#F9FAFB;padding:12px 28px;text-align:center;color:#6B7280;font-size:11px;border-top:1px solid #E5E7EB">
                <strong style="color:#7c3aed">Picap Monitoreo</strong> · #{Time.now.strftime('%d/%m/%Y %H:%M')} · Por: #{ERB::Util.h(usuario)}
              </td></tr>
            </table>
          </td></tr></table>
        </body></html>
      HTML
    end
  end
end
