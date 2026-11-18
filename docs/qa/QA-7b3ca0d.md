# QA — versión 7b3ca0d (2026-11-18), recertificación acotada
**Veredicto:** APROBADA
**Alcance:** commits `2b79f94`, `ade8cdb` y `7b3ca0d` sobre master `40afece`, con la migración `20261118181914_qa_f6_followup.sql`: QA-F6-07 (paginación de `available_vets`) y QA-F6-06 (cierre de `in_progress` y ventana de la dirección exacta). Por acuerdo con el coordinador, no se repitieron los E2E de otras áreas.

**Entorno:** un solo stack aislado `felix-qa-557` (puertos 557xx), creado desde cero sin seed adicional y bajado al terminar. No se tocaron el stack compartido (5432x) ni el servidor web.

## Suites
| Suite | Resultado |
|---|---|
| pgTAP | OK 499/499 (14 archivos) |
| `qa_visitas_exploratorio_e2e` | OK 82/82, código 0 (QA-F6-06 y QA-F6-07 pasan a OK) |
| `visitas_e2e` | OK 73/73 |
| `flutter test -j 1` | OK 256/256 |

## Revisión del diff
- **`available_vets`:**
  - excluye a los vets con un día libre que cubre el día completo (`period @> v_day`) y a los que no trabajan ese día de la semana;
  - recorre a los candidatos por distancia (KNN) en bloques de 40 hasta reunir 20 o agotar el radio;
  - mantiene el tope de 30 búsquedas por minuto.
- **`visit_active_until`:** fija la ventana de cada estado y coincide con los cierres de `expire_visits`:
  - `accepted`: hora + 1 h;
  - `en_route` y `arrived`: hora + 2 h;
  - `in_progress`: lo primero entre inicio + 6 h y hora + 8 h.
- **`visit_view`:** entrega `exact` solo si `now()` está dentro de esa ventana, aunque el cron todavía no haya cerrado la visita.
- **Cambios en mi exploratorio (no lo debilitan):**
  - El PATCH con la clave de servicio pide `pending_vet`. Antes pedía `completed`, que ya podía ser el estado actual, y así no se probaba ningún cambio real.
  - El caso KNN exige que aparezca "Vet KNN 31", el vet libre a ~15 km. Antes exigía exactamente 1 resultado, pero otros vets libres del mismo script también pueden aparecer legítimamente.

## Búsqueda de bypasses (script temporal, no versionado)
| Caso | Resultado |
|---|---|
| Visita `accepted` vencida (hora −61 min) con el cron pausado | el vet ya no ve `exact` (estado sigue `accepted`) |
| `in_progress` con inicio hace 7 h, con el cron pausado | sin `exact`. Dentro de la ventana el vet sí veía la dirección y el teléfono |
| Otras vías | `grep` de `street_text` y `phone` en las migraciones: solo `visit_view` los entrega. RLS de `addresses`, `owner_profiles` y `pets`: solo el dueño (y el admin en perfiles). GraphQL no está expuesto (`/graphql/v1` → 406 PGRST106) |
| Cierre automático como `completed` | sin actor, sin pagos (0) y sin cargo (0). El vet no puede cobrar (403). El dueño no puede cancelarla. Solo el dueño puede iniciar el pago simulado (200) |

## Observaciones (Bajo, sin bloqueo)
- **O-6:** una visita que el vet inició y nunca terminó queda `completed` y cobrable por el dueño. Es correcto que no haya cobro automático, pero en la fase 7 `completed` abrirá 30 días de acceso a la ficha. Conviene distinguir una visita cerrada por el sistema (p. ej. `closed_by_system` en `visit_events` o una marca en la visita) antes de esa fase.
- **O-7:** un día libre *parcial* no saca al vet de la preselección (solo los que cubren el día completo). Es correcto, porque sus horarios restantes se calculan igual; solo se anota.
