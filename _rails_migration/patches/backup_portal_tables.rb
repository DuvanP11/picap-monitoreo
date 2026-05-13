#!/usr/bin/env ruby
# patches/backup_portal_tables.rb
#
# Exporta las 4 tablas propias del portal a JSON local:
#   - dashboard_users     (usuarios + password_hash, NO incluir en git!)
#   - dashboard_recursos  (biblioteca de queries/enlaces)
#   - cronograma_tareas   (tareas programadas)
#   - dashboard_audit_log (logs de auditoría)
#
# NO backup-ea bookings, passengers, ni demás tablas operacionales de Picap.
# Eso es responsabilidad del equipo de infra de Picap.
#
# Output: backup_portal_YYYYMMDD_HHMMSS.zip con 4 archivos JSON adentro.
#
# Uso desde la raíz del Rails project (necesita ENV CLICKHOUSE_*):
#   bundle exec ruby _rails_migration/patches/backup_portal_tables.rb
#
# O standalone con env vars manuales:
#   CLICKHOUSE_HOST=clickhouse.picap.io CLICKHOUSE_PORT=8443 \
#   CLICKHOUSE_USERNAME=dperilla CLICKHOUSE_PASSWORD=... \
#   CLICKHOUSE_DATABASE=picapmongoprod \
#   ruby _rails_migration/patches/backup_portal_tables.rb

require "net/http"
require "uri"
require "json"
require "openssl"
require "fileutils"

TABLES = %w[
  dashboard_users
  dashboard_recursos
  cronograma_tareas
  dashboard_audit_log
]

CONFIG = {
  host:     ENV.fetch("CLICKHOUSE_HOST"),
  port:     ENV.fetch("CLICKHOUSE_PORT", "8443").to_i,
  username: ENV.fetch("CLICKHOUSE_USERNAME"),
  password: ENV.fetch("CLICKHOUSE_PASSWORD"),
  database: ENV.fetch("CLICKHOUSE_DATABASE", "picapmongoprod"),
}

def ch_query(sql)
  uri = URI::HTTPS.build(
    host: CONFIG[:host],
    port: CONFIG[:port],
    path: "/",
    query: URI.encode_www_form(database: CONFIG[:database], default_format: "JSONCompact")
  )
  req = Net::HTTP::Post.new(uri)
  req.basic_auth(CONFIG[:username], CONFIG[:password])
  req["Content-Type"] = "text/plain; charset=utf-8"
  req.body = sql.strip
  resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                         verify_mode: OpenSSL::SSL::VERIFY_NONE) do |http|
    http.read_timeout = 300
    http.request(req)
  end
  raise "CH HTTP #{resp.code}: #{resp.body[0..200]}" unless resp.is_a?(Net::HTTPSuccess)
  return [] if resp.body.nil? || resp.body.strip.empty?
  parsed = JSON.parse(resp.body)
  cols = parsed["meta"].map { |m| m["name"] }
  parsed["data"].map { |row| cols.zip(row).to_h }
end

ts = Time.now.strftime("%Y%m%d_%H%M%S")
out_dir = "tmp/backup_portal_#{ts}"
FileUtils.mkdir_p(out_dir)

puts "═══════════════════════════════════════════════════════"
puts "  Backup tablas del portal — #{Time.now}"
puts "═══════════════════════════════════════════════════════"
puts

summary = {}

TABLES.each do |table|
  print "→ #{table.ljust(30)} ... "
  begin
    rows = ch_query("SELECT * FROM #{CONFIG[:database]}.#{table} FORMAT JSONCompact")
    # Re-export con FINAL para tablas ReplacingMergeTree (dedup última versión)
    rows = ch_query("SELECT * FROM #{CONFIG[:database]}.#{table} FINAL") rescue rows

    file = File.join(out_dir, "#{table}.json")
    File.write(file, JSON.pretty_generate(rows))
    size_kb = (File.size(file) / 1024.0).round(2)
    puts "#{rows.size} filas · #{size_kb} KB"
    summary[table] = { rows: rows.size, size_kb: size_kb, file: file }
  rescue => e
    puts "ERROR: #{e.message[0,120]}"
    summary[table] = { error: e.message }
  end
end

# Metadata
meta = {
  backup_timestamp: Time.now.iso8601,
  ch_host:          CONFIG[:host],
  ch_database:      CONFIG[:database],
  ch_user:          CONFIG[:username],
  summary:          summary,
  note: "Backup de tablas del portal Picap Monitoreo. NO incluye tablas operacionales " \
        "de Picap (bookings, passengers, wallet_account_transactions, etc.). " \
        "ATENCIÓN: dashboard_users contiene password_hash — NO subir este backup " \
        "a un git público ni compartir sin cifrar.",
}
File.write(File.join(out_dir, "_meta.json"), JSON.pretty_generate(meta))

puts
puts "═══════════════════════════════════════════════════════"
puts "  Resumen"
puts "═══════════════════════════════════════════════════════"
total_rows = summary.values.sum { |s| s[:rows] || 0 }
puts "Total filas:  #{total_rows}"
puts "Archivos en: #{out_dir}/"

# Comprimir
require "zlib"
require "rubygems/package"
tarball = "tmp/backup_portal_#{ts}.tar.gz"
File.open(tarball, "wb") do |io|
  Zlib::GzipWriter.wrap(io) do |gz|
    Gem::Package::TarWriter.new(gz) do |tar|
      Dir.glob(File.join(out_dir, "*")).each do |f|
        data = File.read(f)
        tar.add_file_simple(File.basename(f), 0o600, data.bytesize) { |w| w.write(data) }
      end
    end
  end
end
puts "Tarball:     #{tarball} (#{(File.size(tarball)/1024.0).round(2)} KB)"
puts
puts "⚠ dashboard_users.json contiene password_hash HMAC. Guárdalo en lugar privado."
puts "  Sugerido: Google Drive carpeta privada, NO en git."
