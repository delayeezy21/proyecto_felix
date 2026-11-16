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
- `supabase start` (requiere Docker) · `supabase test db` (pgTAP) · `supabase db advisors`
- Ejecutar: `flutter run -d windows --dart-define-from-file=.env` (o `-d chrome`, `-d <android>`)

## Decisiones no obvias
- Windows usa siempre OpenStreetMap (`google_maps_flutter` no soporta Windows) y no tiene FCM: allí los avisos van por Realtime dentro de la app.
- La UI nunca llama a Supabase directo: Vista → ViewModel (Riverpod) → Repositorio → Servicio.
- Los mapas y el geocoding solo se usan vía `MapAdapter` / `GeocodingAdapter`.
- Los precios se calculan solo en el servidor (`quote_visit`) y quedan congelados en `visits.quote`.
- Los estados de la visita cambian solo vía `transition_visit`; nunca con `update` directo.
- La ficha clínica es solo inserción: las correcciones crean una entrada con `supersedes_id`.
- El vet lee la ficha solo vía la RPC `get_pet_record` (registra cada lectura); no tiene `SELECT` directo.
- Las tablas nuevas de `public` no se exponen solas: cada migración incluye `grant` + `enable/force row level security` + un test pgTAP.
- Helpers `security definer` solo en el esquema `private`, con `set search_path = ''` y `(select auth.uid())`.
- Los roles van en `user_roles`, nunca en `user_metadata`.
- Montos en CLP como `integer`.

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
