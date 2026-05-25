Rails.application.routes.draw do

  # ── Frontend ──
  root "pages#dashboard"
  get  "/dashboard.html", to: "pages#dashboard"

  # ── API ──
  namespace :api do

    # Status / health
    get  "status",          to: "status#index"
    get  "buscar",          to: "buscar#index"

    # Resumen principal (evasión de comisiones)
    get  "resumen",         to: "resumen#index"
    get  "recuperacion",    to: "recuperacion#index"
    get  "wallet",          to: "wallet#index"

    # Bloqueos
    get  "bloqueos",             to: "bloqueos#index"
    get  "estadisticas_bloqueos",to: "bloqueos#estadisticas"

    # Pagos
    namespace :pagos do
      get "tc",             to: "/api/pagos#tc"
      get "promo",          to: "/api/pagos#promo"
    end
    get  "pagos_stats",     to: "pagos#stats"

    # Estafa
    get  "estafa",          to: "estafa#index"

    # Recaudos
    get  "recaudos",                to: "recaudos#index"
    post "recaudos/enviar_email",   to: "recaudos#enviar_email"

    # MoviiRed (acceso restringido: admin/monitoreo/financiero)
    get  "moviired",                to: "moviired#index"
    post "moviired/enviar_email",   to: "moviired#enviar_email"

    # Auditoría Pibox
    namespace :auditoria do
      get    "comisiones",  to: "/api/auditoria#comisiones"
      get    "creditos",    to: "/api/auditoria#creditos"
      get    "exportar",    to: "/api/auditoria#exportar"
      post   "resolver",    to: "/api/auditoria#resolver"
      delete "resolver",    to: "/api/auditoria#desresolver"
    end

    # Reconocimiento facial
    get  "reconocimiento",  to: "reconocimiento#index"

    # Alertas de Cédula
    get  "cedula-alertas",          to: "cedula_alertas#index"
    get  "cedula-alertas/exportar", to: "cedula_alertas#exportar"

    # Pibox
    namespace :pibox do
      get  "servicios",     to: "/api/pibox#servicios"
      get  "alertas",       to: "/api/pibox#alertas"
      get  "export",        to: "/api/pibox#export"
    end

    # Exportaciones Excel
    namespace :exportar do
      get  "evasion",       to: "/api/exportar#evasion"
      get  "estafa",        to: "/api/exportar#estafa"
      get  "bloqueos",      to: "/api/exportar#bloqueos"
      get  "pagos",         to: "/api/exportar#pagos"
      get  "recaudos",      to: "/api/exportar#recaudos"
      get  "moviired",      to: "/api/exportar#moviired"
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
      get    "usuarios",        to: "/api/admin#usuarios"
      post   "editar_usuario",  to: "/api/admin#editar_usuario"
      post   "eliminar_usuario",to: "/api/admin#eliminar_usuario"
      post   "asignar_rol",     to: "/api/admin#asignar_rol"
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
    get    "resumen-general",           to: "resumen_general#index"
  end

  # ── Manejo de errores ──
  match "*path", to: "application#not_found", via: :all
end
