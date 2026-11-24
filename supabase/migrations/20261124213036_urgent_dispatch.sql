-- Fase 8: urgencias (despacho por tandas, ofertas, ubicación en vivo y push).
-- Ver SPEC.md HU2.1 y HU2.3, y docs/arquitectura.md §5, §6 y §8.
--
-- Flujo: request_urgent_visit (cotiza en el servidor y crea la visita
-- `searching`) → private.dispatch_urgent_visits (pg_cron cada 10 s, y una
-- primera tanda inmediata) ofrece la visita a tandas de hasta 3 vets por 60 s,
-- radio 5 → 10 → 20 km sin repetir vets → accept_offer (atómico: gana uno; el
-- resto recibe "ya tomada") → en camino (ubicación en vivo por Broadcast
-- privado `visit:{id}`) → llegó → en curso → completada → pago simulado.
-- A los 10 min, o agotado el radio de 20 km, la visita queda `no_vet_found`
-- (sin cobro).
--
-- Principios:
-- * Precio solo en el servidor. Al pedir, la cotización trae base + recargo
--   de urgencia (30 %) y el tope por distancia (`max_total`, a 20 km). Al
--   aceptar, se emite la cotización final con la distancia de ESA oferta y la
--   MISMA versión de pricing_config; reemplaza a la de la solicitud en
--   visits.quote (única excepción del guardián, solo en searching → accepted).
-- * Privacidad: el vet con oferta ve comuna y distancia redondeada a 0,5 km;
--   nunca la calle, las coordenadas, el nombre de la mascota ni la nota. La
--   distancia se mide desde vet_presence (posición del vet, redondeada a
--   ~100 m), nunca desde la casa real del vet. vet_presence se sobrescribe sin
--   historial; el recorrido en vivo no se guarda.
-- * Estados: siguen cambiando solo vía apply_transition (marca local) o, en
--   la aceptación de una urgencia, vía private.accept_offer con la misma marca.
-- * Push: cola private.push_outbox (payload solo visit_id + evento) que la
--   Edge Function send-push vacía. pg_cron la invoca cada 10 s por pg_net solo
--   si existen los secretos de Vault 'project_url' y 'service_role_key'.

-- ---------------------------------------------------------------------------
-- Parámetros del despacho (constantes del diseño, SPEC HU2.1)
-- ---------------------------------------------------------------------------
create function private.urgent_rules()
returns table (
  batch_size integer,       -- vets por tanda
  offer_ttl interval,       -- vigencia de cada oferta
  radii_km integer[],       -- radios sucesivos
  search_window interval,   -- tiempo máximo de búsqueda
  presence_fresh interval,  -- presencia más antigua que esto = desconectado
  slot_len interval         -- bloque que ocupa una urgencia aceptada (60 + 30)
)
language sql
immutable
set search_path = ''
as $$
  select 3, interval '60 seconds', array[5, 10, 20], interval '10 minutes',
         interval '2 minutes', interval '90 minutes';
$$;
revoke execute on function private.urgent_rules() from public, anon, authenticated;

-- Calificación para el orden del despacho. Aún no hay calificaciones (fase 9):
-- valor neutro para todos, así el orden queda preparado (distancia en tramos
-- de 0,5 km, luego calificación, luego distancia exacta).
create function private.vet_dispatch_rating(p_vet uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select case when p_vet is null then null else 3.0 end::numeric;
$$;
revoke execute on function private.vet_dispatch_rating(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Presencia del vet (solo para el matching)
-- ---------------------------------------------------------------------------
create table public.vet_presence (
  vet_id uuid primary key references public.vet_profiles (user_id) on delete cascade,
  online boolean not null default false,
  -- Posición aproximada (redondeada a 3 decimales, ~100 m). Null si está
  -- desconectado (minimización: no se guarda la última posición).
  location extensions.geography(point, 4326),
  updated_at timestamptz not null default now(),
  constraint vet_presence_location_when_online check (not online or location is not null)
);
create index vet_presence_online_gix on public.vet_presence using gist (location) where online;

alter table public.vet_presence enable row level security;
alter table public.vet_presence force row level security;
revoke all on public.vet_presence from public, anon, authenticated;
-- El vet puede leer solo su propio estado (sin escritura directa: RPC).
grant select (vet_id, online, updated_at) on public.vet_presence to authenticated;
create policy vet_presence_select_own on public.vet_presence
for select to authenticated using (vet_id = (select auth.uid()));

create function private.set_vet_presence(
  p_online boolean, p_lat double precision, p_lng double precision)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_loc extensions.geography;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'vet' then
    raise exception 'Solo un veterinario informa su disponibilidad' using errcode = '42501';
  end if;
  if p_online is null then
    raise exception 'Indica si estás en línea' using errcode = '22023';
  end if;
  if p_online then
    if (select private.current_vet_status()) is distinct from 'approved' then
      raise exception 'Tu cuenta no está habilitada para atender' using errcode = '42501';
    end if;
    -- Chile continental e insular (aprox.).
    if p_lat is null or p_lng is null or p_lat not between -56.5 and -17
       or p_lng not between -110 and -66 then
      raise exception 'Ubicación no válida' using errcode = '22023';
    end if;
    v_loc := extensions.st_setsrid(
      extensions.st_makepoint(round(p_lng::numeric, 3)::double precision,
                              round(p_lat::numeric, 3)::double precision), 4326)::extensions.geography;
  end if;
  insert into public.vet_presence as p (vet_id, online, location, updated_at)
  values (v_uid, p_online, v_loc, now())
  on conflict (vet_id) do update
    set online = excluded.online, location = excluded.location, updated_at = now();
  return jsonb_build_object('online', p_online, 'updated_at', now());
end;
$$;
revoke execute on function private.set_vet_presence(boolean, double precision, double precision)
  from public, anon;
grant execute on function private.set_vet_presence(boolean, double precision, double precision)
  to authenticated;

create function public.set_vet_presence(
  p_online boolean, p_lat double precision default null, p_lng double precision default null)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.set_vet_presence(p_online, p_lat, p_lng);
$$;

-- ---------------------------------------------------------------------------
-- Ofertas
-- ---------------------------------------------------------------------------
create table public.visit_offers (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references public.visits (id) on delete cascade,
  vet_id uuid not null references public.vet_profiles (user_id) on delete cascade,
  batch smallint not null check (batch >= 1),
  radius_km smallint not null check (radius_km > 0),
  -- Distancia real (m) desde vet_presence: interna, nunca se entrega tal cual.
  distance_m integer not null check (distance_m >= 0),
  status text not null default 'pending' check (status in (
    'pending', 'accepted', 'rejected', 'expired', 'lost', 'cancelled')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  responded_at timestamptz,
  -- Sin repetir vets en una misma visita.
  constraint visit_offers_once unique (visit_id, vet_id)
);
create index visit_offers_vet_status_idx on public.visit_offers (vet_id, status);
create index visit_offers_pending_idx on public.visit_offers (visit_id, expires_at)
  where status = 'pending';

alter table public.visit_offers enable row level security;
alter table public.visit_offers force row level security;
revoke all on public.visit_offers from public, anon, authenticated;
-- El vet ve sus ofertas (útil para Realtime en Windows); el detalle va por
-- my_offers. Sin distance_m. Ni el dueño ni el admin leen ofertas.
grant select (id, visit_id, vet_id, batch, status, created_at, expires_at, responded_at)
  on public.visit_offers to authenticated;
create policy visit_offers_select_own on public.visit_offers
for select to authenticated using (vet_id = (select auth.uid()));

create index visits_searching_idx on public.visits (created_at) where status = 'searching';

-- ---------------------------------------------------------------------------
-- Guardián: única excepción nueva. En la aceptación de una urgencia
-- (searching → accepted, dentro de una transición) se fijan el horario
-- (hora = aceptación, slot de 90 min) y la cotización final con distancia.
-- ---------------------------------------------------------------------------
create or replace function private.guard_visit()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_in_transition boolean :=
    coalesce(current_setting('felix.visit_transition', true), '') = 'on';
  v_time_travel boolean :=
    session_user = 'postgres'
    and coalesce(current_setting('felix.time_travel', true), '') = 'on';
  v_urgent_accept boolean;
begin
  if tg_op = 'INSERT' then
    if new.status <> (case new.mode when 'scheduled' then 'pending_vet' else 'searching' end) then
      raise exception 'Una visita nace pendiente' using errcode = '22023';
    end if;
    if new.closed_by_system then
      raise exception 'Una visita nace abierta' using errcode = '22023';
    end if;
    return new;
  end if;

  v_urgent_accept := v_in_transition and old.mode = 'urgent' and old.status = 'searching'
                     and new.status = 'accepted' and old.scheduled_at is null
                     and old.vet_id is null and new.vet_id is not null;

  if (new.mode, new.commune_id, new.species_id, new.specialty_id,
      new.foundation_id, new.owner_notes, new.is_preventive, new.created_at)
     is distinct from
     (old.mode, old.commune_id, old.species_id, old.specialty_id,
      old.foundation_id, old.owner_notes, old.is_preventive, old.created_at)
     or (new.quote is distinct from old.quote and not v_urgent_accept)
     or (new.owner_id is distinct from old.owner_id and new.owner_id is not null)
     or (new.pet_id is distinct from old.pet_id and new.pet_id is not null)
     or (new.address_id is distinct from old.address_id and new.address_id is not null)
     or (new.vet_id is distinct from old.vet_id and new.vet_id is not null
         and old.vet_id is not null)
     or (new.quote_id is distinct from old.quote_id and new.quote_id is not null
         and not v_urgent_accept) then
    raise exception 'Los datos y el precio de una visita no se modifican' using errcode = '42501';
  end if;

  if (new.scheduled_at, new.slot, new.confirm_deadline)
     is distinct from (old.scheduled_at, old.slot, old.confirm_deadline)
     and not v_time_travel
     and not (v_urgent_accept and new.confirm_deadline is not distinct from old.confirm_deadline
              and new.scheduled_at is not null and lower(new.slot) = new.scheduled_at) then
    raise exception 'El horario de una visita no se modifica' using errcode = '42501';
  end if;

  if new.started_at is distinct from old.started_at
     and not (v_in_transition or v_time_travel) then
    raise exception 'El estado de una visita solo cambia con transition_visit'
      using errcode = '42501';
  end if;

  if (new.status, new.cancel_fee, new.cancel_reason, new.accepted_at, new.completed_at,
      new.closed_at, new.closed_by_system)
     is distinct from
     (old.status, old.cancel_fee, old.cancel_reason, old.accepted_at, old.completed_at,
      old.closed_at, old.closed_by_system) then
    if not v_in_transition then
      raise exception 'El estado de una visita solo cambia con transition_visit'
        using errcode = '42501';
    end if;
    if new.status is distinct from old.status
       and not private.visit_edge_allowed(old.status, new.status) then
      raise exception 'Transición no permitida: % → %', old.status, new.status
        using errcode = '22023';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

-- Al salir de `searching`, las ofertas pendientes se cierran: la del vet
-- asignado queda aceptada; las demás, "tomada por otro" (lost) o canceladas.
create function private.close_visit_offers()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'searching' and new.status is distinct from old.status then
    update public.visit_offers o
    set status = case when new.status = 'accepted' and o.vet_id = new.vet_id then 'accepted'
                      when new.status = 'accepted' then 'lost'
                      else 'cancelled' end,
        responded_at = now()
    where o.visit_id = new.id and o.status = 'pending';
  end if;
  return null;
end;
$$;
revoke execute on function private.close_visit_offers() from public, anon, authenticated;

create trigger visits_close_offers after update of status on public.visits
for each row execute function private.close_visit_offers();

-- ---------------------------------------------------------------------------
-- Precio de una urgencia con distancia (misma versión de pricing_config que
-- la cotización de la solicitud)
-- ---------------------------------------------------------------------------
create function private.urgent_price(p_req public.quotes, p_distance_m integer)
returns table (
  pricing_config_id integer, base_price integer, urgent_surcharge integer,
  billable_km integer, distance_surcharge integer, discount integer,
  service_price integer, platform_fee integer, foundation_share integer,
  vet_payout integer, extra_donation integer, total integer)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id, b.base_price, b.urgent_surcharge, b.billable_km, b.distance_surcharge,
         b.discount, b.service_price, b.platform_fee, b.foundation_share, b.vet_payout,
         b.extra_donation, b.total
  from public.pricing_config c
  cross join lateral private.price_breakdown(
    p_req.base_price, true, p_distance_m, p_req.extra_donation,
    c.commission_pct, c.foundation_pct, c.urgent_pct, c.per_km, c.free_km,
    0, false, false, c.commission_on_distance) b
  where c.id = p_req.pricing_config_id;
$$;
revoke execute on function private.urgent_price(public.quotes, integer) from public, anon, authenticated;

-- Cotización final (inmutable, ya consumida) al aceptar la oferta.
create function private.urgent_final_quote(p_req public.quotes, p_vet uuid, p_distance_m integer)
returns public.quotes
language sql
volatile
security definer
set search_path = ''
as $$
  insert into public.quotes (
    owner_id, pet_id, address_id, vet_id, species_id, specialty_id, commune_id,
    mode, pricing_config_id, foundation_id, distance_m,
    base_price, urgent_surcharge, billable_km, distance_surcharge, discount,
    service_price, platform_fee, foundation_share, vet_payout, extra_donation,
    total, expires_at, consumed_at)
  select p_req.owner_id, p_req.pet_id, p_req.address_id, p_vet, p_req.species_id,
    p_req.specialty_id, p_req.commune_id, 'urgent', b.pricing_config_id, p_req.foundation_id,
    p_distance_m, b.base_price, b.urgent_surcharge, b.billable_km, b.distance_surcharge,
    b.discount, b.service_price, b.platform_fee, b.foundation_share, b.vet_payout,
    b.extra_donation, b.total, now(), now()
  from private.urgent_price(p_req, p_distance_m) b
  returning *;
$$;
revoke execute on function private.urgent_final_quote(public.quotes, uuid, integer)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Despacho
-- ---------------------------------------------------------------------------
-- ¿Tiene el vet algo que choque con atender ahora una urgencia? (visita
-- activa urgente, o una agendada activa o pendiente que se solapa con el
-- bloque de 90 min, u otra oferta pendiente).
create function private.vet_busy_for_urgent(p_vet uuid, p_except_visit uuid)
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
    or exists (
      select 1 from public.visit_offers o
      where o.vet_id = p_vet and o.status = 'pending' and o.expires_at > now()
        and o.visit_id is distinct from p_except_visit)
    or exists (
      select 1 from public.vet_time_off t
      where t.vet_id = p_vet and t.period @> now());
$$;
revoke execute on function private.vet_busy_for_urgent(uuid, uuid) from public, anon, authenticated;

-- Avanza el despacho de UNA visita (el llamador ya la bloqueó). Devuelve el
-- número de ofertas nuevas.
create function private.dispatch_visit(p_visit uuid)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  u record;
  v public.visits;
  v_loc extensions.geography;
  v_max_km integer;
  v_radius integer;
  v_batch integer;
  v_r integer;
  v_n integer;
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
      insert into public.visit_offers (visit_id, vet_id, batch, radius_km, distance_m, expires_at)
      select v.id, c.vet_id, v_batch + 1, v_r, c.dist, now() + u.offer_ttl
      from (
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
          and not private.vet_busy_for_urgent(p.vet_id, v.id)
        order by round(extensions.st_distance(p.location, v_loc) / 500.0),
                 private.vet_dispatch_rating(p.vet_id) desc nulls last,
                 extensions.st_distance(p.location, v_loc), p.vet_id
        limit u.batch_size
      ) c;
      get diagnostics v_n = row_count;
      if v_n > 0 then
        return v_n;
      end if;
    end loop;
  end if;

  -- 5) Agotado el radio máximo (20 km): sin vet.
  perform private.apply_transition(v.id, 'no_vet_found', null, null, 0);
  return 0;
end;
$$;
revoke execute on function private.dispatch_visit(uuid) from public, anon, authenticated;

-- pg_cron cada 10 s. `skip locked`: dos ejecuciones (o una aceptación en
-- curso) no compiten por la misma visita.
create function private.dispatch_urgent_visits()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_n integer := 0;
begin
  for v_id in
    select v.id from public.visits v
    where v.status = 'searching'
    order by v.created_at
    limit 200
    for update skip locked
  loop
    v_n := v_n + private.dispatch_visit(v_id);
  end loop;
  return v_n;
end;
$$;
revoke execute on function private.dispatch_urgent_visits() from public, anon, authenticated;

select cron.schedule('dispatch-urgent-visits', '10 seconds',
  'select private.dispatch_urgent_visits()');

-- ---------------------------------------------------------------------------
-- Solicitud del dueño
-- ---------------------------------------------------------------------------
create function private.request_urgent_visit(
  p_pet_id uuid, p_address_id uuid, p_specialty_id integer, p_foundation_id uuid,
  p_extra_donation integer, p_notes text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  r record;
  u record;
  v_spec integer;
  v_q public.quotes;
  v_max record;
  v public.visits;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño puede pedir una urgencia' using errcode = '42501';
  end if;
  if p_notes is not null and char_length(p_notes) > 300 then
    raise exception 'La nota admite hasta 300 caracteres' using errcode = '22023';
  end if;
  select * into r from private.visit_rules();
  select * into u from private.urgent_rules();
  v_spec := coalesce(p_specialty_id, (select s.id from public.specialties s where s.slug = 'general'));

  perform pg_advisory_xact_lock(hashtextextended('visits:' || v_uid::text, 0));
  if exists (select 1 from public.visits x where x.owner_id = v_uid and x.status = 'searching') then
    raise exception 'Ya tienes una urgencia buscando veterinario' using errcode = '22023';
  end if;
  if (select count(*) from public.visits x
      where x.owner_id = v_uid
        and x.status in ('searching', 'pending_vet', 'accepted', 'en_route', 'arrived',
                         'in_progress'))
     >= r.max_open_per_owner then
    raise exception 'Tienes demasiadas visitas abiertas' using errcode = '22023';
  end if;

  -- Valida mascota, dirección, especie/especialidad, tarifa y fundación.
  v_q := private.quote_for(v_uid, p_pet_id, p_address_id, v_spec, 'urgent', null, null,
                           p_foundation_id, p_extra_donation);
  v_q := private.consume_quote(v_q.id, v_uid);
  select * into v_max from private.urgent_price(v_q, u.radii_km[array_upper(u.radii_km, 1)] * 1000);

  insert into public.visits (owner_id, pet_id, address_id, quote_id, mode, status,
    commune_id, species_id, specialty_id, foundation_id, confirm_deadline, quote, owner_notes)
  values (v_uid, v_q.pet_id, v_q.address_id, v_q.id, 'urgent', 'searching',
    v_q.commune_id, v_q.species_id, v_q.specialty_id, v_q.foundation_id,
    now() + u.search_window,
    private.quote_snapshot(v_q) || jsonb_build_object(
      'distance_pending', true,
      'max_distance_km', u.radii_km[array_upper(u.radii_km, 1)],
      'max_service_price', v_max.service_price,
      'max_total', v_max.total),
    nullif(trim(p_notes), ''))
  returning * into v;
  insert into public.visit_events (visit_id, from_status, to_status, actor_id)
  values (v.id, null, v.status, v_uid);

  -- Primera tanda de inmediato (no espera al cron).
  perform private.dispatch_visit(v.id);
  select * into v from public.visits where id = v.id;
  return private.visit_view(v, v_uid);
end;
$$;
revoke execute on function private.request_urgent_visit(uuid, uuid, integer, uuid, integer, text)
  from public, anon;
grant execute on function private.request_urgent_visit(uuid, uuid, integer, uuid, integer, text)
  to authenticated;

create function public.request_urgent_visit(
  p_pet_id uuid, p_address_id uuid, p_specialty_id integer default null,
  p_foundation_id uuid default null, p_extra_donation integer default 0,
  p_notes text default null)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.request_urgent_visit(p_pet_id, p_address_id, p_specialty_id,
                                      p_foundation_id, p_extra_donation, p_notes);
$$;

-- Estado de la búsqueda para el dueño (sin identidades de vets).
create function private.urgent_search_status(p_visit_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'visit_id', v.id, 'status', v.status, 'search_until', v.confirm_deadline,
    'radius_km', (select max(o.radius_km) from public.visit_offers o where o.visit_id = v.id),
    'batches', (select coalesce(max(o.batch), 0) from public.visit_offers o where o.visit_id = v.id),
    'pending_offers', (select count(*) from public.visit_offers o
                       where o.visit_id = v.id and o.status = 'pending' and o.expires_at > now()))
  from public.visits v
  where v.id = p_visit_id and v.mode = 'urgent' and v.owner_id = (select auth.uid());
$$;
revoke execute on function private.urgent_search_status(uuid) from public, anon;
grant execute on function private.urgent_search_status(uuid) to authenticated;

create function public.urgent_search_status(p_visit_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.urgent_search_status(p_visit_id);
$$;

-- ---------------------------------------------------------------------------
-- Ofertas del vet: solo comuna, distancia a 0,5 km, especie, especialidad y
-- montos estimados con esa distancia.
-- ---------------------------------------------------------------------------
create function private.list_my_offers()
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
  left join lateral private.urgent_price(q, o.distance_m) pr on true
  where o.vet_id = (select auth.uid())
    and (select private.current_app_role()) = 'vet'
    and o.status = 'pending' and o.expires_at > now()
  order by o.expires_at;
$$;
revoke execute on function private.list_my_offers() from public, anon;
grant execute on function private.list_my_offers() to authenticated;

create function public.my_offers()
returns setof jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.list_my_offers();
$$;

-- Aceptación atómica: se bloquea la VISITA (mismo orden que el despacho) y
-- luego la oferta. El primero que llega la asigna; el segundo encuentra la
-- visita ya `accepted` y recibe "ya tomada" (hint offer_taken).
create function private.accept_offer(p_offer_id uuid)
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
  if private.vet_busy_for_urgent(v_uid, v.id) then
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
  return private.visit_view(v, v_uid);
end;
$$;
revoke execute on function private.accept_offer(uuid) from public, anon;
grant execute on function private.accept_offer(uuid) to authenticated;

create function public.accept_offer(p_offer_id uuid)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.accept_offer(p_offer_id);
$$;

-- Rechazo: si era la última pendiente de la tanda, sale la siguiente ya.
create function private.reject_offer(p_offer_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_visit uuid;
  o public.visit_offers;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'vet' then
    raise exception 'Solo un veterinario rechaza urgencias' using errcode = '42501';
  end if;
  select x.visit_id into v_visit from public.visit_offers x
  where x.id = p_offer_id and x.vet_id = v_uid;
  if not found then
    raise exception 'La oferta no existe' using errcode = '22023';
  end if;
  perform 1 from public.visits where id = v_visit for update;
  select * into o from public.visit_offers where id = p_offer_id for update;
  if o.status <> 'pending' then
    raise exception 'La oferta ya no está pendiente' using errcode = '22023';
  end if;
  update public.visit_offers set status = 'rejected', responded_at = now()
  where id = o.id;
  if not exists (select 1 from public.visit_offers x
                 where x.visit_id = v_visit and x.status = 'pending' and x.expires_at > now()) then
    perform private.dispatch_visit(v_visit);
  end if;
  return jsonb_build_object('offer_id', o.id, 'status', 'rejected');
end;
$$;
revoke execute on function private.reject_offer(uuid) from public, anon;
grant execute on function private.reject_offer(uuid) to authenticated;

create function public.reject_offer(p_offer_id uuid)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.reject_offer(p_offer_id);
$$;

-- ---------------------------------------------------------------------------
-- Ubicación en vivo: Broadcast privado `visit:{id}`. Recibe el dueño y el vet
-- asignado; envía solo el vet; y solo mientras la visita está `en_route`.
-- (Realtime evalúa estas políticas al unirse al canal; al llegar o cancelar,
-- un nuevo join ya no se autoriza y la app deja de enviar.)
-- ---------------------------------------------------------------------------
create function private.can_use_visit_topic(p_topic text, p_send boolean)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.visits v
    where v.id = case when p_topic ~ '^visit:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                      then substr(p_topic, 7)::uuid end
      and v.status = 'en_route'
      and (v.vet_id = (select auth.uid())
           or (not coalesce(p_send, true) and v.owner_id = (select auth.uid()))));
$$;
revoke execute on function private.can_use_visit_topic(text, boolean) from public, anon;
grant execute on function private.can_use_visit_topic(text, boolean) to authenticated;

create policy visit_location_receive on realtime.messages
for select to authenticated
using (realtime.messages.extension = 'broadcast'
       and (select private.can_use_visit_topic((select realtime.topic()), false)));
create policy visit_location_send on realtime.messages
for insert to authenticated
with check (realtime.messages.extension = 'broadcast'
            and (select private.can_use_visit_topic((select realtime.topic()), true)));

-- ---------------------------------------------------------------------------
-- Push: dispositivos y cola (esquema private: la API no los expone)
-- ---------------------------------------------------------------------------
create table private.push_devices (
  token text primary key check (char_length(token) between 10 and 4096),
  user_id uuid not null references auth.users (id) on delete cascade,
  platform text not null check (platform in ('android', 'ios', 'web')),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index push_devices_user_idx on private.push_devices (user_id);
create index push_devices_seen_idx on private.push_devices (last_seen_at);

create table private.push_outbox (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  visit_id uuid not null references public.visits (id) on delete cascade,
  event text not null check (event ~ '^[a-z_]{3,40}$'),
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index push_outbox_pending_idx on private.push_outbox (id) where sent_at is null;
create index push_outbox_user_idx on private.push_outbox (user_id);
create index push_outbox_visit_idx on private.push_outbox (visit_id);
create index push_outbox_created_idx on private.push_outbox (created_at);

revoke all on private.push_devices, private.push_outbox from public, anon, authenticated, service_role;
alter table private.push_devices enable row level security;
alter table private.push_devices force row level security;
alter table private.push_outbox enable row level security;
alter table private.push_outbox force row level security;

create function private.register_push_device(p_token text, p_platform text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'Inicia sesión para continuar' using errcode = '42501';
  end if;
  if p_token is null or char_length(p_token) not between 10 and 4096
     or p_platform is null or p_platform not in ('android', 'ios', 'web') then
    raise exception 'Dispositivo no válido' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('push:' || v_uid::text, 0));
  if (select count(*) from private.push_devices d where d.user_id = v_uid) >= 10
     and not exists (select 1 from private.push_devices d where d.token = p_token) then
    raise exception 'Demasiados dispositivos registrados' using errcode = '22023';
  end if;
  -- Un token pertenece a un solo usuario (el último que inició sesión).
  insert into private.push_devices as d (token, user_id, platform)
  values (p_token, v_uid, p_platform)
  on conflict (token) do update
    set user_id = excluded.user_id, platform = excluded.platform, last_seen_at = now();
  return jsonb_build_object('registered', true);
end;
$$;
revoke execute on function private.register_push_device(text, text) from public, anon;
grant execute on function private.register_push_device(text, text) to authenticated;

create function public.register_push_device(p_token text, p_platform text)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.register_push_device(p_token, p_platform);
$$;

create function private.unregister_push_device(p_token text)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$
  with d as (
    delete from private.push_devices
    where token = p_token and user_id = (select auth.uid())
    returning 1)
  select jsonb_build_object('removed', (select count(*) from d) > 0);
$$;
revoke execute on function private.unregister_push_device(text) from public, anon;
grant execute on function private.unregister_push_device(text) to authenticated;

create function public.unregister_push_device(p_token text)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.unregister_push_device(p_token);
$$;

-- Encola un aviso (solo si el usuario tiene dispositivos: Windows no tiene
-- FCM y usa Realtime dentro de la app).
create function private.enqueue_push(p_user uuid, p_visit uuid, p_event text)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into private.push_outbox (user_id, visit_id, event)
  select p_user, p_visit, p_event
  where p_user is not null
    and exists (select 1 from private.push_devices d where d.user_id = p_user);
$$;
revoke execute on function private.enqueue_push(uuid, uuid, text) from public, anon, authenticated;

-- Cada cambio de estado avisa al dueño y al vet, salvo a quien lo hizo.
create function private.push_on_visit_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v record;
begin
  if new.to_status = 'searching' then
    return null;
  end if;
  select x.owner_id, x.vet_id into v from public.visits x where x.id = new.visit_id;
  if v.owner_id is distinct from new.actor_id then
    perform private.enqueue_push(v.owner_id, new.visit_id, 'visit_' || new.to_status);
  end if;
  if v.vet_id is distinct from new.actor_id then
    perform private.enqueue_push(v.vet_id, new.visit_id, 'visit_' || new.to_status);
  end if;
  return null;
end;
$$;
revoke execute on function private.push_on_visit_event() from public, anon, authenticated;

create trigger visit_events_push after insert on public.visit_events
for each row execute function private.push_on_visit_event();

-- Ofertas: nueva (offer_new), tomada por otro (offer_taken) o cerrada.
create function private.push_on_offer()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform private.enqueue_push(new.vet_id, new.visit_id, 'offer_new');
  elsif new.status is distinct from old.status and new.status in ('lost', 'cancelled') then
    perform private.enqueue_push(new.vet_id, new.visit_id,
      case new.status when 'lost' then 'offer_taken' else 'offer_cancelled' end);
  end if;
  return null;
end;
$$;
revoke execute on function private.push_on_offer() from public, anon, authenticated;

create trigger visit_offers_push after insert or update of status on public.visit_offers
for each row execute function private.push_on_offer();

-- Lote para la Edge Function send-push (solo service_role). Entrega como
-- máximo una vez: el lote se marca enviado al tomarlo.
create function private.claim_push_batch(p_limit integer)
returns table (id bigint, token text, platform text, visit_id uuid, event text)
language sql
volatile
security definer
set search_path = ''
as $$
  with c as (
    select o.id from private.push_outbox o
    where o.sent_at is null
    order by o.id
    limit least(greatest(coalesce(p_limit, 100), 1), 500)
    for update skip locked
  ), m as (
    update private.push_outbox o set sent_at = now()
    from c where o.id = c.id
    returning o.id, o.user_id, o.visit_id, o.event
  )
  select m.id, d.token, d.platform, m.visit_id, m.event
  from m join private.push_devices d on d.user_id = m.user_id
  order by m.id;
$$;
revoke execute on function private.claim_push_batch(integer) from public, anon, authenticated;
grant execute on function private.claim_push_batch(integer) to service_role;

create function public.claim_push_batch(p_limit integer default 100)
returns table (id bigint, token text, platform text, visit_id uuid, event text)
language sql
volatile
security invoker
set search_path = ''
as $$
  select * from private.claim_push_batch(p_limit);
$$;
revoke execute on function public.claim_push_batch(integer) from public, anon, authenticated;
grant execute on function public.claim_push_batch(integer) to service_role;

-- Tokens que FCM declaró inválidos (UNREGISTERED): se borran.
create function private.drop_push_tokens(p_tokens text[])
returns integer
language sql
volatile
security definer
set search_path = ''
as $$
  with d as (delete from private.push_devices where token = any (p_tokens) returning 1)
  select count(*)::integer from d;
$$;
revoke execute on function private.drop_push_tokens(text[]) from public, anon, authenticated;
grant execute on function private.drop_push_tokens(text[]) to service_role;

create function public.drop_push_tokens(p_tokens text[])
returns integer
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.drop_push_tokens(p_tokens);
$$;
revoke execute on function public.drop_push_tokens(text[]) from public, anon, authenticated;
grant execute on function public.drop_push_tokens(text[]) to service_role;

-- Retención: cola 1 día; tokens sin uso en 90 días (docs/arquitectura.md §8).
create function private.purge_push()
returns integer
language sql
volatile
security definer
set search_path = ''
as $$
  with a as (delete from private.push_outbox where created_at < now() - interval '1 day' returning 1),
       b as (delete from private.push_devices where last_seen_at < now() - interval '90 days' returning 1)
  select ((select count(*) from a) + (select count(*) from b))::integer;
$$;
revoke execute on function private.purge_push() from public, anon, authenticated;

select cron.schedule('purge-push', '23 * * * *', 'select private.purge_push()');

-- Disparo de send-push por pg_net, solo si hay avisos pendientes y existen
-- los secretos de Vault (los mismos de purge-vet-documents). Sin secretos en
-- el código ni en la migración.
select cron.schedule(
  'send-push',
  '10 seconds',
  $cron$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' ||
        (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000)
  where exists (select 1 from private.push_outbox where sent_at is null)
    and exists (select 1 from vault.decrypted_secrets where name = 'project_url')
    and exists (select 1 from vault.decrypted_secrets where name = 'service_role_key');
  $cron$
);
