-- Fase 8: urgencias. Presencia, despacho por tandas (radio 5 → 10 → 20 km,
-- 3 vets × 60 s, sin repetir), no_vet_found a los 10 min o agotado el radio
-- (sin cobro), aceptación atómica ("ya tomada"), privacidad de la oferta,
-- RLS de vet_presence / visit_offers / realtime.messages, cancelación con y
-- sin cargo y cola de push.
--
-- El tiempo: dentro de una transacción now() no avanza, así que el paso del
-- tiempo se simula moviendo columnas como postgres (expires_at de las
-- ofertas, y confirm_deadline de la visita con felix.time_travel = 'on').
--
-- Concurrencia de accept_offer: pgTAP corre en UNA sesión, así que la carrera
-- se simula en secuencia. accept_offer bloquea la fila de la visita
-- (FOR UPDATE) antes de mirar su estado: con dos sesiones, la segunda espera
-- a que la primera confirme y entonces ve `accepted` → "ya tomada", que es
-- exactamente lo que se verifica aquí. La carrera real (dos llamadas en
-- paralelo por la API) la cubre tool/e2e/urgencias_e2e.mjs.
begin;
select plan(78);

-- Fixtures ------------------------------------------------------------------
insert into auth.users (id, email)
select ('00000000-0000-0000-0000-' || k)::uuid, 'f8-' || k || '@test.local'
from unnest(array['000000015a01', '000000015a02', '000000015b01', '000000015b02',
  '000000015b03', '000000015b04', '000000015b05', '000000015b06', '000000015b07',
  '000000015b08', '000000015b09', '000000015b10', '000000015b11', '000000015b12',
  '000000015b13']) k;
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-000000015a01', 'owner'),
  ('00000000-0000-0000-0000-000000015a02', 'owner');
insert into public.user_roles (user_id, role)
select ('00000000-0000-0000-0000-000000015b' || lpad(i::text, 2, '0'))::uuid, 'vet'
from generate_series(1, 13) i;
insert into public.owner_profiles (user_id, display_name, phone, commune_id) values
  ('00000000-0000-0000-0000-000000015a01', 'Ana Urgencia', '+56 9 2222 2222',
   (select id from public.communes where name = 'Ñuñoa')),
  ('00000000-0000-0000-0000-000000015a02', 'Beto Urgencia', null,
   (select id from public.communes where name = 'Ñuñoa'));
insert into public.vet_profiles (user_id, display_name, status)
select ('00000000-0000-0000-0000-000000015b' || lpad(i::text, 2, '0'))::uuid,
       'Vet U' || i, 'approved'
from generate_series(1, 13) i;
insert into public.vet_species (vet_id, species_id)
select ('00000000-0000-0000-0000-000000015b' || lpad(i::text, 2, '0'))::uuid,
       (select id from public.species where slug = case when i = 9 then 'gato' else 'perro' end)
from generate_series(1, 13) i;
insert into public.vet_specialties (vet_id, specialty_id)
select ('00000000-0000-0000-0000-000000015b' || lpad(i::text, 2, '0'))::uuid,
       (select id from public.specialties where slug = 'general')
from generate_series(1, 13) i;

-- Aísla el test de los vets que ya existan en la BD (patrón de 850f40d).
set local session_replication_role = replica;
update public.vet_profiles set status = 'suspended'
  where status = 'approved' and user_id::text not like '00000000-0000-0000-0000-000000015b%';
set local session_replication_role = origin;

update public.foundations set is_default = false where is_default;
insert into public.foundations (id, name, is_default) values
  ('00000000-0000-0000-0000-000000015f01', 'F8 Fundación', true);
insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee, effective_from)
values (15, 20, 30, 500, 5, 5000, now() - interval '2 seconds');

insert into public.pets (id, owner_id, name, species_id) values
  ('00000000-0000-0000-0000-000000015e01', '00000000-0000-0000-0000-000000015a01', 'Rayo',
   (select id from public.species where slug = 'perro'));
insert into public.addresses (id, owner_id, label, street_text, details, commune_id, lat, lng) values
  ('00000000-0000-0000-0000-000000015d01', '00000000-0000-0000-0000-000000015a01', 'Casa',
   'Pasaje Ficticio 456', 'Casa 2', (select id from public.communes where name = 'Ñuñoa'),
   -33.4569, -70.5974);

-- Presencia: vets al norte de la dirección, a d km (1° de latitud ≈ 111,2 km).
create function pg_temp.vid(i integer) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-000000015b' || lpad(i::text, 2, '0'))::uuid;
$$;
insert into public.vet_presence (vet_id, online, location, updated_at)
select pg_temp.vid(i), true,
       extensions.st_setsrid(extensions.st_makepoint(-70.5974,
         round((-33.4569 + d / 111.2)::numeric, 3)::double precision), 4326)::extensions.geography,
       case when i = 10 then now() - interval '3 minutes' else now() end
from (values (1, 1.0), (2, 2.0), (3, 3.0), (4, 4.0), (5, 7.0), (6, 8.0), (7, 15.0),
             (8, 25.0), (9, 1.0), (10, 1.0), (12, 1.0), (13, 1.0)) x (i, d);
insert into public.vet_presence (vet_id, online, location) values (pg_temp.vid(11), false, null);
-- b12 ocupado: una agendada pendiente que se solapa con "ahora".
insert into public.visits (owner_id, vet_id, mode, status, commune_id, species_id, specialty_id,
  foundation_id, scheduled_at, slot, confirm_deadline, quote)
values ('00000000-0000-0000-0000-000000015a02', pg_temp.vid(12), 'scheduled', 'pending_vet',
  (select id from public.communes where name = 'Ñuñoa'),
  (select id from public.species where slug = 'perro'),
  (select id from public.specialties where slug = 'general'),
  '00000000-0000-0000-0000-000000015f01', now() + interval '30 minutes',
  tstzrange(now() + interval '30 minutes', now() + interval '120 minutes'),
  now() + interval '10 minutes', '{}'::jsonb);
-- b13 con día libre ahora.
insert into public.vet_time_off (vet_id, period)
values (pg_temp.vid(13), tstzrange(now() - interval '1 hour', now() + interval '1 hour'));

create temp table t_ids (k text primary key, v uuid);
grant all on t_ids to authenticated;

create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.id(p_k text) returns uuid language sql as $$
  select v from t_ids where k = p_k;
$$;
create function pg_temp.req() returns jsonb language sql as $$
  select public.request_urgent_visit('00000000-0000-0000-0000-000000015e01',
    '00000000-0000-0000-0000-000000015d01');
$$;
-- Vets de una tanda, por distancia.
create function pg_temp.batch(p_v uuid, p_b integer) returns uuid[] language sql as $$
  select array_agg(vet_id order by distance_m) from public.visit_offers
  where visit_id = p_v and batch = p_b;
$$;
create function pg_temp.offer(p_v uuid, p_vet uuid) returns uuid language sql as $$
  select id from public.visit_offers where visit_id = p_v and vet_id = p_vet;
$$;
-- Simula que vencieron las ofertas pendientes de la visita.
create function pg_temp.lapse(p_v uuid) returns void language sql as $$
  update public.visit_offers set expires_at = now() - interval '1 second'
  where visit_id = p_v and status = 'pending';
$$;
create function pg_temp.hint_of(p_sql text) returns text language plpgsql as $$
declare h text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  return h;
end;
$$;
grant execute on function pg_temp.vid(integer), pg_temp.id(text), pg_temp.req(),
  pg_temp.offer(uuid, uuid), pg_temp.hint_of(text) to authenticated;

-- Estructura y privilegios ----------------------------------------------------
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
           where oid in ('public.vet_presence'::regclass, 'public.visit_offers'::regclass,
                         'private.push_devices'::regclass, 'private.push_outbox'::regclass)),
  'RLS habilitada y forzada en las tablas de la fase 8');
select is_empty(
  $$ select t || ':' || p from unnest(array['public.vet_presence', 'public.visit_offers']) t
     cross join unnest(array['INSERT', 'UPDATE', 'DELETE']) p
     where has_table_privilege('authenticated', t, p)
        or exists (select 1 from information_schema.column_privileges c
                   where c.grantee = 'authenticated' and c.table_schema || '.' || c.table_name = t
                     and c.privilege_type = p) $$,
  'la app no escribe presencia ni ofertas (solo RPC)');
select ok(not has_column_privilege('authenticated', 'public.visit_offers', 'distance_m', 'select')
      and not has_column_privilege('authenticated', 'public.vet_presence', 'location', 'select'),
  'ni la distancia exacta de la oferta ni la ubicación del vet se leen directo');
select ok(not has_table_privilege('authenticated', 'private.push_outbox', 'select')
      and not has_table_privilege('authenticated', 'private.push_devices', 'select')
      and not has_table_privilege('service_role', 'private.push_devices', 'select'),
  'nadie lee los tokens ni la cola de push directo');
select ok(not has_function_privilege('authenticated', 'public.claim_push_batch(integer)', 'execute')
      and has_function_privilege('service_role', 'public.claim_push_batch(integer)', 'execute'),
  'solo service_role toma lotes de push');
select is((select schedule from cron.job where jobname = 'dispatch-urgent-visits'), '10 seconds',
  'pg_cron despacha urgencias cada 10 s');
select ok(exists (select 1 from cron.job where jobname = 'send-push')
      and exists (select 1 from cron.job where jobname = 'purge-push'),
  'pg_cron dispara send-push y purga la cola');

-- Presencia -------------------------------------------------------------------
set local role authenticated;
select pg_temp.login('00000000-0000-0000-0000-000000015a01');
select throws_ok($$ select public.set_vet_presence(true, -33.45, -70.6) $$, '42501', null,
  'un dueño no informa presencia');
select pg_temp.login(pg_temp.vid(8));
select lives_ok($$ select public.set_vet_presence(true, -33.23249, -70.59741) $$,
  'el vet informa que está en línea');
select throws_ok($$ select public.set_vet_presence(true, 10, 10) $$, '22023', null,
  'ubicación fuera de Chile: rechazada');
select is((select count(*)::integer from public.vet_presence), 1,
  'el vet ve solo su propia presencia');
select pg_temp.login('00000000-0000-0000-0000-000000015a01');
select is((select count(*)::integer from public.vet_presence), 0, 'un dueño no ve presencias');
reset role;
select is((select round(extensions.st_y(location::extensions.geometry)::numeric, 6)
           from public.vet_presence where vet_id = pg_temp.vid(8)), -33.232,
  'la posición se guarda redondeada (~100 m)');

-- Solicitud ---------------------------------------------------------------------
set local role authenticated;
select pg_temp.login(pg_temp.vid(1));
select throws_ok($$ select pg_temp.req() $$, '42501', null, 'un vet no pide urgencias');
select pg_temp.login('00000000-0000-0000-0000-000000015a02');
select throws_ok($$ select pg_temp.req() $$, '22023', null,
  'un dueño no pide con la mascota ni la dirección de otro');
select pg_temp.login('00000000-0000-0000-0000-000000015a01');
insert into t_ids select 'U1', (pg_temp.req() ->> 'id')::uuid;
select throws_ok($$ select pg_temp.req() $$, '22023',
  'Ya tienes una urgencia buscando veterinario', 'una sola urgencia en búsqueda por dueño');
select is((select j ->> 'status' from public.my_visits() j where j ->> 'id' = pg_temp.id('U1')::text),
  'searching', 'la urgencia nace buscando veterinario');
select ok((select (j -> 'quote' ->> 'urgent_surcharge')::integer = 8097
              and (j -> 'quote' ->> 'distance_pending')::boolean
              and (j -> 'quote' ->> 'max_total')::integer = 26990 + 8097 + 15 * 500
           from public.my_visits() j where j ->> 'id' = pg_temp.id('U1')::text),
  'precio del servidor: base + 30 % de urgencia; tope por distancia a 20 km ($500/km sobre 5)');
reset role;

-- Primera tanda ≤ 5 km, máx. 3, por distancia --------------------------------
select is(pg_temp.batch(pg_temp.id('U1'), 1), array[pg_temp.vid(1), pg_temp.vid(2), pg_temp.vid(3)],
  'primera tanda: los 3 elegibles más cercanos, ordenados por distancia');
select ok((select bool_and(radius_km = 5 and status = 'pending'
                            and expires_at = now() + interval '60 seconds')
           from public.visit_offers where visit_id = pg_temp.id('U1')),
  'ofertas de 60 s en el radio de 5 km');
select is_empty(
  $$ select vet_id from public.visit_offers where visit_id = pg_temp.id('U1')
     and vet_id in (pg_temp.vid(9), pg_temp.vid(10), pg_temp.vid(11), pg_temp.vid(12), pg_temp.vid(13)) $$,
  'sin ofertas a otra especie, presencia vieja, desconectados, ocupados ni con día libre');

-- Privacidad de la oferta --------------------------------------------------------
set local role authenticated;
select pg_temp.login(pg_temp.vid(1));
select is((select string_agg(k, ',' order by k collate "C") from public.my_offers() j, jsonb_object_keys(j) k),
  'batch,commune_name,created_at,distance_km,expires_at,offer_id,service_price,specialty_name,species_name,vet_payout,visit_id',
  'la oferta trae solo comuna, distancia, especie, especialidad y montos');
select ok((select (j ->> 'distance_km')::numeric = 1.0 and j ->> 'commune_name' = 'Ñuñoa'
                  and ((j ->> 'distance_km')::numeric * 2) = round((j ->> 'distance_km')::numeric * 2)
           from public.my_offers() j),
  'distancia redondeada a 0,5 km y comuna');
select ok((select (j ->> 'service_price')::integer = 26990 + 8097 from public.my_offers() j),
  'monto estimado con la distancia de la oferta (≤ 5 km: sin recargo)');
select is((select count(*)::integer from public.visits where id = pg_temp.id('U1')), 0,
  'el vet con oferta no lee la fila de la visita');
select is((select count(*)::integer from public.my_visits() j where j ->> 'id' = pg_temp.id('U1')::text), 0,
  'ni la ve en my_visits (sin dirección ni coordenadas)');
select is((select count(*)::integer from public.visit_offers), 1, 'el vet ve solo sus ofertas');
select pg_temp.login(pg_temp.vid(4));
select is((select count(*)::integer from public.my_offers()), 0, 'un vet sin oferta no ve nada');
select pg_temp.login('00000000-0000-0000-0000-000000015a01');
select is((select count(*)::integer from public.visit_offers), 0, 'el dueño no lee ofertas');
select ok((select (s ->> 'pending_offers')::integer = 3 and (s ->> 'radius_km')::integer = 5
                  and not s ? 'vet_id'
           from public.urgent_search_status(pg_temp.id('U1')) s),
  'el dueño ve el avance de la búsqueda sin identidades de vets');
reset role;

-- Vencimiento a 60 s y expansión del radio sin repetir --------------------------
select private.dispatch_urgent_visits();
select is((select count(*)::integer from public.visit_offers where visit_id = pg_temp.id('U1')), 3,
  'antes de 60 s no sale otra tanda');
select pg_temp.lapse(pg_temp.id('U1'));
select private.dispatch_urgent_visits();
select is((select array_agg(status order by vet_id) from public.visit_offers
           where visit_id = pg_temp.id('U1') and batch = 1), array['expired', 'expired', 'expired'],
  'a los 60 s las ofertas vencen');
select is(pg_temp.batch(pg_temp.id('U1'), 2), array[pg_temp.vid(4)],
  'segunda tanda: el siguiente del radio de 5 km');
set local role authenticated;
select pg_temp.login(pg_temp.vid(1));
select throws_ok(format('select public.accept_offer(%L)', pg_temp.offer(pg_temp.id('U1'), pg_temp.vid(1))),
  '22023', 'La oferta venció', 'una oferta vencida no se acepta');
select pg_temp.login(pg_temp.vid(4));
select lives_ok(format('select public.reject_offer(%L)', pg_temp.offer(pg_temp.id('U1'), pg_temp.vid(4))),
  'el vet rechaza la oferta');
reset role;
select is(pg_temp.batch(pg_temp.id('U1'), 3), array[pg_temp.vid(5), pg_temp.vid(6)],
  'rechazada la última, sale de inmediato la tanda del radio de 10 km');
select ok((select bool_and(radius_km = 10) from public.visit_offers
           where visit_id = pg_temp.id('U1') and batch = 3), 'radio 10 km');
select pg_temp.lapse(pg_temp.id('U1'));
select private.dispatch_urgent_visits();
select is(pg_temp.batch(pg_temp.id('U1'), 4), array[pg_temp.vid(7)], 'luego el radio de 20 km');
select is((select count(distinct vet_id) = count(*) from public.visit_offers
           where visit_id = pg_temp.id('U1')), true, 'ningún vet se repite');
select pg_temp.lapse(pg_temp.id('U1'));
select private.dispatch_urgent_visits();
select ok((select status = 'no_vet_found' and closed_by_system and cancel_fee = 0
           from public.visits where id = pg_temp.id('U1')),
  'agotado el radio de 20 km: no_vet_found, cerrada por el sistema');
select is((select count(*)::integer from public.payments where visit_id = pg_temp.id('U1')), 0,
  'no_vet_found no genera cobro');
select is_empty($$ select 1 from public.visit_offers where visit_id = pg_temp.id('U1')
                   and (vet_id = pg_temp.vid(8) or status = 'pending') $$,
  'el vet a 25 km nunca recibe oferta y no quedan pendientes');

-- 10 min sin vet ----------------------------------------------------------------
set local role authenticated;
select pg_temp.login('00000000-0000-0000-0000-000000015a01');
insert into t_ids select 'U2', (pg_temp.req() ->> 'id')::uuid;
reset role;
select is(cardinality(pg_temp.batch(pg_temp.id('U2'), 1)), 3, 'la nueva urgencia tiene su tanda');
set local felix.time_travel = 'on';
update public.visits set confirm_deadline = now() - interval '1 second' where id = pg_temp.id('U2');
set local felix.time_travel = 'off';
select private.dispatch_urgent_visits();
select ok((select status = 'no_vet_found' and cancel_fee = 0 from public.visits
           where id = pg_temp.id('U2')), 'a los 10 min: no_vet_found');
select is((select array_agg(distinct status) from public.visit_offers where visit_id = pg_temp.id('U2')),
  array['cancelled'], 'las ofertas pendientes se cierran');
select is((select count(*)::integer from public.payments where visit_id = pg_temp.id('U2')), 0,
  'sin cobro');

-- Aceptación atómica y "ya tomada" ------------------------------------------------
insert into private.push_devices (token, user_id, platform) values
  ('tok-owner-a-0001', '00000000-0000-0000-0000-000000015a01', 'android'),
  ('tok-vet-1-000001', pg_temp.vid(1), 'web');
set local role authenticated;
select pg_temp.login('00000000-0000-0000-0000-000000015a01');
insert into t_ids select 'U3', (pg_temp.req() ->> 'id')::uuid;
reset role;
select ok(exists (select 1 from private.push_outbox where user_id = pg_temp.vid(1)
                  and visit_id = pg_temp.id('U3') and event = 'offer_new'),
  'push offer_new al vet con dispositivo');
insert into t_ids select 'Q3', quote_id from public.visits where id = pg_temp.id('U3');
set local role authenticated;
select pg_temp.login(pg_temp.vid(2));
select is((public.accept_offer(pg_temp.offer(pg_temp.id('U3'), pg_temp.vid(2))) ->> 'status'),
  'accepted', 'el primer vet acepta');
select pg_temp.login(pg_temp.vid(1));
select throws_ok(format('select public.accept_offer(%L)', pg_temp.offer(pg_temp.id('U3'), pg_temp.vid(1))),
  '22023', 'Esta urgencia ya fue tomada por otro veterinario', 'el segundo recibe "ya tomada"');
select is(pg_temp.hint_of(format('select public.accept_offer(%L)',
            pg_temp.offer(pg_temp.id('U3'), pg_temp.vid(1)))), 'offer_taken',
  'con un hint explícito para la app');
reset role;
select ok((select status = 'accepted' and vet_id = pg_temp.vid(2) and scheduled_at = now()
                  and slot = tstzrange(now(), now() + interval '90 minutes')
                  and quote_id <> pg_temp.id('Q3')
                  and (quote ->> 'request_quote_id')::uuid = pg_temp.id('Q3')
                  and (quote ->> 'distance_km')::integer = 2
                  and (quote ->> 'distance_surcharge')::integer = 0
           from public.visits where id = pg_temp.id('U3')),
  'queda asignada: hora = aceptación, slot de 90 min y cotización final con distancia');
select is((select array_agg(status order by vet_id) from public.visit_offers
           where visit_id = pg_temp.id('U3')), array['lost', 'accepted', 'lost'],
  'la oferta ganadora queda aceptada y las otras, tomadas');
select ok(exists (select 1 from private.push_outbox where user_id = '00000000-0000-0000-0000-000000015a01'
                  and visit_id = pg_temp.id('U3') and event = 'visit_accepted')
      and exists (select 1 from private.push_outbox where user_id = pg_temp.vid(1)
                  and visit_id = pg_temp.id('U3') and event = 'offer_taken'),
  'push visit_accepted al dueño y offer_taken al que perdió');
select is((select count(*)::integer from private.push_outbox
           where event !~ '^(offer|visit)_[a-z_]+$'), 0, 'eventos de push con nombre acotado');
select ok((select (private.urgent_price(q, 15000)).distance_surcharge = 10 * 500
           from public.quotes q where q.id = pg_temp.id('Q3')),
  'a 15 km se cobran 10 km × $500');
select is((select count(*)::integer from public.record_access_grants
           where visit_id = pg_temp.id('U3') and vet_id = pg_temp.vid(2)), 1,
  'al aceptar, el vet obtiene el acceso a la ficha de la visita');

-- Dirección y Realtime ----------------------------------------------------------------
set local role authenticated;
select pg_temp.login(pg_temp.vid(2));
select ok((select j -> 'exact' ->> 'street_text' = 'Pasaje Ficticio 456'
           from public.my_visits() j where j ->> 'id' = pg_temp.id('U3')::text),
  'el vet asignado ve la dirección exacta');
select ok(not private.can_use_visit_topic('visit:' || pg_temp.id('U3'), true),
  'antes de "en camino" no hay canal de ubicación');
select lives_ok(format('select public.transition_visit(%L, %L)', pg_temp.id('U3'), 'en_route'),
  'el vet sale (en camino)');
select set_config('realtime.topic', 'visit:' || pg_temp.id('U3'), true);
select lives_ok(format($$ insert into realtime.messages (topic, extension, event, payload, private)
  values (%L, 'broadcast', 'location', '{"lat": -33.44, "lng": -70.59}', true) $$,
  'visit:' || pg_temp.id('U3')), 'en camino, el vet asignado publica su posición');
select pg_temp.login('00000000-0000-0000-0000-000000015a01');
select is((select count(*)::integer from realtime.messages where topic = 'visit:' || pg_temp.id('U3')), 1,
  'el dueño recibe la posición');
select throws_ok(format($$ insert into realtime.messages (topic, extension, event, payload, private)
  values (%L, 'broadcast', 'location', '{}', true) $$, 'visit:' || pg_temp.id('U3')), '42501', null,
  'el dueño no publica en el canal');
select pg_temp.login(pg_temp.vid(1));
select is((select count(*)::integer from realtime.messages where topic = 'visit:' || pg_temp.id('U3')), 0,
  'otro vet no recibe');
select throws_ok(format($$ insert into realtime.messages (topic, extension, event, payload, private)
  values (%L, 'broadcast', 'location', '{}', true) $$, 'visit:' || pg_temp.id('U3')), '42501', null,
  'otro vet no publica');
select pg_temp.login('00000000-0000-0000-0000-000000015a02');
select ok(not private.can_use_visit_topic('visit:' || pg_temp.id('U3'), false),
  'otro dueño no se une al canal');
select ok(not private.can_use_visit_topic('visit:no-es-uuid', false)
      and not private.can_use_visit_topic(null, false), 'un topic inválido no autoriza');

-- Cancelación con cargo (después de "en camino") --------------------------------------
select pg_temp.login('00000000-0000-0000-0000-000000015a01');
select is((public.transition_visit(pg_temp.id('U3'), 'cancelled_owner') ->> 'cancel_fee')::integer,
  5000, 'el dueño cancela con el vet en camino: $5.000');
select pg_temp.login(pg_temp.vid(2));
select ok(not private.can_use_visit_topic('visit:' || pg_temp.id('U3'), true),
  'al cancelar se cierra el canal de ubicación');
reset role;
select is((select count(*)::integer from public.payments
           where visit_id = pg_temp.id('U3') and kind = 'cancel_fee'), 1,
  'el cargo queda como pago cancel_fee');

-- Cancelación gratis antes de "en camino" y durante la búsqueda --------------------------
set local role authenticated;
select pg_temp.login('00000000-0000-0000-0000-000000015a01');
insert into t_ids select 'U4', (pg_temp.req() ->> 'id')::uuid;
select pg_temp.login(pg_temp.vid(1));
select lives_ok(format('select public.accept_offer(%L)', pg_temp.offer(pg_temp.id('U4'), pg_temp.vid(1))),
  'otro vet acepta la urgencia siguiente');
select pg_temp.login('00000000-0000-0000-0000-000000015a01');
select is((public.transition_visit(pg_temp.id('U4'), 'cancelled_owner') ->> 'cancel_fee')::integer,
  0, 'aceptada pero antes de "en camino": cancelar es gratis');
insert into t_ids select 'U5', (pg_temp.req() ->> 'id')::uuid;
select is((public.transition_visit(pg_temp.id('U5'), 'cancelled_owner') ->> 'cancel_fee')::integer,
  0, 'durante la búsqueda: cancelar es gratis');
reset role;
select is((select array_agg(distinct status) from public.visit_offers where visit_id = pg_temp.id('U5')),
  array['cancelled'], 'al cancelar la búsqueda, las ofertas se cierran');
select is((select count(*)::integer from public.payments
           where visit_id in (pg_temp.id('U4'), pg_temp.id('U5'))), 0, 'sin cargos');

-- Bordes de la máquina -------------------------------------------------------------------
set local role authenticated;
select pg_temp.login('00000000-0000-0000-0000-000000015a01');
insert into t_ids select 'U6', (pg_temp.req() ->> 'id')::uuid;
select throws_ok(format('select public.transition_visit(%L, %L)', pg_temp.id('U6'), 'accepted'),
  '42501', null, 'el dueño no asigna la urgencia');
select throws_ok(format('select public.transition_visit(%L, %L)', pg_temp.id('U6'), 'no_vet_found'),
  '42501', null, 'el dueño no la cierra como sin vet');
select pg_temp.login(pg_temp.vid(1));
select throws_ok(format('select public.transition_visit(%L, %L)', pg_temp.id('U6'), 'accepted'),
  '22023', 'La visita no existe', 'un vet no se asigna sin accept_offer');
reset role;
select throws_ok(format($$ update public.visits set quote = '{}'::jsonb where id = %L $$, pg_temp.id('U6')),
  '42501', null, 'fuera de la aceptación, la cotización de la urgencia no cambia');

select * from finish();
rollback;
