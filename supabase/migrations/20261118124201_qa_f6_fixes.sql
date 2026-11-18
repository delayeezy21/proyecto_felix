-- Correcciones de QA fase 6 (docs/qa/QA-673113e.md).
--
-- QA-F6-01 (Medio): un vet aprobado SIN punto de partida se podía cotizar y
--   reservar por API (sin distancia, sin recargo y sin el radio máximo). Ahora
--   create_quote exige vet_bases cuando se indica un vet, y la reserva exige
--   que la cotización tenga distancia (calculada desde quote_origin).
-- QA-F6-03 (Medio): una visita "en camino" (o "llegó") que nunca empieza
--   quedaba abierta para siempre y el dueño solo salía pagando $5.000.
--   * expire_visits cierra como cancelled_vet, sin cargo, las en_route/arrived
--     que siguen así 2 h después de la hora agendada;
--   * el dueño cancela gratis una en_route cuando ya pasaron 30 min de la hora.
--   Se suma el borde arrived → cancelled_vet (el vet también puede cerrarla).
-- QA-F6-05 (Medio): available_vets calculaba los horarios de todos los
--   candidatos. Ahora preselecciona los 30 más cercanos con el GiST de
--   quote_origin (KNN), calcula sus horarios en una sola consulta por vet
--   (sin una llamada por horario) y limita a 30 búsquedas por dueño y minuto.
-- QA-F6-02 (Bajo): el admin ya no lee visit_events fila a fila (solo el
--   agregado admin_visit_summary). La tabla queda solo para auditoría por SQL.
-- QA-F6-04 (Bajo): la hora manda también al llegar, iniciar y completar:
--   "llegó" e "inicia" desde 30 min antes de la hora; "completada" con al
--   menos 10 min de atención (visits.started_at).
-- Riesgo: scheduled_at, slot, confirm_deadline y started_at ya no cambian
--   después de crear la visita. Única excepción: una sesión directa de
--   `postgres` (session_user, nunca la API: PostgREST conecta como
--   authenticator) que además fija `felix.time_travel = 'on'`. Así simulan el
--   paso del tiempo pgTAP y los E2E (tool/e2e/sql.mjs); ninguna función
--   SECURITY DEFINER ni la app pueden hacerlo.

-- ---------------------------------------------------------------------------
-- Reglas de horario de las transiciones (constantes documentadas en
-- docs/arquitectura.md §5).
-- ---------------------------------------------------------------------------
create function private.visit_timing()
returns table (
  arrive_from interval,      -- "llegó" e "inicia" desde N antes de la hora
  min_service interval,      -- duración mínima antes de "completada"
  stale_after interval,      -- en_route/arrived sin iniciar: cierre automático
  late_free_after interval   -- en_route tras N de la hora: cancelar es gratis
)
language sql
immutable
set search_path = ''
as $$
  select interval '30 minutes', interval '10 minutes', interval '2 hours',
         interval '30 minutes';
$$;
revoke execute on function private.visit_timing() from public, anon, authenticated;

alter table public.visits add column started_at timestamptz;

-- arrived → cancelled_vet: el vet llegó pero no puede atender (o el sistema
-- cierra una visita que nunca empezó).
create or replace function private.visit_edge_allowed(p_from text, p_to text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select (p_from, p_to) in (
    ('searching', 'accepted'), ('searching', 'no_vet_found'), ('searching', 'cancelled_owner'),
    ('pending_vet', 'accepted'), ('pending_vet', 'expired'), ('pending_vet', 'rejected'),
    ('pending_vet', 'cancelled_owner'),
    ('accepted', 'en_route'), ('accepted', 'cancelled_owner'), ('accepted', 'cancelled_vet'),
    ('en_route', 'arrived'), ('en_route', 'cancelled_owner'), ('en_route', 'cancelled_vet'),
    ('arrived', 'in_progress'), ('arrived', 'cancelled_vet'),
    ('in_progress', 'completed'));
$$;

-- ---------------------------------------------------------------------------
-- Guardián: horario inmutable salvo "viaje en el tiempo" de una sesión
-- directa de postgres (tests).
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
begin
  if tg_op = 'INSERT' then
    if new.status <> (case new.mode when 'scheduled' then 'pending_vet' else 'searching' end) then
      raise exception 'Una visita nace pendiente' using errcode = '22023';
    end if;
    return new;
  end if;

  if (new.quote, new.mode, new.commune_id, new.species_id, new.specialty_id,
      new.foundation_id, new.owner_notes, new.is_preventive, new.created_at)
     is distinct from
     (old.quote, old.mode, old.commune_id, old.species_id, old.specialty_id,
      old.foundation_id, old.owner_notes, old.is_preventive, old.created_at)
     or (new.owner_id is distinct from old.owner_id and new.owner_id is not null)
     or (new.pet_id is distinct from old.pet_id and new.pet_id is not null)
     or (new.address_id is distinct from old.address_id and new.address_id is not null)
     or (new.vet_id is distinct from old.vet_id and new.vet_id is not null
         and old.vet_id is not null)
     or (new.quote_id is distinct from old.quote_id and new.quote_id is not null) then
    raise exception 'Los datos y el precio de una visita no se modifican' using errcode = '42501';
  end if;

  if (new.scheduled_at, new.slot, new.confirm_deadline)
     is distinct from (old.scheduled_at, old.slot, old.confirm_deadline)
     and not v_time_travel then
    raise exception 'El horario de una visita no se modifica' using errcode = '42501';
  end if;

  if new.started_at is distinct from old.started_at
     and not (v_in_transition or v_time_travel) then
    raise exception 'El estado de una visita solo cambia con transition_visit'
      using errcode = '42501';
  end if;

  if (new.status, new.cancel_fee, new.cancel_reason, new.accepted_at, new.completed_at,
      new.closed_at)
     is distinct from
     (old.status, old.cancel_fee, old.cancel_reason, old.accepted_at, old.completed_at,
      old.closed_at) then
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

create or replace function private.apply_transition(
  p_visit uuid, p_to text, p_actor uuid, p_reason text, p_fee integer)
returns public.visits
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_from text;
  v public.visits;
begin
  select status into v_from from public.visits where id = p_visit;
  perform set_config('felix.visit_transition', 'on', true);
  update public.visits
  set status = p_to,
      accepted_at = case when p_to = 'accepted' then now() else accepted_at end,
      started_at = case when p_to = 'in_progress' then now() else started_at end,
      completed_at = case when p_to = 'completed' then now() else completed_at end,
      closed_at = case when p_to in ('completed', 'rejected', 'expired', 'no_vet_found',
                                     'cancelled_owner', 'cancelled_vet')
                       then now() else closed_at end,
      cancel_reason = case when p_to in ('rejected', 'cancelled_owner', 'cancelled_vet')
                           then nullif(trim(p_reason), '') else cancel_reason end,
      cancel_fee = case when p_to = 'cancelled_owner' then coalesce(p_fee, 0) else cancel_fee end
  where id = p_visit
  returning * into v;
  perform set_config('felix.visit_transition', 'off', true);
  insert into public.visit_events (visit_id, from_status, to_status, actor_id)
  values (p_visit, v_from, p_to, p_actor);
  return v;
end;
$$;

-- ---------------------------------------------------------------------------
-- QA-F6-03: cargo de cancelación (en_route atrasada = gratis)
-- ---------------------------------------------------------------------------
create or replace function private.cancel_fee_for(v public.visits, p_at timestamptz)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select case
    -- Antes de que el vet confirme (o mientras se busca vet): gratis.
    when v.status not in ('accepted', 'en_route') then 0
    -- Urgencia: gratis antes de "en camino".
    when v.mode = 'urgent' then case when v.status = 'en_route' then c.cancel_fee else 0 end
    -- El vet va "en camino" pero ya pasó la hora + 30 min: gratis.
    when v.status = 'en_route'
      and p_at >= v.scheduled_at + (select t.late_free_after from private.visit_timing() t)
      then 0
    -- Agendada: gratis hasta N horas antes (2 por defecto) y sin vet en camino.
    when v.status = 'en_route'
      or p_at >= v.scheduled_at - make_interval(hours => c.cancel_free_hours)
      then c.cancel_fee
    else 0
  end
  from (select (private.visit_pricing_config(v)).*) c;
$$;

-- ---------------------------------------------------------------------------
-- QA-F6-04: horario de llegar, iniciar y completar
-- ---------------------------------------------------------------------------
create or replace function private.transition_visit(p_visit_id uuid, p_to text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text := (select private.current_app_role());
  v public.visits;
  v_fee integer := 0;
  r record;
  t record;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para continuar' using errcode = '42501';
  end if;
  if p_reason is not null and char_length(p_reason) > 300 then
    raise exception 'El motivo admite hasta 300 caracteres' using errcode = '22023';
  end if;
  select * into r from private.visit_rules();
  select * into t from private.visit_timing();

  select * into v from public.visits where id = p_visit_id for update;
  -- Sin distinguir "no existe" de "no es tuya" (no se filtra información).
  if not found or (v.owner_id is distinct from v_uid and v.vet_id is distinct from v_uid) then
    raise exception 'La visita no existe' using errcode = '22023';
  end if;
  if not private.visit_edge_allowed(v.status, p_to) then
    raise exception 'Transición no permitida: % → %', v.status, coalesce(p_to, '(vacío)')
      using errcode = '22023';
  end if;

  if v.vet_id = v_uid and v_role = 'vet' then
    if p_to not in ('accepted', 'rejected', 'en_route', 'arrived', 'in_progress',
                    'completed', 'cancelled_vet') then
      raise exception 'Esta acción le corresponde al dueño' using errcode = '42501';
    end if;
    if p_to = 'accepted' then
      if now() > v.confirm_deadline then
        raise exception 'El plazo para confirmar venció' using errcode = '22023';
      end if;
      if (select private.current_vet_status()) is distinct from 'approved' then
        raise exception 'Tu cuenta no está habilitada para atender' using errcode = '42501';
      end if;
    end if;
    if v.mode = 'scheduled' then
      if p_to = 'en_route' and now() < v.scheduled_at - r.en_route_from then
        raise exception 'Puedes marcar "en camino" desde 2 horas antes de la visita'
          using errcode = '22023';
      end if;
      if p_to in ('arrived', 'in_progress') and now() < v.scheduled_at - t.arrive_from then
        raise exception 'Puedes marcar la llegada y el inicio desde 30 minutos antes de la visita'
          using errcode = '22023';
      end if;
    end if;
    if p_to = 'completed' and now() < v.started_at + t.min_service then
      raise exception 'La atención debe durar al menos 10 minutos antes de completarla'
        using errcode = '22023';
    end if;
  elsif v.owner_id = v_uid and v_role = 'owner' then
    if p_to <> 'cancelled_owner' then
      raise exception 'Esta acción le corresponde al veterinario' using errcode = '42501';
    end if;
    v_fee := coalesce(private.cancel_fee_for(v, now()), 0);
  else
    raise exception 'No puedes cambiar esta visita' using errcode = '42501';
  end if;

  v := private.apply_transition(v.id, p_to, v_uid, p_reason, v_fee);
  if v.cancel_fee > 0 and p_to = 'cancelled_owner' then
    perform private.charge_cancel_fee(v);
  end if;
  return jsonb_build_object('visit_id', v.id, 'status', v.status, 'cancel_fee', v.cancel_fee);
end;
$$;

-- ---------------------------------------------------------------------------
-- QA-F6-03: cierre automático de visitas que nunca empiezan
-- ---------------------------------------------------------------------------
create or replace function private.expire_visits()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  r record;
  t record;
  v_id uuid;
  v_n integer := 0;
begin
  select * into r from private.visit_rules();
  select * into t from private.visit_timing();
  for v_id in
    select v.id from public.visits v
    where v.status = 'pending_vet' and v.confirm_deadline <= now()
    order by v.confirm_deadline
    limit 500
    for update skip locked
  loop
    perform private.apply_transition(v_id, 'expired', null, null, 0);
    v_n := v_n + 1;
  end loop;
  for v_id in
    select v.id from public.visits v
    where v.status = 'accepted' and v.scheduled_at + r.no_show_after <= now()
    order by v.scheduled_at
    limit 500
    for update skip locked
  loop
    perform private.apply_transition(v_id, 'cancelled_vet', null,
      'El veterinario no inició la visita a tiempo (cierre automático).', 0);
    v_n := v_n + 1;
  end loop;
  for v_id in
    select v.id from public.visits v
    where v.status in ('en_route', 'arrived') and v.scheduled_at + t.stale_after <= now()
    order by v.scheduled_at
    limit 500
    for update skip locked
  loop
    perform private.apply_transition(v_id, 'cancelled_vet', null,
      'La atención no comenzó a tiempo (cierre automático, sin cargo).', 0);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create index visits_stale_start_idx on public.visits (scheduled_at)
  where status in ('en_route', 'arrived');

-- ---------------------------------------------------------------------------
-- QA-F6-01: sin punto de partida no hay cotización ni reserva con ese vet
-- ---------------------------------------------------------------------------
create or replace function private.create_quote(
  p_pet_id uuid,
  p_address_id uuid,
  p_specialty_id integer,
  p_mode text,
  p_vet_id uuid,
  p_foundation_id uuid,
  p_extra_donation integer
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_origin extensions.geography;
  v_q public.quotes;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño puede cotizar' using errcode = '42501';
  end if;
  if p_vet_id is not null then
    select b.quote_origin into v_origin from public.vet_bases b where b.vet_id = p_vet_id;
    if v_origin is null then
      raise exception 'El veterinario no tiene punto de partida' using errcode = '22023';
    end if;
  end if;
  v_q := private.quote_for(
    v_uid, p_pet_id, p_address_id, p_specialty_id, p_mode, p_vet_id,
    v_origin, p_foundation_id, p_extra_donation);
  return private.quote_snapshot(v_q);
end;
$$;

create or replace function private.consume_quote(
  p_quote_id uuid, p_owner uuid, p_vet_id uuid, p_pet_id uuid, p_address_id uuid)
returns public.quotes
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_q public.quotes;
begin
  select * into v_q from public.quotes q where q.id = p_quote_id for update;
  if not found or v_q.owner_id is distinct from p_owner then
    raise exception 'La cotización no existe' using errcode = '22023';
  end if;
  if v_q.mode <> 'scheduled' or v_q.vet_id is null then
    raise exception 'La cotización no corresponde a una visita agendada con veterinario'
      using errcode = '22023';
  end if;
  if v_q.vet_id is distinct from p_vet_id or v_q.pet_id is distinct from p_pet_id
     or v_q.address_id is distinct from p_address_id then
    raise exception 'La cotización no coincide con el veterinario, la mascota o la dirección elegidos'
      using errcode = '22023';
  end if;
  -- QA-F6-01: la distancia (recargo y radio) debe venir del punto de partida.
  if v_q.distance_m is null
     or not exists (select 1 from public.vet_bases b where b.vet_id = v_q.vet_id) then
    raise exception 'El veterinario no tiene punto de partida' using errcode = '22023';
  end if;
  return private.consume_quote(p_quote_id, p_owner);
end;
$$;

-- ---------------------------------------------------------------------------
-- QA-F6-05: búsqueda acotada y con tope por dueño
-- ---------------------------------------------------------------------------
create table private.search_quota (
  user_id uuid primary key references auth.users (id) on delete cascade,
  window_start timestamptz not null,
  calls integer not null
);
revoke all on private.search_quota from public, anon, authenticated;

-- Horarios libres en una sola consulta (antes: una llamada a vet_slot_ok por
-- horario). Mismas reglas que vet_slot_ok, que sigue validando la reserva.
create or replace function private.vet_open_slots(p_vet uuid, p_date date)
returns setof timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  with r as (select * from private.visit_rules()),
  c as (
    select distinct
      (p_date::timestamp + make_interval(mins => g.mins)) at time zone 'America/Santiago'
        as starts_at
    from r
    cross join lateral generate_series(0, 1440 - r.step_min, r.step_min) as g (mins)
    where exists (select 1 from public.vet_availability a
                  where a.vet_id = p_vet and a.weekday = extract(isodow from p_date)
                    and a.start_min <= g.mins and a.end_min >= g.mins + r.service_min)
  )
  select c.starts_at
  from c, r
  where c.starts_at >= now() + r.min_lead
    and c.starts_at <= now() + r.horizon
    and not exists (
      select 1 from public.vet_time_off t
      where t.vet_id = p_vet
        and t.period && tstzrange(c.starts_at, c.starts_at + make_interval(mins => r.service_min)))
    and not exists (
      select 1 from public.visits v
      where v.vet_id = p_vet
        and v.status in ('pending_vet', 'accepted', 'en_route', 'arrived', 'in_progress')
        and v.slot && tstzrange(c.starts_at,
                                c.starts_at + make_interval(mins => r.service_min + r.travel_min)))
  order by c.starts_at;
$$;

create or replace function private.find_available_vets(
  p_pet_id uuid, p_address_id uuid, p_specialty_id integer, p_date date)
returns setof jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_species integer;
  v_location extensions.geography;
  v_today date := (now() at time zone 'America/Santiago')::date;
  v_max_km integer := (select c.max_distance_km from public.current_pricing_config() c);
  v_calls integer;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño puede buscar veterinarios' using errcode = '42501';
  end if;

  -- Tope: 30 búsquedas por dueño y minuto (serializado por dueño).
  perform pg_advisory_xact_lock(hashtextextended('available_vets:' || v_uid::text, 0));
  insert into private.search_quota as q (user_id, window_start, calls)
  values (v_uid, now(), 1)
  on conflict (user_id) do update
    set window_start = case when q.window_start <= now() - interval '1 minute'
                            then now() else q.window_start end,
        calls = case when q.window_start <= now() - interval '1 minute'
                     then 1 else q.calls + 1 end
  returning calls into v_calls;
  if v_calls > 30 then
    raise exception 'Demasiadas búsquedas. Espera un minuto.' using errcode = '22023';
  end if;

  select p.species_id into v_species from public.pets p
  where p.id = p_pet_id and p.owner_id = v_uid and p.active;
  if not found then
    raise exception 'La mascota no existe o no está activa' using errcode = '22023';
  end if;
  select a.location into v_location from public.addresses a
  where a.id = p_address_id and a.owner_id = v_uid and a.active;
  if not found then
    raise exception 'La dirección no existe o no está activa' using errcode = '22023';
  end if;
  if p_date is null or p_date < v_today or p_date > v_today + 30 then
    raise exception 'Elige una fecha dentro de los próximos 30 días' using errcode = '22023';
  end if;

  return query
  with near as (
    -- Los 30 compatibles más cercanos al origen aproximado (KNN sobre el GiST
    -- vet_bases_quote_origin_gix), con horario ese día de la semana.
    select v.user_id, v.display_name, v.bio,
           extensions.st_distance(b.quote_origin, v_location) as dist
    from public.vet_bases b
    join public.vet_profiles v on v.user_id = b.vet_id and v.status = 'approved'
    join public.vet_species vs on vs.vet_id = b.vet_id and vs.species_id = v_species
    join public.vet_specialties vsp on vsp.vet_id = b.vet_id
                                   and vsp.specialty_id = p_specialty_id
    where extensions.st_dwithin(b.quote_origin, v_location, v_max_km * 1000)
      and exists (select 1 from public.vet_availability a
                  where a.vet_id = b.vet_id and a.weekday = extract(isodow from p_date))
    order by b.quote_origin operator(extensions.<->) v_location
    limit 30
  )
  select jsonb_build_object(
           'vet_id', n.user_id,
           'display_name', n.display_name,
           'bio', n.bio,
           -- Desde el origen aproximado (QA-F5-01), redondeada al km.
           'distance_km', round(n.dist / 1000.0)::integer,
           'slots', s.slots)
  from near n
  cross join lateral (
    select jsonb_agg(x.starts_at order by x.starts_at) as slots
    from private.vet_open_slots(n.user_id, p_date) as x (starts_at)) s
  where s.slots is not null
  order by n.dist, n.display_name
  limit 20;
end;
$$;

create or replace function public.available_vets(
  p_pet_id uuid, p_address_id uuid, p_specialty_id integer, p_date date)
returns setof jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.find_available_vets(p_pet_id, p_address_id, p_specialty_id, p_date);
$$;

-- ---------------------------------------------------------------------------
-- QA-F6-02: el admin no lee el historial fila a fila
-- ---------------------------------------------------------------------------
drop policy visit_events_admin_read on public.visit_events;
revoke select on public.visit_events from authenticated;
