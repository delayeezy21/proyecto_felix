-- Fase 3: onboarding y verificación de veterinarios.
begin;
select plan(36);

select ok(
  (select not public from storage.buckets where id = 'vet-documents'),
  'el bucket de documentos es privado');

-- Fixtures ------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000003b1', 'vet-v@test.local'),
  ('00000000-0000-0000-0000-0000000003b2', 'vet-w@test.local'),
  ('00000000-0000-0000-0000-0000000003a1', 'dueno-o@test.local'),
  ('00000000-0000-0000-0000-0000000003c1', 'admin-a@test.local');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000003b1', 'vet'),
  ('00000000-0000-0000-0000-0000000003b2', 'vet'),
  ('00000000-0000-0000-0000-0000000003a1', 'owner'),
  ('00000000-0000-0000-0000-0000000003c1', 'admin');
insert into public.vet_profiles (user_id, display_name) values
  ('00000000-0000-0000-0000-0000000003b1', 'Dra. Vera'),
  ('00000000-0000-0000-0000-0000000003b2', 'Dr. Walter');

create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

-- Prepara una solicitud completa para el vet logueado (carpeta = su id).
create function pg_temp.complete_application(p_uid uuid) returns void
language plpgsql as $$
begin
  update public.vet_profiles
     set university = 'Universidad de Chile', graduation_year = 2015,
         declaration_accepted_at = now()
   where user_id = p_uid;
  insert into storage.objects (bucket_id, name) values
    ('vet-documents', p_uid || '/titulo.pdf'),
    ('vet-documents', p_uid || '/cedula.jpg');
  insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes) values
    (p_uid, 'degree_certificate', p_uid || '/titulo.pdf', 'application/pdf', 1000),
    (p_uid, 'id_card_front', p_uid || '/cedula.jpg', 'image/jpeg', 1000);
  insert into public.vet_species (vet_id, species_id)
    select p_uid, id from public.species where slug = 'perro';
  insert into public.vet_specialties (vet_id, specialty_id)
    select p_uid, id from public.specialties where slug = 'general';
end;
$$;

-- Vet V: arma su solicitud ------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000003b1');
set local role authenticated;

update public.vet_profiles
   set university = 'Universidad de Chile', graduation_year = 2015,
       bio = 'Medicina felina y canina'
 where user_id = '00000000-0000-0000-0000-0000000003b1';
select is((select university from public.vet_profiles), 'Universidad de Chile',
  'el vet completa sus datos profesionales');

select lives_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('vet-documents', '00000000-0000-0000-0000-0000000003b1/titulo.pdf') $$,
  'el vet sube un archivo a su carpeta');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('vet-documents', '00000000-0000-0000-0000-0000000003b2/falso.pdf') $$,
  '42501', null, 'el vet no sube archivos a la carpeta de otro vet');

select lives_ok(
  $$ insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes)
     values ('00000000-0000-0000-0000-0000000003b1', 'degree_certificate',
             '00000000-0000-0000-0000-0000000003b1/titulo.pdf', 'application/pdf', 2048) $$,
  'el vet registra su certificado de título');
select throws_ok(
  $$ insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes)
     values ('00000000-0000-0000-0000-0000000003b1', 'id_card_front',
             '00000000-0000-0000-0000-0000000003b1/no-existe.jpg', 'image/jpeg', 10) $$,
  '42501', null, 'no se registra un documento que no fue subido');
select throws_ok(
  $$ insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes)
     values ('00000000-0000-0000-0000-0000000003b1', 'other',
             '00000000-0000-0000-0000-0000000003b1/titulo.pdf', 'application/zip', 10) $$,
  '23514', null, 'solo PDF, JPG o PNG');

select throws_ok(
  $$ select public.submit_vet_application() $$,
  '22023', 'Falta la declaración jurada', 'no envía sin declaración jurada');

update public.vet_profiles set declaration_accepted_at = now()
 where user_id = '00000000-0000-0000-0000-0000000003b1';
select throws_ok(
  $$ select public.submit_vet_application() $$,
  '22023', 'Falta la cédula de identidad', 'no envía sin cédula');

insert into storage.objects (bucket_id, name)
  values ('vet-documents', '00000000-0000-0000-0000-0000000003b1/cedula.jpg');
insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes)
  values ('00000000-0000-0000-0000-0000000003b1', 'id_card_front',
          '00000000-0000-0000-0000-0000000003b1/cedula.jpg', 'image/jpeg', 1024);
select throws_ok(
  $$ select public.submit_vet_application() $$,
  '22023', 'Elige al menos una especie', 'no envía sin especies');

insert into public.vet_species (vet_id, species_id)
  select '00000000-0000-0000-0000-0000000003b1', id from public.species
  where slug in ('perro', 'gato');
insert into public.vet_specialties (vet_id, specialty_id)
  select '00000000-0000-0000-0000-0000000003b1', id from public.specialties
  where slug = 'general';

-- Disponibilidad
insert into public.vet_availability (vet_id, weekday, start_min, end_min)
  values ('00000000-0000-0000-0000-0000000003b1', 1, 540, 780);
select throws_ok(
  $$ insert into public.vet_availability (vet_id, weekday, start_min, end_min)
     values ('00000000-0000-0000-0000-0000000003b1', 1, 720, 900) $$,
  '23P01', null, 'los bloques de un mismo día no se solapan');
select lives_ok(
  $$ insert into public.vet_availability (vet_id, weekday, start_min, end_min)
     values ('00000000-0000-0000-0000-0000000003b1', 1, 840, 1080) $$,
  'un bloque contiguo sin solape se acepta');
select throws_ok(
  $$ insert into public.vet_availability (vet_id, weekday, start_min, end_min)
     values ('00000000-0000-0000-0000-0000000003b2', 2, 540, 600) $$,
  '42501', null, 'el vet no edita la disponibilidad de otro');

select ok(public.submit_vet_application() is not null, 'el vet envía su solicitud');

select throws_ok(
  $$ update public.vet_profiles set university = 'Otra'
     where user_id = '00000000-0000-0000-0000-0000000003b1' $$,
  '42501', null, 'en revisión no puede cambiar sus datos profesionales');
select throws_ok(
  $$ update public.vet_profiles set status = 'approved'
     where user_id = '00000000-0000-0000-0000-0000000003b1' $$,
  '42501', null, 'el vet no puede aprobarse');
select throws_ok(
  $$ update public.vet_profiles set identity_verified_at = now()
     where user_id = '00000000-0000-0000-0000-0000000003b1' $$,
  '42501', null, 'el vet no puede marcarse como verificado');
select lives_ok(
  $$ update public.vet_profiles set bio = 'Atiendo perros y gatos'
     where user_id = '00000000-0000-0000-0000-0000000003b1' $$,
  'la bio sí es editable en revisión');
select throws_ok(
  $$ select public.review_vet_application('00000000-0000-0000-0000-0000000003b1', true) $$,
  '42501', null, 'el vet no puede revisar solicitudes');

reset role;

-- Otros usuarios no ven los documentos ------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000003b2');
set local role authenticated;
select is((select count(*)::int from public.vet_documents), 0,
  'otro vet no ve los documentos ajenos');
select is((select count(*)::int from storage.objects where bucket_id = 'vet-documents'), 0,
  'otro vet no ve los archivos ajenos');
reset role;

select pg_temp.login('00000000-0000-0000-0000-0000000003a1');
set local role authenticated;
select is((select count(*)::int from public.vet_documents), 0,
  'un dueño no ve documentos de vets');
select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('vet-documents', '00000000-0000-0000-0000-0000000003a1/x.pdf') $$,
  '42501', null, 'un dueño no sube documentos de vet');
reset role;

-- Admin aprueba ---------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000003c1');
set local role authenticated;

select is((select count(*)::int from public.vet_documents
           where vet_id = '00000000-0000-0000-0000-0000000003b1'), 2,
  'el admin ve los documentos de la solicitud');
select throws_ok(
  $$ select public.review_vet_application('00000000-0000-0000-0000-0000000003b1', false, '  ') $$,
  '22023', 'El rechazo requiere un motivo', 'rechazar exige motivo');
select is(
  public.review_vet_application('00000000-0000-0000-0000-0000000003b1', true, null,
    'Nombre coincide; código verificado en la U.'),
  'approved', 'el admin aprueba la solicitud');
select is((select verified_by from public.vet_profiles
           where user_id = '00000000-0000-0000-0000-0000000003b1'),
  '00000000-0000-0000-0000-0000000003c1'::uuid, 'queda registrado quién verificó');
select ok(
  (select bool_and(review_status = 'accepted'
                   and purge_after between now() + interval '6 days 23 hours'
                                       and now() + interval '7 days 1 hour')
   from public.vet_documents where vet_id = '00000000-0000-0000-0000-0000000003b1'),
  'los documentos quedan aceptados y con purga a 7 días');
select ok(
  exists (select 1 from public.admin_audit_log
          where table_name = 'vet_profiles'
            and actor_id = '00000000-0000-0000-0000-0000000003c1'),
  'la aprobación queda en el log de auditoría');
select throws_ok(
  $$ select public.review_vet_application('00000000-0000-0000-0000-0000000003b1', true) $$,
  '22023', null, 'una solicitud ya revisada no se revisa de nuevo');
reset role;

-- Vet aprobado: no sube más documentos ------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000003b1');
set local role authenticated;
select throws_ok(
  $$ insert into storage.objects (bucket_id, name)
     values ('vet-documents', '00000000-0000-0000-0000-0000000003b1/otro.pdf') $$,
  '42501', null, 'un vet aprobado no sube nuevos documentos');
reset role;

-- Rechazo y reenvío (vet W) --------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000003b2');
set local role authenticated;
select pg_temp.complete_application('00000000-0000-0000-0000-0000000003b2');
select public.submit_vet_application();
reset role;

select pg_temp.login('00000000-0000-0000-0000-0000000003c1');
set local role authenticated;
select is(
  public.review_vet_application('00000000-0000-0000-0000-0000000003b2', false,
    'El nombre del título no coincide con la cédula'),
  'rejected', 'el admin rechaza con motivo');
select ok(
  (select bool_and(purge_after > now() + interval '29 days')
   from public.vet_documents where vet_id = '00000000-0000-0000-0000-0000000003b2'),
  'los documentos rechazados se purgan a 30 días (ventana de apelación)');
reset role;

select pg_temp.login('00000000-0000-0000-0000-0000000003b2');
set local role authenticated;
select is((select rejection_reason from public.vet_profiles),
  'El nombre del título no coincide con la cédula', 'el vet ve el motivo del rechazo');
select ok(public.submit_vet_application() is not null, 'el vet rechazado puede reenviar');
select is((select status from public.vet_profiles), 'pending',
  'al reenviar vuelve a quedar pendiente');
reset role;

select * from finish();
rollback;
