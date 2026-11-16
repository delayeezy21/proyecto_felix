-- Fase 0: invariantes de seguridad que valen para TODAS las fases.
begin;
select plan(9);

-- authenticated no borra ni trunca tablas de public (los borrados de datos
-- personales pasan por el job de borrado, fase 11). Excepciones: las listas
-- propias del vet (especies, especialidades y horario), que él mismo administra.
select is_empty(
  $$ select c.relname || ':' || p.priv
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     cross join unnest(array['DELETE','TRUNCATE','TRIGGER','REFERENCES']) p(priv)
     where n.nspname = 'public' and c.relkind in ('r', 'p')
       and has_table_privilege('authenticated', c.oid, p.priv)
       and not (p.priv = 'DELETE'
                and c.relname in ('vet_species', 'vet_specialties', 'vet_availability')) $$,
  'authenticated no puede borrar ni truncar tablas de public'
);

-- anon no tiene privilegios de escritura sobre ninguna tabla de public, y solo
-- lee las tablas de la lista blanca.
select is_empty(
  $$ select c.relname || ':' || p.priv
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     cross join unnest(array['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p(priv)
     where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
       and has_table_privilege('anon', c.oid, p.priv) $$,
  'anon no puede escribir en ninguna tabla de public'
);
select is_empty(
  $$ select c.relname
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
       and has_table_privilege('anon', c.oid, 'SELECT')
       and c.relname not in ('legal_versions') $$,
  'anon solo lee tablas públicas autorizadas'
);

select has_extension('postgis', 'PostGIS instalado');
select has_extension('btree_gist', 'btree_gist instalado (restricciones de exclusión)');
select has_schema('private', 'existe el esquema private');

-- `private` no se expone por la Data API; authenticated solo puede ejecutar
-- los helpers de la lista blanca (los usan las políticas RLS) y no toca tablas.
select is_empty(
  $$ select p.proname
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'private'
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
       and p.proname not in ('current_app_role', 'is_admin', 'touch_updated_at',
                              'current_vet_status') $$,
  'authenticated solo ejecuta helpers autorizados de private'
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
