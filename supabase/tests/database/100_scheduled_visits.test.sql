-- Fase 6: visitas agendadas. Disponibilidad, reserva con precio congelado,
-- exclusión de solapes, máquina de estados (válidas e inválidas), privacidad
-- de la dirección, pago solo al completar, cargo de cancelación y
-- expiración por cron.
begin;
select plan(111);
-- QA-F11-02: la sesión en UTC+14 hace que current_date (y todo lo que dependa
-- de la zona de la sesión) difiera casi siempre de la fecha de Chile, como
-- entre las 21:00 y las 24:00 reales. La lógica debe usar America/Santiago.
set local timezone = 'Etc/GMT-14';

-- Fixtures ------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000009a1', 'f6-dueno-a@test.local'),
  ('00000000-0000-0000-0000-0000000009a2', 'f6-dueno-b@test.local'),
  ('00000000-0000-0000-0000-0000000009b1', 'f6-vet-1@test.local'),
  ('00000000-0000-0000-0000-0000000009b2', 'f6-vet-2@test.local'),
  ('00000000-0000-0000-0000-0000000009c1', 'f6-admin@test.local');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000009a1', 'owner'),
  ('00000000-0000-0000-0000-0000000009a2', 'owner'),
  ('00000000-0000-0000-0000-0000000009b1', 'vet'),
  ('00000000-0000-0000-0000-0000000009b2', 'vet'),
  ('00000000-0000-0000-0000-0000000009c1', 'admin');
insert into public.owner_profiles (user_id, display_name, phone, commune_id) values
  ('00000000-0000-0000-0000-0000000009a1', 'Ana Agenda', '+56 9 1111 1111',
   (select id from public.communes where name = 'Ñuñoa')),
  ('00000000-0000-0000-0000-0000000009a2', 'Beto Agenda', null,
   (select id from public.communes where name = 'Ñuñoa'));
insert into public.vet_profiles (user_id, display_name, status, bio) values
  ('00000000-0000-0000-0000-0000000009b1', 'Dra. Agenda', 'approved', 'Perros (ficticia).'),
  ('00000000-0000-0000-0000-0000000009b2', 'Dr. Gatuno', 'approved', null);
insert into public.vet_species (vet_id, species_id) values
  ('00000000-0000-0000-0000-0000000009b1', (select id from public.species where slug = 'perro')),
  ('00000000-0000-0000-0000-0000000009b2', (select id from public.species where slug = 'gato'));
insert into public.vet_specialties (vet_id, specialty_id)
  select v, (select id from public.specialties where slug = 'general')
  from unnest(array['00000000-0000-0000-0000-0000000009b1',
                    '00000000-0000-0000-0000-0000000009b2']::uuid[]) v;
-- Disponibles todos los días, todo el día (hora de Chile).
insert into public.vet_availability (vet_id, weekday, start_min, end_min)
  select v, d, 0, 1440
  from unnest(array['00000000-0000-0000-0000-0000000009b1',
                    '00000000-0000-0000-0000-0000000009b2']::uuid[]) v,
       generate_series(1, 7) d;
-- Origen ≈ 7,99 km al norte de la dirección de A.
insert into public.vet_bases (vet_id, commune_id, lat, lng) values
  ('00000000-0000-0000-0000-0000000009b1',
   (select commune_id from public.communes_at_point(-33.3849, -70.5974) limit 1), -33.3849, -70.5974),
  ('00000000-0000-0000-0000-0000000009b2',
   (select commune_id from public.communes_at_point(-33.3849, -70.5974) limit 1), -33.3849, -70.5974);
-- Sin desplazamiento del origen aproximado (QA-F5-01): montos deterministas.
update public.vet_bases set fuzz_dlat = 0, fuzz_dlng = 0
  where vet_id in ('00000000-0000-0000-0000-0000000009b1', '00000000-0000-0000-0000-0000000009b2');
-- O-F7-c: aísla el test de los vets que ya existan en la BD (demo o de otros
-- E2E). Se suspenden solo dentro de esta transacción, que termina en rollback.
set local session_replication_role = replica;
update public.vet_profiles set status = 'suspended'
  where status = 'approved'
    and user_id not in ('00000000-0000-0000-0000-0000000009b1', '00000000-0000-0000-0000-0000000009b2');
set local session_replication_role = origin;

update public.foundations set is_default = false where is_default;
insert into public.foundations (id, name, is_default) values
  ('00000000-0000-0000-0000-00000000f6a1', 'F6 Fundación', true);
insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee, effective_from)
values (15, 20, 30, 500, 5, 5000, now() - interval '2 seconds');

insert into public.pets (id, owner_id, name, species_id) values
  ('00000000-0000-0000-0000-00000000e9a1', '00000000-0000-0000-0000-0000000009a1', 'Firulais',
   (select id from public.species where slug = 'perro'));
insert into public.addresses (id, owner_id, label, street_text, details, commune_id, lat, lng) values
  ('00000000-0000-0000-0000-00000000e9b1', '00000000-0000-0000-0000-0000000009a1', 'Casa',
   'Av. Ficticia 123', 'Depto 4', (select id from public.communes where name = 'Ñuñoa'),
   -33.4569, -70.5974),
  ('00000000-0000-0000-0000-00000000e9b2', '00000000-0000-0000-0000-0000000009a1', 'Trabajo',
   'Calle Inventada 9', null, (select id from public.communes where name = 'Ñuñoa'),
   -33.4560, -70.5980);

create temp table t_ids (k text primary key, v uuid);
create temp table t_ts (k text primary key, v timestamptz);
grant all on t_ids, t_ts to authenticated;
-- T = pasado mañana a las 09:00 de Chile (QA-F11-02). Antes era "mañana a esta
-- hora": de 22:00 a 22:59 de Chile la reserva de T + 90 min (23:30) cruzaba la
-- medianoche y el test fallaba. A las 09:00 caben todas las reservas del día
-- (la última, T + 13 h = 22:00) a cualquier hora en que se corra, y T − 2 h
-- queda siempre a más de 12 h (el plazo de confirmación es siempre 12 h).
insert into t_ts values ('T',
  ((now() at time zone 'America/Santiago')::date + 2 + time '09:00') at time zone 'America/Santiago');

create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.id(p_k text) returns uuid language sql as $$
  select v from t_ids where k = p_k;
$$;
create function pg_temp.ts(p_k text) returns timestamptz language sql as $$
  select v from t_ts where k = p_k;
$$;
create function pg_temp.spec() returns integer language sql security definer as $$
  select id from public.specialties where slug = 'general';
$$;
-- Cotiza (dueño A) con un vet.
create function pg_temp.q(p_vet uuid default '00000000-0000-0000-0000-0000000009b1')
returns uuid language sql as $$
  select (public.quote_visit('00000000-0000-0000-0000-00000000e9a1',
    '00000000-0000-0000-0000-00000000e9b1', pg_temp.spec(), 'scheduled', p_vet) ->> 'quote_id')::uuid;
$$;
-- Reserva (dueño A) con la mascota, la dirección y el vet 1.
create function pg_temp.book(p_q uuid, p_at timestamptz) returns jsonb language sql as $$
  select public.book_visit(p_q, '00000000-0000-0000-0000-0000000009b1',
    '00000000-0000-0000-0000-00000000e9a1', '00000000-0000-0000-0000-00000000e9b1', p_at);
$$;
create function pg_temp.tr(p_v uuid, p_to text, p_reason text default null)
returns jsonb language sql as $$
  select public.transition_visit(p_v, p_to, p_reason);
$$;
create function pg_temp.mv(p_v uuid) returns jsonb language sql as $$
  select j from public.my_visits(200) j where j ->> 'id' = p_v::text;
$$;
-- Simula el paso del tiempo: solo una sesión directa de postgres con
-- felix.time_travel = 'on' puede mover el horario (riesgo de QA fase 6).
create function pg_temp.tt(p_sql text) returns void language plpgsql as $$
begin
  perform set_config('felix.time_travel', 'on', true);
  execute p_sql;
  perform set_config('felix.time_travel', 'off', true);
end;
$$;
create function pg_temp.shift(p_v uuid, p_at timestamptz) returns void language sql as $$
  select pg_temp.tt(format('update public.visits set scheduled_at = %L::timestamptz,
    slot = tstzrange(%L::timestamptz, %L::timestamptz + interval ''90 minutes'') where id = %L',
    p_at, p_at, p_at, p_v));
$$;
grant execute on function pg_temp.id(text), pg_temp.ts(text), pg_temp.spec(),
  pg_temp.q(uuid), pg_temp.book(uuid, timestamptz), pg_temp.tr(uuid, text, text),
  pg_temp.mv(uuid) to authenticated;

-- Estructura y privilegios ----------------------------------------------------
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
           where oid in ('public.visits'::regclass, 'public.visit_events'::regclass,
                         'public.vet_time_off'::regclass)),
  'RLS habilitada y forzada en las tablas de la fase 6');
select is_empty(
  $$ select t || ':' || p from unnest(array['public.visits', 'public.visit_events']) t
     cross join unnest(array['INSERT', 'UPDATE', 'DELETE']) p
     where has_table_privilege('authenticated', t, p)
        or exists (select 1 from information_schema.column_privileges c
                   where c.grantee = 'authenticated' and c.table_schema || '.' || c.table_name = t
                     and c.privilege_type = p) $$,
  'la app no inserta, modifica ni borra visitas ni su historial');
select ok(not has_column_privilege('authenticated', 'public.visits', 'quote', 'select')
      and has_column_privilege('authenticated', 'public.visits', 'status', 'select'),
  'lectura directa solo de columnas sin datos de terceros (sin el precio)');
select is_empty(
  $$ select p from unnest(array[
       'private.apply_transition(uuid, text, uuid, text, integer)',
       'private.vet_slot_ok(uuid, timestamptz)', 'private.vet_open_slots(uuid, date)',
       'private.expire_visits()', 'private.purge_stale_quotes()',
       'private.record_payment(uuid, uuid, uuid, uuid, uuid, text, integer, integer, integer, integer, integer, boolean)',
       'private.charge_cancel_fee(public.visits)', 'private.cancel_fee_for(public.visits, timestamptz)',
       'private.visit_view(public.visits, uuid)', 'private.visit_edge_allowed(text, text)',
       'private.consume_quote(uuid, uuid, uuid, uuid, uuid)']) p
     where has_function_privilege('authenticated', p, 'execute') $$,
  'las funciones internas de visitas no las ejecuta la app');
select is_empty(
  $$ select p from unnest(array[
       'public.available_vets(uuid, uuid, integer, date)',
       'public.book_visit(uuid, uuid, uuid, uuid, timestamptz, text)',
       'public.transition_visit(uuid, text, text)', 'public.my_visits(integer)',
       'public.simulate_payment(uuid, boolean)', 'public.admin_visit_summary(integer)',
       'public.add_time_off(date, date)']) p
     where has_function_privilege('anon', p, 'execute') $$,
  'anon no ejecuta ninguna RPC de visitas');
select is_empty(
  $$ select c.conrelid::regclass || '.' || a.attname
     from pg_constraint c
     join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f'
       and c.conrelid in ('public.visits'::regclass, 'public.visit_events'::regclass,
                          'public.vet_time_off'::regclass, 'public.payments'::regclass)
       and not exists (select 1 from pg_index i
                       where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1]) $$,
  'toda FK de la fase 6 tiene un índice');
select ok(exists (select 1 from pg_constraint where conname = 'visits_no_overlap'
                  and contype = 'x' and conrelid = 'public.visits'::regclass),
  'restricción de exclusión (btree_gist + tstzrange) sobre las visitas');
select is((select schedule from cron.job where jobname = 'expire-visits'), '* * * * *',
  'pg_cron expira visitas cada minuto');
select is((select command from cron.job where jobname = 'purge-stale-quotes'),
  'select private.purge_stale_quotes()', 'pg_cron purga las cotizaciones vencidas sin usar');

-- Disponibilidad (dueño A) ------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000009a1');
set local role authenticated;

create temp table t_av as
  select j from public.available_vets('00000000-0000-0000-0000-00000000e9a1',
    '00000000-0000-0000-0000-00000000e9b1', pg_temp.spec(),
    (pg_temp.ts('T') at time zone 'America/Santiago')::date) j;
select is((select count(*)::int from t_av), 1,
  'solo aparece el vet aprobado con la especie y la especialidad');
select is((select j ->> 'display_name' from t_av), 'Dra. Agenda', 'el vet compatible es la Dra. Agenda');
select is((select string_agg(k, ',' order by k) from t_av, jsonb_object_keys(j) k),
  'bio,display_name,distance_km,slots,vet_id', 'del vet solo se entregan datos públicos');
select is((select (j ->> 'distance_km')::numeric from t_av), 8.0,
  'la distancia se entrega redondeada al km, desde el origen aproximado');
select ok((select (j -> 'slots') @> to_jsonb(array[pg_temp.ts('T')]) from t_av),
  'el horario de mañana está disponible');
select throws_ok(
  $$ select public.available_vets('00000000-0000-0000-0000-00000000e9a1',
       '00000000-0000-0000-0000-00000000e9b1', pg_temp.spec(),
       (now() at time zone 'America/Santiago')::date + 31) $$,
  '22023', 'Elige una fecha dentro de los próximos 30 días', 'no se ofrece fuera de 30 días');
select ok(not exists (
    select 1 from public.available_vets('00000000-0000-0000-0000-00000000e9a1',
      '00000000-0000-0000-0000-00000000e9b1', pg_temp.spec(),
      (now() at time zone 'America/Santiago')::date) j,
    jsonb_array_elements_text(j -> 'slots') s
    where s::timestamptz < now() + interval '3 hours'),
  'no se ofrecen horas con menos de 3 h de anticipación');

-- Reserva ------------------------------------------------------------------------
insert into t_ids values ('q1', pg_temp.q());
select throws_ok($$ select pg_temp.book(pg_temp.id('q1'), pg_temp.ts('T') + interval '5 minutes') $$,
  '22023', 'El horario ya no está disponible. Elige otro.', 'no se reserva una hora fuera de la grilla');
select throws_ok($$ select pg_temp.book(pg_temp.id('q1'), date_trunc('hour', now()) + interval '2 hours') $$,
  '22023', 'El horario ya no está disponible. Elige otro.', 'no se reserva con menos de 3 h de anticipación');
-- O-1 (QA fase 5): la cotización debe coincidir con lo elegido y traer vet.
select throws_ok(
  $$ select public.book_visit(pg_temp.id('q1'), '00000000-0000-0000-0000-0000000009b2',
       '00000000-0000-0000-0000-00000000e9a1', '00000000-0000-0000-0000-00000000e9b1', pg_temp.ts('T')) $$,
  '22023', 'La cotización no coincide con el veterinario, la mascota o la dirección elegidos',
  'no se reserva con otro vet que el cotizado');
select throws_ok(
  $$ select public.book_visit(pg_temp.id('q1'), '00000000-0000-0000-0000-0000000009b1',
       '00000000-0000-0000-0000-00000000e9a1', '00000000-0000-0000-0000-00000000e9b2', pg_temp.ts('T')) $$,
  '22023', 'La cotización no coincide con el veterinario, la mascota o la dirección elegidos',
  'no se reserva con otra dirección que la cotizada');
insert into t_ids values ('q_novet', pg_temp.q(null));
select throws_ok($$ select pg_temp.book(pg_temp.id('q_novet'), pg_temp.ts('T')) $$,
  '22023', 'La cotización no corresponde a una visita agendada con veterinario',
  'una cotización agendada sin vet no se reserva (saldría sin recargo por distancia)');
select ok((select consumed_at is null from public.quotes where id = pg_temp.id('q1')),
  'los intentos fallidos no consumen la cotización');

insert into t_ids select 'v1', (pg_temp.book(pg_temp.id('q1'), pg_temp.ts('T')) ->> 'id')::uuid;
select is((pg_temp.mv(pg_temp.id('v1')) ->> 'status'), 'pending_vet', 'la reserva nace pendiente del vet');
select ok((select consumed_at is not null from public.quotes where id = pg_temp.id('q1')),
  'la reserva consume la cotización');
select is((pg_temp.mv(pg_temp.id('v1')) -> 'quote' ->> 'quote_id'), pg_temp.id('q1')::text,
  'visits.quote guarda el snapshot de la cotización');
select is((pg_temp.mv(pg_temp.id('v1')) -> 'quote' ->> 'total')::int,
  (select total from public.quotes where id = pg_temp.id('q1')), 'el precio queda congelado en la visita');
select is((pg_temp.mv(pg_temp.id('v1')) ->> 'vet_name'), 'Dra. Agenda', 'el dueño ve el nombre público del vet');
select ok(not (pg_temp.mv(pg_temp.id('v1')) ? 'exact'), 'la vista del dueño no trae datos del vet ni ajenos');
select is((pg_temp.mv(pg_temp.id('v1')) ->> 'confirm_deadline')::timestamptz, now() + interval '12 hours',
  'plazo de confirmación: 12 h (o 2 h antes, lo primero)');
select throws_ok($$ select pg_temp.book(pg_temp.id('q1'), pg_temp.ts('T') + interval '3 hours') $$,
  '22023', 'La cotización ya fue usada', 'una cotización no se reserva dos veces');

-- Solapes.
insert into t_ids values ('q2', pg_temp.q());
select throws_ok($$ select pg_temp.book(pg_temp.id('q2'), pg_temp.ts('T') + interval '1 hour') $$,
  '22023', 'El horario ya no está disponible. Elige otro.', 'no se reserva un horario que se solapa');
select throws_ok($$ select pg_temp.book(pg_temp.id('q2'), pg_temp.ts('T') - interval '1 hour') $$,
  '22023', 'El horario ya no está disponible. Elige otro.',
  'el margen de traslado de 30 min también bloquea la hora anterior');
insert into t_ids select 'v2', (pg_temp.book(pg_temp.id('q2'), pg_temp.ts('T') + interval '90 minutes') ->> 'id')::uuid;
select ok(pg_temp.id('v2') is not null, 'se reserva justo después del margen de traslado');
select ok(not exists (
    select 1 from public.available_vets('00000000-0000-0000-0000-00000000e9a1',
      '00000000-0000-0000-0000-00000000e9b1', pg_temp.spec(),
      (pg_temp.ts('T') at time zone 'America/Santiago')::date) j
    where (j -> 'slots') @> to_jsonb(array[pg_temp.ts('T')])),
  'un horario reservado deja de ofrecerse');

reset role;
select throws_ok(
  $$ insert into public.visits (owner_id, vet_id, mode, status, commune_id, species_id,
       specialty_id, foundation_id, scheduled_at, slot, confirm_deadline, quote)
     values ('00000000-0000-0000-0000-0000000009a2', '00000000-0000-0000-0000-0000000009b1',
       'scheduled', 'pending_vet', 1, 1, 1, '00000000-0000-0000-0000-00000000f6a1',
       pg_temp.ts('T') + interval '30 minutes',
       tstzrange(pg_temp.ts('T') + interval '30 minutes', pg_temp.ts('T') + interval '2 hours'),
       now(), '{}') $$,
  '23P01', null, 'la restricción de exclusión rechaza solapes incluso por SQL directo');
select throws_ok(
  $$ update public.visits set status = 'accepted' where id = pg_temp.id('v1') $$,
  '42501', 'El estado de una visita solo cambia con transition_visit',
  'ni el SQL interno cambia el estado fuera de transition_visit');
select throws_ok(
  $$ update public.visits set quote = '{"total": 1}' where id = pg_temp.id('v1') $$,
  '42501', 'Los datos y el precio de una visita no se modifican', 'el precio congelado no se modifica');
select throws_ok(
  $$ update public.visits set scheduled_at = scheduled_at + interval '1 day',
       slot = tstzrange(lower(slot) + interval '1 day', upper(slot) + interval '1 day')
     where id = pg_temp.id('v1') $$,
  '42501', 'El horario de una visita no se modifica',
  'el horario no se mueve sin la marca de viaje en el tiempo (solo tests)');

-- Accesos indebidos ------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000009a1');
set local role authenticated;
select throws_ok($$ update public.visits set status = 'completed' where id = pg_temp.id('v1') $$,
  '42501', null, 'el dueño no actualiza visitas directamente');
select throws_ok($$ select pg_temp.tr(pg_temp.id('v1'), 'accepted') $$,
  '42501', 'Esta acción le corresponde al veterinario', 'el dueño no confirma su propia visita');
select throws_ok($$ select public.simulate_payment(pg_temp.id('v1')) $$,
  '22023', 'Solo puedes pagar una visita completada', 'no se paga antes de completar');
select is((select count(*)::int from public.vet_profiles), 0, 'el dueño no lee perfiles de vets');
select is((select count(*)::int from public.vet_availability), 0, 'el dueño no lee la agenda del vet');

reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009a2');
set local role authenticated;
select is((select count(*)::int from public.my_visits()), 0, 'el dueño B no ve visitas de A');
select is((select count(*)::int from public.visits), 0, 'el dueño B no lee filas de visitas de A');
select throws_ok($$ select pg_temp.tr(pg_temp.id('v1'), 'cancelled_owner') $$,
  '22023', 'La visita no existe', 'el dueño B no cancela una visita de A');

reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009b2');
set local role authenticated;
select is((select count(*)::int from public.my_visits()), 0, 'otro vet no ve la visita');
select throws_ok($$ select pg_temp.tr(pg_temp.id('v1'), 'accepted') $$,
  '22023', 'La visita no existe', 'otro vet no confirma una visita ajena');

-- Vet asignado: dirección aproximada, confirmación y flujo -----------------------
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009b1');
set local role authenticated;
select is((pg_temp.mv(pg_temp.id('v1')) -> 'exact'), 'null'::jsonb,
  'con la solicitud pendiente el vet no ve la dirección exacta');
select is((pg_temp.mv(pg_temp.id('v1')) ->> 'commune_name'), 'Ñuñoa', 'el vet ve la comuna');
select is((pg_temp.mv(pg_temp.id('v1')) ->> 'distance_km')::numeric, 8.0,
  'el vet ve la distancia redondeada (address_approx)');
select ok(not (pg_temp.mv(pg_temp.id('v1')) ? 'quote') and not (pg_temp.mv(pg_temp.id('v1')) ? 'address_text'),
  'el vet no ve la donación ni la dirección del dueño');
select is((select count(*)::int from public.addresses), 0, 'el vet no lee direcciones');
select throws_ok($$ select pg_temp.tr(pg_temp.id('v1'), 'en_route') $$,
  '22023', 'Transición no permitida: pending_vet → en_route', 'transición inválida: pendiente → en camino');
select throws_ok($$ select pg_temp.tr(pg_temp.id('v1'), 'cancelled_owner') $$,
  '42501', 'Esta acción le corresponde al dueño', 'el vet no cancela como dueño');
select throws_ok($$ select pg_temp.tr(pg_temp.id('v1'), 'volando') $$,
  '22023', 'Transición no permitida: pending_vet → volando', 'estado desconocido');
select is((pg_temp.tr(pg_temp.id('v1'), 'accepted') ->> 'status'), 'accepted', 'el vet confirma');
select is((pg_temp.mv(pg_temp.id('v1')) -> 'exact' ->> 'street_text'), 'Av. Ficticia 123',
  'confirmada, el vet asignado ve la dirección exacta');
select is((pg_temp.mv(pg_temp.id('v1')) -> 'exact' ->> 'owner_phone'), '+56 9 1111 1111',
  'confirmada, el vet asignado ve el teléfono del dueño');
select throws_ok($$ select pg_temp.tr(pg_temp.id('v1'), 'accepted') $$,
  '22023', 'Transición no permitida: accepted → accepted', 'no se confirma dos veces');
select throws_ok($$ select pg_temp.tr(pg_temp.id('v1'), 'en_route') $$,
  '22023', 'Puedes marcar "en camino" desde 2 horas antes de la visita',
  'no puede salir un día antes');

reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009a1');
set local role authenticated;
select is((pg_temp.mv(pg_temp.id('v1')) ->> 'cancel_fee_now')::int, 0,
  'más de 2 h antes, cancelar es gratis');

-- Paso del tiempo: la visita empieza en 20 min.
reset role;
select pg_temp.shift(pg_temp.id('v1'), date_trunc('minute', now()) + interval '20 minutes');
select pg_temp.login('00000000-0000-0000-0000-0000000009a1');
set local role authenticated;
select is((pg_temp.mv(pg_temp.id('v1')) ->> 'cancel_fee_now')::int, 5000,
  'dentro de las 2 h, cancelar tendría cargo de $5.000');

reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009b1');
set local role authenticated;
select is((pg_temp.tr(pg_temp.id('v1'), 'en_route') ->> 'status'), 'en_route', 'en camino');
select throws_ok($$ select pg_temp.tr(pg_temp.id('v1'), 'in_progress') $$,
  '22023', 'Transición no permitida: en_route → in_progress', 'no se salta "llegó"');
select is((pg_temp.tr(pg_temp.id('v1'), 'arrived') ->> 'status'), 'arrived', 'llegó');
select is((pg_temp.tr(pg_temp.id('v1'), 'in_progress') ->> 'status'), 'in_progress', 'en curso');
select throws_ok($$ select pg_temp.tr(pg_temp.id('v1'), 'completed') $$,
  '22023', 'La atención debe durar al menos 10 minutos antes de completarla',
  'QA-F6-04: no se completa sin una atención mínima');
reset role;
select pg_temp.tt(format('update public.visits set started_at = now() - interval ''15 minutes'' where id = %L',
  pg_temp.id('v1')));
select pg_temp.login('00000000-0000-0000-0000-0000000009b1');
set local role authenticated;
select is((pg_temp.tr(pg_temp.id('v1'), 'completed') ->> 'status'), 'completed', 'completada');
select is((pg_temp.mv(pg_temp.id('v1')) -> 'exact'), 'null'::jsonb,
  'cerrada la visita, el vet vuelve a ver solo lo aproximado');
select throws_ok($$ select pg_temp.tr(pg_temp.id('v1'), 'in_progress') $$,
  '22023', 'Transición no permitida: completed → in_progress', 'una visita completada no se reabre');
select throws_ok($$ select public.simulate_payment(pg_temp.id('v1')) $$,
  '42501', 'Solo un dueño puede pagar', 'el vet no paga');

-- Pago solo al completar --------------------------------------------------------
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009a2');
set local role authenticated;
select throws_ok($$ select public.simulate_payment(pg_temp.id('v1')) $$,
  '22023', 'La visita no existe', 'el dueño B no paga la visita de A');

reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009a1');
set local role authenticated;
select throws_ok($$ select pg_temp.tr(pg_temp.id('v1'), 'cancelled_owner') $$,
  '22023', 'Transición no permitida: completed → cancelled_owner', 'no se cancela una visita completada');
select is((public.simulate_payment(pg_temp.id('v1'), true) ->> 'status'), 'simulated_failed',
  'se puede simular un pago rechazado');
select is((public.simulate_payment(pg_temp.id('v1')) ->> 'total')::int,
  (select total from public.quotes where id = pg_temp.id('q1')), 'el pago usa el precio congelado');
select is((select concat_ws(',', kind, status, visit_id, vet_id) from public.payments
           where visit_id = pg_temp.id('v1') and status = 'simulated_paid'),
  'visit,simulated_paid,' || pg_temp.id('v1') || ',00000000-0000-0000-0000-0000000009b1',
  'el pago queda ligado a la visita y al vet');
select throws_ok($$ select public.simulate_payment(pg_temp.id('v1')) $$,
  '22023', 'Esta visita ya está pagada', 'una visita no se paga dos veces');
select is((pg_temp.mv(pg_temp.id('v1')) ->> 'paid')::boolean, true, 'el dueño ve la visita pagada');

reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009b1');
set local role authenticated;
select is((select count(*)::int from public.my_payouts() where visit_id = pg_temp.id('v1')), 2,
  'el vet ve las liquidaciones de su visita (my_payouts, QA-F11-05)');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009b2');
set local role authenticated;
select is((select count(*)::int from public.payments) + (select count(*)::int from public.my_payouts()),
  0, 'otro vet no ve esos pagos');
reset role;
select is((select string_agg(c.kind, ',' order by c.kind) from public.foundation_contributions c
           join public.payments p on p.id = c.payment_id where p.visit_id = pg_temp.id('v1')),
  'commission_share', 'el pago genera el aporte a la fundación');
select is((select string_agg(coalesce(from_status, '-') || '>' || to_status, ' ' order by id)
           from public.visit_events where visit_id = pg_temp.id('v1')),
  '->pending_vet pending_vet>accepted accepted>en_route en_route>arrived arrived>in_progress in_progress>completed',
  'historial completo de estados');

-- Cancelaciones -------------------------------------------------------------------
-- v2 pendiente: el dueño la retira gratis.
select pg_temp.login('00000000-0000-0000-0000-0000000009a1');
set local role authenticated;
select is((pg_temp.tr(pg_temp.id('v2'), 'cancelled_owner') ->> 'cancel_fee')::int, 0,
  'retirar una solicitud pendiente es gratis');
-- v3 confirmada, más de 2 h antes: gratis.
insert into t_ids select 'v3', (pg_temp.book(pg_temp.q(), pg_temp.ts('T') + interval '3 hours') ->> 'id')::uuid;
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009b1');
set local role authenticated;
select pg_temp.tr(pg_temp.id('v3'), 'accepted');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009a1');
set local role authenticated;
select is((pg_temp.tr(pg_temp.id('v3'), 'cancelled_owner') ->> 'cancel_fee')::int, 0,
  'cancelar una confirmada con más de 2 h es gratis');
select is((select count(*)::int from public.payments where visit_id = pg_temp.id('v3')), 0,
  'sin cargo no hay pago');

-- v4 confirmada; el admin publica otro cargo; la visita entra en las 2 h.
insert into t_ids select 'v4', (pg_temp.book(pg_temp.q(), pg_temp.ts('T') + interval '5 hours') ->> 'id')::uuid;
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009b1');
set local role authenticated;
select pg_temp.tr(pg_temp.id('v4'), 'accepted');
reset role;
insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee, effective_from)
values (15, 20, 30, 500, 5, 7000, now() - interval '1 second');
select pg_temp.shift(pg_temp.id('v4'), date_trunc('minute', now()) + interval '90 minutes');
select pg_temp.login('00000000-0000-0000-0000-0000000009a1');
set local role authenticated;
select is((pg_temp.tr(pg_temp.id('v4'), 'cancelled_owner', 'Me surgió un viaje') ->> 'cancel_fee')::int,
  5000, 'cancelar dentro de las 2 h cobra $5.000 (parámetros congelados en la cotización)');
select is((select concat_ws(',', kind, status, service_price, platform_fee, foundation_share,
                            vet_payout, total)
           from public.payments where visit_id = pg_temp.id('v4')),
  'cancel_fee,simulated_paid,5000,750,150,4250,5000', 'el cargo queda como pago simulado con su reparto');
select is((pg_temp.mv(pg_temp.id('v4')) ->> 'cancel_reason'), 'Me surgió un viaje', 'queda el motivo');
select throws_ok($$ select public.simulate_payment(pg_temp.id('v4')) $$,
  '22023', 'Solo puedes pagar una visita completada', 'una visita cancelada no se paga');

-- v5 confirmada: el vet cancela (sin cargo para el dueño).
insert into t_ids select 'v5', (pg_temp.book(pg_temp.q(), pg_temp.ts('T') + interval '7 hours') ->> 'id')::uuid;
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009b1');
set local role authenticated;
select pg_temp.tr(pg_temp.id('v5'), 'accepted');
select is((pg_temp.tr(pg_temp.id('v5'), 'cancelled_vet') ->> 'cancel_fee')::int, 0,
  'si cancela el vet, el dueño no paga');
-- v6 pendiente: el vet la rechaza.
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009a1');
set local role authenticated;
insert into t_ids select 'v6', (pg_temp.book(pg_temp.q(), pg_temp.ts('T') + interval '9 hours') ->> 'id')::uuid;
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009b1');
set local role authenticated;
select is((pg_temp.tr(pg_temp.id('v6'), 'rejected') ->> 'status'), 'rejected', 'el vet rechaza una solicitud');

-- Expiración por cron ---------------------------------------------------------
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009a1');
set local role authenticated;
insert into t_ids select 'v7', (pg_temp.book(pg_temp.q(), pg_temp.ts('T') + interval '11 hours') ->> 'id')::uuid;
insert into t_ids select 'v8', (pg_temp.book(pg_temp.q(), pg_temp.ts('T') + interval '13 hours') ->> 'id')::uuid;
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009b1');
set local role authenticated;
select pg_temp.tr(pg_temp.id('v8'), 'accepted');
reset role;
-- v7: venció el plazo de confirmación. v8: confirmada que nunca empezó.
select pg_temp.tt(format('update public.visits set confirm_deadline = now() - interval ''1 minute'' where id = %L', pg_temp.id('v7')));
select pg_temp.shift(pg_temp.id('v8'), date_trunc('minute', now()) - interval '2 hours');
select pg_temp.login('00000000-0000-0000-0000-0000000009b1');
set local role authenticated;
select throws_ok($$ select pg_temp.tr(pg_temp.id('v7'), 'accepted') $$,
  '22023', 'El plazo para confirmar venció', 'el vet no confirma fuera de plazo');
reset role;
select ok(private.expire_visits() >= 2, 'el job de expiración procesa las dos visitas');
select is((select status from public.visits where id = pg_temp.id('v7')), 'expired',
  'la solicitud no confirmada a tiempo expira');
select is((select concat_ws(',', status, cancel_fee) from public.visits where id = pg_temp.id('v8')),
  'cancelled_vet,0', 'la confirmada que nunca empezó se cierra como cancelación del vet, sin cargo');
select is((select actor_id from public.visit_events where visit_id = pg_temp.id('v7')
           and to_status = 'expired'), null::uuid, 'la expiración la registra el sistema (sin actor)');
select is(private.expire_visits(), 0, 'el job es idempotente');

-- Purga de cotizaciones vencidas sin usar.
insert into public.quotes (id, owner_id, species_id, specialty_id, commune_id, mode,
  pricing_config_id, foundation_id, base_price, urgent_surcharge, billable_km,
  distance_surcharge, discount, service_price, platform_fee, foundation_share,
  vet_payout, extra_donation, total, created_at, expires_at)
values ('00000000-0000-0000-0000-00000000e9f1', '00000000-0000-0000-0000-0000000009a1',
  (select id from public.species where slug = 'perro'), pg_temp.spec(),
  (select id from public.communes where name = 'Ñuñoa'), 'scheduled',
  (select id from public.current_pricing_config()), '00000000-0000-0000-0000-00000000f6a1',
  25000, 0, 0, 0, 0, 25000, 3750, 750, 21250, 0, 25000,
  now() - interval '3 days', now() - interval '2 days');
select ok(private.purge_stale_quotes() >= 1, 'la purga borra cotizaciones vencidas');
select ok(not exists (select 1 from public.quotes where id = '00000000-0000-0000-0000-00000000e9f1')
      and exists (select 1 from public.quotes where id = pg_temp.id('q1')),
  'se purga la vencida sin usar y se conserva la usada');

-- Días libres -----------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000009b1');
set local role authenticated;
insert into t_ts values ('D', pg_temp.ts('T') + interval '2 days');
select lives_ok(
  $$ select public.add_time_off((pg_temp.ts('D') at time zone 'America/Santiago')::date,
                                (pg_temp.ts('D') at time zone 'America/Santiago')::date) $$,
  'el vet registra un día libre');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009a1');
set local role authenticated;
select is((select count(*)::int from public.available_vets('00000000-0000-0000-0000-00000000e9a1',
    '00000000-0000-0000-0000-00000000e9b1', pg_temp.spec(),
    (pg_temp.ts('D') at time zone 'America/Santiago')::date)), 0,
  'en su día libre el vet no aparece');
select throws_ok($$ select pg_temp.book(pg_temp.q(), pg_temp.ts('D')) $$,
  '22023', 'El horario ya no está disponible. Elige otro.', 'no se reserva en un día libre');
select throws_ok($$ select public.add_time_off((now() at time zone 'America/Santiago')::date + 3, (now() at time zone 'America/Santiago')::date + 3) $$,
  '42501', null, 'un dueño no registra días libres');

-- Punto de partida del vet ------------------------------------------------------
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009b1');
set local role authenticated;
select throws_ok(
  $$ update public.vet_bases set commune_id = (select id from public.communes where name = 'Arica')
     where vet_id = '00000000-0000-0000-0000-0000000009b1' $$,
  '22023', 'La ubicación marcada no está en la comuna elegida', 'el punto de partida debe estar en su comuna');
select lives_ok(
  $$ update public.vet_bases set lat = -33.3850
     where vet_id = '00000000-0000-0000-0000-0000000009b1' $$,
  'el vet actualiza su punto de partida');

-- Admin: solo agregados -----------------------------------------------------------
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009c1');
set local role authenticated;
select is((select count(*)::int from public.visits), 0, 'el admin no lee filas de visitas');
select ok((select total::int from public.admin_visit_summary() where mode = 'scheduled'
           and status = 'completed') >= 1, 'el admin ve el resumen agregado por estado');
select is((select count(*)::int from public.my_visits()), 0, 'el admin no obtiene detalle de visitas');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000009a1');
set local role authenticated;
select is((select count(*)::int from public.admin_visit_summary()), 0, 'un dueño no ve el resumen');
select is((select count(*)::int from public.my_visits()), 8, 'el dueño ve todas sus visitas');

reset role;
select * from finish();
rollback;
