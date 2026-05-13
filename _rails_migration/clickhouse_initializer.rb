# config/initializers/clickhouse.rb
# Conexión directa a ClickHouse vía HTTP (compatible con clickhouse.picap.io).
#
# CHANGELOG Bloque F:
# - read_timeout subió de 120s → 300s (Pibox B2B con FINAL en 6 tablas tarda).
# - Acepta timeout: opcional por query (e.g. Pibox usa 600s, normales 300s).

require "net/http"
require "uri"
require "json"

module ClickhouseClient
  CONFIG = {
    host:     ENV.fetch("CLICKHOUSE_HOST",     "clickhouse.picap.io"),
    port:     ENV.fetch("CLICKHOUSE_PORT",     "8443").to_i,
    username: ENV.fetch("CLICKHOUSE_USERNAME", "dperilla"),
    password: ENV.fetch("CLICKHOUSE_PASSWORD", ""),
    database: ENV.fetch("CLICKHOUSE_DATABASE", "picapmongoprod"),
    secure:   ENV.fetch("CLICKHOUSE_SECURE",   "true") == "true",
  }.freeze

  DEFAULT_READ_TIMEOUT = ENV.fetch("CLICKHOUSE_READ_TIMEOUT", "300").to_i

  # Ejecuta una query y retorna array de hashes [{col: val}, ...]
  # @param sql [String] SQL a ejecutar
  # @param timeout [Integer] read_timeout en segundos (default 300)
  def self.query(sql, timeout: DEFAULT_READ_TIMEOUT)
    uri = URI::HTTPS.build(
      host: CONFIG[:host],
      port: CONFIG[:port],
      path: "/",
      query: URI.encode_www_form(
        database: CONFIG[:database],
        default_format: "JSONCompact",
      )
    )

    req = Net::HTTP::Post.new(uri)
    req.basic_auth(CONFIG[:username], CONFIG[:password])
    req["Content-Type"] = "text/plain; charset=utf-8"
    req.body = sql.strip

    use_ssl = CONFIG[:secure]
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: use_ssl,
                           verify_mode: OpenSSL::SSL::VERIFY_NONE) do |http|
      http.read_timeout = timeout
      http.open_timeout = 30
      http.request(req)
    end

    raise "ClickHouse HTTP #{resp.code}: #{resp.body[0..200]}" unless resp.is_a?(Net::HTTPSuccess)

    # INSERT/ALTER/DELETE devuelven body vacío en CH; SELECT siempre devuelve
    # al menos {"meta":[],"data":[]}. Empty body = mutación exitosa, no hay
    # filas que procesar. Sin este guard, JSON.parse("") truena con
    # "unexpected end of input at line 1 column 1" y rompe todos los POSTs.
    return [] if resp.body.nil? || resp.body.strip.empty?

    parsed = JSON.parse(resp.body)
    cols   = parsed["meta"].map { |m| m["name"] }
    parsed["data"].map { |row| cols.zip(row).to_h }
  rescue => e
    Rails.logger.error("[ClickHouse] #{e.message}")
    raise
  end

  # Convierte NaN/Infinity a nil para serialización JSON segura
  def self.limpiar(obj)
    case obj
    when Hash  then obj.transform_values { |v| limpiar(v) }
    when Array then obj.map { |v| limpiar(v) }
    when Float then (obj.nan? || obj.infinite?) ? nil : obj
    else obj
    end
  end
end
