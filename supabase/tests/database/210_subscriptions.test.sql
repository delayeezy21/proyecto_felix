-- Fase 10: suscripciones simuladas (SPEC F5, HU5.1–HU5.3). Catálogo de planes,
-- alta/baja/mascotas, período y renovación, tabla de precios con suscripción
-- (descuento, urgencia, preventiva, distancia), cupo de preventivas, plan
-- congelado en la cotización, subsidio (vet sin descuento) y matriz de accesos.
begin;
select plan(107);
-- Fechas en hora de Chile aunque la sesión esté en UTC+14 (QA-F11-02).
set local timezone = 'Etc/GMT-14';

-- Fixtures ------------------------------------------------------------------
create function pg_temp.u(p text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000021' || p)::uuid;
$$;
insert into auth.users (id, email)
select pg_temp.u(k), 'f10-' || k || '@test.local'
from unnest(array['a1', 'a2', 'a3', 'a4', 'b1', 'c1', 'd1']) k;
insert into public.user_roles (user_id, role) values
  (pg_temp.u('a1'), 'owner'), (pg_temp.u('a2'), 'owner'), (pg_temp.u('a3'), 'owner'),
  (pg_temp.u('a4'), 'owner'), (pg_temp.u('b1'), 'vet'), (pg_temp.u('c1'), 'admin'),
  (pg_temp.u('d1'), 'foundation');
insert into public.owner_profiles (user_id, display_name, commune_id)
select pg_temp.u(k), 'Dueño ' || k, (select id from public.communes where name = 'Ñuñoa')
from unnest(array['a1', 'a2', 'a3', 'a4']) k;
insert into public.vet_profiles (user_id, display_name, status) values
  (pg_temp.u('b1'), 'Dra. Plan', 'approved');
insert into public.vet_species (vet_id, species_id)
  select pg_temp.u('b1'), id from public.species where slug = 'perro';
insert into public.vet_specialties (vet_id, specialty_id)
  select pg_temp.u('b1'), id from public.specialties
  where slug in ('general', 'prevencion', 'urgencias');
insert into public.vet_availability (vet_id, weekday, start_min, end_min)
  select pg_temp.u('b1'), d, 0, 1440 from generate_series(1, 7) d;
-- Origen ≈ 7,99 km al norte de las direcciones (3 km facturables = $1.500).
insert into public.vet_bases (vet_id, commune_id, lat, lng) values
  (pg_temp.u('b1'), (select commune_id from public.communes_at_point(-33.3849, -70.5974) limit 1),
   -33.3849, -70.5974);
update public.vet_bases set fuzz_dlat = 0, fuzz_dlng = 0 where vet_id = pg_temp.u('b1');
set local session_replication_role = replica;
update public.vet_profiles set status = 'suspended'
  where status = 'approved' and user_id <> pg_temp.u('b1');
set local session_replication_role = origin;

update public.foundations set is_default = false where is_default;
insert into public.foundations (id, name, is_default) values
  ('00000000-0000-0000-0000-00000000f210', 'F10 Fundación', true);
insert into public.foundation_members (user_id, foundation_id) values
  (pg_temp.u('d1'), '00000000-0000-0000-0000-00000000f210');
-- Tarifas y parámetros fijos (por si un E2E dejó otros).
update public.tariffs t set base_price = x.p
from (values ('general', 30000), ('prevencion', 20000), ('urgencias', 35000)) x (slug, p)
join public.specialties s on s.slug = x.slug
where t.specialty_id = s.id and t.species_id is null;
delete from public.tariffs t using public.specialties s
where t.specialty_id = s.id and t.species_id is not null
  and s.slug in ('general', 'prevencion', 'urgencias');
insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee, effective_from)
values (15, 20, 30, 500, 5, 5000, now() - interval '2 seconds');

-- Mascotas: A (e1, e2), B (e3), C (c1..c5), D bloqueado (e9), inactiva de A (e0).
insert into public.pets (id, owner_id, name, species_id, active)
select ('00000000-0000-0000-0000-00000021e' || x.k)::uuid, pg_temp.u(x.o), 'Mascota ' || x.k,
       (select id from public.species where slug = 'perro'), x.act
from (values ('0a1', 'a1', false), ('1a1', 'a1', true), ('2a1', 'a1', true),
             ('3a2', 'a2', true), ('c01', 'a3', true), ('c02', 'a3', true),
             ('c03', 'a3', true), ('c04', 'a3', true), ('c05', 'a3', true),
             ('9a4', 'a4', true)) x (k, o, act);
insert into public.addresses (id, owner_id, label, street_text, commune_id, lat, lng)
select ('00000000-0000-0000-0000-000000021d0' || right(k, 1))::uuid, pg_temp.u(k), 'Casa',
       'Calle Ficticia ' || k, (select id from public.communes where name = 'Ñuñoa'),
       -33.4569, -70.5974
from unnest(array['a1', 'a2', 'a3', 'a4']) k;

create temp table t_ids (k text primary key, v uuid);
create temp table t_q (k text primary key, j jsonb);
create temp table t_ts (k text primary key, v timestamptz);
grant all on t_ids, t_q, t_ts to authenticated;
insert into t_ts values ('T',
  ((now() at time zone 'America/Santiago')::date + 2 + time '09:00') at time zone 'America/Santiago');

create function pg_temp.login(p text) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', pg_temp.u(p), 'role', 'authenticated')::text, true);
$$;
create function pg_temp.pet(p text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-00000021e' || p)::uuid;
$$;
create function pg_temp.addr(p text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-000000021d0' || right(p, 1))::uuid;
$$;
create function pg_temp.id(p_k text) returns uuid language sql as $$
  select v from t_ids where k = p_k;
$$;
create function pg_temp.ts(p_k text) returns timestamptz language sql as $$
  select v from t_ts where k = p_k;
$$;
create function pg_temp.plan(p_slug text) returns integer language sql security definer as $$
  select id from public.subscription_plans where slug = p_slug;
$$;
create function pg_temp.spec(p_slug text) returns integer language sql security definer as $$
  select id from public.specialties where slug = p_slug;
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end;
$$;
create function pg_temp.nrows(p_sql text) returns integer language plpgsql as $$
declare n integer;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end;
$$;
-- Cotiza como el usuario logueado. Devuelve
-- base,urgencia,km,distancia,descuento,servicio,comisión,fundación,vet,total,subsidio.
create function pg_temp.qv(p_key text, p_owner text, p_pet text, p_spec text, p_mode text,
  p_with_vet boolean default true, p_don integer default 0)
returns text language plpgsql as $$
declare
  j jsonb;
begin
  j := public.quote_visit(pg_temp.pet(p_pet), pg_temp.addr(p_owner), pg_temp.spec(p_spec),
         p_mode, case when p_with_vet then pg_temp.u('b1') end, null, p_don);
  insert into t_ids values (p_key, (j ->> 'quote_id')::uuid)
    on conflict (k) do update set v = excluded.v;
  insert into t_q values (p_key, j) on conflict (k) do update set j = excluded.j;
  return concat_ws(',', j ->> 'base_price', j ->> 'urgent_surcharge', j ->> 'billable_km',
    j ->> 'distance_surcharge', j ->> 'discount', j ->> 'service_price', j ->> 'platform_fee',
    j ->> 'foundation_share', j ->> 'vet_payout', j ->> 'total', j ->> 'plan_subsidy');
end;
$$;
create function pg_temp.book(p_q text, p_pet text, p_at timestamptz) returns uuid
language sql as $$
  select (public.book_visit(pg_temp.id(p_q), pg_temp.u('b1'), pg_temp.pet(p_pet),
            pg_temp.addr('a1'), p_at) ->> 'id')::uuid;
$$;
create function pg_temp.tt(p_sql text) returns void language plpgsql as $$
begin
  perform set_config('felix.time_travel', 'on', true);
  execute p_sql;
  perform set_config('felix.time_travel', 'off', true);
end;
$$;
grant execute on function pg_temp.plan(text), pg_temp.spec(text), pg_temp.u(text),
  pg_temp.pet(text), pg_temp.addr(text) to authenticated;

-- Estructura y privilegios ----------------------------------------------------
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
           where oid in ('public.subscription_plans'::regclass, 'public.subscriptions'::regclass,
                         'public.subscription_pets'::regclass)),
  'RLS habilitada y forzada en las tablas de la fase 10');
select is_empty(
  $$ select t || ':' || p from unnest(array['public.subscriptions', 'public.subscription_pets']) t
     cross join unnest(array['INSERT', 'UPDATE', 'DELETE']) p
     where has_table_privilege('authenticated', t, p)
        or exists (select 1 from information_schema.column_privileges c
                   where c.grantee = 'authenticated' and c.table_schema || '.' || c.table_name = t
                     and c.privilege_type = p) $$,
  'la app no escribe suscripciones ni mascotas asociadas (solo por RPC)');
select ok(not has_table_privilege('anon', 'public.subscription_plans', 'select')
      and not has_table_privilege('anon', 'public.subscriptions', 'select')
      and not has_function_privilege('anon', 'public.subscribe(integer, uuid[])', 'execute')
      and not has_function_privilege('anon', 'public.my_subscription()', 'execute')
      and not has_function_privilege('anon', 'public.cancel_subscription()', 'execute')
      and not has_function_privilege('anon', 'public.set_subscription_pets(uuid[])', 'execute'),
  'anon no lee planes ni suscripciones ni llama a las RPC');
select is_empty(
  $$ select p from unnest(array[
       'private.renew_subscriptions()', 'private.charge_subscription(public.subscriptions, date)',
       'private.plan_benefits(uuid, uuid, text, integer)', 'private.preventive_used(uuid)',
       'private.subscription_view(public.subscriptions)', 'private.chile_today()',
       'private.check_subscription_pets(uuid, public.subscription_plans, uuid[])',
       'private.urgent_price(public.quotes, integer)',
       'private.record_payment(uuid, uuid, uuid, uuid, uuid, text, integer, integer, integer, integer, integer, boolean, integer)']) p
     where has_function_privilege('authenticated', p, 'execute') $$,
  'los helpers internos de suscripción no los ejecuta la app');
select is((select schedule from cron.job where jobname = 'renew-subscriptions'), '7 * * * *',
  'pg_cron renueva las suscripciones cada hora');
select is((select string_agg(concat_ws(':', slug, discount_pct::int, preventive_per_year,
             waive_urgent, max_pets, price_monthly), ' ' order by sort)
           from public.subscription_plans where slug in ('basico', 'plus', 'familia')),
  'basico:10:1:f:1:4990 plus:20:2:t:1:9990 familia:20:2:t:4:14990',
  'los 3 planes semilla de la SPEC');

-- Sin plan (control) ----------------------------------------------------------
select pg_temp.login('a1');
set local role authenticated;
select is(public.my_subscription(), null, 'sin suscripción, my_subscription es null');
select is(pg_temp.qv('c01', 'a1', '1a1', 'general', 'scheduled'),
  '30000,0,3,1500,0,31500,4725,945,26775,31500,0',
  'caso 01: sin plan, general agendada a 8 km (control)');
select is((select j -> 'plan' from t_q where k = 'c01'), 'null'::jsonb,
  'sin plan, la cotización no trae plan');

-- HU5.1: alta y mascotas ------------------------------------------------------
select is(pg_temp.err(format('select public.subscribe(%s, %L)', pg_temp.plan('basico'),
            array[pg_temp.pet('1a1'), pg_temp.pet('2a1')])),
  '22023: El plan Básico admite hasta 1 mascota(s)', 'Básico respeta max_pets = 1');
select is(pg_temp.err(format('select public.subscribe(%s, %L)', pg_temp.plan('basico'),
            array[pg_temp.pet('3a2')])),
  '22023: La mascota no existe o no está activa', 'no se asocia la mascota de otro dueño');
select is(pg_temp.err(format('select public.subscribe(%s, %L)', pg_temp.plan('basico'),
            array[pg_temp.pet('0a1')])),
  '22023: La mascota no existe o no está activa', 'no se asocia una mascota inactiva');
select is(pg_temp.err(format('select public.subscribe(%s, %L)', pg_temp.plan('basico'),
            '{}'::uuid[])),
  '22023: Elige al menos una mascota', 'se exige al menos una mascota');
select is(pg_temp.err(format('select public.subscribe(%s, %L)', pg_temp.plan('familia'),
            array[pg_temp.pet('1a1'), pg_temp.pet('1a1')])),
  '22023: Hay mascotas repetidas', 'no se repiten mascotas');
select is(pg_temp.err('select public.subscribe(999999, null)'),
  '22023: El plan no existe o no está disponible', 'plan inexistente');
insert into t_q select 'subA', public.subscribe(pg_temp.plan('basico'), array[pg_temp.pet('1a1')]);
select is((select concat_ws(',', j ->> 'status', j -> 'plan' ->> 'name', j ->> 'benefits_active',
             j ->> 'renews', j ->> 'periods_paid', j ->> 'preventive_remaining',
             jsonb_array_length(j -> 'pets'))
           from t_q where k = 'subA'),
  'active,Básico,true,true,1,1,1', 'A se suscribe a Básico con una mascota');
select is((select (j ->> 'current_period_start')::date = (now() at time zone 'America/Santiago')::date
                  and (j ->> 'current_period_end')::date
                      = ((now() at time zone 'America/Santiago')::date + interval '1 month')::date
           from t_q where k = 'subA'), true,
  'período mensual en fecha de Chile: [hoy, hoy + 1 mes)');
select is((select concat_ws(',', kind, status, service_price, platform_fee, vet_payout,
             foundation_share, total, period_start = (now() at time zone 'America/Santiago')::date)
           from public.payments where owner_id = pg_temp.u('a1') and kind = 'subscription'),
  'subscription,simulated_paid,4990,4990,0,0,4990,t',
  'el alta registra el pago simulado del primer mes (sin vet ni aporte)');
select is(pg_temp.err(format('select public.subscribe(%s, %L)', pg_temp.plan('plus'),
            array[pg_temp.pet('1a1')])),
  '22023: Ya tienes una suscripción activa. Cancélala antes de cambiar de plan.',
  'HU5.1: una sola suscripción activa por dueño');
select is(pg_temp.err(format('insert into public.subscriptions (owner_id, plan_id, started_on, current_period_start, current_period_end) values (%L, %s, current_date, current_date, current_date + 30)',
            pg_temp.u('a1'), pg_temp.plan('plus'))),
  '42501: permission denied for table subscriptions', 'la app no inserta suscripciones directo');
select is(pg_temp.err(format('update public.subscriptions set status = %L', 'ended')),
  '42501: permission denied for table subscriptions', 'ni las modifica');

-- HU5.2: tabla de precios con suscripción -------------------------------------
select is(pg_temp.qv('c02', 'a1', '1a1', 'general', 'scheduled'),
  '30000,0,3,1500,3000,28500,4725,945,26775,28500,3000',
  'caso 02: Básico, general a 8 km: 10 % a la base; vet y fundación como sin plan');
select is((select j -> 'plan' ->> 'name' || ':' || (j -> 'plan' ->> 'discount_pct')::numeric::int
           from t_q where k = 'c02'), 'Básico:10', 'la cotización congela el plan aplicado');
select is(pg_temp.qv('c03', 'a1', '1a1', 'general', 'scheduled', false),
  '30000,0,0,0,3000,27000,4500,900,25500,27000,3000', 'caso 03: Básico sin vet (sin distancia)');
select is(pg_temp.qv('c04', 'a1', '1a1', 'urgencias', 'urgent'),
  '35000,10500,3,1500,3500,43500,7050,1410,39950,43500,3500',
  'caso 04: Básico en urgencia paga el recargo; descuento solo a la base');
select is(pg_temp.qv('c05', 'a1', '1a1', 'prevencion', 'scheduled'),
  '20000,0,3,1500,20000,1500,3225,645,18275,1500,20000',
  'caso 05: preventiva incluida: base $0, se cobra solo la distancia');
select is((select (j ->> 'is_preventive')::boolean from t_q where k = 'c05'), true,
  'la cotización marca la preventiva');
select is(pg_temp.qv('c06', 'a1', '1a1', 'prevencion', 'scheduled', false, 2000),
  '20000,0,0,0,20000,0,3000,600,17000,2000,20000',
  'caso 06: preventiva sin distancia + donación: el dueño paga solo la donación');
select is(pg_temp.qv('c07', 'a1', '2a1', 'general', 'scheduled'),
  '30000,0,3,1500,0,31500,4725,945,26775,31500,0',
  'caso 07: mascota no asociada al plan: precio normal');
select is(pg_temp.qv('c08', 'a1', '1a1', 'prevencion', 'urgent'),
  '20000,6000,3,1500,2000,25500,4125,825,23375,25500,2000',
  'caso 08: prevención como urgencia no es preventiva incluida (solo descuento)');
-- Segunda cotización preventiva antes de reservar la primera.
select is(pg_temp.qv('c05b', 'a1', '1a1', 'prevencion', 'scheduled'),
  '20000,0,3,1500,20000,1500,3225,645,18275,1500,20000',
  'caso 05b: con cupo libre, otra cotización preventiva');

-- Cupo anual de preventivas ----------------------------------------------------
insert into t_ids values ('vP1', pg_temp.book('c05', '1a1', pg_temp.ts('T')));
reset role;
select is((select is_preventive from public.visits where id = pg_temp.id('vP1')), true,
  'la visita reservada queda como preventiva (visits.is_preventive)');
select is(private.preventive_used(pg_temp.u('a1')), 1, 'descuenta del cupo anual');
select pg_temp.login('a1');
set local role authenticated;
select is(pg_temp.err(format('select pg_temp.book(%L, %L, %L)', 'c05b', '1a1',
            pg_temp.ts('T') + interval '2 hours')),
  '22023: Tu plan cambió desde la cotización (venció o se agotó el cupo de preventivas). Vuelve a cotizar.',
  'agotado el cupo, la reserva con una cotización preventiva anterior se rechaza');
select is(pg_temp.qv('c09', 'a1', '1a1', 'prevencion', 'scheduled'),
  '20000,0,3,1500,2000,19500,3225,645,18275,19500,2000',
  'caso 09: cupo agotado: se cobra normal (con el 10 % del plan)');
select is((select (j ->> 'is_preventive')::boolean from t_q where k = 'c09'), false,
  'cupo agotado: no es preventiva');
select is(public.my_subscription() ->> 'preventive_remaining', '0', 'my_subscription: cupo 0');
select is((public.transition_visit(pg_temp.id('vP1'), 'cancelled_owner', 'Cambio de planes')
           ->> 'status'), 'cancelled_owner', 'el dueño cancela la preventiva');
select is(pg_temp.qv('c10', 'a1', '1a1', 'prevencion', 'scheduled'),
  '20000,0,3,1500,20000,1500,3225,645,18275,1500,20000',
  'caso 10: la preventiva cancelada devuelve el cupo');

-- Familia: hasta 4 mascotas, sin recargo de urgencia -----------------------------
select pg_temp.login('a3');
select is(pg_temp.err(format('select public.subscribe(%s, %L)', pg_temp.plan('familia'),
            array[pg_temp.pet('c01'), pg_temp.pet('c02'), pg_temp.pet('c03'), pg_temp.pet('c04'),
                  pg_temp.pet('c05')])),
  '22023: El plan Familia admite hasta 4 mascota(s)', 'Familia respeta max_pets = 4');
select is(jsonb_array_length(public.subscribe(pg_temp.plan('familia'),
            array[pg_temp.pet('c01'), pg_temp.pet('c02'), pg_temp.pet('c03')]) -> 'pets'), 3,
  'C se suscribe a Familia con 3 mascotas');
select is(jsonb_array_length(public.set_subscription_pets(
            array[pg_temp.pet('c01'), pg_temp.pet('c02'), pg_temp.pet('c03'), pg_temp.pet('c04')])
            -> 'pets'), 4, 'set_subscription_pets: agrega la cuarta');
select is(pg_temp.err(format('select public.set_subscription_pets(%L)',
            array[pg_temp.pet('c01'), pg_temp.pet('c02'), pg_temp.pet('c03'), pg_temp.pet('c04'),
                  pg_temp.pet('c05')])),
  '22023: El plan Familia admite hasta 4 mascota(s)', 'set_subscription_pets respeta max_pets');
select is(pg_temp.qv('c11', 'a3', 'c01', 'urgencias', 'urgent'),
  '35000,0,3,1500,7000,29500,7050,1410,39950,29500,17500',
  'caso 11: Familia en urgencia a 8 km: sin recargo y 20 %; el vet cobra como sin plan');
select is(pg_temp.qv('c12', 'a3', 'c02', 'urgencias', 'urgent', false),
  '35000,0,0,0,7000,28000,6825,1365,38675,28000,17500',
  'caso 12: Familia en urgencia sin distancia');
select is(pg_temp.qv('c13', 'a3', 'c03', 'general', 'scheduled'),
  '30000,0,3,1500,6000,25500,4725,945,26775,25500,6000', 'caso 13: Familia, general agendada');
select is(pg_temp.qv('c14', 'a3', 'c04', 'prevencion', 'scheduled'),
  '20000,0,3,1500,20000,1500,3225,645,18275,1500,20000',
  'caso 14: Familia, preventiva incluida para la cuarta mascota');
select is(pg_temp.qv('c15', 'a3', 'c01', 'urgencias', 'urgent', true, 1000),
  '35000,0,3,1500,7000,29500,7050,1410,39950,30500,17500',
  'caso 15: Familia en urgencia con donación');
select is(pg_temp.qv('c16', 'a3', 'c05', 'urgencias', 'urgent'),
  '35000,10500,3,1500,0,47000,7050,1410,39950,47000,0',
  'caso 16: quinta mascota fuera del plan: urgencia normal');
select is(pg_temp.qv('c16b', 'a3', 'c01', 'general', 'scheduled', false),
  '30000,0,0,0,6000,24000,4500,900,25500,24000,6000', 'caso 17: Familia sin vet (sin distancia)');

-- Urgencia real: la solicitud congela el plan y el precio final lo respeta.
insert into t_q select 'u1', public.request_urgent_visit(pg_temp.pet('c01'), pg_temp.addr('a3'),
  pg_temp.spec('urgencias'));
reset role;
select is((select concat_ws(',', p.urgent_surcharge, p.discount, p.service_price, p.vet_payout,
             p.plan_subsidy)
           from public.visits v join public.quotes q on q.id = v.quote_id
           cross join lateral private.urgent_price(q, 7989) p
           where v.id = (select (j ->> 'id')::uuid from t_q where k = 'u1')),
  '0,7000,29500,39950,17500', 'urgencia despachada: el precio final usa el plan congelado');
select is((select v.quote -> 'plan' ->> 'name' from public.visits v
           where v.id = (select (j ->> 'id')::uuid from t_q where k = 'u1')),
  'Familia', 'la visita urgente guarda el plan en su cotización');

-- Versión de pricing_config y edición del plan por el admin ---------------------
insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee,
   commission_on_distance, effective_from)
values (15, 20, 30, 500, 5, 5000, false, now() - interval '1 second');
select pg_temp.login('a3');
set local role authenticated;
select is(pg_temp.qv('c18', 'a3', 'c03', 'general', 'scheduled'),
  '30000,0,3,1500,6000,25500,4500,900,27000,25500,6000',
  'caso 18: con commission_on_distance = false, la distancia va completa al vet');
select pg_temp.login('c1');
select is(pg_temp.nrows($$ update public.subscription_plans set discount_pct = 30
             where slug = 'familia' $$), 1, 'el admin edita el descuento de un plan');
select pg_temp.login('a3');
select is(pg_temp.qv('c19', 'a3', 'c03', 'general', 'scheduled'),
  '30000,0,3,1500,9000,22500,4500,900,27000,22500,9000',
  'caso 19: el nuevo descuento vale para cotizaciones nuevas');
reset role;
select is((select discount from public.quotes where id = pg_temp.id('c13')), 6000,
  'la cotización anterior conserva el plan congelado');
select ok(exists (select 1 from public.admin_audit_log
                  where table_name = 'subscription_plans' and action = 'UPDATE'
                    and actor_id = pg_temp.u('c1')),
  'el cambio del plan queda en admin_audit_log');
select pg_temp.login('a3');
set local role authenticated;
select is(pg_temp.nrows($$ update public.subscription_plans set price_monthly = 1
             where slug = 'familia' $$), 0, 'un dueño no edita planes');
select pg_temp.login('c1');
update public.subscription_plans set active = false where slug = 'plus';
select pg_temp.login('a2');
select is((select count(*)::int from public.subscription_plans where slug = 'plus'), 0,
  'un plan desactivado no se lista al dueño');
select is(pg_temp.err(format('select public.subscribe(%s, %L)', pg_temp.plan('plus'),
            array[pg_temp.pet('3a2')])),
  '22023: El plan no existe o no está disponible', 'ni se contrata');
select pg_temp.login('c1');
update public.subscription_plans set active = true where slug = 'plus';

-- HU5.3: cancelación con beneficios hasta el fin del período ---------------------
select pg_temp.login('a2');
select is(public.subscribe(pg_temp.plan('plus'), array[pg_temp.pet('3a2')]) -> 'plan' ->> 'name',
  'Plus', 'B se suscribe a Plus');
select is(pg_temp.qv('p1', 'a2', '3a2', 'urgencias', 'urgent'),
  '35000,0,3,1500,7000,29500,6825,1365,40175,29500,17500', 'caso 20: Plus en urgencia (versión sin comisión sobre la distancia)');
select is((select concat_ws(',', j ->> 'status', j ->> 'renews', j ->> 'benefits_active')
           from (select public.cancel_subscription() j) x),
  'cancelled,false,true', 'HU5.3: al cancelar no se renueva y los beneficios siguen');
select is(pg_temp.err('select public.cancel_subscription()'),
  '22023: No tienes una suscripción activa', 'no se cancela dos veces');
select is(pg_temp.qv('p2', 'a2', '3a2', 'urgencias', 'urgent'),
  '35000,0,3,1500,7000,29500,6825,1365,40175,29500,17500',
  'caso 21: cancelada dentro del período pagado: sigue sin recargo y con descuento');
-- Fin del período (en fecha de Chile).
reset role;
update public.subscriptions
set started_on = (now() at time zone 'America/Santiago')::date - 30,
    current_period_start = (now() at time zone 'America/Santiago')::date - 30,
    current_period_end = (now() at time zone 'America/Santiago')::date
where owner_id = pg_temp.u('a2');
select pg_temp.login('a2');
set local role authenticated;
select is(public.my_subscription() ->> 'benefits_active', 'false',
  'vencido el período pagado, ya no hay beneficios');
select is(pg_temp.qv('p3', 'a2', '3a2', 'urgencias', 'urgent'),
  '35000,10500,3,1500,0,47000,6825,1365,40175,47000,0',
  'caso 22: vencida la cancelada, se cobra normal');
reset role;
select ok(private.renew_subscriptions() >= 1, 'la renovación procesa los períodos vencidos');
select is((select status || ':' || (ended_at is not null) from public.subscriptions
           where owner_id = pg_temp.u('a2')), 'ended:true', 'la cancelada termina sin renovar');
select is((select count(*)::int from public.payments
           where owner_id = pg_temp.u('a2') and kind = 'subscription'), 1,
  'sin cobro al terminar');
select pg_temp.login('a2');
set local role authenticated;
select is(public.my_subscription(), null, 'terminada, my_subscription es null');
select is(public.subscribe(pg_temp.plan('basico'), array[pg_temp.pet('3a2')]) ->> 'status',
  'active', 'terminada la anterior, puede volver a suscribirse');
select is(public.cancel_subscription() ->> 'status', 'cancelled', 'y cancelar otra vez');
select is((public.subscribe(pg_temp.plan('plus'), array[pg_temp.pet('3a2')]) -> 'plan' ->> 'name'),
  'Plus', 'una cancelada vigente se reemplaza al contratar otro plan');
reset role;
select is((select string_agg(status, ',' order by created_at) from public.subscriptions
           where owner_id = pg_temp.u('a2')), 'ended,ended,active',
  'solo queda una abierta');

-- Renovación simulada de una activa ---------------------------------------------
update public.subscriptions
set started_on = (now() at time zone 'America/Santiago')::date - 31,
    current_period_start = (now() at time zone 'America/Santiago')::date - 31,
    current_period_end = (now() at time zone 'America/Santiago')::date
where owner_id = pg_temp.u('a1');
-- El cobro del alta pasa al período anterior (los pagos son inmutables: solo
-- en este fixture, sin triggers).
set local session_replication_role = replica;
update public.payments set period_start = (now() at time zone 'America/Santiago')::date - 31
where owner_id = pg_temp.u('a1') and kind = 'subscription';
set local session_replication_role = origin;
select private.renew_subscriptions();
select is((select concat_ws(',', status, periods_paid,
             current_period_start = (now() at time zone 'America/Santiago')::date,
             current_period_end = ((now() at time zone 'America/Santiago')::date - 31
                                   + interval '2 months')::date)
           from public.subscriptions where owner_id = pg_temp.u('a1')),
  'active,2,t,t', 'renovada: avanza un período anclado a la fecha de alta');
select is((select count(*)::int from public.payments
           where owner_id = pg_temp.u('a1') and kind = 'subscription'
             and period_start = (now() at time zone 'America/Santiago')::date), 1,
  'cobra el nuevo período (period_start en fecha de Chile)');
select is(private.renew_subscriptions(), 0, 'la renovación es idempotente');
select throws_ok($$ insert into public.payments (owner_id, subscription_id, period_start,
    foundation_id, kind, service_price, platform_fee, foundation_share, vet_payout,
    extra_donation, total)
  values (null, null, null, '00000000-0000-0000-0000-00000000f210', 'subscription',
    4990, 4990, 0, 0, 0, 4990) $$,
  '23514', null, 'un pago de suscripción exige el período');

-- Pago de la visita con descuento: vet sin descuento, sin ver el plan ------------
select pg_temp.login('a1');
set local role authenticated;
select pg_temp.qv('c02', 'a1', '1a1', 'general', 'scheduled');
insert into t_ids values ('vD', pg_temp.book('c02', '1a1', pg_temp.ts('T') + interval '2 hours'));
select pg_temp.login('b1');
select is(public.transition_visit(pg_temp.id('vD'), 'accepted') ->> 'status', 'accepted',
  'el vet acepta la visita con descuento');
select is((select concat_ws(',', j ->> 'service_price', j ->> 'vet_payout', j ? 'quote',
             j::text like '%plan%', j::text like '%subsid%')
           from public.my_visits(50) j where j ->> 'id' = pg_temp.id('vD')::text),
  '31500,27000,f,f,f',
  'el vet ve el precio de lista y su pago, sin el plan ni el subsidio');
reset role;
select is((select count(*)::int from public.visits where id = pg_temp.id('vD')
           and is_preventive), 0, 'una visita con descuento no es preventiva');
select pg_temp.tt(format('update public.visits set scheduled_at = %L::timestamptz,
  slot = tstzrange(%L::timestamptz, %L::timestamptz + interval ''90 minutes'') where id = %L',
  date_trunc('minute', now()) + interval '20 minutes', date_trunc('minute', now()) + interval '20 minutes',
  date_trunc('minute', now()) + interval '20 minutes', pg_temp.id('vD')));
select pg_temp.login('b1');
set local role authenticated;
select public.transition_visit(pg_temp.id('vD'), 'en_route');
select public.transition_visit(pg_temp.id('vD'), 'arrived');
select public.transition_visit(pg_temp.id('vD'), 'in_progress');
reset role;
select pg_temp.tt(format('update public.visits set started_at = now() - interval ''15 minutes'' where id = %L',
  pg_temp.id('vD')));
select pg_temp.login('b1');
set local role authenticated;
select is(public.transition_visit(pg_temp.id('vD'), 'completed') ->> 'status', 'completed',
  'visita completada');
select pg_temp.login('a1');
select is((select concat_ws(',', j ->> 'service_price', j ->> 'platform_fee', j ->> 'vet_payout',
             j ->> 'foundation_share', j ->> 'plan_subsidy', j ->> 'total')
           from (select public.simulate_payment(pg_temp.id('vD')) j) x),
  '28500,4500,27000,900,3000,28500',
  'el dueño paga con descuento; la comisión y el vet salen del precio de lista');
select pg_temp.login('b1');
select is((select service_price || ',' || vet_payout from public.my_payouts(10)
           where visit_id = pg_temp.id('vD')), '31500,27000',
  'la liquidación del vet muestra el precio de lista (no delata el plan)');
reset role;
select is((select string_agg(c.kind || ':' || c.amount, ',' order by c.kind)
           from public.foundation_contributions c join public.payments p on p.id = c.payment_id
           where p.visit_id = pg_temp.id('vD')), 'commission_share:900',
  'la fundación recibe lo mismo que sin plan');

-- Matriz de accesos ---------------------------------------------------------------
select pg_temp.login('a2');
set local role authenticated;
select is((select count(*)::int from public.subscriptions where owner_id = pg_temp.u('a1'))
          + (select count(*)::int from public.subscription_pets sp
             join public.subscriptions s on s.id = sp.subscription_id
             where s.owner_id = pg_temp.u('a1')), 0,
  'otro dueño no ve la suscripción ni las mascotas de A');
select pg_temp.login('a1');
select is((select count(*)::int from public.subscriptions where owner_id = pg_temp.u('a1')), 1,
  'el dueño ve su suscripción');
select is((select count(*)::int from public.subscription_pets), 1,
  'y sus mascotas asociadas');
select pg_temp.login('b1');
select is((select count(*)::int from public.subscriptions)
          + (select count(*)::int from public.subscription_pets), 0,
  'el vet no lee suscripciones');
select is(public.my_subscription(), null, 'my_subscription del vet es null');
select is(pg_temp.err(format('select public.subscribe(%s, %L)', pg_temp.plan('basico'),
            array[pg_temp.pet('1a1')])),
  '42501: Solo un dueño puede suscribirse', 'el vet no se suscribe');
select pg_temp.login('d1');
select is((select count(*)::int from public.subscriptions)
          + (select count(*)::int from public.subscription_pets)
          + (select count(*)::int from public.payments), 0,
  'la fundación no lee suscripciones ni pagos de suscripción');
select is(pg_temp.err('select public.cancel_subscription()'),
  '42501: Solo un dueño tiene suscripciones', 'la fundación no opera suscripciones');
select pg_temp.login('c1');
select is((select count(*)::int from public.subscriptions)
          + (select count(*)::int from public.subscription_pets), 0,
  'el admin no lee suscripciones (minimización)');
select ok((select count(*) from public.payments
           where kind = 'subscription' and owner_id = pg_temp.u('a1')) >= 2,
  'el admin sí ve los pagos de suscripción');
select ok((select count(*) from public.subscription_plans where not active or active) >= 3,
  'el admin lee el catálogo completo');
reset role;
set local role anon;
select throws_ok('select count(*) from public.subscriptions', '42501', null,
  'anon no lee suscripciones');
reset role;

-- Cuenta bloqueada y privacidad ------------------------------------------------------
select pg_temp.login('a4');
set local role authenticated;
select is(public.subscribe(pg_temp.plan('basico'), array[pg_temp.pet('9a4')]) ->> 'status',
  'active', 'D se suscribe antes de pedir el borrado');
select ok(public.export_my_data() -> 'subscriptions' -> 0 -> 'pet_ids' ? pg_temp.pet('9a4')::text,
  'export_my_data incluye la suscripción y sus mascotas');
select is((select jsonb_array_length(public.export_my_data() -> 'payments')), 1,
  'y el pago de la suscripción');
reset role;
insert into public.deletion_requests (user_id, role) values (pg_temp.u('a4'), 'owner');
select pg_temp.login('a4');
set local role authenticated;
select set_config('request.path', '/rpc/my_subscription', true);
select throws_ok('select public.check_request()', '42501', null,
  'cuenta bloqueada: el pre-request frena las RPC de suscripción');
reset role;
update public.subscriptions
set started_on = (now() at time zone 'America/Santiago')::date - 30,
    current_period_start = (now() at time zone 'America/Santiago')::date - 30,
    current_period_end = (now() at time zone 'America/Santiago')::date
where owner_id = pg_temp.u('a4');
select private.renew_subscriptions();
select is((select status from public.subscriptions where owner_id = pg_temp.u('a4')), 'ended',
  'cuenta bloqueada: la suscripción termina sin renovarse');
select is((select count(*)::int from public.payments
           where owner_id = pg_temp.u('a4') and kind = 'subscription'), 1,
  'y sin cobrar otro período');
select private.erase_subject((select id from public.deletion_requests
                              where user_id = pg_temp.u('a4')));
select is((select count(*)::int from public.subscriptions where owner_id = pg_temp.u('a4'))
          + (select count(*)::int from public.subscription_pets where pet_id = pg_temp.pet('9a4')),
  0, 'erase_subject borra las suscripciones y las mascotas asociadas');
select is((select count(*)::int from public.payments p
           where p.kind = 'subscription' and p.owner_id is null and p.subscription_id is null
             and p.period_start is not null and p.service_price = 4990
             and p.created_at = now()), 1,
  'el pago de suscripción se conserva anonimizado (contabilidad)');
select ok(exists (select 1 from public.deletion_targets t
                  join public.deletion_requests d on d.id = t.request_id
                  where d.user_id = pg_temp.u('a4') and t.target like 'subscriptions%'),
  'el borrado registra el paso de las suscripciones');

select * from finish();
rollback;
