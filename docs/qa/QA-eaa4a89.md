# QA — versión eaa4a89 (2026-11-17)
**Veredicto:** APROBADA CON OBSERVACIONES
**Alcance:** fases 0–3 y las correcciones de `docs/qa/QA-d0c586c.md` (QA-15, QA-14, QA-16). No hay migraciones nuevas: la última sigue siendo `20261117010145`. Cambiaron `vet_profile_view.dart`, `vet_providers.dart`, `docs/arquitectura.md` y `ci.yml`.

Motivo: todas las suites están en verde, todos los viajes del alcance pasan y no hay defectos críticos, altos ni medios abiertos. Verifiqué las 3 correcciones. Queda 1 defecto Bajo nuevo (QA-17): dos casos borde de la lógica del aviso de "cambios sin guardar". QA-07 sigue aceptado como limitación del entorno local.

## Suites automáticas
| Suite | Resultado | Evidencia |
|---|---|---|
| `dart format --set-exit-if-changed lib test` | OK | 50 archivos, 0 cambios |
| `flutter analyze` | OK | "No issues found!" |
| `flutter test` | OK | 82 pasan, 2 omitidas a propósito (QA-17) |
| `supabase test db` (pgTAP) | OK | 6 archivos, 135/135 |
| `supabase db advisors` | OK | `{"results":[]}` |
| `tool/e2e/auth_e2e.mjs` / `vet_e2e.mjs` | OK | "TODO OK" en ambos |
| `tool/smoke/repos_smoke_test.dart` | OK | 4/4 |
| `tool/e2e/qa_exploratorio_e2e.mjs` | 116 OK · 0 FALLA · 1 DEFECTO (QA-07, aceptado) | código 2 solo por QA-07 |
| `tool/e2e/purga_e2e.mjs` | OK | "Purga: TODO OK". Antes de ejecutarlo había 0 documentos vencidos y 0 huérfanos |

Base compartida: 5 migraciones aplicadas, sin `db reset`. Las cuentas demo, admin y la de Gmail siguen intactas, y quedan 0 usuarios `qa-*`.

## Verificación de las correcciones de QA-d0c586c
| ID | Verificado | Evidencia |
|---|---|---|
| QA-15 (Medio) | SÍ | los 2 casos de `qa_regresiones_test.dart` ya corren sin `skip` y pasan (escribir y deshacer; dato inválido). El provider es `autoDispose`. Revisé el código: el aviso se apaga en `finally` |
| QA-14 (Bajo) | SÍ | 2 widget tests nuevos: un borrador vencido muestra "Eliminado por vencimiento (90 días): súbelo de nuevo" y un rechazo purgado "Eliminado tras el rechazo…", sin decir "verificados", y además se pide el documento en "Te falta". Un vet aprobado con documentos purgados sí ve "verificados y eliminados" |
| QA-16 (Bajo) | SÍ | `docs/arquitectura.md` §8 (retención de 7, 30 y 90 días, y 24 h para huérfanos) y §8.1 (privilegio por columna, que la purga omite lo que está en revisión y la RPC solo para `service_role`) coinciden con la migración y con `purga_e2e` |
| Cambio en CI | Revisado | `supabase start` reintenta una vez ante fallas del entorno. No afecta a las pruebas |

## Viajes de usuario
Los 25 viajes de `QA-d0c586c.md`, vueltos a ejecutar (exploratorio, purga y widget tests):
- pasan todos, incluido el 25 (escribir y deshacer y luego enviar), que antes fallaba por QA-15;
- el 4 corresponde a QA-07, que está aceptado.

Agregué dos casos borde de la UI del vet, que fallan: ver QA-17.

## Trazabilidad SPEC
Sin cambios respecto de `QA-d0c586c.md`: HU1.1 (sin Google), HU1.3, HU1.4, HU1.5 (sin "en línea") y HU6.1/HU6.2 pasan. Observación que se mantiene: HU1.4 pide "avisar al vet" y aún no se le avisa (llegará con las notificaciones de las fases siguientes).

## Defectos
| ID | Severidad | Resumen | Reproducción | Esperado vs. obtenido | Archivo sospechoso |
|---|---|---|---|---|---|
| QA-17 | Bajo (nuevo) | El envío se habilita aunque en pantalla haya datos distintos de los guardados. (a) **Dato inválido:** `_autoSave` apaga el aviso y no guarda, así que se envía el valor anterior de la BD mientras la pantalla muestra otro. (b) **Edición durante un guardado en curso:** el `finally` del primer guardado apaga el aviso mientras el segundo sigue en curso, y queda una ventana para enviar en la que el último cambio se pierde (o lo rechaza el guardián, que ya bloqueó los datos). | (a) Solicitud completa: cambiar el año a "19" y esperar 1 s → "Enviar" habilitado. (b) Con una red lenta (~2 s por guardado), editar, editar de nuevo durante el guardado y enviar justo al terminar el primero | Esperado: no enviar mientras haya cambios inválidos o un guardado pendiente. Obtenido: envío habilitado (2 widget tests con `skip` que fallan sin él) | `lib/ui/features/vet/views/vet_profile_view.dart` (`_autoSave`: apagar el aviso solo si no hay otro guardado ni debounce activo; con un dato inválido, mantener el bloqueo) |
| QA-07 | Bajo, aceptado | Al confirmar el correo desde la red local vuelve a `localhost` | ver QA-c251867 | Limitación del entorno local | `supabase/config.toml` |

## Pruebas agregadas en esta iteración
- `test/ui/qa_regresiones_test.dart`:
  - grupo QA-17 con 2 casos en `skip: true`, que fallan sin el skip (verificado). Incluye `_SlowVetRepository`, que simula la latencia de la red;
  - grupo QA-14 con 2 casos que pasan.
- No cambié las suites de backend: siguen vigentes y en verde.

## Riesgos y lo que NO se probó
- Igual que en las iteraciones anteriores: Google OAuth, UI en dispositivos reales y pg_cron con Vault.
- `purga_e2e.mjs` ejecuta la purga real de la base local. Antes de cada ejecución verifico que haya 0 documentos vencidos y 0 huérfanos.

## Condiciones para la próxima versión (APROBADA sin observaciones)
1. Corregir QA-17 y quitar sus `skip`.
2. Mantener en verde todas las suites.
