-- Fase 10: suscripciones simuladas (SPEC F5, HU5.1–HU5.3; arquitectura §4 y
-- "Fase 10").
--
-- * Catálogo `subscription_plans` (Básico, Plus, Familia), editable por el
--   admin con auditoría; se desactiva, no se borra.
-- * `subscriptions` + `subscription_pets`: una sola abierta por dueño, período
--   mensual en hora de Chile anclado al día de alta, renovación simulada por
--   pg_cron (`renew-subscriptions`) con un pago `subscription` por período.
-- * Beneficios en la cotización (private.quote_for): descuento a la base,
--   recargo de urgencia omitido y preventiva incluida (base $0) con cupo de
--   12 meses móviles. La cotización congela el plan aplicado.
-- * El descuento lo absorbe la plataforma (`plan_subsidy`): el vet cobra lo
--   mismo que sin plan y la fundación recibe lo mismo (decisión a confirmar).
-- * El vet y la fundación nunca ven el plan: al vet se le muestra el precio
--   de lista (servicio + subsidio), igual que a un dueño sin plan.

-- ===========================================================================
-- 1. Catálogo de planes
-- ===========================================================================
create table public.subscription_plans (
  id integer generated always as identity primary key,
  slug text not null unique check (slug ~ '^[a-z0-9_]{2,30}$'),
  name text not null check (char_length(name) between 2 and 60),
  discount_pct numeric(5, 2) not null check (discount_pct between 0 and 100),
  preventive_per_year smallint not null check (preventive_per_year between 0 and 12),
  waive_urgent boolean not null default false,
  max_pets smallint not null check (max_pets between 1 and 10),
  price_monthly integer not null check (price_monthly > 0),
  sort smallint not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.subscription_plans
  (slug, name, discount_pct, preventive_per_year, waive_urgent, max_pets, price_monthly, sort)
values
  ('basico', 'Básico', 10, 1, false, 1, 4990, 1),
  ('plus', 'Plus', 20, 2, true, 1, 9990, 2),
  ('familia', 'Familia', 20, 2, true, 4, 14990, 3);

alter table public.subscription_plans enable row level security;
alter table public.subscription_plans force row level security;

create policy subscription_plans_read on public.subscription_plans
for select to authenticated using (active or (select private.is_admin()));
create policy subscription_plans_admin_insert on public.subscription_plans
for insert to authenticated with check ((select private.is_admin()));
create policy subscription_plans_admin_update on public.subscription_plans
for update to authenticated
using ((select private.is_admin())) with check ((select private.is_admin()));

create trigger subscription_plans_audit after insert or update on public.subscription_plans
for each row execute function private.log_admin_change();

-- ===========================================================================
-- 2. Suscripciones y mascotas asociadas
-- ===========================================================================
-- Período: [current_period_start, current_period_end) en fechas de Chile.
-- El período n termina en started_on + n meses (anclado al alta: 31-ene →
-- 28-feb → 31-mar). `cancelled`: no se renueva y conserva los beneficios
-- hasta current_period_end; `ended`: sin beneficios.
create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.owner_profiles (user_id) on delete cascade,
  plan_id integer not null references public.subscription_plans (id),
  status text not null default 'active' check (status in ('active', 'cancelled', 'ended')),
  started_on date not null,
  periods_paid integer not null default 1 check (periods_paid >= 1),
  current_period_start date not null,
  current_period_end date not null,
  cancelled_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  constraint subscriptions_period check (current_period_end > current_period_start),
  constraint subscriptions_cancelled check (status <> 'cancelled' or cancelled_at is not null),
  constraint subscriptions_ended check ((status = 'ended') = (ended_at is not null))
);

-- HU5.1: una sola suscripción abierta (activa o cancelada con período vigente).
create unique index subscriptions_one_open on public.subscriptions (owner_id)
  where status <> 'ended';
create index subscriptions_owner_idx on public.subscriptions (owner_id, created_at desc);
create index subscriptions_plan_idx on public.subscriptions (plan_id);
create index subscriptions_renewal_idx on public.subscriptions (current_period_end)
  where status <> 'ended';

create table public.subscription_pets (
  subscription_id uuid not null references public.subscriptions (id) on delete cascade,
  pet_id uuid not null references public.pets (id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (subscription_id, pet_id)
);
create index subscription_pets_pet_idx on public.subscription_pets (pet_id);

alter table public.subscriptions enable row level security;
alter table public.subscriptions force row level security;
alter table public.subscription_pets enable row level security;
alter table public.subscription_pets force row level security;

-- Solo el dueño (ni el admin: minimización, como mascotas; el admin ve los
-- pagos `subscription`). Escritura solo por RPC.
create policy subscriptions_select_own on public.subscriptions
for select to authenticated using (owner_id = (select auth.uid()));
create policy subscription_pets_select_own on public.subscription_pets
for select to authenticated
using (exists (select 1 from public.subscriptions s
               where s.id = subscription_id and s.owner_id = (select auth.uid())));

-- ===========================================================================
-- 3. Columnas del plan en cotizaciones y pagos
-- ===========================================================================
-- plan_subsidy = lo que la plataforma pone por el plan (descuento + recargo
-- de urgencia omitido). platform_fee y vet_payout se calculan sobre el precio
-- de lista (service_price + plan_subsidy).
alter table public.quotes
  add column subscription_id uuid references public.subscriptions (id) on delete set null,
  add column plan_id integer references public.subscription_plans (id),
  add column plan_name text,
  add column plan_discount_pct numeric(5, 2) not null default 0
    check (plan_discount_pct between 0 and 100),
  add column plan_waive_urgent boolean not null default false,
  add column is_preventive boolean not null default false,
  add column plan_subsidy integer not null default 0 check (plan_subsidy >= 0),
  add constraint quotes_plan_benefits check (
    plan_id is not null
    or (plan_discount_pct = 0 and not plan_waive_urgent and not is_preventive
        and plan_subsidy = 0)),
  drop constraint quotes_split_sum,
  add constraint quotes_split_sum check (platform_fee + vet_payout = service_price + plan_subsidy);

create index quotes_subscription_idx on public.quotes (subscription_id);
create index quotes_plan_idx on public.quotes (plan_id);

grant select (subscription_id, plan_id, plan_name, plan_discount_pct, plan_waive_urgent,
  is_preventive, plan_subsidy) on public.quotes to authenticated;

alter table public.payments
  add column plan_subsidy integer not null default 0 check (plan_subsidy >= 0),
  add column subscription_id uuid references public.subscriptions (id) on delete set null,
  add column period_start date,
  add constraint payments_subscription_fields check (
    (kind = 'subscription') = (period_start is not null)
    and (kind = 'subscription' or subscription_id is null)
    and (kind <> 'subscription' or (plan_subsidy = 0 and vet_payout = 0
                                    and foundation_share = 0 and extra_donation = 0))),
  drop constraint payments_split_sum,
  add constraint payments_split_sum check (platform_fee + vet_payout = service_price + plan_subsidy);

create index payments_subscription_idx on public.payments (subscription_id);
-- Un período se cobra una sola vez.
create unique index payments_subscription_period_once
  on public.payments (subscription_id, period_start)
  where kind = 'subscription' and status = 'simulated_paid';

-- Cupo de preventivas: visitas preventivas del dueño.
create index visits_owner_preventive_idx on public.visits (owner_id, created_at)
  where is_preventive;

-- Inmutabilidad (igual que antes, más las columnas del plan).
create or replace function private.guard_quote_update()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if (new.owner_id, new.species_id, new.specialty_id, new.commune_id, new.mode,
      new.pricing_config_id, new.foundation_id, new.distance_m, new.base_price,
      new.urgent_surcharge, new.billable_km, new.distance_surcharge, new.discount,
      new.service_price, new.platform_fee, new.foundation_share, new.vet_payout,
      new.extra_donation, new.total, new.created_at, new.expires_at, new.plan_id,
      new.plan_name, new.plan_discount_pct, new.plan_waive_urgent, new.is_preventive,
      new.plan_subsidy)
     is distinct from
     (old.owner_id, old.species_id, old.specialty_id, old.commune_id, old.mode,
      old.pricing_config_id, old.foundation_id, old.distance_m, old.base_price,
      old.urgent_surcharge, old.billable_km, old.distance_surcharge, old.discount,
      old.service_price, old.platform_fee, old.foundation_share, old.vet_payout,
      old.extra_donation, old.total, old.created_at, old.expires_at, old.plan_id,
      old.plan_name, old.plan_discount_pct, old.plan_waive_urgent, old.is_preventive,
      old.plan_subsidy)
     or (new.subscription_id is distinct from old.subscription_id
         and new.subscription_id is not null) then
    raise exception 'Una cotización no se modifica' using errcode = '42501';
  end if;
  if old.consumed_at is not null and new.consumed_at is distinct from old.consumed_at then
    raise exception 'La cotización ya fue usada' using errcode = '42501';
  end if;
  return new;
end;
$$;

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
      new.foundation_share, new.vet_payout, new.extra_donation, new.total, new.created_at,
      new.plan_subsidy, new.period_start)
     is distinct from
     (old.foundation_id, old.kind, old.provider, old.service_price, old.platform_fee,
      old.foundation_share, old.vet_payout, old.extra_donation, old.total, old.created_at,
      old.plan_subsidy, old.period_start)
     or (new.quote_id is distinct from old.quote_id and new.quote_id is not null)
     or (new.owner_id is distinct from old.owner_id and new.owner_id is not null)
     or (new.visit_id is distinct from old.visit_id and new.visit_id is not null)
     or (new.vet_id is distinct from old.vet_id and new.vet_id is not null)
     or (new.subscription_id is distinct from old.subscription_id
         and new.subscription_id is not null) then
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

-- ===========================================================================
-- 4. Desglose con subsidio del plan
-- ===========================================================================
-- Precio de lista = base + recargo de urgencia + distancia (lo que pagaría un
-- dueño sin plan). Dueño: servicio = lista − descuento − urgencia omitida.
-- Comisión, fundación y vet salen del precio de lista; la plataforma absorbe
-- el subsidio (su neto de la visita = comisión − subsidio, puede ser < 0 y lo
-- cubren las cuotas). Sin plan, idéntico a la fase 5.
drop function private.price_breakdown(integer, boolean, integer, integer, numeric, numeric,
  numeric, integer, integer, numeric, boolean, boolean, boolean);

create function private.price_breakdown(
  p_base integer,
  p_urgent boolean,
  p_distance_m integer,
  p_extra_donation integer,
  p_commission_pct numeric,
  p_foundation_pct numeric,
  p_urgent_pct numeric,
  p_per_km integer,
  p_free_km integer,
  p_discount_pct numeric default 0,
  p_waive_urgent boolean default false,
  p_preventive_included boolean default false,
  p_commission_on_distance boolean default true
)
returns table (
  base_price integer,
  urgent_surcharge integer,
  billable_km integer,
  distance_surcharge integer,
  discount integer,
  service_price integer,
  platform_fee integer,
  foundation_share integer,
  vet_payout integer,
  extra_donation integer,
  total integer,
  plan_subsidy integer
)
language sql
immutable
security invoker
set search_path = ''
as $$
  with b as (
    select
      p_base as base,
      case when p_urgent then private.clp_round(p_base * p_urgent_pct / 100) else 0 end
        as urgent_list,
      case when p_distance_m is null then 0
           else greatest(0, ceil((p_distance_m - p_free_km * 1000) / 1000.0))::integer
      end as km,
      case when p_preventive_included then p_base
           else private.clp_round(p_base * p_discount_pct / 100) end as disc
  ), s as (
    select b.*,
           case when p_waive_urgent then 0 else b.urgent_list end as urgent,
           b.km * p_per_km as dist,
           b.base + b.urgent_list + b.km * p_per_km as list
    from b
  ), f as (
    select s.*,
           s.list - s.disc - (s.urgent_list - s.urgent) as service,
           private.clp_round(
             (s.list - case when p_commission_on_distance then 0 else s.dist end)
             * p_commission_pct / 100) as fee
    from s
  )
  select f.base, f.urgent, f.km, f.dist, f.disc, f.service, f.fee,
         private.clp_round(f.fee * p_foundation_pct / 100),
         f.list - f.fee,
         p_extra_donation,
         f.service + p_extra_donation,
         f.list - f.service
  from f;
$$;
revoke execute on function private.price_breakdown(integer, boolean, integer, integer,
  numeric, numeric, numeric, integer, integer, numeric, boolean, boolean, boolean)
  from public, anon, authenticated;

-- ===========================================================================
-- 5. Beneficios vigentes y cupo de preventivas
-- ===========================================================================
create function private.chile_today()
returns date
language sql
stable
security invoker
set search_path = ''
as $$
  select (now() at time zone 'America/Santiago')::date;
$$;
revoke execute on function private.chile_today() from public, anon, authenticated;

-- ¿Da beneficios hoy? Activa (la renovación es simulada y siempre se cobra) o
-- cancelada dentro del período pagado.
create function private.subscription_in_benefit(s public.subscriptions)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select s.status = 'active'
      or (s.status = 'cancelled' and private.chile_today() < s.current_period_end);
$$;
revoke execute on function private.subscription_in_benefit(public.subscriptions)
  from public, anon, authenticated;

-- Preventivas usadas en los últimos 12 meses (fecha de Chile), por dueño y
-- sumando todas sus suscripciones (cancelar y volver a suscribirse no
-- reinicia el cupo). Cuentan las visitas abiertas o completadas; las
-- canceladas, rechazadas o expiradas devuelven el cupo.
create function private.preventive_used(p_owner uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer from public.visits v
  where v.owner_id = p_owner and v.is_preventive
    and v.status in ('pending_vet', 'accepted', 'en_route', 'arrived', 'in_progress',
                     'completed')
    and v.created_at >= ((private.chile_today() - interval '1 year')::date::timestamp
                         at time zone 'America/Santiago');
$$;
revoke execute on function private.preventive_used(uuid) from public, anon, authenticated;

-- Beneficios que corresponden a esta mascota y atención (0 filas = sin plan).
-- Preventiva incluida: agendada, especialidad `prevencion` y cupo disponible.
create function private.plan_benefits(
  p_owner uuid, p_pet uuid, p_mode text, p_specialty integer)
returns table (
  subscription_id uuid, plan_id integer, plan_name text, discount_pct numeric,
  waive_urgent boolean, is_preventive boolean, preventive_quota integer)
language sql
stable
security definer
set search_path = ''
as $$
  select s.id, pl.id, pl.name, pl.discount_pct, pl.waive_urgent,
         p_mode = 'scheduled'
         and exists (select 1 from public.specialties x
                     where x.id = p_specialty and x.slug = 'prevencion')
         and private.preventive_used(p_owner) < pl.preventive_per_year,
         pl.preventive_per_year::integer
  from public.subscriptions s
  join public.subscription_plans pl on pl.id = s.plan_id
  join public.subscription_pets sp on sp.subscription_id = s.id and sp.pet_id = p_pet
  where s.owner_id = p_owner and s.status <> 'ended'
    and private.subscription_in_benefit(s);
$$;
revoke execute on function private.plan_benefits(uuid, uuid, text, integer)
  from public, anon, authenticated;

-- ===========================================================================
-- 6. Cotización con el plan aplicado (congelado en la fila de quotes)
-- ===========================================================================
create or replace function private.quote_snapshot(q public.quotes)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'quote_id', q.id,
    'mode', q.mode,
    'species_id', q.species_id,
    'specialty_id', q.specialty_id,
    'commune_id', q.commune_id,
    'vet_id', q.vet_id,
    'pricing_config_id', q.pricing_config_id,
    'foundation_id', q.foundation_id,
    'foundation_name', (select f.name from public.foundations f where f.id = q.foundation_id),
    'distance_km', case when q.distance_m is null then null
                        else round(q.distance_m / 1000.0)::integer end,
    'base_price', q.base_price,
    'urgent_surcharge', q.urgent_surcharge,
    'billable_km', q.billable_km,
    'distance_surcharge', q.distance_surcharge,
    'discount', q.discount,
    'service_price', q.service_price,
    'platform_fee', q.platform_fee,
    'foundation_share', q.foundation_share,
    'vet_payout', q.vet_payout,
    'extra_donation', q.extra_donation,
    'total', q.total,
    -- Fase 10: plan aplicado (null sin plan) y subsidio de la plataforma.
    'plan', case when q.plan_id is null then null
                 else jsonb_build_object('plan_id', q.plan_id, 'name', q.plan_name,
                        'discount_pct', q.plan_discount_pct,
                        'waive_urgent', q.plan_waive_urgent) end,
    'is_preventive', q.is_preventive,
    'plan_subsidy', q.plan_subsidy,
    'currency', 'CLP',
    'created_at', q.created_at,
    'expires_at', q.expires_at
  );
$$;

-- Igual que en 20261117220000_qa_f5_fixes.sql, más los beneficios del plan.
create or replace function private.quote_for(
  p_owner uuid,
  p_pet_id uuid,
  p_address_id uuid,
  p_specialty_id integer,
  p_mode text,
  p_vet_id uuid,
  p_origin extensions.geography,
  p_foundation_id uuid,
  p_extra_donation integer
)
returns public.quotes
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_species integer;
  v_location extensions.geography;
  v_commune integer;
  v_base integer;
  v_cfg public.pricing_config;
  v_foundation uuid;
  v_distance integer;
  v_plan record;
  v_q public.quotes;
begin
  if p_mode is null or p_mode not in ('urgent', 'scheduled') then
    raise exception 'Tipo de visita no válido' using errcode = '22023';
  end if;
  if coalesce(p_extra_donation, 0) not between 0 and 1000000 then
    raise exception 'La donación debe estar entre $0 y $1.000.000' using errcode = '22023';
  end if;

  select p.species_id into v_species from public.pets p
  where p.id = p_pet_id and p.owner_id = p_owner and p.active;
  if not found then
    raise exception 'La mascota no existe o no está activa' using errcode = '22023';
  end if;

  select a.location, a.commune_id into v_location, v_commune from public.addresses a
  where a.id = p_address_id and a.owner_id = p_owner and a.active;
  if not found then
    raise exception 'La dirección no existe o no está activa' using errcode = '22023';
  end if;

  if not exists (select 1 from public.specialties s
                 join public.species sp on sp.id = v_species and sp.active
                 join public.species_specialties ss
                   on ss.species_id = v_species and ss.specialty_id = s.id
                 where s.id = p_specialty_id and s.active) then
    raise exception 'La especialidad no atiende a esta especie' using errcode = '22023';
  end if;

  v_base := public.base_tariff(v_species, p_specialty_id);
  if v_base is null then
    raise exception 'No hay tarifa vigente para esta especialidad' using errcode = '22023';
  end if;

  select * into v_cfg from public.current_pricing_config();
  if v_cfg.id is null then
    raise exception 'No hay parámetros de precio vigentes' using errcode = '22023';
  end if;

  if p_vet_id is not null and not exists (
       select 1 from public.vet_profiles v
       join public.vet_species vs on vs.vet_id = v.user_id and vs.species_id = v_species
       join public.vet_specialties vsp on vsp.vet_id = v.user_id
                                      and vsp.specialty_id = p_specialty_id
       where v.user_id = p_vet_id and v.status = 'approved') then
    raise exception 'El veterinario no está disponible para esta atención'
      using errcode = '22023';
  end if;

  -- Fundación: la indicada, si no la del perfil, si no la por defecto.
  if p_foundation_id is not null then
    select f.id into v_foundation from public.foundations f
    where f.id = p_foundation_id and f.active;
    if v_foundation is null then
      raise exception 'La fundación no existe o no está activa' using errcode = '22023';
    end if;
  else
    select coalesce(
      (select f.id from public.owner_profiles o
       join public.foundations f on f.id = o.foundation_id and f.active
       where o.user_id = p_owner),
      (select f.id from public.foundations f where f.is_default and f.active))
    into v_foundation;
    if v_foundation is null then
      raise exception 'No hay una fundación por defecto configurada' using errcode = '22023';
    end if;
  end if;

  if p_origin is not null then
    v_distance := round(extensions.st_distance(v_location, p_origin))::integer;
  end if;
  -- QA-F5-02: distancia máxima de atención (configurable y versionada).
  if v_distance is not null and v_distance > v_cfg.max_distance_km * 1000 then
    raise exception 'El veterinario está fuera del radio de atención (máximo % km)',
      v_cfg.max_distance_km using errcode = '22023';
  end if;

  -- Tope anti abuso: 60 cotizaciones por dueño y hora (serializado).
  perform pg_advisory_xact_lock(hashtextextended('quotes:' || p_owner::text, 0));
  if (select count(*) from public.quotes q
      where q.owner_id = p_owner and q.created_at > now() - interval '1 hour') >= 60 then
    raise exception 'Demasiadas cotizaciones. Intenta en unos minutos.'
      using errcode = '22023';
  end if;

  -- Fase 10 (HU5.2): beneficios del plan de la mascota, si tiene.
  select * into v_plan
  from private.plan_benefits(p_owner, p_pet_id, p_mode, p_specialty_id) pb limit 1;

  insert into public.quotes (
    owner_id, pet_id, address_id, vet_id, species_id, specialty_id, commune_id,
    mode, pricing_config_id, foundation_id, distance_m,
    base_price, urgent_surcharge, billable_km, distance_surcharge, discount,
    service_price, platform_fee, foundation_share, vet_payout, extra_donation,
    total, expires_at, subscription_id, plan_id, plan_name, plan_discount_pct,
    plan_waive_urgent, is_preventive, plan_subsidy)
  select p_owner, p_pet_id, p_address_id, p_vet_id, v_species, p_specialty_id,
    v_commune, p_mode, v_cfg.id, v_foundation, v_distance,
    b.base_price, b.urgent_surcharge, b.billable_km, b.distance_surcharge, b.discount,
    b.service_price, b.platform_fee, b.foundation_share, b.vet_payout,
    b.extra_donation, b.total, now() + interval '30 minutes',
    v_plan.subscription_id, v_plan.plan_id, v_plan.plan_name,
    coalesce(v_plan.discount_pct, 0), coalesce(v_plan.waive_urgent, false),
    coalesce(v_plan.is_preventive, false), b.plan_subsidy
  from private.price_breakdown(
    v_base, p_mode = 'urgent', v_distance, coalesce(p_extra_donation, 0),
    v_cfg.commission_pct, v_cfg.foundation_pct, v_cfg.urgent_pct,
    v_cfg.per_km, v_cfg.free_km, coalesce(v_plan.discount_pct, 0),
    coalesce(v_plan.waive_urgent, false), coalesce(v_plan.is_preventive, false),
    v_cfg.commission_on_distance) b
  returning * into v_q;

  return v_q;
end;
$$;

-- Urgencias: el precio final usa el plan congelado en la cotización de la
-- solicitud (misma versión de pricing_config). Agrega plan_subsidy.
drop function private.urgent_price(public.quotes, integer);
create function private.urgent_price(p_req public.quotes, p_distance_m integer)
returns table (
  pricing_config_id integer, base_price integer, urgent_surcharge integer,
  billable_km integer, distance_surcharge integer, discount integer,
  service_price integer, platform_fee integer, foundation_share integer,
  vet_payout integer, extra_donation integer, total integer, plan_subsidy integer)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id, b.base_price, b.urgent_surcharge, b.billable_km, b.distance_surcharge,
         b.discount, b.service_price, b.platform_fee, b.foundation_share, b.vet_payout,
         b.extra_donation, b.total, b.plan_subsidy
  from public.pricing_config c
  cross join lateral private.price_breakdown(
    p_req.base_price, true, p_distance_m, p_req.extra_donation,
    c.commission_pct, c.foundation_pct, c.urgent_pct, c.per_km, c.free_km,
    p_req.plan_discount_pct, p_req.plan_waive_urgent, false, c.commission_on_distance) b
  where c.id = p_req.pricing_config_id;
$$;
revoke execute on function private.urgent_price(public.quotes, integer) from public, anon, authenticated;

create or replace function private.urgent_final_quote(p_req public.quotes, p_vet uuid, p_distance_m integer)
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
    total, expires_at, consumed_at, subscription_id, plan_id, plan_name,
    plan_discount_pct, plan_waive_urgent, is_preventive, plan_subsidy)
  select p_req.owner_id, p_req.pet_id, p_req.address_id, p_vet, p_req.species_id,
    p_req.specialty_id, p_req.commune_id, 'urgent', b.pricing_config_id, p_req.foundation_id,
    p_distance_m, b.base_price, b.urgent_surcharge, b.billable_km, b.distance_surcharge,
    b.discount, b.service_price, b.platform_fee, b.foundation_share, b.vet_payout,
    b.extra_donation, b.total, now(), now(), p_req.subscription_id, p_req.plan_id,
    p_req.plan_name, p_req.plan_discount_pct, p_req.plan_waive_urgent, false, b.plan_subsidy
  from private.urgent_price(p_req, p_distance_m) b
  returning *;
$$;
revoke execute on function private.urgent_final_quote(public.quotes, uuid, integer)
  from public, anon, authenticated;

-- ===========================================================================
-- 7. Al crear la visita: marca la preventiva y revalida el plan
-- ===========================================================================
-- La cotización pudo hacerse con el plan vigente y cupo libre; al reservar
-- (o pedir la urgencia) se vuelve a comprobar, serializado por dueño, para
-- que dos reservas simultáneas no usen la misma preventiva.
create function private.apply_visit_plan()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  q public.quotes;
begin
  select * into q from public.quotes x where x.id = new.quote_id;
  new.is_preventive := coalesce(q.is_preventive, false);
  if q.plan_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('preventive:' || q.owner_id::text, 0));
    if not exists (
         select 1 from private.plan_benefits(q.owner_id, q.pet_id, q.mode, q.specialty_id) b
         where b.subscription_id is not distinct from q.subscription_id
           and (not q.is_preventive or b.is_preventive)) then
      raise exception 'Tu plan cambió desde la cotización (venció o se agotó el cupo de preventivas). Vuelve a cotizar.'
        using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function private.apply_visit_plan() from public, anon, authenticated;

-- Se ejecuta después de visits_guard (orden alfabético).
create trigger visits_plan before insert on public.visits
for each row execute function private.apply_visit_plan();

-- ===========================================================================
-- 8. Pagos de visitas con subsidio
-- ===========================================================================
drop function private.record_payment(uuid, uuid, uuid, uuid, uuid, text,
  integer, integer, integer, integer, integer, boolean);
create function private.record_payment(
  p_owner uuid, p_vet uuid, p_visit uuid, p_quote uuid, p_foundation uuid, p_kind text,
  p_service integer, p_fee integer, p_share integer, p_payout integer, p_donation integer,
  p_fail boolean, p_subsidy integer default 0)
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
    service_price, platform_fee, foundation_share, vet_payout, extra_donation, total,
    plan_subsidy)
  values (p_owner, p_vet, p_visit, p_quote, p_foundation, p_kind,
    p_service, p_fee, p_share, p_payout, p_donation, p_service + p_donation,
    coalesce(p_subsidy, 0))
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
  integer, integer, integer, integer, integer, boolean, integer) from public, anon, authenticated;

create or replace function private.pay_visit_simulated(p_visit_id uuid, p_simulate_failure boolean)
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
    (v.quote ->> 'extra_donation')::integer, p_simulate_failure,
    coalesce((v.quote ->> 'plan_subsidy')::integer, 0));

  return jsonb_build_object(
    'payment_id', v_p.id, 'visit_id', v.id, 'status', v_p.status,
    'total', v_p.total, 'service_price', v_p.service_price,
    'platform_fee', v_p.platform_fee, 'foundation_share', v_p.foundation_share,
    'vet_payout', v_p.vet_payout, 'extra_donation', v_p.extra_donation,
    'plan_subsidy', v_p.plan_subsidy, 'paid_at', v_p.paid_at);
end;
$$;

-- Liquidaciones del vet: precio de lista (servicio + subsidio), sin revelar
-- si el dueño tiene plan.
create or replace function private.my_payouts(p_limit integer)
returns table (
  visit_id uuid, kind text, status text, service_price integer,
  platform_fee integer, vet_payout integer, created_at timestamptz, paid_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select pa.visit_id, pa.kind, pa.status, pa.service_price + pa.plan_subsidy,
         pa.platform_fee, pa.vet_payout, pa.created_at, pa.paid_at
  from public.payments pa
  where pa.vet_id = (select auth.uid())
    and (select private.current_app_role()) = 'vet'
  order by pa.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
$$;

-- ===========================================================================
-- 9. RPC de suscripción
-- ===========================================================================
-- Cobro simulado de un período: todo es ingreso de la plataforma (sin vet ni
-- aporte a la fundación; foundation_id es la del dueño o la por defecto solo
-- porque payments lo exige).
create function private.charge_subscription(s public.subscriptions, p_period_start date)
returns public.payments
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_price integer;
  v_foundation uuid;
  v_p public.payments;
begin
  select pl.price_monthly into v_price from public.subscription_plans pl where pl.id = s.plan_id;
  select coalesce(
    (select f.id from public.owner_profiles o
     join public.foundations f on f.id = o.foundation_id and f.active
     where o.user_id = s.owner_id),
    (select f.id from public.foundations f where f.is_default and f.active))
  into v_foundation;
  if v_foundation is null then
    raise exception 'No hay una fundación por defecto configurada' using errcode = '22023';
  end if;
  insert into public.payments (owner_id, subscription_id, period_start, foundation_id, kind,
    service_price, platform_fee, foundation_share, vet_payout, extra_donation, total)
  values (s.owner_id, s.id, p_period_start, v_foundation, 'subscription',
    v_price, v_price, 0, 0, 0, v_price)
  returning * into v_p;
  update public.payments set status = 'simulated_paid', paid_at = now()
  where id = v_p.id returning * into v_p;
  return v_p;
end;
$$;
revoke execute on function private.charge_subscription(public.subscriptions, date)
  from public, anon, authenticated;

-- Mascotas válidas para el plan: al menos una, sin repetir, hasta max_pets,
-- propias y activas.
create function private.check_subscription_pets(
  p_owner uuid, p_plan public.subscription_plans, p_pet_ids uuid[])
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_n integer := coalesce(cardinality(p_pet_ids), 0);
begin
  if v_n = 0 or array_position(p_pet_ids, null) is not null then
    raise exception 'Elige al menos una mascota' using errcode = '22023';
  end if;
  if (select count(distinct x) from unnest(p_pet_ids) x) <> v_n then
    raise exception 'Hay mascotas repetidas' using errcode = '22023';
  end if;
  if v_n > p_plan.max_pets then
    raise exception 'El plan % admite hasta % mascota(s)', p_plan.name, p_plan.max_pets
      using errcode = '22023';
  end if;
  if (select count(*) from public.pets p
      where p.id = any (p_pet_ids) and p.owner_id = p_owner and p.active) <> v_n then
    raise exception 'La mascota no existe o no está activa' using errcode = '22023';
  end if;
end;
$$;
revoke execute on function private.check_subscription_pets(uuid, public.subscription_plans, uuid[])
  from public, anon, authenticated;

create function private.subscription_view(s public.subscriptions)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', s.id, 'status', s.status,
    'plan', jsonb_build_object('id', pl.id, 'slug', pl.slug, 'name', pl.name,
              'discount_pct', pl.discount_pct, 'preventive_per_year', pl.preventive_per_year,
              'waive_urgent', pl.waive_urgent, 'max_pets', pl.max_pets,
              'price_monthly', pl.price_monthly),
    'started_on', s.started_on, 'periods_paid', s.periods_paid,
    'current_period_start', s.current_period_start,
    -- Exclusivo: los beneficios valen mientras la fecha de Chile sea menor.
    'current_period_end', s.current_period_end,
    'renews', s.status = 'active',
    'cancelled_at', s.cancelled_at,
    'benefits_active', private.subscription_in_benefit(s),
    'preventive_used', private.preventive_used(s.owner_id),
    'preventive_remaining', greatest(pl.preventive_per_year - private.preventive_used(s.owner_id), 0),
    'pets', coalesce((select jsonb_agg(jsonb_build_object('pet_id', p.id, 'name', p.name,
                        'active', p.active) order by sp.added_at, p.name)
                      from public.subscription_pets sp join public.pets p on p.id = sp.pet_id
                      where sp.subscription_id = s.id), '[]'))
  from public.subscription_plans pl
  where pl.id = s.plan_id;
$$;
revoke execute on function private.subscription_view(public.subscriptions)
  from public, anon, authenticated;

create function private.subscribe(p_plan_id integer, p_pet_ids uuid[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_today date := private.chile_today();
  pl public.subscription_plans;
  s public.subscriptions;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño puede suscribirse' using errcode = '42501';
  end if;
  select * into pl from public.subscription_plans x where x.id = p_plan_id and x.active;
  if not found then
    raise exception 'El plan no existe o no está disponible' using errcode = '22023';
  end if;
  perform private.check_subscription_pets(v_uid, pl, p_pet_ids);

  perform pg_advisory_xact_lock(hashtextextended('subscriptions:' || v_uid::text, 0));
  select * into s from public.subscriptions x
  where x.owner_id = v_uid and x.status <> 'ended' for update;
  if found then
    if s.status = 'active' then
      raise exception 'Ya tienes una suscripción activa. Cancélala antes de cambiar de plan.'
        using errcode = '22023';
    end if;
    -- Cancelada con período vigente: la nueva la reemplaza desde hoy.
    update public.subscriptions set status = 'ended', ended_at = now() where id = s.id;
  end if;

  insert into public.subscriptions (owner_id, plan_id, started_on, current_period_start,
    current_period_end)
  values (v_uid, pl.id, v_today, v_today, (v_today + interval '1 month')::date)
  returning * into s;
  insert into public.subscription_pets (subscription_id, pet_id)
  select s.id, x from unnest(p_pet_ids) x;
  perform private.charge_subscription(s, v_today);
  return private.subscription_view(s);
end;
$$;

create function private.set_subscription_pets(p_pet_ids uuid[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  pl public.subscription_plans;
  s public.subscriptions;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño tiene suscripciones' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('subscriptions:' || v_uid::text, 0));
  select * into s from public.subscriptions x
  where x.owner_id = v_uid and x.status <> 'ended' for update;
  if not found then
    raise exception 'No tienes una suscripción vigente' using errcode = '22023';
  end if;
  select * into pl from public.subscription_plans x where x.id = s.plan_id;
  perform private.check_subscription_pets(v_uid, pl, p_pet_ids);
  delete from public.subscription_pets sp
  where sp.subscription_id = s.id and sp.pet_id <> all (p_pet_ids);
  insert into public.subscription_pets (subscription_id, pet_id)
  select s.id, x from unnest(p_pet_ids) x
  on conflict do nothing;
  return private.subscription_view(s);
end;
$$;

-- HU5.3: no se renueva; los beneficios siguen hasta current_period_end.
create function private.cancel_subscription()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  s public.subscriptions;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño tiene suscripciones' using errcode = '42501';
  end if;
  update public.subscriptions x set status = 'cancelled', cancelled_at = now()
  where x.owner_id = v_uid and x.status = 'active'
  returning * into s;
  if not found then
    raise exception 'No tienes una suscripción activa' using errcode = '22023';
  end if;
  return private.subscription_view(s);
end;
$$;

-- Suscripción abierta del dueño (activa o cancelada en su período), o null.
create function private.my_subscription()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.subscription_view(s)
  from public.subscriptions s
  where s.owner_id = (select auth.uid()) and s.status <> 'ended'
    and (select private.current_app_role()) = 'owner';
$$;

-- Renovación simulada (pg_cron, cada hora). Al vencer el período (fecha de
-- Chile ≥ current_period_end): las canceladas, las de cuentas bloqueadas y
-- las de planes desactivados terminan sin cobro; las activas avanzan un
-- período por cada uno vencido, con un pago `subscription` cada uno.
create function private.renew_subscriptions()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_today date := private.chile_today();
  s public.subscriptions;
  v_n integer := 0;
begin
  for s in
    select * from public.subscriptions x
    where x.status <> 'ended' and x.current_period_end <= v_today
    for update skip locked
  loop
    if s.status = 'cancelled' or private.is_blocked(s.owner_id)
       or not exists (select 1 from public.subscription_plans p
                      where p.id = s.plan_id and p.active) then
      update public.subscriptions set status = 'ended', ended_at = now() where id = s.id;
    else
      while s.current_period_end <= v_today loop
        update public.subscriptions x
        set periods_paid = x.periods_paid + 1,
            current_period_start = x.current_period_end,
            current_period_end = (x.started_on + make_interval(months => x.periods_paid + 1))::date
        where x.id = s.id
        returning * into s;
        perform private.charge_subscription(s, s.current_period_start);
      end loop;
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function private.renew_subscriptions() from public, anon, authenticated;

select cron.schedule('renew-subscriptions', '7 * * * *', 'select private.renew_subscriptions()');

-- Envoltorios públicos (SECURITY INVOKER).
create function public.subscribe(p_plan_id integer, p_pet_ids uuid[])
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.subscribe(p_plan_id, p_pet_ids); $$;
create function public.set_subscription_pets(p_pet_ids uuid[])
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.set_subscription_pets(p_pet_ids); $$;
create function public.cancel_subscription()
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.cancel_subscription(); $$;
create function public.my_subscription()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.my_subscription(); $$;

-- ===========================================================================
-- 10. Vistas del vet sin el plan del dueño
-- ===========================================================================
-- Igual que en 20261124230000_qa_f8_fixes.sql, con service_price de lista.
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
    'service_price', pr.service_price + pr.plan_subsidy, 'vet_payout', pr.vet_payout)
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
      'service_price', (v.quote ->> 'service_price')::integer
                       + coalesce((v.quote ->> 'plan_subsidy')::integer, 0),
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

-- ===========================================================================
-- 11. Privacidad: exportación y borrado (arquitectura §8.2)
-- ===========================================================================
-- Igual que en 20261125180000_ratings_cancellations.sql, más las suscripciones
-- del dueño y, para el vet, el precio de lista.
create or replace function private.export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
  v_common jsonb;
  v_data jsonb;
  v_pets uuid[];
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;
  select r.role into v_role from public.user_roles r where r.user_id = v_uid;

  v_common := jsonb_build_object(
    'account', (select jsonb_build_object('id', u.id, 'email', u.email, 'role', v_role,
                  'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at)
                from auth.users u where u.id = v_uid),
    'consents', coalesce((select jsonb_agg(jsonb_build_object('purpose', c.purpose,
                  'version', c.version, 'granted_at', c.granted_at, 'revoked_at', c.revoked_at)
                  order by c.granted_at) from public.consents c where c.user_id = v_uid), '[]'),
    'terms_acceptances', coalesce((select jsonb_agg(jsonb_build_object('version', t.version,
                  'accepted_at', t.accepted_at) order by t.accepted_at)
                  from public.terms_acceptances t where t.user_id = v_uid), '[]'),
    'privacy_notice_views', coalesce((select jsonb_agg(jsonb_build_object('version', p.version,
                  'shown_at', p.shown_at) order by p.shown_at)
                  from public.privacy_notice_views p where p.user_id = v_uid), '[]'),
    'previous_exports', coalesce((select jsonb_agg(jsonb_build_object('exported_at', e.exported_at,
                  'sections', e.sections) order by e.exported_at)
                  from public.data_exports e where e.user_id = v_uid), '[]'),
    'deletion_requests', coalesce((select jsonb_agg(jsonb_build_object('status', d.status,
                  'requested_at', d.requested_at, 'execute_after', d.execute_after,
                  'cancelled_at', d.cancelled_at) order by d.requested_at)
                  from public.deletion_requests d where d.user_id = v_uid), '[]'),
    'push_devices', coalesce((select jsonb_agg(jsonb_build_object('platform', d.platform,
                  'created_at', d.created_at, 'last_seen_at', d.last_seen_at)
                  order by d.created_at) from private.push_devices d where d.user_id = v_uid), '[]'),
    -- Fase 9: calificaciones hechas (todas) y recibidas (solo las publicadas;
    -- un comentario oculto por el admin sale como null).
    'ratings_given', coalesce((select jsonb_agg(jsonb_build_object('visit_id', r.visit_id,
                  'role', r.rater_role, 'stars', r.stars, 'comment', r.comment,
                  'hidden', r.hidden, 'created_at', r.created_at,
                  'publishes_at', private.rating_public_at(r.published_at, vi.completed_at))
                  order by r.created_at)
                  from public.ratings r join public.visits vi on vi.id = r.visit_id
                  where r.rater_id = v_uid), '[]'),
    'ratings_received', coalesce((select jsonb_agg(jsonb_build_object('visit_id', r.visit_id,
                  'from_role', r.rater_role, 'stars', r.stars,
                  'comment', case when r.hidden then null else r.comment end,
                  'comment_hidden', r.hidden,
                  'published_at', private.rating_public_at(r.published_at, vi.completed_at))
                  order by r.created_at)
                  from public.ratings r join public.visits vi on vi.id = r.visit_id
                  where r.ratee_id = v_uid
                    and not private.is_blocked(r.rater_id)
                    and private.rating_public_at(r.published_at, vi.completed_at) <= now()), '[]'));

  if v_role = 'owner' then
    select coalesce(array_agg(p.id), '{}') into v_pets from public.pets p where p.owner_id = v_uid;
    v_data := jsonb_build_object(
      'profile', (select jsonb_build_object('display_name', o.display_name, 'phone', o.phone,
                    'commune', c.name, 'foundation', f.name, 'created_at', o.created_at,
                    'updated_at', o.updated_at)
                  from public.owner_profiles o
                  left join public.communes c on c.id = o.commune_id
                  left join public.foundations f on f.id = o.foundation_id
                  where o.user_id = v_uid),
      'addresses', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'label', a.label,
                    'street_text', a.street_text, 'details', a.details, 'commune', c.name,
                    'lat', a.lat, 'lng', a.lng, 'active', a.active, 'created_at', a.created_at)
                    order by a.created_at)
                    from public.addresses a join public.communes c on c.id = a.commune_id
                    where a.owner_id = v_uid), '[]'),
      'pets', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name,
                    'species', s.name, 'breed', b.name, 'sex', p.sex,
                    'birth_date_approx', p.birth_date_approx, 'sterilized', p.sterilized,
                    'microchip', p.microchip, 'active', p.active, 'created_at', p.created_at)
                    order by p.created_at)
                    from public.pets p join public.species s on s.id = p.species_id
                    left join public.breeds b on b.id = p.breed_id
                    where p.owner_id = v_uid), '[]'),
      -- Ficha completa de sus mascotas, incluidas las entradas de vets (autor
      -- con su nombre público, como en get_pet_record).
      'clinical_entries', coalesce((select jsonb_agg(jsonb_build_object('id', e.id,
                    'pet_id', e.pet_id, 'created_at', e.created_at, 'kind', e.kind,
                    'title', e.title, 'body', e.body, 'author_role', e.author_role,
                    'author_name', case when e.author_role = 'vet'
                                        then coalesce(vp.display_name, 'MV verificado')
                                        else 'Tú' end,
                    'specialty', sp.name, 'species', s.name, 'visit_id', e.visit_id,
                    'supersedes_id', e.supersedes_id,
                    'vaccine', (select jsonb_build_object('vaccine_name', cv.vaccine_name,
                                  'lot', cv.lot, 'applied_on', cv.applied_on, 'next_due', cv.next_due)
                                from public.clinical_vaccines cv where cv.entry_id = e.id),
                    'attachments', coalesce((select jsonb_agg(jsonb_build_object('id', ea.id,
                                  'file_name', ea.file_name, 'mime', ea.mime,
                                  'size_bytes', ea.size_bytes, 'created_at', ea.created_at)
                                  order by ea.created_at)
                                from public.entry_attachments ea where ea.entry_id = e.id), '[]'))
                    order by e.created_at)
                    from public.clinical_entries e
                    join public.species s on s.id = e.species_id
                    left join public.specialties sp on sp.id = e.specialty_id
                    left join public.vet_profiles vp on vp.user_id = e.author_id
                                                    and e.author_role = 'vet'
                    where e.pet_id = any (v_pets)), '[]'),
      'record_access_log', coalesce((select jsonb_agg(jsonb_build_object('pet_id', l.pet_id,
                    'at', l.at, 'action', l.action, 'via', l.via, 'actor_role', l.actor_role,
                    'actor_name', case when l.actor_id = v_uid then 'Tú'
                                       when l.actor_role = 'vet'
                                       then coalesce(v.display_name, 'MV verificado')
                                       else l.actor_role end)
                    order by l.at)
                    from public.record_access_log l
                    left join public.vet_profiles v on v.user_id = l.actor_id
                    where l.pet_id = any (v_pets)), '[]'),
      'record_access_grants', coalesce((select jsonb_agg(jsonb_build_object('pet_id', g.pet_id,
                    'vet_name', v.display_name, 'source', g.source, 'starts_at', g.starts_at,
                    'expires_at', g.expires_at, 'revoked_at', g.revoked_at)
                    order by g.created_at)
                    from public.record_access_grants g
                    left join public.vet_profiles v on v.user_id = g.vet_id
                    where g.pet_id = any (v_pets) and g.source = 'owner'), '[]'),
      'visits', coalesce((select jsonb_agg(jsonb_build_object('id', vi.id, 'mode', vi.mode,
                    'status', vi.status, 'scheduled_at', vi.scheduled_at,
                    'created_at', vi.created_at, 'completed_at', vi.completed_at,
                    'commune', c.name, 'species', s.name, 'specialty', sp.name,
                    'pet_id', vi.pet_id, 'address_id', vi.address_id,
                    'vet_name', vp.display_name, 'notes', vi.owner_notes,
                    'cancel_reason', vi.cancel_reason, 'cancel_fee', vi.cancel_fee,
                    'quote', vi.quote - 'vet_id')
                    order by vi.created_at)
                    from public.visits vi
                    join public.communes c on c.id = vi.commune_id
                    join public.species s on s.id = vi.species_id
                    join public.specialties sp on sp.id = vi.specialty_id
                    left join public.vet_profiles vp on vp.user_id = vi.vet_id
                    where vi.owner_id = v_uid), '[]'),
      'payments', coalesce((select jsonb_agg(jsonb_build_object('id', pa.id,
                    'visit_id', pa.visit_id, 'kind', pa.kind, 'status', pa.status,
                    'provider', pa.provider, 'service_price', pa.service_price,
                    'plan_subsidy', pa.plan_subsidy, 'subscription_id', pa.subscription_id,
                    'period_start', pa.period_start,
                    'platform_fee', pa.platform_fee, 'foundation_share', pa.foundation_share,
                    'extra_donation', pa.extra_donation, 'total', pa.total,
                    'foundation', f.name, 'created_at', pa.created_at, 'paid_at', pa.paid_at)
                    order by pa.created_at)
                    from public.payments pa join public.foundations f on f.id = pa.foundation_id
                    where pa.owner_id = v_uid), '[]'),
      -- Fase 10: suscripciones (plan, períodos y mascotas asociadas).
      'subscriptions', coalesce((select jsonb_agg(jsonb_build_object('id', su.id,
                    'plan', pl.name, 'status', su.status, 'started_on', su.started_on,
                    'periods_paid', su.periods_paid,
                    'current_period_start', su.current_period_start,
                    'current_period_end', su.current_period_end,
                    'cancelled_at', su.cancelled_at, 'ended_at', su.ended_at,
                    'created_at', su.created_at,
                    'pet_ids', coalesce((select jsonb_agg(sp.pet_id order by sp.added_at)
                                         from public.subscription_pets sp
                                         where sp.subscription_id = su.id), '[]'))
                    order by su.created_at)
                    from public.subscriptions su
                    join public.subscription_plans pl on pl.id = su.plan_id
                    where su.owner_id = v_uid), '[]'));
  elsif v_role = 'vet' then
    v_data := jsonb_build_object(
      'profile', (select jsonb_build_object('display_name', v.display_name, 'status', v.status,
                    'bio', v.bio, 'university', v.university,
                    'graduation_year', v.graduation_year, 'foreign_degree', v.foreign_degree,
                    'title_verification_code', v.title_verification_code,
                    'declaration_accepted_at', v.declaration_accepted_at,
                    'submitted_at', v.submitted_at, 'reviewed_at', v.reviewed_at,
                    'identity_verified_at', v.identity_verified_at,
                    'review_notes', v.review_notes, 'rejection_reason', v.rejection_reason,
                    'created_at', v.created_at)
                  from public.vet_profiles v where v.user_id = v_uid),
      -- La base exacta es del propio vet; el origen aproximado no se exporta.
      'base', (select jsonb_build_object('commune', c.name, 'lat', b.lat, 'lng', b.lng,
                 'updated_at', b.updated_at)
               from public.vet_bases b join public.communes c on c.id = b.commune_id
               where b.vet_id = v_uid),
      'species', coalesce((select jsonb_agg(s.name order by s.sort) from public.vet_species x
                 join public.species s on s.id = x.species_id where x.vet_id = v_uid), '[]'),
      'specialties', coalesce((select jsonb_agg(s.name order by s.sort)
                 from public.vet_specialties x
                 join public.specialties s on s.id = x.specialty_id where x.vet_id = v_uid), '[]'),
      'availability', coalesce((select jsonb_agg(jsonb_build_object('weekday', a.weekday,
                 'start_min', a.start_min, 'end_min', a.end_min) order by a.weekday, a.start_min)
                 from public.vet_availability a where a.vet_id = v_uid), '[]'),
      'time_off', coalesce((select jsonb_agg(jsonb_build_object('from', lower(t.period),
                 'to', upper(t.period)) order by lower(t.period))
                 from public.vet_time_off t where t.vet_id = v_uid), '[]'),
      'documents', coalesce((select jsonb_agg(jsonb_build_object('kind', d.kind, 'mime', d.mime,
                 'size_bytes', d.size_bytes, 'uploaded_at', d.uploaded_at,
                 'review_status', d.review_status, 'purge_after', d.purge_after,
                 'purged_at', d.purged_at) order by d.uploaded_at)
                 from public.vet_documents d where d.vet_id = v_uid), '[]'),
      'title_verifications', coalesce((select jsonb_agg(jsonb_build_object('source', t.source,
                 'outcome', t.outcome, 'risk', t.risk, 'suggested_checks', t.suggested_checks,
                 'created_at', t.created_at) order by t.created_at)
                 from public.vet_title_verifications t where t.vet_id = v_uid), '[]'),
      'presence', (select jsonb_build_object('online', p.online, 'updated_at', p.updated_at)
                   from public.vet_presence p where p.vet_id = v_uid),
      -- Visitas atendidas sin datos del dueño, la mascota ni la dirección.
      'visits', coalesce((select jsonb_agg(jsonb_build_object('id', vi.id, 'mode', vi.mode,
                 'status', vi.status, 'scheduled_at', vi.scheduled_at,
                 'completed_at', vi.completed_at, 'commune', c.name, 'species', s.name,
                 'specialty', sp.name,
                 'service_price', (vi.quote ->> 'service_price')::integer
                   + coalesce((vi.quote ->> 'plan_subsidy')::integer, 0),
                 'vet_payout', (vi.quote ->> 'vet_payout')::integer)
                 order by vi.created_at)
                 from public.visits vi
                 join public.communes c on c.id = vi.commune_id
                 join public.species s on s.id = vi.species_id
                 join public.specialties sp on sp.id = vi.specialty_id
                 where vi.vet_id = v_uid), '[]'),
      -- Liquidaciones: sin el dueño, el total ni su donación (HU8.6).
      'payouts', coalesce((select jsonb_agg(jsonb_build_object('visit_id', pa.visit_id,
                 'kind', pa.kind, 'status', pa.status, 'service_price', pa.service_price + pa.plan_subsidy,
                 'platform_fee', pa.platform_fee, 'vet_payout', pa.vet_payout,
                 'paid_at', pa.paid_at) order by pa.created_at)
                 from public.payments pa where pa.vet_id = v_uid), '[]'),
      -- Entradas que escribió: solo metadatos (el contenido es de la ficha del
      -- dueño; se lee por get_pet_record o request_retained_entry).
      'clinical_entries_authored', coalesce((select jsonb_agg(jsonb_build_object('id', e.id,
                 'created_at', e.created_at, 'kind', e.kind, 'species', s.name,
                 'visit_id', e.visit_id, 'retained', e.pet_id is null,
                 'retain_until', e.retain_until) order by e.created_at)
                 from public.clinical_entries e join public.species s on s.id = e.species_id
                 where e.author_id = v_uid and e.author_role = 'vet'), '[]'),
      'retained_entry_requests', coalesce((select jsonb_agg(jsonb_build_object(
                 'entry_id', r.entry_id, 'reason', r.reason, 'requested_at', r.requested_at)
                 order by r.requested_at)
                 from public.retained_entry_requests r where r.vet_id = v_uid), '[]'),
      -- Fase 9: alertas de cancelaciones sobre el vet (sin quién las revisó).
      'cancel_alerts', coalesce((select jsonb_agg(jsonb_build_object(
                 'cancel_count', a.cancel_count, 'first_cancel_at', a.first_cancel_at,
                 'last_cancel_at', a.last_cancel_at, 'created_at', a.created_at,
                 'reviewed_at', a.reviewed_at) order by a.created_at)
                 from public.vet_cancel_alerts a where a.vet_id = v_uid), '[]'));
  elsif v_role = 'foundation' then
    v_data := jsonb_build_object(
      'memberships', coalesce((select jsonb_agg(jsonb_build_object('foundation', f.name,
                 'active', m.active, 'created_at', m.created_at) order by m.created_at)
                 from public.foundation_members m join public.foundations f on f.id = m.foundation_id
                 where m.user_id = v_uid), '[]'));
  else
    v_data := '{}'::jsonb;
  end if;

  insert into public.data_exports (user_id, role, sections)
  values (v_uid, coalesce(v_role, 'none'),
          array(select jsonb_object_keys(v_common || v_data) order by 1));

  return jsonb_build_object('format', 'felix-export', 'format_version', 1,
           'generated_at', now(), 'subject_role', v_role)
         || v_common || v_data;
end;
$$;

-- Igual que en 20261125180000_ratings_cancellations.sql, más el paso de las
-- suscripciones del dueño.
create or replace function private.erase_subject(p_req uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.deletion_requests;
  v_uid uuid;
  v_pets uuid[];
  v_terms text[];
  v_n integer;
  v_t text;
begin
  select * into d from public.deletion_requests where id = p_req;
  v_uid := d.user_id;
  select coalesce(array_agg(p.id), '{}') into v_pets from public.pets p where p.owner_id = v_uid;
  update public.deletion_requests set subject_pet_ids = v_pets where id = p_req;

  -- Términos a redactar del texto libre retenido (M3).
  select array_remove(array_agg(distinct x), null) into v_terms from (
    select u.email as x from auth.users u where u.id = v_uid
    union all select o.display_name from public.owner_profiles o where o.user_id = v_uid
    union all select regexp_split_to_table(o.display_name, '\s+')
              from public.owner_profiles o where o.user_id = v_uid
    union all select o.phone from public.owner_profiles o where o.user_id = v_uid
    union all select p.name from public.pets p where p.owner_id = v_uid
    union all select regexp_split_to_table(p.name, '\s+') from public.pets p where p.owner_id = v_uid
    union all select p.microchip from public.pets p where p.owner_id = v_uid
    union all select a.street_text from public.addresses a where a.owner_id = v_uid
    union all select a.details from public.addresses a where a.owner_id = v_uid
  ) s;

  -- Storage: se encola y la Edge Function lo borra con la API de Storage.
  insert into private.storage_erasure_queue (request_id, bucket_id, object_name)
  select p_req, o.bucket_id, o.name from storage.objects o
  where (o.bucket_id = 'clinical-attachments'
         and (storage.foldername(o.name))[2] = any (array(select x::text from unnest(v_pets) x)))
     or (o.bucket_id = 'vet-documents'
         and ((storage.foldername(o.name))[1] = v_uid::text or o.owner_id = v_uid::text))
     or (o.bucket_id not in ('clinical-attachments', 'vet-documents')
         and o.owner_id = v_uid::text)
  on conflict (bucket_id, object_name) do nothing;
  get diagnostics v_n = row_count;
  perform private.log_target(p_req, 'storage', 'storage.objects', 'delete', v_n, null, v_n = 0);

  -- ---- Dueño ---------------------------------------------------------------
  if d.role = 'owner' then
    delete from public.entry_attachments ea
    using public.clinical_entries e
    where e.id = ea.entry_id and e.pet_id = any (v_pets);
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'entry_attachments', 'delete', v_n,
      'Adjuntos del dueño y de vets: los binarios no se pueden redactar');

    -- Notas del dueño (y entradas sin autor vigente).
    delete from public.clinical_entries e
    where e.pet_id = any (v_pets) and (e.author_role = 'owner' or e.author_id is null);
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'clinical_entries (dueño)', 'delete', v_n);

    -- P1: entradas de vets desvinculadas 5 años, con la PII redactada (M3).
    update public.clinical_vaccines set pet_id = null where pet_id = any (v_pets);
    update public.clinical_entries e
    set pet_id = null,
        retain_until = now() + interval '5 years',
        title = left(coalesce(nullif(trim(private.redact_pii(e.title, v_terms)), ''),
                              '[redactado]'), 120),
        body = left(private.redact_pii(e.body, v_terms), 4000)
    where e.pet_id = any (v_pets);
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'clinical_entries (vets)', 'retain', v_n,
      'P1: defensa ante reclamos (art. 2515 CC), 5 años, desvinculadas y redactadas; '
      || 'solo el vet autor por solicitud registrada');

    delete from public.record_access_log where pet_id = any (v_pets);
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'logs', 'record_access_log', 'delete', v_n);
    delete from public.record_access_grants where pet_id = any (v_pets);
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'record_access_grants', 'delete', v_n);

    -- Visitas y pagos: sin dueño, mascota, dirección ni texto libre; se
    -- conservan comuna, especie y montos (los aportes no se tocan).
    update public.visits
    set owner_id = null, pet_id = null, address_id = null, quote_id = null,
        owner_notes = null, cancel_reason = null
    where owner_id = v_uid;
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'visits', 'anonymize', v_n,
      'Contabilidad: se conservan comuna, especie y montos');
    update public.payments set owner_id = null, quote_id = null where owner_id = v_uid;
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'payments', 'anonymize', v_n,
      'Contabilidad: se conservan los montos y los aportes a fundaciones');

    -- Fase 10: suscripciones y mascotas asociadas (los pagos `subscription`
    -- quedan anonimizados arriba; la FK anula su subscription_id).
    delete from public.subscriptions where owner_id = v_uid;
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'subscriptions (incluye subscription_pets)',
      'delete', v_n);
    delete from public.quotes where owner_id = v_uid;
    delete from private.search_quota where user_id = v_uid;
    select count(*) into v_n from public.addresses where owner_id = v_uid;
    perform private.log_target(p_req, 'db', 'addresses', 'delete', v_n);
    select count(*) into v_n from public.pets where owner_id = v_uid;
    perform private.log_target(p_req, 'db', 'pets (incluye microchip)', 'delete', v_n);
    delete from public.owner_profiles where user_id = v_uid;
    perform private.log_target(p_req, 'db', 'owner_profiles', 'delete', 1);
  end if;

  -- ---- Vet -----------------------------------------------------------------
  if d.role = 'vet' then
    -- Retenidas de dueños borrados: sin autor que las requiera, se borran.
    delete from public.clinical_entries
    where author_id = v_uid and pet_id is null;
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'clinical_entries (retenidas propias)', 'delete', v_n);
    -- HU8.5: la ficha del dueño conserva la autoría clínica ("MV verificado").
    update public.clinical_entries set author_id = null where author_id = v_uid;
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'clinical_entries (autor)', 'anonymize', v_n,
      'HU8.5: la ficha del dueño conserva el contenido con el autor seudonimizado');
    update public.entry_attachments set uploaded_by = null where uploaded_by = v_uid;
    -- Sus archivos en fichas de dueños se quedan (son de la ficha), sin dueño.
    update storage.objects set owner = null, owner_id = null
    where bucket_id = 'clinical-attachments' and owner_id = v_uid::text;
    update public.record_access_log set actor_id = null where actor_id = v_uid;
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'logs', 'record_access_log (actor)', 'anonymize', v_n,
      'Auditoría del dueño: se conserva la acción sin el actor');

    update public.visits set vet_id = null, quote = quote - 'vet_id' where vet_id = v_uid;
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'visits', 'anonymize', v_n,
      'El dueño conserva su historial sin el vet');
    update public.quotes set vet_id = null where vet_id = v_uid;
    update public.payments set vet_id = null where vet_id = v_uid;
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'payments', 'anonymize', v_n,
      'Contabilidad: se conservan los montos');
    delete from public.retained_entry_requests where vet_id = v_uid;
    select count(*) into v_n from public.vet_documents where vet_id = v_uid;
    perform private.log_target(p_req, 'db', 'vet_documents', 'delete', v_n);
    delete from public.vet_cancel_alerts where vet_id = v_uid;
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'vet_cancel_alerts', 'delete', v_n);
    delete from public.vet_profiles where user_id = v_uid;
    perform private.log_target(p_req, 'db', 'vet_profiles (base, horario, presencia)', 'delete', 1);
  end if;

  -- ---- Miembro de fundación ------------------------------------------------
  if d.role = 'foundation' then
    delete from public.foundation_members where user_id = v_uid;
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'foundation_members', 'delete', v_n,
      'Los totales de la fundación no dependen del miembro');
  end if;

  -- ---- Común ---------------------------------------------------------------
  -- Fase 9: calificaciones hechas y recibidas.
  delete from public.ratings where rater_id = v_uid or ratee_id = v_uid;
  get diagnostics v_n = row_count;
  perform private.log_target(p_req, 'db', 'ratings (hechas y recibidas)', 'delete', v_n);

  delete from private.push_devices where user_id = v_uid;
  get diagnostics v_n = row_count;
  perform private.log_target(p_req, 'fcm', 'push_devices', 'delete', v_n);
  delete from private.push_outbox where user_id = v_uid;

  delete from public.consents where user_id = v_uid;
  get diagnostics v_n = row_count;
  perform private.log_target(p_req, 'db', 'consents', 'delete', v_n);
  delete from public.terms_acceptances where user_id = v_uid;
  delete from public.privacy_notice_views where user_id = v_uid;
  delete from public.data_exports where user_id = v_uid;

  update public.admin_audit_log
  set row_pk = '[suprimido]', old_data = null, new_data = null
  where row_pk = v_uid::text
     or old_data::text like '%' || v_uid::text || '%'
     or new_data::text like '%' || v_uid::text || '%';
  get diagnostics v_n = row_count;
  perform private.log_target(p_req, 'logs', 'admin_audit_log', 'anonymize', v_n,
    'Se conserva que hubo una acción del admin, sin el contenido');
  delete from auth.audit_log_entries where payload::text like '%' || v_uid::text || '%';
  get diagnostics v_n = row_count;
  perform private.log_target(p_req, 'logs', 'auth.audit_log_entries', 'delete', v_n);
end;
$$;

-- ===========================================================================
-- 12. Privilegios mínimos
-- ===========================================================================
revoke all on public.subscription_plans, public.subscriptions, public.subscription_pets
  from public, anon, authenticated;
grant select, insert on public.subscription_plans to authenticated;
grant update (name, discount_pct, preventive_per_year, waive_urgent, max_pets, price_monthly,
  sort, active) on public.subscription_plans to authenticated;
grant select on public.subscriptions, public.subscription_pets to authenticated;

revoke execute on function private.subscribe(integer, uuid[]),
  private.set_subscription_pets(uuid[]), private.cancel_subscription(),
  private.my_subscription() from public, anon;
grant execute on function private.subscribe(integer, uuid[]),
  private.set_subscription_pets(uuid[]), private.cancel_subscription(),
  private.my_subscription() to authenticated;
revoke execute on function public.subscribe(integer, uuid[]),
  public.set_subscription_pets(uuid[]), public.cancel_subscription(),
  public.my_subscription() from public, anon;
grant execute on function public.subscribe(integer, uuid[]),
  public.set_subscription_pets(uuid[]), public.cancel_subscription(),
  public.my_subscription() to authenticated;
