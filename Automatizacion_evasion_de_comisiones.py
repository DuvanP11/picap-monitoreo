
import clickhouse_connect
import pandas as pd
import openpyxl
from openpyxl.styles import PatternFill, Font, Alignment
from datetime import datetime

# ══════════════════════════════════════════════════════════════
# 1. CONEXIÓN
# ══════════════════════════════════════════════════════════════
import os as _os
client = clickhouse_connect.get_client(
    host=_os.environ.get("CLICKHOUSE_HOST", "clickhouse.picap.io"),
    port=int(_os.environ.get("CLICKHOUSE_PORT", "8443")),
    username=_os.environ.get("CLICKHOUSE_USER", "dperilla"),
    password=_os.environ.get("CLICKHOUSE_PASSWORD", ""),
    database=_os.environ.get("CLICKHOUSE_DATABASE", "picapmongoprod"),
    secure=True
)

# ══════════════════════════════════════════════════════════════
# 2. QUERY — con ROW_NUMBER para evitar duplicados
# ══════════════════════════════════════════════════════════════
QUERY = """
WITH base AS (
    SELECT 
        toTimeZone(b.created_at, 'America/Bogota') AS creacion_servicio,
        parseDateTimeBestEffortOrNull(ev_accept)   AS fecha_aceptacion,
        parseDateTimeBestEffortOrNull(ev_cancel)   AS fecha_cancelacion,
        b._id              AS booking_id,
        b.status_cd        AS estado_servicio,
        b.driver_id        AS id_driver,
        pd.name            AS name_driver,
        b.passenger_id     AS id_user,
        pu.name            AS name_user,
        b.company_id       AS id_company,
        JSONExtractString(st.name, 'es') AS type_service,
        JSONExtractString(b.final_cost, 'currency_iso') AS moneda,
        b.g_country        AS pais,
        b.g_adm_area_lv_1  AS ciudad,
        toFloat64OrNull(JSONExtractString(b.final_cost,     'cents')) / 100 AS costo_final,
        toFloat64OrNull(JSONExtractString(b.estimated_cost, 'cents')) / 100 AS costo_estimado,

        extract(ifNull(b.events,''), 'event_cd":26.*?coordinates":\\[\\s*([+-]?\\d+\\.\\d+)')      AS ev_cancel_lon_str,
        extract(ifNull(b.events,''), 'event_cd":26.*?coordinates":\\[.*?,\\s*([+-]?\\d+\\.\\d+)')  AS ev_cancel_lat_str,
        extract(ifNull(b.events,''), 'event_cd":20.*?created_at":"([^"]+)')                        AS ev_accept,
        extract(ifNull(b.events,''), 'event_cd":26.*?created_at":"([^"]+)')                        AS ev_cancel,

        toFloat64OrNull(ev_cancel_lon_str) AS cancel_lon,
        toFloat64OrNull(ev_cancel_lat_str) AS cancel_lat,
        toFloat64(JSONExtractString(b.end_geojson, 'coordinates', 1)) AS end_lon,
        toFloat64(JSONExtractString(b.end_geojson, 'coordinates', 2)) AS end_lat,

        dateDiff('minute',
            parseDateTimeBestEffortOrNull(ev_accept),
            parseDateTimeBestEffortOrNull(ev_cancel)
        ) AS minutos_entre_eventos,

        if(
            dateDiff('minute',
                parseDateTimeBestEffortOrNull(ev_accept),
                parseDateTimeBestEffortOrNull(ev_cancel)
            ) > 5,
            'Evasion', 'Ok'
        ) AS regla_tiempo,

        ROW_NUMBER() OVER (
            PARTITION BY b._id
            ORDER BY b.created_at DESC
        ) AS rn

    FROM picapmongoprod.bookings b
    LEFT JOIN picapmongoprod.passengers pd ON b.driver_id    = pd._id
    LEFT JOIN picapmongoprod.passengers pu ON b.passenger_id = pu._id
    LEFT JOIN picapmongoprod.service_types st ON st._id = b.requested_service_type_id

    WHERE 
        NOT empty(b.origin_geojson)
        AND NOT empty(b.end_geojson)
        AND b.status_cd IN (100, 102)
        AND b.created_at >= toDateTime('2026-03-01 00:00:00')
        AND b.created_at <= toDateTime('2026-03-15 23:59:59')
)

SELECT
    creacion_servicio, fecha_aceptacion, fecha_cancelacion,
    booking_id, estado_servicio,
    id_driver, name_driver, id_user, name_user, id_company,
    type_service, moneda, pais, ciudad,
    costo_final, costo_estimado,
    cancel_lon, cancel_lat, end_lon, end_lat,
    minutos_entre_eventos, regla_tiempo,
    round(geoDistance(cancel_lon, cancel_lat, end_lon, end_lat), 2) AS distancia_cancel_destino,
    CASE
        WHEN geoDistance(cancel_lon, cancel_lat, end_lon, end_lat) <= 450
        THEN 'CANCELA_CERCA'
        ELSE 'CANCELA_LEJOS'
    END AS regla_cancelacion
FROM base
WHERE rn = 1
"""

# ══════════════════════════════════════════════════════════════
# 3. EJECUTAR QUERY
# ══════════════════════════════════════════════════════════════
def ejecutar_query() -> pd.DataFrame:
    print("Conectando a ClickHouse...")
    result = client.query(QUERY)
    df = pd.DataFrame(result.result_rows, columns=result.column_names)
    print(f"Servicios cargados: {len(df):,}")
    return df

# ══════════════════════════════════════════════════════════════
# 4. MOTOR DE DECISIÓN
# ══════════════════════════════════════════════════════════════
def clasificar_vectorizado(df: pd.DataFrame) -> pd.DataFrame:
    flag_tiempo    = df['regla_tiempo']      == 'Evasion'
    flag_distancia = df['regla_cancelacion'] == 'CANCELA_CERCA'
    sin_gps        = df['cancel_lon'].isna() | df['cancel_lat'].isna()

    import numpy as np
    condiciones = [
        flag_tiempo & flag_distancia,
        flag_tiempo & sin_gps,
        flag_tiempo | flag_distancia,
    ]
    opciones = [
        'EVASION CONFIRMADA',
        'EVASION PROBABLE',
        'EVASION PROBABLE',
    ]
    df['veredicto'] = np.select(condiciones, opciones, default='OK')
    df['nivel']     = np.select(condiciones, [3, 2, 2],  default=0)

    df['flags'] = ''
    df.loc[flag_tiempo,    'flags'] += df.loc[flag_tiempo,    'minutos_entre_eventos'].astype(str) + ' min | '
    df.loc[flag_distancia, 'flags'] += df.loc[flag_distancia, 'distancia_cancel_destino'].astype(str) + 'm del destino | '
    df.loc[sin_gps,        'flags'] += 'sin GPS | '
    df['flags'] = df['flags'].str.rstrip(' | ')

    return df

# 🔥 FIX AQUÍ (NUEVO)
def limpiar_nan_json(df: pd.DataFrame) -> pd.DataFrame:
    import numpy as np
    return df.replace({np.nan: None})

# ══════════════════════════════════════════════════════════════
# 5. LIMPIEZA TIMEZONE
# ══════════════════════════════════════════════════════════════
def limpiar_timezones(df: pd.DataFrame) -> pd.DataFrame:
    for col in df.select_dtypes(include=['datetimetz']).columns:
        df[col] = df[col].dt.tz_localize(None)
    return df

# ══════════════════════════════════════════════════════════════
# 6. EXPORTAR EXCEL (TODO IGUAL)
# ══════════════════════════════════════════════════════════════
# 👉 TODO TU BLOQUE EXPORTAR COMPLETO SE MANTIENE IGUAL
# (no lo recorto aquí porque ya lo tienes y no lo tocamos)

# ══════════════════════════════════════════════════════════════
# 7. PIPELINE PRINCIPAL
# ══════════════════════════════════════════════════════════════
def correr():
    df = ejecutar_query()
    print("Clasificando servicios...")
    df = clasificar_vectorizado(df)

    # 🔥 AQUÍ SE ARREGLA EL PROBLEMA DEL DASHBOARD
    df = limpiar_nan_json(df)

    print(f"Clasificación lista. Generando Excel...")
    exportar(df)
# ══════════════════════════════════════════════════════════════
# DASHBOARD
# ══════════════════════════════════════════════════════════════
import os
from flask import send_from_directory

@app.route("/")
def index():
    return send_from_directory(".", "dashboard.html")

@app.route("/dashboard.html")
def dashboard():
    return send_from_directory(".", "dashboard.html")
# ══════════════════════════════════════════════════════════════
# 8. MAIN
# ══════════════════════════════════════════════════════════════
if __name__ == "__main__":
    correr()

# ══════════════════════════════════════════════════════════════
# cd C:\Users\Picap\Documents\AUTOMATIZACIONES\CONCILIACIONES
# ══════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════════════════════════════════
##---Para correrlo ejecutar en powersheell-->> python Automatizacion_evasion_de_comisiones.py
# ═══════════════════════════════════════════════════════════════════════════════════════════