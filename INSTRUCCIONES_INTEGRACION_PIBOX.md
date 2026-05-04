# INTEGRACIÓN MÓDULO PIBOX EN DASHBOARD.HTML

## 📋 RESUMEN
Agregar módulo de auditoría Pibox B2B al dashboard de monitoreo.

---

## 1️⃣ AGREGAR ITEM EN SIDEBAR

**Ubicación:** Después de la línea 1238 (después del item "Auditorías")

```html
  <!-- ── Pibox B2B ── -->
  <div class="sb2-item" id="sbg-pibox">
    <div class="sb2-icon" title="Pibox B2B">
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
        <rect x="4" y="6" width="12" height="10" rx="1" stroke="white" stroke-width="1.5"/>
        <path d="M7 6V5a3 3 0 016 0v1" stroke="white" stroke-width="1.5" stroke-linecap="round"/>
        <circle cx="10" cy="11" r="1.5" fill="white"/>
      </svg>
      <span class="sb2-label">Pibox</span>
    </div>
    <div class="sb2-flyout">
      <div class="fly-title">Pibox B2B</div>
      <div class="fly-link" id="nav-pibox-alertas" onclick="switchView('pibox','alertas')">
        <span>🚨</span> Alertas de Fraude
      </div>
    </div>
  </div>
```

---

## 2️⃣ AGREGAR VISTA HTML

**Ubicación:** Después de la vista de Reconocimiento Facial (buscar `<!-- ══ VISTA: RF ══ -->`)

```html
<!-- ══ VISTA: PIBOX ══ -->
<div class="view" id="view-pibox">
  <div class="wrap">
    <h2 style="font-size:18px;margin-bottom:16px;color:var(--text1)">🚨 Auditoría Pibox B2B</h2>
    
    <!-- Filtros -->
    <div class="filters-bar">
      <label>Fecha desde:</label>
      <input type="date" class="filter-select" id="pibox-desde" value="2026-01-01">
      
      <label>Fecha hasta:</label>
      <input type="date" class="filter-select" id="pibox-hasta" value="2026-01-31">
      
      <div class="sep"></div>
      
      <label>País:</label>
      <select class="filter-select" id="pibox-pais">
        <option value="">Todos</option>
        <option value="CO">Colombia</option>
        <option value="MX">México</option>
        <option value="NI">Nicaragua</option>
      </select>
      
      <label>Cliente:</label>
      <input type="text" class="filter-select" id="pibox-cliente" placeholder="Nombre cliente...">
      
      <label>Piloto:</label>
      <input type="text" class="filter-select" id="pibox-piloto" placeholder="Nombre piloto...">
      
      <div class="sep"></div>
      
      <button class="search-btn" onclick="buscarAlertasPibox()">
        <svg width="14" height="14" viewBox="0 0 20 20" fill="none">
          <circle cx="9" cy="9" r="5" stroke="currentColor" stroke-width="2"/>
          <path d="M13 13l4 4" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
        </svg>
        Buscar
      </button>
      
      <button class="search-btn" onclick="exportarPiboxExcel()">
        <svg width="14" height="14" viewBox="0 0 20 20" fill="none">
          <path d="M3 14v3h14v-3M10 3v9m-4-4l4 4 4-4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
        </svg>
        Exportar Excel
      </button>
    </div>
    
    <!-- KPIs -->
    <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-bottom:16px" id="pibox-kpis">
      <!-- Se llenan con JS -->
    </div>
    
    <!-- Tabla de alertas -->
    <div style="background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);overflow:hidden">
      <div style="padding:14px;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:center">
        <h3 style="font-size:14px;font-weight:700">Alertas Detectadas</h3>
        <span id="pibox-total-alertas" style="font-size:12px;color:var(--text3)">0 alertas</span>
      </div>
      
      <div style="overflow-x:auto">
        <table class="data-table" id="pibox-tabla">
          <thead>
            <tr>
              <th>Booking ID</th>
              <th>Piloto</th>
              <th>Cliente</th>
              <th>Tipo Alerta</th>
              <th>Severidad</th>
              <th>Observación</th>
              <th>Monto</th>
              <th>Fecha</th>
            </tr>
          </thead>
          <tbody id="pibox-tbody">
            <tr>
              <td colspan="8" style="text-align:center;padding:40px;color:var(--text3)">
                Selecciona un rango de fechas y presiona "Buscar"
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    
  </div>
</div>
```

---

## 3️⃣ AGREGAR JAVASCRIPT

**Ubicación:** En la sección `<script>` al final del archivo, antes del cierre `</script>`

```javascript
// ══════════════════════════════════════════════════════════════
// PIBOX B2B
// ══════════════════════════════════════════════════════════════

async function buscarAlertasPibox() {
  const desde = document.getElementById('pibox-desde').value;
  const hasta = document.getElementById('pibox-hasta').value;
  const pais = document.getElementById('pibox-pais').value;
  const cliente = document.getElementById('pibox-cliente').value;
  const piloto = document.getElementById('pibox-piloto').value;
  
  const tbody = document.getElementById('pibox-tbody');
  tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;padding:40px">⏳ Cargando alertas...</td></tr>';
  
  try {
    let url = `/api/pibox/alertas?desde=${desde}&hasta=${hasta}`;
    if (pais) url += `&pais=${pais}`;
    if (cliente) url += `&cliente=${encodeURIComponent(cliente)}`;
    if (piloto) url += `&piloto=${encodeURIComponent(piloto)}`;
    
    const res = await fetch(url);
    const data = await res.json();
    
    if (!data.ok) {
      throw new Error(data.error || 'Error al cargar alertas');
    }
    
    const alertas = data.alertas || [];
    
    // Actualizar KPIs
    actualizarKpisPibox(alertas);
    
    // Llenar tabla
    if (alertas.length === 0) {
      tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;padding:40px;color:var(--green)">✅ Sin alertas en este período</td></tr>';
      return;
    }
    
    tbody.innerHTML = alertas.map(a => `
      <tr>
        <td><code style="font-size:11px">${a.booking_id}</code></td>
        <td>${a.piloto_nombre || '—'}</td>
        <td>${a.cliente_nombre || '—'}</td>
        <td>${a.tipo_alerta}</td>
        <td>${getSeveridadBadge(a.severidad)}</td>
        <td>${a.observacion}</td>
        <td>$${Number(a.monto || 0).toLocaleString()}</td>
        <td style="white-space:nowrap">${formatFecha(a.fecha_servicio)}</td>
      </tr>
    `).join('');
    
    document.getElementById('pibox-total-alertas').textContent = `${alertas.length} alertas`;
    
  } catch (err) {
    tbody.innerHTML = `<tr><td colspan="8" style="text-align:center;padding:40px;color:var(--red)">❌ Error: ${err.message}</td></tr>`;
  }
}

function actualizarKpisPibox(alertas) {
  const kpisDiv = document.getElementById('pibox-kpis');
  
  const criticas = alertas.filter(a => a.severidad === 'CRÍTICA').length;
  const altas = alertas.filter(a => a.severidad === 'ALTA').length;
  const medias = alertas.filter(a => a.severidad === 'MEDIA').length;
  const total = alertas.length;
  
  kpisDiv.innerHTML = `
    <div class="kpi-card" style="background:var(--red-bg);border:1px solid ${criticas > 0 ? 'var(--red)' : 'var(--border)'}">
      <div class="kpi-value" style="color:var(--red)">${criticas}</div>
      <div class="kpi-label">Críticas</div>
    </div>
    <div class="kpi-card" style="background:var(--amber-bg);border:1px solid ${altas > 0 ? 'var(--amber)' : 'var(--border)'}">
      <div class="kpi-value" style="color:var(--amber)">${altas}</div>
      <div class="kpi-label">Altas</div>
    </div>
    <div class="kpi-card" style="background:var(--purple-lt);border:1px solid ${medias > 0 ? 'var(--purple)' : 'var(--border)'}">
      <div class="kpi-value" style="color:var(--purple)">${medias}</div>
      <div class="kpi-label">Medias</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-value">${total}</div>
      <div class="kpi-label">Total Alertas</div>
    </div>
  `;
}

function getSeveridadBadge(severidad) {
  const colors = {
    'CRÍTICA': 'background:var(--red-bg);color:var(--red);border:1px solid var(--red)',
    'ALTA': 'background:var(--amber-bg);color:var(--amber);border:1px solid var(--amber)',
    'MEDIA': 'background:var(--purple-lt);color:var(--purple);border:1px solid var(--purple)'
  };
  return `<span style="padding:3px 8px;border-radius:12px;font-size:10px;font-weight:700;${colors[severidad] || ''}">${severidad}</span>`;
}

function formatFecha(fecha) {
  if (!fecha) return '—';
  const d = new Date(fecha);
  return d.toLocaleDateString('es-CO', { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

async function exportarPiboxExcel() {
  const desde = document.getElementById('pibox-desde').value;
  const hasta = document.getElementById('pibox-hasta').value;
  const pais = document.getElementById('pibox-pais').value;
  
  let url = `/api/pibox/export?desde=${desde}&hasta=${hasta}`;
  if (pais) url += `&pais=${pais}`;
  
  window.open(url, '_blank');
}
```

---

## 4️⃣ ACTUALIZAR PERMISOS DE ROL

**Ubicación:** Buscar la variable `VISTAS_PERMITIDAS` en el JavaScript

**Agregar `"pibox"` a los roles que deben tener acceso:**

```javascript
const VISTAS_PERMITIDAS = {
  "admin":      ["monitoreo","pagos","recaudos","auditoria","pibox","rf","cashout","retencion","reconocimiento","home"],
  "evasion":    ["monitoreo","recaudos","auditoria","pibox","home"],
  "pagos":      ["monitoreo","pagos","pibox","home"],
  "recaudos":   ["monitoreo","recaudos","auditoria","pibox","home"],
  "pibox":      ["pibox","recaudos","auditoria","home"],  // Nuevo rol
  "rf":         ["rf","home"]
};
```

---

## 5️⃣ ACTUALIZAR TÍTULOS

**Ubicación:** Buscar `const TITULOS_VISTA` en el JavaScript

**Agregar:**

```javascript
const TITULOS_VISTA = {
  // ... existentes
  pibox:            'Auditoría Pibox B2B',
  // ... resto
};
```

---

## ✅ LISTO

Una vez integrados estos cambios, el módulo de Pibox aparecerá en el sidebar y podrás:
- Filtrar por fechas, país, cliente, piloto
- Ver KPIs de alertas (Críticas, Altas, Medias)
- Ver tabla de alertas detectadas
- Exportar a Excel

---

## 🔧 TESTING

1. Reinicia el servidor Flask
2. Abre el dashboard
3. Navega a "Pibox" en el sidebar
4. Busca alertas con un rango de fechas

