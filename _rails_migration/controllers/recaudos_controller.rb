# app/controllers/api/recaudos_controller.rb
# Validación de Recaudos v2 — Split en Picash | Ida y Vuelta.
# Una fila por booking, con detalle de piloto, comercio, moneda, valor servicio,
# recaudos +/-, recaudo_neto, clasificación (DEBE/AL DIA/PAGADO DE MAS/SIN RECAUDO).
# Fase 3: agrega `estado_real` que considera el balance Picash actual del piloto.

module Api
  class RecaudosController < ApplicationController
    before_action :authenticate_user!

    # GET /api/recaudos?desde=&hasta=&pais=&company_id=&piloto_id=
    def index
      desde      = desde_param
      hasta      = hasta_param
      pais       = params[:pais].to_s.strip
      company_id = params[:company_id].to_s.strip
      piloto_id  = params[:piloto_id].to_s.strip

      esc = ->(v) { v.to_s.gsub("'", "''") }
      filtro_pais = pais.empty? ? "" : "AND b.g_country = '#{esc.(pais[0,2].upcase)}'"

      sql = QueriesService.format(
        QueriesService::Q_RECAUDOS_DETALLE,
        desde: desde, hasta: hasta,
        filtro_pais: filtro_pais,
        limit_filas: 20_000,
      )
      rows = ch.query(sql, timeout: 300)

      rows = rows.map { |r| normalizar(r) }
      if company_id.length >= 4
        cid_low = company_id.downcase
        rows = rows.select { |r| r["company_id"].to_s.downcase.include?(cid_low) }
      end
      if piloto_id.length >= 4
        pid_low = piloto_id.downcase
        rows = rows.select { |r| r["driver_id"].to_s.downcase.include?(pid_low) }
      end

      # Fase 3: enriquecer con balance Picash del piloto + estado_real
      driver_ids = rows.map { |r| r["driver_id"] }.compact.uniq.reject(&:empty?)
      balances   = cargar_balances_picash(driver_ids, hasta)
      rows.each do |r|
        b = balances[r["driver_id"]] || {}
        r["balance_actual"]  = b[:actual]
        r["balance_fin_mes"] = b[:fin_mes]
        # estado_real usa el saldo ACTUAL del piloto (hoy) — si está saldado
        # ahora, el debe del booking ya está cubierto aunque sea por otro
        # servicio posterior.
        r["estado_real"]     = calcular_estado_real(r["debe"], r["balance_actual"])
      end

      picash     = rows.select { |r| r["tipo_deuda"] == "PICASH" }
      idayvuelta = rows.select { |r| r["tipo_deuda"] == "IDA Y VUELTA" }

      render json: limpiar({
        ok: true,
        desde: desde, hasta: hasta, pais: pais,
        picash:        { stats: calc_stats(picash),     filas: picash.first(5000) },
        ida_y_vuelta:  { stats: calc_stats(idayvuelta), filas: idayvuelta.first(5000) },
      })
    rescue => e
      Rails.logger.error("[RecaudosController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    # POST /api/recaudos/enviar_email
    # Body: { email, asunto?, mensaje?, desde, hasta, pais?, tipo (picash|ida_y_vuelta) }
    # Genera el xlsx del sub-tab y lo envía por email con plantilla HTML corporativa.
    def enviar_email
      destinatario = params[:email].to_s.strip
      asunto       = params[:asunto].to_s.strip
      mensaje      = params[:mensaje].to_s.strip[0, 1000]
      desde        = desde_param
      hasta        = hasta_param
      pais         = params[:pais].to_s.strip
      tipo         = params[:tipo].to_s.strip.downcase
      tipo         = "picash" unless %w[picash ida_y_vuelta].include?(tipo)

      unless destinatario.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
        return render(json: { ok: false, error: "Email destinatario inválido" }, status: :bad_request)
      end

      # 1) Query + enriquecimiento (mismo flujo que index)
      esc = ->(v) { v.to_s.gsub("'", "''") }
      filtro_pais = pais.empty? ? "" : "AND b.g_country = '#{esc.(pais[0,2].upcase)}'"
      sql = QueriesService.format(
        QueriesService::Q_RECAUDOS_DETALLE,
        desde: desde, hasta: hasta,
        filtro_pais: filtro_pais,
        limit_filas: 20_000,
      )
      rows = ch.query(sql, timeout: 300).map { |r| normalizar(r) }
      driver_ids = rows.map { |r| r["driver_id"] }.compact.uniq.reject(&:empty?)
      balances   = cargar_balances_picash(driver_ids, hasta)
      rows.each do |r|
        b = balances[r["driver_id"]] || {}
        r["balance_actual"]  = b[:actual]
        r["balance_fin_mes"] = b[:fin_mes]
        r["estado_real"]     = calcular_estado_real(r["debe"], r["balance_actual"])
      end

      sub_rows = if tipo == "ida_y_vuelta"
        rows.select { |r| r["tipo_deuda"] == "IDA Y VUELTA" }
      else
        rows.select { |r| r["tipo_deuda"] == "PICASH" }
      end
      stats     = calc_stats(sub_rows)
      tipo_nbr  = tipo == "ida_y_vuelta" ? "Ida y Vuelta" : "Picash"

      # 2) Construir xlsx
      xlsx = construir_xlsx_recaudos(sub_rows, tipo_nbr, desde, hasta)
      filename = "Picap_Recaudos_#{tipo == 'ida_y_vuelta' ? 'IdaVuelta' : 'Picash'}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.xlsx"

      # 3) Build HTML body + send
      subject_default = "Reporte Recaudos #{tipo_nbr} · #{desde} → #{hasta}"
      asunto_final    = asunto.empty? ? subject_default : asunto
      html            = construir_html_email(tipo_nbr, desde, hasta, stats, mensaje, current_usuario)

      result = ResendMailerService.send_email(
        to:                  destinatario,
        subject:             asunto_final,
        html:                html,
        attachment_bytes:    xlsx[:data],
        attachment_filename: filename,
      )

      render json: {
        ok: true,
        destinatario: destinatario,
        filename: filename,
        total: sub_rows.size,
        resend_id: result[:id],
      }
    rescue ResendMailerService::ConfigError => e
      Rails.logger.error("[RecaudosController#enviar_email] Resend config: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    rescue ResendMailerService::AuthError => e
      Rails.logger.error("[RecaudosController#enviar_email] Resend auth: #{e.message}")
      render json: { ok: false, error: e.message }, status: :internal_server_error
    rescue ResendMailerService::ValidationError => e
      Rails.logger.error("[RecaudosController#enviar_email] Resend validation: #{e.message}")
      render json: { ok: false, error: e.message }, status: :bad_request
    rescue ResendMailerService::NetworkError => e
      Rails.logger.error("[RecaudosController#enviar_email] Resend network: #{e.message}")
      render json: { ok: false, error: e.message }, status: :bad_gateway
    rescue => e
      Rails.logger.error("[RecaudosController#enviar_email] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.first(8).join("\n"))
      render json: { ok: false, error: e.message }, status: :internal_server_error
    end

    private

    # Construye el xlsx del sub-tab (mismas columnas que el export endpoint).
    def construir_xlsx_recaudos(sub_rows, tipo_nbr, desde, hasta)
      ExcelExportService.build("Picap_Recaudos_#{tipo_nbr.gsub(' ', '')}") do |x|
        x.add_sheet("Recaudos #{tipo_nbr}") do |s|
          s.banner("Recaudos #{tipo_nbr}",
                   "Período: #{desde} → #{hasta}  ·  Registros: #{sub_rows.size}", 15)
          s.headers([
            "Fecha servicio", "Booking ID", "Piloto ID", "Piloto Nombre",
            "Comercio ID", "Comercio Nombre", "Ciudad", "Moneda",
            "Valor servicio", "Recaudo +", "Recaudo −", "Recaudo neto",
            "Saldo actual", "Saldo fin de mes", "Estado booking", "Estado real",
          ])
          sub_rows.each do |r|
            ba = r["balance_actual"]
            bf = r["balance_fin_mes"]
            s.data_row([
              r["fecha_servicio"].to_s[0, 19], r["booking_id"], r["driver_id"], r["nombre_piloto"],
              r["company_id"], r["comercio"], r["ciudad"], r["moneda"],
              r["valor_servicio"], r["total_positivo"], r["total_negativo"], r["recaudo_neto"],
              ba.nil? ? "" : ba.to_f.round(2),
              bf.nil? ? "" : bf.to_f.round(2),
              r["debe"], r["estado_real"],
            ], right_align: [9, 10, 11, 12, 13, 14])
          end
          s.finalize(freeze_row: 4)
        end
      end
    end

    # Construye el cuerpo HTML del email con styling Picap (#6B21A8).
    def construir_html_email(tipo_nbr, desde, hasta, stats, mensaje_usuario, usuario)
      fmt_num = ->(n) { (n || 0).to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1.').reverse }
      fmt_money = ->(n) {
        sign = (n || 0) < 0 ? "-" : ""
        "$ #{sign}#{(n || 0).abs.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1.').reverse}"
      }
      msj_html = mensaje_usuario.empty? ? "" : "<p style=\"background:#FFFBEB;border-left:4px solid #F59E0B;padding:12px 16px;margin:16px 0;border-radius:4px;color:#78350F\"><strong>Mensaje:</strong> #{ERB::Util.h(mensaje_usuario)}</p>"

      <<~HTML
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:Arial,Helvetica,sans-serif;margin:0;padding:0;background:#F5F3FF;color:#1F2937;">
          <table cellpadding="0" cellspacing="0" border="0" width="100%" style="background:#F5F3FF;padding:20px 0">
            <tr><td align="center">
              <table cellpadding="0" cellspacing="0" border="0" width="640" style="background:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)">
                <tr><td style="background:linear-gradient(90deg,#6B21A8 0%,#7C3AED 100%);padding:24px 28px;color:#ffffff">
                  <div style="font-size:22px;font-weight:700;letter-spacing:-0.5px">📊 Reporte de Recaudos #{ERB::Util.h(tipo_nbr)}</div>
                  <div style="font-size:13px;margin-top:6px;opacity:0.92">Período: #{desde} → #{hasta}</div>
                </td></tr>
                <tr><td style="padding:28px">
                  <p style="margin:0 0 12px;font-size:14px">Hola,</p>
                  <p style="margin:0 0 12px;font-size:14px;line-height:1.5">Te compartimos el reporte de recaudos del período indicado. Encontrarás el detalle completo de los servicios en el archivo Excel adjunto.</p>
                  #{msj_html}
                  <h3 style="color:#6B21A8;margin:24px 0 12px;font-size:15px">📈 Resumen ejecutivo</h3>
                  <table cellpadding="0" cellspacing="6" border="0" width="100%" style="margin:0 -6px">
                    <tr>
                      <td style="background:#EDE9F5;border-top:3px solid #6B21A8;padding:12px;border-radius:6px;width:33%">
                        <div style="font-size:22px;font-weight:700;color:#1F2937">#{fmt_num.(stats[:total])}</div>
                        <div style="font-size:11px;color:#6B7280;margin-top:4px">Total servicios</div>
                      </td>
                      <td style="background:#FEE2E2;border-top:3px solid #EF4444;padding:12px;border-radius:6px;width:33%">
                        <div style="font-size:22px;font-weight:700;color:#991B1B">#{fmt_num.(stats[:debe])}</div>
                        <div style="font-size:11px;color:#7F1D1D;margin-top:4px">❌ Debe (neto booking)</div>
                        <div style="font-size:12px;font-weight:600;color:#991B1B;margin-top:6px">#{fmt_money.(stats[:v_deuda])}</div>
                      </td>
                      <td style="background:#EDE9FE;border-top:3px solid #7C3AED;padding:12px;border-radius:6px;width:33%">
                        <div style="font-size:22px;font-weight:700;color:#5B21B6">#{fmt_num.(stats[:debe_real])}</div>
                        <div style="font-size:11px;color:#5B21B6;margin-top:4px">🔍 Debe real</div>
                        <div style="font-size:12px;font-weight:600;color:#5B21B6;margin-top:6px">#{fmt_money.(stats[:v_deuda_real])}</div>
                      </td>
                    </tr>
                    <tr>
                      <td style="background:#DCFCE7;border-top:3px solid #22C55E;padding:12px;border-radius:6px">
                        <div style="font-size:22px;font-weight:700;color:#166534">#{fmt_num.(stats[:al_dia])}</div>
                        <div style="font-size:11px;color:#166534;margin-top:4px">✅ Al día</div>
                      </td>
                      <td style="background:#FEF3C7;border-top:3px solid #F59E0B;padding:12px;border-radius:6px">
                        <div style="font-size:22px;font-weight:700;color:#92400E">#{fmt_num.(stats[:pagado_demas])}</div>
                        <div style="font-size:11px;color:#92400E;margin-top:4px">⚠ Pagado de más</div>
                        <div style="font-size:12px;font-weight:600;color:#92400E;margin-top:6px">#{fmt_money.(stats[:v_demas])}</div>
                      </td>
                      <td style="background:#F1F5F9;border-top:3px solid #94A3B8;padding:12px;border-radius:6px">
                        <div style="font-size:22px;font-weight:700;color:#475569">#{fmt_num.(stats[:sin_recaudo])}</div>
                        <div style="font-size:11px;color:#475569;margin-top:4px">∅ Sin recaudo</div>
                      </td>
                    </tr>
                  </table>
                  <table cellpadding="12" cellspacing="6" border="0" width="100%" style="margin-top:6px">
                    <tr>
                      <td style="background:#FAFAFA;border:1px solid #E5E7EB;border-radius:6px;width:50%">
                        <div style="font-size:11px;color:#6B7280">Valor total de servicios · #{stats[:moneda]}</div>
                        <div style="font-size:18px;font-weight:700;color:#6B21A8;margin-top:4px">#{fmt_money.(stats[:v_servicios])}</div>
                      </td>
                      <td style="background:#FAFAFA;border:1px solid #E5E7EB;border-radius:6px;width:50%">
                        <div style="font-size:11px;color:#6B7280">Total recaudado (positivos)</div>
                        <div style="font-size:18px;font-weight:700;color:#22C55E;margin-top:4px">#{fmt_money.(stats[:v_recaudado])}</div>
                      </td>
                    </tr>
                  </table>
                  <p style="margin:24px 0 0;color:#6B7280;font-size:12px;line-height:1.5">📎 <strong>Adjunto:</strong> archivo Excel con el detalle por servicio (piloto, comercio, valor, recaudos, balance Picash, estado real).</p>
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

    def normalizar(r)
      {
        "driver_id"            => r["driver_id"].to_s,
        "booking_id"           => r["booking_id"].to_s,
        "company_id"           => r["company_id"].to_s,
        "nombre_piloto"        => r["nombre_piloto"].to_s,
        "comercio"             => r["comercio"].to_s,
        "fecha_servicio"       => r["fecha_servicio"].to_s[0, 19],
        "pais"                 => r["pais"].to_s,
        "ciudad"               => r["ciudad"].to_s,
        "moneda"               => r["moneda"].to_s,
        "valor_servicio"       => r["valor_servicio"].to_f.round(2),
        "total_positivo"       => r["total_positivo"].to_f.round(2),
        "total_negativo"       => r["total_negativo"].to_f.round(2),
        "recaudo_neto"         => r["recaudo_neto"].to_f.round(2),
        "n_recaudos"           => r["n_recaudos"].to_i,
        "n_recaudos_positivos" => r["n_recaudos_positivos"].to_i,
        "n_recaudos_negativos" => r["n_recaudos_negativos"].to_i,
        "ida_y_vuelta"         => r["ida_y_vuelta"].to_s,
        "debe"                 => r["debe"].to_s,
        "tipo_deuda"           => r["tipo_deuda"].to_s,
      }
    end

    # Balance Picash por piloto: { driver_id => {actual: Float, fin_mes: Float} }
    # - actual: latest amount_after_transaction de cada wallet type_cd=0 SIN límite de fecha (saldo HOY).
    # - fin_mes: latest amount_after_transaction CON created_at <= hasta 23:59:59 (saldo al cierre del rango).
    # Si el piloto no tiene wallet Picash, no aparece en el hash.
    def cargar_balances_picash(driver_ids, hasta)
      return {} if driver_ids.empty?

      esc = ->(v) { v.to_s.gsub("'", "''") }
      ids_csv  = driver_ids.map { |id| "'#{esc.(id)}'" }.join(",")
      hasta_esc = esc.(hasta.to_s)

      sql = <<~SQL
        WITH
            picash_wallets AS (
                SELECT _id AS account_id, passenger_id AS driver_id
                FROM picapmongoprod.wallet_accounts
                WHERE type_cd = 0 AND passenger_id IN (#{ids_csv})
            ),
            latest_actual AS (
                SELECT account_id,
                       argMax(toFloat64OrNull(JSONExtractString(amount_after_transaction, 'cents'))/100, created_at) AS balance
                FROM picapmongoprod.wallet_account_transactions
                WHERE account_id IN (SELECT account_id FROM picash_wallets)
                  AND length(amount_after_transaction) > 2
                GROUP BY account_id
            ),
            latest_fin_mes AS (
                SELECT account_id,
                       argMax(toFloat64OrNull(JSONExtractString(amount_after_transaction, 'cents'))/100, created_at) AS balance
                FROM picapmongoprod.wallet_account_transactions
                WHERE account_id IN (SELECT account_id FROM picash_wallets)
                  AND length(amount_after_transaction) > 2
                  AND created_at <= toDateTime('#{hasta_esc} 23:59:59')
                GROUP BY account_id
            )
        SELECT
            pw.driver_id          AS driver_id,
            sum(la.balance)       AS balance_actual,
            sum(lf.balance)       AS balance_fin_mes
        FROM picash_wallets pw
        LEFT JOIN latest_actual la  ON la.account_id = pw.account_id
        LEFT JOIN latest_fin_mes lf ON lf.account_id = pw.account_id
        GROUP BY pw.driver_id
      SQL

      ch.query(sql, timeout: 120).each_with_object({}) do |r, h|
        h[r["driver_id"]] = {
          actual:  r["balance_actual"].nil?  ? nil : r["balance_actual"].to_f,
          fin_mes: r["balance_fin_mes"].nil? ? nil : r["balance_fin_mes"].to_f,
        }
      end
    rescue => e
      Rails.logger.warn("[RecaudosController#cargar_balances_picash] #{e.message}")
      {}
    end

    def calcular_estado_real(debe, balance)
      return debe if debe != "DEBE"
      # El booking dice DEBE, pero el piloto puede haber saldado por otro lado.
      # Si su balance Picash actual >= 0 → ya pagó → "NO DEBE (saldado)".
      return "DEBE" if balance.nil?      # sin info → asumir que sí debe
      balance >= 0 ? "NO DEBE (saldado)" : "DEBE"
    end

    # Nuevas categorías (v3) basadas en estado_real:
    # - Sin Novedad   = estado_real ∈ {AL DIA, NO DEBE (saldado), PAGADO DE MAS}
    #                   → bookings sin problema, incluso si tienen diferencia positiva
    # - Con Diferencia = estado_real ∈ {DEBE, SIN RECAUDO}
    #                   → bookings con problema real (piloto debe y no saldó)
    # Mantengo los campos viejos (debe, al_dia, etc.) por compat con el email/export.
    SIN_NOVEDAD_STATES   = ["AL DIA", "NO DEBE (saldado)", "PAGADO DE MAS"].freeze
    CON_DIFERENCIA_STATES = ["DEBE", "SIN RECAUDO"].freeze

    def calc_stats(rows)
      total          = rows.size
      n_debe         = rows.count { |r| r["debe"] == "DEBE" }
      n_demas        = rows.count { |r| r["debe"] == "PAGADO DE MAS" }
      n_al_dia       = rows.count { |r| r["debe"] == "AL DIA" }
      n_sin          = rows.count { |r| r["debe"] == "SIN RECAUDO" }
      # Estado real (considera balance picash del piloto)
      n_debe_real    = rows.count { |r| r["estado_real"] == "DEBE" }
      n_saldados     = rows.count { |r| r["estado_real"] == "NO DEBE (saldado)" }
      # v3: categorías Sin Novedad / Con Diferencia (basadas en estado_real)
      n_sin_novedad     = rows.count { |r| SIN_NOVEDAD_STATES.include?(r["estado_real"]) }
      n_con_diferencia  = rows.count { |r| CON_DIFERENCIA_STATES.include?(r["estado_real"]) }
      v_con_diferencia  = rows.select { |r| CON_DIFERENCIA_STATES.include?(r["estado_real"]) }
                              .sum { |r| r["recaudo_neto"].abs }

      v_deuda        = rows.select { |r| r["debe"] == "DEBE" }.sum { |r| r["recaudo_neto"].abs }
      v_deuda_real   = rows.select { |r| r["estado_real"] == "DEBE" }.sum { |r| r["recaudo_neto"].abs }
      v_demas        = rows.select { |r| r["debe"] == "PAGADO DE MAS" }.sum { |r| r["recaudo_neto"] }
      v_recaudado    = rows.sum { |r| r["total_positivo"] }
      v_servicios    = rows.sum { |r| r["valor_servicio"] }
      moneda_top     = rows.group_by { |r| r["moneda"] }.max_by { |_, v| v.size }&.first || ""

      {
        total:               total,
        moneda:              moneda_top,
        # v3: campos nuevos
        sin_novedad:         n_sin_novedad,
        con_diferencia:      n_con_diferencia,
        v_con_diferencia:    v_con_diferencia.round(2),
        pct_sin_novedad:     total > 0 ? (n_sin_novedad.to_f    / total * 100).round(1) : 0,
        pct_con_diferencia:  total > 0 ? (n_con_diferencia.to_f / total * 100).round(1) : 0,
        # Campos legacy (siguen usándose en email, export, debug)
        debe:          n_debe,
        debe_real:     n_debe_real,
        saldados:      n_saldados,
        pagado_demas:  n_demas,
        al_dia:        n_al_dia,
        sin_recaudo:   n_sin,
        v_deuda:       v_deuda.round(2),
        v_deuda_real:  v_deuda_real.round(2),
        v_demas:       v_demas.round(2),
        v_recaudado:   v_recaudado.round(2),
        v_servicios:   v_servicios.round(2),
        pct_debe:      total > 0 ? (n_debe.to_f       / total * 100).round(1) : 0,
        pct_debe_real: total > 0 ? (n_debe_real.to_f  / total * 100).round(1) : 0,
        pct_al_dia:    total > 0 ? (n_al_dia.to_f     / total * 100).round(1) : 0,
        pct_demas:     total > 0 ? (n_demas.to_f      / total * 100).round(1) : 0,
        pct_sin:       total > 0 ? (n_sin.to_f        / total * 100).round(1) : 0,
      }
    end
  end
end
