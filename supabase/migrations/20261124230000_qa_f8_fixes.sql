-- Correcciones del QA de la fase 8 (docs/qa/QA-37c4e3c.md).
--
-- QA-F8-02: con dos urgencias simultáneas y un solo vet libre, ambas le
--   ofrecían (el despacho no veía la oferta sin confirmar de la otra
--   transacción) y accept_offer fallaba en las dos por "otra oferta
--   pendiente". Ahora:
--   * el despacho toma un lock de asesoría por vet (sin esperar: si otro
--     despacho lo tiene, lo salta) y recién entonces revisa, con una lectura
--     nueva, que no tenga otra oferta pendiente vigente;
--   * si el único motivo para no ofrecer es otra oferta pendiente, la
--     urgencia sigue buscando (el cron reintenta cada 10 s) en vez de cerrar
--     como no_vet_found;
--   * accept_offer toma el mismo lock (esperando), ya no cuenta las otras
--     ofertas pendientes del vet como choque y, al aceptar, las cierra
--     (cancelled) y despacha esas visitas si quedaron sin tanda.
-- QA-F8-03: los montos de my_offers se estiman con la distancia redondeada a
--   0,5 km que se muestra. La cotización final sigue usando la real.
-- QA-F8-04: visit_view entrega address_id solo al dueño.

-- Clave del lock de asesoría "ofertas de este vet".
create function private.vet_offer_lock_key(p_vet uuid)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select hashtextextended('vet-offer:' || p_vet::text, 0);
$$;
revoke execute on function private.vet_offer_lock_key(uuid) from public, anon, authenticated;

-- Igual que vet_busy_for_urgent(uuid, uuid), pero las otras ofertas
-- pendientes solo cuentan si p_count_offers.
create function private.vet_busy_for_urgent(p_vet uuid, p_except_visit uuid, p_count_offers boolean)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
      select 1 from public.visits x
      where x.vet_id = p_vet and x.id is distinct from p_except_visit
        and ((x.status in ('accepted', 'en_route', 'arrived', 'in_progress')
              and (x.mode = 'urgent'
                   or x.slot && tstzrange(now(), now() + (select u.slot_len from private.urgent_rules() u))))
             or (x.status = 'pending_vet'
                 and x.slot && tstzrange(now(), now() + (select u.slot_len from private.urgent_rules() u)))))
    or (p_count_offers and exists (
      select 1 from public.visit_offers o
      where o.vet_id = p_vet and o.status = 'pending' and o.expires_at > now()
        and o.visit_id is distinct from p_except_visit))
    or exists (
      select 1 from public.vet_time_off t
      where t.vet_id = p_vet and t.period @> now());
$$;
revoke execute on function private.vet_busy_for_urgent(uuid, uuid, boolean)
  from public, anon, authenticated;

create or replace function private.vet_busy_for_urgent(p_vet uuid, p_except_visit uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.vet_busy_for_urgent(p_vet, p_except_visit, true);
$$;

-- ---------------------------------------------------------------------------
-- Despacho (QA-F8-02)
-- ---------------------------------------------------------------------------
create or replace function private.dispatch_visit(p_visit uuid)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  u record;
  v public.visits;
  c record;
  v_loc extensions.geography;
  v_max_km integer;
  v_radius integer;
  v_batch integer;
  v_r integer;
  v_n integer;
  v_deferred boolean := false;
begin
  select * into u from private.urgent_rules();
  select * into v from public.visits where id = p_visit;
  if not found or v.status <> 'searching' then
    return 0;
  end if;

  -- 1) Vencen las ofertas de la tanda anterior.
  update public.visit_offers set status = 'expired', responded_at = now()
  where visit_id = v.id and status = 'pending' and expires_at <= now();

  -- 2) Pasados 10 min: sin vet (sin cobro). Cierra también las pendientes.
  if now() >= v.confirm_deadline then
    perform private.apply_transition(v.id, 'no_vet_found', null, null, 0);
    return 0;
  end if;

  -- 3) Tanda en curso: esperar.
  if exists (select 1 from public.visit_offers o
             where o.visit_id = v.id and o.status = 'pending') then
    return 0;
  end if;

  select a.location into v_loc from public.addresses a where a.id = v.address_id;
  v_max_km := least(u.radii_km[array_upper(u.radii_km, 1)],
                    (select (private.visit_pricing_config(v)).max_distance_km));
  select coalesce(max(o.radius_km), u.radii_km[1]), coalesce(max(o.batch), 0)
  into v_radius, v_batch
  from public.visit_offers o where o.visit_id = v.id;

  -- 4) Nueva tanda: hasta 3 vets elegibles, del radio actual hacia arriba.
  if v_loc is not null then
    foreach v_r in array u.radii_km loop
      continue when v_r < v_radius;
      exit when v_r > v_max_km;
      v_n := 0;
      for c in
        select p.vet_id,
               round(extensions.st_distance(p.location, v_loc))::integer as dist
        from public.vet_presence p
        join public.vet_profiles vp on vp.user_id = p.vet_id and vp.status = 'approved'
        join public.vet_species vs on vs.vet_id = p.vet_id and vs.species_id = v.species_id
        join public.vet_specialties vsp on vsp.vet_id = p.vet_id
                                       and vsp.specialty_id = v.specialty_id
        where p.online
          and p.updated_at > now() - u.presence_fresh
          and extensions.st_dwithin(p.location, v_loc, v_r * 1000)
          and not exists (select 1 from public.visit_offers o
                          where o.visit_id = v.id and o.vet_id = p.vet_id)
          and not private.vet_busy_for_urgent(p.vet_id, v.id, false)
        order by round(extensions.st_distance(p.location, v_loc) / 500.0),
                 private.vet_dispatch_rating(p.vet_id) desc nulls last,
                 extensions.st_distance(p.location, v_loc), p.vet_id
      loop
        exit when v_n >= u.batch_size;
        -- Otro despacho (u otra aceptación) está ofreciéndole algo: se salta,
        -- sin esperar (así dos despachos nunca se bloquean entre sí).
        if not pg_try_advisory_xact_lock(private.vet_offer_lock_key(c.vet_id)) then
          v_deferred := true;
          continue;
        end if;
        -- Con el lock, cada sentencia ve lo ya confirmado por los demás.
        if exists (select 1 from public.visit_offers o
                   where o.vet_id = c.vet_id and o.status = 'pending'
                     and o.expires_at > now() and o.visit_id <> v.id) then
          v_deferred := true;
          continue;
        end if;
        continue when private.vet_busy_for_urgent(c.vet_id, v.id, false);
        insert into public.visit_offers (visit_id, vet_id, batch, radius_km, distance_m, expires_at)
        values (v.id, c.vet_id, v_batch + 1, v_r, c.dist, now() + u.offer_ttl);
        v_n := v_n + 1;
      end loop;
      if v_n > 0 then
        return v_n;
      end if;
    end loop;
  end if;

  -- 5) Hay vets que solo están ocupados con otra oferta: se sigue buscando
  --    (el cron reintenta hasta confirm_deadline).
  if v_deferred then
    return 0;
  end if;

  -- 6) Agotado el radio máximo (20 km): sin vet.
  perform private.apply_transition(v.id, 'no_vet_found', null, null, 0);
  return 0;
end;
$$;

-- ---------------------------------------------------------------------------
-- Aceptación (QA-F8-02)
-- ---------------------------------------------------------------------------
create or replace function private.accept_offer(p_offer_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  u record;
  v_visit uuid;
  v public.visits;
  o public.visit_offers;
  v_req public.quotes;
  v_fq public.quotes;
  v_other uuid;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'vet' then
    raise exception 'Solo un veterinario acepta urgencias' using errcode = '42501';
  end if;
  select * into u from private.urgent_rules();
  select x.visit_id into v_visit from public.visit_offers x
  where x.id = p_offer_id and x.vet_id = v_uid;
  if not found then
    raise exception 'La oferta no existe' using errcode = '22023';
  end if;

  select * into v from public.visits where id = v_visit for update;
  -- Serializa con los despachos que le estén ofreciendo algo a este vet (ellos
  -- nunca esperan este lock, así que no hay interbloqueo).
  perform pg_advisory_xact_lock(private.vet_offer_lock_key(v_uid));
  select * into o from public.visit_offers where id = p_offer_id for update;

  if v.status <> 'searching' then
    if v.status = 'accepted' or v.vet_id is not null then
      raise exception 'Esta urgencia ya fue tomada por otro veterinario'
        using errcode = '22023', hint = 'offer_taken';
    end if;
    raise exception 'Esta urgencia ya no está disponible'
      using errcode = '22023', hint = 'offer_closed';
  end if;
  if o.status <> 'pending' or o.expires_at <= now() then
    raise exception 'La oferta venció' using errcode = '22023', hint = 'offer_expired';
  end if;
  if (select private.current_vet_status()) is distinct from 'approved' then
    raise exception 'Tu cuenta no está habilitada para atender' using errcode = '42501';
  end if;
  -- Las otras ofertas pendientes del vet no impiden aceptar esta: se cierran.
  if private.vet_busy_for_urgent(v_uid, v.id, false) then
    raise exception 'Tienes otra visita que choca con esta urgencia' using errcode = '22023';
  end if;

  select * into v_req from public.quotes q where q.id = v.quote_id;
  v_fq := private.urgent_final_quote(v_req, v_uid, o.distance_m);

  begin
    perform set_config('felix.visit_transition', 'on', true);
    update public.visits
    set status = 'accepted', vet_id = v_uid, accepted_at = now(),
        quote_id = v_fq.id,
        quote = private.quote_snapshot(v_fq) || jsonb_build_object('request_quote_id', v_req.id),
        scheduled_at = now(), slot = tstzrange(now(), now() + u.slot_len)
    where id = v.id
    returning * into v;
    perform set_config('felix.visit_transition', 'off', true);
  exception when exclusion_violation then
    raise exception 'Tienes otra visita que choca con esta urgencia' using errcode = '22023';
  end;
  insert into public.visit_events (visit_id, from_status, to_status, actor_id)
  values (v.id, 'searching', 'accepted', v_uid);

  -- Cierra las otras ofertas pendientes del vet (si alguna está bloqueada por
  -- otra transacción, esa visita cambia de estado y su trigger la cierra) y
  -- despacha la siguiente tanda de esas visitas si quedaron sin pendientes.
  for v_other in
    with closed as (
      update public.visit_offers x
      set status = 'cancelled', responded_at = now()
      where x.id in (select y.id from public.visit_offers y
                     where y.vet_id = v_uid and y.status = 'pending' and y.visit_id <> v.id
                     for update skip locked)
      returning x.visit_id)
    select distinct closed.visit_id from closed
  loop
    perform 1 from public.visits w
    where w.id = v_other and w.status = 'searching'
    for update skip locked;
    if found then
      perform private.dispatch_visit(v_other);
    end if;
  end loop;

  return private.visit_view(v, v_uid);
end;
$$;

-- ---------------------------------------------------------------------------
-- Ofertas del vet (QA-F8-03): montos con la distancia redondeada a 0,5 km.
-- ---------------------------------------------------------------------------
create or replace function private.list_my_offers()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'offer_id', o.id, 'visit_id', o.visit_id, 'batch', o.batch,
    'created_at', o.created_at, 'expires_at', o.expires_at,
    'commune_name', c.name,
    'distance_km', round(o.distance_m / 500.0) / 2,
    'species_name', sp.name, 'specialty_name', s.name,
    'service_price', pr.service_price, 'vet_payout', pr.vet_payout)
  from public.visit_offers o
  join public.visits v on v.id = o.visit_id and v.status = 'searching'
  join public.communes c on c.id = v.commune_id
  join public.species sp on sp.id = v.species_id
  join public.specialties s on s.id = v.specialty_id
  left join public.quotes q on q.id = v.quote_id
  left join lateral private.urgent_price(q, (round(o.distance_m / 500.0) * 500)::integer) pr
    on true
  where o.vet_id = (select auth.uid())
    and (select private.current_app_role()) = 'vet'
    and o.status = 'pending' and o.expires_at > now()
  order by o.expires_at;
$$;

-- ---------------------------------------------------------------------------
-- Vista de la visita (QA-F8-04): igual que 20261118185149 más address_id
-- para el dueño (nunca para el vet; el admin no usa esta vista).
-- ---------------------------------------------------------------------------
create or replace function private.visit_view(v public.visits, p_uid uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when v.owner_id = p_uid then jsonb_build_object(
      'id', v.id, 'viewer', 'owner', 'mode', v.mode, 'status', v.status,
      'scheduled_at', v.scheduled_at, 'confirm_deadline', v.confirm_deadline,
      'created_at', v.created_at, 'quote', v.quote, 'notes', v.owner_notes,
      'cancel_fee', v.cancel_fee, 'cancel_reason', v.cancel_reason,
      'closed_by_system', v.closed_by_system, 'pet_id', v.pet_id, 'vet_id', v.vet_id,
      -- QA-F8-04: solo el dueño ("Agendar primera hora libre").
      'address_id', v.address_id,
      'pet_name', p.name, 'species_name', sp.name, 'specialty_name', s.name,
      'commune_name', c.name, 'address_label', a.label, 'address_text', a.street_text,
      -- Del vet, solo datos públicos.
      'vet_name', vp.display_name,
      'paid', exists (select 1 from public.payments pay where pay.visit_id = v.id
                      and pay.kind = 'visit' and pay.status = 'simulated_paid'),
      'cancel_fee_now', case when private.visit_edge_allowed(v.status, 'cancelled_owner')
                             then private.cancel_fee_for(v, now()) end)
    when v.vet_id = p_uid then jsonb_build_object(
      'id', v.id, 'viewer', 'vet', 'mode', v.mode, 'status', v.status,
      'scheduled_at', v.scheduled_at, 'confirm_deadline', v.confirm_deadline,
      'created_at', v.created_at, 'notes', v.owner_notes,
      'cancel_reason', v.cancel_reason, 'closed_by_system', v.closed_by_system,
      'pet_id', v.pet_id,
      'service_price', (v.quote ->> 'service_price')::integer,
      'vet_payout', (v.quote ->> 'vet_payout')::integer,
      'pet_name', p.name, 'species_name', sp.name, 'specialty_name', s.name,
      'commune_name', coalesce(ap.commune_name, c.name),
      -- R-1: la distancia sale siempre del origen aproximado (quote_origin).
      'distance_km', coalesce((v.quote ->> 'distance_km')::numeric, ap.distance_km_rounded),
      'paid', exists (select 1 from public.payments pay where pay.visit_id = v.id
                      and pay.kind = 'visit' and pay.status = 'simulated_paid'),
      -- Ficha (fase 7): ventana de la visita y si puede escribir en ella.
      'record_access', g.id is not null and g.revoked_at is null
                       and (g.expires_at > now()
                            or (g.expires_at is null
                                and now() < coalesce(private.visit_active_until(v),
                                                     'infinity'))),
      'record_until', g.expires_at,
      'record_writable', coalesce(v.pet_id is not null
                                  and private.vet_can_write(v.pet_id, v.id), false),
      -- Dirección exacta y contacto: solo asignado, con la visita activa y
      -- dentro de su ventana (QA-F6-06), aunque el cron no la haya cerrado.
      'exact', case when v.status in ('accepted', 'en_route', 'arrived', 'in_progress')
                         and a.id is not null
                         and now() < coalesce(private.visit_active_until(v), 'infinity')
                    then jsonb_build_object(
                      'street_text', a.street_text, 'details', a.details,
                      'lat', a.lat, 'lng', a.lng,
                      'owner_name', o.display_name, 'owner_phone', o.phone) end)
  end
  from (select 1) one
  left join public.pets p on p.id = v.pet_id
  left join public.species sp on sp.id = v.species_id
  left join public.specialties s on s.id = v.specialty_id
  left join public.communes c on c.id = v.commune_id
  left join public.addresses a on a.id = v.address_id
  left join public.vet_profiles vp on vp.user_id = v.vet_id
  left join public.owner_profiles o on o.user_id = v.owner_id
  left join public.vet_bases b on b.vet_id = v.vet_id
  left join public.record_access_grants g
    on g.visit_id = v.id and g.source = 'visit' and v.vet_id = p_uid
  left join lateral private.address_approx(v.address_id, b.quote_origin) ap
    on v.vet_id = p_uid and b.vet_id is not null;
$$;
