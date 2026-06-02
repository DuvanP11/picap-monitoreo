Rails.application.routes.draw do

  # ── Health check (k8s liveness/readiness/startup) ──
  # ⚠️ NO BORRAR: los probes de k8s (helm web.yaml) pegan a GET /up.
  # Sin esta ruta, el catch-all `match "*path"` responde 404 → CrashLoopBackOff
  # → rollout ProgressDeadlineExceeded → ArgoCD Degraded. (Regresión rc8 / commit 591924d)
  get "up" => "rails/health#show", as: :rails_health_check

  # ── Frontend ──
  root "pages#dashboard"
  get  "/dashboard.html", to: "pages#dashboard"

  # ── API ──
  namespace :api do

    # Status / health
    get  "status",          to: "status#index"
    get  "buscar",          to: "buscar#index"

    # Resumen principal (evasión de comisiones)
    get  "resumen",                to: "resumen#index"
    post "resumen/enviar_email",   to: "resumen#enviar_email"
    get  "recuperacion",           to: "recuperacion#index"
    get  "wallet",                 to: "wallet#index"

    # Bloqueos
    get  "bloqueos",             to: "bloqueos#index"
    get  "estadisticas_bloqueos",to: "bloqueos#estadisticas"
    post "bloqueos/enviar_email",to: "bloqueos#enviar_email"

    # Pagos
    namespace :pagos do
      get "tc",             to: "/api/pagos#tc"
      get "promo",          to: "/api/pagos#promo"
    end
    get  "pagos_stats",          to: "pagos#stats"
    post "pagos/enviar_email",   to: "pagos#enviar_email"

    # Estafa
    get  "estafa",                to: "estafa#index"
    post "estafa/enviar_email",   to: "estafa#enviar_email"

    # Recaudos
    get  "recaudos",                to: "recaudos#index"
    post "recaudos/enviar_email",   to: "recaudos#enviar_email"

    # MoviiRed (acceso restringido: admin/monitoreo/financiero)
    get  "moviired",                to: "moviired#index"
    post "moviired/enviar_email",   to: "moviired#enviar_email"

    # Dispersiones (acceso restringido: admin/monitoreo/financiero)
    get  "dispersiones",                 to: "dispersiones#index"
    post "dispersiones/enviar_email",    to: "dispersiones#enviar_email"

    # Reporte OPS CV — bookings Pibox Cruz Verde (acceso restringido)
    get  "reporte_ops_cv",                to: "reporte_ops_cv#index"
    post "reporte_ops_cv/enviar_email",   to: "reporte_ops_cv#enviar_email"

    # v3.3.23: Bonos de Ayuda Voluntaria (acceso restringido)
    get  "bonos_ayuda",                   to: "bonos_ayuda_voluntaria#index"
    post "bonos_ayuda/enviar_email",      to: "bonos_ayuda_voluntaria#enviar_email"

    # v3.3.24: MINTIC — reporte trimestral B2B (acceso restringido)
    namespace :mintic do
      get  "detallado_query",        to: "/api/mintic#detallado_query"
      get  "detallado_facturas",     to: "/api/mintic#detallado_facturas"
      get  "informe_general",        to: "/api/mintic#informe_general"
      get  "job_status/:job_id",     to: "/api/mintic#job_status"
    end
    post "mintic/upload_facturas",   to: "mintic#upload_facturas"
    post "mintic/enviar_email",      to: "mintic#enviar_email"

    # Auditoría Pibox
    namespace :auditoria do
      get    "comisiones",  to: "/api/auditoria#comisiones"
      get    "creditos",    to: "/api/auditoria#creditos"
      get    "exportar",    to: "/api/auditoria#exportar"
      post   "resolver",    to: "/api/auditoria#resolver"
      delete "resolver",    to: "/api/auditoria#desresolver"
    end
    post "auditoria/enviar_email", to: "auditoria#enviar_email"

    # Reconocimiento facial
    get  "reconocimiento",                to: "reconocimiento#index"
    post "reconocimiento/enviar_email",   to: "reconocimiento#enviar_email"

    # Alertas de Cédula
    get  "cedula-alertas",              to: "cedula_alertas#index"
    get  "cedula-alertas/exportar",     to: "cedula_alertas#exportar"
    post "cedula-alertas/enviar_email", to: "cedula_alertas#enviar_email"

    # Pibox
    namespace :pibox do
      get  "servicios",     to: "/api/pibox#servicios"
      get  "alertas",       to: "/api/pibox#alertas"
      get  "export",        to: "/api/pibox#export"
    end
    post "pibox/enviar_email", to: "pibox#enviar_email"

    # Exportaciones Excel
    namespace :exportar do
      get  "evasion",       to: "/api/exportar#evasion"
      get  "estafa",        to: "/api/exportar#estafa"
      get  "bloqueos",      to: "/api/exportar#bloqueos"
      get  "pagos",         to: "/api/exportar#pagos"
      get  "recaudos",      to: "/api/exportar#recaudos"
      get  "moviired",      to: "/api/exportar#moviired"
      get  "dispersiones",  to: "/api/exportar#dispersiones"
      get  "reporte_ops_cv",to: "/api/exportar#reporte_ops_cv"
      get  "bonos_ayuda",   to: "/api/exportar#bonos_ayuda"
    end

    # Autenticación
    post "login",           to: "auth#login"
    post "logout",          to: "auth#logout"
    get  "me",              to: "auth#me"
    post "register",        to: "auth#register"
    post "cambiar_password",to: "auth#cambiar_password"
    post "solicitar_reset", to: "auth#solicitar_reset"
    post "reset_password",  to: "auth#reset_password"

    # Admin
    namespace :admin do
      get    "usuarios",                 to: "/api/admin#usuarios"
      get    "usuario/:usuario/perfil",  to: "/api/admin#usuario_perfil"
      post   "editar_usuario",           to: "/api/admin#editar_usuario"
      post   "eliminar_usuario",         to: "/api/admin#eliminar_usuario"
      post   "asignar_rol",              to: "/api/admin#asignar_rol"
    end

    # Calendario (GET para listar, POST para notificar)
    get  "calendario",            to: "calendario#index"
    namespace :calendario do
      post "notificar",     to: "/api/calendario#notificar"
    end

    # Consola interna
    post "console",         to: "console#run"

    # ── Features recientes (cronograma, recursos, audit logs, resumen 360) ──
    # Recursos compartidos
    get    "recursos",                  to: "recursos#index"
    post   "recursos",                  to: "recursos#create"
    put    "recursos/:id",              to: "recursos#update"
    delete "recursos/:id",              to: "recursos#destroy"
    get    "recursos/visibilidad",      to: "recursos#visibilidad"
    get    "recursos/usuarios-portal",  to: "recursos#usuarios_portal"
    post   "recursos/share-bulk",       to: "recursos#share_bulk"
    post   "recursos/:id/share",        to: "recursos#share"

    # Cronograma de tareas recurrentes
    get    "cronograma",                       to: "cronograma#index"
    post   "cronograma",                       to: "cronograma#create"
    put    "cronograma/:id",                   to: "cronograma#update"
    delete "cronograma/:id",                   to: "cronograma#destroy"
    post   "cronograma/:id/marcar-hecho",      to: "cronograma#marcar_hecho"
    post   "cronograma/:id/test",              to: "cronograma#test"

    # Logs de seguridad / auditoría
    post   "audit/log",                 to: "audit#log"
    get    "audit/logs",                to: "audit#logs"
    get    "audit/export",              to: "audit#export"

    # Resumen General (Vista 360)
    get    "resumen-general",                to: "resumen_general#index"
    post   "resumen-general/enviar_email",   to: "resumen_general#enviar_email"
  end

  # ── Manejo de errores ──
  match "*path", to: "application#not_found", via: :all
end
