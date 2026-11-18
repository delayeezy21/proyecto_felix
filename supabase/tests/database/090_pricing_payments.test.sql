-- Fase 5: precios (tabla de casos), cotización congelada, pagos simulados,
-- aportes y RLS de fundaciones.
begin;
select plan(106);

-- Fixtures ------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000008a1', 'f5-dueno-a@test.local'),
  ('00000000-0000-0000-0000-0000000008a2', 'f5-dueno-b@test.local'),
  ('00000000-0000-0000-0000-0000000008b1', 'f5-vet@test.local'),
  ('00000000-0000-0000-0000-0000000008c1', 'f5-admin@test.local'),
  ('00000000-0000-0000-0000-0000000008d1', 'f5-fund-x@test.local'),
  ('00000000-0000-0000-0000-0000000008d2', 'f5-fund-y@test.local'),
  ('00000000-0000-0000-0000-0000000008d3', 'f5-no-rol@test.local');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000008a1', 'owner'),
  ('00000000-0000-0000-0000-0000000008a2', 'owner'),
  ('00000000-0000-0000-0000-0000000008b1', 'vet'),
  ('00000000-0000-0000-0000-0000000008c1', 'admin'),
  ('00000000-0000-0000-0000-0000000008d1', 'foundation'),
  ('00000000-0000-0000-0000-0000000008d2', 'foundation'),
  ('00000000-0000-0000-0000-0000000008d3', 'owner');
insert into public.owner_profiles (user_id, display_name, commune_id) values
  ('00000000-0000-0000-0000-0000000008a1', 'Ana Ficticia',
   (select id from public.communes where name = 'Ñuñoa')),
  ('00000000-0000-0000-0000-0000000008a2', 'Beto Ficticio',
   (select id from public.communes where name = 'Providencia'));
insert into public.vet_profiles (user_id, display_name, status) values
  ('00000000-0000-0000-0000-0000000008b1', 'Dra. Ficticia', 'approved');
insert into public.vet_species (vet_id, species_id)
  select '00000000-0000-0000-0000-0000000008b1', id from public.species where slug = 'perro';
insert into public.vet_specialties (vet_id, specialty_id)
  select '00000000-0000-0000-0000-0000000008b1', id from public.specialties where slug = 'general';
-- Origen del vet ≈ 7,99 km al norte de la dirección de A.
insert into public.vet_bases (vet_id, commune_id, lat, lng) values
  ('00000000-0000-0000-0000-0000000008b1',
   (select commune_id from public.communes_at_point(-33.3849, -70.5974) limit 1),
   -33.3849, -70.5974);
-- QA-F5-01: guardamos el desplazamiento aleatorio para probarlo y lo anulamos
-- para que los montos de este test sean deterministas.
create temp table t_fuzz as
  select extensions.st_distance(location, quote_origin) as m from public.vet_bases
  where vet_id = '00000000-0000-0000-0000-0000000008b1';
update public.vet_bases set fuzz_dlat = 0, fuzz_dlng = 0
  where vet_id = '00000000-0000-0000-0000-0000000008b1';
-- Segundo vet compatible, con base válida en Punta Arenas (≈ 2.200 km).
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000008b2', 'f5-vet-lejos@test.local');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000008b2', 'vet');
insert into public.vet_profiles (user_id, display_name, status) values
  ('00000000-0000-0000-0000-0000000008b2', 'Dr. Lejano', 'approved');
insert into public.vet_species (vet_id, species_id)
  select '00000000-0000-0000-0000-0000000008b2', id from public.species where slug = 'perro';
insert into public.vet_specialties (vet_id, specialty_id)
  select '00000000-0000-0000-0000-0000000008b2', id from public.specialties where slug = 'general';
insert into public.vet_bases (vet_id, commune_id, lat, lng) values
  ('00000000-0000-0000-0000-0000000008b2',
   (select id from public.communes where name = 'Punta Arenas'), -53.1638, -70.9171);

-- Fundaciones de prueba: X por defecto, Y alternativa, Z inactiva.
update public.foundations set is_default = false where is_default;
insert into public.foundations (id, name, is_default) values
  ('00000000-0000-0000-0000-00000000f0a1', 'F5 Fundación X', true),
  ('00000000-0000-0000-0000-00000000f0a2', 'F5 Fundación Y', false);
insert into public.foundations (id, name, active) values
  ('00000000-0000-0000-0000-00000000f0a3', 'F5 Fundación Z', false);
insert into public.foundation_members (user_id, foundation_id) values
  ('00000000-0000-0000-0000-0000000008d1', '00000000-0000-0000-0000-00000000f0a1'),
  ('00000000-0000-0000-0000-0000000008d2', '00000000-0000-0000-0000-00000000f0a2');

insert into public.pets (id, owner_id, name, species_id) values
  ('00000000-0000-0000-0000-00000000e0a1', '00000000-0000-0000-0000-0000000008a1', 'Firulais',
   (select id from public.species where slug = 'perro')),
  ('00000000-0000-0000-0000-00000000e0b1', '00000000-0000-0000-0000-0000000008a2', 'Michi',
   (select id from public.species where slug = 'gato'));
insert into public.addresses (id, owner_id, label, street_text, commune_id, lat, lng) values
  ('00000000-0000-0000-0000-00000000e1a1', '00000000-0000-0000-0000-0000000008a1', 'Casa',
   'Av. Ficticia 123', (select id from public.communes where name = 'Ñuñoa'), -33.4569, -70.5974),
  ('00000000-0000-0000-0000-00000000e1b1', '00000000-0000-0000-0000-0000000008a2', 'Depto',
   'Calle Inventada 9', (select id from public.communes where name = 'Providencia'), -33.43, -70.61);

-- Parámetros por defecto vigentes (por si un E2E dejó otra versión).
insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee, effective_from)
values (15, 20, 30, 500, 5, 5000, now() - interval '2 seconds');

create temp table t_ids (k text primary key, v uuid);
grant all on t_ids to authenticated;

create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.spec(p_slug text) returns integer language sql security definer as $$
  select id from public.specialties where slug = p_slug;
$$;
create function pg_temp.id(p_k text) returns uuid language sql as $$
  select v from t_ids where k = p_k;
$$;
-- Caso de precio con la configuración por defecto (15 / 20 / 30 / 500 / 5).
create function pg_temp.pc(
  p_base integer, p_urgent boolean, p_distance_m integer, p_extra integer default 0,
  p_disc numeric default 0, p_waive boolean default false, p_prev boolean default false,
  p_comm numeric default 15, p_fpct numeric default 20, p_upct numeric default 30,
  p_per_km integer default 500, p_free_km integer default 5,
  p_cod boolean default true)
returns text language sql as $$
  select concat_ws(',', b.urgent_surcharge, b.billable_km, b.distance_surcharge, b.discount,
                   b.service_price, b.platform_fee, b.foundation_share, b.vet_payout, b.total)
  from private.price_breakdown(p_base, p_urgent, p_distance_m, p_extra, p_comm, p_fpct,
                               p_upct, p_per_km, p_free_km, p_disc, p_waive, p_prev, p_cod) b;
$$;
grant execute on function pg_temp.spec(text), pg_temp.id(text) to authenticated;

-- Desde la fase 6 la app solo paga visitas completadas (simulate_payment
-- recibe una visita). Para probar el reparto de la fase 5 sin armar una
-- visita, este helper replica el cobro con las funciones internas: consume
-- la cotización (como book_visit) y registra el pago (como pay_visit_simulated).
create function pg_temp.pay(p_q uuid, p_fail boolean default false)
returns jsonb language plpgsql security definer as $$
declare
  v public.quotes;
  p public.payments;
begin
  if p_fail then
    select * into v from public.quotes q
    where q.id = p_q and q.owner_id = auth.uid() and q.consumed_at is null
      and q.expires_at > now();
    if not found then
      raise exception 'La cotización no existe, venció o ya fue usada' using errcode = '22023';
    end if;
  else
    v := private.consume_quote(p_q, auth.uid());
  end if;
  p := private.record_payment(v.owner_id, null, null, v.id, v.foundation_id, 'visit',
    v.service_price, v.platform_fee, v.foundation_share, v.vet_payout, v.extra_donation, p_fail);
  return jsonb_build_object('status', p.status, 'platform_fee', p.platform_fee);
end;
$$;
grant execute on function pg_temp.pay(uuid, boolean) to authenticated;

-- Estructura y privilegios ----------------------------------------------------
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
           where oid in ('public.foundations'::regclass, 'public.foundation_members'::regclass,
                         'public.vet_bases'::regclass, 'public.quotes'::regclass,
                         'public.payments'::regclass, 'public.payment_events'::regclass,
                         'public.foundation_contributions'::regclass)),
  'RLS habilitada y forzada en las tablas de la fase 5');
select is_empty(
  $$ select t || ':' || p from unnest(array['public.quotes', 'public.payments',
       'public.payment_events', 'public.foundation_contributions']) t
     cross join unnest(array['INSERT', 'UPDATE', 'DELETE']) p
     where has_table_privilege('authenticated', t, p)
        or exists (select 1 from information_schema.column_privileges c
                   where c.grantee = 'authenticated' and c.table_schema || '.' || c.table_name = t
                     and c.privilege_type = p) $$,
  'la app no inserta ni modifica cotizaciones, pagos, eventos ni aportes');
select ok(not has_function_privilege('authenticated',
            'private.price_breakdown(integer, boolean, integer, integer, numeric, numeric, numeric, integer, integer, numeric, boolean, boolean, boolean)', 'execute')
      and not has_function_privilege('authenticated',
            'private.quote_for(uuid, uuid, uuid, integer, text, uuid, extensions.geography, uuid, integer)', 'execute')
      and not has_function_privilege('authenticated', 'private.consume_quote(uuid, uuid)', 'execute'),
  'el cálculo interno y el consumo de cotizaciones no los ejecuta la app');
select ok(not has_function_privilege('anon', 'public.quote_visit(uuid, uuid, integer, text, uuid, uuid, integer)', 'execute')
      and not has_function_privilege('anon', 'public.simulate_payment(uuid, boolean)', 'execute')
      and not has_function_privilege('anon', 'public.foundation_summary(integer)', 'execute'),
  'anon no cotiza, no paga ni ve resúmenes');
select is_empty(
  $$ select c.conrelid::regclass || '.' || a.attname
     from pg_constraint c
     join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f'
       and c.conrelid in ('public.foundations'::regclass, 'public.foundation_members'::regclass,
                          'public.vet_bases'::regclass, 'public.quotes'::regclass,
                          'public.payments'::regclass, 'public.payment_events'::regclass,
                          'public.foundation_contributions'::regclass,
                          'public.owner_profiles'::regclass)
       and not exists (select 1 from pg_index i
                       where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1]) $$,
  'toda FK de la fase 5 tiene un índice');
select ok(not has_column_privilege('authenticated', 'public.foundations', 'is_default', 'insert')
      and has_column_privilege('authenticated', 'public.owner_profiles', 'foundation_id', 'update'),
  'grants por columna: el dueño elige fundación; is_default solo por actualización del admin');

-- Redondeo explícito ----------------------------------------------------------
select is(private.clp_round(1500.5), 1501, 'clp_round: 0,5 sube');
select is(private.clp_round(1500.49), 1500, 'clp_round: bajo 0,5 baja');

-- Tabla de casos de precio (HU4.1). Formato:
-- urgencia,km,recargo km,descuento,servicio,comisión,fundación,vet,total
select is(pg_temp.pc(30000, false, null), '0,0,0,0,30000,4500,900,25500,30000',
  'caso 01: ejemplo del SPEC ($30.000 → 4.500 / 900 / 25.500)');
select is(pg_temp.pc(25000, false, null), '0,0,0,0,25000,3750,750,21250,25000',
  'caso 02: agendada general sin distancia');
select is(pg_temp.pc(25000, true, null), '7500,0,0,0,32500,4875,975,27625,32500',
  'caso 03: urgencia +30 % de la base');
select is(pg_temp.pc(35000, true, null), '10500,0,0,0,45500,6825,1365,38675,45500',
  'caso 04: urgencia sobre tarifa de $35.000');
select is(pg_temp.pc(25000, false, 5000), '0,0,0,0,25000,3750,750,21250,25000',
  'caso 05: 5,000 km exactos no pagan recargo');
select is(pg_temp.pc(25000, false, 5001), '0,1,500,0,25500,3825,765,21675,25500',
  'caso 06: 5,001 km cobra 1 km (redondeo hacia arriba)');
select is(pg_temp.pc(25000, false, 12300), '0,8,4000,0,29000,4350,870,24650,29000',
  'caso 07: 12,3 km cobra 8 km');
select is(pg_temp.pc(30000, true, 8000), '9000,3,1500,0,40500,6075,1215,34425,40500',
  'caso 08: urgencia + distancia');
select is(pg_temp.pc(30000, false, null, 2000), '0,0,0,0,30000,4500,900,25500,32000',
  'caso 09: donación extra suma al total, no a la comisión');
select is(pg_temp.pc(25000, false, null, 0, 10), '0,0,0,2500,22500,3375,675,19125,22500',
  'caso 10: suscripción Básico (10 % de descuento sobre la base)');
select is(pg_temp.pc(35000, true, null, 0, 20, true), '0,0,0,7000,28000,4200,840,23800,28000',
  'caso 11: suscripción Plus (20 % y sin recargo de urgencia)');
select is(pg_temp.pc(25000, true, null, 0, 10), '7500,0,0,2500,30000,4500,900,25500,30000',
  'caso 12: Básico en urgencia sí paga el recargo');
select is(pg_temp.pc(20000, false, null, 0, 0, false, true), '0,0,0,20000,0,0,0,0,0',
  'caso 13: preventiva incluida en el plan (base $0)');
select is(pg_temp.pc(20000, false, null, 1000, 0, false, true), '0,0,0,20000,0,0,0,0,1000',
  'caso 14: preventiva incluida + donación');
select is(pg_temp.pc(25333, false, null), '0,0,0,0,25333,3800,760,21533,25333',
  'caso 15: redondeo de la comisión (3.799,95 → 3.800)');
select is(pg_temp.pc(10010, false, null), '0,0,0,0,10010,1502,300,8508,10010',
  'caso 16: redondeo mitad hacia arriba (1.501,5 → 1.502)');
select is(pg_temp.pc(25001, true, null), '7500,0,0,0,32501,4875,975,27626,32501',
  'caso 17: redondeo del recargo de urgencia (7.500,3 → 7.500)');
select is(pg_temp.pc(20000, true, 4500, 0, 0, false, false, 12.5, 25, 50, 700, 3),
  '10000,2,1400,0,31400,3925,981,27475,31400',
  'caso 18: configuración distinta (12,5 % / 25 % / 50 % / $700 / 3 km)');
select is(pg_temp.pc(20000, false, null, 0, 0, false, false, 0, 20), '0,0,0,0,20000,0,0,20000,20000',
  'caso 19: comisión 0 % (todo al vet)');
select is(pg_temp.pc(25000, true, 9999, 500, 20, true), '0,5,2500,5000,22500,3375,675,19125,23000',
  'caso 20: Plus en urgencia a 10 km con donación');
-- Consulta general a domicilio (decisión de negocio): $26.990 todo incluido
-- hasta 5 km → comisión 4.049, fundación 810, vet 22.941.
select is(public.base_tariff((select id from public.species where slug = 'perro'),  pg_temp.spec('general')), 26990, 'la tarifa general vigente es $26.990 (dato de referencia)');
select is(pg_temp.pc(26990, false, 4999), '0,0,0,0,26990,4049,810,22941,26990',
  'caso 21: consulta general $26.990 hasta 5 km → vet $22.941 (85 %)');
select is(pg_temp.pc(26990, false, 8000), '0,3,1500,0,28490,4274,855,24216,28490',
  'caso 22: consulta general a 8 km (+3 km × $500)');
select is(pg_temp.pc(26990, false, 8000, 0, 0, false, false, 15, 20, 30, 500, 5, false),
  '0,3,1500,0,28490,4049,810,24441,28490',
  'caso 23: opción sin comisión sobre la distancia (el recargo va 100 % al vet)');

-- Cotización por RPC (dueño A) -----------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000008a1');
set local role authenticated;

insert into t_ids select 'q1', (public.quote_visit(
  '00000000-0000-0000-0000-00000000e0a1', '00000000-0000-0000-0000-00000000e1a1',
  pg_temp.spec('general'), 'scheduled', '00000000-0000-0000-0000-0000000008b1', null, 1000)
  ->> 'quote_id')::uuid;
select is(
  (select concat_ws(',', billable_km, distance_surcharge, service_price, platform_fee,
                    foundation_share, vet_payout, extra_donation, total)
   from public.quotes where id = pg_temp.id('q1')),
  '3,1500,28490,4274,855,24216,1000,29490',
  'quote_visit: tarifa general $26.990 + 3 km (PostGIS, ≈7,99 km) + donación');
select is((select foundation_id from public.quotes where id = pg_temp.id('q1')),
  '00000000-0000-0000-0000-00000000f0a1'::uuid, 'sin elección se usa la fundación por defecto');
select is((public.quote_visit('00000000-0000-0000-0000-00000000e0a1',
  '00000000-0000-0000-0000-00000000e1a1', pg_temp.spec('general'), 'scheduled',
  '00000000-0000-0000-0000-0000000008b1') ->> 'distance_km')::numeric, 8.0,
  'al cliente solo se le muestra la distancia redondeada al km (desde el origen aproximado)');
select is((select pricing_config_id from public.quotes where id = pg_temp.id('q1')),
  (select id from public.current_pricing_config()), 'la cotización guarda la versión de parámetros');
select ok((select expires_at > now() + interval '29 minutes' and consumed_at is null
           from public.quotes where id = pg_temp.id('q1')), 'vigencia de 30 minutos, sin usar');

insert into t_ids select 'q_urg', (public.quote_visit(
  '00000000-0000-0000-0000-00000000e0a1', '00000000-0000-0000-0000-00000000e1a1',
  pg_temp.spec('general'), 'urgent') ->> 'quote_id')::uuid;
select is(
  (select concat_ws(',', billable_km = 0, urgent_surcharge, service_price, total)
   from public.quotes where id = pg_temp.id('q_urg')),
  't,8097,35087,35087', 'urgencia sin vet asignado: recargo 30 %, distancia pendiente');

-- El cliente no puede manipular el precio.
select throws_ok(
  $$ insert into public.quotes (owner_id, species_id, specialty_id, commune_id, mode,
       pricing_config_id, foundation_id, base_price, urgent_surcharge, billable_km,
       distance_surcharge, discount, service_price, platform_fee, foundation_share,
       vet_payout, extra_donation, total, expires_at)
     values ('00000000-0000-0000-0000-0000000008a1', 1, 1, 1, 'scheduled', 1,
       '00000000-0000-0000-0000-00000000f0a1', 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1, now()) $$,
  '42501', null, 'el dueño no inserta cotizaciones a mano');
select throws_ok(
  $$ update public.quotes set total = 1 where id = pg_temp.id('q1') $$,
  '42501', null, 'el dueño no modifica montos de una cotización');
select throws_ok(
  $$ select public.quote_visit('00000000-0000-0000-0000-00000000e0a1',
       '00000000-0000-0000-0000-00000000e1a1', pg_temp.spec('general'), 'scheduled',
       p_total => 1) $$,
  '42883', null, 'quote_visit no acepta montos del cliente');
select throws_ok(
  $$ insert into public.payments (owner_id, foundation_id, kind, service_price,
       platform_fee, foundation_share, vet_payout, extra_donation, total)
     values ('00000000-0000-0000-0000-0000000008a1', '00000000-0000-0000-0000-00000000f0a1',
       'visit', 1, 0, 0, 1, 0, 1) $$,
  '42501', null, 'el dueño no inserta pagos a mano');
select throws_ok(
  $$ select public.quote_visit('00000000-0000-0000-0000-00000000e0b1',
       '00000000-0000-0000-0000-00000000e1a1', pg_temp.spec('general'), 'scheduled') $$,
  '22023', 'La mascota no existe o no está activa', 'no se cotiza con la mascota de otro dueño');
select throws_ok(
  $$ select public.quote_visit('00000000-0000-0000-0000-00000000e0a1',
       '00000000-0000-0000-0000-00000000e1b1', pg_temp.spec('general'), 'scheduled') $$,
  '22023', 'La dirección no existe o no está activa', 'no se cotiza con la dirección de otro dueño');
select throws_ok(
  $$ select public.quote_visit('00000000-0000-0000-0000-00000000e0a1',
       '00000000-0000-0000-0000-00000000e1a1', pg_temp.spec('equina'), 'scheduled') $$,
  '22023', 'La especialidad no atiende a esta especie', 'especialidad incompatible con la especie');
select throws_ok(
  $$ select public.quote_visit('00000000-0000-0000-0000-00000000e0a1',
       '00000000-0000-0000-0000-00000000e1a1', pg_temp.spec('general'), 'scheduled',
       null, null, -1) $$,
  '22023', null, 'donación negativa rechazada');
select throws_ok(
  $$ select public.quote_visit('00000000-0000-0000-0000-00000000e0a1',
       '00000000-0000-0000-0000-00000000e1a1', pg_temp.spec('general'), 'express') $$,
  '22023', 'Tipo de visita no válido', 'tipo de visita inválido');
select throws_ok(
  $$ select public.quote_visit('00000000-0000-0000-0000-00000000e0a1',
       '00000000-0000-0000-0000-00000000e1a1', pg_temp.spec('general'), 'scheduled',
       null, '00000000-0000-0000-0000-00000000f0a3') $$,
  '22023', 'La fundación no existe o no está activa', 'no se elige una fundación inactiva');
select is((select count(*)::int from public.vet_bases), 0,
  'el dueño no ve el punto de partida del vet');

-- QA-F5-01: la distancia exacta no es legible; QA-F5-02: radio máximo.
select throws_ok($$ select distance_m from public.quotes limit 1 $$,
  '42501', null, 'el dueño no lee quotes.distance_m (grant por columna)');
select lives_ok($$ select total, billable_km from public.quotes limit 1 $$,
  'el dueño sí lee los montos de sus cotizaciones');
select throws_ok(
  $$ select public.quote_visit('00000000-0000-0000-0000-00000000e0a1',
       '00000000-0000-0000-0000-00000000e1a1', pg_temp.spec('general'), 'scheduled',
       '00000000-0000-0000-0000-0000000008b2') $$,
  '22023', 'El veterinario está fuera del radio de atención (máximo 30 km)',
  'un vet a ~2.200 km queda fuera del radio máximo (pricing_config.max_distance_km)');

-- QA-F5-02: la base del vet se valida contra los límites comunales.
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000008b1');
set local role authenticated;
select throws_ok(
  $$ update public.vet_bases set lat = -32.889, lng = -68.845
     where vet_id = '00000000-0000-0000-0000-0000000008b1' $$,
  '22023', 'La ubicación debe estar en Chile', 'base del vet fuera de Chile (Mendoza) rechazada');
select throws_ok(
  $$ update public.vet_bases set commune_id = (select id from public.communes where name = 'Punta Arenas')
     where vet_id = '00000000-0000-0000-0000-0000000008b1' $$,
  '22023', 'La ubicación marcada no está en la comuna elegida', 'base con comuna incoherente rechazada');
select throws_ok(
  $$ update public.vet_bases set fuzz_dlat = 0
     where vet_id = '00000000-0000-0000-0000-0000000008b1' $$,
  '42501', null, 'el vet no puede anular su desplazamiento aleatorio');
reset role;
select ok((select m between 990 and 2010 from t_fuzz),
  'el origen aproximado queda a 1–2 km de la base real (QA-F5-01)');
select ok(not has_column_privilege('authenticated', 'public.quotes', 'distance_m', 'select')
      and has_column_privilege('authenticated', 'public.quotes', 'total', 'select'),
  'privilegios por columna en quotes: sin distance_m');
select pg_temp.login('00000000-0000-0000-0000-0000000008a1');
set local role authenticated;

-- El dueño elige su fundación en el perfil.
select throws_ok(
  $$ update public.owner_profiles set foundation_id = '00000000-0000-0000-0000-00000000f0a3'
     where user_id = '00000000-0000-0000-0000-0000000008a1' $$,
  '22023', null, 'no puede elegir una fundación inactiva en el perfil');
select lives_ok(
  $$ update public.owner_profiles set foundation_id = '00000000-0000-0000-0000-00000000f0a2'
     where user_id = '00000000-0000-0000-0000-0000000008a1' $$,
  'elige la fundación Y en su perfil');
select is((public.quote_visit('00000000-0000-0000-0000-00000000e0a1',
  '00000000-0000-0000-0000-00000000e1a1', pg_temp.spec('general'), 'scheduled')
  ->> 'foundation_name'), 'F5 Fundación Y', 'la cotización usa la fundación del perfil');
select is((select count(*)::int from public.foundations where id = '00000000-0000-0000-0000-00000000f0a3'), 0,
  'el dueño no ve fundaciones inactivas');

-- Otros roles no cotizan.
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000008b1');
set local role authenticated;
select throws_ok(
  $$ select public.quote_visit('00000000-0000-0000-0000-00000000e0a1',
       '00000000-0000-0000-0000-00000000e1a1', pg_temp.spec('general'), 'scheduled') $$,
  '42501', null, 'un vet no cotiza');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000008d1');
set local role authenticated;
select throws_ok(
  $$ select public.quote_visit('00000000-0000-0000-0000-00000000e0a1',
       '00000000-0000-0000-0000-00000000e1a1', pg_temp.spec('general'), 'scheduled') $$,
  '42501', null, 'una fundación no cotiza');

-- Precio congelado: el admin cambia la configuración después de cotizar -------
reset role;
insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee, effective_from)
values (20, 50, 40, 800, 2, 6000, now() - interval '1 second');

select pg_temp.login('00000000-0000-0000-0000-0000000008a1');
set local role authenticated;
select is((select platform_fee from public.quotes where id = pg_temp.id('q1')), 4274,
  'la cotización existente conserva su comisión tras el cambio de parámetros');
select is((public.quote_visit('00000000-0000-0000-0000-00000000e0a1',
  '00000000-0000-0000-0000-00000000e1a1', pg_temp.spec('general'), 'scheduled',
  '00000000-0000-0000-0000-0000000008b1') ->> 'platform_fee')::int, 6358,
  'una cotización nueva usa la versión vigente (26.990 + 6 km × 800 = 31.790 × 20 % = 6.358)');

-- Pago simulado -----------------------------------------------------------------
-- Fase 6: la app ya no paga cotizaciones sueltas (solo visitas completadas).
select throws_ok($$ select public.simulate_payment(pg_temp.id('q1')) $$,
  '22023', 'La visita no existe', 'simulate_payment ya no acepta una cotización');
select is((pg_temp.pay(pg_temp.id('q1')) ->> 'platform_fee')::int, 4274,
  'el pago usa el precio congelado de la cotización');
select is((select concat_ws(',', status, provider, service_price, platform_fee,
                            foundation_share, vet_payout, extra_donation, total, foundation_id)
           from public.payments where quote_id = pg_temp.id('q1')),
  'simulated_paid,simulated,28490,4274,855,24216,1000,29490,00000000-0000-0000-0000-00000000f0a1',
  'pago simulado con el reparto completo y la fundación de la cotización');
select ok((select consumed_at is not null from public.quotes where id = pg_temp.id('q1')),
  'la cotización queda usada');
select throws_ok($$ select pg_temp.pay(pg_temp.id('q1')) $$,
  '22023', 'La cotización ya fue usada', 'una cotización no se paga dos veces');
select throws_ok(
  $$ update public.payments set total = 1 where quote_id = pg_temp.id('q1') $$,
  '42501', null, 'el dueño no modifica pagos');

-- Pago fallido: queda registrado, sin aportes, y la cotización sigue usable.
select is((pg_temp.pay(pg_temp.id('q_urg'), true) ->> 'status'), 'simulated_failed',
  'se puede simular un pago rechazado');
select ok((select consumed_at is null from public.quotes where id = pg_temp.id('q_urg')),
  'un pago fallido no consume la cotización');
select is((pg_temp.pay(pg_temp.id('q_urg')) ->> 'status'), 'simulated_paid',
  'reintento exitoso después del fallo');
select is((select count(*)::int from public.payments), 3, 'el dueño A ve sus 3 pagos');
select is((select count(*)::int from public.foundation_contributions), 0,
  'el dueño no ve los aportes');

-- Auditoría y aportes (como postgres) -----------------------------------------
reset role;
select is(
  (select string_agg(coalesce(e.from_status, '-') || '>' || e.to_status, ' ' order by e.id)
   from public.payment_events e join public.payments p on p.id = e.payment_id
   where p.quote_id = pg_temp.id('q1')),
  '->pending pending>simulated_paid', 'historial de estados del pago');
select is(
  (select string_agg(c.kind || ':' || c.amount, ' ' order by c.kind)
   from public.foundation_contributions c join public.payments p on p.id = c.payment_id
   where p.quote_id = pg_temp.id('q1')),
  'commission_share:855 donation:1000', 'aportes: 20 % de la comisión + 100 % de la donación');
select is(
  (select count(*)::int from public.foundation_contributions c
   join public.payments p on p.id = c.payment_id where p.status = 'simulated_failed'), 0,
  'un pago fallido no genera aportes');
select throws_ok(
  $$ update public.payments set foundation_share = 0 where quote_id = pg_temp.id('q1') $$,
  '42501', 'Los montos de un pago no se modifican', 'montos inmutables incluso para SQL interno');
select throws_ok(
  $$ update public.payments set status = 'pending', paid_at = null
     where quote_id = pg_temp.id('q1') and status = 'simulated_paid' $$,
  '22023', null, 'un pago pagado no vuelve a pendiente');
select throws_ok(
  $$ update public.quotes set base_price = 1 where id = pg_temp.id('q1') $$,
  '42501', 'Una cotización no se modifica', 'cotización inmutable incluso para SQL interno');

-- Cotización vencida.
insert into public.quotes (id, owner_id, species_id, specialty_id, commune_id, mode,
  pricing_config_id, foundation_id, base_price, urgent_surcharge, billable_km,
  distance_surcharge, discount, service_price, platform_fee, foundation_share,
  vet_payout, extra_donation, total, created_at, expires_at)
values ('00000000-0000-0000-0000-00000000e2a1', '00000000-0000-0000-0000-0000000008a1',
  (select id from public.species where slug = 'perro'), pg_temp.spec('general'),
  (select id from public.communes where name = 'Ñuñoa'), 'scheduled',
  (select id from public.current_pricing_config()), '00000000-0000-0000-0000-00000000f0a1',
  25000, 0, 0, 0, 0, 25000, 3750, 750, 21250, 0, 25000,
  now() - interval '2 hours', now() - interval '1 hour');
select pg_temp.login('00000000-0000-0000-0000-0000000008a1');
set local role authenticated;
select throws_ok($$ select pg_temp.pay('00000000-0000-0000-0000-00000000e2a1') $$,
  '22023', 'La cotización venció. Vuelve a cotizar.', 'no se paga una cotización vencida');

-- Otros roles no ven pagos ajenos ---------------------------------------------
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000008a2');
set local role authenticated;
select is((select count(*)::int from public.payments), 0, 'el dueño B no ve pagos de A');
select is((select count(*)::int from public.quotes), 0, 'el dueño B no ve cotizaciones de A');
select throws_ok($$ select pg_temp.pay(pg_temp.id('q_urg')) $$,
  '22023', null, 'el dueño B no paga una cotización de A');

reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000008b1');
set local role authenticated;
select is((select count(*)::int from public.payments), 0, 'el vet no ve pagos (fase 6: solo los suyos)');
select is((select count(*)::int from public.foundation_contributions), 0, 'el vet no ve aportes');

-- Fundación X: solo totales agregados de la suya ------------------------------
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000008d1');
set local role authenticated;
select is((select count(*)::int from public.payments), 0, 'la fundación no ve pagos');
select is((select count(*)::int from public.foundation_contributions), 0,
  'la fundación no ve filas de aportes (solo agregados)');
select is((select count(*)::int from public.payment_events), 0, 'la fundación no ve eventos de pago');
select is((select count(*)::int from public.owner_profiles), 0, 'la fundación no ve dueños');
-- X recibió: q1 (795 + 1000) y q_urg (fundación Y del perfil no aplica: q_urg
-- se cotizó antes de elegir Y → X): comisión 35.087 × 15 % = 5.263 → 1.053.
select is(
  (select concat_ws(',', commission_total, donation_total, total) from public.foundation_summary()),
  '1908,1000,2908', 'la fundación X ve sus totales del mes (comisión y donación)');
select is((select count(*)::int from public.foundation_summary()), 1,
  'el resumen es una fila por mes, sin detalle de pagos');
select is((select name from public.foundations where id = (select private.current_foundation_id())),
  'F5 Fundación X', 'el miembro identifica su fundación');

reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000008d2');
set local role authenticated;
select is((select count(*)::int from public.foundation_summary()), 0,
  'la fundación Y no ve los aportes de X');

reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000008a1');
set local role authenticated;
select is((select count(*)::int from public.foundation_summary()), 0,
  'un dueño no obtiene resúmenes de fundaciones');

-- Admin: ve todo y gestiona la fundación por defecto ----------------------------
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000008c1');
set local role authenticated;
select ok((select count(*) >= 3 from public.payments), 'el admin ve los pagos');
select ok((select count(*) >= 3 from public.foundation_contributions), 'el admin ve los aportes');
select lives_ok($$ select public.set_default_foundation('00000000-0000-0000-0000-00000000f0a2') $$,
  'el admin cambia la fundación por defecto');
select is((select string_agg(name, ',') from public.foundations where is_default), 'F5 Fundación Y',
  'hay exactamente una fundación por defecto');
select throws_ok(
  $$ update public.foundations set active = false where id = '00000000-0000-0000-0000-00000000f0a2' $$,
  '23514', null, 'no se desactiva la fundación por defecto');
select throws_ok(
  $$ insert into public.foundation_members (user_id, foundation_id)
     values ('00000000-0000-0000-0000-0000000008d3', '00000000-0000-0000-0000-00000000f0a1') $$,
  '22023', 'El usuario no tiene el rol fundación', 'un miembro debe tener el rol fundación');
select ok(exists (select 1 from public.admin_audit_log where table_name = 'foundations'
                  and row_pk = '00000000-0000-0000-0000-00000000f0a2' and action = 'UPDATE'),
  'los cambios del admin en fundaciones quedan auditados');

reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000008a1');
set local role authenticated;
select throws_ok($$ select public.set_default_foundation('00000000-0000-0000-0000-00000000f0a1') $$,
  '42501', null, 'un dueño no cambia la fundación por defecto');
select is((select count(*)::int from public.foundations where name like 'F5 %' and active), 2,
  'el dueño ve las fundaciones activas para elegir');

reset role;
select * from finish();
rollback;
