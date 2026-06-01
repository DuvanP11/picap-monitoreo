# Setup MINTIC v1 — Extractor de facturas desde Google Drive

Script: `procesar_facturas_mintic.py`

Conecta directo al Drive vía Service Account (sin OAuth, sin abrir navegador,
ideal para correr scheduled). Lista los PDFs en una carpeta compartida,
extrae los campos y genera el Excel.

---

## Paso 1 — Crear Google Cloud Project (1 vez)

1. Andá a https://console.cloud.google.com/
2. Arriba a la izquierda, clic en el selector de proyecto → **NEW PROJECT**
3. Nombre: `pibox-mintic-facturas` (o el que quieras)
4. Crear → seleccionar el proyecto creado

## Paso 2 — Habilitar Google Drive API

1. Menú izquierdo → **APIs & Services → Library**
2. Buscar **Google Drive API** → clic → **ENABLE**

## Paso 3 — Crear Service Account

1. **APIs & Services → Credentials**
2. Clic en **+ CREATE CREDENTIALS → Service account**
3. Nombre: `mintic-reader`
4. **Create and continue**
5. Role: dejar vacío (no necesita roles a nivel de proyecto, solo permisos en la carpeta de Drive). Clic en **Continue** → **Done**

## Paso 4 — Descargar la llave JSON

1. En la lista de Service Accounts, clic sobre el que creaste
2. Pestaña **KEYS** → **ADD KEY → Create new key**
3. Tipo: **JSON** → **Create**
4. Se descarga un archivo `pibox-mintic-facturas-xxxxxx.json`
5. **Guardalo en:**
   ```
   C:\Users\Picap\Documents\AUTOMATIZACIONES\AUTOMATIZACIONES\dashboards\picap_evasion_dashboard\mintic_facturas\credentials\service_account.json
   ```
6. Anotá el email del Service Account (algo como `mintic-reader@pibox-mintic-facturas.iam.gserviceaccount.com`). Lo necesitás en el paso 5.

> ⚠️ Este JSON da acceso a todo lo que el Service Account pueda leer.
> **NO lo subas a git.** Ya está cubierto por `.gitignore` (ver abajo).

## Paso 5 — Compartir la carpeta del Drive con el Service Account

1. En Google Drive, andá a la carpeta donde están los PDFs
   (la que en tu screenshot está como `Compartido conmigo → PDF → Marzo`)
2. Clic derecho → **Share** (Compartir)
3. Pegar el email del Service Account (paso 4.6)
4. Permiso: **Viewer** (suficiente para leer)
   - Si querés usar `--upload` para subir el Excel resultante, dale **Editor**.
5. ✅ Listo

## Paso 6 — Conseguir el FOLDER_ID

1. Abrí la carpeta en Drive desde el navegador
2. Mirá la URL: `https://drive.google.com/drive/folders/1abcDEF_xyz123…`
3. La parte después de `/folders/` es el **FOLDER_ID**

## Paso 7 — Configurar el script

Editá `procesar_facturas_mintic.py` y reemplazá la línea:

```python
FOLDER_ID = os.environ.get(
    "MINTIC_FOLDER_ID",
    "PEGAR_AQUI_EL_FOLDER_ID",  # ← reemplazar
)
```

por el ID real. **O** definí una env var de Windows:

```powershell
setx MINTIC_FOLDER_ID "1abcDEF_xyz123…"
```

(reabrí la terminal para que tome efecto).

## Paso 8 — Probar

```powershell
cd "C:\Users\Picap\Documents\AUTOMATIZACIONES\AUTOMATIZACIONES\dashboards\picap_evasion_dashboard\mintic_facturas"
python procesar_facturas_mintic.py --limit 3
```

Deberías ver algo como:

```
🔑 Autenticando con Service Account: …/credentials/service_account.json
📂 Listando PDFs en carpeta 1abcDEF_xyz123… …
   Encontrados: 3 PDF(s)
   [  1/3] 901381198-01-EXP-00000506.pdf … ✓ EXP506  $629.400
   [  2/3] 901381198-01-EXP-00000507.pdf … ✓ EXP507  $XYZ
   …
📊 Generando Excel: facturas_pibox_extraidas.xlsx
✅ Listo.
```

## Uso normal

```powershell
# Procesar TODOS los PDFs de la carpeta
python procesar_facturas_mintic.py

# Procesar y subir el Excel al mismo Drive
python procesar_facturas_mintic.py --upload

# Output custom
python procesar_facturas_mintic.py --output "Reporte_MINTIC_2026_03.xlsx"

# Procesar otra carpeta sin tocar el script
python procesar_facturas_mintic.py --folder-id <OTRO_ID>
```

---

## Seguridad

- El JSON del Service Account debe quedarse **solo en tu PC**.
- Ya hay un `.gitignore` que excluye `credentials/` del repo.
- Si subiste el JSON por error: rotarlo desde Google Cloud Console → Service Accounts → Keys → Delete + Create new key.

## Troubleshooting

**"❌ No encuentro el JSON del Service Account en: …"**
- Verificá que el archivo esté en `credentials/service_account.json`.

**"⚠️ La carpeta está vacía o el Service Account no tiene acceso."**
- ¿Compartiste la carpeta con el email del Service Account? (paso 5)
- ¿FOLDER_ID correcto? Probá `--folder-id <ID>` directo.

**"HttpError 403: insufficientPermissions"**
- El SA no tiene permiso suficiente. Si solo lees → Viewer.
  Si querés `--upload` → Editor.

**"HttpError 404: File not found"**
- FOLDER_ID inválido o carpeta no compartida con el SA.
