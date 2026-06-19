# v3.3.111 — Asistente Picap v2.0 (LLM endpoint, Claude o Ollama)
# Prioridad: si hay ANTHROPIC_API_KEY usa Claude Haiku; sino Ollama; sino error.
# POST /api/asistente/chat { mensaje, vista, rol }
# GET  /api/asistente/status
module Api
  class AsistenteController < ApplicationController
    before_action :authenticate_user!

    # POST /api/asistente/chat
    def chat
      mensaje = params[:mensaje].to_s.strip
      return render(json: { ok: false, error: 'mensaje vacío' }, status: :bad_request) if mensaje.empty?
      return render(json: { ok: false, error: 'mensaje demasiado largo (máx 500 chars)' }, status: :bad_request) if mensaje.length > 500

      service = _asistente_service
      return render(json: { ok: false, error: 'No LLM provider habilitado' }, status: :service_unavailable) unless service

      ctx    = { rol: current_rol, vista: params[:vista].to_s }
      t0     = Time.now
      result = service.chat(mensaje, contexto: ctx)
      Rails.logger.info("[Asistente] provider=#{result[:provider]} rol=#{current_rol} #{(Time.now - t0).round(1)}s tool=#{result[:tool_usada]} ok=#{result[:ok]}")
      render json: result
    end

    # GET /api/asistente/status — para feature flag del frontend
    def status
      claude = AsistenteClaudeService.enabled? rescue false
      ollama = AsistenteOllamaService.enabled?
      provider = claude ? 'claude' : (ollama ? 'ollama' : nil)
      render json: {
        ok:          true,
        llm_enabled: claude || ollama,
        provider:    provider,
        model:       claude ? (ENV['CLAUDE_MODEL'] || 'claude-haiku-4-5-20251001')
                            : (ollama ? ENV['OLLAMA_MODEL'] : nil),
      }
    end

    private

    def _asistente_service
      return AsistenteClaudeService.new(ch: ch) if defined?(AsistenteClaudeService) && AsistenteClaudeService.enabled?
      return AsistenteOllamaService.new(ch: ch) if AsistenteOllamaService.enabled?
      nil
    end
  end
end
