# Proyecto Felix

Marketplace de veterinarios a domicilio (Flutter + Supabase). Requisitos: `SPEC.md`. Diseño: `docs/arquitectura.md`.

## Idioma
- Responde siempre en español. Solo el código, los identificadores y los comandos van en inglés.

## Memoria (NotebookLM)
- Notebook: `f18b8953-2f68-4a1b-a4d9-d220afbbfa87`. Nota principal `MEMORIA-PROYECTO` (se carga sola). Actualízala con `/guardar-memoria`.
- En todo comando `notebooklm` usa `-n f18b8953-2f68-4a1b-a4d9-d220afbbfa87` y `--json`.
- Nunca guardes secretos, tokens ni datos personales reales en el notebook.

## Comandos de prueba
- `flutter analyze` · `flutter test` · `flutter test integration_test`
- Supabase CLI fijada vía npx (no está instalada global): `npx --yes supabase@3.2.0 start` (requiere Docker) · `... test db` (pgTAP) · `... db advisors`
- Ejecutar: `flutter run -d windows --dart-define-from-file=.env` (o `-d chrome`, `-d <android>`)
- E2E Auth + REST (con `supabase start`): `node tool/e2e/auth_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"`
- Smoke de repositorios reales: `flutter test tool/smoke/repos_smoke_test.dart --dart-define=SUPABASE_PUBLISHABLE_KEY=... --dart-define=SUPABASE_SERVICE_KEY=...` (claves de `supabase status`).
- En consultas de "mi fila" filtrar siempre por `auth.uid()` en el cliente: la RLS deja al admin ver todas las filas.
- La plantilla de entorno es `env.example` (sin punto: Claude Code tiene bloqueado leer `.env.*`).
- `supabase_flutter` fijado en 2.x (v3 aún es prerelease); la clave va en `publishableKey`.

## Decisiones no obvias
- Windows usa siempre OpenStreetMap (`google_maps_flutter` no soporta Windows) y no tiene FCM: allí los avisos van por Realtime dentro de la app.
- La UI nunca llama a Supabase directo: Vista → ViewModel (Riverpod) → Repositorio → Servicio.
- Los mapas y el geocoding solo se usan vía `MapAdapter` / `GeocodingAdapter`.
- Los precios se calculan solo en el servidor (`quote_visit`) y quedan congelados en `visits.quote`.
- Los estados de la visita cambian solo vía `transition_visit`; nunca con `update` directo.
- La ficha clínica es solo inserción: las correcciones crean una entrada con `supersedes_id`.
- El vet lee la ficha solo vía la RPC `get_pet_record` (registra cada lectura); no tiene `SELECT` directo.
- Supabase local concede ALL por defecto a `anon`/`authenticated` en tablas nuevas: cada migración hace `revoke all` + `grant` mínimos (con UPDATE por columna) + `enable/force row level security` + test pgTAP. Las invariantes de `000_base.test.sql` lo vigilan.
- El registro se completa con la RPC `complete_registration` (SECURITY INVOKER); el rol solo se autoasigna como `owner`/`vet`. El admin se crea por SQL.
- Helpers `security definer` solo en el esquema `private`, con `set search_path = ''` y `(select auth.uid())`.
- Los roles van en `user_roles`, nunca en `user_metadata`.
- Montos en CLP como `integer`.
- Datos de referencia (regiones, 346 comunas, especies, especialidades, tarifas, parámetros) van en migraciones; datos demo (clínicas ficticias) en `seed.sql`. Los catálogos no se borran: se desactivan (`active`).
- `pricing_config` es versionada (solo INSERT). Cambios del admin en catálogos quedan en `admin_audit_log` (trigger `private.log_admin_change`).
- Para no perder datos locales, aplicar migraciones con `supabase migration up` (no `db reset`).
- Verificación del título **asistida** (`docs/verificacion-automatica.md`): Edge Function `verify-vet-title` + tabla `vet_title_verifications`. Solo sugiere chequeos y nunca aprueba. `TITLE_VERIFICATION_PROVIDER` = `off` (por defecto) | `fake` | `colmevet`. Nunca llamar a COLMEVET en tests ni en CI.
- E2E de la verificación (`tool/e2e/verificacion_e2e.mjs`) y unit tests de los adaptadores (`node --test supabase/functions/verify-vet-title/providers.test.ts`): se ejecutan en un stack aislado con `TITLE_VERIFICATION_PROVIDER = "fake"` en `[edge_runtime.secrets]`.
- `dart fix` puede introducir imports de `riverpod/src` y `riverpod: any`: revisar el diff después de usarlo.

## Reglas de negocio (valores por defecto, configurables en `pricing_config`)
- Comisión 15 % del servicio; 20 % de la comisión va a la fundación elegida (o a la por defecto). Donación extra: 100 % a la fundación.
- Urgencia: radio 5 → 10 → 20 km, tandas de 3 vets × 60 s, máximo 10 min; si no hay vet, sin cobro y se ofrece agendar o ver clínicas 24 h.
- Recargo de urgencia 30 % de la base; $500/km sobre 5 km.
- Cancelación gratis hasta 2 h antes (agendada) o antes de "en camino" (urgente); después $5.000.
- Acceso del vet a la ficha: desde que acepta hasta 30 días después de cerrar la visita, o por autorización revocable del dueño.
- Dirección exacta visible solo para el vet asignado mientras la visita está activa.

## Seguridad
- Secretos solo en `.env` o `supabase/.env` (ambos en `.gitignore`); nunca en el código.
- La clave `service_role`/secreta nunca va en el cliente.
- Solo datos de prueba ficticios. Antes de cada release: `/security-review` y la matriz pgTAP de la ficha.
