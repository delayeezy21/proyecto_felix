# QA — versión 26ac1c3 (2026-11-18)
**Veredicto:** APROBADA CON OBSERVACIONES
**Alcance:** recertificación de la fase 5 con `caf7a92` (QA-F5-01 y QA-F5-02) y `26ac1c3` (QA-F5-03 y O-2) sobre `docs/qa/QA-9897476.md`, más la regresión completa.

**Entorno:**
- Stack aislado `felix-qa-557` (puertos 557xx, con Mailpit y Edge Runtime), creado desde cero con las 13 migraciones.
- Al empezar solo corría el stack compartido (5432x), que no se tocó.
- Todo se corrió en secuencia; pgTAP corrió antes de `precios_e2e`.

## Suites automáticas
| Suite | Resultado | Evidencia |
|---|---|---|
| `dart format` / `flutter analyze` | OK | 103 archivos, 0 cambiados / "No issues found!" |
| `flutter test -j 1` | OK 236/236 | incluye `password_reset_neutral_test` (4) y "modo recuperación persistente (O-2)" (2) |
| pgTAP | OK 345/345 | 11 archivos |
| `db advisors` | OK | "No issues found" |
| E2E `precios` / `mascotas` / `auth` / `vet_e2e` (Edge Runtime) / `purga` | OK 45 / 32 / 22 / 23 / 17 | "TODO OK" |
| `qa_mascotas_exploratorio` | OK 65/65 | código 0 |
| `qa_exploratorio` (fases 0–3) | 116 OK, 1 DEFECTO | QA-07, ya conocido (redirección desde la LAN) |
| `qa_precios_exploratorio` (reforzado en esta iteración) | OK 84/84 | código 0 |
| Smoke de repositorios | OK 5/5 | contra el stack aislado |
| Flujo de recuperación con Mailpit | OK | pedir → correo → `/verify` (`type=recovery`) → clave débil 422 → clave nueva 200 → login nuevo 200 / viejo 400 → reusar el enlace da `otp_expired` |

## QA-F5-01 (Alto): ubicación del vet → **cerrado**
| Caso | Resultado | Evidencia |
|---|---|---|
| `quotes.distance_m` desde la API | PASA | `select=distance_m` como dueño o admin, y `select=*` → 403. `has_column_privilege('authenticated','quotes','distance_m','select')` = f |
| Lo que recibe el cliente | PASA | `distance_km` entero, medido desde `quote_origin` |
| Desplazamiento de `vet_base_offset` | PASA | 5.000 sorteos por latitud (−18,5 / −33,4 / −53,2): de 995 a 2.003 m, media ≈ 1.500 m, rumbo de 0 a 2π, ~995 valores distintos por latitud |
| **Mejor atacante posible** (conoce `quote_origin` exacto, simulado con la clave de servicio) | PASA | la base real queda a 1.025 m del origen; está dentro del anillo de 1–2 km |
| Re-sorteo para promediar | PASA | el vet no puede borrar su base (DELETE 403, sin grant), ni hacer PATCH de `fuzz_dlng` (403) o `quote_origin` (400, columna generada); mover la base no cambia `fuzz_dlat`/`fuzz_dlng` |
| ¿Quién ve `quote_origin` o el desplazamiento? | PASA | solo el propio vet (política `vet_bases_select_own`). El dueño, otro vet, el admin y una fundación → 0 filas. Que el vet vea su propio desplazamiento no le sirve a nadie más |
| Trilateración con `distance_km` (3 direcciones) | Informativo | estimación a 1.208 m de la base real |

**Revisión de los umbrales que cambió el agente en mi script:**
- Km facturables ±2 y `distance_km` ±2,5 km: son correctos. El origen está a ≤ 2 km de la base y el redondeo suma ≤ 0,5 km.
- Trilateración con un error de más de 500 m: el criterio era **débil y aleatorio**.
  - El ajuste con distancias al km tiene ruido propio, que puede acercar o alejar la estimación de la base real.
  - Además, no medía la garantía real: un atacante paciente, que mueve su dirección y busca el borde del redondeo o del `ceil` de los km facturables, recupera `quote_origin` casi exacto.
- Lo reemplacé:
  - la trilateración queda como `INFO`;
  - se agregó la verificación determinista del peor caso (el origen exacto está a entre 990 y 2.010 m de la base);
  - se agregaron las pruebas de no re-sorteo.

**¿Protege lo suficiente el anillo de 1–2 km?**
- Para el MVP, sí. La base queda en un anillo de ~9,4 km², del tamaño de un barrio o una comuna chica.
- No se puede promediar, porque el desplazamiento es fijo por vet y no se puede borrar.
- El anillo se achica si el dueño conoce la comuna de la base: `point_in_commune` obliga a que la base esté en ella. Hoy el dueño no lee `vet_profiles` ni `vet_bases`.
- Ver R-1 para la fase 6.

## QA-F5-02 (Medio): base del vet y distancia máxima → **cerrado**
- Mendoza con comuna Ñuñoa → 400; una comuna incoherente → 400 (`precios_e2e` y pgTAP).
- Una base a ~2.200 km (Punta Arenas) → la cotización desde Ñuñoa da 400 "fuera del radio de atención (máximo 30 km)".
- `pricing_config.max_distance_km` = 30, versionado y con check entre 1 y 500.
- Un vet no crea la base de otro (403) y un dueño no crea bases (403).

## QA-F5-03 (Medio): enumeración en "Olvidé mi contraseña" → **mitigado en la app; queda Bajo**
- `neutralPasswordReset` trata el 429 `over_email_send_rate_limit` como envío correcto y espera al menos 800 ms. Lo cubren los unit tests: 429 neutro, tiempo mínimo y propagación de los demás errores después de la misma espera.
- El runbook documenta el captcha (hCaptcha/Turnstile) y que `email_sent` es global en la nube.
- **Residual (Bajo):** contra la API directa, GoTrue sigue respondiendo 429 vs 200 y con tiempos distintos (medido en QA-9897476). Solo el captcha lo cierra.
- Además, con un SMTP real, el envío de una cuenta existente puede superar los 800 ms y reabrir la diferencia de tiempo en la UI. Conviene medirlo en Beta.

## O-2: modo recuperación tras una recarga → **cerrado**
- La marca se guarda en `shared_preferences` con el id del usuario; una marca de otro usuario se descarta (widget tests).
- Observación (Bajo): si la sesión de recuperación expira sin cambiar la clave y el mismo usuario vuelve a entrar con su clave, la marca sigue ahí y lo lleva a `/reset-password`. Es una molestia de UX, no un riesgo; se resuelve borrando la marca en el login con contraseña.

## Defectos abiertos
| ID | Severidad | Resumen | Reproducción | Esperado vs. obtenido | Archivo sospechoso |
|---|---|---|---|---|---|
| QA-F5-03r | Bajo | La enumeración por la API de GoTrue sigue (429 y tiempo) hasta activar el captcha | `POST /auth/v1/recover` dos veces con un correo existente | Respuesta uniforme; obtenido: 429 vs 200 | `docs/despliegue-beta.md` (captcha opcional) |
| O-1 | Bajo | `consume_quote` no compara el vet, la mascota ni la dirección; una cotización agendada sin vet no lleva recargo por distancia (viene de QA-9897476) | revisión | La fase 6 debe exigirlo | `private.consume_quote` |
| O-5 | Bajo | El recargo por distancia puede variar ±2 km (±$1.000) respecto de la distancia real. Es el costo documentado de proteger la base del vet | `precios_e2e` anula el desplazamiento para obtener montos exactos | Decisión de negocio aceptada en la migración | `20261117220000_qa_f5_fixes.sql` |

## Pruebas agregadas o ajustadas en esta iteración
`tool/e2e/qa_precios_exploratorio_e2e.mjs`, de 78 a 84 verificaciones:
- `distance_m` ilegible para el admin y con `select=*`;
- el peor atacante (origen exacto) a 1–2 km de la base;
- DELETE de la base (403), PATCH de `fuzz_dlng` y `quote_origin` rechazados;
- mover la base no re-sortea el desplazamiento;
- solo el vet ve su desplazamiento;
- la trilateración aleatoria queda como `INFO`.

## Riesgos y lo que NO se probó
- **R-1 (fase 6):** no exponer al dueño la comuna de la base del vet ni ninguna distancia calculada desde `vet_bases.location` (la real). Solo usar `quote_origin`. En la fase 8 (urgencias) la ubicación en vivo tiene su propio diseño.
- El captcha no está activo (es opcional, en la nube).
- No se probó la UI en un navegador ni en un dispositivo real; solo widget tests.

## Condiciones para aprobar la próxima versión
1. Mantener en verde todas las suites, con `qa_precios_exploratorio_e2e.mjs` en código 0.
2. En la fase 6: validar en `consume_quote` el vet, la mascota y la dirección (O-1), y cumplir R-1.
3. Antes del Beta público: activar el captcha o aceptar formalmente QA-F5-03r.
