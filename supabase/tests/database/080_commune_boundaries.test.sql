-- QA-F4-01 y QA-F4-02: la dirección debe estar en Chile y en la comuna elegida
-- (límites comunales BCN/OCHA vía geoBoundaries, CC BY 3.0 IGO).
begin;
select plan(30);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000008a1', 'f4b-dueno@test.local');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000008a1', 'owner');
insert into public.owner_profiles (user_id, display_name, commune_id) values
  ('00000000-0000-0000-0000-0000000008a1', 'Dueña Ficticia',
   (select id from public.communes where name = 'Ñuñoa'));

create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.cid(p_name text) returns integer language sql security definer as $$
  select id from public.communes where name = p_name;
$$;
-- Inserta una dirección del dueño en (lat, lng) con la comuna indicada.
create function pg_temp.addr(p_label text, p_commune text, p_lat float8, p_lng float8)
returns text language sql as $$
  select format(
    $f$ insert into public.addresses (owner_id, label, street_text, commune_id, lat, lng)
        values ('00000000-0000-0000-0000-0000000008a1', %L, 'Calle Ficticia 1', %s, %s, %s) $f$,
    p_label, pg_temp.cid(p_commune), p_lat, p_lng);
$$;

-- Datos de referencia ---------------------------------------------------------
select has_table('public', 'commune_boundaries', 'existe la tabla de límites comunales');
select ok((select relrowsecurity and relforcerowsecurity from pg_class
           where oid = 'public.commune_boundaries'::regclass), 'RLS habilitada y forzada');
select is((select count(*)::int from public.commune_boundaries), 345,
  '345 límites (todas las comunas menos Antártica)');
select is_empty(
  $$ select c.name from public.communes c
     where not exists (select 1 from public.commune_boundaries b where b.commune_id = c.id)
       and c.name <> 'Antártica' $$,
  'toda comuna (salvo Antártica) tiene límite');
select is_empty(
  $$ select c.name from public.commune_boundaries b join public.communes c on c.id = b.commune_id
     where not extensions.st_dwithin(b.area,
       extensions.st_setsrid(extensions.st_makepoint(b.center_lng, b.center_lat), 4326)::extensions.geography, 0) $$,
  'el centro de cada comuna cae dentro de su propio límite');
select ok(has_table_privilege('authenticated', 'public.commune_boundaries', 'select')
      and not has_table_privilege('authenticated', 'public.commune_boundaries', 'insert')
      and not has_table_privilege('authenticated', 'public.commune_boundaries', 'update')
      and not has_table_privilege('anon', 'public.commune_boundaries', 'select'),
  'authenticated solo lee los límites; anon no los ve');
select ok(not has_function_privilege('authenticated',
            'private.point_in_commune(integer, double precision, double precision)', 'execute')
      and not has_function_privilege('authenticated',
            'private.point_in_chile(double precision, double precision)', 'execute'),
  'los helpers de validación no los ejecuta la app');
select ok(has_function_privilege('authenticated',
            'public.communes_at_point(double precision, double precision)', 'execute')
      and not has_function_privilege('anon',
            'public.communes_at_point(double precision, double precision)', 'execute'),
  'communes_at_point solo para authenticated');

-- Validación del guardián (como el dueño) ----------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000008a1');
set local role authenticated;

select throws_ok(pg_temp.addr('Ñuñoa con Arica', 'Arica', -33.4569, -70.5974),
  '22023', 'La ubicación marcada no está en la comuna elegida',
  'QA-F4-02: un punto de Ñuñoa con la comuna de Arica se rechaza');
select throws_ok(pg_temp.addr('Mendoza', 'Los Andes', -32.889, -68.845),
  '22023', 'La ubicación debe estar en Chile', 'QA-F4-01: Mendoza (Argentina) se rechaza');
select throws_ok(pg_temp.addr('Uyuni', 'Ollagüe', -20.4597, -66.8250),
  '22023', 'La ubicación debe estar en Chile', 'QA-F4-01: Uyuni (Bolivia) se rechaza');
select throws_ok(pg_temp.addr('Océano', 'Valparaíso', -33.0, -75.0),
  '22023', 'La ubicación debe estar en Chile', 'un punto en el océano se rechaza');

select lives_ok(pg_temp.addr('Ñuñoa', 'Ñuñoa', -33.4569, -70.5974),
  'un punto de Ñuñoa con su comuna se acepta');
select lives_ok(pg_temp.addr('Plaza de Armas', 'Santiago', -33.4372, -70.6506),
  'un punto válido de Santiago se acepta');
select lives_ok(pg_temp.addr('Puerto Natales', 'Natales', -51.7236, -72.4875),
  'un punto de Natales (comuna extensa del sur) se acepta');
select lives_ok(pg_temp.addr('Hanga Roa', 'Isla de Pascua', -27.1497, -109.4296),
  'Isla de Pascua se acepta');
select lives_ok(pg_temp.addr('San Juan Bautista', 'Juan Fernández', -33.6378, -78.8306),
  'Juan Fernández se acepta');
select lives_ok(pg_temp.addr('Puerto Williams', 'Cabo de Hornos', -54.9341, -67.6087),
  'Puerto Williams (Cabo de Hornos) se acepta');
select lives_ok(pg_temp.addr('Villa Las Estrellas', 'Antártica', -62.2000, -58.9667),
  'el Territorio Chileno Antártico se acepta con la comuna Antártica');
select throws_ok(pg_temp.addr('Antártica con Ñuñoa', 'Ñuñoa', -62.2000, -58.9667),
  '22023', 'La ubicación marcada no está en la comuna elegida',
  'un punto antártico con otra comuna se rechaza');

-- Al editar también se valida (pero cambiar solo el nombre no exige nada).
select throws_ok(
  format($$ update public.addresses set commune_id = %s where label = 'Plaza de Armas' $$,
         pg_temp.cid('Arica')),
  '22023', 'La ubicación marcada no está en la comuna elegida',
  'cambiar la comuna a una incoherente se rechaza');
select throws_ok(
  $$ update public.addresses set lat = -32.889, lng = -68.845 where label = 'Plaza de Armas' $$,
  '22023', 'La ubicación debe estar en Chile', 'mover el punto fuera de Chile se rechaza');
select lives_ok(
  $$ update public.addresses set label = 'Centro' where label = 'Plaza de Armas' $$,
  'editar solo el nombre no vuelve a validar el punto');

-- communes_at_point: propone la comuna -----------------------------------------
select is((select name from public.communes_at_point(-33.4372, -70.6506) limit 1), 'Santiago',
  'Plaza de Armas → Santiago primero');
select is((select distance_m from public.communes_at_point(-33.4372, -70.6506) limit 1), 0::float8,
  'la comuna que contiene el punto viene a distancia 0');
select ok('Ñuñoa' = any (array(select name from public.communes_at_point(-33.4569, -70.5974))),
  'el punto de Ñuñoa propone Ñuñoa');
select ok(not ('Arica' = any (array(select name from public.communes_at_point(-33.4569, -70.5974)))),
  'el punto de Ñuñoa no propone Arica');
select is((select count(*)::int from public.communes_at_point(-32.889, -68.845)), 0,
  'Mendoza no propone ninguna comuna');
select is((select name from public.communes_at_point(-51.7236, -72.4875) limit 1), 'Natales',
  'Puerto Natales → Natales');
select is((select name from public.communes_at_point(-62.2, -58.9667) limit 1), 'Antártica',
  'el Territorio Antártico → Antártica');

select * from finish();
rollback;
