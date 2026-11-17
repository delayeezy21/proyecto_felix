-- QA de la versión d0c586c: pruebas de las correcciones de QA-c251867 que no
-- tenían prueba propia y regresiones de los flujos legítimos que tocaron.
-- Ver docs/qa/QA-d0c586c.md.
begin;
select plan(22);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000005a1', 'qa5-dueno@test.local'),
  ('00000000-0000-0000-0000-0000000005a2', 'qa5-manual@test.local'),
  ('00000000-0000-0000-0000-0000000005b1', 'qa5-vet-revision@test.local'),
  ('00000000-0000-0000-0000-0000000005b2', 'qa5-vet-aprobado@test.local'),
  ('00000000-0000-0000-0000-0000000005b3', 'qa5-vet-rechazado@test.local'),
  ('00000000-0000-0000-0000-0000000005c1', 'qa5-admin@test.local');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000005b1', 'vet'),
  ('00000000-0000-0000-0000-0000000005b2', 'vet'),
  ('00000000-0000-0000-0000-0000000005b3', 'vet'),
  ('00000000-0000-0000-0000-0000000005c1', 'admin');
insert into public.vet_profiles (user_id, display_name, status, university, graduation_year,
    declaration_accepted_at, submitted_at, rejection_reason, reviewed_at) values
  ('00000000-0000-0000-0000-0000000005b1', 'Dra. Revisión', 'pending', 'U QA', 2015, now(), now(), null, null),
  ('00000000-0000-0000-0000-0000000005b2', 'Dr. Aprobado', 'approved', 'U QA', 2015, now(), now(), null, now()),
  ('00000000-0000-0000-0000-0000000005b3', 'Dra. Rechazada', 'rejected', 'U QA', 2015, now(), null, 'Falta folio', now());
insert into storage.objects (bucket_id, name) values
  ('vet-documents', '00000000-0000-0000-0000-0000000005b1/titulo.pdf'),
  ('vet-documents', '00000000-0000-0000-0000-0000000005b1/cedula.pdf'),
  ('vet-documents', '00000000-0000-0000-0000-0000000005b3/titulo.pdf');
insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes, purge_after) values
  ('00000000-0000-0000-0000-0000000005b1', 'degree_certificate',
   '00000000-0000-0000-0000-0000000005b1/titulo.pdf', 'application/pdf', 10, now() - interval '1 day'),
  ('00000000-0000-0000-0000-0000000005b1', 'id_card_front',
   '00000000-0000-0000-0000-0000000005b1/cedula.pdf', 'application/pdf', 10, now() - interval '1 day');
insert into public.vet_species (vet_id, species_id)
  select '00000000-0000-0000-0000-0000000005b1', id from public.species where slug = 'perro';
insert into public.vet_specialties (vet_id, specialty_id)
  select '00000000-0000-0000-0000-0000000005b1', id from public.specialties where slug = 'general';

create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

-- Privilegios de las RPC de purga --------------------------------------------
select ok(not has_function_privilege('authenticated', 'public.purge_candidates(integer)', 'execute')
      and not has_function_privilege('anon', 'public.purge_candidates(integer)', 'execute'),
  'purge_candidates no es ejecutable por usuarios');
select ok(not has_function_privilege('authenticated', 'public.purge_orphan_candidates(integer)', 'execute')
      and not has_function_privilege('anon', 'public.purge_orphan_candidates(integer)', 'execute'),
  'purge_orphan_candidates no es ejecutable por usuarios');
select ok(has_function_privilege('service_role', 'public.purge_candidates(integer)', 'execute')
      and has_function_privilege('service_role', 'public.purge_orphan_candidates(integer)', 'execute'),
  'el rol de servicio sí ejecuta las RPC de purga');
select ok(
  not exists (select 1 from private.vet_documents_due(1000)
              where storage_path like '00000000-0000-0000-0000-0000000005b1/%'),
  'QA-06: la purga omite los documentos vencidos de una solicitud en revisión');

-- QA-12: en revisión no se agregan especialidades; aprobado sí (HU1.5) ---------
select pg_temp.login('00000000-0000-0000-0000-0000000005b1');
set local role authenticated;
select throws_ok(
  $$ insert into public.vet_specialties (vet_id, specialty_id)
     select '00000000-0000-0000-0000-0000000005b1', id from public.specialties where slug = 'urgencias' $$,
  '42501', null, 'QA-12: en revisión no se agregan especialidades');
select throws_ok(
  $$ update public.vet_profiles set submitted_at = now() + interval '1 hour'
     where user_id = '00000000-0000-0000-0000-0000000005b1' $$,
  '42501', null, 'QA-02: en revisión no se cambia la fecha de envío');
reset role;

select pg_temp.login('00000000-0000-0000-0000-0000000005b2');
set local role authenticated;
select lives_ok(
  $$ insert into public.vet_species (vet_id, species_id)
     select '00000000-0000-0000-0000-0000000005b2', id from public.species where slug = 'gato' $$,
  'HU1.5: un vet aprobado sigue eligiendo sus especies');
select lives_ok(
  $$ delete from public.vet_species where vet_id = '00000000-0000-0000-0000-0000000005b2' $$,
  'HU1.5: un vet aprobado puede quitar especies');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('vet-documents', '00000000-0000-0000-0000-0000000005b2/nuevo.pdf') $$,
  '42501', null, 'un vet aprobado no sube documentos');
reset role;

-- Documentos: privilegio por columna, plazo por defecto, unicidad ------------
select pg_temp.login('00000000-0000-0000-0000-0000000005b3');
set local role authenticated;
select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('vet-documents', '00000000-0000-0000-0000-0000000005b3/titulo2.pdf') $$,
  'un vet rechazado puede subir documentos para reenviar');
select lives_ok(
  $$ insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes)
     values ('00000000-0000-0000-0000-0000000005b3', 'degree_certificate',
             '00000000-0000-0000-0000-0000000005b3/titulo.pdf', 'application/pdf', 10) $$,
  'un vet rechazado registra un documento');
select throws_ok(
  $$ insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes)
     values ('00000000-0000-0000-0000-0000000005b3', 'other',
             '00000000-0000-0000-0000-0000000005b3/titulo.pdf', 'application/pdf', 10) $$,
  '23505', null, 'QA-09: un archivo no se registra dos veces');
select throws_ok(
  $$ insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes, purge_after)
     values ('00000000-0000-0000-0000-0000000005b3', 'other',
             '00000000-0000-0000-0000-0000000005b3/titulo2.pdf', 'application/pdf', 10, '2999-01-01') $$,
  '42501', null, 'QA-06: el vet no fija su propia fecha de purga');
select ok(
  (select purge_after between now() + interval '89 days' and now() + interval '91 days'
   from public.vet_documents where storage_path = '00000000-0000-0000-0000-0000000005b3/titulo.pdf'),
  'QA-06: un documento sin revisar nace con purga a 90 días');
reset role;

-- QA-02: al aprobar se revalidan los requisitos ------------------------------
delete from public.vet_species where vet_id = '00000000-0000-0000-0000-0000000005b1';
select pg_temp.login('00000000-0000-0000-0000-0000000005c1');
set local role authenticated;
select throws_ok(
  $$ select public.review_vet_application('00000000-0000-0000-0000-0000000005b1', true) $$,
  '22023', 'Elige al menos una especie', 'QA-02: no se aprueba si faltan requisitos');
select is(
  public.review_vet_application('00000000-0000-0000-0000-0000000005b1', false, 'Faltan especies'),
  'rejected', 'pero sí se puede rechazar');
reset role;

-- QA-10: contextos de confianza (rol de servicio) ----------------------------
set local role service_role;
select lives_ok(
  $$ update public.vet_profiles set review_notes = 'mantención'
     where user_id = '00000000-0000-0000-0000-0000000005b2' $$,
  'QA-10: el rol de servicio puede mantener vet_profiles');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000005b2');
set local role authenticated;
select throws_ok(
  $$ update public.vet_profiles set review_notes = 'yo mismo'
     where user_id = '00000000-0000-0000-0000-0000000005b2' $$,
  '42501', null, 'QA-10: el vet autenticado sigue sin tocar la revisión');
reset role;

-- QA-01: registro manual con términos sí; dueño sin comuna no -----------------
select pg_temp.login('00000000-0000-0000-0000-0000000005a2');
set local role authenticated;
insert into public.terms_acceptances (user_id, version)
  values ('00000000-0000-0000-0000-0000000005a2', public.current_legal_version('terms'));
insert into public.privacy_notice_views (user_id, version)
  values ('00000000-0000-0000-0000-0000000005a2', public.current_legal_version('privacy'));
select lives_ok(
  $$ insert into public.user_roles (user_id, role)
     values ('00000000-0000-0000-0000-0000000005a2', 'owner') $$,
  'QA-01: con términos y aviso vigentes se puede tomar el rol');
select throws_ok(
  $$ insert into public.owner_profiles (user_id, display_name)
     values ('00000000-0000-0000-0000-0000000005a2', 'Sin Comuna') $$,
  '42501', null, 'QA-01: el perfil de dueño exige comuna');
reset role;

-- Regresiones del dueño --------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000005a1');
set local role authenticated;
select public.complete_registration('owner', 'Dueña QA5', null,
  public.current_legal_version('terms'), public.current_legal_version('privacy'),
  (select id from public.communes where name = 'Santiago'));
select throws_ok(
  $$ select public.complete_registration('owner', 'Dueña QA5', null,
       public.current_legal_version('terms'), public.current_legal_version('privacy'),
       (select id from public.communes where name = 'Santiago')) $$,
  '23505', 'Tu cuenta ya completó el registro', 'registrarse dos veces: 23505 con mensaje claro');
select lives_ok(
  $$ update public.owner_profiles set commune_id = (select id from public.communes where name = 'Ñuñoa')
     where user_id = '00000000-0000-0000-0000-0000000005a1' $$,
  'QA-04: el dueño sí puede cambiar de comuna');
reset role;

select * from finish();
rollback;
