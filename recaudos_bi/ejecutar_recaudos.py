"""
Wrapper de ejecución automática del generador de Recaudos BI.

Uso: doble-click en este archivo (o `python ejecutar_recaudos.py` desde cualquier shell).

Configurá la sección CONFIG abajo con las fechas y el output del mes que quieras
generar. Cuando termine, abre el Excel resultante automáticamente.

Si querés correr varios meses seguidos, duplicá la llamada a generar() al final.
"""
from __future__ import annotations

import os
import sys
import subprocess
from pathlib import Path

# UTF-8 en Windows
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass


# ═══════════════════════════════════════════════════════════════════════════
# CONFIG — editá los valores acá según el mes que quieras correr
# ═══════════════════════════════════════════════════════════════════════════

# Rango para AMBAS queries (Recaudos + Transacciones).
# Si querés rangos distintos, completá las 4 vars y dejá DESDE/HASTA en None.
DESDE = "2026-04-01"
HASTA = "2026-04-30"

# Override por query (None = usa DESDE/HASTA de arriba)
RECAUDOS_DESDE = None
RECAUDOS_HASTA = None
TX_DESDE       = None
TX_HASTA       = None

# Nombre del archivo de salida
OUTPUT = "Saldo Recaudos al 30 de abril 2026.xlsx"

# Credenciales ClickHouse (env vars o hardcodeadas acá).
# Si las dejás vacías, lee las env vars MINTIC_CH_HOST/USER/PASS.
CH_HOST = os.environ.get("MINTIC_CH_HOST", "https://clickhouse.picap.io:8443")
CH_USER = os.environ.get("MINTIC_CH_USER", "dperilla")
CH_PASS = os.environ.get("MINTIC_CH_PASS", "")  # ponela acá si querés (mejor env var)

# Abrir el Excel automáticamente al terminar
ABRIR_AL_TERMINAR = True


# ═══════════════════════════════════════════════════════════════════════════
# Lógica (no tocar)
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR = Path(__file__).parent
GENERADOR  = SCRIPT_DIR / "generar_recaudos.py"


def generar(
    desde=None, hasta=None,
    recaudos_desde=None, recaudos_hasta=None,
    tx_desde=None, tx_hasta=None,
    output=None,
):
    """Ejecuta generar_recaudos.py con los args dados. Devuelve la ruta del .xlsx."""
    args = [sys.executable, str(GENERADOR)]
    if desde:           args += ["--desde", desde]
    if hasta:           args += ["--hasta", hasta]
    if recaudos_desde:  args += ["--recaudos-desde", recaudos_desde]
    if recaudos_hasta:  args += ["--recaudos-hasta", recaudos_hasta]
    if tx_desde:        args += ["--tx-desde", tx_desde]
    if tx_hasta:        args += ["--tx-hasta", tx_hasta]
    if output:          args += ["--output", output]

    env = os.environ.copy()
    if CH_HOST: env["MINTIC_CH_HOST"] = CH_HOST
    if CH_USER: env["MINTIC_CH_USER"] = CH_USER
    if CH_PASS: env["MINTIC_CH_PASS"] = CH_PASS

    if not env.get("MINTIC_CH_PASS"):
        print("❌ Falta MINTIC_CH_PASS. Editá CH_PASS arriba o setealo como env var.")
        return None

    print(f"🚀 Ejecutando: {' '.join(args[1:])}")
    print()
    result = subprocess.run(args, env=env, cwd=str(SCRIPT_DIR))
    if result.returncode != 0:
        print(f"❌ El generador retornó código {result.returncode}")
        return None

    out_path = SCRIPT_DIR / (output or "")
    return out_path if out_path.exists() else None


def main():
    print("═══════════════════════════════════════════════════════════════════════════")
    print(" GENERADOR AUTOMATICO — SALDO RECAUDOS BI")
    print("═══════════════════════════════════════════════════════════════════════════")
    print(f"  Rango común:        {DESDE} → {HASTA}")
    print(f"  Override Recaudos:  {RECAUDOS_DESDE or '(usa rango común)'} → {RECAUDOS_HASTA or '(usa rango común)'}")
    print(f"  Override Tx:        {TX_DESDE or '(usa rango común)'} → {TX_HASTA or '(usa rango común)'}")
    print(f"  Output:             {OUTPUT}")
    print()

    out = generar(
        desde=DESDE, hasta=HASTA,
        recaudos_desde=RECAUDOS_DESDE, recaudos_hasta=RECAUDOS_HASTA,
        tx_desde=TX_DESDE,             tx_hasta=TX_HASTA,
        output=OUTPUT,
    )
    if not out:
        print()
        input("Presioná Enter para cerrar…")
        return 1

    print()
    print(f"✅ Listo: {out}")

    if ABRIR_AL_TERMINAR:
        print("📂 Abriendo Excel…")
        try:
            os.startfile(str(out))
        except Exception as e:
            print(f"   (no pude abrirlo: {e})")

    print()
    input("Presioná Enter para cerrar…")
    return 0


if __name__ == "__main__":
    sys.exit(main())
