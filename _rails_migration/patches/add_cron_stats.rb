#!/usr/bin/env ruby
# patches/add_cron_stats.rb
#
# Agrega al panel "Cronograma" del dashboard.html.erb:
#   - Donut chart SVG dinámico con % completado
#   - 3 botones de filtro: Todas / Hechas / Pendientes
#   - KPI con contadores
#
# 100% frontend — usa los datos `hecho_en_periodo_actual` que el backend ya
# devuelve. No toca controllers, queries, ni nada del backend.
#
# Idempotente: si ya está aplicado, sale sin hacer nada (busca un marcador único).
#
# Uso desde la raíz del Rails project:
#   ruby /tmp/picap-monitoreo-source/_rails_migration/patches/add_cron_stats.rb
#   # o copiá este archivo a tu Rails y lo corrés
#
# Si algo sale mal, hay backup en .bak.<timestamp>.

require "fileutils"

DASHBOARD = "app/views/pages/dashboard.html.erb"
MARKER    = "<!-- @cron-stats-panel:v1 -->"

abort "❌ #{DASHBOARD} no existe. Ejecuta este script desde la raíz del proyecto Rails." unless File.exist?(DASHBOARD)

src = File.read(DASHBOARD)

if src.include?(MARKER)
  puts "✓ Patch ya aplicado (marcador #{MARKER} encontrado). Sin cambios."
  exit 0
end

# ── Anchor 1: insertar el panel de stats ANTES de <div id="cron-lista">
ANCHOR_HTML = '<div id="cron-lista">'
unless src.include?(ANCHOR_HTML)
  abort "❌ No encuentro '#{ANCHOR_HTML}' en dashboard.html.erb. Aborto sin cambios."
end

STATS_PANEL_HTML = <<~HTML.chomp
  #{MARKER}
          <div id="cron-stats" style="display:flex;gap:20px;align-items:center;padding:14px 18px;background:linear-gradient(135deg,#f3eaff 0%,#fff 100%);border:1px solid #d8c4ff;border-radius:12px;margin-bottom:14px;flex-wrap:wrap">
            <!-- Donut SVG dinámico -->
            <div style="position:relative;width:120px;height:120px;flex-shrink:0">
              <svg width="120" height="120" viewBox="0 0 120 120" style="transform:rotate(-90deg)">
                <circle cx="60" cy="60" r="48" fill="none" stroke="#e9d5ff" stroke-width="14"/>
                <circle id="cron-donut-progress" cx="60" cy="60" r="48" fill="none" stroke="#7c3aed" stroke-width="14" stroke-dasharray="0 999" stroke-linecap="round" style="transition:stroke-dasharray 0.6s cubic-bezier(0.4,0,0.2,1)"/>
              </svg>
              <div style="position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);text-align:center;pointer-events:none">
                <div id="cron-donut-pct" style="font-size:22px;font-weight:800;color:#5a2bb8;line-height:1">0%</div>
                <div style="font-size:9px;color:#7c3aed;font-weight:600;margin-top:2px">completadas</div>
              </div>
            </div>
            <!-- Stats + filtros -->
            <div style="flex:1;min-width:240px">
              <div style="font-size:14px;font-weight:700;color:#5a2bb8;margin-bottom:4px">📊 Mi rendimiento <span id="cron-stats-periodo" style="color:#7c3aed;font-weight:500;font-size:12px">esta semana</span></div>
              <div id="cron-stats-numeros" style="font-size:12px;color:var(--text2);margin-bottom:10px">Cargá las tareas para ver tu rendimiento.</div>
              <div style="display:flex;gap:6px;flex-wrap:wrap">
                <button class="cron-filtro-btn" data-filtro="todas" onclick="cronFiltrar('todas')" style="font-size:11px;padding:5px 12px;background:#7c3aed;color:#fff;border:none;border-radius:6px;font-weight:700;cursor:pointer">📋 Todas <span id="cron-cnt-todas" style="opacity:0.85;margin-left:2px">0</span></button>
                <button class="cron-filtro-btn" data-filtro="hechas" onclick="cronFiltrar('hechas')" style="font-size:11px;padding:5px 12px;background:#fff;color:#16a34a;border:1px solid #16a34a;border-radius:6px;font-weight:700;cursor:pointer">✓ Hechas <span id="cron-cnt-hechas" style="opacity:0.85;margin-left:2px">0</span></button>
                <button class="cron-filtro-btn" data-filtro="pendientes" onclick="cronFiltrar('pendientes')" style="font-size:11px;padding:5px 12px;background:#fff;color:#dc2626;border:1px solid #dc2626;border-radius:6px;font-weight:700;cursor:pointer">⏳ Pendientes <span id="cron-cnt-pendientes" style="opacity:0.85;margin-left:2px">0</span></button>
              </div>
            </div>
          </div>
          #{ANCHOR_HTML}
HTML

src = src.sub(ANCHOR_HTML, STATS_PANEL_HTML)
puts "✓ Anchor HTML insertado (panel stats antes de cron-lista)"

# ── Anchor 2: reemplazar renderCronogramaLista() para que filtre + dispare stats
OLD_RENDER_START = "function renderCronogramaLista() {\n  const cont = document.getElementById('cron-lista');\n  if (!cont) return;\n  if (!_cronTareas.length) {"
NEW_RENDER_START = "function renderCronogramaLista() {\n  const cont = document.getElementById('cron-lista');\n  if (!cont) return;\n  renderCronogramaStats();\n  // Aplicar filtro activo\n  let _tareasFiltradas = _cronTareas;\n  if (_cronFiltro === 'hechas')      _tareasFiltradas = _cronTareas.filter(t => t.hecho_en_periodo_actual);\n  else if (_cronFiltro === 'pendientes') _tareasFiltradas = _cronTareas.filter(t => !t.hecho_en_periodo_actual);\n  if (!_tareasFiltradas.length) {\n    const msg = _cronTareas.length === 0\n      ? '📭 No hay tareas programadas. Crea una con el formulario de arriba.'\n      : (_cronFiltro === 'hechas' ? '✓ Aún no marcaste ninguna como hecha en este período.' : '🎉 ¡Tienes todo al día! No hay pendientes.');\n    cont.innerHTML = `<div style=\"text-align:center;padding:24px;color:var(--text3);font-size:12px\">${msg}</div>`;\n    return;\n  }\n  if (false) {"

unless src.include?(OLD_RENDER_START)
  abort "❌ No encuentro el inicio de renderCronogramaLista(). Aborto sin cambios."
end
src = src.sub(OLD_RENDER_START, NEW_RENDER_START)
puts "✓ renderCronogramaLista actualizado (filtra + dispara stats)"

# Ahora hay que cambiar `_cronTareas.map` → `_tareasFiltradas.map` dentro de esa función
src = src.sub("const html = _cronTareas.map(t => {", "const html = _tareasFiltradas.map(t => {")
puts "✓ map dentro de renderCronogramaLista usa _tareasFiltradas"

# ── Anchor 3: agregar funciones helpers ANTES de `async function cronGuardar()`
ANCHOR_JS = "async function cronGuardar() {"
unless src.include?(ANCHOR_JS)
  abort "❌ No encuentro 'async function cronGuardar()'. Aborto sin cambios."
end

HELPER_JS = <<~JS.chomp
  // ── Cron stats + filtro (@cron-stats-panel:v1) ──────────────────────
  let _cronFiltro = 'todas';

  function _cronPeriodoFreqLabel() {
    // Si hay tareas, usa la frecuencia más común para el título del card.
    if (!_cronTareas.length) return 'esta semana';
    const counts = {};
    _cronTareas.forEach(t => { const f = (t.frecuencia||'semanal').toLowerCase(); counts[f] = (counts[f]||0)+1; });
    const mostFreq = Object.entries(counts).sort((a,b)=>b[1]-a[1])[0][0];
    return {
      diaria:'hoy', semanal:'esta semana', mensual:'este mes',
      trimestral:'este trimestre', semestral:'este semestre',
      anual:'este año', unica:'(tarea única)'
    }[mostFreq] || 'este período';
  }

  function renderCronogramaStats() {
    const total = _cronTareas.length;
    const hechas = _cronTareas.filter(t => t.hecho_en_periodo_actual).length;
    const pendientes = total - hechas;
    const pct = total > 0 ? Math.round(hechas / total * 100) : 0;

    // Donut: r=48 → circ = 2πr ≈ 301.59
    const circ = 2 * Math.PI * 48;
    const filled = (pct / 100) * circ;
    const donut = document.getElementById('cron-donut-progress');
    if (donut) donut.setAttribute('stroke-dasharray', `${filled} ${circ - filled}`);
    const pctEl = document.getElementById('cron-donut-pct');
    if (pctEl) pctEl.textContent = `${pct}%`;

    const periodoEl = document.getElementById('cron-stats-periodo');
    if (periodoEl) periodoEl.textContent = _cronPeriodoFreqLabel();

    const numEl = document.getElementById('cron-stats-numeros');
    if (numEl) {
      if (total === 0) {
        numEl.innerHTML = 'No hay tareas programadas todavía.';
      } else {
        numEl.innerHTML = `<strong style="color:#16a34a">${hechas}</strong> de <strong>${total}</strong> tareas completadas · <strong style="color:#dc2626">${pendientes}</strong> pendiente${pendientes===1?'':'s'}`;
      }
    }
    const ids = {todas:total, hechas:hechas, pendientes:pendientes};
    Object.keys(ids).forEach(k => {
      const el = document.getElementById('cron-cnt-' + k);
      if (el) el.textContent = ids[k];
    });
  }

  function cronFiltrar(filtro) {
    _cronFiltro = filtro;
    // Estilo de botones activos
    document.querySelectorAll('.cron-filtro-btn').forEach(btn => {
      const isActive = btn.dataset.filtro === filtro;
      const baseColor = filtro === 'hechas' ? '#16a34a' : filtro === 'pendientes' ? '#dc2626' : '#7c3aed';
      btn.style.background = isActive ? baseColor : '#fff';
      btn.style.color      = isActive ? '#fff' : baseColor;
      btn.style.border     = isActive ? 'none' : `1px solid ${baseColor}`;
    });
    renderCronogramaLista();
  }

JS

src = src.sub(ANCHOR_JS, HELPER_JS + "\n  " + ANCHOR_JS)
puts "✓ Helpers JS agregados (renderCronogramaStats + cronFiltrar + _cronPeriodoFreqLabel)"

# ── Backup + write
ts = Time.now.strftime("%Y%m%d_%H%M%S")
bak = "#{DASHBOARD}.bak.#{ts}"
FileUtils.cp(DASHBOARD, bak)
File.write(DASHBOARD, src)
puts ""
puts "🎯 Patch aplicado a #{DASHBOARD}"
puts "   Backup: #{bak}"
puts ""
puts "Para revertir si algo se rompe:"
puts "   cp #{bak} #{DASHBOARD}"
