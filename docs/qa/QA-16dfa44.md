# QA — versión 16dfa44 (2026-11-25)
**Veredicto:** APROBADA CON OBSERVACIONES (re-QA corta de la fase 11)
**Alcance:** cierre de QA-F11-07 y QA-F11-08 (`008a355`, migración `20261125150000_qa_f11_fixes_2.sql` y pgTAP `190`), más una regresión mínima de la fase 11, privacidad (SPEC §F8, Ley 21.719). `16dfa44` es la integración en master.

**Por qué se aprueba:** las condiciones 1 y 3 de QA-db5f16c se cumplen con evidencia de pgTAP, de HTTP real y de SQL. Todas las suites del alcance están en verde y el exploratorio de privacidad sale con código 0. No hay defectos nuevos. Las observaciones son las mismas que el usuario aceptó en `docs/privacidad.md` §8 (B2, B3, B5, O-F7-a, límites de la redacción, Realtime ≤ 1 h, plazos de retención provisorios) y O-F11-g / PE-11-03, que se difiere a la fase 12. No se reabren.

**Entorno:**
- Stack aislado `felix-qa-557` (puertos 557xx), levantado desde un `git worktree` temporal de `16dfa44` en el scratchpad. Allí se ajustó `config.toml` (`project_id`, puertos y `[edge_runtime.secrets]` con `PUSH_PROVIDER` y `TITLE_VERIFICATION_PROVIDER` en `"fake"`). El árbol de master no se tocó.
- `start -x studio,imgproxy,logflare,vector,supavisor,postgres-meta`, con las 11 migraciones de la fase aplicadas desde cero y `edge_runtime` en `Up` desde el inicio.
- Al terminar: `stop --no-backup` y se borró el worktree. Quedaron 0 contenedores. El stack compartido `proyecto-felix` (5432x) estaba detenido y no se tocó.

## Suites automáticas
| Suite | Resultado | Evidencia |
|---|---|---|
| pgTAP (`supabase test db`) | OK, **886/886** (21 archivos) | "Files=21, Tests=886 … Result: PASS". El `190` tiene `plan(22)` y ningún `todo()` |
| `supabase db advisors` | OK | "No issues found" |
| `flutter analyze` | OK | "No issues found! (ran in 85.7s)" |
| `dart format --set-exit-if-changed lib test` | OK | "Formatted 158 files (0 changed)", código 0 |
| `flutter test -j 1` | OK, **379/379** | "All tests passed!" |
| `privacidad_e2e` | OK, 36 OK | "E2E fase 11: TODO OK", código 0 |
| `qa_privacidad_exploratorio_e2e` (ampliado en QA-db5f16c) | OK, 79 OK, **código 0** | "QA exploratorio fase 11: TODO OK", "limpieza: quedan 0 usuarios de esta corrida" |
| `auth_e2e` | OK, 22 OK | "E2E: TODO OK" |
| `urgencias_e2e` | OK, 49 OK | "E2E fase 8: TODO OK" |

## Cierre de los defectos de QA-db5f16c
| ID | Condición de cierre | Evidencia | Estado |
|---|---|---|---|
| QA-F11-07 (Medio) | El admin no escribe en `vet_profiles` ni en `vet_documents` de un titular bloqueado (42501). Los `todo` de `190` pasan a casos normales en verde | **pgTAP `190`:** los 3 casos que eran `todo` ahora son normales y dan `42501` (aprobar, anotar, revisar documentos). Los controles con un vet libre siguen en `ok`.<br>**HTTP real (exploratorio):** con el JWT del admin, `PATCH /rest/v1/vet_profiles?user_id=eq.<vet bloqueado>` da HTTP 403 y el vet sigue `pending` sin nota. `PATCH /rest/v1/vet_documents?vet_id=eq.<vet>` da HTTP 403 y queda `review_status pending`.<br>**Causa corregida:** `private.guard_vet_profile` mira el bloqueo antes del pase del admin, y las políticas de `vet_documents` usan `private.admin_may_treat` | **CERRADO** |
| O-F11-h (Bajo, observación) | Decidir si el admin puede leer y firmar el título de un vet bloqueado | Se decidió bloquearlo (`private.folder_owner_blocked`). **pgTAP `190`:** el admin no lee `vet_documents` del vet bloqueado (`42501`), pero sí los de un vet libre (1). En `storage.objects` solo ve la carpeta del vet libre.<br>**HTTP:** `POST /storage/v1/object/sign/vet-documents/...` con el admin da HTTP 400; antes daba 200 | **CERRADO** |
| QA-F11-08 (Bajo) | Se redactan `dpto` y `departamento`, o se acepta el residuo | **pgTAP `190`:** los 2 casos que eran `todo` ahora son normales y pasan. Hay 2 casos nuevos: `dpto.` y un negativo clínico.<br>**SQL directo:** `private.redact_pii(t, array['Torre B depto 51'])` devuelve `Dejar en [redactado].` para `dpto 51`, `dpto. 51`, `departamento 51` y `DPTO 51`. `Derivar al departamento de cirugía; 51 mg.` queda intacto | **CERRADO** |

## Viajes de usuario (exploratorio)
| # | Viaje | Resultado | Evidencia |
|---|---|---|---|
| 1 | Bloqueo del dueño, gracia, cancelación, exportación y borrado (con caída de Storage) | PASA | `qa_privacidad_exploratorio_e2e`, secciones A–B |
| 2 | Vet en revisión pide el borrado. El admin intenta tratarlo por RPC (QA-F11-04), por PATCH directo (QA-F11-07) y firmando su título (O-F11-h) | PASA | Líneas `[QA-F11-04]` y `[QA-F11-07]` en OK. Firmar el título da HTTP 400 |
| 3 | Escaneo final del borrado con una tabla nueva con `user_id` | PASA | "una tabla nueva con user_id entra sola al escaneo y lo hace fallar" |
| 4 | Versión nueva de la política de privacidad y consentimiento | PASA | `must_review true → false`, `ask = false` sin finalidad nueva |

## Trazabilidad SPEC (F8)
| HU | Caso(s) | Resultado |
|---|---|---|
| HU8.2 (borrado: la cuenta queda bloqueada, sin tratamiento) | pgTAP `170`/`180`/`190`, `privacidad_e2e`, exploratorio A–B y viaje 2 | PASA |
| HU8.1 / HU8.3 (exportación, acceso) | `privacidad_e2e`, exploratorio | PASA |
| HU8.6 (liquidaciones del vet sin datos del dueño) | pgTAP `180`, exploratorio | PASA |
| Redacción de PII en lo que se retiene | pgTAP `180`/`190`, `privacidad_e2e` ("la entrada retenida llega desvinculada y con la PII redactada") | PASA |

## Defectos
No hay defectos nuevos en esta iteración (no se abre QA-F11-09). QA-F11-07, QA-F11-08 y O-F11-h quedan cerrados.

## Pruebas agregadas en esta iteración
Ninguna. Las pruebas de cierre (`190` sin `todo` y los casos de O-F11-h) vienen en `008a355`, y el exploratorio ampliado de QA-db5f16c ya verificaba QA-F11-07 por HTTP.

## Riesgos y lo que NO se probó (y por qué)
- Esta re-QA es corta. No se corrieron `visitas_e2e`, `ficha_e2e`, `mascotas_e2e`, `verificacion_e2e`, `precios_e2e`, `node --test` ni los smokes de Flutter. `008a355` solo toca la migración `qa_f11_fixes_2`, el pgTAP y la documentación, y pgTAP completo (886) cubre las tablas afectadas.
- Tampoco se probó pgTAP a otra hora del día (QA-F11-02, ya cerrado en QA-db5f16c).
- No se probó la UI en un dispositivo real. El panel del admin usa la RPC (`vet_repository.dart`), no el PATCH directo.
- Siguen aceptadas por el usuario (`docs/privacidad.md` §8) y no son defectos: B2, B3, B5, O-F7-a, los límites de la redacción, el canal Realtime ≤ 1 h y los plazos de retención provisorios.
- Sigue diferido a la fase 12: O-F11-g / PE-11-03 (una solicitud puede quedar en `executing` sin alerta).

## Condiciones para aprobar la próxima versión
1. Mantener pgTAP en verde (≥ 886) y el exploratorio de privacidad con código 0.
2. Fase 12: la alerta de PE-11-03 / O-F11-g para solicitudes en `executing` vencidas.
3. Antes del release: `/security-review` y la matriz pgTAP de la ficha (CLAUDE.md).
