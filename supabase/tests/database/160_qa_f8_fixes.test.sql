-- Correcciones del QA de la fase 8 (docs/qa/QA-37c4e3c.md).
--
-- QA-F8-02: 2 solicitudes y 1 vet. pgTAP corre en UNA sesión, así que la
-- carrera real (dos request_urgent_visit en paralelo) la cubre el viaje 7 de
-- tool/e2e/qa_urgencias_exploratorio_e2e.mjs. Aquí se verifica en secuencia
-- que el despacho no ofrece a un vet con otra oferta pendiente vigente (y que
-- la urgencia sigue buscando en vez de cerrar como no_vet_found), y que si la
-- carrera dejó 2 ofertas pendientes (se insertan a mano), el vet puede
-- aceptar una y la otra se cierra.
-- QA-F8-03: los montos de my_offers usan la distancia redondeada a 0,5 km;
-- la cotización final, la real.
-- QA-F8-04: my_visits entrega address_id solo al dueño.
begin;
select plan(27);

-- Fixtures ------------------------------------------------------------------
insert into auth.users (id, email)
select ('00000000-0000-0000-0000-' || k)::uuid, 'f8qa-' || k || '@test.local'
from unnest(array['000000016a01', '000000016a02', '000000016a09', '000000016b01',
  '000000016b02', '000000016b03']) k;
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-000000016a01', 'owner'),
  ('00000000-0000-0000-0000-000000016a02', 'owner'),
  ('00000000-0000-0000-0000-000000016a09', 'admin'),
  ('00000000-0000-0000-0000-000000016b01', 'vet'),
  ('00000000-0000-0000-0000-000000016b02', 'vet'),
  ('00000000-0000-0000-0000-000000016b03', 'vet');
insert into public.owner_profiles (user_id, display_name, phone, commune_id)
select ('00000000-0000-0000-0000-' || k)::uuid, 'Dueño ' || k, null,
       (select id from public.communes where name = 'Ñuñoa')
from unnest(array['000000016a01', '000000016a02']) k;
insert into public.vet_profiles (user_id, display_name, status)
select ('00000000-0000-0000-0000-000000016b0' || i)::uuid, 'Vet QA ' || i, 'approved'
from generate_series(1, 3) i;
insert into public.vet_species (vet_id, species_id)
select ('00000000-0000-0000-0000-000000016b0' || i)::uuid,
       (select id from public.species where slug = 'perro')
from generate_series(1, 3) i;
insert into public.vet_specialties (vet_id, specialty_id)
select ('00000000-0000-0000-0000-000000016b0' || i)::uuid,
       (select id from public.specialties where slug = 'general')
from generate_series(1, 3) i;

-- Aísla el test de los vets que ya existan en la BD.
set local session_replication_role = replica;
update public.vet_profiles set status = 'suspended'
  where status = 'approved' and user_id::text not like '00000000-0000-0000-0000-000000016b%';
set local session_replication_role = origin;

update public.foundations set is_default = false where is_default;
insert into public.foundations (id, name, is_default) values
  ('00000000-0000-0000-0000-000000016f01', 'F8 QA Fundación', true);
insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee, effective_from)
values (15, 20, 30, 500, 5, 5000, now() - interval '2 seconds');

insert into public.pets (id, owner_id, name, species_id) values
  ('00000000-0000-0000-0000-000000016e01', '00000000-0000-0000-0000-000000016a01', 'Uno',
   (select id from public.species where slug = 'perro')),
  ('00000000-0000-0000-0000-000000016e02', '00000000-0000-0000-0000-000000016a02', 'Dos',
   (select id from public.species where slug = 'perro'));
insert into public.addresses (id, owner_id, label, street_text, commune_id, lat, lng) values
  ('00000000-0000-0000-0000-000000016d01', '00000000-0000-0000-0000-000000016a01', 'Casa',
   'Pasaje Ficticio 456', (select id from public.communes where name = 'Ñuñoa'),
   -33.4569, -70.5974),
  ('00000000-0000-0000-0000-000000016d02', '00000000-0000-0000-0000-000000016a02', 'Casa',
   'Pasaje Ficticio 789', (select id from public.communes where name = 'Ñuñoa'),
   -33.4569, -70.5974);

create function pg_temp.vid(i integer) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-000000016b0' || i)::uuid;
$$;
-- b01 a 1 km; b02 y b03 (fuera de línea al comienzo) a ~5,88 y ~6,10 km:
-- ambas ofertas muestran 6 km, pero el recargo real es de 1 y 2 km.
insert into public.vet_presence (vet_id, online, location, updated_at)
select pg_temp.vid(i), i = 1,
       extensions.st_setsrid(extensions.st_makepoint(-70.5974, -33.4569 + dlat), 4326)
         ::extensions.geography,
       now()
from (values (1, 0.009), (2, 0.053), (3, 0.055)) x (i, dlat);

create temp table t_ids (k text primary key, v uuid);
grant all on t_ids to authenticated;
create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.id(p_k text) returns uuid language sql as $$
  select v from t_ids where k = p_k;
$$;
create function pg_temp.req(p_owner text) returns jsonb language sql as $$
  select public.request_urgent_visit(('00000000-0000-0000-0000-000000016e0' || p_owner)::uuid,
    ('00000000-0000-0000-0000-000000016d0' || p_owner)::uuid);
$$;
create function pg_temp.offer(p_v uuid, p_vet uuid) returns uuid language sql as $$
  select id from public.visit_offers where visit_id = p_v and vet_id = p_vet;
$$;
create function pg_temp.pending(p_vet uuid) returns bigint language sql as $$
  select count(*) from public.visit_offers
  where vet_id = p_vet and status = 'pending' and expires_at > now();
$$;
grant execute on function pg_temp.vid(integer), pg_temp.id(text), pg_temp.req(text),
  pg_temp.offer(uuid, uuid) to authenticated;

-- Privilegios de los objetos nuevos ---------------------------------------------
select ok(not has_function_privilege('authenticated',
            'private.vet_busy_for_urgent(uuid, uuid, boolean)', 'execute')
          and not has_function_privilege('anon',
            'private.vet_busy_for_urgent(uuid, uuid, boolean)', 'execute')
          and not has_function_privilege('authenticated',
            'private.vet_offer_lock_key(uuid)', 'execute'),
  'helpers nuevos sin EXECUTE para anon/authenticated');
select ok((select prosecdef and proconfig @> array['search_path=""']
           from pg_proc where oid = 'private.vet_busy_for_urgent(uuid, uuid, boolean)'::regprocedure),
  'vet_busy_for_urgent/3: security definer con search_path vacío');

-- QA-F8-02: 2 solicitudes y 1 vet ------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-000000016a01');
set local role authenticated;
insert into t_ids select 'V1', (pg_temp.req('1') ->> 'id')::uuid;
reset role;
select ok(pg_temp.offer(pg_temp.id('V1'), pg_temp.vid(1)) is not null,
  'la 1.ª urgencia le ofrece al único vet');

select pg_temp.login('00000000-0000-0000-0000-000000016a02');
set local role authenticated;
insert into t_ids select 'V2', (pg_temp.req('2') ->> 'id')::uuid;
reset role;
select is(pg_temp.pending(pg_temp.vid(1)), 1::bigint,
  'la 2.ª urgencia no le ofrece al vet que ya tiene una oferta pendiente');
select is((select status from public.visits where id = pg_temp.id('V2')), 'searching',
  'la 2.ª urgencia sigue buscando (no cierra como no_vet_found)');

-- Vence la oferta de V1: el cron cierra V1 (ya le ofreció a todos) y V2 le ofrece.
update public.visit_offers set expires_at = now() - interval '1 second'
where visit_id = pg_temp.id('V1') and status = 'pending';
select ok(private.dispatch_urgent_visits() >= 1, 'el cron despacha');
select is((select status from public.visits where id = pg_temp.id('V1')), 'no_vet_found',
  'V1 agotó a sus vets: no_vet_found');
select ok(pg_temp.offer(pg_temp.id('V2'), pg_temp.vid(1)) is not null,
  'con el vet libre, V2 recibe su oferta');

-- Otra urgencia (V3) mientras el vet tiene la oferta de V2: espera.
select pg_temp.login('00000000-0000-0000-0000-000000016a01');
set local role authenticated;
insert into t_ids select 'V3', (pg_temp.req('1') ->> 'id')::uuid;
reset role;
select ok(pg_temp.offer(pg_temp.id('V3'), pg_temp.vid(1)) is null
          and (select status from public.visits where id = pg_temp.id('V3')) = 'searching',
  'V3 no le ofrece al vet ocupado con la oferta de V2 y sigue buscando');

-- Lo que dejaba la carrera: 2 ofertas pendientes al mismo vet.
insert into public.visit_offers (visit_id, vet_id, batch, radius_km, distance_m, expires_at)
values (pg_temp.id('V3'), pg_temp.vid(1), 1, 5, 1000, now() + interval '60 seconds');
select is(pg_temp.pending(pg_temp.vid(1)), 2::bigint, 'carrera simulada: 2 ofertas pendientes');

select pg_temp.login(pg_temp.vid(1));
set local role authenticated;
select lives_ok(format('select public.accept_offer(%L)',
                       pg_temp.offer(pg_temp.id('V3'), pg_temp.vid(1))),
  'con 2 ofertas pendientes el vet puede aceptar una (antes: "choca")');
reset role;
select is((select status || ':' || vet_id::text from public.visits where id = pg_temp.id('V3')),
          'accepted:' || pg_temp.vid(1)::text, 'V3 queda asignada al vet');
select is((select status from public.visit_offers
           where id = pg_temp.offer(pg_temp.id('V2'), pg_temp.vid(1))), 'cancelled',
  'la otra oferta pendiente del vet (V2) se cierra al aceptar');
select is(pg_temp.pending(pg_temp.vid(1)), 0::bigint, 'el vet no queda con ofertas colgadas');
select is((select status from public.visits where id = pg_temp.id('V2')), 'no_vet_found',
  'V2 se despacha de inmediato: sin otros vets libres, no_vet_found');

-- QA-F8-03: montos de la oferta con la distancia redondeada --------------------
update public.vet_presence set online = true, updated_at = now()
where vet_id in (pg_temp.vid(2), pg_temp.vid(3));
select pg_temp.login('00000000-0000-0000-0000-000000016a02');
set local role authenticated;
insert into t_ids select 'V4', (pg_temp.req('2') ->> 'id')::uuid;
reset role;
select ok(pg_temp.offer(pg_temp.id('V4'), pg_temp.vid(2)) is not null
          and pg_temp.offer(pg_temp.id('V4'), pg_temp.vid(3)) is not null,
  'V4 les ofrece a los 2 vets a ~6 km');
select ok((select bool_and(distance_m between 5750 and 6249) and count(distinct distance_m) = 2
           from public.visit_offers where visit_id = pg_temp.id('V4')),
  'distancias reales distintas, ambas redondean a 6 km');
select ok((select (ceil((max(distance_m) - 5000) / 1000.0) <> ceil((min(distance_m) - 5000) / 1000.0))
           from public.visit_offers where visit_id = pg_temp.id('V4')),
  'con la distancia exacta, los km facturables serían distintos (1 y 2)');

create temp table t_offer (vet integer, j jsonb);
grant all on t_offer to authenticated;
select pg_temp.login(pg_temp.vid(2));
set local role authenticated;
insert into t_offer select 2, j from public.my_offers() j;
reset role;
select pg_temp.login(pg_temp.vid(3));
set local role authenticated;
insert into t_offer select 3, j from public.my_offers() j;
reset role;
select is((select count(distinct (j ->> 'distance_km')::numeric) || ':' || min((j ->> 'distance_km')::numeric)::float8
           from t_offer), '1:6', 'ambas ofertas muestran 6 km');
select is((select count(distinct j ->> 'vet_payout') from t_offer), 1::bigint,
  'el pago estimado no revela más precisión que 0,5 km');
select is((select count(distinct j ->> 'service_price') from t_offer), 1::bigint,
  'el precio del servicio tampoco');
select is((select (j ->> 'vet_payout')::integer from t_offer where vet = 3),
          (select pr.vet_payout from public.visits v
           join public.quotes q on q.id = v.quote_id
           cross join lateral private.urgent_price(q, 6000) pr
           where v.id = pg_temp.id('V4')),
  'el pago estimado es el de la distancia mostrada (6 km)');

-- Al aceptar, la cotización final usa la distancia real.
select pg_temp.login(pg_temp.vid(3));
set local role authenticated;
select lives_ok(format('select public.accept_offer(%L)',
                       pg_temp.offer(pg_temp.id('V4'), pg_temp.vid(3))),
  'b03 acepta V4');
reset role;
select ok((select q.distance_m = o.distance_m and q.billable_km = 2
           from public.visits v
           join public.quotes q on q.id = v.quote_id
           join public.visit_offers o on o.visit_id = v.id and o.vet_id = v.vet_id
           where v.id = pg_temp.id('V4')),
  'la cotización final usa la distancia real (2 km facturables)');

-- QA-F8-04: address_id solo para el dueño ---------------------------------------
select pg_temp.login('00000000-0000-0000-0000-000000016a02');
set local role authenticated;
select is((select j ->> 'address_id' from public.my_visits() j
           where (j ->> 'id')::uuid = pg_temp.id('V4')),
          '00000000-0000-0000-0000-000000016d02', 'el dueño recibe address_id');
reset role;
select pg_temp.login(pg_temp.vid(3));
set local role authenticated;
select ok((select count(*) = 1 and bool_and(not (j ? 'address_id')) from public.my_visits() j
           where (j ->> 'id')::uuid = pg_temp.id('V4')),
  'el vet asignado no recibe address_id');
reset role;
select pg_temp.login('00000000-0000-0000-0000-000000016a09');
set local role authenticated;
select is((select count(*) from public.my_visits() j where j ? 'address_id'), 0::bigint,
  'el admin no recibe address_id');
reset role;

select * from finish();
rollback;
