-- Fase 1: registro, roles, perfiles, términos, aviso de privacidad y consentimientos.
begin;
select plan(27);

-- Fixtures ------------------------------------------------------------------
insert into public.legal_versions (kind, version, effective_from) values
  ('terms', 'test-v1', now()),
  ('privacy', 'test-v1', now());

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'dueno-a@test.local'),
  ('00000000-0000-0000-0000-0000000000a2', 'dueno-b@test.local'),
  ('00000000-0000-0000-0000-0000000000b1', 'vet@test.local'),
  ('00000000-0000-0000-0000-0000000000c1', 'admin@test.local'),
  ('00000000-0000-0000-0000-0000000000d1', 'sinrol@test.local');

-- El admin no se autorregistra: se crea por SQL (service role / seed).
insert into public.user_roles (user_id, role)
  values ('00000000-0000-0000-0000-0000000000c1', 'admin');

create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

-- Registro de dueño ----------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
set local role authenticated;

select is(
  public.complete_registration('owner', ' Ana ', '+56 9 1234 5678', 'test-v1', 'test-v1', (select id from public.communes where name = 'Santiago')),
  'owner', 'un dueño completa su registro');

select is((select role from public.user_roles), 'owner', 'el dueño ve su propio rol');
select is((select display_name from public.owner_profiles), 'Ana',
  'el perfil se crea con el nombre recortado');
select is((select count(*)::int from public.terms_acceptances), 1,
  'queda registrada la aceptación de términos');
select is((select count(*)::int from public.privacy_notice_views), 1,
  'queda registrado el aviso de privacidad mostrado');

select throws_ok(
  $$ select public.complete_registration('owner', 'Ana', null, 'test-v1', 'test-v1',
       (select id from public.communes where name = 'Santiago')) $$,
  '23505', null, 'no puede registrarse dos veces');

select throws_ok(
  $$ select public.complete_registration('owner', 'Ana', null, 'test-v1', 'test-v1') $$,
  '22023', 'La comuna es obligatoria', 'el dueño debe indicar su comuna');

-- No puede cambiar su rol (no hay política UPDATE ni privilegio).
select throws_ok(
  $$ update public.user_roles set role = 'admin' $$,
  '42501', null, 'no puede modificar su rol');

select throws_ok(
  $$ insert into public.user_roles (user_id, role)
     values ('00000000-0000-0000-0000-0000000000d1', 'owner') $$,
  '42501', null, 'no puede crear el rol de otro usuario');

-- Edita su perfil, pero no puede reasignarlo a otro usuario.
update public.owner_profiles set phone = '+56 9 8765 4321';
select is((select phone from public.owner_profiles), '+56 9 8765 4321',
  'el dueño edita su teléfono');
select throws_ok(
  $$ update public.owner_profiles set user_id = '00000000-0000-0000-0000-0000000000a2' $$,
  '42501', null, 'no puede reasignar su perfil a otro usuario');

-- Consentimiento opcional: otorgar y revocar.
insert into public.consents (user_id, purpose, version)
  values ('00000000-0000-0000-0000-0000000000a1', 'marketing', 'test-v1');
update public.consents set revoked_at = now() where purpose = 'marketing';
select is((select count(*)::int from public.consents where revoked_at is not null), 1,
  'el dueño revoca su consentimiento');
select throws_ok(
  $$ insert into public.consents (user_id, purpose, version)
     values ('00000000-0000-0000-0000-0000000000a2', 'marketing', 'test-v1') $$,
  '42501', null, 'no puede crear consentimientos de otro usuario');

select throws_ok(
  $$ delete from public.terms_acceptances $$,
  '42501', null, 'la aceptación de términos no se puede borrar');

reset role;

-- Validaciones del registro ---------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
set local role authenticated;

select throws_ok(
  $$ select public.complete_registration('admin', 'Hacker', null, 'test-v1', 'test-v1') $$,
  '22023', null, 'no puede autorregistrarse como admin');
select throws_ok(
  $$ select public.complete_registration('owner', 'Bea', null, 'vieja', 'test-v1') $$,
  '22023', null, 'rechaza una versión de términos no vigente');
select throws_ok(
  $$ select public.complete_registration('owner', 'Bea', null, 'test-v1', 'vieja') $$,
  '22023', null, 'rechaza una versión de privacidad no vigente');

select public.complete_registration('owner', 'Bea', null, 'test-v1', 'test-v1', (select id from public.communes where name = 'Ñuñoa'));

-- Aislamiento entre usuarios.
select is((select count(*)::int from public.owner_profiles), 1,
  'un dueño solo ve su propio perfil');
select is((select count(*)::int from public.user_roles), 1,
  'un dueño solo ve su propio rol');
select is((select count(*)::int from public.consents), 0,
  'un dueño no ve consentimientos ajenos');

reset role;

-- Registro de veterinario ------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
set local role authenticated;

select public.complete_registration('vet', 'Dra. Vera', null, 'test-v1', 'test-v1');
select is((select status from public.vet_profiles), 'pending',
  'el veterinario nace pendiente de aprobación');
select throws_ok(
  $$ update public.vet_profiles set status = 'approved' $$,
  '42501', null, 'el veterinario no puede aprobarse a sí mismo');
select is((select count(*)::int from public.owner_profiles), 0,
  'el veterinario no ve perfiles de dueños');

reset role;

-- Admin ----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000c1');
set local role authenticated;

select is((select count(*)::int from public.user_roles where user_id::text like '00000000-0000-0000-0000-0000000000%'), 4,
  'el admin ve todos los roles');
select is((select count(*)::int from public.owner_profiles where user_id::text like '00000000-0000-0000-0000-0000000000%'), 2,
  'el admin ve los perfiles de dueños');

reset role;

-- Anónimo -------------------------------------------------------------------------
set local role anon;
select ok((select count(*) from public.legal_versions) >= 2,
  'anónimo puede leer las versiones legales (para el registro)');
select throws_ok(
  $$ select * from public.user_roles $$,
  '42501', null, 'anónimo no puede leer roles');
reset role;

select * from finish();
rollback;
