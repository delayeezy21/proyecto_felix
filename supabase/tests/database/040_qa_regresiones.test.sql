-- QA (versión c251867): regresiones de los defectos encontrados por el QA
-- Reality Checker. Ver docs/qa/QA-c251867.md.
--
-- Los defectos abiertos van dentro de `todo(...)`: pg_prove los reporta como
-- "not ok # TODO" sin romper la suite. Cuando se corrijan, aparecerán como
-- "TODO passed": en ese momento hay que quitar el `todo` para que queden como
-- pruebas normales.
begin;
select plan(13);

-- Fixtures ------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000004a1', 'qa-dueno@test.local'),
  ('00000000-0000-0000-0000-0000000004a2', 'qa-sinrol@test.local'),
  ('00000000-0000-0000-0000-0000000004a3', 'qa-sinrol-vet@test.local'),
  ('00000000-0000-0000-0000-0000000004b1', 'qa-vet@test.local'),
  ('00000000-0000-0000-0000-0000000004b2', 'qa-vet-aprobado@test.local'),
  ('00000000-0000-0000-0000-0000000004c1', 'qa-admin@test.local');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000004a1', 'owner'),
  ('00000000-0000-0000-0000-0000000004b1', 'vet'),
  ('00000000-0000-0000-0000-0000000004b2', 'vet'),
  ('00000000-0000-0000-0000-0000000004c1', 'admin');
insert into public.owner_profiles (user_id, display_name, commune_id)
  select '00000000-0000-0000-0000-0000000004a1', 'Dueña QA', id
  from public.communes where name = 'Santiago';
insert into public.vet_profiles (user_id, display_name) values
  ('00000000-0000-0000-0000-0000000004b1', 'Dra. QA');
-- Vet ya aprobado por el admin QA.
insert into public.vet_profiles (user_id, display_name, status, university, graduation_year,
    declaration_accepted_at, submitted_at, reviewed_at, identity_verified_at, verified_by)
  values ('00000000-0000-0000-0000-0000000004b2', 'Dr. Aprobado', 'approved',
    'Universidad QA', 2010, now(), now(), now(), now(), '00000000-0000-0000-0000-0000000004c1');
insert into public.consents (user_id, purpose, version, revoked_at)
  values ('00000000-0000-0000-0000-0000000004a1', 'marketing', '2026-11-16', now());

create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

-- Solicitud completa del vet QA, ya enviada (en revisión).
insert into storage.objects (bucket_id, name) values
  ('vet-documents', '00000000-0000-0000-0000-0000000004b1/titulo.pdf'),
  ('vet-documents', '00000000-0000-0000-0000-0000000004b1/cedula.jpg'),
  ('vet-documents', '00000000-0000-0000-0000-0000000004b1/extra.pdf');
insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes) values
  ('00000000-0000-0000-0000-0000000004b1', 'degree_certificate',
   '00000000-0000-0000-0000-0000000004b1/titulo.pdf', 'application/pdf', 1000),
  ('00000000-0000-0000-0000-0000000004b1', 'id_card_front',
   '00000000-0000-0000-0000-0000000004b1/cedula.jpg', 'image/jpeg', 1000);
insert into public.vet_species (vet_id, species_id)
  select '00000000-0000-0000-0000-0000000004b1', id from public.species where slug = 'perro';
insert into public.vet_specialties (vet_id, specialty_id)
  select '00000000-0000-0000-0000-0000000004b1', id from public.specialties where slug = 'general';

-- QA-06: retención de documentos de una solicitud nunca enviada.
select ok(
  (select bool_and(purge_after is not null) from public.vet_documents
   where vet_id = '00000000-0000-0000-0000-0000000004b1'),
  'QA-06: todo documento subido tiene un plazo de retención (purge_after)');

select pg_temp.login('00000000-0000-0000-0000-0000000004b1');
set local role authenticated;
update public.vet_profiles
   set university = 'Universidad QA', graduation_year = 2015, declaration_accepted_at = now()
 where user_id = '00000000-0000-0000-0000-0000000004b1';
select ok(public.submit_vet_application() is not null, 'el vet QA envía su solicitud');

-- QA-02: lo enviado no se puede alterar mientras está en revisión.
select throws_ok(
  $$ update public.vet_profiles set declaration_accepted_at = null
     where user_id = '00000000-0000-0000-0000-0000000004b1' $$,
  '42501', null, 'QA-02: en revisión no se retira la declaración jurada');
select throws_ok(
  $$ update public.vet_profiles set submitted_at = '2000-01-01'
     where user_id = '00000000-0000-0000-0000-0000000004b1' $$,
  '42501', null, 'QA-02: en revisión no se reescribe la fecha de envío');
select is_empty(
  $$ delete from public.vet_species
     where vet_id = '00000000-0000-0000-0000-0000000004b1' returning species_id $$,
  'QA-02: en revisión no se quitan las especies enviadas');

-- QA-03: en revisión no se agregan documentos.
select throws_ok(
  $$ insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes)
     values ('00000000-0000-0000-0000-0000000004b1', 'other',
             '00000000-0000-0000-0000-0000000004b1/extra.pdf', 'application/pdf', 10) $$,
  '42501', null, 'QA-03: en revisión no se registran documentos nuevos');
reset role;

-- QA-02 (aprobado): la evidencia de la verificación es inmutable.
select pg_temp.login('00000000-0000-0000-0000-0000000004b2');
set local role authenticated;
select throws_ok(
  $$ update public.vet_profiles set declaration_accepted_at = null
     where user_id = '00000000-0000-0000-0000-0000000004b2' $$,
  '42501', null, 'QA-02: un vet aprobado no borra su declaración jurada');
select lives_ok(
  $$ update public.vet_profiles set bio = 'Nueva presentación'
     where user_id = '00000000-0000-0000-0000-0000000004b2' $$,
  'un vet aprobado sí edita su presentación');
reset role;

-- QA-01: registro sin pasar por complete_registration (sin términos).
select pg_temp.login('00000000-0000-0000-0000-0000000004a2');
set local role authenticated;
select throws_ok(
  $$ insert into public.user_roles (user_id, role)
     values ('00000000-0000-0000-0000-0000000004a2', 'owner') $$,
  '42501', null, 'QA-01: el rol no se autoasigna sin aceptar los términos vigentes');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000004a3');
set local role authenticated;
select throws_ok(
  $$ insert into public.user_roles (user_id, role)
     values ('00000000-0000-0000-0000-0000000004a3', 'admin') $$,
  '42501', null, 'nadie se autoasigna admin (control vigente)');
reset role;

-- QA-04 y QA-05: dueño.
select pg_temp.login('00000000-0000-0000-0000-0000000004a1');
set local role authenticated;
select throws_ok(
  $$ update public.owner_profiles set commune_id = null
     where user_id = '00000000-0000-0000-0000-0000000004a1' $$,
  null, null, 'QA-04: la comuna del dueño sigue siendo obligatoria al editar');
select is_empty(
  $$ update public.consents set revoked_at = '2099-01-01'
     where user_id = '00000000-0000-0000-0000-0000000004a1' returning id $$,
  'QA-05: un retiro ya registrado no se reescribe');
reset role;

-- QA-10: borrar la cuenta de un admin que verificó vets.
select lives_ok(
  $$ delete from auth.users where id = '00000000-0000-0000-0000-0000000004c1' $$,
  'QA-10: se puede borrar la cuenta de un admin que aprobó vets');

select * from finish();
rollback;
