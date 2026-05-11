# Bloque a INSERTAR dentro de `namespace :api do ... end` en config/routes.rb
# Agrega rutas de features recientes que el frontend usa.

      # ── RECURSOS ──────────────────────────────────────────────────
      get    "recursos",                  to: "recursos#index"
      post   "recursos",                  to: "recursos#create"
      put    "recursos/:id",              to: "recursos#update"
      delete "recursos/:id",              to: "recursos#destroy"
      get    "recursos/usuarios-portal",  to: "recursos#usuarios_portal"
      post   "recursos/share-bulk",       to: "recursos#share_bulk"
      post   "recursos/:id/share",        to: "recursos#share"

      # ── CRONOGRAMA ───────────────────────────────────────────────
      get    "cronograma",                       to: "cronograma#index"
      post   "cronograma",                       to: "cronograma#create"
      put    "cronograma/:id",                   to: "cronograma#update"
      delete "cronograma/:id",                   to: "cronograma#destroy"
      post   "cronograma/:id/marcar-hecho",      to: "cronograma#marcar_hecho"
      post   "cronograma/:id/test",              to: "cronograma#test"

      # ── AUDIT (logs de seguridad) ───────────────────────────────
      post   "audit/log",                 to: "audit#log"
      get    "audit/logs",                to: "audit#logs"
      get    "audit/export",              to: "audit#export"

      # ── RESUMEN GENERAL (Vista 360) ─────────────────────────────
      get    "resumen-general",           to: "resumen_general#index"
