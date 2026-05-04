"""
════════════════════════════════════════════════════════════════════════════════
ROBOT DE VALIDACIÓN DE FOTOS PIBOX - Sistema Trump de Picap
Automatiza la navegación en https://trump.picap.app para validar evidencias
════════════════════════════════════════════════════════════════════════════════

FLUJO:
1. Login con email + contraseña + clave dinámica (2FA)
2. Navega a cada servicio: /trump/bookings/{booking_id}
3. Extrae fotos de "Recogiendo paquete" y "Entregando paquete"
4. Compara y detecta patrones sospechosos

CREDENCIALES:
- Email: dperilla@pibox.app
- Password: 200028Louds+
- Clave dinámica: Se solicita al usuario durante ejecución
"""

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException, NoSuchElementException
import time
import requests
from PIL import Image
import imagehash
import io
import pickle
import os
from typing import List, Dict, Optional


class TrumpFotoValidator:
    """
    Robot que valida fotos de servicios Pibox en el sistema Trump.
    """
    
    BASE_URL = "https://trump.picap.app/trump"
    LOGIN_URL = "https://trump.picap.app/trump"
    EMAIL = "automatizador@gmail.com"
    PASSWORD = "Picap2026*"
    COOKIES_FILE = "trump_session.pkl"
    
    def __init__(self, headless: bool = False):
        """
        Inicializa el robot.
        
        Args:
            headless: Si True, corre sin interfaz gráfica
        """
        self.headless = headless
        self.driver = None
        self.session = requests.Session()
        self.sesion_activa = False
    
    
    def iniciar_navegador(self):
        """Inicia Chrome con configuración optimizada."""
        options = webdriver.ChromeOptions()
        
        if self.headless:
            options.add_argument('--headless')
        
        options.add_argument('--no-sandbox')
        options.add_argument('--disable-dev-shm-usage')
        options.add_argument('--disable-gpu')
        options.add_argument('--window-size=1920,1080')
        options.add_argument('user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36')
        
        # Deshabilitar detección de automatización
        options.add_experimental_option("excludeSwitches", ["enable-automation"])
        options.add_experimental_option('useAutomationExtension', False)
        
        self.driver = webdriver.Chrome(options=options)
        self.driver.implicitly_wait(10)
        
        print("✅ Navegador iniciado")
    
    
    def guardar_cookies(self):
        """Guarda cookies de sesión para reutilizar."""
        with open(self.COOKIES_FILE, 'wb') as f:
            pickle.dump(self.driver.get_cookies(), f)
        print("💾 Cookies guardadas")
    
    
    def cargar_cookies(self) -> bool:
        """
        Carga cookies guardadas para evitar re-login.
        
        Returns:
            True si cargó cookies exitosamente
        """
        if not os.path.exists(self.COOKIES_FILE):
            return False
        
        try:
            # Ir primero al dominio para poder cargar cookies
            self.driver.get(self.BASE_URL)
            time.sleep(2)
            
            with open(self.COOKIES_FILE, 'rb') as f:
                cookies = pickle.load(f)
            
            for cookie in cookies:
                self.driver.add_cookie(cookie)
            
            print("🍪 Cookies cargadas")
            
            # Verificar si la sesión sigue activa navegando a bookings
            self.driver.get(f"{self.BASE_URL}/bookings")
            time.sleep(3)
            
            # Si no redirige al login o a la raíz, la sesión está activa
            current_url = self.driver.current_url
            if "bookings" in current_url:
                self.sesion_activa = True
                print("✅ Sesión activa")
                return True
            else:
                print("⚠️ Sesión expirada")
                return False
                
        except Exception as e:
            print(f"❌ Error cargando cookies: {e}")
            return False
    
    
    def hacer_login(self, clave_dinamica: Optional[str] = None):
        """
        Realiza login en Trump sin autenticación 2FA.
        
        Usa el formulario inferior (Usuario + Contraseña solamente).
        
        Returns:
            True si login exitoso
        """
        try:
            print(f"🔐 Iniciando sesión en Trump...")
            print(f"   Usuario: {self.EMAIL}")
            
            # Ir a la página de login
            self.driver.get(self.LOGIN_URL)
            time.sleep(3)
            
            # Buscar el campo USUARIO (no Email)
            # Este es el formulario inferior que NO requiere clave dinámica
            usuario_field = None
            
            # Intentar encontrar el campo Usuario (puede tener diferentes atributos)
            selectores_usuario = [
                "//input[@placeholder='Usuario']",
                "//input[contains(@placeholder, 'Usuario')]",
                "(//input[@type='text'])[last()]",  # Último campo de texto
            ]
            
            for selector in selectores_usuario:
                try:
                    usuario_field = self.driver.find_element(By.XPATH, selector)
                    if usuario_field:
                        print("  ✓ Campo Usuario encontrado")
                        break
                except:
                    continue
            
            if not usuario_field:
                print("❌ No se encontró el campo Usuario")
                return False
            
            # Llenar Usuario
            usuario_field.clear()
            usuario_field.send_keys(self.EMAIL)
            print("  ✓ Usuario ingresado")
            time.sleep(1)
            
            # Buscar el campo Contraseña (NO clave dinámica)
            # Debe ser el campo con placeholder "Contraseña" específicamente
            password_field = None
            
            selectores_password = [
                "//input[@placeholder='Contraseña']",
                "//input[contains(@placeholder, 'Contraseña')]",
                "//input[@type='password' and not(contains(@placeholder, 'dinámica'))]",
            ]
            
            for selector in selectores_password:
                try:
                    password_field = self.driver.find_element(By.XPATH, selector)
                    if password_field:
                        print("  ✓ Campo Contraseña encontrado")
                        break
                except:
                    continue
            
            if not password_field:
                print("❌ No se encontró el campo Contraseña")
                return False
            
            password_field.clear()
            password_field.send_keys(self.PASSWORD)
            print("  ✓ Contraseña ingresada")
            time.sleep(1)
            
            # ENVIAR FORMULARIO con ENTER (NO llenar clave dinámica)
            print("  ⏳ Enviando formulario...")
            password_field.send_keys(Keys.RETURN)
            
            # Esperar respuesta del servidor
            print("  ⏳ Esperando respuesta del servidor...")
            time.sleep(8)
            
            # Verificar URL actual
            current_url = self.driver.current_url
            print(f"  📍 URL actual: {current_url}")
            
            # Si sigue en sessions (cualquier variante), el login falló
            if "/sessions" in current_url or current_url.endswith("/trump"):
                print("❌ Login fallido - verifica las credenciales")
                
                # Intentar capturar mensaje de error
                try:
                    error_msg = self.driver.find_element(By.CSS_SELECTOR, ".alert, .error, [class*='error'], [class*='alert']")
                    if error_msg and error_msg.text:
                        print(f"   ⚠️ Mensaje: {error_msg.text}")
                except:
                    pass
                
                return False
            
            # Si llegamos a /bookings o cualquier otra página, el login fue exitoso
            print("✅ Login exitoso - sesión iniciada")
            
            # Guardar cookies
            self.guardar_cookies()
            self.sesion_activa = True
            
            return True
            
        except Exception as e:
            print(f"❌ Error en login: {e}")
            print(f"   URL actual: {self.driver.current_url}")
            import traceback
            traceback.print_exc()
            return False
    
    
    def navegar_a_servicio(self, booking_id: str) -> bool:
        """
        Navega a un servicio específico.
        
        Args:
            booking_id: ID del servicio (ej: "688a4cfeff1a1da2867c3e1a")
            
        Returns:
            True si navegó exitosamente
        """
        try:
            url = f"{self.BASE_URL}/bookings/{booking_id}"
            print(f"🔍 Navegando a servicio {booking_id}...")
            
            self.driver.get(url)
            time.sleep(3)
            
            # Verificar que la página cargó (buscar elementos característicos)
            try:
                WebDriverWait(self.driver, 10).until(
                    EC.presence_of_element_located((
                        By.XPATH, 
                        "//h2[contains(text(), 'Datos básicos')] | " +
                        "//div[contains(text(), 'Formulario')] | " +
                        "//h2[contains(text(), 'Recogiendo')] | " +
                        "//h2[contains(text(), 'Entregando')]"
                    ))
                )
                print(f"✅ Servicio {booking_id} cargado")
                return True
            except TimeoutException:
                print(f"⚠️ Servicio {booking_id} no encontrado o sin acceso")
                return False
                
        except Exception as e:
            print(f"❌ Error navegando al servicio: {e}")
            return False
    
    
    def extraer_urls_fotos(self) -> Dict[str, List[str]]:
        """
        Extrae URLs de fotos de "Recogiendo paquete" y "Entregando paquete".
        
        Returns:
            Dict con 'recogida' y 'entrega', cada uno con lista de URLs
        """
        fotos = {
            'recogida': [],
            'entrega': []
        }
        
        try:
            # Scroll down para que las imágenes se carguen
            self.driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")
            time.sleep(2)
            
            # ESTRATEGIA 1: Buscar por texto exacto
            print("  🔍 Buscando secciones de fotos...")
            
            # Buscar sección "Recogiendo paquete"
            selectores_recogida = [
                "//h2[contains(text(), 'Recogiendo paquete')]",
                "//h3[contains(text(), 'Recogiendo paquete')]",
                "//div[contains(text(), 'Recogiendo paquete')]",
                "//p[contains(text(), 'Recogiendo paquete')]",
                "//*[contains(text(), 'Recogiendo')]",
                "//*[contains(text(), 'recogiendo')]",
            ]
            
            seccion_recogida = None
            for selector in selectores_recogida:
                try:
                    seccion_recogida = self.driver.find_element(By.XPATH, selector)
                    if seccion_recogida:
                        print(f"  ✓ Sección 'Recogiendo' encontrada con: {selector[:50]}")
                        break
                except:
                    continue
            
            if seccion_recogida:
                # Buscar imágenes cercanas a esa sección
                try:
                    # Buscar en el contenedor padre
                    parent = seccion_recogida.find_element(By.XPATH, "./ancestor::div[1]")
                    imgs_recogida = parent.find_elements(By.TAG_NAME, "img")
                    
                    for img in imgs_recogida:
                        src = img.get_attribute('src')
                        if src and ('http' in src or 'blob:' in src or 'data:' in src):
                            fotos['recogida'].append(src)
                    
                    print(f"  📸 {len(fotos['recogida'])} foto(s) de recogida")
                except Exception as e:
                    print(f"  ⚠️ Error extrayendo fotos de recogida: {e}")
            else:
                print("  ⚠️ No se encontró sección 'Recogiendo paquete'")
            
            # Buscar sección "Entregando paquete"
            selectores_entrega = [
                "//h2[contains(text(), 'Entregando paquete')]",
                "//h3[contains(text(), 'Entregando paquete')]",
                "//div[contains(text(), 'Entregando paquete')]",
                "//p[contains(text(), 'Entregando paquete')]",
                "//*[contains(text(), 'Entregando')]",
                "//*[contains(text(), 'entregando')]",
            ]
            
            seccion_entrega = None
            for selector in selectores_entrega:
                try:
                    seccion_entrega = self.driver.find_element(By.XPATH, selector)
                    if seccion_entrega:
                        print(f"  ✓ Sección 'Entregando' encontrada con: {selector[:50]}")
                        break
                except:
                    continue
            
            if seccion_entrega:
                try:
                    parent = seccion_entrega.find_element(By.XPATH, "./ancestor::div[1]")
                    imgs_entrega = parent.find_elements(By.TAG_NAME, "img")
                    
                    for img in imgs_entrega:
                        src = img.get_attribute('src')
                        if src and ('http' in src or 'blob:' in src or 'data:' in src):
                            fotos['entrega'].append(src)
                    
                    print(f"  📸 {len(fotos['entrega'])} foto(s) de entrega")
                except Exception as e:
                    print(f"  ⚠️ Error extrayendo fotos de entrega: {e}")
            else:
                print("  ⚠️ No se encontró sección 'Entregando paquete'")
            
            # ESTRATEGIA 2: Si no encontró nada, buscar TODAS las imágenes
            if not fotos['recogida'] and not fotos['entrega']:
                print("  🔍 Estrategia alternativa: buscando todas las imágenes...")
                all_imgs = self.driver.find_elements(By.TAG_NAME, "img")
                print(f"  📊 Total de imágenes en la página: {len(all_imgs)}")
                
                # Mostrar las primeras 5 URLs para debugging
                for i, img in enumerate(all_imgs[:5]):
                    src = img.get_attribute('src')
                    alt = img.get_attribute('alt')
                    print(f"    Img {i+1}: src={src[:50] if src else 'None'}, alt={alt}")
            
        except Exception as e:
            print(f"❌ Error extrayendo fotos: {e}")
        
        return fotos
    
    
    def descargar_imagen(self, url: str) -> Optional[Image.Image]:
        """
        Descarga una imagen desde URL.
        
        Args:
            url: URL de la imagen
            
        Returns:
            Objeto PIL Image o None si falla
        """
        try:
            # Copiar cookies del navegador a la sesión requests
            cookies = self.driver.get_cookies()
            for cookie in cookies:
                self.session.cookies.set(cookie['name'], cookie['value'])
            
            # Agregar headers realistas
            headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                'Referer': self.BASE_URL
            }
            
            response = self.session.get(url, headers=headers, timeout=15)
            
            if response.status_code == 200:
                img = Image.open(io.BytesIO(response.content))
                return img
            else:
                print(f"⚠️ Error descargando imagen: HTTP {response.status_code}")
                return None
                
        except Exception as e:
            print(f"❌ Error descargando imagen: {e}")
            return None
    
    
    def comparar_imagenes(self, img1: Image.Image, img2: Image.Image) -> Dict:
        """
        Compara dos imágenes usando hashing perceptual.
        
        Args:
            img1: Primera imagen
            img2: Segunda imagen
            
        Returns:
            Dict con resultado de la comparación
        """
        try:
            # Calcular hashes perceptuales
            hash1 = imagehash.average_hash(img1, hash_size=8)
            hash2 = imagehash.average_hash(img2, hash_size=8)
            
            # Calcular diferencia (0 = idénticas, >10 = muy diferentes)
            diferencia = hash1 - hash2
            
            resultado = {
                'son_identicas': diferencia == 0,
                'son_muy_similares': diferencia <= 5,
                'son_similares': diferencia <= 10,
                'diferencia_hash': int(diferencia),
                'hash1': str(hash1),
                'hash2': str(hash2)
            }
            
            return resultado
            
        except Exception as e:
            print(f"❌ Error comparando imágenes: {e}")
            return {'error': str(e)}
    
    
    def validar_servicio(self, booking_id: str) -> Dict:
        """
        Valida las fotos de un servicio completo.
        
        Args:
            booking_id: ID del servicio
            
        Returns:
            Dict con alertas detectadas
        """
        alertas = []
        
        # Navegar al servicio
        if not self.navegar_a_servicio(booking_id):
            return {
                'booking_id': booking_id,
                'error': 'No se pudo cargar el servicio',
                'alertas': []
            }
        
        # Extraer URLs de fotos
        fotos = self.extraer_urls_fotos()
        
        # Validar que existan fotos
        if not fotos['recogida']:
            alertas.append({
                'tipo': 'Evidencia fotográfica',
                'severidad': 'ALTA',
                'observacion': 'Falta foto de recogida del paquete'
            })
        
        if not fotos['entrega']:
            alertas.append({
                'tipo': 'Evidencia fotográfica',
                'severidad': 'ALTA',
                'observacion': 'Falta foto de entrega del paquete'
            })
        
        # Si faltan fotos, retornar inmediatamente
        if not fotos['recogida'] or not fotos['entrega']:
            return {
                'booking_id': booking_id,
                'alertas': alertas,
                'fotos_encontradas': {
                    'recogida': len(fotos['recogida']),
                    'entrega': len(fotos['entrega'])
                }
            }
        
        # Descargar y comparar imágenes
        print("  📥 Descargando imágenes...")
        img_recogida = self.descargar_imagen(fotos['recogida'][0])
        img_entrega = self.descargar_imagen(fotos['entrega'][0])
        
        if not img_recogida or not img_entrega:
            alertas.append({
                'tipo': 'Evidencia fotográfica',
                'severidad': 'MEDIA',
                'observacion': 'No se pudieron descargar las fotos para análisis'
            })
            return {
                'booking_id': booking_id,
                'alertas': alertas,
                'fotos_encontradas': {
                    'recogida': len(fotos['recogida']),
                    'entrega': len(fotos['entrega'])
                }
            }
        
        # Comparar imágenes
        print("  🔍 Analizando imágenes...")
        comparacion = self.comparar_imagenes(img_recogida, img_entrega)
        
        # Siempre generar alerta de fotos sospechosas
        # Las fotos de servicios B2B deben mostrar el paquete claramente
        if comparacion.get('son_identicas'):
            alertas.append({
                'tipo': 'Evidencia fotográfica',
                'severidad': 'CRÍTICA',
                'observacion': 'Las fotos de recogida y entrega son idénticas (posible fraude)',
                'detalle': f"Diferencia hash: {comparacion['diferencia_hash']}"
            })
        elif comparacion.get('son_muy_similares'):
            alertas.append({
                'tipo': 'Evidencia fotográfica',
                'severidad': 'ALTA',
                'observacion': f'Las fotos de recogida y entrega son muy similares (diferencia: {comparacion["diferencia_hash"]})',
                'detalle': 'Posible foto duplicada o tomada en el mismo lugar'
            })
        else:
            # Incluso si las fotos son diferentes, marcar para revisión manual
            alertas.append({
                'tipo': 'Evidencia fotográfica',
                'severidad': 'MEDIA',
                'observacion': 'Fotos requieren revisión manual de evidencia',
                'detalle': f'Las fotos son diferentes pero deben verificarse manualmente (diferencia hash: {comparacion["diferencia_hash"]})'
            })
        
        # TODO: Implementar detección de patrones específicos
        # - Detectar solo pies del piloto (requiere ML)
        # - Detectar solo fachada de tienda (requiere ML)
        # - Validar que el paquete sea visible
        
        return {
            'booking_id': booking_id,
            'alertas': alertas,
            'fotos_encontradas': {
                'recogida': len(fotos['recogida']),
                'entrega': len(fotos['entrega'])
            },
            'analisis_completado': True
        }
    
    
    def procesar_lote(self, booking_ids: List[str], clave_dinamica: Optional[str] = None) -> List[Dict]:
        """
        Procesa un lote de servicios.
        
        Args:
            booking_ids: Lista de booking_ids a procesar
            clave_dinamica: Código 2FA (se solicita si no se proporciona)
            
        Returns:
            Lista de resultados de validación
        """
        # Iniciar navegador
        if not self.driver:
            self.iniciar_navegador()
        
        # Intentar cargar sesión guardada
        if not self.cargar_cookies():
            # Si no hay sesión, hacer login
            if not self.hacer_login(clave_dinamica):
                print("❌ No se pudo iniciar sesión")
                return []
        
        resultados = []
        
        print(f"\n{'='*80}")
        print(f"PROCESANDO {len(booking_ids)} SERVICIOS")
        print(f"{'='*80}\n")
        
        for i, booking_id in enumerate(booking_ids, 1):
            print(f"\n[{i}/{len(booking_ids)}] 📦 Servicio: {booking_id}")
            print("-" * 60)
            
            resultado = self.validar_servicio(booking_id)
            resultados.append(resultado)
            
            # Mostrar resumen inmediato
            if resultado.get('error'):
                print(f"  ❌ Error: {resultado['error']}")
            elif resultado['alertas']:
                print(f"  ⚠️ {len(resultado['alertas'])} alerta(s) detectadas:")
                for alerta in resultado['alertas']:
                    print(f"    • [{alerta['severidad']}] {alerta['observacion']}")
            else:
                print(f"  ✅ Sin alertas - Fotos válidas")
            
            # Pausa entre servicios
            if i < len(booking_ids):
                time.sleep(2)
        
        return resultados
    
    
    def cerrar(self):
        """Cierra el navegador y limpia recursos."""
        if self.driver:
            self.driver.quit()
            print("\n✅ Navegador cerrado")


# ════════════════════════════════════════════════════════════════════════════
# EJEMPLO DE USO
# ════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    # Crear robot (headless=False para ver el navegador)
    robot = TrumpFotoValidator(headless=False)
    
    # Servicios a validar
    servicios_test = [
        "688a4cfeff1a1da2867c3e1a",  # Ejemplo de la imagen
        # Agregar más booking_ids aquí
    ]
    
    try:
        # Procesar servicios
        # Si ya tienes una clave dinámica, pásala como argumento:
        # resultados = robot.procesar_lote(servicios_test, clave_dinamica="527311")
        
        # Si no, el robot te la pedirá interactivamente:
        resultados = robot.procesar_lote(servicios_test)
        
        # Mostrar resumen final
        print("\n" + "="*80)
        print("RESUMEN FINAL DE VALIDACIÓN")
        print("="*80)
        
        total_servicios = len(resultados)
        servicios_con_alertas = len([r for r in resultados if r['alertas']])
        total_alertas = sum(len(r['alertas']) for r in resultados)
        
        print(f"\n📊 Servicios procesados: {total_servicios}")
        print(f"⚠️  Servicios con alertas: {servicios_con_alertas}")
        print(f"🚨 Total de alertas: {total_alertas}")
        
        # Detalle por servicio
        print("\n" + "-"*80)
        for res in resultados:
            print(f"\n📦 {res['booking_id']}")
            if res.get('error'):
                print(f"   ❌ {res['error']}")
            elif res['alertas']:
                for alerta in res['alertas']:
                    print(f"   [{alerta['severidad']}] {alerta['observacion']}")
            else:
                print("   ✅ Sin alertas")
        
    finally:
        # Cerrar navegador
        robot.cerrar()
