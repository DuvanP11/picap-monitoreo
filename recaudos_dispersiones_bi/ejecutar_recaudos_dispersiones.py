"""
Wrapper de ejecución automática del generador "Recaudos y Dispersiones".

Uso: doble-click en este archivo (o `python ejecutar_recaudos_dispersiones.py` desde cualquier shell).
"""
from __future__ import annotations

import os
import sys
import subprocess
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass


# ═══════════════════════════════════════════════════════════════════════════
# CONFIG — editá los valores acá según el mes que quieras correr
# ═══════════════════════════════════════════════════════════════════════════

MES = "2026-04"
OUTPUT = None  # None = auto: "Recaudos y Dispersiones Abril 2026.xlsx"

CH_HOST = os.environ.get("MINTIC_CH_HOST", "https://clickhouse.picap.io:8443")
CH_USER = os.environ.get("MINTIC_CH_USER", "dperilla")
CH_PASS = os.environ.get("MINTIC_CH_PASS", "")

ABRIR_AL_TERMINAR = True


# ═══════════════════════════════════════════════════════════════════════════
# Lógica
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR = Path(__file__).parent
GENERADOR  = SCRIPT_DIR / "generar_recaudos_dispersiones.py"


def generar(mes, output=None):
    args = [sys.executable, str(GENERADOR), "--mes", mes]
    if output:
        args += ["--output", output]

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

    if output:
        out_path = SCRIPT_DIR / output
    else:
        meses_es = {"01": "Enero", "02": "Febrero", "03": "Marzo", "04": "Abril",
                    "05": "Mayo", "06": "Junio", "07": "Julio", "08": "Agosto",
                    "09": "Septiembre", "10": "Octubre", "11": "Noviembre", "12": "Diciembre"}
        año, mes_n = mes.split("-")
        out_name = f"Recaudos y Dispersiones {meses_es[mes_n]} {año}.xlsx"
        out_path = SCRIPT_DIR / out_name

    return out_path if out_path.exists() else None


def main():
    print("═══════════════════════════════════════════════════════════════════════════")
    print(" GENERADOR AUTOMATICO — RECAUDOS Y DISPERSIONES (7 hojas)")
    print("═══════════════════════════════════════════════════════════════════════════")
    print(f"  Mes:    {MES}")
    print(f"  Output: {OUTPUT or '(auto)'}")
    print()

    out = generar(mes=MES, output=OUTPUT)
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
