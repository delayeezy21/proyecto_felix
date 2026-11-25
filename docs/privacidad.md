# Privacidad — informe del Privacy Engineer (fase 11)

**Versión revisada:** `8230dea` (rama `fase-11`), 2026-11-25. Revisión de código sin levantar Supabase.
**Marco:** Ley 19.628 modificada por la **Ley 21.719** (vigente desde el 1 de diciembre de 2026), SPEC §F8 (HU8.1–HU8.6, P1–P3) y `docs/arquitectura.md` §7, §8 y §8.2.
**Fuentes:** migraciones `20261125005641_privacy_rights.sql` y `20261125120000_qa_f11_fixes.sql`, Edge Functions `purge-privacy-storage`, `verify-vet-title`, `send-push` y `purge-vet-documents`, `lib/ui/features/privacy/`, `lib/data/services/account_blocked.dart`, `docs/qa/QA-690dd06.md`.

> Los artículos y plazos legales que se citan son **orientativos**. Todos están en la lista "a verificar" (§9) y hay que confirmarlos con el texto oficial en bcn.cl o con un abogado antes de usar datos reales.

## 1. Resumen

| Tema | Estado |
|---|---|
| Derechos (acceso, portabilidad, rectificación, supresión, oposición, bloqueo) | Implementados en la app y por RPC, para los tres roles |
| Borrado distribuido con verificación | Implementado: job idempotente, `deletion_targets`, escaneo por catálogo y registro |
| Minimización | Fuerte: sin RUT, dirección y teléfono solo para el vet asignado, presencia sin historial, microchip restringido, pagos ocultos a vets y fundaciones |
| Hallazgos altos de código | **Ninguno** en la BD. Hay **1 alto de configuración** (PE-11-01: geocoding y tiles públicos de OSM en la Beta web) |
| Bloqueantes antes de datos reales | PE-11-01, los DPA de los encargados (§5), la política v2 (PE-11-04) y la lista P3 (§9) |

**Veredicto:** la parte técnica de F8 está cumplida. "Terminado F8" queda cumplido con este informe, siempre que el dueño del producto acepte lo marcado como "aceptado" en §8 (en particular PE-11-10, que trata de "datos semilla"). **No apto para datos reales** hasta cerrar los bloqueantes de §10.

## 2. Alcance y titulares

| Titular | Cómo entra | Datos principales | Derechos en la app |
|---|---|---|---|
| **Dueño** | Registro (`complete_registration`, rol `owner`) | Nombre visible, correo, teléfono, comuna, direcciones, mascotas (incluido el microchip), notas de la ficha, visitas y pagos | Todos (`/privacy`) |
| **Veterinario** | Registro (rol `vet`) + solicitud de verificación | Nombre profesional, correo, base, horario, presencia, documentos de título, verificaciones, visitas, liquidaciones, entradas clínicas que escribió | Todos (`/privacy`, también en revisión) |
| **Miembro de fundación** | Creado por SQL | Correo y membresía | Todos (`/privacy`) |
| **Admin** | Creado por SQL | Correo y acciones en `admin_audit_log` | Exporta. El borrado se hace por soporte (sin botón; `request_account_deletion` → 42501) |
| Terceros | — | Las mascotas no son titulares. Las personas nombradas en el texto libre se tratan con el escaneo de PII y la redacción (M3) | — |

Fuera de alcance: pagos reales, planes (fase 10) y calificaciones (`ratings`, fase 9: el borrado ya las contempla si la tabla existe).

## 3. Inventario de datos personales

Bases: **C** = contrato (art. 13 a verificar), **LO** = obligación legal, **IL** = interés legítimo, **CO** = consentimiento. Toda tabla tiene RLS forzada y grants mínimos (`000_base` lo vigila).

| Tabla / bucket | Categoría | Finalidad | Base | Quién accede | Retención y borrado |
|---|---|---|---|---|---|
| `auth.users`, `auth.sessions`, `auth.refresh_tokens`, `auth.audit_log_entries` | Identificación y contacto (correo), sesión | Cuenta e inicio de sesión | C | Titular (Auth). Admin: no | Mientras exista la cuenta. Al borrar: ban → sesiones → `delete auth.users` y su rastro en `audit_log_entries` |
| `user_roles` | Rol | Autorización | C | Titular, admin | Cascada con `auth.users` |
| `owner_profiles` | Nombre visible, teléfono, comuna | Coordinar visitas | C | Dueño. El vet asignado ve el teléfono solo mientras la visita está activa (`my_visits`) | Borrado al ejecutar la supresión |
| `addresses` (`street_text`, `details`, `lat`/`lng`, `location`) | Ubicación del domicilio | Prestar la visita a domicilio | C | Solo el dueño (ni el admin). El vet, la exacta solo vía `my_visits` (accepted → in_progress) | Borrado. Se geocodifica una vez al guardar |
| `pets` (incluido `microchip`) | Datos de la mascota; el microchip es un identificador indirecto del dueño | Ficha y visitas | C | Dueño. El microchip, además, el vet con acceso vigente por `get_pet_record` | Borrado (también el microchip) |
| `clinical_entries`, `clinical_vaccines`, `entry_attachments` + bucket `clinical-attachments` | Ficha clínica veterinaria (puede contener PII en texto libre) | Atención y continuidad clínica | C | Dueño (SELECT). Vet solo por `get_pet_record` (cada lectura queda en el log) y adjuntos con URL firmada de 60 s | Solo inserción. Al borrar al dueño: sus notas y **todos** los adjuntos se borran; las entradas de vets se **desvinculan** (`pet_id = null`), se redactan (M3) y se retienen 5 años (P1). Luego `privacy-retention` las borra |
| `record_access_grants`, `record_access_log` | Metadatos de acceso | Control y auditoría del acceso a la ficha | C / IL | Dueño (log de sus mascotas). Admin: solo conteos | Log: a los 2 años se anula el actor. Se borran con el dueño |
| `vet_profiles`, `vet_species`, `vet_specialties`, `vet_availability`, `vet_time_off` | Datos profesionales y agenda | Ofrecer el servicio | C | Público (perfil profesional). Agenda: el vet y el sistema | Borrados al suprimir al vet |
| `vet_bases` (base exacta + `quote_origin` desplazado 1–2 km) | Ubicación del vet | Cotizar la distancia | C | Vet (exacta). Nadie más ve la base ni `quotes.distance_m` | Borrado con el vet |
| `vet_presence` | Posición redondeada (~100 m), en línea | Despacho de urgencias | C | Sistema (despacho) | Se sobrescribe, sin historial; `null` si está offline. Borrado con el vet |
| Realtime `visit:{id}` (broadcast) | Ubicación en vivo del vet en camino | Seguimiento de la visita | C (aviso "compartiendo ubicación") | Dueño y vet de la visita (políticas en `realtime.messages`) | No se persiste (broadcast por WS) |
| `vet_documents` + bucket `vet-documents` | Cédula (anverso) y título | Verificar al vet | C / IL | Vet (lo suyo) y admin | Archivo: 7 días tras aprobar, 30 si se rechaza, 90 si nunca se envía, huérfanos 24 h (`purge-vet-documents`). Metadatos hasta borrar la cuenta (B5: nombre original del archivo) |
| `vet_title_verifications`, `title_verification_reservations` | Resultado de chequeos (sin nombres de terceros) | Verificación asistida | IL | Vet (las suyas) y admin | Sin plazo (PE-11-07). Se borran con el vet |
| `visits`, `visit_events` | Servicio: fecha, estado, comuna, especie, montos; `owner_notes`, `cancel_reason` | Prestar y cobrar el servicio | C / LO (contabilidad) | Dueño y vet de la visita; admin solo por `admin_visit_summary` | Sin plazo. Al borrar al dueño: sin dueño, mascota, dirección, notas ni motivo (**desvinculadas**, ver PE-11-05) |
| `visit_offers` | Ofertas de urgencia: vet, `distance_m` real, respuesta y hora | Despacho | C | Vet (las suyas) | Sin plazo (PE-11-06). Cascada con el vet |
| `quotes` | Cotización (dueño, mascota, dirección, distancia) | Precio en el servidor | C | Dueño | Las no consumidas se purgan al vencer. Borradas con el dueño |
| `payments`, `payment_events`, `foundation_contributions` | Montos, donación voluntaria (posible dato socioeconómico) | Pago simulado y aportes | C / LO | Dueño y admin. Vet: solo `my_payouts()` sin dueño, total ni donación (QA-F11-05). Fundación: solo `foundation_summary()` | Sin plazo. Al borrar: sin dueño ni vet; montos y aportes intactos |
| `consents`, `terms_acceptances`, `privacy_notice_views`, `legal_versions` | Prueba de consentimiento e información | Demostrar cumplimiento | LO | Titular | Historia completa mientras exista la cuenta. Borrados con ella |
| `data_exports` | Registro de exportaciones (solo secciones) | Constancia del ejercicio de derechos | LO | Titular, admin | Borrado con la cuenta |
| `deletion_requests`, `deletion_targets` | Constancia de borrado (al terminar: sin `user_id` ni mascotas) | Probar la supresión | LO | Titular (la suya, sin columnas internas); admin | Sin plazo (PE-11-07) |
| `retained_entry_requests` | Motivo del vet para consultar una entrada retenida | Control del acceso P1 | LO / IL | Vet autor, admin | Borradas con el vet |
| `private.push_devices`, `private.push_outbox` | Token de dispositivo; aviso (`visit_id` + evento) | Notificaciones | C | Sistema | Token: 90 días sin uso. Outbox: 1 día. Borrados con la cuenta |
| `foundation_members` | Membresía | Acceso al panel de la fundación | C | Miembro, admin | Borrada con el miembro |
| `admin_audit_log` | Cambios del admin (puede incluir ids de usuarios) | Auditoría | IL | Admin | Sin plazo (PE-11-07). Al borrar: `row_pk = '[suprimido]'` y sin `old_data`/`new_data` |
| `pii_scan_findings` | Tabla, columna, fila y valor enmascarado (`xx***`) | Detectar PII en texto libre | IL | Admin | Sin plazo (PE-11-07) |
| `private.search_quota`, `private.storage_erasure_queue` | Contadores y rutas internas | Cuota y borrado | IL / LO | Sistema | Borrados con la cuenta / al confirmar Storage |
| Respaldos (Supabase diario, `pg_dump` semanal cifrado) | Copia de todo lo anterior | Continuidad | IL | Dueño del proyecto (clave `age` fuera del PC) | 7 días (Supabase) y 90 días (artefactos de GitHub). Ver PE-11-02 |
| Logs de la plataforma (API gateway, Edge Functions, Auth) | IP, ruta, `sub` del JWT | Operación y seguridad | IL | Dueño del proyecto | Según el plan de Supabase (Pro: días). No se pueden borrar por titular: riesgo residual aceptado |

## 4. Derechos del titular

| Derecho | En la app | RPC / mecanismo | Prueba |
|---|---|---|---|
| Acceso y portabilidad | "Privacidad y datos" → Descargar mis datos (JSON `felix-mis-datos-AAAA-MM-DD.json`) | `export_my_data()` → `{format: 'felix-export', format_version: 1, ...}` por rol; queda en `data_exports` | pgTAP 170, `privacidad_e2e`, viaje 14 de QA |
| Rectificación | Editar perfil, direcciones y mascotas. Ficha: corrección con `supersedes_id` (solo inserción) | RLS de cada tabla; `add_clinical_entry` | Fases 1, 2 y 7 |
| Supresión | "Borrar mi cuenta" (escribir `BORRAR`) | `request_account_deletion()`, `cancel_account_deletion()`, `my_deletion_request()` | pgTAP 170 y 180, viajes 4–13 |
| Bloqueo | Automático al pedir el borrado | `private.is_blocked`, pre-request `public.check_request`, políticas restrictivas en Storage y Realtime | Viajes 1–5 |
| Oposición y retiro del consentimiento | Interruptores de finalidades opcionales (hoy solo `marketing`) | `my_privacy_status()`, `set_consent()`; ubicación y servicio = contrato | Viaje 16 |
| Información | Política con versión y aviso de cambio (`PrivacyNoticeBanner`) | `record_privacy_notice_view()`, `must_review`, `ask` | `privacidad_test` |
| Entradas retenidas (vet autor) | Lista sin contenido y solicitud con motivo | `list_my_retained_entries()`, `request_retained_entry()` (10–500 caracteres) | Viaje 11 |

### 4.1 Flujo de borrado

| Paso | Qué pasa | Dónde |
|---|---|---|
| 1. Solicitud | Acuse inmediato `{status: 'blocked', execute_after: +15 días, cancellable}` | `private.request_account_deletion` |
| 2. Bloqueo | Se borran `auth.sessions` y `auth.refresh_tokens`. Se cancelan sin cargo las visitas abiertas (dueño hasta `en_route`; vet hasta `arrived` y sus ofertas) y el vet queda offline. La REST/RPC responde 403 `account_blocked`, salvo ver, cancelar o exportar. Storage, Realtime (join y envío), `verify-vet-title`, `review_vet_application`, `send-push` y la actualización en Auth (`felix_blocked_account_guard`) también lo rechazan | `check_request`, `qa_f11_fixes.sql` |
| 3. Gracia (15 días, P2) | Cancelable por el titular. La app solo deja `/account-blocked` | `cancel_account_deletion`, `AccountBlockedSignal` |
| 4. Job (`privacy-deletions`, cada 10 min) | Espera si hay una atención en curso. Banea, borra sesiones y ejecuta `private.erase_subject`, que registra cada paso en `deletion_targets` (sistema, acción, conteo y motivo de retención) | `run_account_deletions` → `process_deletion` |
| 5. Storage | Encola los objetos. `purge-privacy-storage` los borra con la API y el job confirma contra `storage.objects` antes de borrar `auth.users` | `private.storage_erasure_queue` |
| 6. Escaneo | `private.privacy_residue` recorre por catálogo `public`, `private`, `auth` y `storage` buscando el `user_id` y los `pet_id`. Si hay restos, queda `executing` y reintenta | Viaje 8 |
| 7. Registro | `done`: sin `user_id`, con `report` = {deleted, anonymized, retained, scan: 'clean'} | `deletion_requests` |

**Riesgo residual del borrado (aceptado, ver §8):**
- Un canal Realtime suscrito antes del bloqueo sigue **recibiendo** hasta que vence el JWT (≤ 1 h). Enviar y unirse sí se bloquean (O-F11-d). Lo mitigan la cancelación de las visitas abiertas y la salida del canal al cambiar de ruta.
- `alter role authenticator set pgrst.db_pre_request` y el trigger en `auth.users` funcionan en local, pero **hay que confirmarlos en el proyecto alojado** con el sondeo del viaje 1 y un `PUT /auth/v1/user`. Si el pre-request no queda aplicado, la REST no bloquea.
- Respaldos y logs de la plataforma (PE-11-02).

## 5. Encargados y transferencias internacionales

Chile no figura hoy en ninguna lista de adecuación propia: cada transferencia necesita un mecanismo (cláusulas tipo o DPA del proveedor; el mecanismo exacto está en la lista P3). **Todos los DPA están pendientes de firmar o aceptar.**

| Encargado | País del tratamiento | Datos | Cuándo | Mecanismo | Estado |
|---|---|---|---|---|---|
| Supabase Inc. (sobre AWS) | Brasil (sa-east-1); empresa y soporte en EE.UU. | Toda la BD, Auth, Storage, Realtime, Edge Functions y logs | Siempre | DPA de Supabase (dashboard) + cláusulas tipo | Pendiente |
| Google: Maps SDK (Android) y Geocoding | EE.UU. | Viewport de los tiles, texto de la dirección buscada, lat/lng, IP | Solo con `MAP_PROVIDER=google` o `GOOGLE_GEOCODING_API_KEY` | Google Maps Platform Data Processing Terms | Pendiente |
| Google: Firebase Cloud Messaging | EE.UU. | Token del dispositivo, `visit_id` + evento (sin texto personal) | Con `PUSH_PROVIDER=fcm` | Firebase Data Processing and Security Terms | Pendiente |
| Google: inicio de sesión | EE.UU. | Correo, nombre y foto de la cuenta Google | Solo si se activa (`[auth.external.google] enabled = false` hoy) | Términos de Google Identity | Pendiente / apagado |
| Cloudflare (Pages) | EE.UU. / red global | IP, user agent y rutas de la app web estática (sin datos de la cuenta) | Web | DPA de Cloudflare (self-serve) | Pendiente |
| Resend o Amazon SES (SMTP de Auth) | EE.UU. | Correo del titular y contenido del correo (enlaces de confirmación y recuperación) | Siempre en la Beta | DPA de Resend / AWS Data Processing Addendum | Pendiente |
| OpenStreetMap Foundation (Nominatim y tiles públicos) | Reino Unido | Texto de la dirección, lat/lng (reverse), viewport e IP | **Hoy, por defecto en la Beta web** (PE-11-01) | Ninguno: no hay DPA y su política de uso prohíbe el uso productivo | **Solo desarrollo**. Reemplazar antes de datos reales |
| MapTiler o Stadia (si se configura `OSM_TILE_URL`) | Suiza / EE.UU. | Viewport e IP | Opcional | DPA del proveedor | A elegir |
| GitHub (artefactos de Actions) | EE.UU. | `pg_dump` completo, **cifrado con `age`** (el runner solo tiene la clave pública) | Con `BACKUP_ENABLED=true` | GitHub DPA + cifrado | Pendiente (PE-11-02) |
| COLMEVET (buscador público) | Chile | Nombre del vet | Solo con `TITLE_VERIFICATION_PROVIDER=colmevet` (apagado) | No es encargado: es una consulta a una fuente pública. Exige aviso y autorización previa (§8.1) | Apagado |
| NotebookLM (memoria del proyecto) | EE.UU. | Nunca datos personales (regla de `CLAUDE.md`) | Desarrollo | — | No aplica |

## 6. Decisiones automatizadas

| Proceso | Lógica | ¿Efecto significativo? | Intervención humana |
|---|---|---|---|
| Despacho de urgencias | Candidatos en línea dentro del radio (5 → 10 → 20 km), en tandas de 3 vets × 60 s, ordenados por **tramo de distancia de 500 m**, luego **calificación** (`private.vet_dispatch_rating`; hoy `null` para todos, fase 9) y luego distancia exacta (`urgent_dispatch.sql` l. 436–437) | Sí para el vet: decide a quién se ofrece el trabajo | El vet acepta o rechaza; la asignación la hace `accept_offer`. No hay revisión del orden (PE-11-08) |
| Suspensión o rechazo de vets | **Ninguna suspensión automática.** Las alertas de cancelaciones (HU7.4) solo avisan al admin. La verificación del título solo sugiere y nunca aprueba | No es automática | El admin decide y el vet puede reenviar o pedir revisión |
| Precio | Tarifas y reglas públicas en `pricing_config` (`quote_visit`) | Bajo: es una regla transparente, igual para todos | Soporte |
| Cierres por tiempo (`expire-visits`, 6 h en curso) | Reglas fijas de `private.visit_timing()` | Bajo | Soporte |

## 7. Seguridad y respuesta a brechas

| Existe | Falta |
|---|---|
| RLS forzada en todas las tablas, `revoke all` + grants mínimos y la invariante de `000_base` | Tabla `security_incidents` (está en el diseño, `arquitectura.md` l. 169, pero no hay migración) — PE-11-09 |
| Helpers `security definer` solo en `private` con `search_path = ''` | **Runbook de brechas**: detección, contención, evaluación del riesgo, notificación a la Agencia y a los titulares (plazos "a verificar", §9) |
| Buckets privados, URL firmada de 60 s (es de portador: el log registra la **firma** de la URL, no cada descarga, O-F7-a) | Alerta de borrados atrasados (PE-11-03) |
| JWT de 1 h, sesiones revocadas al bloquear, `service_role` solo en el servidor | Confirmar en el proyecto alojado el pre-request y el trigger de Auth |
| Escaneo diario de PII en texto libre (`pii-scan`, valor enmascarado) | Escaneo de los logs de la plataforma (hoy solo cubre tablas de `public`) |
| `record_access_log` de cada lectura de la ficha por el vet | `/security-review` y la matriz pgTAP de la ficha antes de cada release (regla del proyecto) |
| Respaldos cifrados con `age`, clave fuera del PC | Procedimiento para re-aplicar los borrados tras restaurar (PE-11-02) |
| Edge Functions sin `console.log` de datos personales | — |

## 8. Hallazgos y estado

Severidad: **A** alto · **M** medio · **B** bajo. "Aceptado" exige la firma de quien se indica (**usuario** = dueño del producto; **abogado** cuando es una interpretación legal).

### 8.1 Hallazgos previos

| ID | Sev. | Resumen | Estado | Evidencia o motivo |
|---|---|---|---|---|
| M1 | M | El dueño con ficha no se podía borrar | **Cerrado** | `c2fb9f6` (`felix.record_maintenance` en el job), pgTAP 170 |
| M2 | M | Adjuntos huérfanos de la ficha | **Cerrado** | `c2fb9f6` (`purge-privacy-storage`, 24 h), `plan.test.ts`, viaje 12 |
| M3 | M | PII en el texto libre de las entradas retenidas | **Cerrado** con residuo aceptado | `c2fb9f6` + `4ba0f8f` (`unaccent` equivalente, dirección por tokens y teléfonos), pgTAP 180. Residuo: términos de < 3 letras, calle sin número y palabras sueltas del detalle no se redactan, para no dañar el texto clínico → **aceptado: usuario** |
| B1 | B | Los guardianes revelaban entradas o conteos | **Cerrado** | `cdf8eee`, pgTAP 130 |
| B2 | B | El vet lee la ficha desde que acepta (antes de llegar) | **Aceptado: usuario** | Necesario para preparar la atención. Queda en el log |
| B3 | B | O-6 da 30 días de escritura tras un cierre del sistema | **Aceptado: usuario** | Permite documentar una atención real |
| B4 | B | Autorización de visita sin vencimiento si el cron no corre | **Cerrado** | `cdf8eee` (`private.visit_active_until`), pgTAP 130 |
| B5 | B | Se guarda el nombre original del archivo | **Aceptado: usuario** | Útil para el dueño. Se borra con la entrada o la cuenta |
| B6 | B | El vet leía `record_access_grants` | **Cerrado** | `cdf8eee`, pgTAP 130 |
| O-F7-a | B | La URL firmada es de portador; el log registra la firma, no cada descarga | **Aceptado por diseño: usuario**. El texto de la política se corrige en PE-11-04 | La política v1 dice "Cada acceso queda registrado" |
| QA-F11-01 | M | Redacción incompleta (tildes, dirección parcial, teléfonos) | **Cerrado** | `4ba0f8f`, pgTAP 180 (variantes del viaje 10). Residuo: ver M3 |
| QA-F11-02 | M | pgTAP 100 y 130 fallaban según la hora de Chile | **Cerrado** | `4ba0f8f` (fechas ancladas a `America/Santiago`) |
| QA-F11-03 | M | Faltaba `docs/privacidad.md` | **Cerrado** con este documento. La parte de "datos semilla" sigue en PE-11-10 | Commit de este informe |
| QA-F11-04 | M | El bloqueo no cubría `verify-vet-title`, `review_vet_application` ni la Auth API | **Cerrado** en local; **por confirmar en el proyecto alojado** (trigger en `auth.users`) | `4ba0f8f`, pgTAP 180 |
| QA-F11-05 | M | El vet leía el dueño, el total y la donación en `payments` (HU8.6) | **Cerrado** | `4ba0f8f` (`my_payouts()`, política solo del dueño y del admin), pgTAP 180 |
| QA-F11-06 | B | El smoke registraba al dueño sin comuna | **Cerrado** | `8030600` |
| O-F11-a | B | `request_account_deletion` no está en la lista blanca del pre-request | **Cerrado** (se corrigió el texto: "idempotente" solo sin bloqueo) | `8230dea` (§8.2) |
| O-F11-b | M | Una excepción revierte el lote completo del job | **Abierto** → PE-11-03 | — |
| O-F11-c | B | Cada pasada con restos inserta otra fila `verification_scan` | **Aceptado: usuario** | Solo es ruido en la constancia |
| O-F11-d | B | Un canal Realtime abierto sigue recibiendo ≤ 1 h | **Aceptado: usuario** | Ver §4.1 |
| O-F11-e | B | La exportación del vet no incluye `visit_offers` | **Abierto** → PE-11-06 | — |
| O-F11-f | B | `check_request` se puede invocar como RPC | **Aceptado: usuario** | Devuelve void; es inocuo |

### 8.2 Hallazgos nuevos (esta revisión)

| ID | Sev. | Hallazgo | Archivo y línea | Corrección propuesta | Estado |
|---|---|---|---|---|---|
| **PE-11-01** | **A** | La Beta web usa por defecto `MAP_PROVIDER=osm` con Nominatim y tiles **públicos**: la dirección que escribe el dueño, el lat/lng del reverse y la IP salen a la OSMF (Reino Unido) sin contrato, y su política prohíbe el uso productivo. `CLAUDE.md` dice "los públicos solo para desarrollo" | `.github/workflows/web-deploy.yml` l. 67; `lib/core/config/env.dart` l. 66 y 68 | Que el build de `beta`/`production` falle si `NOMINATIM_URL`/`OSM_TILE_URL` quedan en los públicos, o exigir un proveedor con DPA (Google con su clave, MapTiler, LocationIQ o Nominatim propio). Registrar el elegido en §5 | **Abierto** (bloquea datos reales) |
| **PE-11-02** | M | Los respaldos conservan los datos borrados (7 días en Supabase y 90 en los artefactos de GitHub) y no hay cómo re-aplicar un borrado tras restaurar: al terminar, `deletion_requests` anula `user_id` | `privacy_rights.sql` l. 1424; `db-backup.yml` l. 44 | Guardar `subject_hash = sha256(user_id)` en la solicitud terminada. Escribir el runbook "tras restaurar, re-borrar cada cuenta cuyo hash coincida con una solicitud `done` posterior al respaldo". Informar en la política la retención de los respaldos y GitHub como encargado | **Abierto** |
| **PE-11-03** | M | Sin alerta de plazo legal: una solicitud puede quedar `executing` indefinidamente (Storage caído, Vault sin secretos, `SUPABASE_SERVICE_ROLE_KEY` distinta de la de Vault en el proyecto alojado, o restos del escaneo), y una excepción revierte el lote completo (O-F11-b) | `privacy_rights.sql` l. 1439–1462; `purge-privacy-storage/index.ts` l. 15–18 | `begin … exception` por solicitud, con el error en `deletion_targets`. Alerta en el panel del admin para solicitudes con `execute_after + 7 días < now()` sin `done`. Probar `purge-privacy-storage` en el primer despliegue | **Abierto** |
| **PE-11-04** | M | La política v1 (2026-11-16) no cubre lo implementado: falta el responsable y su contacto, la base por finalidad, los plazos (P1 5 años, log 2 años, respaldos), los encargados (Cloudflare, Resend/SES, GitHub, OSM), la ubicación en vivo, el orden del despacho y el reclamo ante la Agencia. Además dice "Cada acceso queda registrado" (O-F7-a) | `assets/legal/privacidad.txt` l. 1–30 | Versión 2 basada en §3–§7 de este documento, revisada por un abogado. Al publicarla, `must_review` avisa a todos | **Abierto** (bloquea datos reales) |
| **PE-11-05** | B | Lo "anonimizado" es en realidad **seudonimizado**. Las visitas del dueño borrado conservan en `visits.quote` el `distance_km` (distancia del origen del vet a la casa), `quote_id` y `request_quote_id`. Con el vet, la comuna y la fecha, el vet puede reconocer al dueño | `privacy_rights.sql` l. 1232–1236 y 387 (`guard_visit`); `qa_f5_fixes.sql` (`quote_snapshot`) | En el UPDATE del dueño, `quote = quote - 'distance_km' - 'quote_id' - 'request_quote_id'` (y permitirlo en `guard_visit`). Llamar "desvinculadas" a las visitas, los pagos y las entradas retenidas en la política y en la app | **Abierto** |
| **PE-11-06** | B | `visit_offers.distance_m` (distancia real entre el vet y la casa, por oferta) se guarda sin plazo y no sale en la exportación del vet (O-F11-e) | `urgent_dispatch.sql` (`visit_offers`) | Anular `distance_m` a los 30 días en `run_privacy_retention`. Exportar las ofertas propias (respuesta y hora, sin distancia) | **Abierto** |
| **PE-11-07** | B | Sin plazo de retención: `deletion_requests`/`deletion_targets` terminadas, `admin_audit_log`, `vet_title_verifications`, `pii_scan_findings` resueltos y visitas y pagos desvinculados | Varias tablas (§3) | Fijar plazos (por ejemplo, constancias de borrado 5 años y contabilidad 6 años, a verificar en §9) y agregarlos a `run_privacy_retention` | **Aceptado temporalmente: usuario** hasta tener los plazos legales |
| **PE-11-08** | B | El orden del despacho no se explica a los vets ni en la app ni en la política, y no hay un canal para pedir revisión humana | `urgent_dispatch.sql` l. 436–437 | Un texto en la pantalla de urgencias del vet y en la política, más un canal de revisión por soporte | **Abierto** |
| **PE-11-09** | B | No hay tabla `security_incidents` ni runbook de brechas, aunque el diseño los pide | `docs/arquitectura.md` l. 169 y 375 | Migración con la tabla (solo admin, RLS y pgTAP) y `docs/runbook-brechas.md` con plazos "a verificar" | **Abierto** (bloquea datos reales) |
| **PE-11-10** | B | "Terminado F8" pide pruebas de exportación y borrado "con datos semilla", pero `seed.sql` no tiene usuarios y no existe `is_seed`: las pruebas usan usuarios ficticios creados al vuelo | `supabase/seed.sql`; SPEC §F8 | Aceptar que los usuarios ficticios de los tests equivalen a datos semilla (ajustar el texto del SPEC), o agregar usuarios demo marcados y correr `privacidad_e2e` sobre ellos | **Aceptado: usuario** (pendiente de su confirmación) |

## 9. Lista P3: a verificar con bcn.cl o un abogado

| # | Punto | Qué confirmar |
|---|---|---|
| 1 | Numeración de artículos | Los artículos de la Ley 19.628 modificada por la 21.719 que se citan en la política y en la app (bases de licitud, derechos, transferencias, brechas) |
| 2 | Plazos de respuesta a los derechos | Plazo para responder (se asume 30 días corridos, prorrogables) y que 15 días de gracia + job quepan siempre dentro de él |
| 3 | EIPD | Si el tratamiento de la ubicación en vivo, la ficha y la donación exige una evaluación de impacto antes del piloto |
| 4 | Decisiones automatizadas | Si el orden del despacho es una decisión "basada únicamente en tratamiento automatizado" con efecto significativo, y qué información y revisión humana se deben a los vets |
| 5 | Ley 21.431 (plataformas digitales) | Si los vets califican como trabajadores de plataforma y qué obligaciones de transparencia del algoritmo y de protección de datos impone |
| 6 | Notificación de brechas | Plazo y forma de notificar a la Agencia de Protección de Datos Personales y a los titulares |
| 7 | Retención de 5 años (P1) | Que el art. 2515 del Código Civil respalde conservar las entradas clínicas desvinculadas 5 años, o si aplica otro plazo |
| 8 | Retención contable | Plazo para visitas y pagos desvinculados (Código Tributario; se suele citar 6 años) |
| 9 | Transferencias internacionales | Mecanismo válido para Brasil, EE.UU. y Reino Unido (cláusulas tipo de la Agencia, DPA del proveedor) |
| 10 | Donación voluntaria | Si cuenta como dato sensible o socioeconómico con un régimen especial |
| 11 | Datos de la mascota y microchip | Si el microchip vinculado al dueño es dato personal del dueño (se trata así) |
| 12 | Mayoría de edad | Edad mínima para registrarse y cómo tratar a los menores |

## 10. Pendientes antes de usar datos reales

1. **PE-11-01:** geocoding y tiles con un proveedor con contrato (o propios) en la Beta y en producción.
2. Aceptar o firmar los **DPA** de §5 (Supabase, Google, Cloudflare, Resend/SES y GitHub) y registrar la fecha.
3. **PE-11-04:** política v2 revisada por un abogado, con el responsable, el contacto y el canal para ejercer derechos fuera de la app.
4. **PE-11-09:** `security_incidents` y el runbook de brechas.
5. **PE-11-03:** aislar los errores del job y agregar la alerta de plazo; probar `purge-privacy-storage` y los secretos de Vault en el proyecto alojado.
6. **PE-11-02:** el runbook de restauración con re-aplicación de los borrados.
7. En el primer despliegue: el sondeo del viaje 1 (pre-request), `PUT /auth/v1/user` con una cuenta bloqueada (trigger de Auth) y un borrado completo de punta a punta.
8. Resolver la lista P3 (§9), en especial los puntos 2, 3, 4 y 6.
9. Que el usuario firme las aceptaciones de §8 (B2, B3, B5, M3, O-F7-a, O-F11-c, O-F11-d, O-F11-f, PE-11-07 y PE-11-10).
10. Antes de cada release: `/security-review` y la matriz pgTAP de la ficha.
