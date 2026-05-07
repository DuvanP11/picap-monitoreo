"""
reconocimiento_facial_v3.py — Picap
Pipeline completo de detección de identidades duplicadas entre pilotos.

Lógica:
  - RF + IMEI : cara similar Y mismo dispositivo → caso más grave
  - Solo RF   : cara similar, dispositivos diferentes → revisar
  - Solo IMEI : mismo dispositivo, caras distintas → posible préstamo

Optimizaciones:
  - Solo último mes de datos
  - 1 foto por piloto (la más reciente)
  - Todos los IMEIs únicos del mes por piloto (detecta cambios de celular)
  - LIMIT 500 pilotos para no explotar RAM
  - Libera matriz de embeddings antes de generar alertas
"""

import os, sys, signal, gc
import numpy as np
import cv2
import requests
import pandas as pd
import face_recognition
from itertools import combinations
from collections import defaultdict
from datetime import datetime, date, timedelta, timezone
import clickhouse_connect

# ══════════════════════════════════════════════════════
# CONFIGURACIÓN
# ══════════════════════════════════════════════════════

import os as _os
CLICKHOUSE_CONFIG = {
    "host":     _os.environ.get("CLICKHOUSE_HOST", "clickhouse.picap.io"),
    "port":     int(_os.environ.get("CLICKHOUSE_PORT", "8443")),
    "username": _os.environ.get("CLICKHOUSE_USER", "dperilla"),
    "password": _os.environ.get("CLICKHOUSE_PASSWORD", ""),
    "database": _os.environ.get("CLICKHOUSE_DATABASE", "picapmongoprod"),
    "secure":   True,
}

# ── Umbrales de similitud coseno puro [-1, 1] ──
# Equivalencias con distancia L2 de dlib:
#   cos ≥ 0.99  ↔  L2 ≈ 0.14  → FOTO_DUPLICADA (misma foto)
#   cos ≥ 0.92  ↔  L2 < 0.40  → ALERTA         (misma persona, certeza alta)
#   cos ≥ 0.875 ↔  L2 < 0.50  → REVISAR        (probable match)
#   cos ≥ 0.82  ↔  L2 < 0.60  → POSIBLE        (umbral oficial dlib)
#   cos < 0.82                 → personas distintas
SIM_DUPLICADA = 0.99
SIM_ALERTA    = 0.92
SIM_REVISAR   = 0.875
SIM_POSIBLE   = 0.82

COD_PILOTO    = 3      # driver_enrollment_status_cd = 3 → PILOTO
MAX_ANCHO     = 500    # px máximo antes de redimensionar
BATCH_SIZE    = 50     # pilotos por lote de descarga
LIMIT_QUERY   = 500    # máx pilotos a analizar (None = sin límite)

PALABRAS_PRUEBA = ["prueba", "testeo", "test", "demo", "fake"]

# ── Rango de fechas: primer día del mes anterior → hoy ──
HOY        = date.today()
DESDE_MES  = (HOY.replace(day=1) - timedelta(days=1)).replace(day=1)
DESDE_STR  = DESDE_MES.strftime("%Y-%m-%d")
HASTA_STR  = HOY.strftime("%Y-%m-%d")
LIMIT_SQL  = f"LIMIT {LIMIT_QUERY}" if LIMIT_QUERY else ""

# ══════════════════════════════════════════════════════
# CONTROL DE INTERRUPCIÓN
# ══════════════════════════════════════════════════════

stop_flag = False

def detener(sig, frame):
    global stop_flag
    print("\n⚠ Interrupción detectada. Guardando progreso...")
    stop_flag = True

signal.signal(signal.SIGINT, detener)
session = requests.Session()

# ══════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════

def es_prueba(nombre):
    return nombre and any(p in str(nombre).lower() for p in PALABRAS_PRUEBA)

def redimensionar(img):
    h, w = img.shape[:2]
    if w <= MAX_ANCHO:
        return img
    return cv2.resize(img, (MAX_ANCHO, int(h * MAX_ANCHO / w)), interpolation=cv2.INTER_AREA)

def obtener_embedding(url):
    """Descarga imagen y retorna embedding numpy 128d, o None si falla."""
    try:
        resp = session.get(str(url), timeout=(5, 12))
        if resp.status_code != 200:
            return None
        arr     = np.frombuffer(resp.content, np.uint8)
        img     = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        del arr
        if img is None:
            return None
        img     = redimensionar(img)
        img_rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        del img
        encs    = face_recognition.face_encodings(img_rgb, num_jitters=1, model="large")
        del img_rgb
        return encs[0] if encs else None
    except Exception:
        return None

def clasificar(sim):
    """Retorna nivel de alerta según similitud coseno, o None si no aplica."""
    if sim >= SIM_DUPLICADA: return "FOTO_DUPLICADA"
    if sim >= SIM_ALERTA:    return "ALERTA"
    if sim >= SIM_REVISAR:   return "REVISAR"
    if sim >= SIM_POSIBLE:   return "POSIBLE"
    return None

# ══════════════════════════════════════════════════════
# ESQUEMA DE TABLA EN CLICKHOUSE
# ══════════════════════════════════════════════════════

CREATE_TABLE = """
CREATE TABLE IF NOT EXISTS picapmongoprod.alertas_reconocimiento (
    tipo_alerta  String,
    nivel        String,
    similitud    Float64,
    mismo_imei   String,
    imei_comun   String,
    nombre_a     String,
    user_id_a    String,
    url_a        String,
    created_at_a String,
    nombre_b     String,
    user_id_b    String,
    url_b        String,
    created_at_b String,
    procesado_en DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY (procesado_en, tipo_alerta, nivel)
"""

# ALTER TABLE para tablas existentes que no tengan las columnas nuevas
ALTERS = [
    "ALTER TABLE picapmongoprod.alertas_reconocimiento ADD COLUMN IF NOT EXISTS tipo_alerta  String DEFAULT 'RF'",
    "ALTER TABLE picapmongoprod.alertas_reconocimiento ADD COLUMN IF NOT EXISTS mismo_imei   String DEFAULT 'NO'",
    "ALTER TABLE picapmongoprod.alertas_reconocimiento ADD COLUMN IF NOT EXISTS imei_comun   String DEFAULT ''",
    "ALTER TABLE picapmongoprod.alertas_reconocimiento ADD COLUMN IF NOT EXISTS nombre_a     String DEFAULT ''",
    "ALTER TABLE picapmongoprod.alertas_reconocimiento ADD COLUMN IF NOT EXISTS nombre_b     String DEFAULT ''",
]

# ══════════════════════════════════════════════════════
# PASO 1 — CONECTAR Y PREPARAR TABLA
# ══════════════════════════════════════════════════════

print("=" * 60)
print("  PICAP — Reconocimiento Facial v3")
print(f"  Período  : {DESDE_STR} → {HASTA_STR}")
print(f"  Umbrales : DUPLICADA≥{SIM_DUPLICADA} | ALERTA≥{SIM_ALERTA} | REVISAR≥{SIM_REVISAR} | POSIBLE≥{SIM_POSIBLE}")
print("=" * 60)

print("\n[1/5] Conectando a ClickHouse...")
client = clickhouse_connect.get_client(**CLICKHOUSE_CONFIG)
client.command(CREATE_TABLE)
for alter in ALTERS:
    try:
        client.command(alter)
    except Exception:
        pass  # columna ya existe
print("      ✓ Tabla alertas_reconocimiento lista")

# ══════════════════════════════════════════════════════
# PASO 2 — CONSULTAR PILOTOS (1 foto por piloto)
# ══════════════════════════════════════════════════════

print(f"\n[2/5] Consultando pilotos únicos del período...")

Q_PILOTOS = f"""
SELECT created_at, _id, photo_selfie_url, name
FROM (
    SELECT
        created_at, _id, photo_selfie_url, name,
        ROW_NUMBER() OVER (PARTITION BY _id ORDER BY created_at DESC) AS rn
    FROM picapmongoprod.passengers
    WHERE photo_selfie_url IS NOT NULL
      AND length(trim(photo_selfie_url)) > 0
      AND lower(photo_selfie_url) NOT IN ('null', '')
      AND name IS NOT NULL
      AND length(trim(name)) > 0
      AND driver_enrollment_status_cd = {COD_PILOTO}
      AND lower(name) NOT LIKE '%prueba%'
      AND lower(name) NOT LIKE '%testeo%'
      AND lower(name) NOT LIKE '%test%'
      AND lower(name) NOT LIKE '%demo%'
      AND lower(name) NOT LIKE '%fake%'
      AND created_at >= toDateTime('{DESDE_STR} 00:00:00', 'America/Bogota')
      AND created_at <= toDateTime('{HASTA_STR} 23:59:59', 'America/Bogota')
)
WHERE rn = 1
ORDER BY created_at DESC
{LIMIT_SQL}
"""

filas = client.query(Q_PILOTOS).result_rows
print(f"      ✓ Pilotos únicos: {len(filas)} (máx {LIMIT_QUERY})")

if not filas:
    print("Sin pilotos en el período. Verifica la query o las fechas.")
    sys.exit(1)

# ══════════════════════════════════════════════════════
# PASO 3 — CONSULTAR IMEIs (todos los del mes por piloto)
# ══════════════════════════════════════════════════════

print(f"\n[3/5] Consultando IMEIs del período...")

Q_IMEI = f"""
SELECT DISTINCT passenger_id, imei
FROM picapmongoprod.sessions
WHERE imei IS NOT NULL
  AND imei != ''
  AND passenger_id IS NOT NULL
  AND passenger_id != ''
  AND created_at >= toDateTime('{DESDE_STR} 00:00:00', 'America/Bogota')
  AND created_at <= toDateTime('{HASTA_STR} 23:59:59', 'America/Bogota')
"""

imei_rows = client.query(Q_IMEI).result_rows

# usuario → set de IMEIs únicos usados en el período
IMEI_MAP = defaultdict(set)
for r in imei_rows:
    if r[0] and r[1]:
        IMEI_MAP[str(r[0])].add(str(r[1]))

total_imeis = sum(len(v) for v in IMEI_MAP.values())
prom = total_imeis / max(len(IMEI_MAP), 1)
print(f"      ✓ Pilotos con IMEI: {len(IMEI_MAP)} | Total IMEIs: {total_imeis} | Prom/piloto: {prom:.2f}")

# ══════════════════════════════════════════════════════
# PASO 4 — EXTRAER EMBEDDINGS
# ══════════════════════════════════════════════════════

print(f"\n[4/5] Extrayendo embeddings faciales (lotes de {BATCH_SIZE})...")

registros  = []
sin_rostro = 0

for start in range(0, len(filas), BATCH_SIZE):
    if stop_flag:
        break
    batch = filas[start:start + BATCH_SIZE]
    fin   = min(start + BATCH_SIZE, len(filas))
    print(f"      Lote {start+1}-{fin}/{len(filas)} | Válidos: {len(registros)} | Sin rostro: {sin_rostro}")

    for fila in batch:
        if stop_flag:
            break
        created_at, user_id, url, nombre = fila
        if es_prueba(nombre):
            continue
        emb = obtener_embedding(url)
        if emb is not None:
            registros.append({
                "user_id":    str(user_id),
                "nombre":     str(nombre),
                "image_url":  str(url),
                "created_at": str(created_at),
                "embedding":  emb,
            })
        else:
            sin_rostro += 1
        gc.collect()

n = len(registros)
print(f"\n      Resumen extracción:")
print(f"        Embeddings válidos : {n}")
print(f"        Sin rostro         : {sin_rostro}")

if n < 2:
    print("Menos de 2 embeddings. No se puede comparar.")
    sys.exit(1)

# ══════════════════════════════════════════════════════
# PASO 5 — COMPARAR N×N + CRUZAR IMEI + GUARDAR
# ══════════════════════════════════════════════════════

print(f"\n[5/5] Comparando {n} pilotos y generando alertas...")

# Matriz de similitud coseno
E     = np.array([r["embedding"] for r in registros])
norms = np.linalg.norm(E, axis=1, keepdims=True)
norms[norms == 0] = 1
E_n   = E / norms
sim_matrix = E_n @ E_n.T   # coseno puro [-1, 1]
del E, E_n, norms
gc.collect()

# ── 5a. Alertas por RF (y RF+IMEI si comparten dispositivo) ──
alertas = []
for i, j in combinations(range(n), 2):
    if stop_flag:
        break
    sim   = float(sim_matrix[i, j])
    nivel = clasificar(sim)
    if nivel is None:
        continue
    a, b = registros[i], registros[j]
    if a["user_id"] == b["user_id"]:
        continue

    # Cruzar IMEIs: intersección de todos los usados en el período
    imeis_a       = IMEI_MAP.get(a["user_id"], set())
    imeis_b       = IMEI_MAP.get(b["user_id"], set())
    imeis_comunes = imeis_a & imeis_b
    mismo_imei    = len(imeis_comunes) > 0
    imei_comun    = list(imeis_comunes)[0] if imeis_comunes else ""
    tipo_alerta   = "RF + IMEI" if mismo_imei else "RF"

    alertas.append({
        "tipo_alerta":  tipo_alerta,
        "nivel":        nivel,
        "similitud":    round(sim, 4),
        "mismo_imei":   "SÍ" if mismo_imei else "NO",
        "imei_comun":   imei_comun,
        "nombre_a":     a["nombre"],
        "user_id_a":    a["user_id"],
        "url_a":        a["image_url"],
        "created_at_a": a["created_at"],
        "nombre_b":     b["nombre"],
        "user_id_b":    b["user_id"],
        "url_b":        b["image_url"],
        "created_at_b": b["created_at"],
    })

# Ordenar: RF+IMEI primero, luego RF, luego por similitud desc
alertas.sort(key=lambda x: (
    0 if x["tipo_alerta"] == "RF + IMEI" else
    1 if x["tipo_alerta"] == "RF" else 2,
    -x["similitud"]
))

# ── 5b. Alertas solo por IMEI (pilotos con mismo dispositivo sin coincidencia facial) ──
print("      Buscando pares con mismo IMEI sin alerta RF...")

ids_con_embedding = {r["user_id"] for r in registros}
imei_to_users     = defaultdict(list)
for uid, imeis_set in IMEI_MAP.items():
    for imei in imeis_set:
        imei_to_users[imei].append(uid)

pares_rf = {
    (x["user_id_a"], x["user_id_b"]) for x in alertas
} | {
    (x["user_id_b"], x["user_id_a"]) for x in alertas
}

alertas_imei = []
for imei, uids in imei_to_users.items():
    uids_validos = [u for u in uids if u in ids_con_embedding]
    if len(uids_validos) < 2:
        continue
    for i2 in range(len(uids_validos)):
        for j2 in range(i2 + 1, len(uids_validos)):
            uid_a, uid_b = uids_validos[i2], uids_validos[j2]
            if (uid_a, uid_b) in pares_rf:
                continue   # ya tiene alerta RF — no duplicar
            reg_a = next((r for r in registros if r["user_id"] == uid_a), None)
            reg_b = next((r for r in registros if r["user_id"] == uid_b), None)
            if not reg_a or not reg_b:
                continue
            alertas_imei.append({
                "tipo_alerta":  "IMEI",
                "nivel":        "REVISAR",
                "similitud":    0.0,
                "mismo_imei":   "SÍ",
                "imei_comun":   imei,
                "nombre_a":     reg_a["nombre"],
                "user_id_a":    uid_a,
                "url_a":        reg_a["image_url"],
                "created_at_a": reg_a["created_at"],
                "nombre_b":     reg_b["nombre"],
                "user_id_b":    uid_b,
                "url_b":        reg_b["image_url"],
                "created_at_b": reg_b["created_at"],
            })

alertas += alertas_imei

# ── Resumen ──
n_rf_imei = sum(1 for a in alertas if a["tipo_alerta"] == "RF + IMEI")
n_rf_solo = sum(1 for a in alertas if a["tipo_alerta"] == "RF")
n_im_solo = sum(1 for a in alertas if a["tipo_alerta"] == "IMEI")
n_dup     = sum(1 for a in alertas if a["nivel"] == "FOTO_DUPLICADA")
n_al      = sum(1 for a in alertas if a["nivel"] == "ALERTA")
n_rev     = sum(1 for a in alertas if a["nivel"] == "REVISAR")
n_pos     = sum(1 for a in alertas if a["nivel"] == "POSIBLE")

print(f"\n      Total alertas: {len(alertas)}")
print(f"        🔴 RF + IMEI    : {n_rf_imei}  ← MÁS GRAVE")
print(f"        🟠 Solo RF      : {n_rf_solo}")
print(f"        🔵 Solo IMEI    : {n_im_solo}")
print(f"        ───────────────")
print(f"        FOTO_DUPLICADA  : {n_dup}")
print(f"        ALERTA          : {n_al}")
print(f"        REVISAR         : {n_rev}")
print(f"        POSIBLE         : {n_pos}")

# ── Guardar Excel ──
df = pd.DataFrame([{k: v for k, v in a.items()} for a in alertas])
df.to_excel("alertas_duplicados.xlsx", index=False)
print(f"\n      ✓ alertas_duplicados.xlsx ({len(alertas)} filas)")

df_emb = pd.DataFrame([{k: v for k, v in r.items() if k != "embedding"} for r in registros])
df_emb.to_excel("embeddings_parciales.xlsx", index=False)
print(f"      ✓ embeddings_parciales.xlsx ({n} pilotos)")

# ── Guardar en ClickHouse ──
if alertas:
    hoy_str = datetime.now().strftime("%Y-%m-%d")
    client.command(
        f"ALTER TABLE picapmongoprod.alertas_reconocimiento DELETE "
        f"WHERE procesado_en >= toDateTime('{hoy_str} 00:00:00')"
    )
    rows_ch = [[
        a["tipo_alerta"], a["nivel"], float(a["similitud"]),
        a["mismo_imei"], a["imei_comun"],
        a["nombre_a"], a["user_id_a"], a["url_a"], a["created_at_a"],
        a["nombre_b"], a["user_id_b"], a["url_b"], a["created_at_b"],
        datetime.now(timezone.utc),
    ] for a in alertas]

    client.insert(
        "picapmongoprod.alertas_reconocimiento",
        rows_ch,
        column_names=[
            "tipo_alerta", "nivel", "similitud", "mismo_imei", "imei_comun",
            "nombre_a", "user_id_a", "url_a", "created_at_a",
            "nombre_b", "user_id_b", "url_b", "created_at_b",
            "procesado_en",
        ]
    )
    print(f"      ✓ ClickHouse: {len(alertas)} alertas insertadas")
else:
    print("      Sin alertas para guardar.")

print("\n" + "=" * 60)
print("  PROCESO COMPLETADO")
print("=" * 60)
