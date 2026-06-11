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
    # v3.3.36: download async (soluciona 502 cuando hay > 5k servicios)
    get  "reporte_ops_cv/exportar_async",        to: "reporte_ops_cv#exportar_async"
    get  "reporte_ops_cv/export_status/:job_id", to: "reporte_ops_cv#export_status"
    # v3.3.43: load async (soluciona "Failed to fetch" / 502 cuando query CH > 60s)
    get  "reporte_ops_cv/cargar_async",          to: "reporte_ops_cv#cargar_async"
    get  "reporte_ops_cv/cargar_status/:job_id", to: "reporte_ops_cv#cargar_status"
    # v3.3.44: email status polling (soluciona silent failure en enviar_email)
    get  "reporte_ops_cv/enviar_email_status/:job_id", to: "reporte_ops_cv#enviar_email_status"

    # v3.3.23: Bonos de Ayuda Voluntaria (acceso restringido)
    get  "bonos_ayuda",                   to: "bonos_ayuda_voluntaria#index"
    post "bonos_ayuda/enviar_email",      to: "bonos_ayuda_voluntaria#enviar_email"

    # v3.3.28: Saldo Recaudos (acceso restringido) — balance mensual Recaudos vs Servicios B2B.
    namespace :saldo_recaudos do
      get  "estadisticas",         to: "/api/saldo_recaudos#estadisticas"
      get  "query_recaudos",       to: "/api/saldo_recaudos#query_recaudos"
      get  "query_transacciones",  to: "/api/saldo_recaudos#query_transacciones"
      get  "informe_general",      to: "/api/saldo_recaudos#informe_general"
      get  "job_status/:job_id",   to: "/api/saldo_recaudos#job_status"
    end
    post "saldo_recaudos/enviar_email",   to: "saldo_recaudos#enviar_email"
    # v3.3.48: email status polling
    get  "saldo_recaudos/enviar_email_status/:job_id", to: "saldo_recaudos#enviar_email_status"

    # v3.3.29: Comisiones Recaudo (acceso restringido) — informe mensual 9 hojas.
    namespace :comisiones_recaudo do
      get  "estadisticas",         to: "/api/comisiones_recaudo#estadisticas"
      get  "query_recaudos",       to: "/api/comisiones_recaudo#query_recaudos"
      get  "query_comision",       to: "/api/comisiones_recaudo#query_comision"
      get  "informe_general",      to: "/api/comisiones_recaudo#informe_general"
      get  "job_status/:job_id",   to: "/api/comisiones_recaudo#job_status"
    end
    post "comisiones_recaudo/enviar_email",   to: "comisiones_recaudo#enviar_email"
    # v3.3.44: email status polling
    get  "comisiones_recaudo/enviar_email_status/:job_id", to: "comisiones_recaudo#enviar_email_status"

    # v3.3.30: Recaudos y Dispersiones (acceso restringido) — informe mensual 7 hojas.
    namespace :recaudos_dispersiones do
      get  "estadisticas",         to: "/api/recaudos_dispersiones#estadisticas"
      get  "query_dispersiones",   to: "/api/recaudos_dispersiones#query_dispersiones"
      get  "query_recaudos",       to: "/api/recaudos_dispersiones#query_recaudos"
      get  "informe_general",      to: "/api/recaudos_dispersiones#informe_general"
      get  "job_status/:job_id",   to: "/api/recaudos_dispersiones#job_status"
    end
    post "recaudos_dispersiones/enviar_email",   to: "recaudos_dispersiones#enviar_email"

    # v3.3.31: Estado de Cuenta SURTITODO (acceso restringido) — informe mensual 3 hojas con logo.
    namespace :estado_cuenta do
      get  "estadisticas",             to: "/api/estado_cuenta#estadisticas"
      get  "query_recaudos",           to: "/api/estado_cuenta#query_recaudos"
      get  "query_valor_mensajeria",   to: "/api/estado_cuenta#query_valor_mensajeria"
      get  "informe_general",          to: "/api/estado_cuenta#informe_general"
      get  "job_status/:job_id",       to: "/api/estado_cuenta#job_status"
    end
    post "estado_cuenta/enviar_email", to: "estado_cuenta#enviar_email"

    # v3.3.52: Validador de Dispersiones (submódulo Cash Out)
    namespace :validador_dispersiones do
      get  "cargar_async",                 to: "/api/validador_dispersiones#cargar_async"
      get  "cargar_status/:job_id",        to: "/api/validador_dispersiones#cargar_status"
      get  "exportar_async",               to: "/api/validador_dispersiones#exportar_async"
      get  "export_status/:job_id",        to: "/api/validador_dispersiones#export_status"
      get  "enviar_email_status/:job_id",  to: "/api/validador_dispersiones#enviar_email_status"
    end
    post "validador_dispersiones/enviar_email", to: "validador_dispersiones#enviar_email"

    # v3.3.58: PICAP CAMPAIGN VALIDATOR — pagos de campaña con datos reales de CH
    namespace :campaign_validator do
      get  "cargar_async",          to: "/api/campaign_validator#cargar_async"
      get  "cargar_status/:job_id", to: "/api/campaign_validator#cargar_status"
    end

    # v3.3.56: Consolidado Cash Out (submódulo Cash Out)
    namespace :consolidado_cash_out do
      get  "cargar_async",                 to: "/api/consolidado_cash_out#cargar_async"
      get  "cargar_status/:job_id",        to: "/api/consolidado_cash_out#cargar_status"
      get  "exportar_async",               to: "/api/consolidado_cash_out#exportar_async"
      get  "export_status/:job_id",        to: "/api/consolidado_cash_out#export_status"
      get  "enviar_email_status/:job_id",  to: "/api/consolidado_cash_out#enviar_email_status"
    end
    post "consolidado_cash_out/enviar_email", to: "consolidado_cash_out#enviar_email"

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
