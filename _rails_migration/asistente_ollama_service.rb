# app/services/asistente_ollama_service.rb
# v3.3.110 — Asistente Picap v2.0 (LLM con Ollama).
# Cliente HTTP a Ollama API con loop de tool calling.
#
# Envvars:
#   OLLAMA_URL              — base URL del Ollama (ej: http://host.docker.internal:11434)
#   OLLAMA_MODEL            — modelo a usar (ej: qwen2.5:3b)
#   ASISTENTE_LLM_ENABLED   — 'true' para habilitar (default 'false' en prod)

require 'net/http'
require 'json'

class AsistenteOllamaService
  FALLBACK_MSG = "Esa información no está disponible o al parecer no está en la selección de preguntas en el portal de monitoreo. Te recomiendo escribir al equipo de monitoreo (dperilla@pibox.app o verificaciones@pibox.app).".freeze

  SYSTEM_PROMPT = <<~PROMPT.freeze
    Eres el Asistente Picap, un agente que ayuda a directores y gerentes a consultar KPIs del portal de monitoreo Picap.

    Reglas estrictas:
    1. Solo respondes preguntas sobre los KPIs que están en las herramientas (tools) disponibles.
    2. Para cualquier pregunta que requiera datos, DEBES llamar a una tool. NO inventes números.
    3. Si la pregunta no puede ser respondida con las tools disponibles, responde EXACTAMENTE este mensaje:
       "Esa información no está disponible o al parecer no está en la selección de preguntas en el portal de monitoreo. Te recomiendo escribir al equipo de monitoreo (dperilla@pibox.app o verificaciones@pibox.app)."
    4. Cuando recibas datos de una tool, los presentas de forma clara y concisa (1-3 frases). Incluye números formateados con separadores de miles y moneda si aplica.
    5. Al final de la respuesta sugiere ver el detalle en el módulo correspondiente.
    6. Si el usuario pregunta sobre el mes/año sin especificar, asume el mes actual.
    7. País por defecto: Colombia (CO), salvo que el usuario diga otro.
    8. Responde SIEMPRE en español, tono ejecutivo y profesional.
  PROMPT

  def initialize(ch:)
    @ch         = ch
    @tools_svc  = AsistenteToolsService.new(ch)
    @url        = (ENV['OLLAMA_URL'] || 'http://host.docker.internal:11434').sub(%r{/$}, '')
    @model      = ENV['OLLAMA_MODEL'] || 'qwen2.5:3b'
    @timeout    = (ENV['OLLAMA_TIMEOUT'] || '60').to_i
  end

  def self.enabled?
    ENV['ASISTENTE_LLM_ENABLED'].to_s.downcase == 'true'
  end

  # Procesa el mensaje del usuario y devuelve la respuesta final del asistente.
  # Returns: { ok, respuesta, tool_usada, datos, modulo, error }
  def chat(mensaje, contexto: {})
    return { ok: false, error: 'Asistente LLM no habilitado (set ASISTENTE_LLM_ENABLED=true)' } unless self.class.enabled?

    messages = [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user',   content: contexto_user_prompt(mensaje, contexto) }
    ]

    # Loop max 3 turnos para no caer en bucle infinito de tool calls
    tool_ejecutada = nil
    datos_tool     = nil
    3.times do |turno|
      resp = ollama_chat(messages, with_tools: turno < 2)
      raise "Sin respuesta de Ollama" if resp.nil?

      msg = resp['message'] || {}
      tool_calls = msg['tool_calls']

      if tool_calls && tool_calls.any?
        tc = tool_calls.first
        tool_name = tc.dig('function', 'name')
        args      = tc.dig('function', 'arguments') || {}
        args      = JSON.parse(args) if args.is_a?(String)

        Rails.logger.info("[AsistenteOllama] Tool call: #{tool_name}(#{args.inspect})")
        result = @tools_svc.call(tool_name, args)
        tool_ejecutada = tool_name
        datos_tool     = result

        # Devolvemos el resultado al modelo para que lo redacte
        messages << { role: 'assistant', content: '', tool_calls: tool_calls }
        messages << { role: 'tool', content: JSON.generate(result), name: tool_name }
        next
      end

      # No tool call → respuesta final
      texto = msg['content'].to_s.strip
      texto = FALLBACK_MSG if texto.empty?
      return {
        ok:          true,
        respuesta:   texto,
        tool_usada:  tool_ejecutada,
        datos:       datos_tool && datos_tool[:datos],
        modulo:      datos_tool && datos_tool[:modulo],
      }
    end

    { ok: true, respuesta: FALLBACK_MSG, tool_usada: tool_ejecutada, datos: datos_tool && datos_tool[:datos], modulo: datos_tool && datos_tool[:modulo] }
  rescue => e
    Rails.logger.error("[AsistenteOllama] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    { ok: false, error: e.message }
  end

  private

  def contexto_user_prompt(mensaje, ctx)
    hoy = Date.today
    rol = ctx[:rol].presence || 'usuario'
    "[Contexto: hoy es #{hoy.strftime('%Y-%m-%d')}, rol del usuario: #{rol}]\n#{mensaje}"
  end

  def ollama_chat(messages, with_tools: true)
    uri = URI.parse("#{@url}/api/chat")
    body = {
      model:    @model,
      messages: messages,
      stream:   false,
      options:  { temperature: 0.2 },
    }
    if with_tools
      body[:tools] = AsistenteToolsService::TOOL_SCHEMAS.map do |t|
        {
          type: 'function',
          function: {
            name:        t[:name],
            description: t[:description],
            parameters:  AsistenteToolsService::TOOL_PARAMS[t[:name]],
          }
        }
      end
    end

    req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    req.body = JSON.generate(body)
    Net::HTTP.start(uri.hostname, uri.port, read_timeout: @timeout, open_timeout: 10) do |http|
      resp = http.request(req)
      raise "Ollama HTTP #{resp.code}: #{resp.body[0..200]}" unless resp.is_a?(Net::HTTPSuccess)
      JSON.parse(resp.body)
    end
  end
end
