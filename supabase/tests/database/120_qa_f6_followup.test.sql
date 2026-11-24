-- Seguimiento de QA fase 6: QA-F6-07 (candidatos sin días libres ni agendas
-- llenas) y QA-F6-06 (visita "en curso" que nunca se completa).
begin;
select plan(13);

-- Fixtures (carga masiva sin triggers ni FK; luego se vuelve a `origin`) ----
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000a7a1', 'f6b-dueno@test.local'),
  ('00000000-0000-0000-0000-00000000a7f1', 'f6b-vet-libre@test.local');
set local session_replication_role = replica;
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-00000000a7a1', 'owner'),
  ('00000000-0000-0000-0000-00000000a7f1', 'vet');
insert into public.owner_profiles (user_id, display_name, phone, commune_id) values
  ('00000000-0000-0000-0000-00000000a7a1', 'Ana F6b', '+56 9 7777 7777',
   (select id from public.communes where name = 'Ñuñoa'));
insert into public.pets (id, owner_id, name, species_id) values
  ('00000000-0000-0000-0000-00000000e7a1', '00000000-0000-0000-0000-00000000a7a1', 'Toby',
   (select id from public.species where slug = 'perro'));
insert into public.addresses (id, owner_id, label, street_text, commune_id, lat, lng) values
  ('00000000-0000-0000-0000-00000000e7b1', '00000000-0000-0000-0000-00000000a7a1', 'Casa',
   'Av. Ficticia 789', (select id from public.communes where name = 'Ñuñoa'), -33.4569, -70.5974);

-- 30 vets cercanos con día libre (g 1–30), 25 cercanos con la agenda llena
-- (g 31–55) y 1 vet libre a ~15 km.
create temp table t_vets as
  select ('00000000-0000-0000-0000-0000a7' || lpad(g::text, 6, '0'))::uuid as id, g
  from generate_series(1, 55) g
  union all select '00000000-0000-0000-0000-00000000a7f1'::uuid, 0;
insert into public.vet_profiles (user_id, display_name, status)
  select id, case when g = 0 then 'Dra. Libre' else 'Vet cercano ' || g end, 'approved' from t_vets;
insert into public.vet_species (vet_id, species_id)
  select id, (select id from public.species where slug = 'perro') from t_vets;
insert into public.vet_specialties (vet_id, specialty_id)
  select id, (select id from public.specialties where slug = 'general') from t_vets;
-- Día libre: todo el día. Agenda llena: un solo horario (9:00–10:00) ya tomado.
insert into public.vet_availability (vet_id, weekday, start_min, end_min)
  select id, d, case when g between 31 and 55 then 540 else 0 end,
         case when g between 31 and 55 then 600 else 1440 end
  from t_vets, generate_series(1, 7) d;
insert into public.vet_bases (vet_id, commune_id, lat, lng)
  select id, (select id from public.communes where name = 'Ñuñoa'),
         case when g = 0 then -33.32 else -33.4569 + 0.0005 * g end, -70.5974
  from t_vets;
insert into public.vet_time_off (vet_id, period)
  select id, tstzrange(now(), now() + interval '3 days') from t_vets where g between 1 and 30;
insert into public.visits (owner_id, vet_id, mode, status, commune_id, species_id, specialty_id,
  foundation_id, scheduled_at, slot, confirm_deadline, quote)
  -- Sin dueño (como una visita anonimizada): no ocupa el tope de visitas abiertas.
  select null::uuid, id, 'scheduled', 'pending_vet',
         (select id from public.communes where name = 'Ñuñoa'),
         (select id from public.species where slug = 'perro'),
         (select id from public.specialties where slug = 'general'),
         (select id from public.foundations order by is_default desc limit 1),
         (((now() at time zone 'America/Santiago')::date + 1)::timestamp + interval '9 hours')
           at time zone 'America/Santiago',
         tstzrange((((now() at time zone 'America/Santiago')::date + 1)::timestamp + interval '9 hours')
                     at time zone 'America/Santiago',
                   (((now() at time zone 'America/Santiago')::date + 1)::timestamp + interval '630 minutes')
                     at time zone 'America/Santiago'),
         now() + interval '1 hour', '{}'
  from t_vets where g between 31 and 55;
-- O-F7-c: aísla el test de los vets que ya existan en la BD (solo en esta
-- transacción, que termina en rollback).
update public.vet_profiles set status = 'suspended'
  where status = 'approved' and user_id not in (select id from t_vets);
set local session_replication_role = origin;

insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee, effective_from)
values (15, 20, 30, 500, 5, 5000, now() - interval '2 seconds');

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
create function pg_temp.tt(p_sql text) returns void language plpgsql as $$
begin
  perform set_config('felix.time_travel', 'on', true);
  execute p_sql;
  perform set_config('felix.time_travel', 'off', true);
end;
$$;
create function pg_temp.vet_view(p_v uuid) returns jsonb language sql as $$
  select j from public.my_visits(200) j where j ->> 'id' = p_v::text;
$$;
grant execute on function pg_temp.id(text), pg_temp.spec(), pg_temp.vet_view(uuid) to authenticated;

-- QA-F6-07 ------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000a7a1');
set local role authenticated;
create temp table t_av as
  select j from public.available_vets('00000000-0000-0000-0000-00000000e7a1',
    '00000000-0000-0000-0000-00000000e7b1', pg_temp.spec(),
    (now() at time zone 'America/Santiago')::date + 1) j;
select is((select count(*)::int from t_av), 1,
  'QA-F6-07: con 30 vets cercanos de día libre y 25 con la agenda llena, aparece el vet libre');
select is((select j ->> 'display_name' from t_av), 'Dra. Libre', 'el vet ofrecido es el libre a ~15 km');
select ok((select (j ->> 'distance_km')::int between 13 and 17 from t_av), 'a unos 15 km');
reset role;
select ok(exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private' and p.proname = 'find_available_vets'
      and pg_get_functiondef(p.oid) like '%t.period @> v_day%'
      and pg_get_functiondef(p.oid) like '%v_found < 20%'),
  'los días libres completos se excluyen de los candidatos y se recorre hasta reunir 20');
-- Pasado mañana los 30 con día libre siguen libres (rango de 3 días) y los 25
-- con agenda llena tienen su horario disponible: aparecen hasta 20, los más cercanos.
select pg_temp.login('00000000-0000-0000-0000-00000000a7a1');
set local role authenticated;
select is((select count(*)::int from public.available_vets('00000000-0000-0000-0000-00000000e7a1',
    '00000000-0000-0000-0000-00000000e7b1', pg_temp.spec(),
    (now() at time zone 'America/Santiago')::date + 2)), 20,
  'con vets libres de sobra se devuelven 20');
reset role;

-- QA-F6-06 ------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000a7a1');
set local role authenticated;
insert into t_ids select 'v', (public.book_visit(
  (public.quote_visit('00000000-0000-0000-0000-00000000e7a1', '00000000-0000-0000-0000-00000000e7b1',
    pg_temp.spec(), 'scheduled', '00000000-0000-0000-0000-00000000a7f1') ->> 'quote_id')::uuid,
  '00000000-0000-0000-0000-00000000a7f1', '00000000-0000-0000-0000-00000000e7a1',
  '00000000-0000-0000-0000-00000000e7b1', date_trunc('hour', now()) + interval '1 day' + interval '2 hours')
  ->> 'id')::uuid;
reset role;
select pg_temp.tt(format('update public.visits set scheduled_at = date_trunc(''minute'', now()) + interval ''20 minutes'',
  slot = tstzrange(date_trunc(''minute'', now()) + interval ''20 minutes'', date_trunc(''minute'', now()) + interval ''110 minutes'')
  where id = %L', pg_temp.id('v')));
select pg_temp.login('00000000-0000-0000-0000-00000000a7f1');
set local role authenticated;
select public.transition_visit(pg_temp.id('v'), s)
  from unnest(array['accepted', 'en_route', 'arrived', 'in_progress']) s;
select is((pg_temp.vet_view(pg_temp.id('v')) -> 'exact' ->> 'owner_phone'), '+56 9 7777 7777',
  'en curso y dentro de la ventana, el vet ve el contacto');
reset role;
-- Empezó hace 7 h (más de 6 h) y nadie la completó.
select pg_temp.tt(format('update public.visits set started_at = now() - interval ''7 hours'' where id = %L',
  pg_temp.id('v')));
select pg_temp.login('00000000-0000-0000-0000-00000000a7f1');
set local role authenticated;
select is((pg_temp.vet_view(pg_temp.id('v')) ->> 'status'), 'in_progress', 'el cron aún no la cierra');
select is((pg_temp.vet_view(pg_temp.id('v')) -> 'exact'), 'null'::jsonb,
  'QA-F6-06: vencida la ventana, el vet ya no ve dirección ni teléfono aunque siga abierta');
reset role;
select ok(private.expire_visits() >= 1, 'el cron procesa la visita');
select is((select status from public.visits where id = pg_temp.id('v')), 'completed',
  'QA-F6-06: "en curso" de más de 6 h se cierra como completada');
select is((select actor_id from public.visit_events where visit_id = pg_temp.id('v')
           and to_status = 'completed'), null::uuid, 'el cierre lo registra el sistema (sin actor)');
select is((select count(*)::int from public.payments where visit_id = pg_temp.id('v')), 0,
  'sin cobro automático: el dueño paga desde la app');
-- Regla alternativa: 8 h desde la hora agendada (aunque el inicio sea reciente).
select is(
  (select private.visit_active_until(jsonb_populate_record(v, jsonb_build_object(
     'status', 'in_progress', 'started_at', now(), 'scheduled_at', now() - interval '9 hours')))
   from public.visits v where v.id = pg_temp.id('v')),
  now() - interval '1 hour',
  'la ventana de "en curso" también vence 8 h después de la hora agendada');

select * from finish();
rollback;
