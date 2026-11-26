-- Fase 12: el admin consulta clientes (admin_list_owners, admin_owner_detail).
-- Matriz: dueño (a01), dueño bloqueado (a02), vet (f01), admin (c01), anónimo.
begin;
select plan(18);

create function pg_temp.u(p_k text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000d2' || p_k)::uuid;
$$;

insert into auth.users (id, email)
select pg_temp.u(k), 'f12-' || k || '@test.local'
from unnest(array['a01', 'a02', 'f01', 'c01']) k;
set local session_replication_role = replica;
insert into public.user_roles (user_id, role) values
  (pg_temp.u('a01'), 'owner'), (pg_temp.u('a02'), 'owner'),
  (pg_temp.u('f01'), 'vet'), (pg_temp.u('c01'), 'admin');
insert into public.owner_profiles (user_id, display_name, phone, commune_id) values
  (pg_temp.u('a01'), 'Clienta Zeta Ficticia', '+56911112222',
   (select id from public.communes where name = 'San Miguel')),
  (pg_temp.u('a02'), 'Cliente Bloqueado Ficticio', '+56933334444', null);
insert into public.deletion_requests (user_id, role) values (pg_temp.u('a02'), 'owner');
set local session_replication_role = origin;

create function pg_temp.login(p_k text) returns void language plpgsql as $$
begin
  if p_k = 'anon' then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    set local role anon;
  else
    perform set_config('request.jwt.claims', json_build_object(
      'sub', pg_temp.u(p_k), 'role', 'authenticated')::text, true);
    set local role authenticated;
  end if;
end;
$$;
create function pg_temp.try(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  raise exception using errcode = 'P0001', message = 'ok';
exception
  when sqlstate 'P0001' then
    return case when sqlerrm = 'ok' then 'ok' else 'err:P0001' end;
  when insufficient_privilege then return 'denied';
  when others then return 'err:' || sqlstate;
end;
$$;
grant execute on function pg_temp.u(text), pg_temp.try(text) to anon, authenticated;

-- Acceso: solo el admin ------------------------------------------------------
select pg_temp.login('a01');
select is(pg_temp.try('select * from public.admin_list_owners()'), 'denied',
  'un dueño no lista clientes');
select is(pg_temp.try(format('select public.admin_owner_detail(%L)', pg_temp.u('a01'))),
  'denied', 'un dueño no ve el detalle (ni el propio por esta vía)');
select pg_temp.login('f01');
select is(pg_temp.try('select * from public.admin_list_owners()'), 'denied',
  'un vet no lista clientes');
reset role;
select pg_temp.login('anon');
select is(pg_temp.try('select * from public.admin_list_owners()'), 'denied',
  'anónimo no lista clientes');
reset role;

-- Admin: listado ---------------------------------------------------------------
select pg_temp.login('c01');
select is((select display_name from public.admin_list_owners('Zeta')),
  'Clienta Zeta Ficticia', 'busca por nombre');
select is((select email from public.admin_list_owners('f12-a01')),
  'f12-a01@test.local', 'busca por correo');
select is((select commune_name from public.admin_list_owners('Zeta')),
  'San Miguel', 'trae la comuna');
select is((select visits_total from public.admin_list_owners('Zeta')), 0,
  'sin visitas, el total es 0');
select is((select count(*)::integer from public.admin_list_owners('f12-')), 1,
  'el bloqueado no se encuentra por su correo');
select is((select count(*)::integer from public.admin_list_owners()
           where user_id = pg_temp.u('f01')), 0, 'los vets no aparecen como clientes');
select ok((select blocked and email is null and phone is null
                  and display_name = 'Cuenta en proceso de borrado'
           from public.admin_list_owners(null, 500) where user_id = pg_temp.u('a02')),
  'el bloqueado aparece sin datos personales');
select is(pg_temp.try($$select * from public.admin_list_owners(repeat('x', 81))$$),
  'err:22023', 'búsqueda de más de 80 caracteres rechazada');

-- Admin: detalle ---------------------------------------------------------------
select is((public.admin_owner_detail(pg_temp.u('a01')))->>'phone', '+56911112222',
  'el detalle trae el teléfono');
select ok((public.admin_owner_detail(pg_temp.u('a01'))) ?& array['visits_by_status',
  'paid_total', 'cancel_fees', 'rating_avg', 'last_sign_in_at'],
  'el detalle trae los agregados');
select ok(not ((public.admin_owner_detail(pg_temp.u('a01'))) ?| array['pets', 'addresses',
  'subscription', 'plan', 'visits']), 'minimización: sin mascotas, direcciones, plan ni visitas');
select is(pg_temp.try(format('select public.admin_owner_detail(%L)', pg_temp.u('a02'))),
  'err:22023', 'el detalle de una cuenta bloqueada se rechaza (22023)');
select is(pg_temp.try(format('select public.admin_owner_detail(%L)', pg_temp.u('f01'))),
  'err:22023', 'el detalle de un vet no existe como cliente');
reset role;

-- Las funciones privadas no se exponen a anon.
select ok(not has_function_privilege('anon', 'private.admin_list_owners(text, integer)',
  'EXECUTE'), 'anon no ejecuta el helper privado');

select * from finish();
rollback;
