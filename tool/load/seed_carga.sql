-- Datos FICTICIOS para la prueba de capacidad (docs/qa/capacidad-5000.md).
-- SOLO para un stack local AISLADO. Nunca en la nube ni en el stack compartido.
--
-- 5.000 usuarios: 1 admin, 300 vets (200 aprobados, 60 en revisión, 40 sin
-- enviar o rechazados) y 4.699 dueños, con términos, aviso de privacidad,
-- consentimientos, especies, especialidades, horarios, documentos (solo
-- metadatos) y bitácora de admin. Correos @carga.felix.test (dominio reservado).
-- Contraseña de todos: la de LOAD_PASSWORD en capacidad.mjs.
--
-- Uso (superusuario, desactiva triggers durante la carga):
--   docker exec -i supabase_db_<project_id> psql -U supabase_admin -d postgres \
--     -v ON_ERROR_STOP=1 < tool/load/seed_carga.sql

\set ON_ERROR_STOP 1
begin;
set local session_replication_role = replica;

-- Un solo hash bcrypt (costo 10, como GoTrue) para no gastar minutos en crypt().
create temp table _pw as
  select extensions.crypt('Carga-Felix-2026!', extensions.gen_salt('bf', 10)) as h;

create temp table _u as
select
  gen_random_uuid() as id,
  n,
  case
    when n = 0 then 'admin'
    when n <= 300 then 'vet'
    else 'owner'
  end as role,
  case
    when n = 0 then 'carga-admin@carga.felix.test'
    when n <= 300 then format('carga-vet-%s@carga.felix.test', lpad(n::text, 4, '0'))
    else format('carga-owner-%s@carga.felix.test', lpad(n::text, 4, '0'))
  end as email
from generate_series(0, 4999) n;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  email_change_token_current, phone_change, phone_change_token, reauthentication_token
)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
  u.email, (select h from _pw), now() - interval '30 days',
  '{"provider":"email","providers":["email"]}', '{}',
  now() - (u.n % 60) * interval '1 day', now(),
  '', '', '', '', '', '', '', ''
from _u u;

insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select u.id::text, u.id,
  jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
  'email', now(), now(), now()
from _u u;

insert into public.user_roles (user_id, role) select id, role from _u;

-- Dueños
insert into public.owner_profiles (user_id, display_name, phone, commune_id)
select u.id, 'Dueño Carga ' || u.n, '+56 9 0000 ' || lpad((u.n % 10000)::text, 4, '0'),
  (select c.id from public.communes c order by c.id offset (u.n % 346) limit 1)
from _u u where u.role = 'owner';

-- Vets: 1–200 aprobados, 201–260 en revisión, 261–280 rechazados, 281–300 borrador.
insert into public.vet_profiles (
  user_id, display_name, status, identity_verified_at, verified_by, bio, university,
  graduation_year, foreign_degree, title_verification_code, declaration_accepted_at,
  submitted_at, reviewed_at, rejection_reason
)
select u.id, 'Vet Carga ' || u.n,
  case when u.n <= 200 then 'approved' when u.n between 261 and 280 then 'rejected' else 'pending' end,
  case when u.n <= 200 then now() - interval '10 days' end,
  case when u.n <= 200 or u.n between 261 and 280 then (select id from _u where n = 0) end,
  'Veterinaria ficticia para pruebas de carga.',
  'Universidad Ficticia ' || (u.n % 7),
  (2000 + u.n % 24)::smallint, false, 'FOLIO-' || u.n,
  case when u.n <= 280 then now() - interval '12 days' end,
  case when u.n <= 280 then now() - (u.n % 20) * interval '1 hour' end,
  case when u.n <= 200 or u.n between 261 and 280 then now() - interval '10 days' end,
  case when u.n between 261 and 280 then 'Documento ilegible (ficticio).' end
from _u u where u.role = 'vet';

insert into public.vet_species (vet_id, species_id)
select v.user_id, s.id
from public.vet_profiles v
cross join lateral (select id from public.species order by id limit 2) s;

insert into public.vet_specialties (vet_id, specialty_id)
select v.user_id, s.id
from public.vet_profiles v
cross join lateral (select id from public.specialties order by id limit 2) s;

insert into public.vet_availability (vet_id, weekday, start_min, end_min)
select v.user_id, d, 540, 1080
from public.vet_profiles v cross join generate_series(1, 5) d;

insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes, review_status)
select v.user_id, k, null, 'application/pdf', 250000,
  case v.status when 'approved' then 'accepted' when 'rejected' then 'rejected' else 'pending' end
from public.vet_profiles v
cross join unnest(array['degree_certificate', 'id_card_front']) k
where v.submitted_at is not null;

insert into public.vet_title_verifications (vet_id, source, outcome, risk, run_trigger, requested_by, provider_version)
select v.user_id, 'rules', 'skipped', 'low', 'submit', v.user_id, 'carga-1'
from public.vet_profiles v where v.submitted_at is not null;

-- Términos, aviso de privacidad y consentimientos (30 % acepta marketing).
insert into public.terms_acceptances (user_id, version)
select id, public.current_legal_version('terms') from _u;
insert into public.privacy_notice_views (user_id, version)
select id, public.current_legal_version('privacy') from _u;
insert into public.consents (user_id, purpose, version)
select id, 'marketing', public.current_legal_version('privacy') from _u where n % 10 < 3;

-- Bitácora de admin (historial de unos meses de revisión).
insert into public.admin_audit_log (actor_id, table_name, row_pk, action, old_data, new_data, at)
select (select id from _u where n = 0), 'vet_profiles', gen_random_uuid()::text, 'UPDATE',
  '{"status":"pending"}', '{"status":"approved"}', now() - g * interval '1 hour'
from generate_series(1, 3000) g;

commit;

analyze;
select role, count(*) from public.user_roles group by role order by role;
