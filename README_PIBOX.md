# 📦 Módulo Pibox B2B - Robot de Auditoría

## 🎯 Descripción

Sistema automatizado de detección de fraude para servicios B2B de Pibox. Valida **4 tracks** en tiempo real:

1. ⏱️ **Tiempo de servicio** - Detecta servicios anormalmente cortos
2. 📍 **Recorrido GPS** - Detecta servicios sin movimiento real
3. 📸 **Evidencia fotográfica** - Valida fotos de recogida/entrega usando robot web
4. 💰 **Validación de pagos** - Detecta montos excesivos

---

## 🚀 Características

✅ **Robot automatizado** - Navega Trump system y valida fotos sin intervención manual  
✅ **Multi-track** - 4 validaciones independientes por servicio  
✅ **Severidad graduada** - CRÍTICA / ALTA / MEDIA  
✅ **API REST** - Endpoints listos para integrar con dashboard  
✅ **Exportación Excel** - Genera reportes descargables  
✅ **Sesión persistente** - Reutiliza cookies para evitar re-login  

---

## 📁 Archivos

```
picap-monitoreo/
├── api.py                              # Backend con endpoints Pibox
├── trump_foto_validator.py             # Robot de validación de fotos
├── test_robot_simple.py                # Script de prueba (sin ClickHouse)
├── requirements.txt                    # Dependencias Python
├── INSTRUCCIONES_INTEGRACION_PIBOX.md  # Guía de integración en dashboard.html
└── README_PIBOX.md                     # Este archivo
```

---

## 🔧 Instalación

### 1. Dependencias

```bash
pip install selenium Pillow imagehash webdriver-manager
```

### 2. Credenciales Trump

El robot usa una cuenta de automatización:
- **Email:** `automatizador@gmail.com`
- **Contraseña:** `Picap2026*`
- **Sin 2FA** (cuenta específica para bots)

### 3. Configuración ClickHouse

Variables de entorno (ver `.env.example`):

```bash
CLICKHOUSE_HOST=clickhouse.picap.io
CLICKHOUSE_PORT=8443
CLICKHOUSE_USER=dperilla
CLICKHOUSE_PASSWORD=<solicitar al admin>
CLICKHOUSE_DATABASE=picapmongoprod
```

---

## 🧪 Testing

### Prueba standalone (SIN ClickHouse):

```bash
python test_robot_simple.py
```

Esto valida el servicio `688a4cfeff1a1da2867c3e1a` con datos simulados.

**Salida esperada:**
```
🚨 TOTAL DE ALERTAS: 2

⛔ CRÍTICAS (2):
   • [Recorrido GPS] Mismo punto de origen y destino
   • [Evidencia fotográfica] Las fotos son idénticas
```

---

## 📡 API Endpoints

### 1. Listar servicios

```http
GET /api/pibox/servicios?desde=2026-01-01&hasta=2026-01-31
```

Retorna servicios B2B filtrados por fecha.

### 2. Obtener alertas

```http
GET /api/pibox/alertas?desde=2026-01-01&hasta=2026-01-31&pais=CO
```

**Parámetros opcionales:**
- `pais`: Código del país (CO, MX, NI)
- `cliente`: Nombre del cliente
- `piloto`: Nombre del piloto

**Respuesta:**

```json
{
  "ok": true,
  "total": 2,
  "alertas": [
    {
      "booking_id": "688a4cfeff1a1da2867c3e1a",
      "piloto_nombre": "Juan Pérez",
      "cliente_nombre": "Cliente XYZ",
      "tipo_alerta": "Recorrido GPS",
      "severidad": "CRÍTICA",
      "observacion": "Mismo punto de origen y destino",
      "monto": 50000,
      "fecha_servicio": "2026-01-15 14:30:00"
    }
  ]
}
```

### 3. Exportar a Excel

```http
GET /api/pibox/export?desde=2026-01-01&hasta=2026-01-31
```

Descarga archivo `.xlsx` con todas las alertas.

---

## ⚙️ Configuración de Umbrales

En `api.py`, líneas 4623-4652:

```python
PIBOX_CONFIG = {
    'TIEMPO_MINIMO_SERVICIO': 5,  # minutos
    'TOLERANCIA_GPS': 0.001,       # ~100 metros
    'MONTOS_ALERTA': {
        'carry_carga_moto': 400000,        # COP
        'cruz_verde_mostrador': 80000      # COP
    },
    'EXCLUSIONES': {
        'clientes': ['tada', 'test', 'prueba', 'qa', 'onboarding'],
        'excepciones': ['cruz verde integración']
    }
}
```

---

## 🎨 Integración Frontend

Ver archivo `INSTRUCCIONES_INTEGRACION_PIBOX.md` para agregar:
- Item en sidebar
- Vista HTML con filtros y tabla
- JavaScript para llamadas API
- Permisos de rol

---

## 📊 Severidad de Alertas

| Severidad | Descripción | Color |
|-----------|-------------|-------|
| **CRÍTICA** | Evidencia clara de fraude (fotos idénticas, GPS sin movimiento) | 🔴 Rojo |
| **ALTA** | Comportamiento muy sospechoso (tiempo < 5min, montos excesivos) | 🟠 Ámbar |
| **MEDIA** | Requiere revisión manual (fotos diferentes pero sospechosas) | 🟣 Morado |

---

## 🤖 Funcionamiento del Robot

El robot (`trump_foto_validator.py`):

1. Inicia navegador Chrome en modo headless
2. Carga cookies guardadas o hace login
3. Navega a `https://trump.picap.app/trump/bookings/{booking_id}`
4. Busca secciones "Recogiendo paquete" / "Entregando paquete"
5. Descarga imágenes con cookies de sesión
6. Compara usando perceptual hashing (imagehash)
7. Genera alertas según similitud

**Umbrales de comparación:**
- Hash diff = 0 → IDÉNTICAS (CRÍTICA)
- Hash diff ≤ 5 → MUY SIMILARES (ALTA)
- Cualquier caso → REVISIÓN MANUAL (MEDIA)

---

## ⚠️ Notas Importantes

1. **Headless mode:** El robot corre en modo headless en producción para evitar ventanas emergentes
2. **Cookies persistentes:** Se guardan en `trump_session.pkl` para evitar re-login constante
3. **Manejo de errores:** Si el robot falla, se registra un error técnico pero las demás validaciones continúan
4. **Performance:** Cada validación de fotos toma ~15-20 segundos (navegación + descarga + análisis)

---

## 🔄 Próximas Mejoras (Fase 2)

- [ ] ML model para detectar "fotos de pies solamente"
- [ ] ML model para detectar "fotos de fachada solamente"
- [ ] OCR para verificar texto en fotos
- [ ] Procesamiento paralelo de múltiples servicios
- [ ] Background jobs con Celery/Redis
- [ ] Cache de resultados

---

## 👨‍💻 Autor

**Duvan Perilla**  
Data Automation/Operations Analyst @ Picap  
https://github.com/DuvanP11/picap-monitoreo

---

## 📜 Licencia

Uso interno de Picap
