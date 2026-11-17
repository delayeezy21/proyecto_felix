-- Verificación asistida del título (docs/verificacion-automatica.md):
-- tabla de resultados de solo inserción vía service_role, lectura propia o del
-- admin, cuota de ejecuciones.
begin;
select plan(20);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000006b1', 'qa6-vet@test.local'),
  ('00000000-0000-0000-0000-0000000006b2', 'qa6-otro-vet@test.local'),
  ('00000000-0000-0000-0000-0000000006a1', 'qa6-dueno@test.local'),
  ('00000000-0000-0000-0000-0000000006c1', 'qa6-admin@test.local');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000006b1', 'vet'),
  ('00000000-0000-0000-0000-0000000006b2', 'vet'),
  ('00000000-0000-0000-0000-0000000006a1', 'owner'),
  ('00000000-0000-0000-0000-0000000006c1', 'admin');
insert into public.vet_profiles (user_id, display_name, status, university, graduation_year,
    declaration_accepted_at, submitted_at) values
  ('00000000-0000-0000-0000-0000000006b1', 'Dra. Ficticia', 'pending', 'Universidad de Chile', 2015, now(), now()),
  ('00000000-0000-0000-0000-0000000006b2', 'Dr. Otro', 'pending', 'U QA', 2015, null, null);

create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

-- Estructura y privilegios ----------------------------------------------------
select has_table('public', 'vet_title_verifications', 'existe la tabla de resultados');
select ok((select relrowsecurity and relforcerowsecurity from pg_class
           where oid = 'public.vet_title_verifications'::regclass),
  'RLS habilitada y forzada');
select ok(has_table_privilege('authenticated', 'public.vet_title_verifications', 'select')
      and not has_table_privilege('authenticated', 'public.vet_title_verifications', 'insert')
      and not has_table_privilege('authenticated', 'public.vet_title_verifications', 'update')
      and not has_table_privilege('authenticated', 'public.vet_title_verifications', 'delete'),
  'authenticated solo lee (no inserta, no actualiza, no borra)');
select ok(not has_table_privilege('anon', 'public.vet_title_verifications', 'select'),
  'anon no lee resultados');
select ok(has_table_privilege('service_role', 'public.vet_title_verifications', 'insert')
      and not has_table_privilege('service_role', 'public.vet_title_verifications', 'update')
      and not has_table_privilege('service_role', 'public.vet_title_verifications', 'delete'),
  'service_role solo inserta (resultados inmutables)');
select ok(not has_function_privilege('authenticated', 'public.title_verification_quota(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.title_verification_quota(uuid)', 'execute')
      and has_function_privilege('service_role', 'public.title_verification_quota(uuid)', 'execute'),
  'la cuota solo la ejecuta service_role');

-- Restricciones de minimización ------------------------------------------------
set local role service_role;
select lives_ok(
  $$ insert into public.vet_title_verifications
       (vet_id, source, outcome, risk, suggested_checks, evidence, run_trigger, provider_version)
     values ('00000000-0000-0000-0000-0000000006b1', 'rules', 'match', 'low',
             array['university'], '{"university_known": true}', 'submit', 'rules-1') $$,
  'service_role registra un resultado');
select throws_ok(
  $$ insert into public.vet_title_verifications
       (vet_id, source, outcome, risk, suggested_checks, run_trigger, provider_version)
     values ('00000000-0000-0000-0000-0000000006b1', 'rules', 'match', 'low',
             array['name'], 'submit', 'rules-1') $$,
  '23514', null, 'ningún proveedor puede sugerir "el nombre coincide" (lo confirma una persona)');
select throws_ok(
  $$ insert into public.vet_title_verifications
       (vet_id, source, outcome, risk, suggested_checks, run_trigger, provider_version)
     values ('00000000-0000-0000-0000-0000000006b1', 'rules', 'match', 'low',
             array['code'], 'submit', 'rules-1') $$,
  '23514', null, 'ningún proveedor puede sugerir "verifiqué el certificado"');
select throws_ok(
  $$ insert into public.vet_title_verifications
       (vet_id, source, outcome, risk, evidence, run_trigger, provider_version)
     values ('00000000-0000-0000-0000-0000000006b1', 'colmevet', 'match', 'low',
             jsonb_build_object('blob', repeat('x', 3000)), 'submit', 'colmevet-1') $$,
  '23514', null, 'la evidencia tiene tamaño acotado');
select throws_ok(
  $$ insert into public.vet_title_verifications
       (vet_id, source, outcome, risk, run_trigger, provider_version)
     values ('00000000-0000-0000-0000-0000000006b1', 'scraper', 'match', 'low', 'submit', 'x-1') $$,
  '23514', null, 'solo fuentes conocidas');
select throws_ok(
  $$ update public.vet_title_verifications set outcome = 'no_match' $$,
  '42501', null, 'service_role no modifica resultados');
select is((select count(*)::int from public.title_verification_quota('00000000-0000-0000-0000-0000000006b1')
           where vet_ok and colmevet_ok), 1, 'con 1 ejecución reciente hay cuota');
insert into public.vet_title_verifications (vet_id, source, outcome, risk, run_trigger, provider_version)
  values ('00000000-0000-0000-0000-0000000006b1', 'rules', 'match', 'low', 'admin', 'rules-1'),
         ('00000000-0000-0000-0000-0000000006b1', 'rules', 'match', 'low', 'admin', 'rules-1');
select is((select vet_ok from public.title_verification_quota('00000000-0000-0000-0000-0000000006b1')),
  false, 'cuota por vet: máximo 3 ejecuciones cada 10 minutos');
select is((select vet_ok from public.title_verification_quota('00000000-0000-0000-0000-0000000006b2')),
  true, 'la cuota es por vet');
reset role;

-- Lectura: propio vet y admin; nadie más ----------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000006b1');
set local role authenticated;
select is((select count(*)::int from public.vet_title_verifications), 3,
  'el vet ve sus propios resultados');
select throws_ok(
  $$ insert into public.vet_title_verifications (vet_id, source, outcome, risk, run_trigger, provider_version)
     values ('00000000-0000-0000-0000-0000000006b1', 'rules', 'match', 'low', 'submit', 'rules-1') $$,
  '42501', null, 'el vet no puede fabricar un resultado');
reset role;

select pg_temp.login('00000000-0000-0000-0000-0000000006b2');
set local role authenticated;
select is((select count(*)::int from public.vet_title_verifications), 0,
  'otro vet no ve resultados ajenos');
reset role;

select pg_temp.login('00000000-0000-0000-0000-0000000006a1');
set local role authenticated;
select is((select count(*)::int from public.vet_title_verifications), 0,
  'un dueño no ve resultados');
reset role;

select pg_temp.login('00000000-0000-0000-0000-0000000006c1');
set local role authenticated;
select is((select count(*)::int from public.vet_title_verifications
           where vet_id = '00000000-0000-0000-0000-0000000006b1'), 3,
  'el admin ve los resultados');
reset role;

select * from finish();
rollback;
