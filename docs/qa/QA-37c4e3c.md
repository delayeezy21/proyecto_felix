# QA — versión 37c4e3c (2026-11-24)
**Veredicto:** APROBADA CON OBSERVACIONES
**Alcance:** fase 8, urgencias (SPEC F2: HU2.1 completa y, de HU2.3, push y teléfono). Son la rama `fase-8` en `37c4e3c` sobre master `850f40d`:
- backend `3103799`: migración `20261124213036_urgent_dispatch.sql`, Edge Function `send-push`, pgTAP `150_urgent_dispatch` y E2E `urgencias_e2e`;
- app `c7cd5d8`: `lib/ui/features/urgent/`, `urgent_repository.dart`, los servicios `live_location_service`, `device_location`, `push_service` y `clock`, y el paquete `geolocator`;
- el arreglo O-F7-c (`850f40d`).

**Entorno:**
- Un solo stack aislado, `felix-qa-557` (puertos 557xx), levantado desde una copia de `supabase/` en el scratchpad, con `PUSH_PROVIDER = "fake"` en `[edge_runtime.secrets]`.
- Se excluyeron studio, imgproxy, logflare, vector, supavisor y postgres-meta, por la memoria. Mailpit quedó arriba, así que `auth_e2e` corrió completo. `edge_runtime` quedó `Up` desde el inicio.
- Todo corrió en secuencia. Al final se bajó el stack con `stop --no-backup`.
- El stack compartido `proyecto-felix` (5432x) estaba detenido y siguió así: 0 contenedores antes y después.

## Suites automáticas
| Suite | Resultado | Evidencia |
|---|---|---|
| `dart format --set-exit-if-changed lib test` | OK | 144 archivos, 0 cambios |
| `flutter analyze` | OK | No issues found (incluye el smoke nuevo) |
| `flutter test -j 1` | OK 320/320 | All tests passed |
| pgTAP (`supabase test db`) | OK 645/645 (17 archivos) | Corrió sobre el stack recién creado. `150_urgent_dispatch` OK |
| `supabase db advisors` | OK | No issues found |
| `node --test supabase/functions/send-push/providers.test.ts` | OK 5/5 | |
| `urgencias_e2e` | OK 49/49 | E2E fase 8: TODO OK |
| `visitas_e2e` | OK 73/73 | E2E fase 6: TODO OK |
| `ficha_e2e` | OK 65/65 | E2E fase 7: TODO OK |
| `auth_e2e` | OK 22/22 | E2E: TODO OK |
| `precios_e2e` (al final, tras borrar mis datos y restaurar `pricing_config`) | OK 48/48 | E2E fase 5: TODO OK |
| **`qa_urgencias_exploratorio_e2e` (nuevo)** | 71 OK, 3 DEFECTO, código 2 | QA-F8-02, QA-F8-03 y QA-F8-04 |
| **`tool/smoke/urgent_smoke_test.dart` (nuevo)** | 1 test, falla solo en la aserción de QA-F8-01 | El resto del viaje con los repositorios y servicios reales pasa (ver viaje 9) |

## Viajes de usuario (exploratorio: REST, Realtime por WebSocket, Edge Function y SQL solo para el tiempo)
| # | Viaje | Pasos | Resultado | Evidencia |
|---|---|---|---|---|
| 1 | Tandas y radios | 9 vets: 4 a 1–4 km, 1 a 8, 1 a 15, 1 a 25, 1 con presencia de hace 3 min y 1 solo de gatos. Se pausa `dispatch-urgent-visits` (`cron.alter_job`) y se vence cada tanda con SQL | PASA | Tanda 1: N1, N2 y N3 (≤ 5 km). Tanda 2: N4 @5. Tanda 3: M5 @10. Tanda 4: F6 @20. Luego `no_vet_found` con `closed_by_system`, `cancel_fee = 0` y 0 pagos. Nunca se ofreció a X7, S8 ni G9, y no se repitió ningún vet. Cada oferta vale 60 s y la búsqueda, `confirm_deadline = creación + 10 min` |
| 2 | Rechazos y cancelación | 2 de 3 rechazan, se repite un rechazo, rechaza el tercero y el dueño cancela | PASA | No sale tanda con una pendiente. El rechazo repetido da 400. Al rechazar la última sale la tanda 2 de inmediato. Cancelar buscando: $0, y la oferta queda `cancelled` y sale de `my_offers` |
| 3 | Permisos | Anónimo, vet, dueño ajeno, 2 solicitudes simultáneas del mismo dueño, dueño acepta, oferta ajena frente a inexistente | PASA | 401, 403 y 400. Solo pasa 1 de 2 (200/400). 403. Mismo mensaje "La oferta no existe" |
| 4 | **Carrera de 6 vets** | 3 ofertas del despacho + 3 insertadas por SQL; 6 `accept_offer` en paralelo × 8 rondas | PASA | 8/8 con 1 ganador, 5 `offer_taken`, ofertas 1 `accepted` / 5 `lost`. Exactamente 8 cotizaciones finales |
| 5 | **Aceptar vs. vencimiento** | Oferta que vence en 700 ms; aceptación entre 450 y 850 ms y despacho por psql en paralelo, × 10 | PASA | 1 aceptada, 9 vencidas (`offer_expired`), todas coherentes: nunca hay visita aceptada con oferta no aceptada ni oferta aceptada sin vet |
| 6 | **Aceptar vs. cancelación del dueño** | Ambas en paralelo, alternando el orden, × 10 | PASA | 5 × (200/200): aceptó y luego canceló gratis. 5 × (400 `offer_closed`/200). Siempre `cancelled_owner`, $0, 0 pagos y oferta coherente |
| 7 | **Dos dueños piden a la vez con 1 vet libre** | 2 `request_urgent_visit` en paralelo × 6 | **DEFECTO** | El vet recibió 2 ofertas pendientes en 6/6 rondas y en todas `accept_offer` respondió 400 "Tienes otra visita que choca con esta urgencia" (QA-F8-02) |
| 8 | Precio | Vet a 8 km, donación de $1.000. El admin publica otra versión (40 % urgencia, $900/km, cargo de $7.000) **durante** la búsqueda. Luego acepta, sale en camino y el dueño cancela. Otra: acepta y cancela antes de en camino | PASA | Al pedir: recargo $8.097 y "hasta" $43.587 (20 km + donación). Final: misma versión (21 → 21), 3 km × $500 → $37.587 ≤ tope, y coincide con lo que vio el vet en la oferta. Cargo en camino: $5.000 de la versión congelada (pago `cancel_fee`). Antes de en camino: $0 |
| 9 | **RPC reales contra la app** (`urgent_smoke_test.dart`) | `SupabaseUrgentRepository`, `SupabaseVisitRepository` y `SupabaseLiveLocationService` contra el stack | PASA salvo QA-F8-01 | `request`, `searchStatus`, `setPresence`, `myOffers`, `accept` (con `OfferFailure.taken` para el segundo), `reject`, `myVisits` y `transition` parsean bien. La posición en vivo llega al dueño. `sendEnd()` lanza `Unsupported operation: Cannot modify unmodifiable map` |
| 10 | Privacidad de la oferta y la presencia | Claves de `my_offers`. Lectura de `vet_presence.location`, `select=*`, `visit_offers.distance_m` y `quotes.distance_m` por REST y GraphQL con vet, dueño, admin y anónimo. Redondeo en BD | PASA, con QA-F8-03 | Solo comuna, distancia, especie, especialidad y montos. 403/401 en REST y 406 en GraphQL. Posición a 3 decimales. Pero el pago estimado revela la distancia con más precisión que 0,5 km (QA-F8-03) |
| 11 | Push | Cola y RPC de servicio con usuario. `send-push` con la clave pública. Envío fake | PASA | 404/403. 403. 87 avisos con solo `{visit_id, event}`, en 9 tipos de evento. Sin tokens ni datos personales en la respuesta |
| 12 | `urgent_search_status` ajeno | Propia, ajena e inexistente × 25. Como vet | PASA | Ajena = inexistente = `200 null`. Medianas 3,4 / 3,4 / 3,4 ms. El vet también recibe `null` |
| 13 | **Realtime `visit:{id}` con WebSocket real** (protocolo Phoenix 2.0.0, como supabase-js) | Join privado con la visita aceptada. En camino: dueño, vet asignado, otro dueño, vet de otra visita en camino, vet sin visita, admin y anónimo. Canal público homónimo. Envíos por WS y por `POST /realtime/v1/api/broadcast` | PASA | Aceptada: "Unauthorized". En camino: entran el dueño y el vet. Los 5 intrusos son rechazados o no reciben respuesta, y ninguno recibe mensajes. El dueño recibe lo del vet por WS y por REST. Lo que manda el dueño no llega. Un tercero no inyecta (REST 202 sin entrega). El canal público homónimo acepta joins, pero no recibe nada del privado |
| 14 | Realtime al salir de `en_route` con el canal abierto | El vet pasa a "llegó" y vuelve a enviar por WS y por REST | Riesgo documentado (O-F8-a) | Por WS **sí llega** al dueño (1 mensaje). Por REST ya no (202 sin entrega). Un nuevo join se rechaza |
| 15 | Dirección para "Agendar primera hora libre" | El dueño tiene 2 direcciones "Casa · Pasaje Ficticio 456" (Ñuñoa y Providencia) y pide una urgencia desde Providencia, sin vets | **DEFECTO** | `my_visits` no trae `address_id`. Las 2 coinciden por etiqueta y calle, y la primera es la de Ñuñoa (QA-F8-04) |
| 16 | pg_cron real | Se reactiva `dispatch-urgent-visits` con una búsqueda vencida | PASA | Queda `no_vet_found` en 11 s (job `10 seconds`) |

## Trazabilidad SPEC
| HU | Caso(s) | Resultado |
|---|---|---|
| HU2.1 primera tanda ≤ 5 km, máx. 3, por distancia y calificación | Viaje 1; pgTAP 150 | PASA (la calificación es neutra hasta la fase 9) |
| HU2.1 60 s y siguiente tanda sin repetir; 5 → 10 → 20 km | Viajes 1 y 2; pgTAP 150 | PASA |
| HU2.1 dos aceptan a la vez: uno asignado, otro "ya tomada" | Viajes 4–6; pgTAP 150; `urgencias_e2e` | PASA. Ver QA-F8-02: concurrencia entre **solicitudes**, no entre aceptaciones |
| HU2.1 10 min o 20 km → `no_vet_found` sin cobro | Viajes 1 y 16; `urgencias_e2e` | PASA |
| HU2.1 [widget] opciones "Agendar primera hora libre" y "Clínicas 24 h" | `flutter test` (`urgencias_test`); viaje 15 | PASA, con QA-F8-04 (dirección ambigua) |
| HU2.1 la oferta muestra comuna y distancia a 0,5 km, nunca dirección ni coordenadas | Viaje 10; pgTAP 150; `urgencias_e2e` | PASA, con QA-F8-03 (precisión extra vía pago) |
| HU2.1 [int] el dueño ve al vet moverse; al llegar o cancelar se deja de compartir | Viajes 9, 13 y 14 | PASA en lo probable aquí (WS real y smoke Dart), con QA-F8-01 y O-F8-a. Sin dispositivo real |
| HU2.3 push en cada cambio relevante | Viaje 11; `urgencias_e2e` | PASA con el proveedor fake. FCM real no probado |
| HU2.3 payload solo `visit_id` + evento | Viaje 11; `providers.test.ts`; unit `PushPayload` | PASA |
| HU2.3 teléfono solo para el vet asignado | `urgencias_e2e` (ganador ve `exact.owner_phone`); smoke; oferta sin teléfono (viaje 10) | PASA |

## Defectos
| ID | Severidad | Resumen | Reproducción | Esperado vs. obtenido | Archivo sospechoso |
|---|---|---|---|---|---|
| QA-F8-01 | Medio | El vet nunca envía el evento `end`: `sendEnd()` falla siempre | `urgent_smoke_test.dart`: el vet en camino llama `SupabaseLiveLocationService.join(id).sendEnd()` | **Esperado:** el dueño recibe `LiveEnded` y refresca la visita (arquitectura §6, "Antes de salir, el vet manda el evento `end`").<br>**Obtenido:** `UnsupportedError: Cannot modify unmodifiable map`. `realtime_client` 2.13.2 `RealtimeChannel.send` hace `payload['type'] = …` y el servicio pasa `const {}`. `VetLiveSharing._close` traga el error, así que el dueño sigue viendo el último marcador hasta el sondeo de 15 s. Los fakes de `test/` no lo detectan | `lib/data/services/live_location_service.dart` (`sendEnd`: usar `payload: <String, dynamic>{}`) |
| QA-F8-02 | Medio | Dos solicitudes simultáneas ofrecen al mismo vet, y entonces no puede aceptar ninguna | 1 vet en línea. 2 dueños llaman `request_urgent_visit` en paralelo. Luego el vet llama `accept_offer` sobre una oferta (viaje 7, 6/6) | **Esperado:** cada vet tiene como máximo 1 oferta pendiente, o puede aceptar una de las dos.<br>**Obtenido:** 2 ofertas pendientes y `accept_offer` → 400 "Tienes otra visita que choca con esta urgencia" en ambas, porque `vet_busy_for_urgent` cuenta la otra oferta pendiente. Las 2 urgencias pierden a ese vet durante 60 s. Pasa porque el despacho inline de `request_urgent_visit` (y el de `reject_offer`) no ve las ofertas sin confirmar de otra transacción, y `skip locked` solo serializa por visita | Migración `20261124213036`: `dispatch_visit`/`vet_busy_for_urgent`/`accept_offer`. Sugerencias: `pg_advisory_xact_lock` por vet al ofertar, o que `accept_offer` ignore las otras ofertas pendientes del vet y las cierre al aceptar |
| QA-F8-03 | Bajo | El pago estimado de la oferta revela la distancia con más precisión que 0,5 km | 2 vets con ofertas de la misma visita a 5,87 y 6,09 km reales (viaje 10) | **Esperado:** con `distance_km` = 6 en ambas, nada más fino.<br>**Obtenido:** `vet_payout` $30.249 frente a $30.674. Los km facturables se calculan con `ceil` sobre `distance_m` exacta, y eso parte el tramo de 0,5 km en 0,25 km. Sobre 5 km, cada oferta acota la distancia a ±125 m | `private.list_my_offers` (montos con `o.distance_m`). Sugerencia: estimar con la distancia redondeada que se muestra, o mostrar solo un rango |
| QA-F8-04 | Bajo | "Agendar primera hora libre" puede proponer otra dirección del dueño | Dos direcciones activas con la misma etiqueta y calle en comunas distintas. Urgencia `no_vet_found` desde la segunda (viaje 15) | **Esperado:** el formulario de reserva se abre con la dirección de la urgencia.<br>**Obtenido:** `my_visits` no trae `address_id` y `NoVetFoundView` toma la primera que coincide en `label` y `street_text` (la de Ñuñoa). Con una dirección desactivada, no preselecciona ninguna | `lib/ui/features/urgent/views/urgent_search_view.dart` (l. 166–175) y `my_visits`. Sugerencia: exponer `address_id` solo al dueño |

## Observaciones (sin defecto)
- **O-F8-a (riesgo documentado, Bajo):**
  - Realtime evalúa la política al unirse. Con el canal ya abierto, si la visita deja `en_route`, lo que el vet manda por WebSocket **sigue llegando** al dueño. Por REST ya no se entrega, y un nuevo join se rechaza.
  - El riesgo se limita a la posición del propio vet, y la app sale del canal. Mitigaciones: el dueño ignora posiciones si la visita no está `en_route`, y un JWT de vida corta.
- **O-F8-b (endurecimiento):** cualquiera, incluso anónimo, puede unirse al canal **público** homónimo `visit:{id}`. No recibe nada del privado (verificado), pero conviene desactivar el acceso público de Realtime en producción ("private only").
- **O-F8-c:** con la clave pública, 4 de 5 intrusos no recibieron respuesta al join en 5 s, en vez de un "Unauthorized" explícito. En ningún caso recibieron mensajes.
- **O-F8-d:** cada urgencia crea 2 cotizaciones (la solicitud y la final), y ambas cuentan para el límite de 60 por hora del dueño. No afecta a un uso normal, pero sí a los scripts de carga: el exploratorio usa dueños separados por eso.
- **O-F8-e (por diseño):** `register_push_device` reasigna un token al último usuario que lo registra. Quien conozca el token FCM de otro puede quitarle los avisos, pero no leer datos (el payload solo lleva `visit_id` + evento).
- **O-F8-f (higiene):** los archivos generados de Windows versionados (`windows/flutter/generated_plugin_registrant.cc` y `generated_plugins.cmake`) no incluyen `geolocator_windows`, y `flutter pub get` los cambia. Se regeneran al compilar, pero conviene versionarlos actualizados. QA no los tocó: se restauraron con `git checkout`.
- **O-F7-c resuelto:** pgTAP 645/645 sobre el stack nuevo, y `150` aísla los vets preexistentes con el mismo patrón.

## Pruebas agregadas en esta iteración
- `tool/e2e/qa_urgencias_exploratorio_e2e.mjs`:
  - 74 comprobaciones de los viajes 1–8 y 10–16;
  - cliente Realtime propio sobre `WebSocket` de Node (Phoenix 2.0.0 por defecto, `RT_VSN=1.0.0` opcional), sin dependencias;
  - pausa y reactiva `dispatch-urgent-visits`; publica una versión de `pricing_config` y restaura los valores por defecto; limpia lo que crea;
  - sale con 2 mientras QA-F8-02, QA-F8-03 y QA-F8-04 sigan abiertos.
- `tool/smoke/urgent_smoke_test.dart`: viaje completo con los repositorios y servicios reales de la app. Falla mientras QA-F8-01 siga abierto. Uso en la cabecera, con `SUPABASE_URL` del stack.

## Riesgos y lo que NO se probó (y por qué)
- `geolocator` en dispositivos reales (permisos, precisión y segundo plano), la compilación nativa en Windows y FCM real: no hay dispositivos ni proyecto Firebase en este entorno. `PushService` sigue en `NoopPushService` y el envío se probó solo con `PUSH_PROVIDER = "fake"`.
- UI real (mapa con el marcador moviéndose, cuenta regresiva y sonidos): solo los widget tests (320) y el smoke de datos.
- El cron `send-push` por `pg_net` no se ejercitó, porque no hay secretos de Vault en el stack aislado. Se invocó la función a mano.
- La renovación del JWT con el canal abierto y la expulsión del canal al revocar la sesión no se probaron.
- "Terminado F2" pide datos semilla de 20 vets en 3 ciudades: `seed.sql` no trae vets. Queda fuera del alcance declarado para esta fase.
- No se midió la carga del despacho con muchas visitas simultáneas (límite de 200 por pasada).

## Condiciones para aprobar la próxima versión
1. QA-F8-01 corregido. `urgent_smoke_test.dart` debe pasar completo y se recomienda un unit test del servicio que use un mapa no modificable.
2. QA-F8-02 corregido, con un test de concurrencia (pgTAP con `dblink` o E2E) de 2 solicitudes simultáneas y 1 vet. El viaje 7 del exploratorio debe pasar.
3. QA-F8-03 y QA-F8-04: corregir, o documentarlos como riesgo aceptado en `docs/arquitectura.md`.
4. Recomendado antes de producción: O-F8-a (el dueño ignora posiciones fuera de `en_route`) y O-F8-b (Realtime solo privado).
5. Todas las suites anteriores en verde y `qa_urgencias_exploratorio_e2e` con código 0.
