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
      balances   = cargar_balances_picash(driver_ids)
      rows.each do |r|
        bal = balances[r["driver_id"]]
        r["balance_picash"]     = bal
        r["balance_picash_str"] = bal.nil? ? "" : bal.round(2).to_s
        r["estado_real"]        = calcular_estado_real(r["debe"], bal)
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

    private

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

    # Fase 3: balance Picash actual por piloto.
    # Suma el latest amount_after_transaction de cada wallet type_cd=0 del piloto.
    # Si la suma >= 0 → piloto saldado (incluso si el booking dice DEBE).
    # Devuelve { driver_id => balance_total_Float }. Sin wallet picash → no aparece.
    def cargar_balances_picash(driver_ids)
      return {} if driver_ids.empty?

      esc = ->(v) { v.to_s.gsub("'", "''") }
      ids_csv = driver_ids.map { |id| "'#{esc.(id)}'" }.join(",")

      sql = <<~SQL
        WITH
            picash_wallets AS (
                SELECT _id AS account_id, passenger_id AS driver_id
                FROM picapmongoprod.wallet_accounts
                WHERE type_cd = 0
                  AND passenger_id IN (#{ids_csv})
            ),
            latest_balance AS (
                SELECT
                    account_id,
                    argMax(
                        toFloat64OrNull(JSONExtractString(amount_after_transaction, 'cents')) / 100,
                        created_at
                    ) AS balance
                FROM picapmongoprod.wallet_account_transactions
                WHERE account_id IN (SELECT account_id FROM picash_wallets)
                  AND length(amount_after_transaction) > 2
                GROUP BY account_id
            )
        SELECT
            pw.driver_id AS driver_id,
            sum(lb.balance) AS balance_total
        FROM picash_wallets pw
        LEFT JOIN latest_balance lb ON lb.account_id = pw.account_id
        GROUP BY pw.driver_id
      SQL

      ch.query(sql, timeout: 120).each_with_object({}) do |r, h|
        bal = r["balance_total"]
        h[r["driver_id"]] = bal.nil? ? nil : bal.to_f
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

    def calc_stats(rows)
      total          = rows.size
      n_debe         = rows.count { |r| r["debe"] == "DEBE" }
      n_demas        = rows.count { |r| r["debe"] == "PAGADO DE MAS" }
      n_al_dia       = rows.count { |r| r["debe"] == "AL DIA" }
      n_sin          = rows.count { |r| r["debe"] == "SIN RECAUDO" }
      # Estado real (considera balance picash del piloto)
      n_debe_real    = rows.count { |r| r["estado_real"] == "DEBE" }
      n_saldados     = rows.count { |r| r["estado_real"] == "NO DEBE (saldado)" }
      v_deuda        = rows.select { |r| r["debe"] == "DEBE" }.sum { |r| r["recaudo_neto"].abs }
      v_deuda_real   = rows.select { |r| r["estado_real"] == "DEBE" }.sum { |r| r["recaudo_neto"].abs }
      v_demas        = rows.select { |r| r["debe"] == "PAGADO DE MAS" }.sum { |r| r["recaudo_neto"] }
      v_recaudado    = rows.sum { |r| r["total_positivo"] }
      v_servicios    = rows.sum { |r| r["valor_servicio"] }
      moneda_top     = rows.group_by { |r| r["moneda"] }.max_by { |_, v| v.size }&.first || ""

      {
        total:         total,
        moneda:        moneda_top,
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
