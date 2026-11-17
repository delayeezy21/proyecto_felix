# QA — versión d0c586c (2026-11-17)
**Veredicto:** APROBADA CON OBSERVACIONES
**Alcance:** fases 0–3 y las correcciones de `docs/qa/QA-c251867.md` (migración `20261117010145_qa_fixes.sql`, Edge Function `purge-vet-documents`, `lib/`). HU1.1 (sin Google), HU1.3, HU1.4, HU1.5 (sin "en línea"), HU6.1, HU6.2 y seguridad transversal.

Motivo: todas las suites están en verde, los 22 viajes del alcance pasan por API y no quedan defectos críticos ni altos. Verifiqué de forma independiente los 12 defectos que se declararon corregidos. Quedan abiertos 1 Medio nuevo (QA-15, introducido por la corrección de QA-13) y 2 Bajos nuevos. QA-07 queda como observación aceptada. Recomendación: corregir QA-15 antes de las pruebas manuales de un vet en la UI.

## Suites automáticas
| Suite | Resultado | Evidencia |
|---|---|---|
| `dart format --set-exit-if-changed lib test` | OK | 50 archivos, 0 cambios |
| `flutter analyze` | OK | "No issues found!" |
| `flutter test` | OK | 78 pasan, 2 omitidas a propósito (QA-15) |
| `supabase test db` (pgTAP) | OK | 6 archivos, **135/135** (incluye el nuevo `050_qa_d0c586c`, con 22) |
| `supabase db advisors` | OK | `{"results":[]}` |
| `tool/e2e/auth_e2e.mjs` | OK | "E2E: TODO OK" |
| `tool/e2e/vet_e2e.mjs` | OK | "E2E fase 3: TODO OK" |
| `tool/smoke/repos_smoke_test.dart` | OK | 4/4 |
| `tool/e2e/qa_exploratorio_e2e.mjs` | 116 OK · 0 FALLA · 1 DEFECTO (QA-07) | código 2 solo por QA-07 |
| `tool/e2e/purga_e2e.mjs` (nuevo) | OK | 18/18 "Purga: TODO OK" |

Migraciones: las 5 aplicadas en la base compartida (`migration list`), sin `db reset`. Los datos manuales (demo, admin y la cuenta de Gmail) siguen intactos.

Nota de entorno: en la máquina hay un segundo stack de Supabase (`felix-ci-repro`) que no es de este QA. La primera versión de `purga_e2e.mjs` tomaba el primer contenedor `supabase_db_*` y ejecutó dos `UPDATE` (0 filas afectadas) en ese stack. Ahora elige el contenedor por el puerto de `DB_URL`.

## Verificación de las correcciones de QA-c251867
| ID | Corrección declarada | Verificado | Evidencia |
|---|---|---|---|
| QA-02 (Alto) | El guardián bloquea la declaración y `submitted_at`; se revalida al aprobar | SÍ | exploratorio: PATCH declaración en revisión o aprobado → 403; `submitted_at` → 403. pgTAP 050: aprobar sin especies → 22023 "Elige al menos una especie"; rechazar sigue funcionando |
| QA-12 | Especies y especialidades bloqueadas en revisión (BD + UI) | SÍ | DELETE y POST en revisión → bloqueados (exploratorio y pgTAP 040/050); un vet aprobado sí las cambia (HU1.5, pgTAP 050); los chips quedan deshabilitados (`qa_regresiones_test`) |
| QA-01 | El rol exige términos y aviso vigentes; el dueño exige comuna | SÍ | INSERT directo sin términos → 403. Con términos y aviso cargados, el camino manual funciona (aceptable: los términos quedan registrados). `owner_profiles` sin comuna → 42501 |
| QA-06 | `purge_after` por defecto a +90 d; la purga omite lo que está en revisión; huérfanos > 24 h | SÍ | `purga_e2e`: borrador a +90 d; los vencidos en revisión no se tocan; aprobado y borrador vencido se purgan (`{"purged":4,"orphans":1}`); huérfano viejo borrado, el reciente se conserva; RPC de purga → 403 para usuarios |
| QA-10 | El guardián confía en contextos sin usuario final | SÍ | pgTAP 040: se borra un admin que verificó vets. pgTAP 050: `service_role` actualiza la revisión y el vet autenticado sigue con 42501. Revisé el código: el rol activo lo fija PostgREST desde un JWT firmado, así que un cliente no puede forzarlo |
| QA-03 | No se suben documentos en revisión | SÍ | Storage y `vet_documents` → ≥ 400; un vet rechazado sí puede subir (pgTAP 050) |
| QA-04 | La comuna no se puede vaciar | SÍ | → error; cambiar de comuna sí funciona (pgTAP 050) |
| QA-05 | El retiro de un consentimiento es inmutable | SÍ | reescribir → 0 filas; volver a otorgar → 201 |
| QA-09 | `unique(storage_path)` | SÍ | duplicado → 23505 |
| QA-08 | `maxLength: 500` en las notas | SÍ (código) | checklist ~250 + 500 < 1000 |
| QA-11 | Mensaje real para los 22023 | SÍ (código) | `profile_repository.dart` |
| QA-13 | Texto 7/30 días y envío bloqueado mientras hay cambios sin guardar | Parcial | el texto está corregido, pero el bloqueo introdujo **QA-15** |
| QA-07 | Se propone aceptar | ACEPTADO como observación | solo afecta el entorno local: el enlace del correo apunta además a `127.0.0.1:54321`, que no abre desde el iPhone. No afecta producción |

## Viajes de usuario (exploratorio)
Son los mismos 22 viajes de `QA-c251867.md`, vueltos a ejecutar con `qa_exploratorio_e2e.mjs` y `purga_e2e.mjs`. Ahora pasan todos los que antes fallaban (7, 15, 19, 21 y 22), salvo el viaje 4, que corresponde a QA-07 (aceptado). Se agregaron tres:

| # | Viaje | Resultado | Evidencia |
|---|---|---|---|
| 23 | Purga real con el tiempo simulado (borrador, en revisión, aprobado, borrador vencido, huérfanos) | PASA | `purga_e2e.mjs` 18/18 |
| 24 | Volver a otorgar un consentimiento tras retirarlo | PASA | 201 |
| 25 | Vet en borrador: escribir y deshacer antes del autoguardado, y luego enviar (UI) | FALLA (QA-15) | widget test: queda "Guardando tus datos profesionales…" y "Enviar" deshabilitado |

## Trazabilidad SPEC
| HU | Resultado |
|---|---|
| HU1.1 confirmación del correo, términos y aviso registrados, perfil propio, formulario mínimo | PASA (Google no se probó) |
| HU1.3 vet `pending`, bucket privado, sin RUT, PDF/JPG/PNG ≤ 5 MB | PASA |
| HU1.4 aprobar o rechazar con motivo, solo el admin, auditoría, purga a 7/30 d | PASA. "Avisar al vet" sigue sin implementarse (observación) |
| HU1.5 bloques sin solape | PASA ("en línea" queda para la fase 8) |
| HU6.1 / HU6.2 catálogos | PASA (16 regiones · 346 comunas · 9 especies · 12 especialidades) |

## Defectos
| ID | Severidad | Resumen | Reproducción | Esperado vs. obtenido | Archivo sospechoso |
|---|---|---|---|---|---|
| QA-15 | Medio (nuevo) | El aviso de cambios sin guardar (`vetDataDirtyProvider`) puede quedar en `true` para siempre: `_onEdited` lo enciende, pero `_autoSave` sale sin apagarlo si ya no hay cambios (el vet escribió y deshizo) o si el dato es inválido. "Enviar a revisión" queda deshabilitado con "Guardando tus datos profesionales…" hasta tocar "Guardar" o recargar. Como el provider es global (no `autoDispose`), el estado también sobrevive a un cambio de cuenta en la misma sesión. | Vet en borrador: escribir una letra en "Universidad", borrarla antes de 900 ms y esperar | Esperado: envío habilitado. Obtenido: bloqueado con "Guardando…" (`test/ui/qa_regresiones_test.dart`, 2 casos con `skip`) | `lib/ui/features/vet/views/vet_profile_view.dart` (`_onEdited`/`_autoSave`), `vet_providers.dart` |
| QA-14 | Bajo (nuevo) | Cuando los documentos de un borrador se purgan a los 90 días (o un rechazo a los 30), la UI dice "Verificado y eliminado" o "Tus documentos ya fueron verificados y eliminados", aunque nunca se verificaron. Además, al vet no se le informa que un borrador vence a los 90 días. | Borrador con `purge_after` vencido + purga | Esperado: "Vencido, vuelve a subirlo". Obtenido: "Verificado y eliminado" | `vet_profile_view.dart` (`_DocumentsCard`, `_DocumentRow`) |
| QA-16 | Bajo (nuevo) | `docs/arquitectura.md` §8 y §8.1 no recogen la retención de 90 días para borradores, que la purga omite lo que está en revisión ni la purga de huérfanos | — | Documentación desactualizada | `docs/arquitectura.md` |
| QA-07 | Bajo, **aceptado** | Retorno a `localhost` al confirmar desde la red local | ver QA-c251867 | Limitación del entorno local | `supabase/config.toml` |

## Pruebas agregadas o ajustadas en esta iteración
- **Nuevo** `supabase/tests/database/050_qa_d0c586c.test.sql` (22 pruebas): privilegios de las RPC de purga, purga que omite lo que está en revisión, QA-12 al insertar, `submitted_at` en revisión, HU1.5 para un vet aprobado, un vet rechazado sube documentos, QA-09, privilegio por columna de `purge_after`, el plazo de 90 d, revalidación al aprobar, QA-10 con `service_role` frente al vet autenticado, QA-01 por el camino manual legítimo, registro doble con el mensaje 23505 y cambio de comuna.
- **Nuevo** `tool/e2e/purga_e2e.mjs`: purga real de punta a punta con el tiempo simulado vía `psql` en el contenedor. Elige el contenedor por el puerto de `DB_URL`.
- `test/ui/qa_regresiones_test.dart`: 2 casos de QA-15 con `skip: true` (sin el skip fallan, verificado).
- `tool/e2e/qa_exploratorio_e2e.mjs` (ajustes):
  - el check de especies en revisión pasa a llevar la etiqueta QA-12, que es la correcta (antes decía QA-02);
  - nuevo check de QA-12 al insertar una especialidad;
  - nuevo check de que se puede volver a otorgar un consentimiento;
  - texto de QA-08 actualizado;
  - comentario de la "restauración" de la declaración (ahora responde 403, como corresponde).
  
  Ninguna verificación anterior se cambió por un cambio de diseño: todas mantienen su expectativa original.

## Riesgos y lo que NO se probó
- Login con Google, UI en dispositivos reales (Android, Windows, Web, iPhone) y pg_cron con Vault: mismos motivos que en QA-c251867.
- `purga_e2e.mjs` invoca la purga real: borra cualquier documento vencido o huérfano (> 24 h) de la base local. Antes de ejecutarlo comprobé que había 0 de ambos.
- La confianza de QA-10 depende de que ningún camino permita a un cliente fijar `role` distinto de `authenticated`. Hoy no lo hay (PostgREST, Storage y GraphQL lo toman del JWT). Revisarlo si se agregan funciones `security definer` que cambien de rol.

## Condiciones para la próxima versión (APROBADA sin observaciones)
1. QA-15: apagar el aviso cuando `_autoSave` termina sin guardar (sin cambios o inválido) o cuando falla, y que el provider se reinicie por sesión (`autoDispose` o atado al usuario). Luego quitar los `skip` de QA-15.
2. QA-14 y QA-16: textos para documentos vencidos y documentación de la retención.
3. Mantener en verde todas las suites, incluidas `050_qa_d0c586c` y `purga_e2e.mjs`.
