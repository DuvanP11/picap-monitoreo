# app/services/motivo_mapper.rb
# Mapea texto libre de motivo de bloqueo al motivo oficial más cercano.
# Replica mapear_motivo() de api.py Python.
# Quita tildes (NFD) para hacer match insensible a acentos.

module MotivoMapper
  # Mapeo keyword → motivo oficial.
  # IMPORTANTE: el orden importa — se evalúa de arriba abajo y se devuelve
  # el primer match. Las keywords más específicas van primero.
  KEYWORDS_MOTIVOS = [
    [["cobrar dos", "doble cobro", "dos veces", "diferentes medios de pago"],      "Cobrar dos o más veces el mismo servicio"],
    [["cobros adicionales", "cobro adicional"],                                    "Realizar cobros adicionales no acordados"],
    [["no cumplir con la totalidad"],                                              "No cumplir con la totalidad del servicio"],
    [["fake gps", "modificar la ubicacion", "finaliza el servicio", "modificar ubicacion"], "Modificar ubicación de destino (Fake GPS)"],
    [["no devolver el vehiculo", "arrendataria"],                                  "No devolver vehículo al arrendatario"],
    [["cobrar el valor del servicio en tarjeta", "cobrar en tc", "picash y no realizarlo"], "Cobrar en TC/Pica$h y no realizar el servicio"],
    [["no prestar el servicio por no aceptar el metodo de pago", "no aceptar el metodo de pago"], "No prestar servicio por método de pago"],
    [["cobro excesivo", "tarifa excesiva", "cobro excesivo en la tarifa"],         "Cobro excesivo en tarifa"],
    [["vehiculo diferente", "vehiculo registrado"],                                "Servicio con vehículo diferente al registrado"],
    [["preguntar el lugar de destino y negarse"],                                  "Preguntar destino y negarse a prestar servicio"],
    [["vocabulario adecuado", "agente de servicio al cliente", "no manejar un vocabulario"], "Vocabulario inadecuado con agente SAC"],
    [["no devolver", "dinero que sobre", "efectivo"],                              "No devolver dinero sobrante al usuario"],
    [["solicitar al usuario", "cancelar el servicio para no prestarlo"],           "Solicitar al usuario cancelar para no prestar"],
    [["no pagar el valor del servicio al usuario prestador"],                      "No pagar valor del servicio al prestador"],
    [["cancelar los servicios para evitar pagar la comision", "evadir comision", "cancelar servicios para"], "Cancelar servicios para evadir comisión"],
    [["insultar al usuario prestador"],                                            "Insultar al usuario prestador"],
    [["bonificacion por cancelacion", "solicitar al usuario consumidor cancelar el servicio y si realizarlo"], "Solicitar cancelación para generar bonificación"],
    [["cancelar servicios de forma reiterada"],                                    "Cancelar servicios de forma reiterada"],
    [["comercializar o vender saldos", "picash entre"],                            "Comercializar saldos Pica$h"],
    [["insultar o amenazar", "chat del servicio"],                                 "Insultar o amenazar por chat"],
    [["documento que no corresponda"],                                             "Registrar documento que no corresponde"],
    [["cuenta nueva cuando se haya cancelado", "crear una cuenta nueva"],          "Crear cuenta nueva con cuenta cancelada"],
    [["fraude dentro de la app", "realizar cualquier fraude"],                     "Fraude dentro de la APP"],
    [["estafa dentro de la app", "realizar cualquier estafa"],                     "Estafa dentro de la APP"],
    [["alterar cualquier documento", "datos registrados en la app"],               "Alterar documentos o datos en la APP"],
    [["prestar o alquilar su cuenta", "cuenta de otro usuario"],                   "Prestar o alquilar cuenta personal"],
    [["hurtar las pertenencias", "hurtar"],                                        "Hurtar pertenencias del usuario"],
    [["amenazar o atentar contra", "atentar contra de la vida"],                   "Amenazar contra la vida del usuario"],
    [["arma de fuego", "arma blanca", "elemento que pueda atentar"],               "Portar armas al prestar el servicio"],
    [["mal estado al destinatario"],                                               "Entregar paquete en mal estado"],
    [["no entregar el paquete al destinatario el mismo dia"],                      "No entregar paquete el mismo día"],
    [["paquete incompleto"],                                                       "Entregar paquete incompleto"],
    [["direccion equivocada"],                                                     "Entregar paquete en dirección equivocada"],
    [["no entregar el dinero recaudado a pibox"],                                  "No entregar dinero recaudado a Pibox"],
    [["no entregar el paquete al destinatario"],                                   "No entregar paquete al destinatario"],
    [["apropiarse del paquete"],                                                   "Apropiarse del paquete"],
    [["sustancia ilicita", "peligrosa"],                                           "Solicitar envío de sustancias ilícitas"],
    [["comparendo d12"],                                                           "Presentar comparendo D12 fraudulento"],
    [["no finalizar el servicio en el lugar de destino"],                          "No finalizar servicio en destino"],
    [["negarse a prestar el soat", "soat"],                                        "Negarse a presentar SOAT en accidente"],
    [["malas practicas en la prestacion del servicio"],                            "Malas prácticas en prestación del servicio"],
    [["normas basicas de seguridad", "casco", "chaleco reflectivo"],               "No cumplir normas de seguridad (casco/chaleco)"],
    [["normas de transito", "maniobras peligrosas"],                               "Conducción peligrosa o sin respetar tránsito"],
    [["hostigar", "comportamiento vulgar", "obsceno"],                             "Hostigar/molestar con comportamiento vulgar"],
    [["evidencias de haber realizado el servicio", "no tomar correctamente las evidencias"], "No tomar evidencias del servicio"],
    [["accion de mejora"],                                                         "Incumplir acción de mejora propuesta"],
    [["horario establecido"],                                                      "Incumplir horario establecido"],
    [["no asistir al servicio programado"],                                        "No asistir al servicio programado"],
    [["insultar al cliente"],                                                      "Insultar al cliente"],
    [["no entregar el paquete"],                                                   "No entregar paquete"],
    [["no entregar del recaudo"],                                                  "No entregar recaudo del paquete"],
    [["servicios corporativos"],                                                   "Malas prácticas en servicios corporativos"],
    [["antecedentes penales"],                                                     "Tener antecedentes penales"],
  ].freeze

  PAISES_MAP = {
    "CO" => "Colombia", "MX" => "México", "NI" => "Nicaragua",
    "GT" => "Guatemala", "PE" => "Perú", "EC" => "Ecuador",
  }.freeze

  # Quita tildes (descomposición NFD + elimina caracteres combinantes)
  def self.normalizar(texto)
    return "" if texto.nil?
    texto.to_s.downcase.unicode_normalize(:nfd).gsub(/[̀-ͯ]/, "")
  end

  # Mapea texto libre al motivo oficial más cercano.
  # Si no hay match, devuelve el texto recortado a 80 chars.
  # Si está vacío, devuelve nil.
  def self.mapear(texto)
    return nil if texto.nil? || texto.to_s.strip.empty?
    t_norm = normalizar(texto.strip)
    KEYWORDS_MOTIVOS.each do |keywords, motivo|
      keywords.each do |kw|
        return motivo if t_norm.include?(normalizar(kw))
      end
    end
    # Sin match → primeros 80 chars del texto original
    texto.length > 80 ? "#{texto[0, 80]}…" : texto
  end

  # Resuelve el motivo según el tipo de usuario (prioridad distinta).
  def self.mapear_segun_tipo(tipo_usuario, comentario_driver:, comentario_user:, comentario_expulsion_user:)
    candidatos = if tipo_usuario.to_s == "PILOTO"
      [comentario_driver, comentario_user, comentario_expulsion_user]
    else
      [comentario_user, comentario_expulsion_user, comentario_driver]
    end
    raw = candidatos.map(&:to_s).map(&:strip).find { |x| !x.empty? }
    mapear(raw)
  end
end
