module Api
  class ResumenGeneralController < ApplicationController
    before_action :authenticate_user!
    def index
      render json: {
        ok: true,
        filtros: { desde: desde_param, hasta: hasta_param,
                   pais: pais_param, pais_iso: iso_pais },
        modulos: {},
        areas: {
          "monitoreo"   => { "nombre" => "Monitoreo",                "color" => "#1d4ed8", "icono" => "🔵" },
          "sac_recl"    => { "nombre" => "SAC / Reclamaciones",      "color" => "#7c3aed", "icono" => "🟣" },
          "comercial"   => { "nombre" => "Comercial",                "color" => "#16a34a", "icono" => "🟢" },
          "operaciones" => { "nombre" => "Operaciones",              "color" => "#ea580c", "icono" => "🟠" },
          "sac_act"     => { "nombre" => "SAC / Activaciones",       "color" => "#ca8a04", "icono" => "🟡" },
        },
        generado_en: Time.now.utc.strftime("%Y-%m-%d %H:%M:%S"),
        nota: "Resumen 360: pendiente de migrar (Bloque I)",
      }
    end
  end
end
