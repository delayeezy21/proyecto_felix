-- Fase 6: visitas agendadas (Beta 1).
-- Ver SPEC.md HU2.2 y HU2.3, §3 (confirmación, cancelación y dirección) y
-- docs/arquitectura.md §4, §5 y §11.
--
-- Flujo: disponibilidad (available_vets) → cotización con vet (quote_visit)
-- → reserva (book_visit: consume la cotización y congela su snapshot en
-- visits.quote) → el vet confirma o rechaza (o expira por pg_cron) → en
-- camino → llegó → en curso → completada → el dueño paga (simulate_payment).
--
-- Principios:
-- * El estado cambia SOLO con transition_visit (una función interna marca la
--   transacción y el trigger guardián rechaza cualquier otro UPDATE de estado
--   o un borde que no esté en la máquina de estados).
-- * La app no tiene INSERT/UPDATE sobre visits: todo pasa por RPC.
-- * Sin doble reserva: restricción de exclusión (vet, slot) sobre las visitas
--   activas; el slot incluye 60 min de atención + 30 min de traslado.
-- * Privacidad: el vet ve la dirección exacta y el teléfono del dueño solo
--   mientras la visita le está asignada y activa (accepted → in_progress);
--   antes y después, solo la comuna y la distancia redondeada a 0,5 km
--   (private.address_approx). El dueño ve del vet solo los datos públicos.
-- * Horas locales de Chile (America/Santiago): vet_availability guarda
--   minutos locales.
-- * Escala: índices por vet, dueño y estado; (select auth.uid()) en RLS.

-- ---------------------------------------------------------------------------
-- Parámetros de agenda (constantes del diseño; el cargo y la ventana de
-- cancelación gratis viven en pricing_config, versionados).
-- ---------------------------------------------------------------------------
create function private.visit_rules()
returns table (
  service_min integer,      -- duración de la atención
  travel_min integer,       -- margen de traslado tras cada visita (SPEC HU2.2)
  step_min integer,         -- granularidad de los horarios ofrecidos
  min_lead interval,        -- anticipación mínima al reservar
  horizon interval,         -- hasta cuándo se puede reservar
  confirm_window interval,  -- plazo del vet para confirmar (SPEC §3)
  confirm_cutoff interval,  -- ... o hasta esta antelación, lo primero
  en_route_from interval,   -- desde cuándo puede marcar "en camino"
  no_show_after interval,   -- confirmada que nunca empieza: cierre automático
  max_open_per_owner integer
)
language sql
immutable
set search_path = ''
as $$
  -- min_lead = 3 h: el vet debe confirmar hasta 2 h antes, así siempre tiene
  -- al menos 1 h para responder (SPEC: "al menos 2 h de anticipación").
  select 60, 30, 30, interval '3 hours', interval '30 days', interval '12 hours',
         interval '2 hours', interval '2 hours', interval '1 hour', 5;
$$;
revoke execute on function private.visit_rules() from public, anon, authenticated;

-- Ventana de cancelación gratis (horas antes de la visita agendada).
alter table public.pricing_config
  add column cancel_free_hours integer not null default 2
    check (cancel_free_hours between 0 and 72);

-- ---------------------------------------------------------------------------
-- Días libres del vet (SPEC HU1.5 / HU2.2)
-- ---------------------------------------------------------------------------
create table public.vet_time_off (
  id uuid primary key default gen_random_uuid(),
  vet_id uuid not null references public.vet_profiles (user_id) on delete cascade,
  period tstzrange not null,
  created_at timestamptz not null default now(),
  constraint vet_time_off_bounded check (
    not isempty(period) and lower(period) is not null and upper(period) is not null
    and upper(period) - lower(period) <= interval '120 days')
);

create index vet_time_off_vet_period_gix on public.vet_time_off using gist (vet_id, period);

alter table public.vet_time_off enable row level security;
alter table public.vet_time_off force row level security;

create policy vet_time_off_read on public.vet_time_off
for select to authenticated
using (vet_id = (select auth.uid()) or (select private.is_admin()));
create policy vet_time_off_insert_self on public.vet_time_off
for insert to authenticated
with check (vet_id = (select auth.uid())
            and (select private.current_vet_status()) = 'approved');
create policy vet_time_off_delete_self on public.vet_time_off
for delete to authenticated
using (vet_id = (select auth.uid()));

-- Días completos en hora de Chile (el cliente no calcula zonas horarias).
create function public.add_time_off(p_from date, p_to date)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Elige un rango de fechas válido' using errcode = '22023';
  end if;
  if p_from < (now() at time zone 'America/Santiago')::date then
    raise exception 'Los días libres no pueden estar en el pasado' using errcode = '22023';
  end if;
  insert into public.vet_time_off (vet_id, period)
  values ((select auth.uid()),
          tstzrange(p_from::timestamp at time zone 'America/Santiago',
                    (p_to + 1)::timestamp at time zone 'America/Santiago'))
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Visitas
-- ---------------------------------------------------------------------------
create table public.visits (
  id uuid primary key default gen_random_uuid(),
  -- Nullables para anonimizar en el borrado (fase 11).
  owner_id uuid references public.owner_profiles (user_id) on delete set null,
  pet_id uuid references public.pets (id) on delete set null,
  address_id uuid references public.addresses (id) on delete set null,
  vet_id uuid references public.vet_profiles (user_id) on delete set null,
  quote_id uuid unique references public.quotes (id) on delete set null,
  mode text not null check (mode in ('urgent', 'scheduled')),
  status text not null check (status in (
    'searching', 'pending_vet', 'accepted', 'en_route', 'arrived', 'in_progress',
    'completed', 'rejected', 'expired', 'no_vet_found', 'cancelled_owner', 'cancelled_vet')),
  commune_id integer not null references public.communes (id),
  species_id integer not null references public.species (id),
  specialty_id integer not null references public.specialties (id),
  foundation_id uuid not null references public.foundations (id),
  scheduled_at timestamptz,
  slot tstzrange,
  confirm_deadline timestamptz,
  -- Snapshot congelado de la cotización (private.quote_snapshot).
  quote jsonb not null,
  owner_notes text check (owner_notes is null or char_length(owner_notes) <= 300),
  is_preventive boolean not null default false,
  cancel_reason text check (cancel_reason is null or char_length(cancel_reason) <= 300),
  cancel_fee integer not null default 0 check (cancel_fee >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  accepted_at timestamptz,
  completed_at timestamptz,
  closed_at timestamptz,
  constraint visits_scheduled_fields check (
    mode <> 'scheduled'
    or (scheduled_at is not null and slot is not null and confirm_deadline is not null)),
  constraint visits_slot_start check (slot is null or lower(slot) = scheduled_at),
  -- Sin doble reserva (incluye el margen de traslado dentro del slot).
  constraint visits_no_overlap exclude using gist (vet_id with =, slot with &&)
    where (status in ('pending_vet', 'accepted', 'en_route', 'arrived', 'in_progress'))
);

create index visits_owner_idx on public.visits (owner_id, scheduled_at desc);
create index visits_vet_idx on public.visits (vet_id, scheduled_at desc);
create index visits_pet_idx on public.visits (pet_id);
create index visits_address_idx on public.visits (address_id);
create index visits_commune_idx on public.visits (commune_id);
create index visits_species_idx on public.visits (species_id);
create index visits_specialty_idx on public.visits (specialty_id);
create index visits_foundation_idx on public.visits (foundation_id);
-- Para el cron de expiración.
create index visits_pending_deadline_idx on public.visits (confirm_deadline)
  where status = 'pending_vet';
create index visits_accepted_start_idx on public.visits (scheduled_at)
  where status = 'accepted';
create index visits_created_idx on public.visits (created_at);

-- Historial de estados (solo inserción, desde las funciones internas).
create table public.visit_events (
  id bigint generated always as identity primary key,
  visit_id uuid not null references public.visits (id) on delete cascade,
  from_status text,
  to_status text not null,
  actor_id uuid references auth.users (id) on delete set null,
  at timestamptz not null default now()
);

create index visit_events_visit_idx on public.visit_events (visit_id);
create index visit_events_actor_idx on public.visit_events (actor_id);

-- Bordes de la máquina de estados (docs/arquitectura.md §5). Se suma
-- pending_vet → cancelled_owner: el dueño puede retirar una solicitud que el
-- vet aún no confirma (siempre gratis).
create function private.visit_edge_allowed(p_from text, p_to text)
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
    ('arrived', 'in_progress'),
    ('in_progress', 'completed'));
$$;
revoke execute on function private.visit_edge_allowed(text, text) from public, anon, authenticated;

-- Guardián: el estado y los datos del ciclo de vida cambian solo dentro de
-- private.apply_transition (marca local de la transacción) y por un borde
-- permitido. El precio congelado y el contexto de la visita no cambian nunca.
create function private.guard_visit()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_in_transition boolean :=
    coalesce(current_setting('felix.visit_transition', true), '') = 'on';
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
revoke execute on function private.guard_visit() from public, anon, authenticated;

create trigger visits_guard before insert or update on public.visits
for each row execute function private.guard_visit();

alter table public.visits enable row level security;
alter table public.visits force row level security;
alter table public.visit_events enable row level security;
alter table public.visit_events force row level security;

-- Lectura directa solo de los participantes y de columnas sin datos de
-- terceros (estado y fecha; útil para refrescar). El detalle va por
-- my_visits, que aplica las reglas de privacidad. El admin no lee filas:
-- solo el resumen agregado (admin_visit_summary).
create policy visits_select_participants on public.visits
for select to authenticated
using (owner_id = (select auth.uid()) or vet_id = (select auth.uid()));
create policy visit_events_admin_read on public.visit_events
for select to authenticated using ((select private.is_admin()));

-- ---------------------------------------------------------------------------
-- Disponibilidad
-- ---------------------------------------------------------------------------
-- ¿Puede el vet atender una visita que empieza en p_start? Bloque semanal
-- (hora de Chile), fuera de días libres, sin solaparse con sus visitas
-- activas (con traslado), con la anticipación mínima y dentro del horizonte.
create function private.vet_slot_ok(p_vet uuid, p_start timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with r as (select * from private.visit_rules()),
  l as (
    select (p_start at time zone 'America/Santiago') as lt,
           (extract(hour from p_start at time zone 'America/Santiago') * 60
            + extract(minute from p_start at time zone 'America/Santiago'))::integer as m
  )
  select coalesce(
    extract(second from p_start) = 0
    and l.m % r.step_min = 0
    and p_start >= now() + r.min_lead
    and p_start <= now() + r.horizon
    and exists (
      select 1 from public.vet_availability a
      where a.vet_id = p_vet
        and a.weekday = extract(isodow from l.lt)
        and a.start_min <= l.m
        and a.end_min >= l.m + r.service_min)
    and not exists (
      select 1 from public.vet_time_off t
      where t.vet_id = p_vet
        and t.period && tstzrange(p_start, p_start + make_interval(mins => r.service_min)))
    and not exists (
      select 1 from public.visits v
      where v.vet_id = p_vet
        and v.status in ('pending_vet', 'accepted', 'en_route', 'arrived', 'in_progress')
        and v.slot && tstzrange(p_start,
                                p_start + make_interval(mins => r.service_min + r.travel_min))),
    false)
  from r, l;
$$;
revoke execute on function private.vet_slot_ok(uuid, timestamptz) from public, anon, authenticated;

-- Horarios libres de un vet en un día (hora de Chile).
create function private.vet_open_slots(p_vet uuid, p_date date)
returns setof timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select distinct s.starts_at
  from private.visit_rules() r
  cross join lateral generate_series(0, 1440 - r.step_min, r.step_min) as g (mins)
  cross join lateral (
    select (p_date::timestamp + make_interval(mins => g.mins))
           at time zone 'America/Santiago' as starts_at) s
  where exists (select 1 from public.vet_availability a
                where a.vet_id = p_vet and a.weekday = extract(isodow from p_date)
                  and a.start_min <= g.mins and a.end_min >= g.mins + r.service_min)
    and private.vet_slot_ok(p_vet, s.starts_at)
  order by s.starts_at;
$$;
revoke execute on function private.vet_open_slots(uuid, date) from public, anon, authenticated;

-- Vets disponibles para la mascota, la dirección y la especialidad del dueño
-- en una fecha: aprobados, con la especie y la especialidad, con punto de
-- partida a ≤ 30 km y con al menos un horario libre. Solo datos públicos.
create function private.find_available_vets(
  p_pet_id uuid, p_address_id uuid, p_specialty_id integer, p_date date)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_species integer;
  v_location extensions.geography;
  v_today date := (now() at time zone 'America/Santiago')::date;
  r record;
  -- Mismo radio máximo que la cotización (QA-F5-02, versionado).
  v_max_km integer := (select c.max_distance_km from public.current_pricing_config() c);
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño puede buscar veterinarios' using errcode = '42501';
  end if;
  select * into r from private.visit_rules();
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
  select jsonb_build_object(
           'vet_id', v.user_id,
           'display_name', v.display_name,
           'bio', v.bio,
           -- Desde el origen aproximado (QA-F5-01), redondeada al km como la
           -- cotización: nunca desde la base real.
           'distance_km', round(extensions.st_distance(b.quote_origin, v_location) / 1000.0)::integer,
           'slots', s.slots)
  from public.vet_profiles v
  join public.vet_bases b on b.vet_id = v.user_id
  join public.vet_species vs on vs.vet_id = v.user_id and vs.species_id = v_species
  join public.vet_specialties vsp on vsp.vet_id = v.user_id
                                 and vsp.specialty_id = p_specialty_id
  cross join lateral (
    select jsonb_agg(x.starts_at order by x.starts_at) as slots
    from private.vet_open_slots(v.user_id, p_date) as x (starts_at)) s
  where v.status = 'approved'
    and extensions.st_dwithin(b.quote_origin, v_location, v_max_km * 1000)
    and s.slots is not null
  order by extensions.st_distance(b.quote_origin, v_location), v.display_name
  limit 20;
end;
$$;
revoke execute on function private.find_available_vets(uuid, uuid, integer, date) from public, anon;
grant execute on function private.find_available_vets(uuid, uuid, integer, date) to authenticated;

-- Búsqueda por cercanía desde el origen aproximado.
create index vet_bases_quote_origin_gix on public.vet_bases using gist (quote_origin);

create function public.available_vets(
  p_pet_id uuid, p_address_id uuid, p_specialty_id integer, p_date date)
returns setof jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.find_available_vets(p_pet_id, p_address_id, p_specialty_id, p_date);
$$;

-- ---------------------------------------------------------------------------
-- Pagos ligados a la visita
-- ---------------------------------------------------------------------------
alter table public.payments
  add column visit_id uuid references public.visits (id) on delete set null,
  add column vet_id uuid references public.vet_profiles (user_id) on delete set null;

create index payments_visit_idx on public.payments (visit_id);
create index payments_vet_idx on public.payments (vet_id, created_at desc);
-- Una visita se paga una vez por tipo (visita o cargo de cancelación).
create unique index payments_visit_paid_once on public.payments (visit_id, kind)
  where status = 'simulated_paid';

create or replace function private.guard_payment()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'pending' then
      raise exception 'Un pago nace pendiente' using errcode = '22023';
    end if;
    return new;
  end if;
  if (new.foundation_id, new.kind, new.provider, new.service_price, new.platform_fee,
      new.foundation_share, new.vet_payout, new.extra_donation, new.total, new.created_at)
     is distinct from
     (old.foundation_id, old.kind, old.provider, old.service_price, old.platform_fee,
      old.foundation_share, old.vet_payout, old.extra_donation, old.total, old.created_at)
     or (new.quote_id is distinct from old.quote_id and new.quote_id is not null)
     or (new.owner_id is distinct from old.owner_id and new.owner_id is not null)
     or (new.visit_id is distinct from old.visit_id and new.visit_id is not null)
     or (new.vet_id is distinct from old.vet_id and new.vet_id is not null) then
    raise exception 'Los montos de un pago no se modifican' using errcode = '42501';
  end if;
  if new.status is distinct from old.status
     and not (old.status = 'pending' and new.status in ('simulated_paid', 'simulated_failed')) then
    raise exception 'Transición de pago no permitida: % → %', old.status, new.status
      using errcode = '22023';
  end if;
  return new;
end;
$$;

-- El dueño ve sus pagos y el vet los de sus visitas (su liquidación); el
-- admin, todos. Las fundaciones nunca (solo agregados).
drop policy payments_select on public.payments;
create policy payments_select on public.payments
for select to authenticated
using (owner_id = (select auth.uid()) or vet_id = (select auth.uid())
       or (select private.is_admin()));

-- Registro de un pago simulado (pendiente → pagado o rechazado). Interna.
create function private.record_payment(
  p_owner uuid, p_vet uuid, p_visit uuid, p_quote uuid, p_foundation uuid, p_kind text,
  p_service integer, p_fee integer, p_share integer, p_payout integer, p_donation integer,
  p_fail boolean)
returns public.payments
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_p public.payments;
begin
  insert into public.payments (owner_id, vet_id, visit_id, quote_id, foundation_id, kind,
    service_price, platform_fee, foundation_share, vet_payout, extra_donation, total)
  values (p_owner, p_vet, p_visit, p_quote, p_foundation, p_kind,
    p_service, p_fee, p_share, p_payout, p_donation, p_service + p_donation)
  returning * into v_p;

  update public.payments
  set status = case when coalesce(p_fail, false) then 'simulated_failed' else 'simulated_paid' end,
      paid_at = case when coalesce(p_fail, false) then null else now() end
  where id = v_p.id
  returning * into v_p;
  return v_p;
end;
$$;
revoke execute on function private.record_payment(uuid, uuid, uuid, uuid, uuid, text,
  integer, integer, integer, integer, integer, boolean) from public, anon, authenticated;

-- Fase 5 → 6: ya no se paga una cotización suelta. El cobro es de una visita
-- completada (in_progress → completed) y por su precio congelado.
drop function public.simulate_payment(uuid, boolean);
drop function private.pay_quote_simulated(uuid, boolean);

create function private.pay_visit_simulated(p_visit_id uuid, p_simulate_failure boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v public.visits;
  v_p public.payments;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño puede pagar' using errcode = '42501';
  end if;
  select * into v from public.visits where id = p_visit_id for update;
  if not found or v.owner_id is distinct from v_uid then
    raise exception 'La visita no existe' using errcode = '22023';
  end if;
  if v.status <> 'completed' then
    raise exception 'Solo puedes pagar una visita completada' using errcode = '22023';
  end if;
  if exists (select 1 from public.payments p where p.visit_id = v.id and p.kind = 'visit'
             and p.status = 'simulated_paid') then
    raise exception 'Esta visita ya está pagada' using errcode = '22023';
  end if;
  if (select count(*) from public.payments p where p.visit_id = v.id and p.kind = 'visit') >= 5 then
    raise exception 'Demasiados intentos de pago para esta visita' using errcode = '22023';
  end if;

  v_p := private.record_payment(v.owner_id, v.vet_id, v.id, v.quote_id, v.foundation_id, 'visit',
    (v.quote ->> 'service_price')::integer, (v.quote ->> 'platform_fee')::integer,
    (v.quote ->> 'foundation_share')::integer, (v.quote ->> 'vet_payout')::integer,
    (v.quote ->> 'extra_donation')::integer, p_simulate_failure);

  return jsonb_build_object(
    'payment_id', v_p.id, 'visit_id', v.id, 'status', v_p.status,
    'total', v_p.total, 'service_price', v_p.service_price,
    'platform_fee', v_p.platform_fee, 'foundation_share', v_p.foundation_share,
    'vet_payout', v_p.vet_payout, 'extra_donation', v_p.extra_donation,
    'paid_at', v_p.paid_at);
end;
$$;
revoke execute on function private.pay_visit_simulated(uuid, boolean) from public, anon;
grant execute on function private.pay_visit_simulated(uuid, boolean) to authenticated;

create function public.simulate_payment(p_visit_id uuid, p_simulate_failure boolean default false)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.pay_visit_simulated(p_visit_id, p_simulate_failure);
$$;

-- ---------------------------------------------------------------------------
-- Cancelación: cargo según estado y hora (parámetros de la versión de
-- pricing_config congelada en la cotización de la visita).
-- ---------------------------------------------------------------------------
create function private.visit_pricing_config(v public.visits)
returns public.pricing_config
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select c from public.pricing_config c where c.id = (v.quote ->> 'pricing_config_id')::integer),
    (select c from public.current_pricing_config() c));
$$;
revoke execute on function private.visit_pricing_config(public.visits) from public, anon, authenticated;

create function private.cancel_fee_for(v public.visits, p_at timestamptz)
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
    -- Agendada: gratis hasta N horas antes (2 por defecto) y sin vet en camino.
    when v.status = 'en_route'
      or p_at >= v.scheduled_at - make_interval(hours => c.cancel_free_hours)
      then c.cancel_fee
    else 0
  end
  from (select (private.visit_pricing_config(v)).*) c;
$$;
revoke execute on function private.cancel_fee_for(public.visits, timestamptz)
  from public, anon, authenticated;

-- Cargo simulado: mismo reparto que una visita (comisión, fundación y vet).
create function private.charge_cancel_fee(v public.visits)
returns public.payments
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c public.pricing_config := private.visit_pricing_config(v);
  v_fee integer;
begin
  v_fee := private.clp_round(v.cancel_fee * c.commission_pct / 100);
  return private.record_payment(v.owner_id, v.vet_id, v.id, null, v.foundation_id,
    'cancel_fee', v.cancel_fee, v_fee, private.clp_round(v_fee * c.foundation_pct / 100),
    v.cancel_fee - v_fee, 0, false);
end;
$$;
revoke execute on function private.charge_cancel_fee(public.visits) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Transiciones
-- ---------------------------------------------------------------------------
-- Núcleo (sin EXECUTE para la app): aplica un borde ya autorizado.
create function private.apply_transition(
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
revoke execute on function private.apply_transition(uuid, text, uuid, text, integer)
  from public, anon, authenticated;

-- Punto de entrada de la app: valida quién puede hacer cada transición.
create function private.transition_visit(p_visit_id uuid, p_to text, p_reason text)
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
begin
  if v_uid is null then
    raise exception 'Inicia sesión para continuar' using errcode = '42501';
  end if;
  if p_reason is not null and char_length(p_reason) > 300 then
    raise exception 'El motivo admite hasta 300 caracteres' using errcode = '22023';
  end if;
  select * into r from private.visit_rules();

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
    if p_to = 'en_route' and v.mode = 'scheduled'
       and now() < v.scheduled_at - r.en_route_from then
      raise exception 'Puedes marcar "en camino" desde 2 horas antes de la visita'
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
revoke execute on function private.transition_visit(uuid, text, text) from public, anon;
grant execute on function private.transition_visit(uuid, text, text) to authenticated;

create function public.transition_visit(
  p_visit_id uuid, p_to_status text, p_reason text default null)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.transition_visit(p_visit_id, p_to_status, p_reason);
$$;

-- ---------------------------------------------------------------------------
-- Vista de una visita según quién mira (reglas de privacidad)
-- ---------------------------------------------------------------------------
create function private.visit_view(v public.visits, p_uid uuid)
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
      'cancel_reason', v.cancel_reason,
      'service_price', (v.quote ->> 'service_price')::integer,
      'vet_payout', (v.quote ->> 'vet_payout')::integer,
      'pet_name', p.name, 'species_name', sp.name, 'specialty_name', s.name,
      'commune_name', coalesce(ap.commune_name, c.name),
      'distance_km', coalesce(ap.distance_km_rounded, (v.quote ->> 'distance_km')::numeric),
      'paid', exists (select 1 from public.payments pay where pay.visit_id = v.id
                      and pay.kind = 'visit' and pay.status = 'simulated_paid'),
      -- Dirección exacta y contacto: solo asignado y con la visita activa.
      'exact', case when v.status in ('accepted', 'en_route', 'arrived', 'in_progress')
                         and a.id is not null
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
  left join lateral private.address_approx(v.address_id, b.location) ap
    on v.vet_id = p_uid and b.vet_id is not null;
$$;
revoke execute on function private.visit_view(public.visits, uuid) from public, anon, authenticated;

create function private.list_my_visits(p_limit integer)
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with me as (select (select auth.uid()) as uid, (select private.current_app_role()) as role),
  lim as (select least(greatest(coalesce(p_limit, 50), 1), 200) as n)
  (select private.visit_view(v, me.uid)
   from public.visits v, me, lim
   where me.role = 'owner' and v.owner_id = me.uid
   order by v.scheduled_at desc nulls last, v.created_at desc
   limit (select n from lim))
  union all
  (select private.visit_view(v, me.uid)
   from public.visits v, me, lim
   where me.role = 'vet' and v.vet_id = me.uid
   order by v.scheduled_at desc nulls last, v.created_at desc
   limit (select n from lim));
$$;
revoke execute on function private.list_my_visits(integer) from public, anon;
grant execute on function private.list_my_visits(integer) to authenticated;

create function public.my_visits(p_limit integer default 50)
returns setof jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.list_my_visits(p_limit);
$$;

-- ---------------------------------------------------------------------------
-- Reserva
-- ---------------------------------------------------------------------------
create function private.book_visit(
  p_quote_id uuid, p_vet_id uuid, p_pet_id uuid, p_address_id uuid,
  p_scheduled_at timestamptz, p_notes text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_q public.quotes;
  v public.visits;
  r record;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño puede reservar' using errcode = '42501';
  end if;
  if p_notes is not null and char_length(p_notes) > 300 then
    raise exception 'La nota admite hasta 300 caracteres' using errcode = '22023';
  end if;
  select * into r from private.visit_rules();

  select * into v_q from public.quotes q where q.id = p_quote_id and q.owner_id = v_uid;
  if not found then
    raise exception 'La cotización no existe' using errcode = '22023';
  end if;
  -- O-1 (QA fase 5): la cotización agendada debe traer vet (si no, saldría
  -- sin recargo por distancia) y coincidir con el vet, la mascota y la
  -- dirección que el dueño eligió. Se valida antes de consumirla.
  if v_q.mode <> 'scheduled' or v_q.vet_id is null then
    raise exception 'La cotización no corresponde a una visita agendada con veterinario'
      using errcode = '22023';
  end if;
  if v_q.vet_id is distinct from p_vet_id or v_q.pet_id is distinct from p_pet_id
     or v_q.address_id is distinct from p_address_id then
    raise exception 'La cotización no coincide con el veterinario, la mascota o la dirección elegidos'
      using errcode = '22023';
  end if;

  -- Tope anti abuso: visitas abiertas por dueño (serializado).
  perform pg_advisory_xact_lock(hashtextextended('visits:' || v_uid::text, 0));
  if (select count(*) from public.visits x
      where x.owner_id = v_uid
        and x.status in ('pending_vet', 'accepted', 'en_route', 'arrived', 'in_progress'))
     >= r.max_open_per_owner then
    raise exception 'Tienes demasiadas visitas abiertas' using errcode = '22023';
  end if;

  v_q := private.consume_quote(p_quote_id, v_uid);

  if not exists (select 1 from public.pets p
                 where p.id = v_q.pet_id and p.owner_id = v_uid and p.active) then
    raise exception 'La mascota no existe o no está activa' using errcode = '22023';
  end if;
  if not exists (select 1 from public.addresses a
                 where a.id = v_q.address_id and a.owner_id = v_uid and a.active) then
    raise exception 'La dirección no existe o no está activa' using errcode = '22023';
  end if;
  if not exists (select 1 from public.vet_profiles vp
                 join public.vet_species vs on vs.vet_id = vp.user_id
                                           and vs.species_id = v_q.species_id
                 join public.vet_specialties vsp on vsp.vet_id = vp.user_id
                                                and vsp.specialty_id = v_q.specialty_id
                 where vp.user_id = v_q.vet_id and vp.status = 'approved') then
    raise exception 'El veterinario ya no está disponible' using errcode = '22023';
  end if;
  if not private.vet_slot_ok(v_q.vet_id, p_scheduled_at) then
    raise exception 'El horario ya no está disponible. Elige otro.' using errcode = '22023';
  end if;

  begin
    insert into public.visits (owner_id, pet_id, address_id, vet_id, quote_id, mode, status,
      commune_id, species_id, specialty_id, foundation_id, scheduled_at, slot,
      confirm_deadline, quote, owner_notes)
    values (v_uid, v_q.pet_id, v_q.address_id, v_q.vet_id, v_q.id, 'scheduled', 'pending_vet',
      v_q.commune_id, v_q.species_id, v_q.specialty_id, v_q.foundation_id, p_scheduled_at,
      tstzrange(p_scheduled_at,
                p_scheduled_at + make_interval(mins => r.service_min + r.travel_min)),
      least(now() + r.confirm_window, p_scheduled_at - r.confirm_cutoff),
      private.quote_snapshot(v_q), nullif(trim(p_notes), ''))
    returning * into v;
  exception when exclusion_violation then
    -- Dos reservas simultáneas: gana la primera.
    raise exception 'El horario ya no está disponible. Elige otro.' using errcode = '22023';
  end;

  insert into public.visit_events (visit_id, from_status, to_status, actor_id)
  values (v.id, null, v.status, v_uid);
  return private.visit_view(v, v_uid);
end;
$$;
revoke execute on function private.book_visit(uuid, uuid, uuid, uuid, timestamptz, text)
  from public, anon;
grant execute on function private.book_visit(uuid, uuid, uuid, uuid, timestamptz, text)
  to authenticated;

create function public.book_visit(
  p_quote_id uuid, p_vet_id uuid, p_pet_id uuid, p_address_id uuid,
  p_scheduled_at timestamptz, p_notes text default null)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.book_visit(p_quote_id, p_vet_id, p_pet_id, p_address_id,
                            p_scheduled_at, p_notes);
$$;

-- ---------------------------------------------------------------------------
-- Admin: solo agregados (sin dueños, mascotas ni direcciones)
-- ---------------------------------------------------------------------------
create function private.visit_status_summary(p_days integer)
returns table (mode text, status text, total bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select v.mode, v.status, count(*)::bigint
  from public.visits v
  where (select private.is_admin())
    and v.created_at >= now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 365))
  group by v.mode, v.status
  order by v.mode, v.status;
$$;
revoke execute on function private.visit_status_summary(integer) from public, anon;
grant execute on function private.visit_status_summary(integer) to authenticated;

create function public.admin_visit_summary(p_days integer default 30)
returns table (mode text, status text, total bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.visit_status_summary(p_days);
$$;

-- ---------------------------------------------------------------------------
-- Trabajos programados (pg_cron)
-- ---------------------------------------------------------------------------
-- Expira las solicitudes no confirmadas a tiempo y cierra las confirmadas
-- que nunca empezaron (el vet no marcó "en camino" hasta 1 h después de la
-- hora): cancelled_vet automático, sin cargo para el dueño.
create function private.expire_visits()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  r record;
  v_id uuid;
  v_n integer := 0;
begin
  select * into r from private.visit_rules();
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
  return v_n;
end;
$$;
revoke execute on function private.expire_visits() from public, anon, authenticated;

-- Purga las cotizaciones vencidas y nunca usadas (las usadas viven con su
-- visita o su pago).
create function private.purge_stale_quotes()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  with doomed as (
    select q.id from public.quotes q
    where q.consumed_at is null and q.expires_at < now() - interval '1 day'
    order by q.expires_at
    limit 5000
  )
  delete from public.quotes q using doomed d where q.id = d.id;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function private.purge_stale_quotes() from public, anon, authenticated;

create index quotes_stale_idx on public.quotes (expires_at) where consumed_at is null;

select cron.schedule('expire-visits', '* * * * *', 'select private.expire_visits()');
select cron.schedule('purge-stale-quotes', '17 * * * *', 'select private.purge_stale_quotes()');

-- ---------------------------------------------------------------------------
-- Privilegios mínimos
-- ---------------------------------------------------------------------------
revoke all on public.visits, public.visit_events, public.vet_time_off
  from public, anon, authenticated;

grant select (id, owner_id, vet_id, mode, status, scheduled_at, confirm_deadline,
  created_at, updated_at) on public.visits to authenticated;
grant select on public.visit_events to authenticated;
grant select, delete on public.vet_time_off to authenticated;
grant insert (vet_id, period) on public.vet_time_off to authenticated;

revoke execute on function public.add_time_off(date, date) from public, anon;
grant execute on function public.add_time_off(date, date) to authenticated;
revoke execute on function public.available_vets(uuid, uuid, integer, date) from public, anon;
grant execute on function public.available_vets(uuid, uuid, integer, date) to authenticated;
revoke execute on function public.simulate_payment(uuid, boolean) from public, anon;
grant execute on function public.simulate_payment(uuid, boolean) to authenticated;
revoke execute on function public.transition_visit(uuid, text, text) from public, anon;
grant execute on function public.transition_visit(uuid, text, text) to authenticated;
revoke execute on function public.my_visits(integer) from public, anon;
grant execute on function public.my_visits(integer) to authenticated;
revoke execute on function public.book_visit(uuid, uuid, uuid, uuid, timestamptz, text)
  from public, anon;
grant execute on function public.book_visit(uuid, uuid, uuid, uuid, timestamptz, text)
  to authenticated;
revoke execute on function public.admin_visit_summary(integer) from public, anon;
grant execute on function public.admin_visit_summary(integer) to authenticated;
