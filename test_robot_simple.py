"""
════════════════════════════════════════════════════════════════════════════════
TEST ROBOT PIBOX - CON DATOS SIMULADOS
Valida TODOS los tracks sin necesidad de conectar a ClickHouse
════════════════════════════════════════════════════════════════════════════════
"""

from trump_foto_validator import TrumpFotoValidator

# Configuración de umbrales
TIEMPO_MINIMO_SERVICIO = 5  # minutos
TOLERANCIA_GPS = 0.001  # ~100 metros
MONTOS_ALERTA = {
    'carry_carga_moto': 400000,
    'cruz_verde_mostrador': 80000
}


def validar_servicio_test(booking_id: str, datos_simulados: dict):
    """Valida un servicio con datos simulados (sin ClickHouse)"""
    
    print("="*80)
    print(f"VALIDACIÓN COMPLETA - Servicio: {booking_id}")
    print("="*80)
    
    print(f"\n📊 Datos del servicio (simulados):")
    print(f"   Piloto: {datos_simulados['piloto_nombre']}")
    print(f"   Cliente: {datos_simulados['cliente_nombre']}")
    print(f"   Monto: ${datos_simulados['monto_pagado']:,.0f}")
    print(f"   Duración: {datos_simulados['minutos_servicio']} min")
    print(f"   GPS: Origen({datos_simulados['lat_origen']}, {datos_simulados['lon_origen']})")
    print(f"        Destino({datos_simulados['lat_destino']}, {datos_simulados['lon_destino']})")
    
    # Inicializar lista de alertas
    alertas = []
    
    # ═══════════════════════════════════════════════════════════════
    # TRACK 1: VALIDAR TIEMPO DE SERVICIO
    # ═══════════════════════════════════════════════════════════════
    print(f"\n⏱️  TRACK 1: Validando tiempo de servicio...")
    
    minutos = datos_simulados['minutos_servicio']
    if minutos < TIEMPO_MINIMO_SERVICIO:
        alerta = {
            'tipo': 'Tiempo de servicio',
            'severidad': 'ALTA',
            'observacion': f"Servicio completado en {minutos} min (menos de {TIEMPO_MINIMO_SERVICIO} min)"
        }
        alertas.append(alerta)
        print(f"   🚨 ALERTA: {alerta['observacion']}")
    else:
        print(f"   ✅ Tiempo válido: {minutos} min")
    
    # ═══════════════════════════════════════════════════════════════
    # TRACK 2: VALIDAR RECORRIDO GPS
    # ═══════════════════════════════════════════════════════════════
    print(f"\n📍 TRACK 2: Validando recorrido GPS...")
    
    # Calcular distancia
    diff_lat = abs(datos_simulados['lat_origen'] - datos_simulados['lat_destino'])
    diff_lon = abs(datos_simulados['lon_origen'] - datos_simulados['lon_destino'])
    mismo_punto = diff_lat < TOLERANCIA_GPS and diff_lon < TOLERANCIA_GPS
    
    print(f"   Diferencia latitud: {diff_lat:.6f}°")
    print(f"   Diferencia longitud: {diff_lon:.6f}°")
    
    if mismo_punto:
        alerta = {
            'tipo': 'Recorrido GPS',
            'severidad': 'CRÍTICA',
            'observacion': f'Mismo punto de origen y destino (diff lat: {diff_lat:.6f}, lon: {diff_lon:.6f})'
        }
        alertas.append(alerta)
        print(f"   🚨 ALERTA: {alerta['observacion']}")
    else:
        print(f"   ✅ Recorrido válido (hubo desplazamiento)")
    
    # ═══════════════════════════════════════════════════════════════
    # TRACK 3: VALIDAR EVIDENCIAS FOTOGRÁFICAS
    # ═══════════════════════════════════════════════════════════════
    print(f"\n📸 TRACK 3: Validando evidencias fotográficas...")
    
    try:
        robot = TrumpFotoValidator(headless=True)
        robot.iniciar_navegador()
        
        # Intentar usar cookies guardadas
        if not robot.cargar_cookies():
            robot.hacer_login()
        
        # Validar fotos del servicio
        resultado_fotos = robot.validar_servicio(booking_id)
        
        # Agregar alertas de fotos
        if resultado_fotos.get('alertas'):
            for alerta_foto in resultado_fotos['alertas']:
                alertas.append(alerta_foto)
                print(f"   🚨 ALERTA [{alerta_foto['severidad']}]: {alerta_foto['observacion']}")
        else:
            print(f"   ✅ Evidencias fotográficas válidas")
        
        robot.cerrar()
        
    except Exception as e:
        print(f"   ❌ Error validando fotos: {e}")
        alertas.append({
            'tipo': 'Error técnico',
            'severidad': 'MEDIA',
            'observacion': f'No se pudieron validar fotos: {str(e)[:100]}'
        })
    
    # ═══════════════════════════════════════════════════════════════
    # TRACK 4: VALIDAR PAGOS
    # ═══════════════════════════════════════════════════════════════
    print(f"\n💰 TRACK 4: Validando montos de pago...")
    
    service_type = datos_simulados.get('service_type_cd')
    cliente_nombre = str(datos_simulados.get('cliente_nombre', '')).lower()
    monto = datos_simulados.get('monto_pagado', 0)
    
    alertas_pago = []
    
    # Validar servicios Carry/Carga/Moto
    if service_type in [1, 2, 3]:
        if monto > MONTOS_ALERTA['carry_carga_moto']:
            alerta = {
                'tipo': 'Validación de pago',
                'severidad': 'ALTA',
                'observacion': f'Monto excesivo ${monto:,.0f} para servicio tipo {service_type} (límite: ${MONTOS_ALERTA["carry_carga_moto"]:,.0f})'
            }
            alertas.append(alerta)
            alertas_pago.append(alerta)
    
    # Validar Cruz Verde Mostrador
    if 'cruz verde mostrador' in cliente_nombre:
        if monto > MONTOS_ALERTA['cruz_verde_mostrador']:
            alerta = {
                'tipo': 'Validación de pago',
                'severidad': 'ALTA',
                'observacion': f'Monto excesivo ${monto:,.0f} para Cruz Verde Mostrador (límite: ${MONTOS_ALERTA["cruz_verde_mostrador"]:,.0f})'
            }
            alertas.append(alerta)
            alertas_pago.append(alerta)
    
    if alertas_pago:
        for alerta in alertas_pago:
            print(f"   🚨 ALERTA: {alerta['observacion']}")
    else:
        print(f"   ✅ Monto válido: ${monto:,.0f}")
    
    # ═══════════════════════════════════════════════════════════════
    # RESUMEN FINAL
    # ═══════════════════════════════════════════════════════════════
    print("\n" + "="*80)
    print("RESUMEN FINAL DE VALIDACIÓN")
    print("="*80)
    
    if alertas:
        print(f"\n🚨 TOTAL DE ALERTAS: {len(alertas)}\n")
        
        # Agrupar por severidad
        criticas = [a for a in alertas if a.get('severidad') == 'CRÍTICA']
        altas = [a for a in alertas if a.get('severidad') == 'ALTA']
        medias = [a for a in alertas if a.get('severidad') == 'MEDIA']
        
        if criticas:
            print(f"⛔ CRÍTICAS ({len(criticas)}):")
            for a in criticas:
                print(f"   • [{a['tipo']}] {a['observacion']}")
        
        if altas:
            print(f"\n⚠️  ALTAS ({len(altas)}):")
            for a in altas:
                print(f"   • [{a['tipo']}] {a['observacion']}")
        
        if medias:
            print(f"\n📋 MEDIAS ({len(medias)}):")
            for a in medias:
                print(f"   • [{a['tipo']}] {a['observacion']}")
    else:
        print("\n✅ Sin alertas - Servicio válido")
    
    print("\n" + "="*80)
    
    return alertas


if __name__ == "__main__":
    # ════════════════════════════════════════════════════════════════
    # DATOS SIMULADOS DEL SERVICIO 688a4cfeff1a1da2867c3e1a
    # ════════════════════════════════════════════════════════════════
    
    booking_id = "688a4cfeff1a1da2867c3e1a"
    
    # Estos datos simulan el servicio fraudulento que mencionaste:
    # - Tiempo: 8 minutos (OK - no alerta)
    # - GPS: Mismo punto (ALERTA)
    # - Fotos: Sospechosas (ALERTA)
    # - Monto: Normal (OK - no alerta)
    
    datos_simulados = {
        'piloto_nombre': 'Piloto Sospechoso',
        'cliente_nombre': 'Cliente XYZ',
        'service_type_cd': 5,  # No es Carry/Carga/Moto
        'monto_pagado': 50000,  # Monto normal
        'minutos_servicio': 8.0,  # OK - más de 5 min
        
        # GPS: MISMO PUNTO (diferencia casi cero)
        'lat_origen': 6.244203,
        'lon_origen': -75.581211,
        'lat_destino': 6.244203,  # Igual que origen
        'lon_destino': -75.581211,  # Igual que origen
    }
    
    print("\n🔍 CASO DE PRUEBA: Servicio fraudulento")
    print("   - Tiempo: 8 min (pasa)")
    print("   - GPS: Mismo punto (ALERTA esperada)")
    print("   - Fotos: Sospechosas (ALERTA esperada)")
    print("   - Monto: Normal (pasa)")
    print()
    
    try:
        alertas = validar_servicio_test(booking_id, datos_simulados)
        
        print(f"\n✅ Test completado")
        print(f"   Total de alertas detectadas: {len(alertas)}")
        
    except KeyboardInterrupt:
        print("\n\n⚠️ Proceso interrumpido por el usuario")
    except Exception as e:
        print(f"\n❌ Error fatal: {e}")
        import traceback
        traceback.print_exc()
