-- Fase 0: invariantes de seguridad que valen para TODAS las fases.
begin;
select plan(6);

select has_extension('postgis', 'PostGIS instalado');
select has_extension('btree_gist', 'btree_gist instalado (restricciones de exclusión)');
select has_schema('private', 'existe el esquema private');

select ok(
  not has_schema_privilege('authenticated', 'private', 'USAGE'),
  'authenticated no puede usar el esquema private'
);

-- Toda tabla de public debe tener RLS habilitada Y forzada.
select is_empty(
  $$ select c.relname
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p')
       and not (c.relrowsecurity and c.relforcerowsecurity) $$,
  'todas las tablas de public tienen RLS habilitada y forzada'
);

-- Ninguna función SECURITY DEFINER puede vivir en public sin estar en la lista
-- de excepciones justificadas (docs/arquitectura.md §7).
select is_empty(
  $$ select p.proname
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prosecdef
       and p.proname not in ('get_pet_record') $$,
  'no hay funciones SECURITY DEFINER no autorizadas en public'
);

select * from finish();
rollback;
