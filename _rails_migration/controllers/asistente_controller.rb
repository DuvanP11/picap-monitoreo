# v3.3.110 — Asistente Picap v2.0 (LLM endpoint)
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

      service = AsistenteOllamaService.new(ch: ch)
      ctx     = { rol: current_rol, vista: params[:vista].to_s }
      t0      = Time.now
      result  = service.chat(mensaje, contexto: ctx)
      Rails.logger.info("[Asistente] rol=#{current_rol} #{(Time.now - t0).round(1)}s tool=#{result[:tool_usada]} ok=#{result[:ok]}")
      render json: result
    end

    # GET /api/asistente/status — para feature flag del frontend
    def status
      render json: {
        ok:           true,
        llm_enabled:  AsistenteOllamaService.enabled?,
        model:        ENV['OLLAMA_MODEL'],
      }
    end
  end
end
