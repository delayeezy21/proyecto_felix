-- Correcciones de QA fase 6 (QA-F6-01 a 05 y horario inmutable).
begin;
select plan(29);

-- Fixtures ------------------------------------------------------------------
-- Dueño A, vet V (con base), vet S (aprobado, SIN base), admin y 25 vets más
-- cercanos o lejanos para la preselección.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000a6a1', 'f6q-dueno@test.local'),
  ('00000000-0000-0000-0000-00000000a6b1', 'f6q-vet@test.local'),
  ('00000000-0000-0000-0000-00000000a6b2', 'f6q-vet-sin-base@test.local'),
  ('00000000-0000-0000-0000-00000000a6c1', 'f6q-admin@test.local');
insert into auth.users (id, email)
  select ('00000000-0000-0000-0000-0000a6d' || lpad(g::text, 5, '0'))::uuid,
         'f6q-extra-' || g || '@test.local'
  from generate_series(1, 25) g;
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-00000000a6a1', 'owner'),
  ('00000000-0000-0000-0000-00000000a6b1', 'vet'),
  ('00000000-0000-0000-0000-00000000a6b2', 'vet'),
  ('00000000-0000-0000-0000-00000000a6c1', 'admin');
insert into public.user_roles (user_id, role)
  select ('00000000-0000-0000-0000-0000a6d' || lpad(g::text, 5, '0'))::uuid, 'vet'
  from generate_series(1, 25) g;
insert into public.owner_profiles (user_id, display_name, commune_id) values
  ('00000000-0000-0000-0000-00000000a6a1', 'Ana Q6', (select id from public.communes where name = 'Ñuñoa'));
insert into public.vet_profiles (user_id, display_name, status) values
  ('00000000-0000-0000-0000-00000000a6b1', 'Dra. Q6', 'approved'),
  ('00000000-0000-0000-0000-00000000a6b2', 'Dr. Sin Base', 'approved');
insert into public.vet_profiles (user_id, display_name, status)
  select ('00000000-0000-0000-0000-0000a6d' || lpad(g::text, 5, '0'))::uuid,
         'Extra ' || lpad(g::text, 2, '0'), 'approved'
  from generate_series(1, 25) g;
insert into public.vet_species (vet_id, species_id)
  select user_id, (select id from public.species where slug = 'perro')
  from public.vet_profiles where display_name in ('Dra. Q6', 'Dr. Sin Base') or display_name like 'Extra %';
insert into public.vet_specialties (vet_id, specialty_id)
  select vet_id, (select id from public.specialties where slug = 'general')
  from public.vet_species where vet_id in (select user_id from public.vet_profiles
    where display_name in ('Dra. Q6', 'Dr. Sin Base') or display_name like 'Extra %');
insert into public.vet_availability (vet_id, weekday, start_min, end_min)
  select s.vet_id, d, 0, 1440 from public.vet_species s, generate_series(1, 7) d
  where s.vet_id in (select user_id from public.vet_profiles
    where display_name in ('Dra. Q6', 'Dr. Sin Base') or display_name like 'Extra %');
insert into public.vet_bases (vet_id, commune_id, lat, lng) values
  ('00000000-0000-0000-0000-00000000a6b1',
   (select commune_id from public.communes_at_point(-33.3849, -70.5974) limit 1), -33.3849, -70.5974);
-- Extras: todos en la misma base que la dirección (más cercanos que V).
insert into public.vet_bases (vet_id, commune_id, lat, lng)
  select ('00000000-0000-0000-0000-0000a6d' || lpad(g::text, 5, '0'))::uuid,
         (select id from public.communes where name = 'Ñuñoa'), -33.4569, -70.5974
  from generate_series(1, 25) g;
update public.vet_bases set fuzz_dlat = 0, fuzz_dlng = 0
  where vet_id = '00000000-0000-0000-0000-00000000a6b1'
     or vet_id::text like '00000000-0000-0000-0000-0000a6d%';

update public.foundations set is_default = false where is_default;
insert into public.foundations (id, name, is_default) values
  ('00000000-0000-0000-0000-00000000f6b1', 'F6Q Fundación', true);
insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee, effective_from)
values (15, 20, 30, 500, 5, 5000, now() - interval '2 seconds');
insert into public.pets (id, owner_id, name, species_id) values
  ('00000000-0000-0000-0000-00000000e6a1', '00000000-0000-0000-0000-00000000a6a1', 'Rex',
   (select id from public.species where slug = 'perro'));
insert into public.addresses (id, owner_id, label, street_text, commune_id, lat, lng) values
  ('00000000-0000-0000-0000-00000000e6b1', '00000000-0000-0000-0000-00000000a6a1', 'Casa',
   'Av. Ficticia 456', (select id from public.communes where name = 'Ñuñoa'), -33.4569, -70.5974);

create temp table t_ids (k text primary key, v uuid);
grant all on t_ids to authenticated;
create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.id(p_k text) returns uuid language sql as $$
  select v from t_ids where k = p_k;
$$;
create function pg_temp.spec() returns integer language sql security definer as $$
  select id from public.specialties where slug = 'general';
$$;
create function pg_temp.q(p_vet uuid) returns uuid language sql as $$
  select (public.quote_visit('00000000-0000-0000-0000-00000000e6a1',
    '00000000-0000-0000-0000-00000000e6b1', pg_temp.spec(), 'scheduled', p_vet) ->> 'quote_id')::uuid;
$$;
create function pg_temp.book(p_q uuid, p_vet uuid, p_at timestamptz) returns uuid language sql as $$
  select (public.book_visit(p_q, p_vet, '00000000-0000-0000-0000-00000000e6a1',
    '00000000-0000-0000-0000-00000000e6b1', p_at) ->> 'id')::uuid;
$$;
create function pg_temp.tr(p_v uuid, p_to text) returns jsonb language sql as $$
  select public.transition_visit(p_v, p_to);
$$;
create function pg_temp.fee(p_v uuid) returns integer language sql as $$
  select (j ->> 'cancel_fee_now')::int from public.my_visits(200) j where j ->> 'id' = p_v::text;
$$;
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
grant execute on function pg_temp.login(uuid), pg_temp.id(text), pg_temp.spec(), pg_temp.q(uuid),
  pg_temp.book(uuid, uuid, timestamptz), pg_temp.tr(uuid, text), pg_temp.fee(uuid)
  to authenticated;

-- Reserva y avance de una visita del vet V a la hora p_at.
create function pg_temp.accepted_visit(p_k text, p_at timestamptz) returns void language plpgsql as $$
begin
  perform pg_temp.login('00000000-0000-0000-0000-00000000a6a1');
  set local role authenticated;
  insert into t_ids values (p_k, pg_temp.book(pg_temp.q('00000000-0000-0000-0000-00000000a6b1'),
    '00000000-0000-0000-0000-00000000a6b1', p_at));
  perform pg_temp.login('00000000-0000-0000-0000-00000000a6b1');
  perform pg_temp.tr(pg_temp.id(p_k), 'accepted');
  reset role;
end;
$$;

-- QA-F6-01: vet sin punto de partida ------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000a6a1');
set local role authenticated;
select throws_ok($$ select pg_temp.q('00000000-0000-0000-0000-00000000a6b2') $$,
  '22023', 'El veterinario no tiene punto de partida',
  'QA-F6-01: no se cotiza con un vet sin punto de partida');
reset role;
-- Cotización con vet pero sin distancia (como la que dejaba la versión anterior).
insert into public.quotes (id, owner_id, pet_id, address_id, vet_id, species_id, specialty_id,
  commune_id, mode, pricing_config_id, foundation_id, base_price, urgent_surcharge,
  billable_km, distance_surcharge, discount, service_price, platform_fee, foundation_share,
  vet_payout, extra_donation, total, expires_at)
values ('00000000-0000-0000-0000-00000000e6f1', '00000000-0000-0000-0000-00000000a6a1',
  '00000000-0000-0000-0000-00000000e6a1', '00000000-0000-0000-0000-00000000e6b1',
  '00000000-0000-0000-0000-00000000a6b2', (select id from public.species where slug = 'perro'),
  pg_temp.spec(), (select id from public.communes where name = 'Ñuñoa'), 'scheduled',
  (select id from public.current_pricing_config()), '00000000-0000-0000-0000-00000000f6b1',
  26990, 0, 0, 0, 0, 26990, 4049, 810, 22941, 0, 26990, now() + interval '20 minutes');
select pg_temp.login('00000000-0000-0000-0000-00000000a6a1');
set local role authenticated;
select throws_ok(
  $$ select pg_temp.book('00000000-0000-0000-0000-00000000e6f1',
       '00000000-0000-0000-0000-00000000a6b2', date_trunc('hour', now()) + interval '1 day') $$,
  '22023', 'El veterinario no tiene punto de partida',
  'QA-F6-01: no se reserva una cotización sin distancia (vet sin base)');
select ok((select consumed_at is null from public.quotes where id = '00000000-0000-0000-0000-00000000e6f1'),
  'el rechazo no consume la cotización');
select ok(pg_temp.q('00000000-0000-0000-0000-00000000a6b1') is not null,
  'con punto de partida sí se cotiza');

-- QA-F6-05: preselección y tope -------------------------------------------------
create temp table t_av as
  select j from public.available_vets('00000000-0000-0000-0000-00000000e6a1',
    '00000000-0000-0000-0000-00000000e6b1', pg_temp.spec(),
    ((now() + interval '1 day') at time zone 'America/Santiago')::date) j;
select is((select count(*)::int from t_av), 20, 'devuelve como máximo 20 vets');
select ok(not exists (select 1 from t_av where j ->> 'display_name' in ('Dr. Sin Base', 'Dra. Q6')),
  'prioriza los más cercanos (V queda fuera) y nunca un vet sin base');
select is((select min((j ->> 'distance_km')::int) from t_av), 0, 'los más cercanos primero');
reset role;
select ok(exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private' and p.proname = 'find_available_vets'
      and pg_get_functiondef(p.oid) like '%operator(extensions.<->)%limit 30%'),
  'preselección KNN de 30 candidatos antes de calcular horarios');
update private.search_quota set calls = 30, window_start = now()
  where user_id = '00000000-0000-0000-0000-00000000a6a1';
select pg_temp.login('00000000-0000-0000-0000-00000000a6a1');
set local role authenticated;
select throws_ok(
  $$ select public.available_vets('00000000-0000-0000-0000-00000000e6a1',
       '00000000-0000-0000-0000-00000000e6b1', pg_temp.spec(), current_date + 1) $$,
  '22023', 'Demasiadas búsquedas. Espera un minuto.', 'tope de 30 búsquedas por dueño y minuto');
reset role;
update private.search_quota set window_start = now() - interval '61 seconds'
  where user_id = '00000000-0000-0000-0000-00000000a6a1';
select pg_temp.login('00000000-0000-0000-0000-00000000a6a1');
set local role authenticated;
select lives_ok(
  $$ select public.available_vets('00000000-0000-0000-0000-00000000e6a1',
       '00000000-0000-0000-0000-00000000e6b1', pg_temp.spec(), current_date + 1) $$,
  'pasado el minuto se puede volver a buscar');
select ok(not has_table_privilege('authenticated', 'private.search_quota', 'select'),
  'la app no lee ni escribe el contador');
reset role;

-- QA-F6-04: horario de llegar, iniciar y completar ------------------------------
select pg_temp.accepted_visit('a', date_trunc('hour', now()) + interval '1 day');
select pg_temp.shift(pg_temp.id('a'), date_trunc('minute', now()) + interval '100 minutes');
select pg_temp.login('00000000-0000-0000-0000-00000000a6b1');
set local role authenticated;
select is((pg_temp.tr(pg_temp.id('a'), 'en_route') ->> 'status'), 'en_route', 'en camino a 100 min');
select throws_ok($$ select pg_temp.tr(pg_temp.id('a'), 'arrived') $$,
  '22023', 'Puedes marcar la llegada y el inicio desde 30 minutos antes de la visita',
  'QA-F6-04: no marca "llegó" con más de 30 min de anticipación');
reset role;
select pg_temp.shift(pg_temp.id('a'), date_trunc('minute', now()) + interval '20 minutes');
select pg_temp.login('00000000-0000-0000-0000-00000000a6b1');
set local role authenticated;
select is((pg_temp.tr(pg_temp.id('a'), 'arrived') ->> 'status'), 'arrived', 'llegó a 20 min');
select is((pg_temp.tr(pg_temp.id('a'), 'in_progress') ->> 'status'), 'in_progress', 'inicia');
select throws_ok($$ select pg_temp.tr(pg_temp.id('a'), 'completed') $$,
  '22023', 'La atención debe durar al menos 10 minutos antes de completarla',
  'QA-F6-04: duración mínima de 10 min');
reset role;
select ok((select started_at = now() from public.visits where id = pg_temp.id('a')),
  'visits.started_at registra el inicio');
-- Se completa para liberar el horario del vet.
select pg_temp.tt(format('update public.visits set started_at = now() - interval ''15 minutes'' where id = %L',
  pg_temp.id('a')));
select pg_temp.login('00000000-0000-0000-0000-00000000a6b1');
set local role authenticated;
select pg_temp.tr(pg_temp.id('a'), 'completed');
reset role;

-- QA-F6-03: "en camino" que nunca llega -------------------------------------------
select pg_temp.accepted_visit('b', date_trunc('hour', now()) + interval '1 day' + interval '3 hours');
select pg_temp.shift(pg_temp.id('b'), date_trunc('minute', now()) + interval '1 hour');
select pg_temp.login('00000000-0000-0000-0000-00000000a6b1');
set local role authenticated;
select pg_temp.tr(pg_temp.id('b'), 'en_route');
reset role;
select pg_temp.login('00000000-0000-0000-0000-00000000a6a1');
set local role authenticated;
select is(pg_temp.fee(pg_temp.id('b')), 5000, 'en camino antes de la hora: cancelar cobra $5.000');
reset role;
select pg_temp.shift(pg_temp.id('b'), date_trunc('minute', now()) - interval '31 minutes');
select pg_temp.login('00000000-0000-0000-0000-00000000a6a1');
set local role authenticated;
select is(pg_temp.fee(pg_temp.id('b')), 0, 'QA-F6-03: 30 min después de la hora, cancelar es gratis');
select is((pg_temp.tr(pg_temp.id('b'), 'cancelled_owner') ->> 'cancel_fee')::int, 0,
  'el dueño cancela sin cargo un vet atrasado');
reset role;
select is((select count(*)::int from public.payments where visit_id = pg_temp.id('b')), 0,
  'sin cargo no hay pago');

-- Cierre automático de en_route y arrived vencidos.
select pg_temp.accepted_visit('c', date_trunc('hour', now()) + interval '1 day' + interval '6 hours');
select pg_temp.shift(pg_temp.id('c'), date_trunc('minute', now()) + interval '10 minutes');
select pg_temp.accepted_visit('d', date_trunc('hour', now()) + interval '1 day' + interval '9 hours');
select pg_temp.shift(pg_temp.id('d'), date_trunc('minute', now()) + interval '105 minutes');
select pg_temp.login('00000000-0000-0000-0000-00000000a6b1');
set local role authenticated;
select pg_temp.tr(pg_temp.id('c'), 'en_route');
select pg_temp.tr(pg_temp.id('c'), 'arrived');
select pg_temp.tr(pg_temp.id('d'), 'en_route');
reset role;
select pg_temp.shift(pg_temp.id('c'), date_trunc('minute', now()) - interval '121 minutes');
select private.expire_visits();
select is((select concat_ws(',', status, cancel_fee) from public.visits where id = pg_temp.id('c')),
  'cancelled_vet,0', 'QA-F6-03: "llegó" sin iniciar 2 h después se cierra sin cargo');
select pg_temp.shift(pg_temp.id('d'), date_trunc('minute', now()) - interval '119 minutes');
select private.expire_visits();
select is((select status from public.visits where id = pg_temp.id('d')), 'en_route',
  'antes de las 2 h no se cierra');
select pg_temp.shift(pg_temp.id('d'), date_trunc('minute', now()) - interval '3 hours');
select private.expire_visits();
select is((select concat_ws(',', status, cancel_fee) from public.visits where id = pg_temp.id('d')),
  'cancelled_vet,0', 'QA-F6-03: "en camino" que nunca llega se cierra sin cargo');
select ok(private.visit_edge_allowed('arrived', 'cancelled_vet')
      and not private.visit_edge_allowed('arrived', 'cancelled_owner'),
  'el vet puede cerrar una visita a la que llegó; el dueño no la cancela');

-- QA-F6-02: el admin solo ve agregados --------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000a6c1');
set local role authenticated;
select throws_ok($$ select count(*) from public.visit_events $$,
  '42501', null, 'QA-F6-02: el admin no lee visit_events fila a fila');
select ok((select count(*) from public.admin_visit_summary()) >= 1, 'el admin sigue viendo el agregado');
reset role;

-- Riesgo: horario inmutable --------------------------------------------------------
select throws_ok(
  $$ update public.visits set scheduled_at = scheduled_at + interval '1 day',
       slot = tstzrange(lower(slot) + interval '1 day', upper(slot) + interval '1 day')
     where id = pg_temp.id('a') $$,
  '42501', 'El horario de una visita no se modifica', 'sin la marca, ni postgres mueve el horario');
select throws_ok(
  $$ update public.visits set started_at = null where id = pg_temp.id('a') $$,
  '42501', 'El estado de una visita solo cambia con transition_visit', 'started_at no se toca a mano');

select * from finish();
rollback;
