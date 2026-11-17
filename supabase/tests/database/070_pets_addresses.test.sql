-- Fase 4: mascotas y direcciones (RLS, privilegios, validaciones, PostGIS).
begin;
select plan(48);

-- Fixtures ------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000007a1', 'f4-dueno-a@test.local'),
  ('00000000-0000-0000-0000-0000000007a2', 'f4-dueno-b@test.local'),
  ('00000000-0000-0000-0000-0000000007b1', 'f4-vet@test.local'),
  ('00000000-0000-0000-0000-0000000007c1', 'f4-admin@test.local');
insert into public.user_roles (user_id, role) values
  ('00000000-0000-0000-0000-0000000007a1', 'owner'),
  ('00000000-0000-0000-0000-0000000007a2', 'owner'),
  ('00000000-0000-0000-0000-0000000007b1', 'vet'),
  ('00000000-0000-0000-0000-0000000007c1', 'admin');
insert into public.owner_profiles (user_id, display_name, commune_id) values
  ('00000000-0000-0000-0000-0000000007a1', 'Ana Ficticia',
   (select id from public.communes where name = 'Ñuñoa')),
  ('00000000-0000-0000-0000-0000000007a2', 'Beto Ficticio',
   (select id from public.communes where name = 'Providencia'));
insert into public.vet_profiles (user_id, display_name, status) values
  ('00000000-0000-0000-0000-0000000007b1', 'Dra. Ficticia', 'approved');

-- Especie inactiva para probar la validación del catálogo.
update public.species set active = false where slug = 'otro_exotico';

create function pg_temp.login(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.sp(p_slug text) returns integer language sql security definer as $$
  select id from public.species where slug = p_slug;
$$;
create function pg_temp.br(p_slug text, p_name text) returns integer language sql as $$
  select b.id from public.breeds b join public.species s on s.id = b.species_id
  where s.slug = p_slug and b.name = p_name;
$$;
create function pg_temp.pet_a() returns uuid language sql security definer as $$
  select id from public.pets
  where owner_id = '00000000-0000-0000-0000-0000000007a1' and name like 'Firu%';
$$;
create function pg_temp.addr_a() returns uuid language sql security definer as $$
  select id from public.addresses
  where owner_id = '00000000-0000-0000-0000-0000000007a1' and label = 'Casa';
$$;
grant execute on function pg_temp.sp(text), pg_temp.br(text, text) to authenticated, anon;

-- Estructura, privilegios e índices -------------------------------------------
select has_table('public', 'pets', 'existe pets');
select has_table('public', 'addresses', 'existe addresses');
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
           where oid in ('public.pets'::regclass, 'public.addresses'::regclass)),
  'RLS habilitada y forzada en pets y addresses');
select ok(not has_table_privilege('authenticated', 'public.pets', 'delete')
      and not has_table_privilege('authenticated', 'public.addresses', 'delete'),
  'authenticated no borra mascotas ni direcciones (se desactivan)');
select ok(not has_table_privilege('anon', 'public.pets', 'select')
      and not has_table_privilege('anon', 'public.addresses', 'select'),
  'anon no lee mascotas ni direcciones');
select ok(not has_column_privilege('authenticated', 'public.pets', 'owner_id', 'update')
      and not has_column_privilege('authenticated', 'public.addresses', 'owner_id', 'update')
      and not has_column_privilege('authenticated', 'public.addresses', 'location', 'insert')
      and not has_column_privilege('authenticated', 'public.pets', 'created_at', 'update'),
  'UPDATE e INSERT solo por columna (sin owner_id, location ni fechas)');
select ok(exists (select 1 from pg_indexes where schemaname = 'public'
                  and tablename = 'addresses' and indexdef ilike '%using gist (location)%'),
  'índice GiST sobre addresses.location');
select is_empty(
  $$ select c.conrelid::regclass || '.' || a.attname
     from pg_constraint c
     join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
     where c.contype = 'f' and c.conrelid in ('public.pets'::regclass, 'public.addresses'::regclass)
       and not exists (select 1 from pg_index i
                       where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1]) $$,
  'toda FK de pets y addresses tiene un índice');
select ok(not has_function_privilege('authenticated',
            'private.address_approx(uuid, extensions.geography)', 'execute')
      and not has_function_privilege('anon',
            'private.address_approx(uuid, extensions.geography)', 'execute'),
  'el helper de ubicación aproximada no lo ejecuta la app (fase 6)');

-- Dueño A: crea, edita y desactiva mascotas -----------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000007a1');
set local role authenticated;

select lives_ok(
  $$ insert into public.pets (owner_id, name, species_id, breed_id, sex,
       birth_date_approx, sterilized, microchip)
     values ('00000000-0000-0000-0000-0000000007a1',
       ' Firulais ', pg_temp.sp('perro'), pg_temp.br('perro', 'Beagle'), 'male',
       date '2020-03-01', true, '152000000000001') $$,
  'el dueño registra una mascota con raza y microchip');
select is((select name from public.pets), 'Firulais', 'el nombre se guarda recortado');
select lives_ok(
  $$ insert into public.pets (owner_id, name, species_id, sex)
     values ('00000000-0000-0000-0000-0000000007a1', 'Pío', pg_temp.sp('ave'), 'unknown') $$,
  'la raza es opcional (especies sin razas en el catálogo)');

select throws_ok(
  $$ insert into public.pets (owner_id, name, species_id)
     values ('00000000-0000-0000-0000-0000000007a1', 'X', pg_temp.sp('otro_exotico')) $$,
  '22023', 'La especie no existe o no está activa', 'la especie debe estar activa (HU1.2)');
select throws_ok(
  $$ insert into public.pets (owner_id, name, species_id)
     values ('00000000-0000-0000-0000-0000000007a1', 'X', 999999) $$,
  '22023', 'La especie no existe o no está activa', 'la especie debe existir (HU1.2)');
select throws_ok(
  $$ insert into public.pets (owner_id, name, species_id, breed_id)
     values ('00000000-0000-0000-0000-0000000007a1', 'X', pg_temp.sp('gato'),
             pg_temp.br('perro', 'Beagle')) $$,
  '22023', null, 'la raza debe corresponder a la especie');
select throws_ok(
  $$ insert into public.pets (owner_id, name, species_id, birth_date_approx)
     values ('00000000-0000-0000-0000-0000000007a1', 'X', pg_temp.sp('gato'),
             current_date + 30) $$,
  '22023', 'La fecha de nacimiento no puede ser futura', 'la fecha de nacimiento no es futura');
select throws_ok(
  $$ insert into public.pets (owner_id, name, species_id, microchip)
     values ('00000000-0000-0000-0000-0000000007a1', 'X', pg_temp.sp('gato'), '12AB') $$,
  '23514', null, 'el microchip tiene 15 dígitos');
select throws_ok(
  $$ insert into public.pets (owner_id, name, species_id)
     values ('00000000-0000-0000-0000-0000000007a2', 'Intrusa', pg_temp.sp('gato')) $$,
  '42501', null, 'no crea mascotas a nombre de otro dueño');
select throws_ok(
  $$ insert into public.pets (owner_id, name, species_id, active)
     values ('00000000-0000-0000-0000-0000000007a1', 'X', pg_temp.sp('gato'), false) $$,
  '42501', null, 'no fija columnas fuera de la lista (active al crear)');

update public.pets set name = 'Firu', sterilized = false
 where id = (select pg_temp.pet_a());
select is((select name from public.pets where id = (select pg_temp.pet_a())),
  'Firu', 'el dueño edita su mascota');
select throws_ok(
  $$ update public.pets set owner_id = '00000000-0000-0000-0000-0000000007a2' $$,
  '42501', null, 'no reasigna la mascota a otro dueño');
select throws_ok(
  $$ delete from public.pets $$, '42501', null, 'no borra mascotas');
update public.pets set active = false where name = 'Pío';
select is((select count(*)::int from public.pets where not active), 1,
  'el dueño desactiva una mascota (no se borra)');

-- Direcciones del dueño A -------------------------------------------------------
select lives_ok(
  $$ insert into public.addresses (owner_id, label, street_text, details, commune_id, lat, lng)
     values ('00000000-0000-0000-0000-0000000007a1',
       'Casa', 'Av. Ficticia 123', ' Depto 4 ', (select id from public.communes where name = 'Ñuñoa'),
       -33.4569, -70.5974) $$,
  'el dueño guarda una dirección con coordenadas');
select is((select round(extensions.st_y(location::extensions.geometry)::numeric, 4)
           from public.addresses), -33.4569::numeric,
  'location (geography) se deriva de lat/lng');
select is((select details from public.addresses), 'Depto 4', 'los detalles se recortan');
select throws_ok(
  $$ insert into public.addresses (owner_id, label, street_text, commune_id, lat, lng)
     values ('00000000-0000-0000-0000-0000000007a1', 'Lejos', 'Calle Falsa 1',
       (select id from public.communes where name = 'Ñuñoa'), 40.4, -3.7) $$,
  '23514', null, 'rechaza coordenadas fuera de Chile');
select throws_ok(
  $$ insert into public.addresses (owner_id, label, street_text, commune_id, lat, lng)
     values ('00000000-0000-0000-0000-0000000007a2', 'Ajena', 'Calle Falsa 1',
       (select id from public.communes where name = 'Ñuñoa'), -33.45, -70.6) $$,
  '42501', null, 'no crea direcciones a nombre de otro dueño');
update public.addresses set street_text = 'Av. Ficticia 456', lat = -33.4500
 where id = (select pg_temp.addr_a());
select is((select round(extensions.st_y(location::extensions.geometry)::numeric, 4)
           from public.addresses), -33.4500::numeric,
  'al editar las coordenadas se recalcula location');
select throws_ok(
  $$ delete from public.addresses $$, '42501', null, 'no borra direcciones');

-- Dueño B: no ve ni modifica lo de A -----------------------------------------
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000007a2');
set local role authenticated;
select is((select count(*)::int from public.pets), 0, 'otro dueño no ve mascotas ajenas');
select is((select count(*)::int from public.addresses), 0, 'otro dueño no ve direcciones ajenas');
update public.pets set name = 'Hackeado';
update public.addresses set street_text = 'Hackeada 1';

-- Topes por dueño (20 mascotas y 10 direcciones activas).
insert into public.pets (owner_id, name, species_id)
select '00000000-0000-0000-0000-0000000007a2', 'Gato ' || g, pg_temp.sp('gato')
from generate_series(1, 20) g;
select throws_ok(
  $$ insert into public.pets (owner_id, name, species_id)
     values ('00000000-0000-0000-0000-0000000007a2', 'Gato 21', pg_temp.sp('gato')) $$,
  '22023', 'Puedes tener hasta 20 mascotas activas', 'tope de 20 mascotas activas');
insert into public.addresses (owner_id, label, street_text, commune_id, lat, lng)
select '00000000-0000-0000-0000-0000000007a2', 'Dir ' || g, 'Calle Ficticia ' || g,
  (select id from public.communes where name = 'Providencia'), -33.43, -70.61
from generate_series(1, 10) g;
select throws_ok(
  $$ insert into public.addresses (owner_id, label, street_text, commune_id, lat, lng)
     values ('00000000-0000-0000-0000-0000000007a2', 'Dir 11', 'Calle 11',
       (select id from public.communes where name = 'Providencia'), -33.43, -70.61) $$,
  '22023', 'Puedes tener hasta 10 direcciones activas', 'tope de 10 direcciones activas');
update public.addresses set active = false where label = 'Dir 1';
select lives_ok(
  $$ insert into public.addresses (owner_id, label, street_text, commune_id, lat, lng)
     values ('00000000-0000-0000-0000-0000000007a2', 'Dir 11', 'Calle 11',
       (select id from public.communes where name = 'Providencia'), -33.43, -70.61) $$,
  'al desactivar una dirección se libera un cupo');
select throws_ok(
  $$ update public.addresses set active = true where label = 'Dir 1' $$,
  '22023', 'Puedes tener hasta 10 direcciones activas', 'reactivar respeta el tope');

-- Vet: ni lee ni crea ------------------------------------------------------------
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000007b1');
set local role authenticated;
select is((select count(*)::int from public.pets), 0, 'un vet no ve mascotas (fase 7: vía get_pet_record)');
select is((select count(*)::int from public.addresses), 0, 'un vet no ve direcciones (fase 6: solo el asignado)');
select throws_ok(
  $$ insert into public.pets (owner_id, name, species_id)
     values ('00000000-0000-0000-0000-0000000007b1', 'X', pg_temp.sp('gato')) $$,
  '42501', null, 'un vet no registra mascotas');

-- Admin: minimización, no ve mascotas ni direcciones ------------------------------
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000007c1');
set local role authenticated;
select is((select count(*)::int from public.pets), 0, 'el admin no ve mascotas (minimización)');
select is((select count(*)::int from public.addresses), 0, 'el admin no ve direcciones');
update public.pets set name = 'Admin';

-- Anónimo ------------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
set local role anon;
select throws_ok($$ select count(*) from public.pets $$, '42501', null, 'anon no lee mascotas');
select throws_ok($$ select count(*) from public.addresses $$, '42501', null, 'anon no lee direcciones');

-- Verificación como postgres: nadie modificó lo de A ------------------------------
reset role;
select is((select name from public.pets where id = (select pg_temp.pet_a())),
  'Firu', 'ni otro dueño ni el admin modificaron la mascota de A');
select is((select street_text from public.addresses where id = (select pg_temp.addr_a())),
  'Av. Ficticia 456', 'otro dueño no modificó la dirección de A');

-- Desactivar una especie no borra ni bloquea mascotas existentes (HU6.1).
update public.species set active = false where slug = 'perro';
select pg_temp.login('00000000-0000-0000-0000-0000000007a1');
set local role authenticated;
select lives_ok(
  $$ update public.pets set name = 'Firulais' where id = (select pg_temp.pet_a()) $$,
  'una mascota de especie desactivada se sigue editando');
select is((select count(*)::int from public.pets where species_id = pg_temp.sp('perro')), 1,
  'desactivar la especie no borra la mascota');

-- Helper de la fase 6: comuna y distancia redondeada a 0,5 km.
reset role;
select is(
  (select distance_km_rounded from private.address_approx(
     (select pg_temp.addr_a()),
     extensions.st_setsrid(extensions.st_makepoint(-70.5974, -33.4620), 4326)::extensions.geography)),
  1.5::numeric, 'distancia aproximada redondeada a 0,5 km (≈1,34 km → 1,5)');

select * from finish();
rollback;
