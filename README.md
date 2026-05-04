# Picap · Tablero de Evasión de Comisiones

Tablero de gerencia conectado directamente a ClickHouse.
Dos archivos, sin framework, sin base de datos adicional.

## Estructura

```
picap_evasion/
├── api.py          ← Servidor Flask (conecta a ClickHouse, expone JSON)
├── dashboard.html  ← Tablero web (abre directo en el browser)
└── README.md
```

## Instalación

```bash
pip install flask flask-cors clickhouse-connect pandas numpy
```

## Uso

### 1. Iniciar el servidor

```bash
python api.py
```

Verás:
```
=======================================================
  Picap Evasión API  →  http://localhost:5050
  Endpoints:
    GET /api/status
    GET /api/resumen?desde=YYYY-MM-DD&hasta=YYYY-MM-DD
    GET /api/datos?desde=&hasta=&nivel=&ciudad=
=======================================================
```

La primera carga tarda ~10–30 segundos dependiendo del volumen en ClickHouse.

### 2. Abrir el tablero

Abre `dashboard.html` directamente en Chrome/Edge/Firefox:
```
Doble clic en dashboard.html
```
O desde terminal:
```bash
# macOS
open dashboard.html

# Linux
xdg-open dashboard.html

# Windows
start dashboard.html
```

### 3. Seleccionar período

Usa los botones **7 / 15 / 30 días** o las fechas personalizadas.
Cada vez que cambias el período, el servidor re-ejecuta la query en ClickHouse.

---

## Endpoints de la API

| Endpoint | Descripción |
|---|---|
| `GET /api/status` | Health-check, estado del caché |
| `GET /api/resumen` | KPIs + tendencia + ciudades + conductores |
| `GET /api/datos`   | Registros completos (detalle auditoria) |

**Parámetros opcionales** en todos los endpoints:
- `desde=2026-03-01`
- `hasta=2026-03-15`
- `nivel=3` → solo evasión confirmada
- `ciudad=Bogotá` → filtrar por ciudad

**Ejemplo:**
```bash
curl "http://localhost:5050/api/resumen?desde=2026-03-01&hasta=2026-03-15"
```

---

## Lógica de clasificación (igual que tu script original)

| Condición | Veredicto | Nivel |
|---|---|---|
| regla_tiempo AND regla_cancelacion | EVASION CONFIRMADA | 3 |
| regla_tiempo AND sin_GPS | EVASION PROBABLE | 2 |
| regla_tiempo OR regla_cancelacion | EVASION PROBABLE | 2 |
| ninguna | OK | 0 |

- **regla_tiempo**: `minutos_entre_eventos > 5`
- **regla_cancelacion**: `geoDistance(cancel, destino) <= 450 m`

---

## Caché y actualización

El servidor guarda los datos en memoria y los refresca automáticamente **cada hora**,
igual que tu frecuencia de exportación actual.

Para forzar recarga inmediata: haz clic en **↻ Actualizar** en el tablero,
o llama directamente al endpoint con el rango deseado.

---

## Producción (opcional)

Para dejar el servidor corriendo en background:

```bash
# Con nohup
nohup python api.py > picap_api.log 2>&1 &

# O con screen
screen -S picap_api
python api.py
# Ctrl+A, D para desconectar
```

Para exponer en red local (que gerencia lo abra desde otro PC):
- El servidor ya escucha en `0.0.0.0:5050`
- Cambia `const API = "http://localhost:5050"` en dashboard.html
  por `const API = "http://TU_IP_LOCAL:5050"`
