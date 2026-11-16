-- Fase 0: base de la base de datos (ver docs/arquitectura.md §4 y §7).

-- Extensiones en el esquema `extensions` (no expuesto por la Data API).
create extension if not exists postgis with schema extensions;
create extension if not exists btree_gist with schema extensions;

-- Esquema privado para helpers `security definer` y lógica interna.
-- No está en [api].schemas, así que la Data API no lo expone.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- Por defecto, las funciones nuevas no son ejecutables por PUBLIC.
-- Cada función que deba llamarse desde la app recibe un GRANT explícito.
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema private revoke execute on functions from public;
