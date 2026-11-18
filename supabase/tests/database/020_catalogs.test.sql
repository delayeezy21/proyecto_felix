-- Fase 2: catálogos, tarifas, parámetros de precio, clínicas y auditoría.
begin;
select plan(28);

-- Datos de referencia ----------------------------------------------------------
select is((select count(*)::int from public.regions), 16, '16 regiones');
select is((select count(*)::int from public.communes), 346, '346 comunas');
select is(
  (select count(*)::int from public.communes where region_id = 13), 52,
  'Región Metropolitana con 52 comunas');
select is(
  (select count(*)::int from public.communes where region_id = 16), 21,
  'Ñuble con 21 comunas');
select ok((select count(*) from public.species) >= 8, 'al menos 8 especies');
select ok((select count(*) from public.specialties) >= 10, 'al menos 10 especialidades');
select ok(
  (select count(*) from public.species s
   where not exists (select 1 from public.species_specialties x where x.species_id = s.id)) = 0,
  'toda especie tiene al menos una especialidad');

-- Tarifas y parámetros
select is(
  public.base_tariff(
    (select id from public.species where slug = 'perro'),
    (select id from public.specialties where slug = 'general')),
  26990, 'tarifa general de perro = 26.990');

insert into public.tariffs (specialty_id, species_id, base_price)
values (
  (select id from public.specialties where slug = 'general'),
  (select id from public.species where slug = 'equino'), 50000);
select is(
  public.base_tariff(
    (select id from public.species where slug = 'equino'),
    (select id from public.specialties where slug = 'general')),
  50000, 'la tarifa específica de la especie tiene prioridad');

select is((select commission_pct from public.current_pricing_config()), 15.00::numeric,
  'comisión vigente 15 %');
select is((select foundation_pct from public.current_pricing_config()), 20.00::numeric,
  'fundación 20 % de la comisión');

-- Usuarios ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000002a1', 'dueno-cat@test.local'),
  ('00000000-0000-0000-0000-0000000002c1', 'admin-cat@test.local');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000002a1', 'owner'),
  ('00000000-0000-0000-0000-0000000002c1', 'admin');

create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;

-- Admin ------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000002c1');
set local role authenticated;

insert into public.species (slug, name, sort) values ('caprino', 'Caprinos', 20);
select is((select count(*)::int from public.species where slug = 'caprino'), 1,
  'el admin crea una especie');

update public.species set active = false where slug = 'caprino';
select is((select active from public.species where slug = 'caprino'), false,
  'el admin desactiva una especie');

select throws_ok(
  $$ delete from public.species where slug = 'caprino' $$,
  '42501', null, 'nadie borra especies (se desactivan)');

update public.tariffs set base_price = 27000
where specialty_id = (select id from public.specialties where slug = 'general')
  and species_id is null;
select is(
  public.base_tariff(
    (select id from public.species where slug = 'perro'),
    (select id from public.specialties where slug = 'general')),
  27000, 'el admin cambia una tarifa');

insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee, created_by)
values (12, 25, 30, 500, 5, 5000, '00000000-0000-0000-0000-0000000002c1');
select is((select commission_pct from public.current_pricing_config()), 12.00::numeric,
  'una nueva versión de parámetros pasa a ser la vigente');
select is((select count(*)::int from public.pricing_config), 2,
  'la versión anterior se conserva');

select throws_ok(
  $$ update public.pricing_config set commission_pct = 99 $$,
  '42501', null, 'los parámetros no se editan: se versionan');

select ok(
  (select count(*) from public.admin_audit_log
   where table_name in ('species', 'tariffs', 'pricing_config')
     and actor_id = '00000000-0000-0000-0000-0000000002c1') >= 4,
  'los cambios del admin quedan en admin_audit_log con su autor');

select is((select count(*)::int from public.species where slug = 'caprino'), 1,
  'el admin ve especies inactivas');

reset role;

-- Dueño ------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000002a1');
set local role authenticated;

select is((select count(*)::int from public.species where slug = 'caprino'), 0,
  'el dueño no ve especies inactivas');
select is((select count(*)::int from public.communes), 346, 'el dueño lee las comunas');
select ok((select count(*) from public.emergency_clinics) >= 0,
  'el dueño lee las clínicas activas');

select throws_ok(
  $$ insert into public.species (slug, name) values ('x', 'Hack') $$,
  '42501', null, 'el dueño no crea especies');

update public.tariffs set base_price = 1;
select ok(
  (select min(base_price) from public.tariffs) > 1,
  'el dueño no puede cambiar tarifas (0 filas afectadas)');

select throws_ok(
  $$ insert into public.pricing_config
       (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee)
     values (0, 0, 0, 0, 0, 0) $$,
  '42501', null, 'el dueño no cambia los parámetros económicos');

select is((select count(*)::int from public.admin_audit_log), 0,
  'el dueño no ve el log de auditoría');

reset role;

-- Anónimo ----------------------------------------------------------------------
set local role anon;
select throws_ok($$ select * from public.communes $$, '42501', null,
  'anónimo no lee catálogos');
reset role;

select * from finish();
rollback;
