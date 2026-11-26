# Proyecto Felix

Marketplace de veterinarios a domicilio (Flutter + Supabase). Requisitos: `SPEC.md`. Diseño: `docs/arquitectura.md`.

## Idioma y reserva de uso
- Responde siempre en español. Solo el código, los identificadores y los comandos van en inglés.
- Mantén siempre 20 % del límite de uso de la sesión libre. Al llegar al 80 %, o ante el primer aviso de límite (429), detén el desarrollo y los agentes, ejecuta `/guardar-memoria` y envía al usuario un PDF TDAH con el estado de los servicios, las pruebas y los avances del equipo.

## Memoria (NotebookLM)
- Notebook: `f18b8953-2f68-4a1b-a4d9-d220afbbfa87`. Nota principal `MEMORIA-PROYECTO` (se carga sola). Actualízala con `/guardar-memoria`.
- En todo comando `notebooklm` usa `-n f18b8953-2f68-4a1b-a4d9-d220afbbfa87` y `--json`.
- Nunca guardes secretos, tokens ni datos personales reales en el notebook.

## Comandos de prueba
- `flutter analyze` · `flutter test` · `flutter test integration_test`
- Supabase CLI fijada vía npx (no está instalada global): `npx --yes supabase@3.2.0 start` (requiere Docker) · `... test db` (pgTAP) · `... db advisors`
- Ejecutar: `flutter run -d windows --dart-define-from-file=.env` (o `-d chrome`, `-d <android>`)
- E2E Auth + REST (con `supabase start`): `node tool/e2e/auth_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"` Igual con `mascotas_e2e.mjs`, `privacidad_e2e.mjs`, `urgencias_e2e.mjs` (con `PUSH_PROVIDER = "fake"` en `[edge_runtime.secrets]`) `suscripciones_e2e.mjs` (fase 10) y `precios_e2e.mjs` (este publica versiones de `pricing_config`: correr pgTAP antes, en un stack limpio).
- Smoke de repositorios reales: `flutter test tool/smoke/repos_smoke_test.dart --dart-define=SUPABASE_PUBLISHABLE_KEY=... --dart-define=SUPABASE_SERVICE_KEY=...` (claves de `supabase status`).
- En consultas de "mi fila" filtrar siempre por `auth.uid()` en el cliente: la RLS deja al admin ver todas las filas.
- La plantilla de entorno es `env.example` (sin punto: Claude Code tiene bloqueado leer `.env.*`).
- `supabase_flutter` fijado en 2.x (v3 aún es prerelease); la clave va en `publishableKey`.

## Decisiones no obvias
- Windows usa siempre OpenStreetMap (`google_maps_flutter` no soporta Windows) y no tiene FCM: allí los avisos van por Realtime dentro de la app. iOS también usa OSM hasta probar la clave nativa en un Mac, y el geocoding en Web siempre es Nominatim (Google REST no admite CORS).
- Mascotas y direcciones: solo las ve su dueño (el admin tampoco, por minimización). `addresses.location` es columna generada desde `lat`/`lng`, validada contra `commune_boundaries` (BCN vía geoBoundaries, CC BY 3.0 IGO; margen de 2,5 km). Tiles OSM por `OSM_TILE_URL` (los públicos solo para desarrollo). El geocoding de Google requiere `GOOGLE_GEOCODING_API_KEY` propia; si no hay, Nominatim.
- La UI nunca llama a Supabase directo: Vista → ViewModel (Riverpod) → Repositorio → Servicio.
- Los mapas y el geocoding solo se usan vía `MapAdapter` / `GeocodingAdapter`.
- Los precios se calculan solo en el servidor (`quote_visit` → fila inmutable en `quotes`); `book_visit` la consume con `private.consume_quote(id, dueño, vet, mascota, dirección)` (exige vet y que coincidan) y congela su snapshot en `visits.quote`. Pago al vet = precio de lista (servicio + `plan_subsidy`) − comisión (`private.clp_round`, mitad hacia arriba).
- Suscripciones (arquitectura §5.2): el descuento del plan lo absorbe la plataforma (`plan_subsidy`); comisión, fundación y vet se calculan sobre el precio de lista. Al vet y a la fundación nunca se les muestra el plan: en sus vistas `service_price` es el de lista. Preventiva incluida = agendada de `prevencion` con cupo (12 meses móviles por dueño); el trigger `visits_plan` la revalida al reservar. Período mensual en fecha de Chile anclado al alta; renueva pg_cron `renew-subscriptions`.
- Pagos solo simulados (`provider = 'simulated'`): `simulate_payment(p_visit_id)` solo para visitas `completed`; el cargo por cancelación tardía se registra como pago `cancel_fee`. El vet no lee `payments` (HU8.6): sus liquidaciones solo por `my_payouts()`, sin dueño, total ni donación. Las fundaciones no leen pagos ni aportes: solo `foundation_summary()` (totales por mes). Sus miembros se crean por SQL.
- La distancia al vet se mide desde `vet_bases.quote_origin` (base desplazada 1–2 km al azar, fija): nunca exponer `quotes.distance_m` ni la base real; tope `pricing_config.max_distance_km`.
- Los estados de la visita cambian solo vía `transition_visit` (el trigger `private.guard_visit` rechaza todo otro cambio). Agenda en hora de Chile; slot = 60 min + 30 de traslado (exclusión `visits_no_overlap`); se reserva con ≥ 3 h; pg_cron `expire-visits` expira las pendientes y cierra como `cancelled_vet` (sin cargo) las confirmadas sin "en camino" 1 h después. El vet ve la dirección exacta solo vía `my_visits` (accepted → in_progress); el admin, solo `admin_visit_summary`.
- El horario de una visita es inmutable; los tests lo mueven solo desde una sesión directa de `postgres` con `felix.time_travel = 'on'` (`tool/e2e/sql.mjs`, `docker exec` + psql, solo stacks locales). Reglas de llegar/iniciar/completar y cierres automáticos: `private.visit_timing()`; "en curso" se cierra como completada a las 6 h (`visit_progress_limits`) (arquitectura §5).
- Urgencias (arquitectura §6): el despacho mide desde `vet_presence` (posición redondeada, sin historial), nunca desde la casa ni `vet_bases`; en urgencias `confirm_deadline` = fin de la búsqueda (10 min). Solo `accept_offer` asigna (bloquea la visita antes que la oferta) y es el único momento en que el guardián deja fijar `scheduled_at`/`slot` y reemplazar `visits.quote` por la cotización final con distancia (misma versión de `pricing_config`).
- Push solo vía la cola `private.push_outbox` + Edge Function `send-push` (`PUSH_PROVIDER` = `off` | `fake` | `fcm`; payload solo `visit_id` + evento). Nunca llamar a FCM en tests ni en CI. Una Edge Function nueva exige reiniciar el stack (`stop` + `start`) para que se sirva.
- Calificaciones (arquitectura §5.1): `ratings` y `vet_cancel_alerts` no tienen grants; todo va por RPC (`rate_visit`, `visit_rating_status`, `my_ratings_received`, `my_rating_summary`, `vet_rating_summary`, `admin_*`). La publicación es por consulta: visible desde `coalesce(published_at, completed_at + 168 h)`, sin pg_cron. `hidden` oculta solo el comentario. `rating_avg`/`cancel_count_30d` se calculan al consultar; las `cancelled_vet` cerradas por el sistema también cuentan para la alerta (≥ 3 en 720 h).
- La ficha clínica es solo inserción: las correcciones crean una entrada con `supersedes_id`.
- Cuenta bloqueada (borrado pedido, arquitectura §8.2): la frena el pre-request de PostgREST `public.check_request` (403, `hint: account_blocked`; solo deja `my_deletion_request`, `cancel_account_deletion` y `export_my_data`) más políticas restrictivas en Storage/Realtime; un helper nuevo que dé acceso de terceros a datos de un titular debe excluir `private.is_blocked(...)`.
- Con clave de servicio o en una RPC del admin el pre-request no actúa: antes de tratar datos de un titular, rechaza si está bloqueado (`any_account_blocked` en Edge Functions, `private.assert_subject_not_blocked` en RPC invoker). El trigger `felix_blocked_account_guard` en `auth.users` frena los cambios de metadatos, email y teléfono por la Auth API.
- En pgTAP y E2E la fecha "de hoy" es `(now() at time zone 'America/Santiago')::date`, nunca `current_date`; los pgTAP afectados corren con `set local timezone = 'Etc/GMT-14'` para delatarlo, y las horas de prueba se anclan a una hora fija de Chile.
- En la app, el bloqueo lo detecta `AccountBlockedHttpClient` (cliente HTTP de Supabase) y el router lleva a `/account-blocked`; en repositorios usa `isAccountBlocked(e)` (no `e.hint` solo: con `maybeSingle()` postgrest-dart pierde el hint).
- El job de borrado corre en pg_cron (sesión `postgres`, con `felix.record_maintenance`/`felix.privacy_erasure`), nunca desde una Edge Function; su escaneo final descubre por catálogo toda columna con `user_id`/`pet_id`, así que una tabla nueva con datos de un titular debe tener su paso en `private.erase_subject` o el borrado queda en `executing`.
- El vet lee la ficha solo vía `get_pet_record` (registra cada lectura; sin `SELECT` directo) y baja adjuntos solo con URL firmada de 60 s (Edge Function `clinical-attachment-url`).
- Supabase local concede ALL por defecto a `anon`/`authenticated` en tablas nuevas: cada migración hace `revoke all` + `grant` mínimos (con UPDATE por columna) + `enable/force row level security` + test pgTAP. Las invariantes de `000_base.test.sql` lo vigilan.
- El registro se completa con la RPC `complete_registration` (SECURITY INVOKER); el rol solo se autoasigna como `owner`/`vet`. El admin se crea por SQL.
- "Olvidé mi contraseña": `resetPasswordForEmail` vuelve con el evento `passwordRecovery`; mientras `passwordRecoveryProvider` sea true, el router solo deja `/reset-password`.
- Helpers `security definer` solo en el esquema `private`, con `set search_path = ''` y `(select auth.uid())`.
- Los roles van en `user_roles`, nunca en `user_metadata`. Montos en CLP como `integer`.
- Datos de referencia (regiones, 346 comunas, especies, especialidades, tarifas, parámetros) van en migraciones; datos demo (clínicas ficticias) en `seed.sql`. Los catálogos no se borran: se desactivan (`active`).
- `pricing_config` es versionada (solo INSERT). Cambios del admin en catálogos quedan en `admin_audit_log` (trigger `private.log_admin_change`).
- Para no perder datos locales, aplicar migraciones con `supabase migration up` (no `db reset`).
- Verificación del título **asistida** (`docs/verificacion-automatica.md`): Edge Function `verify-vet-title` + tabla `vet_title_verifications`. Solo sugiere chequeos y nunca aprueba. `TITLE_VERIFICATION_PROVIDER` = `off` (por defecto) | `fake` | `colmevet`. Nunca llamar a COLMEVET en tests ni en CI.
- E2E de la verificación (`tool/e2e/verificacion_e2e.mjs`) y unit tests de los adaptadores (`node --test supabase/functions/verify-vet-title/providers.test.ts`): se ejecutan en un stack aislado con `TITLE_VERIFICATION_PROVIDER = "fake"` en `[edge_runtime.secrets]`.
- `dart fix` puede introducir imports de `riverpod/src` y `riverpod: any`: revisar el diff después de usarlo.
- Todo latido o temporizador de la app (refrescos, presencia, cuentas regresivas, ubicación en vivo) se pide a `clockProvider`; en los tests `testApp` usa `ManualClock` (`fire`/`advance`). En los notifiers no hagas `await` de `StreamSubscription.cancel()`: en FakeAsync se queda colgado.

## Reglas de negocio (valores por defecto, configurables en `pricing_config`)
- Comisión 15 % del servicio; 20 % de la comisión va a la fundación elegida (o a la por defecto). Donación extra: 100 % a la fundación.
- Consulta general a domicilio: $26.990 todo incluido hasta 5 km (vet $22.941), en `tariffs` vía migración. Opción sin activar: `pricing_config.commission_on_distance = false` (recargo por km 100 % al vet).
- Urgencia: radio 5 → 10 → 20 km, tandas de 3 vets × 60 s, máximo 10 min; si no hay vet, sin cobro y se ofrece agendar o ver clínicas 24 h.
- Recargo de urgencia 30 % de la base; $500/km sobre 5 km.
- Cancelación gratis hasta 2 h antes (agendada) o antes de "en camino" (urgente); después $5.000 (`cancel_fee`, `cancel_free_hours` de la versión congelada en la cotización).
- Acceso del vet a la ficha: desde que acepta hasta 30 días después de completar la visita (también si la cerró el sistema, `closed_by_system`; cancelada = fin inmediato), o por autorización revocable del dueño. Escribe solo desde "llegó".
- Dirección exacta visible solo para el vet asignado mientras la visita está activa.

## Seguridad
- Secretos solo en `.env` o `supabase/.env` (ambos en `.gitignore`); nunca en el código.
- La clave `service_role`/secreta nunca va en el cliente.
- Solo datos de prueba ficticios. Antes de cada release: `/security-review` y la matriz pgTAP de la ficha.
