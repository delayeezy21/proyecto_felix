# QA — versión db5f16c (2026-11-25)
**Veredicto:** NECESITA TRABAJO (re-certificación de las condiciones de QA-690dd06)
**Alcance:** las correcciones de la fase 11, privacidad (SPEC §F8). `4ba0f8f` corrige QA-F11-01, 02, 04 y 05 (`20261125120000_qa_f11_fixes.sql` y el pgTAP `180`). `8230dea` es de documentación y `db5f16c` agrega `docs/privacidad.md` (QA-F11-03).

**Por qué no se aprueba:** todas las suites pasan y las 5 correcciones funcionan. Pero se pidió buscar una cuarta vía de tratamiento de una cuenta bloqueada y apareció una: el admin aprueba, anota y revisa los documentos de un vet bloqueado con un `PATCH` directo a `vet_profiles` o `vet_documents`, sin pasar por `review_vet_application` (QA-F11-07, Medio). Es el mismo tipo de defecto que dejó la versión anterior en NECESITA TRABAJO (QA-F11-04), y el viaje del exploratorio falla. Además, "Terminado F8" depende todavía de que el usuario firme las aceptaciones de `docs/privacidad.md` §8.

**Entorno:**
- Un solo stack aislado, `felix-qa-557` (puertos 557xx), con `PUSH_PROVIDER` y `TITLE_VERIFICATION_PROVIDER` en `"fake"`. `config.toml` se cambió en el worktree y se restauró sin commitear.
- Se excluyeron studio, imgproxy, logflare, vector, supavisor y postgres-meta. `edge_runtime` quedó `Up` desde el inicio.
- Todo corrió en secuencia, con `precios_e2e` al final. Después se bajó el stack con `stop --no-backup`.
- El stack compartido `proyecto-felix` estaba detenido y siguió así: había 0 contenedores antes y después.

## Suites
| Suite | Resultado |
|---|---|
| `dart format --set-exit-if-changed lib test` | OK |
| `flutter analyze` | OK, sin issues |
| `flutter test -j 1` | OK, 379/379 |
| pgTAP (`supabase test db`) | OK, 864/864 (20 archivos). Con el `190` nuevo de QA: 881/881, porque sus 6 casos `todo` no rompen la suite |
| pgTAP a las 22:2x de Chile (QA-F11-02) | OK, 864/864 (ver la condición 5) |
| `supabase db advisors` | OK, "No issues found" |
| `node --test` (`verify-vet-title`, `purge-privacy-storage`, `send-push`) | OK, 24/24 |
| `privacidad_e2e` | OK, "E2E fase 11: TODO OK" |
| `qa_privacidad_exploratorio_e2e`, original | OK, código 0 (QA-F11-01, 04 y 05 cerrados) |
| `qa_privacidad_exploratorio_e2e`, ampliado | Código 2: 0 fallas, defecto abierto QA-F11-07 |
| `urgencias_e2e` · `visitas_e2e` · `ficha_e2e` · `auth_e2e` · `verificacion_e2e` | OK, todos "TODO OK" |
| `precios_e2e` (al final) | OK, "E2E fase 5: TODO OK" |
| Smoke `privacy_smoke_test.dart` (contra 55721) | OK, 3/3 |

## Condiciones de QA-690dd06
1. **QA-F11-05: cumplida.**
   - La política `payments_select` ahora es `owner_id = auth.uid() or is_admin()`.
   - Con el JWT del vet, `GET /rest/v1/payments?select=id` devuelve 0 filas, y GraphQL `paymentsCollection` también 0.
   - `my_payouts()` le devuelve al vet su liquidación con 8 campos (`created_at,kind,paid_at,platform_fee,service_price,status,vet_payout,visit_id`), sin dueño, total, cotización ni donación. Al dueño y a la fundación no les devuelve nada.
   - Realtime: `payments`, `quotes`, `payment_events` y `foundation_contributions` no están en ninguna publicación (solo existe `realtime.messages`).
   - En la exportación del vet: "liquidaciones sin total ni donación … fugas: ninguna".
   - `foundation_summary()` queda igual antes y después del borrado.
   - Funciones `security definer` que leen `payments`: `erase_subject`, `export_my_data`, `my_payouts`, `pay_visit_simulated`, `record_payment` y `visit_view`. Se revisó `visit_view`: al vet solo le muestra `vet_payout` (de su cotización) y `paid`.
2. **QA-F11-04: cumplida para las 3 vías, pero hay una cuarta (QA-F11-07).**
   - Se probaron con HTTP real:
     - `verify-vet-title` → 403, con 0→0 verificaciones;
     - `review_vet_application` → 403, el vet sigue `pending`;
     - `PUT /auth/v1/user` → HTTP 500, no se guarda nada.
   - `send-push` (`claim_push_batch`) descarta lo bloqueado (pgTAP 180).
   - Se buscaron otras vías en las RPC, en las Edge Functions y en las políticas de escritura del admin:
     - `purge-vet-documents` solo borra documentos huérfanos o vencidos;
     - `clinical-attachment-url` con el JWT bloqueado da 404;
     - la agenda (`vet_open_slots`/`vet_slot_ok`) y la ficha excluyen a los bloqueados, y la presencia queda offline;
     - las políticas `vet_profiles_update` y `vet_documents_admin_update` dejan escribir al admin sin mirar el bloqueo: ese es QA-F11-07.
3. **QA-F11-01: cumplida.** Hay 9 variantes nuevas en el pgTAP `190` y pasan:
   - `N°`, `nro.`, el teléfono con puntos y con paréntesis, `Depto.` y el nombre partido por un salto de línea;
   - 3 negativos clínicos: el lote o la dosis con el mismo número de la casa o del depto, palabras que contienen el nombre o la mascota (`Angelina`, `Ñandúes`) y cifras clínicas cortas.

   Queda un residuo Bajo: "dpto 51" y "departamento 51" no se redactan (QA-F11-08).
4. **QA-F11-03: cumplida en lo documental; el cierre depende del usuario.**
   - `docs/privacidad.md` existe e incluye el informe del Privacy Engineer, los hallazgos previos y O-F11-d (aceptado).
   - "Terminado F8" pide "hallazgos cerrados o aceptados". Siguen **Abiertos** PE-11-01 a 06, 08 y 09, además de O-F11-b y O-F11-e (asignados a PE-11-03 y 06). Las aceptaciones de §8 (PE-11-07, PE-11-10 y otras) están "pendientes de confirmación" del usuario (§10, punto 9).
   - Prueba con datos semilla: PE-11-10 la propone como aceptada, porque `seed.sql` no tiene usuarios.
5. **QA-F11-02: cumplida.**
   - En el contenedor de BD se reemplazó `America/Santiago` del tzdata del sistema (nix store) por `Etc/GMT-8`, con lo que Chile quedó a las 22:24.
   - La sesión de la base quedó en `Etc/GMT-11`, es decir, Chile + 3 h, como el UTC real: `current_date` = 26-11 y la fecha de Chile = 25-11.
   - Se corrió `supabase test db` completo: 864/864, PASS.
   - Al terminar se restauraron el archivo y `alter database postgres reset timezone`.
   - No se repitió a las 21:15 ni a las 23:15: el `180` ya fija `Etc/GMT-14` en la sesión.
6. **Suites en verde y exploratorio con código 0: cumplida para el exploratorio de QA-690dd06.** La ampliación de esta iteración sale con código 2 por QA-F11-07.

## Defectos nuevos
| ID | Severidad | Resumen | Reproducción | Esperado vs. obtenido | Archivo sospechoso |
|---|---|---|---|---|---|
| QA-F11-07 | Medio | El admin trata los datos de un vet bloqueado con UPDATE directo, sin pasar por la RPC que se corrigió | El vet en revisión pide el borrado. Con el JWT del admin: `PATCH /rest/v1/vet_profiles?user_id=eq.<vet>` con `{status:'approved', review_notes:'QA directo'}` y `PATCH /rest/v1/vet_documents?vet_id=eq.<vet>` con `{review_status:'accepted'}` | **Esperado:** HU8.2 "bloqueada (sin tratamiento)", 42501 como en `review_vet_application`.<br>**Obtenido:** HTTP 200 en ambos, el vet queda `approved` con la nota y los documentos quedan `accepted`. La app usa la RPC (`vet_repository.dart:424`), pero la API lo permite. pgTAP `190`: los casos 14 a 17 son `todo` y los controles con un vet libre pasan | `private.guard_vet_profile` (el admin sale con `return new` antes de mirar `is_blocked`) y la política `vet_documents_admin_update` |
| QA-F11-08 | Bajo | No se redactan otras abreviaturas de la unidad | `select private.redact_pii('Dejar en dpto 51.', <términos con 'Torre B depto 51'>)` | **Esperado:** `[redactado]`.<br>**Obtenido:** queda "dpto 51" (también "departamento 51"). La calle y el número sí se redactan, así que el riesgo de reidentificar es bajo. pgTAP `190`, casos 10 y 11 en `todo` | `private.pii_term_patterns` |

## Observaciones
- **O-F11-g (Medio, igual a PE-11-03):** HU8.2 dice "siempre se ejecuta dentro del plazo legal". Una solicitud puede quedar en `executing` sin plazo y sin alerta (por ejemplo, con Storage caído, lo que el exploratorio reproduce). No es una regresión, pero el texto de HU8.2 solo se cumple con la alerta de PE-11-03.
- **O-F11-h (Bajo):** el admin sigue **leyendo** a un vet bloqueado: `vet_documents` y la URL firmada del título (`POST /storage/v1/object/sign/vet-documents/...` → 200). Hay que decidir en `docs/privacidad.md` si es conservación legítima (defensa o auditoría) o si se bloquea junto con QA-F11-07.
- **O-F11-i (Bajo):** con una cuenta bloqueada, la Auth API responde **500** ("Database error updating user") en lugar de un 4xx. El cliente no puede distinguirlo de una falla real. `docs/privacidad.md` ya pide confirmarlo en el proyecto alojado.
- **Clasificación de los PE-11:**
  - **PE-11-01** (Alto, configuración: OSM y Nominatim públicos en la Beta web) y **PE-11-04** (política v1 incompleta): no contradicen el texto de §F8 (HU8.1–HU8.6), pero bloquean el uso de datos reales.
  - **PE-11-05:** se acepta como observación. HU8.2 pide "sin el dueño, la mascota ni la dirección" y eso se cumple; `distance_km` es un cuasi-identificador.
  - **PE-11-03:** ver O-F11-g.
  - El resto son observaciones sin defecto en esta versión.
- Siguen abiertas: O-F7-c, O-F11-b (→ PE-11-03) y O-F11-e (→ PE-11-06).

## Pruebas agregadas en esta iteración
- `supabase/tests/database/190_qa_db5f16c.test.sql` (17 casos): las variantes y negativos de QA-F11-01, QA-F11-07 (2 controles más 4 `todo`) y QA-F11-08 (2 `todo`). Cuando se corrija, hay que quitar los `todo()`.
- `tool/e2e/qa_privacidad_exploratorio_e2e.mjs`:
  - QA-F11-05 por REST sin filtro, GraphQL, `my_payouts` (dueño, vet y fundación) y la publicación de Realtime;
  - QA-F11-07, con un `PATCH` directo del admin a `vet_profiles` y `vet_documents`;
  - O-F11-h, la URL firmada del admin, como INFO.

## Lo que NO se probó (y por qué)
- **El trigger en `auth.users` y los secretos de Vault en el proyecto alojado:** solo hay stack local.
- **Realtime `postgres_changes` sobre `payments`:** no se probó con un socket, porque la tabla no está en ninguna publicación (se verificó por SQL).
- **pgTAP a las 21:15 y a las 23:15:** solo se corrió a las 22:2x, como se pidió.
- **UI real en dispositivos:** sin automatización.
- **Exportación y borrado con usuarios de `seed.sql`:** no existen (PE-11-10).

## Condiciones para aprobar la próxima versión
1. QA-F11-07: el admin no escribe en `vet_profiles` ni en `vet_documents` de un titular bloqueado (42501). Los `todo` de `190` tienen que pasar a ser casos normales y en verde.
2. El usuario confirma por escrito las aceptaciones de `docs/privacidad.md` §8. Los PE-11 "Abiertos" quedan aceptados o diferidos a una fase con fecha, y se decide sobre O-F11-h.
3. QA-F11-08: se corrige (`dpto` y `departamento`) o se acepta en el residuo de M3.
4. Todas las suites en verde y el exploratorio ampliado con código 0.
