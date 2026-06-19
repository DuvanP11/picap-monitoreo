# app/services/asistente_tools_service.rb
# v3.3.110 — Asistente Picap v2.0 (LLM).
# Tools predefinidas que el LLM puede invocar. Cada método ejecuta UNA query
# CH preaprobada y devuelve un hash con datos agregados.
# El LLM NUNCA genera SQL libre; solo elige qué tool llamar y con qué parámetros.

class AsistenteToolsService
  PAIS_MAP = { 'CO' => 'Colombia', 'MX' => 'México', 'NI' => 'Nicaragua' }.freeze
  CURRENCY = { 'CO' => 'COP', 'MX' => 'MXN', 'NI' => 'NIO' }.freeze

  # JSON Schema de las herramientas disponibles para el LLM.
  # Pasamos esto a Ollama/Claude con cada call para que sepa qué puede pedir.
  TOOL_SCHEMAS = [
    { name: 'kpi_evasion_comision',
      description: 'Cuánto se cobró por evasión de comisión y cuántas transacciones hubo en un país y mes.' },
    { name: 'kpi_pilotos_evasores',
      description: 'Número de pilotos únicos que evadieron comisión en un país y mes.' },
    { name: 'kpi_bloqueos',
      description: 'Total de bloqueos en un país y mes, separados por tipo (definitivo/temporal/expulsion/suspension).' },
    { name: 'kpi_estafa',
      description: 'Número de casos de estafa detectados y monto en riesgo en un país y mes.' },
    { name: 'kpi_recaudos',
      description: 'Total recaudado en un país y mes (suma de Picash + Ida y Vuelta).' },
    { name: 'kpi_dispersiones',
      description: 'Monto dispersado por Daviplata CashOut en un mes (solo Colombia) y cuántos conductores beneficiados.' },
    { name: 'kpi_moviired',
      description: 'Transacciones MoviiRed y comisión generada en un mes (solo Colombia).' },
    { name: 'kpi_pibox_cv',
      description: 'Servicios Pibox para Cruz Verde en un mes (solo Colombia) e ingreso generado.' },
    { name: 'kpi_auditorias_pibox',
      description: 'Auditorías Pibox pendientes (comisiones y créditos).' },
    { name: 'kpi_resumen_360',
      description: 'Resumen ejecutivo de TODOS los módulos en un mes y país (Evasión + Bloqueos + Estafa + Recaudos).' },
  ].freeze

  TOOL_PARAMS = {
    'kpi_evasion_comision' => {
      type: 'object',
      properties: {
        pais: { type: 'string', enum: ['CO','MX','NI'], description: 'Código del país (CO/MX/NI)' },
        mes:  { type: 'integer', description: 'Mes 1-12' },
        anio: { type: 'integer', description: 'Año (ej: 2026)' },
      },
      required: %w[pais mes anio]
    },
    'kpi_pilotos_evasores' => {
      type: 'object',
      properties: {
        pais: { type: 'string', enum: ['CO','MX','NI'] },
        mes:  { type: 'integer' },
        anio: { type: 'integer' },
      },
      required: %w[pais mes anio]
    },
    'kpi_bloqueos' => {
      type: 'object',
      properties: {
        pais: { type: 'string', enum: ['CO','MX','NI'] },
        mes:  { type: 'integer' },
        anio: { type: 'integer' },
      },
      required: %w[pais mes anio]
    },
    'kpi_estafa' => {
      type: 'object',
      properties: {
        pais: { type: 'string', enum: ['CO','MX','NI'] },
        mes:  { type: 'integer' },
        anio: { type: 'integer' },
      },
      required: %w[pais mes anio]
    },
    'kpi_recaudos' => {
      type: 'object',
      properties: {
        mes:  { type: 'integer' },
        anio: { type: 'integer' },
      },
      required: %w[mes anio]
    },
    'kpi_dispersiones' => {
      type: 'object',
      properties: {
        mes:  { type: 'integer' },
        anio: { type: 'integer' },
      },
      required: %w[mes anio]
    },
    'kpi_moviired' => {
      type: 'object',
      properties: {
        mes:  { type: 'integer' },
        anio: { type: 'integer' },
      },
      required: %w[mes anio]
    },
    'kpi_pibox_cv' => {
      type: 'object',
      properties: {
        mes:  { type: 'integer' },
        anio: { type: 'integer' },
      },
      required: %w[mes anio]
    },
    'kpi_auditorias_pibox' => {
      type: 'object',
      properties: {},
      required: []
    },
    'kpi_resumen_360' => {
      type: 'object',
      properties: {
        pais: { type: 'string', enum: ['CO','MX','NI'] },
        mes:  { type: 'integer' },
        anio: { type: 'integer' },
      },
      required: %w[pais mes anio]
    },
  }.freeze

  MODULOS_SUGERIDOS = {
    'kpi_evasion_comision'   => { slug: 'monitoreo',     label: 'Monitoreo · Evasión de Comisión' },
    'kpi_pilotos_evasores'   => { slug: 'monitoreo',     label: 'Monitoreo · Evasión de Comisión' },
    'kpi_bloqueos'           => { slug: 'bloqueos',      label: 'Vista de Bloqueos' },
    'kpi_estafa'             => { slug: 'estafa',        label: 'Servicios Estafa' },
    'kpi_recaudos'           => { slug: 'recaudos',      label: 'Validación de Recaudos' },
    'kpi_dispersiones'       => { slug: 'dispersiones',  label: 'Dispersiones — Daviplata' },
    'kpi_moviired'           => { slug: 'moviired',      label: 'MoviiRed — Comisiones' },
    'kpi_pibox_cv'           => { slug: 'reporte_ops_cv',label: 'Reporte OPS CV — Cruz Verde' },
    'kpi_auditorias_pibox'   => { slug: 'auditoria',     label: 'Auditorías Pibox' },
    'kpi_resumen_360'        => { slug: 'resumen',       label: 'Resumen 360' },
  }.freeze

  def initialize(ch)
    @ch = ch
  end

  # Ejecuta un tool por nombre. Devuelve { ok, datos, modulo, error }
  def call(tool_name, params = {})
    method_name = tool_name.to_s
    raise "Tool desconocido: #{tool_name}" unless MODULOS_SUGERIDOS.key?(method_name)
    datos = send(method_name, **params.to_h.symbolize_keys.slice(:pais, :mes, :anio))
    { ok: true, datos: datos, modulo: MODULOS_SUGERIDOS[method_name] }
  rescue => e
    Rails.logger.error("[AsistenteTools] #{tool_name}: #{e.class}: #{e.message}")
    { ok: false, error: e.message, modulo: MODULOS_SUGERIDOS[method_name] }
  end

  private

  def rango_fechas(mes, anio)
    m = mes.to_i.clamp(1, 12)
    y = anio.to_i
    desde = Date.new(y, m, 1).strftime('%Y-%m-%d 00:00:00')
    hasta = (Date.new(y, m, 1).next_month - 1).strftime('%Y-%m-%d 23:59:59')
    [desde, hasta]
  end

  def pais_filter(pais, col = 'pais')
    case pais.to_s.upcase
    when 'CO' then "AND upper(#{col}) = 'CO'"
    when 'MX' then "AND upper(#{col}) = 'MX'"
    when 'NI' then "AND upper(#{col}) = 'NI'"
    else ''
    end
  end

  # ───────────────────────── KPIs ─────────────────────────

  def kpi_evasion_comision(pais:, mes:, anio:, **_)
    desde, hasta = rango_fechas(mes, anio)
    sql = <<~SQL
      SELECT
        ifNull(sum(toFloat64OrZero(JSONExtractString(final_cost,'cents'))/100.0),0) AS total_cobrado,
        count() AS transacciones,
        uniqExact(toString(driver_id)) AS pilotos_unicos
      FROM picapmongoprod.bookings
      WHERE status_cd = 4
        AND created_at >= toDateTime('#{desde}','America/Bogota')
        AND created_at <= toDateTime('#{hasta}','America/Bogota')
        #{pais_filter(pais, 'g_country')}
        AND JSONExtractString(final_cost,'currency_iso') = '#{CURRENCY[pais.to_s.upcase] || 'COP'}'
    SQL
    row = @ch.query(sql, timeout: 60).first || {}
    {
      pais:          PAIS_MAP[pais.to_s.upcase],
      periodo:       "#{Date::MONTHNAMES[mes.to_i].downcase} #{anio}",
      total_cobrado: row['total_cobrado'].to_f.round(0),
      transacciones: row['transacciones'].to_i,
      pilotos_unicos:row['pilotos_unicos'].to_i,
      moneda:        CURRENCY[pais.to_s.upcase] || 'COP'
    }
  end

  def kpi_pilotos_evasores(pais:, mes:, anio:, **_)
    desde, hasta = rango_fechas(mes, anio)
    sql = <<~SQL
      SELECT
        uniqExact(toString(driver_id)) AS pilotos_unicos,
        count() AS servicios_evadidos
      FROM picapmongoprod.bookings
      WHERE status_cd = 4
        AND created_at >= toDateTime('#{desde}','America/Bogota')
        AND created_at <= toDateTime('#{hasta}','America/Bogota')
        AND notEmpty(toString(reasons_to_verify))
        #{pais_filter(pais, 'g_country')}
    SQL
    row = @ch.query(sql, timeout: 60).first || {}
    {
      pais:               PAIS_MAP[pais.to_s.upcase],
      periodo:            "#{Date::MONTHNAMES[mes.to_i].downcase} #{anio}",
      pilotos_evasores:   row['pilotos_unicos'].to_i,
      servicios_evadidos: row['servicios_evadidos'].to_i,
    }
  end

  def kpi_bloqueos(pais:, mes:, anio:, **_)
    desde, hasta = rango_fechas(mes, anio)
    sql = <<~SQL
      SELECT
        count() AS total,
        countIf(account_status_cd = 4) AS definitivos,
        countIf(account_status_cd = 3) AS temporales,
        countIf(account_status_cd = 5) AS expulsados
      FROM picapmongoprod.passengers
      WHERE updated_at >= toDateTime('#{desde}','America/Bogota')
        AND updated_at <= toDateTime('#{hasta}','America/Bogota')
        AND account_status_cd IN (3,4,5)
        #{pais_filter(pais, 'g_country')}
    SQL
    row = @ch.query(sql, timeout: 60).first || {}
    {
      pais:        PAIS_MAP[pais.to_s.upcase],
      periodo:     "#{Date::MONTHNAMES[mes.to_i].downcase} #{anio}",
      total:       row['total'].to_i,
      definitivos: row['definitivos'].to_i,
      temporales:  row['temporales'].to_i,
      expulsados:  row['expulsados'].to_i,
    }
  end

  def kpi_estafa(pais:, mes:, anio:, **_)
    desde, hasta = rango_fechas(mes, anio)
    sql = <<~SQL
      SELECT
        count() AS casos,
        ifNull(sum(toFloat64OrZero(JSONExtractString(final_cost,'cents'))/100.0),0) AS monto_riesgo
      FROM picapmongoprod.bookings
      WHERE created_at >= toDateTime('#{desde}','America/Bogota')
        AND created_at <= toDateTime('#{hasta}','America/Bogota')
        AND length(JSONExtractArrayRaw(reasons_to_verify)) > 0
        #{pais_filter(pais, 'g_country')}
    SQL
    row = @ch.query(sql, timeout: 60).first || {}
    {
      pais:         PAIS_MAP[pais.to_s.upcase],
      periodo:      "#{Date::MONTHNAMES[mes.to_i].downcase} #{anio}",
      casos:        row['casos'].to_i,
      monto_riesgo: row['monto_riesgo'].to_f.round(0),
      moneda:       CURRENCY[pais.to_s.upcase] || 'COP',
    }
  end

  def kpi_recaudos(mes:, anio:, **_)
    desde, hasta = rango_fechas(mes, anio)
    sql = <<~SQL
      SELECT
        ifNull(sum(toFloat64OrZero(JSONExtractString(amount,'cents'))/100.0),0) AS total,
        count() AS transacciones
      FROM picapmongoprod.wallet_account_transactions
      WHERE created_at >= toDateTime('#{desde}','America/Bogota')
        AND created_at <= toDateTime('#{hasta}','America/Bogota')
        AND lower(_type) LIKE '%recaudo%'
    SQL
    row = @ch.query(sql, timeout: 60).first || {}
    {
      periodo:       "#{Date::MONTHNAMES[mes.to_i].downcase} #{anio}",
      total_recaudado: row['total'].to_f.round(0),
      transacciones: row['transacciones'].to_i,
      moneda:        'COP',
    }
  end

  def kpi_dispersiones(mes:, anio:, **_)
    desde, hasta = rango_fechas(mes, anio)
    sql = <<~SQL
      SELECT
        ifNull(sum(toFloat64OrZero(JSONExtractString(amount,'cents'))/100.0),0) AS total,
        uniqExact(account_id) AS conductores
      FROM picapmongoprod.wallet_account_transactions
      WHERE created_at >= toDateTime('#{desde}','America/Bogota')
        AND created_at <= toDateTime('#{hasta}','America/Bogota')
        AND lower(_type) LIKE '%dispers%'
    SQL
    row = @ch.query(sql, timeout: 60).first || {}
    {
      periodo:         "#{Date::MONTHNAMES[mes.to_i].downcase} #{anio}",
      total_dispersado:row['total'].to_f.round(0),
      conductores:     row['conductores'].to_i,
      moneda:          'COP',
    }
  end

  def kpi_moviired(mes:, anio:, **_)
    desde, hasta = rango_fechas(mes, anio)
    sql = <<~SQL
      SELECT
        count() AS transacciones,
        ifNull(sum(toFloat64OrZero(JSONExtractString(amount,'cents'))/100.0),0) AS comision_total
      FROM picapmongoprod.wallet_account_transactions
      WHERE created_at >= toDateTime('#{desde}','America/Bogota')
        AND created_at <= toDateTime('#{hasta}','America/Bogota')
        AND lower(_type) LIKE '%moviired%'
    SQL
    row = @ch.query(sql, timeout: 60).first || {}
    {
      periodo:        "#{Date::MONTHNAMES[mes.to_i].downcase} #{anio}",
      transacciones:  row['transacciones'].to_i,
      comision_total: row['comision_total'].to_f.round(0),
      moneda:         'COP',
    }
  end

  def kpi_pibox_cv(mes:, anio:, **_)
    desde, hasta = rango_fechas(mes, anio)
    sql = <<~SQL
      SELECT
        count() AS servicios,
        ifNull(sum(toFloat64OrZero(JSONExtractString(final_cost,'cents'))/100.0),0) AS ingreso
      FROM picapmongoprod.bookings
      WHERE status_cd = 4
        AND created_at >= toDateTime('#{desde}','America/Bogota')
        AND created_at <= toDateTime('#{hasta}','America/Bogota')
        AND positionCaseInsensitive(ifNull(toString(company_id),''), 'cruzverde') > 0
    SQL
    row = @ch.query(sql, timeout: 60).first || {}
    {
      periodo:   "#{Date::MONTHNAMES[mes.to_i].downcase} #{anio}",
      servicios: row['servicios'].to_i,
      ingreso:   row['ingreso'].to_f.round(0),
      moneda:    'COP',
    }
  end

  def kpi_auditorias_pibox(**_)
    sql = <<~SQL
      SELECT count() AS pendientes
      FROM picapmongoprod.bookings
      WHERE status_cd = 4
        AND created_at >= now() - INTERVAL 30 DAY
        AND notEmpty(toString(company_id))
    SQL
    row = @ch.query(sql, timeout: 60).first || {}
    { pendientes_estimadas: row['pendientes'].to_i, ventana: 'últimos 30 días' }
  end

  def kpi_resumen_360(pais:, mes:, anio:, **_)
    evasion = kpi_evasion_comision(pais: pais, mes: mes, anio: anio)
    bloqueos = kpi_bloqueos(pais: pais, mes: mes, anio: anio)
    estafa = kpi_estafa(pais: pais, mes: mes, anio: anio)
    {
      pais:    PAIS_MAP[pais.to_s.upcase],
      periodo: "#{Date::MONTHNAMES[mes.to_i].downcase} #{anio}",
      evasion: { total_cobrado: evasion[:total_cobrado], transacciones: evasion[:transacciones], pilotos: evasion[:pilotos_unicos] },
      bloqueos: { total: bloqueos[:total], definitivos: bloqueos[:definitivos], temporales: bloqueos[:temporales] },
      estafa:  { casos: estafa[:casos], monto_riesgo: estafa[:monto_riesgo] },
      moneda:  CURRENCY[pais.to_s.upcase] || 'COP',
    }
  end
end
