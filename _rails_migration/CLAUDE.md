# picap-monitoreo-rails

App Rails 7.1 de monitoreo Picap. Se despliega vía ArgoCD (app `picap-monitoring`,
chart en `secrets/picap-infra/k8s/apps/helm/picap-monitoring`) al cluster **k8s-apps**.

## ⚠️ Reglas que NO se deben romper

### 1. La ruta `GET /up` NO se debe borrar
`config/routes.rb` DEBE contener, antes del catch-all:

```ruby
get "up" => "rails/health#show", as: :rails_health_check
```

- Los probes de Kubernetes (`startupProbe`/`livenessProbe`/`readinessProbe` en
  `helm/picap-monitoring/templates/web.yaml`) pegan a `GET :3000/up`.
- Sin esa ruta, el catch-all final `match "*path", to: "application#not_found"`
  responde **404** → el probe falla → **CrashLoopBackOff** →
  `ProgressDeadlineExceeded` en el Deployment → **ArgoCD Degraded**.
- Ya pasó una vez: el commit `591924d` (v3.3.24-rc8) la borró por accidente y
  desde rc8 hasta rc11 (`78fc4c4`) la app quedó crasheando en producción.

### 2. El catch-all va siempre al FINAL de `routes.rb`
`match "*path", to: "application#not_found", via: :all` captura todo lo no
definido; cualquier ruta nueva (incluida `/up`) debe declararse antes.
