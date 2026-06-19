# app/services/asistente_claude_service.rb
# v3.3.111 — Asistente Picap v2.0 con Claude Haiku 4.5 (Anthropic API).
# Misma interfaz que AsistenteOllamaService: .chat(mensaje, contexto:)
#
# Envvars:
#   ANTHROPIC_API_KEY        — API key de Anthropic (requerido)
#   CLAUDE_MODEL             — modelo (default: claude-haiku-4-5-20251001)
#   ASISTENTE_LLM_ENABLED    — 'true' para habilitar (default 'false')

require 'net/http'
require 'json'

class AsistenteClaudeService
  API_URL          = 'https://api.anthropic.com/v1/messages'.freeze
  API_VERSION      = '2023-06-01'.freeze
  DEFAULT_MODEL    = 'claude-haiku-4-5-20251001'.freeze
  MAX_TOOL_TURNS   = 4

  FALLBACK_MSG = AsistenteOllamaService::FALLBACK_MSG
  SYSTEM_PROMPT = AsistenteOllamaService::SYSTEM_PROMPT

  def self.enabled?
    return false unless ENV['ASISTENTE_LLM_ENABLED'].to_s.downcase == 'true'
    !ENV['ANTHROPIC_API_KEY'].to_s.strip.empty?
  end

  def initialize(ch:)
    @ch        = ch
    @tools_svc = AsistenteToolsService.new(ch)
    @api_key   = ENV['ANTHROPIC_API_KEY']
    @model     = ENV['CLAUDE_MODEL'].presence || DEFAULT_MODEL
    @timeout   = (ENV['CLAUDE_TIMEOUT'] || '60').to_i
    raise 'ANTHROPIC_API_KEY no configurada' if @api_key.to_s.strip.empty?
  end

  # Returns: { ok, respuesta, tool_usada, datos, modulo, error }
  def chat(mensaje, contexto: {})
    messages = [{
      role: 'user',
      content: contexto_user_prompt(mensaje, contexto)
    }]

    tool_ejecutada = nil
    datos_tool     = nil

    MAX_TOOL_TURNS.times do |turno|
      resp = claude_call(messages, system: SYSTEM_PROMPT, with_tools: turno < (MAX_TOOL_TURNS - 1))
      raise 'Respuesta vacía de Claude' if resp.nil?

      content = resp['content'] || []
      tool_use = content.find { |c| c['type'] == 'tool_use' }
      text     = content.find { |c| c['type'] == 'text' }

      if tool_use
        tool_name = tool_use['name']
        args      = tool_use['input'] || {}
        Rails.logger.info("[AsistenteClaude] Tool: #{tool_name}(#{args.inspect})")
        result = @tools_svc.call(tool_name, args)
        tool_ejecutada = tool_name
        datos_tool     = result

        messages << { role: 'assistant', content: content }
        messages << {
          role: 'user',
          content: [{
            type: 'tool_result',
            tool_use_id: tool_use['id'],
            content: JSON.generate(result)
          }]
        }
        next
      end

      texto = (text && text['text']).to_s.strip
      texto = FALLBACK_MSG if texto.empty?
      return {
        ok: true,
        respuesta: texto,
        tool_usada: tool_ejecutada,
        datos: datos_tool && datos_tool[:datos],
        modulo: datos_tool && datos_tool[:modulo],
        provider: 'claude'
      }
    end

    { ok: true, respuesta: FALLBACK_MSG, tool_usada: tool_ejecutada,
      datos: datos_tool && datos_tool[:datos], modulo: datos_tool && datos_tool[:modulo],
      provider: 'claude' }
  rescue => e
    Rails.logger.error("[AsistenteClaude] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    { ok: false, error: e.message, provider: 'claude' }
  end

  private

  def contexto_user_prompt(mensaje, ctx)
    hoy = Date.today
    rol = ctx[:rol].presence || 'usuario'
    "[Contexto: hoy es #{hoy.strftime('%Y-%m-%d')}, rol del usuario: #{rol}]\n#{mensaje}"
  end

  def claude_call(messages, system:, with_tools: true)
    uri = URI.parse(API_URL)
    body = {
      model:      @model,
      max_tokens: 1024,
      system:     system,
      messages:   messages,
    }
    if with_tools
      body[:tools] = AsistenteToolsService::TOOL_SCHEMAS.map do |t|
        {
          name:         t[:name],
          description:  t[:description],
          input_schema: AsistenteToolsService::TOOL_PARAMS[t[:name]],
        }
      end
    end

    req = Net::HTTP::Post.new(uri)
    req['x-api-key']         = @api_key
    req['anthropic-version'] = API_VERSION
    req['content-type']      = 'application/json'
    req.body = JSON.generate(body)

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                    read_timeout: @timeout, open_timeout: 10) do |http|
      resp = http.request(req)
      raise "Claude HTTP #{resp.code}: #{resp.body[0..300]}" unless resp.is_a?(Net::HTTPSuccess)
      JSON.parse(resp.body)
    end
  end
end
