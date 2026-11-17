-- QA de la versión d142432: las versiones legales vigentes vienen de una
-- MIGRACIÓN (20261117150000_legal_versions_reference.sql), no solo de seed.sql.
-- En la nube no se aplica el seed: sin estas filas nadie puede registrarse.
-- Ver docs/qa/QA-d142432.md.
begin;
select plan(6);

select ok(
  exists (select 1 from supabase_migrations.schema_migrations where version = '20261117150000'),
  'la migración de referencia de versiones legales está aplicada'
);

select is(public.current_legal_version('terms'), '2026-11-16', 'términos vigentes = 2026-11-16');
select is(public.current_legal_version('privacy'), '2026-11-16', 'aviso de privacidad vigente = 2026-11-16');

-- Idempotencia: re-ejecutar el insert de la migración (y del seed) no duplica.
create temp table _antes as select count(*) as n from public.legal_versions;
insert into public.legal_versions (kind, version, effective_from) values
  ('terms', '2026-11-16', '2026-11-16'),
  ('privacy', '2026-11-16', '2026-11-16')
on conflict (kind, version) do nothing;
select is(
  (select count(*) from public.legal_versions),
  (select n from _antes),
  're-ejecutar la migración no duplica filas'
);

-- El registro necesita leer la versión vigente antes de tener sesión.
set local role anon;
select isnt(public.current_legal_version('terms'), null, 'anon lee la versión de términos vigente');
reset role;

set local role authenticated;
select throws_ok(
  $$insert into public.legal_versions (kind, version, effective_from) values ('terms', 'qa-x', now())$$,
  '42501',
  null,
  'un usuario autenticado no puede insertar versiones legales'
);
reset role;

select * from finish();
rollback;
