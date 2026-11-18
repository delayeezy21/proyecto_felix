# QA — versión cdf8eee (2026-11-18)
**Veredicto:** APROBADA CON OBSERVACIONES
**Alcance:** fase 7, ficha clínica (SPEC F3: HU3.1–HU3.4) y O-6 (`visits.closed_by_system`). Son los commits `c5a7a82` y `cdf8eee` sobre master `84ccf47`, con la migración `20261118185149_clinical_record.sql` y la Edge Function `clinical-attachment-url`.

**Entorno:**
- Se usó un solo stack aislado, `felix-qa-557` (puertos 557xx), levantado desde una copia de `supabase/`.
- El stack se levantó primero **sin** la migración de la fase 7. Luego se crearon datos previos y se aplicó la migración con `migration up`, para probar el backfill sobre datos reales.
- Todo corrió en secuencia y el stack se bajó al final (`stop --no-backup`).
- No se tocaron el stack compartido (5432x, siguió con 12 contenedores arriba) ni el servidor web.

## Suites automáticas
| Suite | Resultado | Evidencia |
|---|---|---|
| `dart format --set-exit-if-changed lib test` | OK | 125 archivos, 0 cambios |
| `flutter analyze` | OK | No issues found |
| `flutter test -j 1` | OK 274/274 | All tests passed |
| pgTAP (`supabase test db`) | OK 558/558 (15 archivos) | Corrido tras borrar mis datos previos. Con un vet aprobado y agenda completa en la BD, `100_scheduled_visits` y `120_qa_f6_followup` fallan (ver O-F7-c) |
| `supabase db advisors` | OK | No issues found |
| `ficha_e2e` | OK 65/65 | E2E fase 7: TODO OK |
| `visitas_e2e` | OK 73/73 | E2E fase 6: TODO OK |
| `qa_visitas_exploratorio_e2e` | OK 82/82, código 0 | QA fase 6: TODO OK |
| `auth_e2e` | 21/22 (entorno) | Mailpit se excluyó al levantar el stack, por lo que el signup devuelve 500 "Error sending confirmation email" y falla el caso "no se puede entrar sin confirmar el correo". La fase 7 no toca Auth |
| `precios_e2e` (al final) | OK 48/48 | E2E fase 5: TODO OK |
| **`qa_ficha_exploratorio_e2e` (nuevo)** | 127 OK, 2 DEFECTO, código 2 | QA-F7-01 y QA-F7-02 |

## Viajes de usuario (exploratorio por API: REST, Storage, Edge Function y SQL solo para el tiempo)
| # | Viaje | Pasos | Resultado | Evidencia |
|---|---|---|---|---|
| 1 | Matriz de accesos indebidos | 10 perfiles (otro dueño, otro vet, vet de visita cancelada, vet suspendido, vet con ventana vencida sin cron, autorización revocada, autorización vencida, fundación, admin y anónimo) × 6 grupos de operaciones (ver detalle abajo) | PASA | Lectura directa vacía o 401. RPC 403/401. Escritura 403/401. Storage 400. Firma 404 |
| 2 | Autor y dueña no modifican | PATCH/DELETE de entrada, vacuna, adjunto y log. Storage con upsert, PUT, DELETE, list y descarga directa | PASA | 403 ×5. Storage 400 (list → `[]`) y objeto intacto |
| 3 | Cadena `supersedes_id` | Corrección, bifurcación, 3 correcciones concurrentes, otro autor, otro tipo, inexistente, otra mascota, ciclo `id = supersedes_id` y dueña sobre entrada del vet | PASA | 200. 400. 200/409/409. 400 ×4 con el mismo mensaje para inexistente y ajena. 400. 400 |
| 4 | Inserciones forjadas | Otro `author_id`, dueña con `author_role = vet`, nota del dueño con `visit_id`, `created_at` propio, visita propia con otra mascota | PASA | 403 ×5 |
| 5 | Solo inserción frente a `service_role` y `postgres` | UPDATE/DELETE por REST con clave de servicio. UPDATE/DELETE como postgres. `set role authenticated/service_role` + `felix.record_maintenance = on`. Anulación de FKs. TRUNCATE | **2 DEFECTOS** | 403 y "no se modifica" en todos los casos, salvo dos. PATCH `actor_id = null` (log) y `supersedes_id = null` → **204** (QA-F7-01). `TRUNCATE record_access_log` → **se ejecuta** (QA-F7-02) |
| 6 | Log no omitible | 3 lecturas, GET y HEAD sobre `/rpc/get_pet_record`, `Prefer: tx=rollback`, 2 firmas | PASA | +3 vistas. GET y HEAD → 405. rollback → 200 y +1 fila (PostgREST ignora el rollback). +2 descargas. Las de la dueña no se registran |
| 7 | GUC desde la API | `POST /rpc/set_config` | PASA | 404 (no expuesto). GraphQL → 406. Las tablas no están en la publicación `supabase_realtime` |
| 8 | Fugas indirectas | Error y tiempo de una mascota ajena frente a una inexistente. Mismo par para entrada, vacuna, adjunto, firma y subida | PASA | Mismo 403/404/400 y mismo mensaje. Mediana 3,7 ms frente a 3,1 ms (Δ 0,5 ms) |
| 9 | Sin contenido clínico | `admin_record_stats`. `my_visits` del vet, la dueña y el admin. Nombres en Storage | PASA | 6 conteos numéricos. Sin título, cuerpo ni vacuna. `pets/<uuid>/<uuid>/<timestamp>.pdf`. El servidor rechaza `Juan Pérez.pdf` (400) |
| 10 | Autorización del dueño | 30 min, 366 días, vet suspendido, no-vet, mascota ajena o inexistente, `source = visit`, autoautorización del vet, re-revocar, des-revocar, cambiar `vet_id`, revocar la de visita | PASA | 400 ×4. 403 con el mismo mensaje. 403. 403. 400/400/403. 0 filas |
| 11 | Ventanas | VC: cancelación. VS: suspensión. VX: aceptada con hora −61 min y cron pausado. V: en curso con inicio −7 h y cron pausado. Días 29 y 31 | PASA | Corte inmediato en todos los casos. Día 29: lee y descarga. Día 31: sin leer, descargar, escribir ni corregir, y `record_access = false` |
| 12 | O-6 | `expire_visits` sobre la en curso y la aceptada vencidas. `closed_by_system` por REST (vet, dueña, service_role) | PASA | Queda `completed` con la marca (vet y dueña la ven), 30 días de lectura y escritura (`record_until` ≈ 30 d) y 0 pagos. La aceptada queda `cancelled_vet` con la marca y sin acceso. Por REST → 403 |
| 13 | URL firmada | La firma del vet sin sesión a los 0 s y a los 62 s | PASA | 200 con el PDF exacto. A los 62 s → 400 |
| 14 | Backfill de la migración | 6 visitas previas: A aceptada, B completada hace 10 d, C completada hace 40 d, D cancelada, E en curso cerrada por el cron, F en curso | PASA | A y F: autorización sin vencimiento. B: vence en 20 d. C y D: sin autorización. E: `closed_by_system = true` y 30 d. Solo 1 de 6 visitas quedó marcada |

Grupos de operaciones del viaje 1:
- leer entradas, vacunas, adjuntos, log y autorizaciones;
- llamar a `get_pet_record`;
- escribir, en nota y en diagnóstico;
- corregir `dx`;
- PATCH y DELETE de una entrada, e INSERT en el log;
- subir, descargar y firmar directo en Storage, y firmar con la Edge Function.

## Trazabilidad SPEC
| HU | Caso(s) | Resultado |
|---|---|---|
| HU3.1 (el vet asignado ve historial, vacunas, diagnósticos y adjuntos) | Viajes 1, 6, 11, 13 y 14; pgTAP 130; `ficha_e2e` | PASA |
| HU3.2 (escritura del vet, sin UPDATE/DELETE, `supersedes_id`, log de create/correct) | Viajes 2–5; pgTAP 130; `ficha_e2e` (log `create`/`correct`) | PASA, con QA-F7-01 y QA-F7-02 fuera de la API de usuario |
| HU3.3 (autorizar y revocar; la siguiente lectura falla de inmediato) | Viajes 1 y 10; `ficha_e2e`; widget `ficha_test` | PASA |
| HU3.4 (notas y adjuntos del dueño, sin diagnóstico ni vacuna) | Viaje 4; pgTAP 130; `ficha_e2e` (`ownerDx` 403); unit `clinical_test` | PASA |
| Terminado F3 (matriz pgTAP y Privacy Engineer sin altos) | pgTAP 558/558 y viaje 1 (matriz propia por API) | PASA |

## Defectos
| ID | Severidad | Resumen | Reproducción | Esperado vs. obtenido | Archivo sospechoso |
|---|---|---|---|---|---|
| QA-F7-01 | Medio | `service_role` por REST anula FKs de la ficha y del log. Así borra quién leyó la ficha y rompe la cadena de versiones | Con la clave secreta, `PATCH /rest/v1/record_access_log?actor_id=eq.<vet>` con `{actor_id:null}`, y `PATCH /rest/v1/clinical_entries?id=eq.<corrección>` con `{supersedes_id:null}` | **Esperado:** 403. La documentación dice "fuera de la API solo deja anular FKs".<br>**Obtenido:** 204 en ambos. La corrección deja de reemplazar a la original, que vuelve a quedar "vigente" y corregible. El log pierde al actor | `private.forbid_record_change`: `v_ok` solo excluye `anon`/`authenticated`. Sugerencia: excluir también `service_role`. Los `ON DELETE SET NULL` corren como dueño de la tabla, así que siguen funcionando |
| QA-F7-02 | Bajo | `TRUNCATE` salta el trigger de solo inserción | Como postgres: `begin; truncate public.record_access_log; rollback;` | **Esperado:** error.<br>**Obtenido:** se ejecuta. `service_role` tiene el privilegio TRUNCATE sobre `clinical_entries` y `record_access_log`, y hay 0 triggers de TRUNCATE. No es alcanzable por PostgREST | Migración 20261118185149. Sugerencia: `revoke truncate ... from service_role` y un trigger `before truncate ... for each statement` que lance el mismo error |

## Observaciones (sin defecto)
- **O-F7-a (Bajo, por diseño):**
  - La URL firmada es de portador: durante 60 s la descarga cualquiera que la tenga, sin sesión.
  - El log registra la firma, no cada descarga. Conviene decirlo en la política de privacidad.
- **O-F7-b (endurecimiento):**
  - Hoy `felix.record_maintenance` no es explotable:
    - ninguna función hace `set_config` con valores del usuario;
    - `set_config` no está expuesto (404);
    - `authenticated` y `service_role` con la marca fijada siguen bloqueados.
  - Aun así, el guardián se basa en `current_user`. Una futura función `security definer` del job de borrado lo haría pasar. Conviene exigir además `session_user = 'postgres'`, como `felix.time_travel`.
  - `felix.record_internal` y `felix.visit_transition` no tienen ningún chequeo de rol (son preexistentes y tampoco son alcanzables hoy).
- **O-F7-c (higiene de tests):** `100_scheduled_visits` y `120_qa_f6_followup` fallan si en la BD hay un vet aprobado con agenda 24×7 cerca. Es la razón para correr pgTAP antes de `precios_e2e`. Conviene que filtren por los vets que crean.
- **B3 aceptado:** O-6 da 30 días de escritura a una `completed` cerrada por el sistema. Se verificó que no hay cobro y que el dueño la ve marcada.

## Pruebas agregadas en esta iteración
- `tool/e2e/qa_ficha_exploratorio_e2e.mjs`:
  - 129 comprobaciones: viajes 1–13, incluida la matriz de 10 perfiles por REST, Storage y Edge Function;
  - pausa y reactiva el job `expire-visits` con `cron.alter_job`;
  - limpia lo que crea;
  - sale con 2 mientras QA-F7-01 y QA-F7-02 sigan abiertos.
- El viaje 14 (backfill) se corrió con un script temporal no versionado, porque requiere aplicar la migración sobre datos previos.

## Riesgos y lo que NO se probó (y por qué)
- UI real en iPhone y en web: el usuario la está probando contra el stack compartido, que no se tocó. Solo corrieron los widget tests (274).
- El caso de correo sin confirmar de `auth_e2e` no se repitió con mailpit. Habría que reiniciar el stack, y la fase 7 no toca Auth.
- El día 29/31 se simuló moviendo `expires_at` de la autorización, no el reloj. El cálculo `completed_at + 30 d` sí se verificó (≈ 30 d).
- Pendientes ya declarados por el agente: M1 (supresión del dueño con ficha, fase 11), M2 (barrido de adjuntos huérfanos) y M3 (PII en texto libre al desvincular). No se probó el tope de 5 adjuntos (cubierto en pgTAP).

## Condiciones para aprobar la próxima versión
1. QA-F7-01 corregido y con test pgTAP: `service_role` no anula FKs en las 4 tablas y el log. `qa_ficha_exploratorio_e2e` debe pasar ese caso.
2. QA-F7-02: revocar TRUNCATE y agregar un trigger de statement, o documentarlo como riesgo aceptado.
3. Recomendado: chequeo de `session_user` en `felix.record_maintenance` antes de la fase 11.
4. Todas las suites anteriores en verde y `qa_ficha_exploratorio_e2e` con código 0.
