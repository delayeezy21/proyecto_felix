-- Fase 11: derechos de privacidad (SPEC §F8, P1, P2; arquitectura §8).
-- Exportación por rol sin datos de terceros, consentimientos, bloqueo y
-- revocación de sesiones, gracia cancelable, job de borrado (dueño, vet y
-- miembro de fundación) con Storage, redacción, escaneo final e idempotencia,
-- acceso a entradas retenidas, retención, huérfanos (M2), HU8.6 y escaneo de PII.
begin;
select plan(138);
-- QA-F11-02: sesión en UTC+14 (current_date ≠ fecha de Chile, como de 21:00 a 24:00).
set local timezone = 'Etc/GMT-14';

create function pg_temp.u(k text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-000000170' || k)::uuid $$;
create function pg_temp.login(k text) returns void language plpgsql as $$
begin
  if k = 'anon' then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    set local role anon;
  else
    perform set_config('request.jwt.claims', json_build_object(
      'sub', pg_temp.u(k), 'role', 'authenticated')::text, true);
    set local role authenticated;
  end if;
end;
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end;
$$;

-- Fixtures (sin triggers, como los tests 100/130) ------------------------------
set local session_replication_role = replica;
insert into auth.users (id, email)
select pg_temp.u(k), 'f11-' || k || '@test.local'
from unnest(array['a01', 'a02', 'a03', 'b01', 'b02', 'c01', 'c02', 'd01']) k;
insert into public.user_roles (user_id, role)
select pg_temp.u(k), r from (values ('a01', 'owner'), ('a02', 'owner'), ('a03', 'owner'),
  ('b01', 'vet'), ('b02', 'vet'), ('c01', 'foundation'), ('c02', 'foundation'),
  ('d01', 'admin')) v (k, r);
insert into public.owner_profiles (user_id, display_name, phone, commune_id)
select pg_temp.u(k), n, p, (select id from public.communes where name = 'Ñuñoa')
from (values ('a01', 'Ana Ficticia', '+56 9 8765 4321'), ('a02', 'Beto Control', null),
             ('a03', 'Carla Gracia', null)) v (k, n, p);
insert into public.vet_profiles (user_id, display_name, status) values
  (pg_temp.u('b01'), 'Dra. Autora', 'approved'), (pg_temp.u('b02'), 'Dr. Baja', 'approved');
insert into public.vet_availability (vet_id, weekday, start_min, end_min)
select pg_temp.u('b02'), d, 0, 1440 from generate_series(1, 7) d;
insert into public.vet_bases (vet_id, commune_id, lat, lng)
values (pg_temp.u('b02'), (select id from public.communes where name = 'Ñuñoa'), -33.45, -70.6);
insert into public.vet_presence (vet_id, online, location)
values (pg_temp.u('b02'), true, 'SRID=4326;POINT(-70.6 -33.45)'::extensions.geography);
insert into public.foundations (id, name, is_default) values (pg_temp.u('fd1'), 'Fundación F11', false);
insert into public.foundation_members (user_id, foundation_id) values
  (pg_temp.u('c01'), pg_temp.u('fd1')), (pg_temp.u('c02'), pg_temp.u('fd1'));
insert into public.pets (id, owner_id, name, species_id, microchip) values
  (pg_temp.u('e01'), pg_temp.u('a01'), 'Firulais', (select id from public.species where slug = 'perro'),
   '941000012345678'),
  (pg_temp.u('e02'), pg_temp.u('a02'), 'Michi', (select id from public.species where slug = 'gato'), null);
insert into public.addresses (id, owner_id, label, street_text, details, commune_id, lat, lng) values
  (pg_temp.u('ad1'), pg_temp.u('a01'), 'Casa', 'Av. Privada 742', 'Depto 5B',
   (select id from public.communes where name = 'Ñuñoa'), -33.4569, -70.5974),
  (pg_temp.u('ad2'), pg_temp.u('a02'), 'Casa', 'Calle Control 1', null,
   (select id from public.communes where name = 'Ñuñoa'), -33.4569, -70.5974);
insert into public.visits (id, owner_id, pet_id, address_id, vet_id, mode, status, commune_id,
  species_id, specialty_id, foundation_id, scheduled_at, slot, confirm_deadline, quote,
  owner_notes, cancel_reason, accepted_at, started_at, completed_at, closed_at)
select pg_temp.u(v), pg_temp.u(o), pg_temp.u(p), pg_temp.u(ad), pg_temp.u(vet), 'scheduled', st,
       (select id from public.communes where name = 'Ñuñoa'),
       (select species_id from public.pets where id = pg_temp.u(p)),
       (select id from public.specialties where slug = 'general'), pg_temp.u('fd1'),
       t, tstzrange(t, t + interval '90 minutes'), t - interval '1 day',
       jsonb_build_object('vet_id', pg_temp.u(vet), 'service_price', 26990, 'vet_payout', 22941),
       notes, reason, t - interval '1 day',
       case when st = 'completed' then t end, case when st = 'completed' then t + interval '1 hour' end,
       case when st = 'completed' then t + interval '1 hour' end
from (values
  ('f01', 'a01', 'e01', 'ad1', 'b01', 'completed', now() - interval '10 days', 'Timbre malo', 'x'),
  ('f02', 'a01', 'e01', 'ad1', 'b01', 'pending_vet', now() + interval '2 days', null, null),
  ('f03', 'a02', 'e02', 'ad2', 'b02', 'completed', now() - interval '5 days',
   'Escribir a beto.control@test.local', null)) x (v, o, p, ad, vet, st, t, notes, reason);
insert into public.payments (id, owner_id, foundation_id, kind, status, provider, service_price,
  platform_fee, foundation_share, vet_payout, extra_donation, total, paid_at, visit_id, vet_id) values
  (pg_temp.u('aa7'), pg_temp.u('a01'), pg_temp.u('fd1'), 'visit', 'simulated_paid', 'simulated',
   26990, 4049, 810, 22941, 1000, 27990, now() - interval '10 days', pg_temp.u('f01'), pg_temp.u('b01')),
  (pg_temp.u('aa8'), pg_temp.u('a02'), pg_temp.u('fd1'), 'visit', 'simulated_paid', 'simulated',
   26990, 4049, 810, 22941, 0, 26990, now() - interval '5 days', pg_temp.u('f03'), pg_temp.u('b02'));
insert into public.foundation_contributions (payment_id, foundation_id, kind, amount) values
  (pg_temp.u('aa7'), pg_temp.u('fd1'), 'commission_share', 810),
  (pg_temp.u('aa7'), pg_temp.u('fd1'), 'donation', 1000),
  (pg_temp.u('aa8'), pg_temp.u('fd1'), 'commission_share', 810);
insert into public.record_access_grants (pet_id, vet_id, source, visit_id, starts_at, expires_at) values
  (pg_temp.u('e01'), pg_temp.u('b01'), 'visit', pg_temp.u('f01'), now() - interval '11 days',
   now() + interval '20 days'),
  (pg_temp.u('e02'), pg_temp.u('b02'), 'visit', pg_temp.u('f03'), now() - interval '6 days',
   now() + interval '25 days');
insert into public.clinical_entries (id, pet_id, visit_id, author_id, author_role, kind, species_id,
  title, body, retain_until) values
  (pg_temp.u('ee1'), pg_temp.u('e01'), pg_temp.u('f01'), pg_temp.u('b01'), 'vet', 'diagnosis',
   (select id from public.species where slug = 'perro'), 'Otitis de Firulais',
   'Dueña Ana Ficticia, fono +56 9 8765 4321, correo f11-a01@test.local, vive en Av. Privada 742. '
   || 'Control en 7 días.', null),
  (pg_temp.u('ee2'), pg_temp.u('e01'), null, pg_temp.u('a01'), 'owner', 'note',
   (select id from public.species where slug = 'perro'), 'Firulais come poco', null, null),
  (pg_temp.u('ee3'), pg_temp.u('e01'), pg_temp.u('f01'), pg_temp.u('b01'), 'vet', 'vaccine',
   (select id from public.species where slug = 'perro'), 'Antirrábica', null, null),
  (pg_temp.u('ee4'), pg_temp.u('e02'), pg_temp.u('f03'), pg_temp.u('b02'), 'vet', 'consultation',
   (select id from public.species where slug = 'gato'), 'Control de Michi', 'Sano', null),
  (pg_temp.u('ee5'), null, null, pg_temp.u('b01'), 'vet', 'diagnosis',
   (select id from public.species where slug = 'perro'), 'Retenida vencida', null,
   now() - interval '1 day');
insert into public.clinical_vaccines (entry_id, pet_id, vaccine_name, applied_on, next_due)
values (pg_temp.u('ee3'), pg_temp.u('e01'), 'Antirrábica', (now() at time zone 'America/Santiago')::date, (now() at time zone 'America/Santiago')::date + 365);
insert into storage.objects (bucket_id, name, owner_id, created_at) values
  ('clinical-attachments', 'pets/' || pg_temp.u('e01') || '/' || pg_temp.u('ee1') || '/rx.pdf',
   pg_temp.u('b01')::text, now()),
  ('clinical-attachments', 'pets/' || pg_temp.u('e01') || '/' || pg_temp.u('ee2') || '/foto.png',
   pg_temp.u('a01')::text, now()),
  ('clinical-attachments', 'pets/' || pg_temp.u('e02') || '/' || pg_temp.u('ee4') || '/huerfano.pdf',
   pg_temp.u('b02')::text, now() - interval '25 hours'),
  ('clinical-attachments', 'pets/' || pg_temp.u('e02') || '/' || pg_temp.u('ee4') || '/reciente.pdf',
   pg_temp.u('b02')::text, now()),
  ('vet-documents', pg_temp.u('b02') || '/titulo.pdf', pg_temp.u('b02')::text, now());
insert into public.entry_attachments (id, entry_id, pet_id, storage_path, file_name, mime,
  size_bytes, uploaded_by) values
  (pg_temp.u('ab1'), pg_temp.u('ee1'), pg_temp.u('e01'),
   'pets/' || pg_temp.u('e01') || '/' || pg_temp.u('ee1') || '/rx.pdf', 'rx.pdf',
   'application/pdf', 100, pg_temp.u('b01')),
  (pg_temp.u('ab2'), pg_temp.u('ee2'), pg_temp.u('e01'),
   'pets/' || pg_temp.u('e01') || '/' || pg_temp.u('ee2') || '/foto.png', 'foto.png',
   'image/png', 100, pg_temp.u('a01'));
insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes)
values (pg_temp.u('b02'), 'degree_certificate', pg_temp.u('b02') || '/titulo.pdf', 'application/pdf', 100);
insert into public.record_access_log (pet_id, actor_id, actor_role, action, via, visit_id, at) values
  (pg_temp.u('e01'), pg_temp.u('b01'), 'vet', 'view', 'visit', pg_temp.u('f01'), now() - interval '1 day'),
  (pg_temp.u('e02'), pg_temp.u('b02'), 'vet', 'view', 'visit', pg_temp.u('f03'), now() - interval '3 years'),
  (pg_temp.u('e02'), pg_temp.u('b02'), 'vet', 'view', 'visit', pg_temp.u('f03'), now() - interval '1 year'),
  (pg_temp.u('e02'), pg_temp.u('b01'), 'vet', 'view', 'owner_grant', null, now() - interval '3 years');
insert into private.push_devices (token, user_id, platform, last_seen_at) values
  ('token-a01-xxxxxxxx', pg_temp.u('a01'), 'android', now()),
  ('token-a02-viejo-xx', pg_temp.u('a02'), 'android', now() - interval '100 days'),
  ('token-a02-nuevo-xx', pg_temp.u('a02'), 'web', now() - interval '10 days');
insert into public.admin_audit_log (actor_id, table_name, row_pk, action, old_data, new_data) values
  (pg_temp.u('d01'), 'vet_profiles', pg_temp.u('b02')::text, 'UPDATE',
   jsonb_build_object('user_id', pg_temp.u('b02'), 'status', 'pending'),
   jsonb_build_object('user_id', pg_temp.u('b02'), 'status', 'approved')),
  (pg_temp.u('d01'), 'foundation_members', pg_temp.u('c01')::text || ',' || pg_temp.u('fd1'), 'INSERT',
   null, jsonb_build_object('user_id', pg_temp.u('c01')));
insert into auth.sessions (id, user_id) values (pg_temp.u('5a1'), pg_temp.u('a01'));
insert into auth.refresh_tokens (token, user_id, session_id, revoked)
values ('rt-f11-a01', pg_temp.u('a01')::text, pg_temp.u('5a1'), false);
insert into public.consents (user_id, purpose, version) values (pg_temp.u('a01'), 'marketing', '2026-11-16');
insert into public.privacy_notice_views (user_id, version, shown_at)
select pg_temp.u(k), '2026-11-16', now() - interval '30 days' from unnest(array['a01', 'a02', 'a03']) k;
set local session_replication_role = origin;

create temp table t_tot as
  select * from private.foundation_monthly_totals(12) where false;
grant all on t_tot to authenticated;

-- 1. Estructura y privilegios ---------------------------------------------------
select is((select count(*)::int from cron.job where jobname in
  ('privacy-deletions', 'privacy-retention', 'pii-scan', 'purge-privacy-storage')), 4,
  'pg_cron programa borrado, retención, escaneo de PII y purga de Storage');
select ok((select 'pgrst.db_pre_request=public.check_request' = any (rolconfig)
           from pg_roles where rolname = 'authenticator'),
  'PostgREST usa public.check_request como pre-request');
select ok(exists (select 1 from pg_policy where polname = 'privacy_blocked_storage'
                  and polrelid = 'storage.objects'::regclass and not polpermissive),
  'política restrictiva de cuenta bloqueada en storage.objects');
select ok(exists (select 1 from pg_policy where polname = 'privacy_blocked_realtime'
                  and polrelid = 'realtime.messages'::regclass and not polpermissive),
  'política restrictiva de cuenta bloqueada en realtime.messages');
select is_empty($$ select p from unnest(array['public.export_my_data()', 'public.set_consent(text,boolean)',
    'public.my_privacy_status()', 'public.record_privacy_notice_view()',
    'public.request_account_deletion()', 'public.cancel_account_deletion()',
    'public.my_deletion_request()', 'public.list_my_retained_entries()',
    'public.request_retained_entry(uuid,text)', 'public.privacy_storage_candidates(integer)']) p
  where has_function_privilege('anon', p, 'execute') $$, 'anon no ejecuta las RPC de privacidad');
select is_empty($$ select p from unnest(array['private.run_account_deletions(integer)',
    'private.process_deletion(uuid)', 'private.erase_subject(uuid)', 'private.privacy_residue(uuid[])',
    'private.run_privacy_retention()', 'private.run_pii_scan()', 'private.is_blocked(uuid)',
    'private.privacy_storage_due(integer)', 'public.privacy_storage_candidates(integer)']) p
  where has_function_privilege('authenticated', p, 'execute') $$,
  'authenticated no ejecuta los jobs ni la cola de Storage');
select ok(has_function_privilege('service_role', 'public.privacy_storage_candidates(integer)', 'execute'),
  'solo service_role (la Edge Function) pide los candidatos de Storage');
select is_empty($$ select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where (n.nspname, c.relname) in (('public', 'deletion_requests'), ('public', 'deletion_targets'),
    ('public', 'data_exports'), ('public', 'retained_entry_requests'), ('public', 'pii_scan_findings'),
    ('private', 'storage_erasure_queue'))
    and (has_table_privilege('authenticated', c.oid, 'INSERT') or has_table_privilege('authenticated', c.oid, 'DELETE')) $$,
  'las tablas de privacidad no aceptan INSERT ni DELETE de la API');
select ok(not has_column_privilege('authenticated', 'public.deletion_requests', 'subject_pet_ids', 'SELECT')
          and not has_column_privilege('authenticated', 'public.deletion_requests', 'report', 'SELECT'),
  'las columnas internas de la solicitud no se exponen');

-- 2. Consentimientos y política (HU8.3, HU8.4) -----------------------------------
select pg_temp.login('a02');
select is((public.set_consent('marketing', true) -> 'purposes' -> 0 ->> 'granted')::boolean, true,
  'el usuario otorga el consentimiento opcional');
select is((public.set_consent('marketing', false) -> 'purposes' -> 0 ->> 'granted')::boolean, false,
  'y lo retira');
select is((select count(*)::int from public.consents where revoked_at is not null), 1,
  'el retiro queda registrado con fecha (la fila no se borra)');
select is(jsonb_array_length(public.set_consent('marketing', true) -> 'history'), 2,
  'volver a otorgarlo crea una fila nueva y conserva la historia');
select is(pg_temp.err($$ select public.set_consent('perfilamiento', true) $$), '22023',
  'una finalidad desconocida se rechaza');
select is((public.my_privacy_status() ->> 'must_review')::boolean, false,
  'con la versión vigente vista no hay aviso');
reset role;
insert into public.legal_versions (kind, version, effective_from) values ('privacy', 'f11-v2', now());
select pg_temp.login('a02');
select is((public.my_privacy_status() ->> 'must_review')::boolean, true,
  'una política nueva se informa al usuario');
select is((public.my_privacy_status() -> 'purposes' -> 0 ->> 'ask')::boolean, false,
  'sin finalidad opcional nueva no se pide otro consentimiento');
select is((public.record_privacy_notice_view() ->> 'must_review')::boolean, false,
  'registrar la vista de la versión nueva quita el aviso');
select is((select count(*)::int from public.privacy_notice_views), 2,
  'cada versión vista queda registrada');

-- 3. Exportación por rol (HU8.1, HU8.5) ------------------------------------------
select pg_temp.login('a01');
create temp table t_exp as select public.export_my_data() as j;
select is((select j ->> 'subject_role' from t_exp), 'owner', 'exportación del dueño');
select ok((select j ?& array['account', 'profile', 'addresses', 'pets', 'clinical_entries',
  'visits', 'payments', 'consents', 'terms_acceptances', 'privacy_notice_views',
  'record_access_log', 'record_access_grants'] from t_exp),
  'incluye perfil, direcciones, mascotas, ficha, visitas, pagos, consentimientos y avisos');
select is((select j -> 'pets' -> 0 ->> 'microchip' from t_exp), '941000012345678',
  'el dueño exporta el microchip de su mascota');
select is((select jsonb_array_length(j -> 'clinical_entries') from t_exp), 3,
  'la ficha incluye las entradas de los vets y las propias');
select is((select e ->> 'author_name' from t_exp, jsonb_array_elements(j -> 'clinical_entries') e
           where e ->> 'id' = pg_temp.u('ee1')::text), 'Dra. Autora',
  'con el nombre público del vet autor');
select is((select jsonb_array_length(j -> 'payments') from t_exp), 1, 'sus pagos (y solo los suyos)');
select ok((select position('Michi' in j::text) = 0 and position('Beto' in j::text) = 0
             and position(pg_temp.u('b01')::text in j::text) = 0 from t_exp),
  'sin datos de otros dueños ni identificadores internos del vet');
select is((select count(*)::int from public.data_exports), 1, 'la exportación queda registrada');
select ok((select 'pets' = any (sections) from public.data_exports), 'el registro guarda solo las secciones');
select pg_temp.login('b01');
create temp table t_vexp as select public.export_my_data() as j;
select ok((select j ?& array['profile', 'base', 'availability', 'documents', 'visits', 'payouts',
  'clinical_entries_authored'] from t_vexp), 'exportación del vet: perfil, base, horario, documentos, visitas, pagos y entradas');
select ok((select position('8765 4321' in j::text) = 0 and position('Firulais' in j::text) = 0
             and position('Av. Privada' in j::text) = 0 and position('Ana Ficticia' in j::text) = 0
             and position(pg_temp.u('a01')::text in j::text) = 0 from t_vexp),
  'la exportación del vet no incluye teléfono, nombre, dirección ni id del dueño ni la mascota');
select ok((select not (j -> 'payouts' -> 0 ?| array['total', 'extra_donation', 'owner_id']) from t_vexp),
  'las liquidaciones del vet no muestran el total ni la donación del dueño');
select is((select jsonb_array_length(j -> 'clinical_entries_authored') from t_vexp), 3,
  'el vet ve los metadatos de las entradas que escribió');
select pg_temp.login('c01');
select is((public.export_my_data() -> 'memberships' -> 0 ->> 'foundation'), 'Fundación F11',
  'exportación del miembro de fundación con su membresía');

-- 4. HU8.6 ----------------------------------------------------------------------
select pg_temp.login('b01');
select is((select count(*)::int from public.my_payouts()), 1, 'el vet ve solo la liquidación de su visita (my_payouts)');
select is((select count(*)::int from public.payments), 0, 'el vet no lee filas de payments (QA-F11-05)');
select is((select count(*)::int from public.pets), 0, 'el vet no lee mascotas (ni el microchip) directo');
select is((public.get_pet_record(pg_temp.u('e01'), pg_temp.u('f01')) -> 'pet' ->> 'microchip'),
  '941000012345678', 'el microchip lo ve el vet con acceso vigente');
select is(pg_temp.err($$ select public.get_pet_record('00000000-0000-0000-0000-000000170e02') $$),
  '42501', 'un vet sin acceso no ve la mascota ni su microchip');
select pg_temp.login('c02');
select is((select count(*)::int from public.payments) + (select count(*)::int from public.foundation_contributions),
  0, 'la fundación no ve pagos ni aportes de los dueños');
insert into t_tot select * from public.foundation_summary(12);
select is((select sum(total)::int from t_tot), 2620, 'la fundación solo ve sus totales mensuales');
select ok(to_regclass('public.subscriptions') is null,
  'aún no hay planes (fase 10): no hay plan de dueño que exponer');

-- 5. Solicitud de borrado: acuse, bloqueo y sesiones (HU8.2, P2) ------------------
select pg_temp.login('d01');
select is(pg_temp.err($$ select public.request_account_deletion() $$), '42501',
  'el admin no se borra por la app');
select pg_temp.login('a01');
create temp table t_req as select public.request_account_deletion() as j;
grant all on t_req, t_exp, t_vexp to authenticated;
select is((select j ->> 'status' from t_req), 'blocked', 'acuse inmediato: la cuenta queda bloqueada');
select ok((select (j ->> 'execute_after')::timestamptz between now() + interval '15 days' - interval '1 minute'
                  and now() + interval '15 days' from t_req), 'gracia de 15 días');
select is((public.request_account_deletion() ->> 'request_id'), (select j ->> 'request_id' from t_req),
  'pedirlo de nuevo devuelve la misma solicitud');
select is((public.my_deletion_request() ->> 'cancellable')::boolean, true, 'la solicitud se puede cancelar');
reset role;
select is((select count(*)::int from auth.sessions where user_id = pg_temp.u('a01'))
          + (select count(*)::int from auth.refresh_tokens where user_id = pg_temp.u('a01')::text), 0,
  'las sesiones y refresh tokens se revocan');
select is((select status || ':' || cancel_fee from public.visits where id = pg_temp.u('f02')),
  'cancelled_owner:0', 'la visita abierta se cancela sin cargo');
select is((select count(*)::int from public.payments where visit_id = pg_temp.u('f02')), 0,
  'sin pago de cancelación');
select ok(private.is_blocked(pg_temp.u('a01')), 'la cuenta está bloqueada');
select pg_temp.login('a01');
select set_config('request.path', '/rpc/my_visits', true);
select is(pg_temp.err($$ select public.check_request() $$), '42501',
  'cuenta bloqueada: la REST/RPC (también con el JWT vigente) se rechaza');
select set_config('request.path', '/pets', true);
select is(pg_temp.err($$ select public.check_request() $$), '42501', 'también la lectura de tablas');
select set_config('request.path', '/rpc/cancel_account_deletion', true);
select is(pg_temp.err($$ select public.check_request() $$), 'ok', 'pero puede cancelar la solicitud');
select set_config('request.path', '/rpc/export_my_data', true);
select is(pg_temp.err($$ select public.check_request() $$), 'ok', 'y exportar sus datos');
select ok((public.export_my_data() ? 'pets'), 'la exportación funciona con la cuenta bloqueada');
select ok((select private.account_blocked()), 'las políticas restrictivas ven la cuenta bloqueada');
select pg_temp.login('a02');
select set_config('request.path', '/rpc/my_visits', true);
select is(pg_temp.err($$ select public.check_request() $$), 'ok', 'otra cuenta no se ve afectada');
select pg_temp.login('b01');
select is(pg_temp.err($$ select public.get_pet_record('00000000-0000-0000-0000-000000170e01', '00000000-0000-0000-0000-000000170f01') $$),
  '42501', 'sin tratamiento: el vet ya no lee la ficha del dueño bloqueado');
select ok(not private.vet_can_write(pg_temp.u('e01'), pg_temp.u('f01')), 'ni escribe en ella');
select pg_temp.login('anon');
select set_config('request.path', '/rpc/current_legal_version', true);
select is(pg_temp.err($$ select public.check_request() $$), 'ok', 'el pre-request deja pasar a anon');

-- 6. Cancelación dentro de la gracia ---------------------------------------------
select pg_temp.login('a03');
select is((public.request_account_deletion() ->> 'status'), 'blocked', 'otro dueño pide el borrado');
select is((public.cancel_account_deletion() ->> 'status'), 'cancelled', 'y lo cancela dentro de la gracia');
select ok(not (select private.account_blocked()), 'la cuenta deja de estar bloqueada');
select is(pg_temp.err($$ select public.cancel_account_deletion() $$), '22023', 'no hay nada más que cancelar');
reset role;
select is(private.process_deletion((select (j ->> 'request_id')::uuid from t_req)), 'blocked',
  'antes de la gracia el job no ejecuta');
update public.deletion_requests set execute_after = now() - interval '1 minute'
  where id = (select (j ->> 'request_id')::uuid from t_req);
select pg_temp.login('a01');
select is(pg_temp.err($$ select public.cancel_account_deletion() $$), '22023',
  'vencida la gracia ya no se puede cancelar');
reset role;

-- 7. Job de borrado del dueño -----------------------------------------------------
create temp table t_before as
  select (select sum(amount) from public.foundation_contributions where foundation_id = pg_temp.u('fd1')) as contrib,
         (select sum(total) from public.payments where foundation_id = pg_temp.u('fd1')) as paid;
select is(private.process_deletion((select (j ->> 'request_id')::uuid from t_req)), 'executing',
  'el job ejecuta y espera a Storage');
select is((select count(*)::int from public.owner_profiles where user_id = pg_temp.u('a01'))
          + (select count(*)::int from public.addresses where owner_id = pg_temp.u('a01'))
          + (select count(*)::int from public.pets where owner_id = pg_temp.u('a01')), 0,
  'se borran el perfil, las direcciones y las mascotas (con el microchip)');
select is((select count(*)::int from public.clinical_entries where id = pg_temp.u('ee2')), 0,
  'se borra la nota del dueño');
select is((select count(*)::int from public.entry_attachments where pet_id = pg_temp.u('e01')
           or entry_id in (pg_temp.u('ee1'), pg_temp.u('ee2'))), 0, 'se borran los adjuntos de la ficha');
select is((select count(*)::int from public.clinical_entries
           where id in (pg_temp.u('ee1'), pg_temp.u('ee3')) and pet_id is null
             and retain_until between now() + interval '5 years' - interval '1 day' and now() + interval '5 years'
             and author_id = pg_temp.u('b01') and kind in ('diagnosis', 'vaccine')
             and species_id = (select id from public.species where slug = 'perro')), 2,
  'P1: las entradas de vets quedan desvinculadas con especie, tipo y retain_until = +5 años');
select is((select title from public.clinical_entries where id = pg_temp.u('ee1')), 'Otitis de [redactado]',
  'M3: el nombre de la mascota se redacta del título');
select ok((select body !~* '(ana|ficticia|8765|f11-a01|privada)' and body like '%Control en 7 días.%'
           from public.clinical_entries where id = pg_temp.u('ee1')),
  'M3: nombre, teléfono, email y dirección del dueño se redactan del texto (el resto queda)');
select is((select pet_id from public.clinical_vaccines where entry_id = pg_temp.u('ee3')), null,
  'la vacuna retenida queda sin mascota');
select is((select count(*)::int from public.record_access_log where pet_id = pg_temp.u('e01'))
          + (select count(*)::int from public.record_access_grants where pet_id = pg_temp.u('e01')), 0,
  'se borran el log y las autorizaciones de la mascota');
select is((select concat_ws('|', owner_id, pet_id, address_id, owner_notes, cancel_reason)
           from public.visits where id = pg_temp.u('f01')), '',
  'la visita queda sin dueño, mascota, dirección, notas ni cancel_reason');
select ok((select commune_id is not null and species_id is not null and (quote ->> 'service_price') = '26990'
           from public.visits where id = pg_temp.u('f01')), 'se conservan comuna, especie y montos');
select is((select owner_id from public.payments where id = pg_temp.u('aa7')), null, 'el pago queda sin dueño');
select is((select (sum(amount), (select sum(total) from public.payments where foundation_id = pg_temp.u('fd1')))::text
           from public.foundation_contributions where foundation_id = pg_temp.u('fd1')),
  (select (contrib, paid)::text from t_before), 'los montos y los aportes a la fundación no cambian');
select is((select count(*)::int from public.consents where user_id = pg_temp.u('a01'))
          + (select count(*)::int from private.push_devices where user_id = pg_temp.u('a01'))
          + (select count(*)::int from public.data_exports where user_id = pg_temp.u('a01')), 0,
  'se borran consentimientos, tokens push y el registro de exportaciones');
select is((select count(*)::int from private.storage_erasure_queue), 2,
  'los objetos de Storage de la ficha quedan encolados para la Edge Function');
select ok(exists (select 1 from auth.users where id = pg_temp.u('a01') and banned_until > now() + interval '50 years'),
  'el usuario de Auth sigue (bloqueado) hasta que Storage confirme');
select is((select system || ':' || coalesce(ack_at::text, 'pendiente') from public.deletion_targets
           where request_id = (select (j ->> 'request_id')::uuid from t_req) and system = 'storage'),
  'storage:pendiente', 'el target de Storage espera confirmación');
select ok((select bool_and(system in ('db', 'storage', 'fcm', 'logs', 'auth')) and count(distinct system) = 5
           from public.deletion_targets where request_id = (select (j ->> 'request_id')::uuid from t_req)),
  'deletion_targets cubre BD, Storage, FCM, logs y Auth');
select ok((select bool_and(retained_reason is not null) from public.deletion_targets
           where request_id = (select (j ->> 'request_id')::uuid from t_req) and action = 'retain'),
  'lo retenido queda con su motivo');
create temp table t_cnt as select count(*) as n from public.deletion_targets
  where request_id = (select (j ->> 'request_id')::uuid from t_req);
select is(private.process_deletion((select (j ->> 'request_id')::uuid from t_req)), 'executing',
  'idempotente: correrlo de nuevo sin Storage confirmado no cambia nada');
select is((select count(*) from public.deletion_targets where request_id = (select (j ->> 'request_id')::uuid from t_req)),
  (select n from t_cnt), 'sin targets duplicados');
select is((select count(*)::int from private.privacy_storage_due(100) where reason = 'erasure'), 2,
  'la Edge Function recibe los 2 objetos por borrar');
-- La Edge Function borra con la API de Storage (aquí se simula).
set local storage.allow_delete_query = 'true';
delete from storage.objects o using private.storage_erasure_queue q
  where o.bucket_id = q.bucket_id and o.name = q.object_name;
select is(private.process_deletion((select (j ->> 'request_id')::uuid from t_req)), 'done',
  'con Storage confirmado el job termina');
select is((select count(*)::int from auth.users where id = pg_temp.u('a01')), 0, 'el usuario de Auth se borra al final');
select is((select status || ':' || coalesce(user_id::text, '-') || ':' || (report ->> 'scan')
           from public.deletion_requests where id = (select (j ->> 'request_id')::uuid from t_req)),
  'done:-:clean', 'la solicitud queda terminada, sin el usuario y con el escaneo limpio');
select is((select affected || ':' || (verified_at is not null) from public.deletion_targets
           where request_id = (select (j ->> 'request_id')::uuid from t_req) and target = 'verification_scan'),
  '0:true', 'el escaneo de verificación no encuentra restos');
select is_empty($$ select * from private.privacy_residue(array['00000000-0000-0000-0000-000000170a01',
  '00000000-0000-0000-0000-000000170e01']::uuid[]) $$,
  'ninguna tabla (descubierta por catálogo) conserva el user_id ni el pet_id');
select is((select count(*)::int from storage.objects where name like 'pets/' || pg_temp.u('e01') || '/%'), 0,
  'Storage queda sin objetos de la mascota');
truncate t_cnt;
insert into t_cnt select count(*) from public.deletion_targets
  where request_id = (select (j ->> 'request_id')::uuid from t_req);
select is(private.process_deletion((select (j ->> 'request_id')::uuid from t_req)), 'done',
  'idempotente: una solicitud terminada no se vuelve a procesar');
select is((select count(*) from public.deletion_targets where request_id = (select (j ->> 'request_id')::uuid from t_req)),
  (select n from t_cnt), 'ni agrega targets');
select is(private.run_account_deletions(), '{}'::jsonb, 'el job programado no encuentra nada pendiente');

-- 8. Entradas retenidas: solo el vet autor con solicitud registrada (P1) ------------
select pg_temp.login('b01');
select is((select count(*)::int from public.list_my_retained_entries()), 2,
  'el vet autor lista sus entradas retenidas (sin contenido)');
select ok((select bool_and(not (x ? 'title') and not (x ? 'body')) from public.list_my_retained_entries() x),
  'el listado no trae título ni texto');
select is(pg_temp.err($$ select public.request_retained_entry('00000000-0000-0000-0000-000000170ee1', 'corto') $$),
  '22023', 'la consulta exige un motivo');
select is((public.request_retained_entry(pg_temp.u('ee1'), 'Reclamo del cliente por el tratamiento') ->> 'title'),
  'Otitis de [redactado]', 'con motivo, el vet autor consulta la entrada redactada');
select is((select count(*)::int from public.retained_entry_requests where entry_id = pg_temp.u('ee1')), 1,
  'la consulta queda registrada');
select is((select count(*)::int from public.clinical_entries), 0, 'el vet no lee las entradas retenidas directo');
select pg_temp.login('b02');
select is(pg_temp.err($$ select public.request_retained_entry('00000000-0000-0000-0000-000000170ee1', 'Quiero ver esta entrada') $$),
  '42501', 'otro vet no consulta la entrada retenida');
select pg_temp.login('a02');
select is(pg_temp.err($$ select public.request_retained_entry('00000000-0000-0000-0000-000000170ee1', 'Quiero ver esta entrada') $$),
  '42501', 'un dueño tampoco');
select pg_temp.login('d01');
select is((select count(*)::int from public.retained_entry_requests), 1, 'el admin audita las consultas');

-- 9. Vet que borra su cuenta (HU8.5) ------------------------------------------------
reset role;
select ok((select count(*) from private.vet_open_slots(pg_temp.u('b02'), (now() at time zone 'America/Santiago')::date + 2)) > 0,
  'antes de pedir el borrado el vet ofrece horas');
select pg_temp.login('b02');
create temp table t_vreq as select public.request_account_deletion() as j;
reset role;
select is((select count(*)::int from private.vet_open_slots(pg_temp.u('b02'), (now() at time zone 'America/Santiago')::date + 2)), 0,
  'un vet bloqueado no ofrece horas');
select is((select online from public.vet_presence where vet_id = pg_temp.u('b02')), false,
  'su presencia queda offline');
update public.deletion_requests set execute_after = now() - interval '1 minute'
  where id = (select (j ->> 'request_id')::uuid from t_vreq);
select is(private.process_deletion((select (j ->> 'request_id')::uuid from t_vreq)), 'executing',
  'el borrado del vet espera a Storage (documentos)');
delete from storage.objects o using private.storage_erasure_queue q
  where o.bucket_id = q.bucket_id and o.name = q.object_name;
select is(private.process_deletion((select (j ->> 'request_id')::uuid from t_vreq)), 'done',
  'y termina con el escaneo limpio');
select is((select count(*)::int from public.vet_profiles where user_id = pg_temp.u('b02'))
          + (select count(*)::int from public.vet_bases where vet_id = pg_temp.u('b02'))
          + (select count(*)::int from public.vet_documents where vet_id = pg_temp.u('b02')), 0,
  'se borran su perfil, su base y sus documentos');
select is((select author_role || ':' || coalesce(author_id::text, 'null') || ':' || title
           from public.clinical_entries where id = pg_temp.u('ee4')), 'vet:null:Control de Michi',
  'la entrada del vet se conserva en la ficha del dueño, sin autor');
select pg_temp.login('a02');
select is((select e ->> 'author_name' from jsonb_array_elements(
             public.get_pet_record(pg_temp.u('e02')) -> 'entries') e where e ->> 'id' = pg_temp.u('ee4')::text),
  'MV verificado', 'el dueño ve la autoría clínica seudonimizada ("MV verificado")');
reset role;
select is((select coalesce(vet_id::text, 'null') || ':' || (quote ? 'vet_id')::text || ':' || (owner_id is not null)
           from public.visits where id = pg_temp.u('f03')), 'null:false:true',
  'la visita se anonimiza del lado del vet (también en la cotización congelada)');
select is((select coalesce(vet_id::text, 'null') || ':' || total from public.payments where id = pg_temp.u('aa8')),
  'null:26990', 'el pago queda sin vet y con sus montos');
select is((select count(*)::int from public.admin_audit_log where row_pk = pg_temp.u('b02')::text
           or new_data::text like '%' || pg_temp.u('b02') || '%'), 0,
  'el log del admin no conserva al vet');
select is((select actor_id from public.record_access_log where pet_id = pg_temp.u('e02') order by at desc limit 1),
  null, 'el log de la ficha conserva la acción sin el vet');
select is_empty($$ select * from private.privacy_residue(array['00000000-0000-0000-0000-000000170b02']::uuid[]) $$,
  'sin restos del vet en ninguna tabla');

-- 10. Miembro de fundación ---------------------------------------------------------
select pg_temp.login('c01');
create temp table t_freq as select public.request_account_deletion() as j;
reset role;
update public.deletion_requests set execute_after = now() - interval '1 minute'
  where id = (select (j ->> 'request_id')::uuid from t_freq);
select is(private.run_account_deletions(), '{"done": 1}'::jsonb,
  'el job programado borra al miembro de fundación (sin Storage)');
select is((select count(*)::int from public.foundation_members where user_id = pg_temp.u('c01')), 0,
  'su membresía se borra');
select pg_temp.login('c02');
select is((select sum(total)::int from public.foundation_summary(12)), (select sum(total)::int from t_tot),
  'foundation_summary() no cambia tras los tres borrados');
reset role;
select is_empty($$ select * from private.privacy_residue(array['00000000-0000-0000-0000-000000170c01']::uuid[]) $$,
  'sin restos del miembro');

-- 11. Retención y huérfanos (M2) ------------------------------------------------------
select is((select count(*)::int from private.privacy_storage_due(1000)
           where reason = 'orphan' and name like 'pets/' || pg_temp.u('e02') || '/%'), 1,
  'M2: solo el adjunto sin registrar de más de 24 h es candidato');
select ok((select bool_and(name like '%huerfano.pdf') from private.privacy_storage_due(1000)
           where reason = 'orphan' and name like 'pets/' || pg_temp.u('e02') || '/%'),
  'el reciente (menos de 24 h) aún no');
select ok((select (r ->> 'retained_entries_deleted')::int >= 1 and (r ->> 'access_log_anonymized')::int >= 1
                  and (r ->> 'push_tokens_deleted')::int >= 1
           from (select private.run_privacy_retention() as r) x),
  'retención: entradas retenidas vencidas, logs de más de 2 años y tokens sin uso en 90 días');
select is((select count(*)::int from public.clinical_entries where id = pg_temp.u('ee5')), 0,
  'la entrada retenida vencida se borra');
select is((select count(*)::int from public.record_access_log
           where pet_id = pg_temp.u('e02') and at < now() - interval '2 years' and actor_id is not null), 0,
  'el log de más de 2 años queda sin actor');
select is((select token from private.push_devices where user_id = pg_temp.u('a02')), 'token-a02-nuevo-xx',
  'se borra el token sin uso en 90 días y se conserva el de hace 10 días');
select is(private.run_privacy_retention(),
  '{"push_tokens_deleted": 0, "access_log_anonymized": 0, "retained_entries_deleted": 0}'::jsonb,
  'la retención es idempotente');

-- 12. Escaneo de PII en texto libre ----------------------------------------------------
select pg_temp.login('a02');
select is(pg_temp.err($$ update public.clinical_entries set title = 'x' $$), '42501',
  'la ficha sigue siendo solo inserción para la API');
reset role;
select ok(private.run_pii_scan() >= 1, 'el escaneo de PII corre y registra hallazgos');
create temp table t_hits as select * from public.pii_scan_findings
  where table_name = 'visits' and row_pk = pg_temp.u('f03')::text;
select is((select count(*)::int from t_hits where column_name = 'owner_notes' and kind = 'email'), 1,
  'detecta el email en las notas de una visita');
select is((select masked from t_hits where kind = 'email'), 'be***', 'guarda solo un valor enmascarado');
select is(private.run_pii_scan(), 0, 'el escaneo no duplica hallazgos');
select is((select count(*)::int from public.pii_scan_findings
           where table_name = 'clinical_entries' and row_pk = pg_temp.u('ee1')::text), 0,
  'la entrada retenida y redactada no tiene PII');
select pg_temp.login('a02');
select is((select count(*)::int from public.pii_scan_findings), 0, 'los hallazgos no los ve un usuario');
select pg_temp.login('d01');
select ok((select count(*)::int from public.pii_scan_findings) >= 1, 'el admin ve los hallazgos');

select * from finish();
rollback;
