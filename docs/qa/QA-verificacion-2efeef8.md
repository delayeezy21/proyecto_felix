# QA — Verificación asistida de títulos, versión 2efeef8 (2026-11-17)
**Veredicto:** APROBADA CON OBSERVACIONES
**Alcance:**
- Rama `worktree-agent-aefa8c2146253e1a6`: 68f2559 (análisis) y 2efeef8 (implementación), sobre master 2d379b8. El merge fue *fast-forward*.
- Edge Function `verify-vet-title`, con los proveedores `rules`, `colmevet` y `fake`.
- Migración `20261117040253_title_verifications.sql` (tabla `vet_title_verifications` y cuota).
- La revisión del admin y el disparo de la verificación al enviar la solicitud.
- Regresión completa de las fases 0–3.

Motivo:
- Todas las suites están en verde, en el stack compartido y en el aislado.
- La seguridad de la tabla y de la función se cumple: autenticación por JWT, autorización por rol, nadie escribe fuera de `service_role`, evidencia acotada y sin datos personales, y el proveedor no se puede elegir desde el cliente.
- El flujo manual sigue intacto cuando la verificación está apagada o falla.
- No hay defectos críticos, altos ni medios. Quedan 2 defectos Bajos nuevos de los límites de tasa (QA-19 y QA-20). QA-07 sigue aceptado.

**Reglas del encargo cumplidas:**
- Nunca se llamó a COLMEVET ni a sitios externos: solo `off` en el stack compartido y `fake` en el aislado, y los unit tests usan un `fetch` simulado.
- Sin `db reset`.
- Las cuentas demo, admin y la de Gmail, y la solicitud pendiente de "Dr Boby", siguen intactas.
- Todo se ejecutó en secuencia, sin tocar el servidor del iPhone.

## Suites automáticas
| Suite | Entorno | Resultado | Evidencia |
|---|---|---|---|
| `dart format --set-exit-if-changed lib test` | — | OK | 58 archivos, 0 cambios |
| `flutter analyze` | — | OK | "No issues found!" |
| `flutter test` | — | OK | **119/119** |
| `node --test …/providers.test.ts` | sin red | OK | 15/15 (`fetch` simulado que rechaza la red; HTML sintético) |
| `supabase test db` (pgTAP) | compartido | OK | 7 archivos, **155/155** (incluye `060_title_verifications`) |
| `supabase db advisors` | compartido | OK | `{"results":[]}` |
| `auth_e2e` / `vet_e2e` / `purga_e2e` / smoke 4/4 | compartido | OK | "TODO OK" |
| `qa_exploratorio_e2e.mjs` | compartido | 0 FALLA · solo QA-07 (aceptado) | código 2 solo por QA-07 |
| `verificacion_e2e.mjs` (del desarrollador) | aislado, `fake` | OK | 23/23 "TODO OK" |
| `verificacion_abuso_e2e.mjs` (nuevo) | aislado, `fake` | 17 OK · 0 FALLA · 2 DEFECTO (QA-19, QA-20) | código 2 |

Stack aislado:
- Configuración: `project_id = felix-qa-verif`, puertos 553xx, `inspector_port = 8093` y `[edge_runtime.secrets] TITLE_VERIFICATION_PROVIDER = "fake"`.
- Se levantó sin studio, imgproxy, vector, logflare, realtime, mailpit, pg-meta ni supavisor, para ahorrar memoria.
- Al terminar se bajó con `stop --no-backup` (quedan 0 contenedores).

## Seguridad de la Edge Function y de la tabla
| Control | Resultado | Evidencia |
|---|---|---|
| Sin sesión, clave publicable como token o JWT inválido | 401 | E2E, abuso |
| Quién la invoca | Admin: cualquier solicitud en revisión. Vet: solo la propia (otro `vet_id` → 403). Dueño o fundación → 403 | E2E, abuso |
| Entradas | GET → 405; JSON inválido o `vet_id` no UUID → 400; vet inexistente, sin enviar o ya resuelto → 409 | abuso, E2E |
| Elección del proveedor | Solo por la variable de entorno del servidor (`TITLE_VERIFICATION_PROVIDER`, `COLMEVET_SEARCH_URL`); el cuerpo de la petición no la influye. Por defecto `off` | revisión de `run.ts` y `index.ts` |
| Escritura en `vet_title_verifications` | Solo `service_role` (INSERT). Ni el admin inserta ni modifica (403); nadie borra; anónimo no lee | pgTAP 060, E2E, abuso |
| Lectura | El vet ve las suyas, el admin todas; otro vet o un dueño, 0 filas | E2E |
| Evidencia | `jsonb` de máximo 1 KB (rechazado incluso para `service_role`); sugerencias limitadas a `university` y `colmevet` (`name` → 400) | abuso |
| Datos personales | La respuesta y la evidencia no contienen el nombre. COLMEVET guarda solo `matches` (máximo 99) y `http_status`; los nombres de terceros se procesan en memoria | E2E y revisión de `colmevet.ts` |
| Timeout y tamaño | Un proveedor lento se corta a los 8,0 s y queda `error`; las reglas igual se registran. Tope de 1 MB al leer la respuesta (`readCapped`) | abuso, unit tests |
| Cuota RPC | `title_verification_quota` es solo para `service_role` | pgTAP, abuso |
| Sin auto-aprobación | Ningún proveedor tiene `authoritative = true`; la aprobación sigue siendo `review_vet_application`, en manos del admin | revisión de código, E2E ("el admin aprueba manualmente aunque la verificación falló") |

## Flujo manual con la verificación apagada o fallando
- En el stack compartido la función no está desplegada (404):
  - el envío del vet ignora el error (`unawaited` con `onError`);
  - la revisión muestra "Aún no hay resultados" y el botón responde "La verificación automática no está disponible. Sigue con la revisión manual.";
  - ningún E2E de las fases 0–3 cambió de resultado.
- En la UI lo cubre el widget test "si la verificación falla, el flujo manual sigue funcionando". Las sugerencias se pueden desmarcar y no se vuelven a marcar mientras no lleguen resultados nuevos.
- Las notas de revisión siguen bajo 1000 caracteres: ~230 de la lista de chequeo + ~70 del resumen + 500 de notas.

## Privacidad y aspectos legales del proveedor COLMEVET real (no se activó)
- **Revisión del código:**
  - el proveedor solo se activa por configuración del servidor;
  - busca por nombre, sin RUT;
  - no salta captchas: si los detecta, el resultado es `error`;
  - usa un User-Agent propio, timeout y tope de tamaño;
  - "sin coincidencias" es neutro.
- **Riesgos que quedan para la decisión del usuario.** Coinciden con `docs/verificacion-automatica.md` §2 y §5:
  1. Sin términos publicados ni permiso, consultar de forma automática y recurrente es un riesgo reputacional y contractual. Conviene un convenio antes de activarlo en producción.
  2. Enviar el nombre del vet a un tercero exige informarlo en la política de privacidad (Ley 21.719).
  3. **Homónimos y suplantación:** una sola coincidencia por nombre sugiere el chequeo opcional COLMEVET, pero no prueba identidad. El cotejo nombre–cédula sigue siendo manual y obligatorio.
  4. `redirect: 'follow'` sigue redirecciones del sitio: es aceptable, porque la URL base es fija en el servidor.
- **Sesgo de automatización:** la sugerencia `university` premarca un chequeo **obligatorio**. Se puede desmarcar y queda indicado como "Sugerido por la verificación automática", pero conviene recordarle al admin que debe confirmarlo.
- **Retención:** `vet_title_verifications` no tiene plazo de retención (las filas se borran junto con el vet). Contiene solo metadatos mínimos, pero conviene definir un plazo en la política, como con los documentos.

## Defectos
| ID | Severidad | Resumen | Reproducción | Esperado vs. obtenido | Archivo sospechoso |
|---|---|---|---|---|---|
| QA-19 | Bajo (nuevo) | El límite de tasa se verifica antes de insertar, sin bloqueo, así que las invocaciones simultáneas lo superan. Localmente (un solo worker): 30 peticiones en paralelo → 4 ejecuciones con un límite de 3. Con varias instancias en producción podría ser más, y lo mismo vale para el tope global de 20 consultas COLMEVET por minuto. | Vet en revisión: 30 `POST /functions/v1/verify-vet-title` en paralelo | Esperado ≤ 3. Obtenido 4 | `index.ts` (cuota y luego insert) y `title_verification_quota`: falta reservar el cupo de forma atómica (p. ej., `pg_advisory_xact_lock` por vet o una RPC que cuente e inserte en una transacción) |
| QA-20 | Bajo (nuevo) | La cuota por vet la comparten el vet y el admin. El vet puede gastar sus 3 ejecuciones (el envío ya consume 1) y el admin recibe 429 durante 10 min al tocar "Ejecutar verificación". El flujo manual no se bloquea. | El vet invoca 3 veces; el admin ejecuta | Esperado: el admin puede ejecutar. Obtenido 429 "Ya se ejecutó varias veces." | `title_verification_quota` (cuenta `run_trigger` de vet y admin juntos) |
| QA-07 | Bajo, aceptado | Retorno a `localhost` al confirmar el correo desde la red local | — | Limitación del entorno local | `supabase/config.toml` |

## Pruebas agregadas en esta iteración
- `tool/e2e/verificacion_abuso_e2e.mjs`: 19 verificaciones (autenticación, entradas, concurrencia, cuota del admin, timeout, escritura y lectura de la tabla, límites de la evidencia). Solo se ejecuta contra un stack aislado: se niega a correr si el puerto es 543xx. Marca `DEFECTO QA-19` y `DEFECTO QA-20`.

## Riesgos y lo que NO se probó
- El proveedor COLMEVET contra el sitio real: prohibido por el encargo. Solo se revisó el código y los unit tests con HTML sintético.
- La función desplegada en el stack compartido o en producción. Hoy no está desplegada en el compartido; tras el merge, el edge runtime compartido la servirá en modo `off`.
- La concurrencia con varias instancias del edge runtime (QA-19 podría ser mayor que lo medido).
- La UI en dispositivos reales.

## Condiciones para APROBADA sin observaciones
1. QA-19: reservar el cupo de forma atómica (por vet y global de COLMEVET).
2. QA-20: separar la cuota del admin de la del vet, o no contar las ejecuciones del admin contra el vet.
3. Antes de activar `colmevet` en producción: convenio o autorización de COLMEVET, actualización de la política de privacidad y plazo de retención para `vet_title_verifications`.
