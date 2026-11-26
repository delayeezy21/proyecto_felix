-- Fase 12: el admin consulta a sus clientes (dueños) para dar soporte.
--
-- Minimización (arquitectura §8): solo datos de contacto y agregados. Nunca
-- mascotas, direcciones, ficha, plan contratado ni el detalle de cada visita.
-- Las cuentas bloqueadas (borrado pedido) aparecen sin datos personales y su
-- detalle se rechaza con 22023 `counterpart_blocked` (no `account_blocked`,
-- que la app interpreta como bloqueo de la propia sesión).

create function private.admin_list_owners(p_search text, p_limit integer)
returns table (user_id uuid, display_name text, email text, phone text,
               commune_name text, created_at timestamptz, visits_total integer,
               visits_completed integer, last_visit_at timestamptz, blocked boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  if not coalesce((select private.is_admin()), false) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  if v_q is not null and char_length(v_q) > 80 then
    raise exception 'La búsqueda es demasiado larga' using errcode = '22023';
  end if;
  return query
  with o as (
    select op.user_id, op.display_name, u.email::text as email, op.phone,
           c.name as commune_name, op.created_at,
           private.is_blocked(op.user_id) as blocked
    from public.owner_profiles op
    join public.user_roles r on r.user_id = op.user_id and r.role = 'owner'
    join auth.users u on u.id = op.user_id
    left join public.communes c on c.id = op.commune_id
  )
  select o.user_id,
         case when o.blocked then 'Cuenta en proceso de borrado' else o.display_name end,
         case when o.blocked then null else o.email end,
         case when o.blocked then null else o.phone end,
         case when o.blocked then null else o.commune_name end,
         o.created_at,
         (select count(*)::integer from public.visits v where v.owner_id = o.user_id),
         (select count(*)::integer from public.visits v
          where v.owner_id = o.user_id and v.status = 'completed'),
         (select max(v.scheduled_at) from public.visits v where v.owner_id = o.user_id),
         o.blocked
  from o
  -- Los bloqueados no se encuentran por nombre, correo ni teléfono.
  where v_q is null
     or (not o.blocked and (
           o.display_name ilike '%' || v_q || '%'
        or o.email ilike '%' || v_q || '%'
        or coalesce(o.phone, '') ilike '%' || v_q || '%'
        or coalesce(o.commune_name, '') ilike '%' || v_q || '%'))
  order by o.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end;
$$;
revoke execute on function private.admin_list_owners(text, integer) from public, anon;
grant execute on function private.admin_list_owners(text, integer) to authenticated;

create function private.admin_owner_detail(p_owner_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_res jsonb;
begin
  if not coalesce((select private.is_admin()), false) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  if private.is_blocked(p_owner_id) then
    raise exception 'La cuenta tiene una solicitud de eliminación: no se puede consultar'
      using errcode = '22023', hint = 'counterpart_blocked';
  end if;
  select jsonb_build_object(
    'user_id', op.user_id,
    'display_name', op.display_name,
    'email', u.email,
    'phone', op.phone,
    'commune_name', c.name,
    'created_at', op.created_at,
    'last_sign_in_at', u.last_sign_in_at,
    'foundation_name', f.name,
    'visits_by_status', coalesce((
      select jsonb_object_agg(s.status, s.n)
      from (select v.status, count(*)::integer as n from public.visits v
            where v.owner_id = op.user_id group by v.status) s), '{}'::jsonb),
    'urgent_visits', (select count(*)::integer from public.visits v
                      where v.owner_id = op.user_id and v.mode = 'urgent'),
    'last_visit_at', (select max(v.scheduled_at) from public.visits v
                      where v.owner_id = op.user_id),
    'paid_total', coalesce((select sum(p.total)::integer from public.payments p
                            where p.owner_id = op.user_id and p.status = 'simulated_paid'
                              and p.kind = 'visit'), 0),
    'cancel_fees', (select count(*)::integer from public.payments p
                    where p.owner_id = op.user_id and p.kind = 'cancel_fee'),
    'donations_total', coalesce((select sum(p.extra_donation)::integer from public.payments p
                                 where p.owner_id = op.user_id
                                   and p.status = 'simulated_paid'), 0),
    -- Calificaciones publicadas que los vets le dieron (solo el agregado).
    'rating_count', (select count(*)::integer from public.ratings x
                     join public.visits v on v.id = x.visit_id
                     where x.ratee_id = op.user_id and x.rater_role = 'vet'
                       and private.rating_public_at(x.published_at, v.completed_at) <= now()),
    'rating_avg', (select round(avg(x.stars), 1) from public.ratings x
                   join public.visits v on v.id = x.visit_id
                   where x.ratee_id = op.user_id and x.rater_role = 'vet'
                     and private.rating_public_at(x.published_at, v.completed_at) <= now())
  ) into v_res
  from public.owner_profiles op
  join public.user_roles r on r.user_id = op.user_id and r.role = 'owner'
  join auth.users u on u.id = op.user_id
  left join public.communes c on c.id = op.commune_id
  left join public.foundations f on f.id = op.foundation_id
  where op.user_id = p_owner_id;
  if v_res is null then
    raise exception 'Cliente no encontrado' using errcode = '22023';
  end if;
  return v_res;
end;
$$;
revoke execute on function private.admin_owner_detail(uuid) from public, anon;
grant execute on function private.admin_owner_detail(uuid) to authenticated;

create function public.admin_list_owners(p_search text default null, p_limit integer default 100)
returns table (user_id uuid, display_name text, email text, phone text,
               commune_name text, created_at timestamptz, visits_total integer,
               visits_completed integer, last_visit_at timestamptz, blocked boolean)
language sql stable security invoker set search_path = ''
as $$ select * from private.admin_list_owners(p_search, p_limit); $$;

create function public.admin_owner_detail(p_owner_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.admin_owner_detail(p_owner_id); $$;

revoke execute on function public.admin_list_owners(text, integer),
  public.admin_owner_detail(uuid) from public, anon;
grant execute on function public.admin_list_owners(text, integer),
  public.admin_owner_detail(uuid) to authenticated;
