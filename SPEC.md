# SPEC — Proyecto Felix (v1)

> Estado: borrador v1 para aprobación · Fecha: 2026-11-16
> Arquitectura y plan de construcción: [docs/arquitectura.md](docs/arquitectura.md)

## 1. Objetivo

App tipo Uber que conecta **veterinarios a domicilio** con **dueños de mascotas** (personas naturales) en todo Chile y para todas las especies. Parte de la comisión de la app va a **fundaciones de animales** elegidas por el dueño.

- **Contexto:** proyecto de portafolio, **diseñado como si fuera producción**: RLS, auditoría y cumplimiento de la Ley 21.719. Al inicio usa solo datos de prueba, nunca datos reales.
- **Presupuesto cero:** solo los niveles gratuitos de cada servicio. **Los pagos y las suscripciones son simulados** (no se mueve dinero).
- **Plataformas:** Android, Web y Windows se prueban en el MVP. iPhone queda listo en el código y se prueba después (requiere un Mac).

## 2. Usuarios y roles

| Rol | Qué hace |
|---|---|
| **Dueño** | Registra sus mascotas y direcciones, pide visitas urgentes o agendadas, paga (simulado), se suscribe, dona, califica y controla quién ve la ficha clínica de cada mascota. |
| **Veterinario** | Se registra, sube su título y carnet, queda pendiente hasta que lo aprueban, define disponibilidad, especies y especialidades, acepta o rechaza solicitudes, escribe en la ficha clínica y califica a dueños. |
| **Fundación** | Ve sus aportes recibidos y su total (usuarios miembros de la fundación, solo lectura). |
| **Administrador** | Aprueba o rechaza veterinarios, gestiona fundaciones, catálogos (especies, especialidades, tarifas, planes, clínicas 24 h) y parámetros económicos, modera calificaciones y ve métricas. |

Un usuario tiene un solo rol en el MVP. Los roles se guardan en el servidor (nunca en `user_metadata`).

## 3. Reglas de negocio (valores por defecto, todos configurables por el admin)

| Tema | Regla |
|---|---|
| Radio de urgencia | Expansivo: **5 → 10 → 20 km**. |
| Oferta de urgencia | Por **tandas de 3** veterinarios (orden: distancia, luego calificación), **60 s** por tanda. El primero que acepta se queda con la visita; las demás ofertas de la tanda se anulan. |
| Sin aceptación | Tras agotar el radio de 20 km o **10 min** en total: la solicitud se cierra **sin costo** y se ofrece (a) agendar con la primera hora libre de un vet compatible o (b) la lista de clínicas 24 h de la región. |
| Elegibilidad de vet | Aprobado, **en línea**, ubicación actualizada hace < 2 min, sin otra visita activa, atiende la especie y la especialidad pedidas. |
| Tarifa | `base(especie, especialidad)` + recargo urgencia (**30 %** de la base) + recargo distancia (**$500/km** sobre 5 km) − descuento de suscripción. Montos en CLP enteros. |
| Comisión | **15 %** del precio del servicio; de esa comisión, **20 %** va a la fundación elegida (si no elige, a la fundación por defecto). Ejemplo: visita $30.000 → comisión $4.500 → fundación $900 → vet $25.500. |
| Donación extra | Opcional, 100 % a la fundación elegida. |
| Cancelación del dueño | Gratis: agendada hasta **2 h** antes; urgente antes de que el vet marque "en camino". Después: cargo de **$5.000** (simulado). |
| Cancelación del vet | Sin cargo monetario. Baja su tasa de cumplimiento; sobre **3 cancelaciones en 30 días** el admin recibe una alerta. |
| Confirmación de agendada | El vet debe aceptar antes de 12 h o 2 h antes de la hora, lo que ocurra primero; si no responde, la solicitud expira y se avisa al dueño. |
| Calificaciones | Bidireccionales, de 1 a 5 estrellas y comentario de hasta 500 caracteres, solo para visitas completadas y dentro de 7 días. Se publican cuando ambos calificaron o al cumplirse el plazo. El admin puede ocultar comentarios. |
| Planes | **Básico** (10 % de descuento, 1 preventiva al año, 1 mascota, $4.990/mes) · **Plus** (20 %, 2 preventivas, sin recargo de urgencia, 1 mascota, $9.990/mes) · **Familia** (como Plus, hasta 4 mascotas, $14.990/mes). |
| Acceso a ficha clínica | El vet que atiende la ve desde que acepta hasta **30 días** después de cerrar la visita. El dueño puede dar acceso extra con fecha de vencimiento y revocarlo cuando quiera. |
| Escritura en ficha | Diagnósticos, vacunas y atenciones: solo un vet con acceso vigente. El dueño puede agregar notas y adjuntos, marcados como "aportado por el dueño". **Nada se borra**: se corrige creando una versión nueva. |
| Dirección del dueño | Los vets que reciben una oferta solo ven la comuna y la distancia aproximada. La dirección exacta la ve solo el vet asignado, y deja de verla al cerrar la visita. |
| Ubicación en vivo | La posición del vet se comparte solo mientras la visita está "en camino" y no se guarda el recorrido. |
| Login | Email y contraseña (con confirmación del email) y Google. |

## 4. Historias de usuario y criterios de aceptación

Cada criterio es verificable con un test (pgTAP, unitario, de widget o de integración); el tipo de test va entre corchetes.

### F1. Registro, perfiles y verificación

- **HU1.1** Como dueño quiero registrarme con email o Google para pedir visitas.
  - [int] Al registrarse con email, la cuenta no puede iniciar sesión hasta confirmar el correo.
  - [int] Al registrarse, el usuario acepta los **términos (contrato)**; queda en `terms_acceptances` con versión y fecha. Se le **muestra la política de privacidad** (deber de información) y queda en `privacy_notice_views`. El consentimiento (`consents`) se pide solo para tratamientos opcionales, nunca como condición del servicio.
  - [pgTAP] Un dueño solo puede leer y editar su propio perfil, sus mascotas y sus direcciones (con otro usuario la consulta devuelve 0 filas).
  - [widget] El formulario pide solo: nombre para mostrar, teléfono y comuna. No pide RUT, fecha de nacimiento ni género.
- **HU1.2** Como dueño quiero registrar mis mascotas con especie, raza, sexo, fecha de nacimiento aproximada y microchip opcional.
  - [pgTAP] La especie debe existir y estar activa en el catálogo.
  - [widget] Al elegir una especie, la lista de razas se filtra por esa especie.
- **HU1.3** Como veterinario quiero registrarme y subir mi título y carnet para quedar habilitado.
  - [int] El vet queda en estado `pending` y no aparece en búsquedas ni recibe ofertas.
  - [pgTAP] Los documentos van a un bucket privado. Solo los leen el propio vet y el admin; otro vet o un dueño recibe un error o 0 filas.
  - [widget] No se pide RUT (no hay pagos reales). Del carnet se pide solo el anverso. La identidad se verifica visualmente y queda solo `identity_verified_at` + `verified_by`.
  - [unit] Solo se aceptan PDF, JPG y PNG de hasta 5 MB.
- **HU1.4** Como admin quiero aprobar o rechazar veterinarios desde un panel.
  - [int] Aprobar cambia el estado a `approved` y le avisa al vet. Rechazar exige un motivo.
  - [pgTAP] Solo el rol admin puede cambiar `vet_profiles.status`. Cada cambio queda en `admin_audit_log`.
  - [pgTAP] 7 días después de la resolución (30 si el rechazo se apela), un job borra los documentos de Storage y conserva solo los metadatos de verificación (quién, cuándo, resultado y tipo de documento).
- **HU1.5** Como vet aprobado quiero definir mis especies, especialidades, horario semanal y días libres.
  - [pgTAP] Los bloques de un mismo día no pueden solaparse.
  - [widget] Desde su pantalla principal el vet puede ponerse "en línea" o "fuera de línea".

**Terminado F1:** registro y login (email y Google) funcionan en Android, Web y Windows · aprobación de vets de punta a punta · tests pgTAP de RLS de perfiles, mascotas y documentos en verde · CI en verde.

### F2. Pedir visita: urgente y agendada

- **HU2.1 (urgente)** Como dueño quiero pedir una visita urgente para una mascota y una dirección, y que la tome un vet cercano.
  - [pgTAP] La primera tanda incluye solo vets elegibles a ≤ 5 km, como máximo 3, ordenados por distancia y luego por calificación.
  - [pgTAP] Si en 60 s ninguno acepta, se ofrece a la siguiente tanda sin repetir vets. Agotados los candidatos de un radio, se pasa al radio siguiente (10 km y luego 20 km).
  - [pgTAP] Si dos vets aceptan al mismo tiempo, solo uno queda asignado y el otro recibe "ya tomada" (test de concurrencia).
  - [pgTAP] Pasados 10 min o agotado el radio de 20 km, la visita queda `no_vet_found` y no genera cobro.
  - [widget] Con `no_vet_found`, la app muestra las opciones "Agendar primera hora libre" y "Clínicas 24 h".
  - [pgTAP] Un vet con una oferta pendiente ve la comuna y la distancia redondeada a 0,5 km, nunca la dirección ni las coordenadas exactas.
  - [int] Cuando la visita está "en camino", el dueño ve al vet moverse en el mapa (Realtime). Al llegar o cancelar, se deja de compartir la ubicación.
- **HU2.2 (agendada)** Como dueño quiero elegir un vet, un día y una hora disponibles.
  - [pgTAP] No se pueden crear dos visitas activas que se solapen para el mismo vet (restricción de exclusión, que incluye un margen de traslado de 30 min).
  - [pgTAP] Solo se ofrecen horas dentro de la disponibilidad del vet, fuera de sus días libres y con al menos 2 h de anticipación.
  - [pgTAP] Si el vet no confirma dentro del plazo, la solicitud expira automáticamente.
- **HU2.3 (estados)** Como dueño y como vet quiero ver el estado de la visita.
  - [unit + pgTAP] Solo se permiten las transiciones de la máquina de estados (ver arquitectura §5). Una transición inválida falla con un error explícito.
  - [int] Cada cambio de estado relevante envía un push por FCM en Android y Web. En Windows se avisa dentro de la app.
  - [unit] El payload del push lleva solo `visit_id` y el tipo de evento, sin nombre de mascota, dirección ni datos clínicos (FCM pasa por Google).
  - [pgTAP] El teléfono del dueño, igual que la dirección, solo lo ve el vet asignado entre `accepted` y el cierre de la visita.

**Terminado F2:** ambos modos funcionan de punta a punta con datos semilla de 20 vets en 3 ciudades · tests de despacho y concurrencia en verde · mapa funcionando con Google Maps (Android/Web) y con OpenStreetMap (Windows), cambiando solo la configuración.

### F3. Ficha clínica con acceso controlado

- **HU3.1** Como vet asignado quiero ver el historial, las vacunas, los diagnósticos y los adjuntos de la mascota.
  - [pgTAP] Un vet sin acceso vigente (sin visita, con el acceso vencido o revocado) obtiene 0 filas o un error en cada tabla y función de la ficha.
  - [pgTAP] El acceso nace al aceptar la visita y vence 30 días después de cerrarla.
  - [pgTAP] Cada lectura de la ficha (función `get_pet_record`) inserta una fila en `record_access_log` con el actor, la mascota, la acción y la fecha.
- **HU3.2** Como vet quiero registrar atenciones, vacunas (con fecha de próxima dosis) y diagnósticos, con especie y especialidad.
  - [pgTAP] No existen `UPDATE` ni `DELETE` sobre las entradas clínicas. Una corrección crea una entrada nueva con `supersedes_id`, y el historial muestra la versión vigente y la anterior.
  - [pgTAP] Cada escritura queda en `record_access_log` con la acción `create` o `correct`.
- **HU3.3** Como dueño quiero autorizar a un vet a ver la ficha por un tiempo y revocar ese acceso.
  - [pgTAP] Al revocar, el siguiente intento de lectura del vet falla de inmediato.
  - [widget] El dueño ve quién tiene acceso, hasta cuándo, y el registro de quién vio o editó la ficha.
- **HU3.4** Como dueño quiero agregar notas y adjuntos.
  - [pgTAP] Las entradas del dueño quedan marcadas con `author_role = 'owner'` y no pueden ser de tipo diagnóstico ni vacuna.
  - [unit] Los adjuntos aceptan PDF, JPG y PNG de hasta 5 MB (las imágenes se comprimen en el cliente).

**Terminado F3:** suite pgTAP de la matriz de acceso a la ficha (dueño, vet con acceso, vet sin acceso, vet vencido, vet revocado, admin y anónimo) en verde · revisión del agente Privacy Engineer sin hallazgos altos abiertos.

### F4. Pagos simulados y fundaciones

- **HU4.1** Como dueño quiero ver el desglose del precio antes de confirmar y pagar (simulado).
  - [pgTAP] La función `quote_visit` calcula base, recargos, descuento, comisión, parte de la fundación, monto para el vet y donación. El ejemplo de $30.000 da comisión $4.500, fundación $900 y vet $25.500.
  - [pgTAP] El precio se calcula solo en el servidor. Si el cliente manda montos, se ignoran.
  - [pgTAP] El precio cotizado queda congelado en la visita. Si el admin cambia la configuración después, la visita conserva su precio.
- **HU4.2** Como dueño quiero elegir la fundación y agregar una donación extra.
  - [pgTAP] Al completar el pago se crean los aportes (`commission_share` y `donation`) asociados a la fundación.
- **HU4.3** Como fundación quiero ver mi total y el detalle por mes.
  - [pgTAP] Un miembro de una fundación solo ve los aportes de la suya, sin datos de dueños: solo la fecha, el monto y el tipo.
- **HU4.4** Como admin quiero cambiar la comisión, el % para la fundación, los recargos, el cargo por cancelación y las tarifas.
  - [pgTAP] La configuración se versiona con `effective_from` y la anterior no se modifica.

**Terminado F4:** tests de tabla de precios (al menos 15 casos, con suscripción, preventiva, urgencia y distancia) en verde · panel de la fundación muestra totales correctos con datos semilla.

### F5. Suscripciones simuladas

- **HU5.1** Como dueño quiero suscribirme a un plan y asociar mascotas.
  - [pgTAP] Se respeta `max_pets` del plan y un dueño solo tiene una suscripción activa a la vez.
- **HU5.2** Como suscriptor quiero que mis beneficios se apliquen solos.
  - [pgTAP] Se aplica el descuento a la base, se omite el recargo de urgencia si el plan lo incluye y una visita preventiva incluida tiene base $0 y descuenta del cupo anual. Agotado el cupo, se cobra normal.
- **HU5.3** Como suscriptor quiero cancelar mi plan.
  - [pgTAP] Los beneficios siguen hasta el fin del período pagado (simulado).

**Terminado F5:** los 3 planes semilla funcionan y los beneficios se reflejan en `quote_visit` con sus tests.

### F6. Cobertura y catálogos

- **HU6.1** Como admin quiero editar especies, razas, especialidades, la relación especie–especialidad, tarifas y clínicas 24 h.
  - [pgTAP] Solo el admin escribe en los catálogos; los demás roles solo leen los ítems activos.
  - [pgTAP] Desactivar una especie no borra mascotas ni fichas existentes.
- **HU6.2** Cobertura nacional: el catálogo semilla incluye las 16 regiones y sus comunas, al menos 8 especies (perro, gato, conejo, hurón, aves, reptiles, roedores, equinos) y al menos 10 especialidades.

**Terminado F6:** semillas cargadas y validadas con tests · panel del admin para los catálogos operativo.

### F7. Calificaciones y cancelaciones

- **HU7.1** [pgTAP] Solo los participantes de una visita completada pueden calificar, una vez cada uno y dentro de 7 días.
- **HU7.2** [pgTAP] La calificación no se ve hasta que ambos calificaron o se cumplió el plazo.
- **HU7.3** [pgTAP] Las cancelaciones aplican la regla de cargo según el estado y la hora, y el cargo queda como pago simulado.
- **HU7.4** [pgTAP] Con 3 o más cancelaciones de un vet en 30 días se genera una alerta en el panel del admin.

**Terminado F7:** las reglas de calificaciones y cancelaciones están cubiertas por tests.

### F8. Privacidad y derechos (Ley 21.719)

- **HU8.1** Como dueño quiero descargar mis datos (portabilidad).
  - [int] La exportación genera un JSON con su perfil, mascotas, fichas, visitas y consentimientos, y queda registrada.
- **HU8.2** Como dueño quiero borrar mi cuenta.
  - [pgTAP] Al pedirlo, se acusa recibo de inmediato, la cuenta queda **bloqueada** (sin tratamiento) y se revocan las sesiones. Hay un período de gracia cancelable de **15 días**, y siempre se ejecuta dentro del plazo legal de respuesta.
  - [pgTAP] Se borran el perfil, las direcciones, las mascotas, las notas y adjuntos del dueño, los objetos de Storage, los tokens, las calificaciones hechas **y recibidas**, `cancel_reason` y el microchip. Las visitas y los pagos quedan anonimizados (sin el dueño, la mascota ni la dirección; se conservan la comuna, la especie y los montos) y los totales de las fundaciones no cambian.
  - [pgTAP] Las entradas escritas por vets quedan desvinculadas (`pet_id` y dueño nulos; se conservan especie, fecha, tipo y contenido) con `retain_until` = +5 años. Solo el vet autor puede consultarlas mediante una solicitud registrada, y un job las borra al vencer.
  - [pgTAP] Un job idempotente recorre `deletion_targets` (BD, Storage, FCM, logs). Al final, un escaneo por `user_id` y `pet_id` verifica que no queden datos, y se registra lo borrado y lo retenido con su motivo.
- **HU8.3** Como usuario quiero ver y retirar consentimientos opcionales (por ejemplo, comunicaciones). La ubicación necesaria para el servicio se basa en el contrato, no en el consentimiento.
  - [pgTAP] Retirar un consentimiento queda registrado con fecha y la app deja de usar ese tratamiento.
- **HU8.4** [int] La app muestra la política de privacidad con su versión. Si cambia, se informa al usuario. Solo se pide un consentimiento nuevo si aparece una finalidad opcional nueva.
- **HU8.5** Como vet o miembro de una fundación quiero ejercer los mismos derechos (exportar, rectificar, borrar).
  - [pgTAP] Si un vet borra su cuenta, sus entradas clínicas se conservan con el autor seudonimizado ("MV verificado"): la ficha del dueño no pierde la autoría clínica.
- **HU8.6** [pgTAP] Ni las fundaciones ni los vets ven el plan contratado ni el historial de pagos de un dueño (posible dato socioeconómico). El microchip solo lo ven el dueño y un vet con acceso vigente.

**Terminado F8:** las pruebas de exportación y borrado pasan con datos semilla · el informe del agente Privacy Engineer está archivado en `docs/privacidad.md` con sus hallazgos cerrados o aceptados.

## 5. Fuera de alcance (MVP)

- Dinero real, pasarelas de pago (Webpay, Mercado Pago), boletas y facturas electrónicas (SII).
- **Escaneo de microchips** (solo evaluación de factibilidad, ver §7).
- Chat entre dueño y vet, videollamada y telemedicina.
- Recetas electrónicas o venta de medicamentos.
- Multi-rol (un usuario que sea dueño y vet a la vez).
- App para Mac y Linux; publicación en tiendas (Play Store y App Store).
- Integración con el Registro Nacional de Mascotas.
- Verificación automática de títulos (se hace a mano).
- SMS u OTP por teléfono (tienen costo).

## 6. Definición general de "terminado" (aplica a toda función)

1. Cumple todos sus criterios de aceptación, cada uno con su test automatizado en verde.
2. `flutter analyze` sin advertencias · `flutter test` en verde · `supabase test db` en verde · `supabase db advisors` sin hallazgos de seguridad.
3. RLS habilitada en toda tabla nueva, con un test pgTAP que pruebe el acceso permitido y el denegado.
4. Ningún secreto en el repo (revisión con `git grep` y `.gitignore` de `.env*`).
5. Funciona en Android, Web y Windows (iPhone: compila en CI cuando haya un Mac disponible).
6. Textos en español de Chile y accesibilidad básica (etiquetas semánticas y contraste AA).
7. Decisiones nuevas registradas en MEMORIA-PROYECTO.

## 7. Factibilidad: escaneo de microchips (no entra al MVP)

**Problema:** los microchips de animales usan 134,2 kHz (ISO 11784/11785, FDX-B). El NFC del celular trabaja a 13,56 MHz y **no puede leerlos**.

| Opción | Pros | Contras | Costo aprox. |
|---|---|---|---|
| **A. Ingreso manual del número (15 dígitos)** | Costo cero, funciona en todas las plataformas, se valida el formato (código de país 152 = Chile, o código de fabricante) | Lento y propenso a errores; requiere otro lector para ver el número | $0 |
| **B. Lector USB o Bluetooth en modo teclado (HID)** | El lector "escribe" el número en el campo de texto: **no requiere código especial**. Funciona en Windows, Web y Android (USB OTG o BT HID) | Hay que comprar el lector; calidad variable en el mercado chino | USD 20–60 (AliExpress) |
| **C. Lector BLE con protocolo propio** | Lectura directa en la app, mejor experiencia | Cada modelo tiene su protocolo (sin estándar) y requiere integración con `flutter_blue_plus` por modelo. La web BLE no funciona en iOS | USD 40–120 + desarrollo |
| **D. Consulta al Registro Nacional de Mascotas (Ley 21.020)** | Identificaría al dueño registrado | **No hay una API pública documentada.** Hacer scraping del sitio es frágil y riesgoso legalmente (datos personales de terceros). Requiere un convenio con la SUBDERE | $0, pero depende de un convenio |

**Recomendación:** en una fase posterior al MVP, implementar **A + B** juntas: un campo con validación ISO y compatibilidad con lectores en modo teclado. Agregar un registro de "animales comunitarios y colonias" propio de cada fundación (número de chip, foto, ubicación aproximada de la colonia, estado sanitario), sin datos de personas. Para el registro nacional, solo un enlace a su consulta pública, abierto por el usuario, sin automatizar. La opción C se evalúa si una fundación concreta ya tiene un lector BLE.

**Registro de colonias (post-MVP, por privacidad):** ubicación redondeada (~500 m o a nivel de comuna), sin texto libre sobre personas y con revisión de fotos (personas o patentes). Si un chip tiene dueño registrado, solo se guarda el aviso "tiene dueño", sin sus datos. Los datos de cuidadores, solo con su consentimiento.

## 8. Supuestos y decisiones pendientes

**Valores propuestos por defecto (no definidos en la entrevista):**

- Las tarifas base y los precios de los planes son de ejemplo.
- Recargo de urgencia de 30 %, $500/km sobre 5 km y cargo de cancelación de $5.000.
- El vet tiene 12 h para confirmar una visita agendada; margen de traslado de 30 min.

**Decisiones tomadas tras la revisión de privacidad (2026-11-16):**

- **P1 (aprobada).** Al borrar la cuenta del dueño, las entradas escritas por el vet se conservan **5 años desvinculadas** del dueño (sin dueño, nombre de mascota ni dirección; con especie, fecha, tipo y contenido), por defensa ante reclamos (prescripción, art. 2515 del Código Civil). Acceso solo del vet autor, previa solicitud registrada. Las notas y adjuntos del dueño se borran.
- **P2 (aprobada).** El período de gracia del borrado baja a **15 días**, con la cuenta bloqueada.
- **P3. Puntos legales marcados "a verificar"** (numeración de artículos, plazos, decisiones automatizadas, EIPD, Ley 21.431 de plataformas): se listan en `docs/privacidad.md` para confirmarlos con el texto en bcn.cl o con un abogado antes de un piloto real.
