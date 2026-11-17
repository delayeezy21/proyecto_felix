-- Fase 5: precios, pagos simulados y fundaciones.
-- Ver SPEC.md F4 (HU4.1 a HU4.4), §3 (tarifa y comisión) y
-- docs/arquitectura.md §4 y §11.
--
-- Principios:
-- * El precio se calcula SOLO en el servidor. `quote_visit` no recibe montos:
--   lee la tarifa, la versión vigente de `pricing_config` y la distancia
--   (PostGIS) y guarda una cotización persistente e inmutable en `quotes`.
--   La fase 6 la congela en `visits.quote` con `private.consume_quote`.
-- * Redondeo explícito a CLP enteros: `private.clp_round` (mitad hacia arriba)
--   en cada porcentaje; el pago al vet es la resta (servicio − comisión), así
--   los montos siempre cuadran al peso.
-- * Pagos SIMULADOS: no existe ninguna pasarela. `payments.provider` solo
--   admite 'simulated'. El reparto (comisión, fundación, vet, donación) queda
--   en columnas inmutables con `check` de cuadratura, en `payment_events`
--   (historial de estados) y en `foundation_contributions`.
-- * Fundaciones (Ley 21.719): sus miembros NO leen pagos ni aportes; solo
--   reciben totales agregados por mes vía `foundation_summary`.
-- * Escala: índice en toda FK y columna de RLS, `(select auth.uid())` y
--   tope de cotizaciones por dueño y hora (advisory lock).

-- ---------------------------------------------------------------------------
-- Redondeo y desglose (funciones puras, sin EXECUTE para la app)
-- ---------------------------------------------------------------------------
create function private.clp_round(p numeric)
returns integer
language sql
immutable
security invoker
set search_path = ''
as $$
  -- Mitad hacia arriba (los montos nunca son negativos): 0,5 → 1.
  select floor(p + 0.5)::integer;
$$;
revoke execute on function private.clp_round(numeric) from public, anon, authenticated;

-- Desglose de una visita. Los parámetros de suscripción (descuento, recargo
-- de urgencia incluido, preventiva incluida) los alimenta la fase 10; hoy
-- quote_visit pasa 0/false/false.
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
  p_preventive_included boolean default false
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
  total integer
)
language sql
immutable
security invoker
set search_path = ''
as $$
  with b as (
    select
      p_base as base,
      case when p_urgent and not p_waive_urgent
           then private.clp_round(p_base * p_urgent_pct / 100) else 0 end as urgent,
      -- Km facturables: se redondea HACIA ARRIBA el tramo sobre los km libres
      -- (5,2 km con 5 libres = 1 km). Sin distancia conocida = 0.
      case when p_distance_m is null then 0
           else greatest(0, ceil((p_distance_m - p_free_km * 1000) / 1000.0))::integer
      end as km,
      case when p_preventive_included then p_base
           else private.clp_round(p_base * p_discount_pct / 100) end as disc
  ), s as (
    select b.*, b.km * p_per_km as dist,
           b.base - b.disc + b.urgent + b.km * p_per_km as service
    from b
  ), f as (
    select s.*, private.clp_round(s.service * p_commission_pct / 100) as fee from s
  )
  select f.base, f.urgent, f.km, f.dist, f.disc, f.service, f.fee,
         private.clp_round(f.fee * p_foundation_pct / 100),
         f.service - f.fee,
         p_extra_donation,
         f.service + p_extra_donation
  from f;
$$;
revoke execute on function private.price_breakdown(integer, boolean, integer, integer,
  numeric, numeric, numeric, integer, integer, numeric, boolean, boolean)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Fundaciones
-- ---------------------------------------------------------------------------
create table public.foundations (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(trim(name)) between 2 and 80),
  description text check (description is null or char_length(description) <= 280),
  website text check (website is null or website ~ '^https://[^[:space:]]{3,200}$'),
  is_default boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- La fundación por defecto debe estar activa.
  constraint foundations_default_active check (not is_default or active)
);

-- Solo una fundación por defecto.
create unique index foundations_one_default on public.foundations (is_default)
  where is_default;
create index foundations_active_idx on public.foundations (active);

-- Miembros (usuarios con rol `foundation`). Los crea el admin por SQL, igual
-- que el admin: el registro de la app solo asigna owner/vet.
create table public.foundation_members (
  user_id uuid primary key references auth.users (id) on delete cascade,
  foundation_id uuid not null references public.foundations (id),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create index foundation_members_foundation_idx on public.foundation_members (foundation_id);

-- Fundación del miembro actual (o null). La usan RLS y el resumen.
create function private.current_foundation_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.foundation_id
  from public.foundation_members m
  join public.user_roles r on r.user_id = m.user_id and r.role = 'foundation'
  where m.user_id = (select auth.uid()) and m.active;
$$;
revoke execute on function private.current_foundation_id() from public, anon;
grant execute on function private.current_foundation_id() to authenticated;

-- Un miembro debe tener el rol `foundation`.
create function private.guard_foundation_member()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.user_roles r
                 where r.user_id = new.user_id and r.role = 'foundation') then
    raise exception 'El usuario no tiene el rol fundación' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke execute on function private.guard_foundation_member() from public, anon, authenticated;

create trigger foundation_members_guard before insert or update on public.foundation_members
for each row execute function private.guard_foundation_member();
create trigger foundations_touch before update on public.foundations
for each row execute function private.touch_updated_at();
create trigger foundations_audit after insert or update on public.foundations
for each row execute function private.log_admin_change();
create trigger foundation_members_audit after insert or update on public.foundation_members
for each row execute function private.log_admin_change();

alter table public.foundations enable row level security;
alter table public.foundations force row level security;
alter table public.foundation_members enable row level security;
alter table public.foundation_members force row level security;

-- Todos los autenticados ven las activas (el dueño elige); el miembro ve la
-- suya aunque esté inactiva; el admin ve todas.
create policy foundations_read on public.foundations
for select to authenticated
using (active or id = (select private.current_foundation_id())
       or (select private.is_admin()));
create policy foundations_admin_insert on public.foundations
for insert to authenticated with check ((select private.is_admin()));
create policy foundations_admin_update on public.foundations
for update to authenticated
using ((select private.is_admin())) with check ((select private.is_admin()));

create policy foundation_members_read on public.foundation_members
for select to authenticated
using (user_id = (select auth.uid()) or (select private.is_admin()));
create policy foundation_members_admin_insert on public.foundation_members
for insert to authenticated with check ((select private.is_admin()));
create policy foundation_members_admin_update on public.foundation_members
for update to authenticated
using ((select private.is_admin())) with check ((select private.is_admin()));

-- Cambio atómico de la fundación por defecto (solo admin, vía RLS).
create function public.set_default_foundation(p_foundation_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not (select private.is_admin()) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  if not exists (select 1 from public.foundations f
                 where f.id = p_foundation_id and f.active) then
    raise exception 'La fundación no existe o no está activa' using errcode = '22023';
  end if;
  update public.foundations set is_default = false
  where is_default and id <> p_foundation_id;
  update public.foundations set is_default = true
  where id = p_foundation_id and not is_default;
end;
$$;

-- ---------------------------------------------------------------------------
-- Fundación elegida por el dueño (null = la por defecto)
-- ---------------------------------------------------------------------------
alter table public.owner_profiles
  add column foundation_id uuid references public.foundations (id);

create index owner_profiles_foundation_idx on public.owner_profiles (foundation_id);

-- SECURITY INVOKER: el dueño solo ve las fundaciones activas, así que una
-- inactiva o inexistente no pasa.
create function private.guard_owner_foundation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.foundation_id is not null
     and new.foundation_id is distinct from old.foundation_id
     and not exists (select 1 from public.foundations f
                     where f.id = new.foundation_id and f.active) then
    raise exception 'La fundación no existe o no está activa' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke execute on function private.guard_owner_foundation() from public, anon, authenticated;

create trigger owner_profiles_foundation_guard before update of foundation_id
on public.owner_profiles
for each row execute function private.guard_owner_foundation();

-- ---------------------------------------------------------------------------
-- Punto de partida del vet (origen de la distancia de las visitas agendadas).
-- Solo lo lee y escribe el propio vet; nadie más ve sus coordenadas. La UI
-- para editarlo llega con la fase 6 (agenda).
-- ---------------------------------------------------------------------------
create table public.vet_bases (
  vet_id uuid primary key references public.vet_profiles (user_id) on delete cascade,
  commune_id integer not null references public.communes (id),
  lat double precision not null check (lat between -90 and -17),
  lng double precision not null check (lng between -110 and -66),
  location extensions.geography(Point, 4326) generated always as (
    extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography
  ) stored,
  updated_at timestamptz not null default now()
);

create index vet_bases_commune_idx on public.vet_bases (commune_id);
create index vet_bases_location_gix on public.vet_bases using gist (location);

create trigger vet_bases_touch before update on public.vet_bases
for each row execute function private.touch_updated_at();

alter table public.vet_bases enable row level security;
alter table public.vet_bases force row level security;

create policy vet_bases_select_own on public.vet_bases
for select to authenticated using (vet_id = (select auth.uid()));
create policy vet_bases_insert_own on public.vet_bases
for insert to authenticated
with check (vet_id = (select auth.uid())
            and (select private.current_app_role()) = 'vet');
create policy vet_bases_update_own on public.vet_bases
for update to authenticated
using (vet_id = (select auth.uid())) with check (vet_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Cotizaciones (persistentes e inmutables)
-- ---------------------------------------------------------------------------
create table public.quotes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.owner_profiles (user_id) on delete cascade,
  pet_id uuid references public.pets (id) on delete set null,
  address_id uuid references public.addresses (id) on delete set null,
  vet_id uuid references public.vet_profiles (user_id) on delete set null,
  species_id integer not null references public.species (id),
  specialty_id integer not null references public.specialties (id),
  commune_id integer not null references public.communes (id),
  mode text not null check (mode in ('urgent', 'scheduled')),
  pricing_config_id integer not null references public.pricing_config (id),
  foundation_id uuid not null references public.foundations (id),
  -- Distancia real (m) entre el origen del vet y addresses.location; null si
  -- aún no hay vet (urgencias: se conoce al aceptar, fase 8).
  distance_m integer check (distance_m is null or distance_m >= 0),
  base_price integer not null check (base_price >= 0),
  urgent_surcharge integer not null check (urgent_surcharge >= 0),
  billable_km integer not null check (billable_km >= 0),
  distance_surcharge integer not null check (distance_surcharge >= 0),
  discount integer not null check (discount >= 0),
  service_price integer not null check (service_price >= 0),
  platform_fee integer not null check (platform_fee >= 0),
  foundation_share integer not null check (foundation_share >= 0),
  vet_payout integer not null check (vet_payout >= 0),
  extra_donation integer not null check (extra_donation between 0 and 1000000),
  total integer not null check (total >= 0),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  constraint quotes_service_sum check (
    service_price = base_price - discount + urgent_surcharge + distance_surcharge),
  constraint quotes_split_sum check (platform_fee + vet_payout = service_price),
  constraint quotes_foundation_le_fee check (foundation_share <= platform_fee),
  constraint quotes_total_sum check (total = service_price + extra_donation)
);

create index quotes_owner_created_idx on public.quotes (owner_id, created_at desc);
create index quotes_pet_idx on public.quotes (pet_id);
create index quotes_address_idx on public.quotes (address_id);
create index quotes_vet_idx on public.quotes (vet_id);
create index quotes_species_idx on public.quotes (species_id);
create index quotes_specialty_idx on public.quotes (specialty_id);
create index quotes_commune_idx on public.quotes (commune_id);
create index quotes_pricing_config_idx on public.quotes (pricing_config_id);
create index quotes_foundation_idx on public.quotes (foundation_id);

-- Montos inmutables incluso para funciones internas: solo cambian
-- `consumed_at` (una vez) y los FK que se anulan por borrado.
create function private.guard_quote_update()
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
      new.extra_donation, new.total, new.created_at, new.expires_at)
     is distinct from
     (old.owner_id, old.species_id, old.specialty_id, old.commune_id, old.mode,
      old.pricing_config_id, old.foundation_id, old.distance_m, old.base_price,
      old.urgent_surcharge, old.billable_km, old.distance_surcharge, old.discount,
      old.service_price, old.platform_fee, old.foundation_share, old.vet_payout,
      old.extra_donation, old.total, old.created_at, old.expires_at) then
    raise exception 'Una cotización no se modifica' using errcode = '42501';
  end if;
  if old.consumed_at is not null and new.consumed_at is distinct from old.consumed_at then
    raise exception 'La cotización ya fue usada' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke execute on function private.guard_quote_update() from public, anon, authenticated;

create trigger quotes_guard before update on public.quotes
for each row execute function private.guard_quote_update();

alter table public.quotes enable row level security;
alter table public.quotes force row level security;

create policy quotes_select on public.quotes
for select to authenticated
using (owner_id = (select auth.uid()) or (select private.is_admin()));

-- Snapshot que la fase 6 guarda en visits.quote (y que devuelve quote_visit).
create function private.quote_snapshot(q public.quotes)
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
    -- Al cliente solo se le muestra la distancia redondeada a 0,5 km.
    'distance_km', case when q.distance_m is null then null
                        else round(q.distance_m / 500.0) / 2 end,
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
    'currency', 'CLP',
    'created_at', q.created_at,
    'expires_at', q.expires_at
  );
$$;
revoke execute on function private.quote_snapshot(public.quotes) from public, anon, authenticated;

-- Núcleo de la cotización. Sin EXECUTE para la app: el origen de la distancia
-- (p_origin) lo decide el servidor, nunca el cliente.
create function private.quote_for(
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

  -- Tope anti abuso: 60 cotizaciones por dueño y hora (serializado).
  perform pg_advisory_xact_lock(hashtextextended('quotes:' || p_owner::text, 0));
  if (select count(*) from public.quotes q
      where q.owner_id = p_owner and q.created_at > now() - interval '1 hour') >= 60 then
    raise exception 'Demasiadas cotizaciones. Intenta en unos minutos.'
      using errcode = '22023';
  end if;

  insert into public.quotes (
    owner_id, pet_id, address_id, vet_id, species_id, specialty_id, commune_id,
    mode, pricing_config_id, foundation_id, distance_m,
    base_price, urgent_surcharge, billable_km, distance_surcharge, discount,
    service_price, platform_fee, foundation_share, vet_payout, extra_donation,
    total, expires_at)
  select p_owner, p_pet_id, p_address_id, p_vet_id, v_species, p_specialty_id,
    v_commune, p_mode, v_cfg.id, v_foundation, v_distance,
    b.base_price, b.urgent_surcharge, b.billable_km, b.distance_surcharge, b.discount,
    b.service_price, b.platform_fee, b.foundation_share, b.vet_payout,
    b.extra_donation, b.total, now() + interval '30 minutes'
  from private.price_breakdown(
    v_base, p_mode = 'urgent', v_distance, coalesce(p_extra_donation, 0),
    v_cfg.commission_pct, v_cfg.foundation_pct, v_cfg.urgent_pct,
    v_cfg.per_km, v_cfg.free_km) b
  returning * into v_q;

  return v_q;
end;
$$;
revoke execute on function private.quote_for(uuid, uuid, uuid, integer, text, uuid,
  extensions.geography, uuid, integer) from public, anon, authenticated;

-- Punto de entrada de la app: valida al usuario y deriva el origen del vet.
create function private.create_quote(
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
  v_q public.quotes;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño puede cotizar' using errcode = '42501';
  end if;
  v_q := private.quote_for(
    v_uid, p_pet_id, p_address_id, p_specialty_id, p_mode, p_vet_id,
    (select b.location from public.vet_bases b where b.vet_id = p_vet_id),
    p_foundation_id, p_extra_donation);
  return private.quote_snapshot(v_q);
end;
$$;
revoke execute on function private.create_quote(uuid, uuid, integer, text, uuid, uuid, integer)
  from public, anon;
grant execute on function private.create_quote(uuid, uuid, integer, text, uuid, uuid, integer)
  to authenticated;

create function public.quote_visit(
  p_pet_id uuid,
  p_address_id uuid,
  p_specialty_id integer,
  p_mode text,
  p_vet_id uuid default null,
  p_foundation_id uuid default null,
  p_extra_donation integer default 0
)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.create_quote(p_pet_id, p_address_id, p_specialty_id, p_mode,
                              p_vet_id, p_foundation_id, p_extra_donation);
$$;

-- Contrato para la fase 6: bloquea la cotización, verifica dueño, vigencia y
-- que no se haya usado, y la marca como usada. Sin EXECUTE para la app.
create function private.consume_quote(p_quote_id uuid, p_owner uuid)
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
  if v_q.consumed_at is not null then
    raise exception 'La cotización ya fue usada' using errcode = '22023';
  end if;
  if v_q.expires_at < now() then
    raise exception 'La cotización venció. Vuelve a cotizar.' using errcode = '22023';
  end if;
  update public.quotes set consumed_at = now() where id = p_quote_id
  returning * into v_q;
  return v_q;
end;
$$;
revoke execute on function private.consume_quote(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Pagos simulados
-- ---------------------------------------------------------------------------
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  -- Ambos se anulan si se borra al dueño (fase 11): los montos se conservan.
  owner_id uuid references public.owner_profiles (user_id) on delete set null,
  quote_id uuid references public.quotes (id) on delete set null,
  foundation_id uuid not null references public.foundations (id),
  kind text not null check (kind in ('visit', 'cancel_fee', 'subscription')),
  status text not null default 'pending'
    check (status in ('pending', 'simulated_paid', 'simulated_failed')),
  -- Nunca hay pasarela real.
  provider text not null default 'simulated' check (provider = 'simulated'),
  service_price integer not null check (service_price >= 0),
  platform_fee integer not null check (platform_fee >= 0),
  foundation_share integer not null check (foundation_share >= 0),
  vet_payout integer not null check (vet_payout >= 0),
  extra_donation integer not null check (extra_donation >= 0),
  total integer not null check (total >= 0),
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  constraint payments_split_sum check (platform_fee + vet_payout = service_price),
  constraint payments_foundation_le_fee check (foundation_share <= platform_fee),
  constraint payments_total_sum check (total = service_price + extra_donation),
  constraint payments_paid_at check ((status = 'simulated_paid') = (paid_at is not null))
);

create index payments_owner_idx on public.payments (owner_id, created_at desc);
create index payments_quote_idx on public.payments (quote_id);
create index payments_foundation_idx on public.payments (foundation_id);
-- Una cotización se paga una sola vez (los intentos fallidos no cuentan).
create unique index payments_quote_paid_once on public.payments (quote_id)
  where status = 'simulated_paid';

-- Historial de estados (solo inserción, vía trigger).
create table public.payment_events (
  id bigint generated always as identity primary key,
  payment_id uuid not null references public.payments (id) on delete cascade,
  from_status text,
  to_status text not null,
  actor_id uuid references auth.users (id) on delete set null,
  at timestamptz not null default now()
);

create index payment_events_payment_idx on public.payment_events (payment_id);
create index payment_events_actor_idx on public.payment_events (actor_id);

-- Aportes a fundaciones. Sin datos del dueño: solo pago, fundación, tipo,
-- monto y fecha. Se generan al quedar el pago en simulated_paid.
create table public.foundation_contributions (
  id bigint generated always as identity primary key,
  payment_id uuid not null references public.payments (id),
  foundation_id uuid not null references public.foundations (id),
  kind text not null check (kind in ('commission_share', 'donation')),
  amount integer not null check (amount > 0),
  created_at timestamptz not null default now(),
  unique (payment_id, kind)
);

create index foundation_contributions_foundation_idx
  on public.foundation_contributions (foundation_id, created_at);

-- Estados válidos: pending → simulated_paid | simulated_failed. Montos,
-- dueño, fundación y tipo son inmutables.
create function private.guard_payment()
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
     or (new.owner_id is distinct from old.owner_id and new.owner_id is not null) then
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
revoke execute on function private.guard_payment() from public, anon, authenticated;

-- Registra el cambio de estado y, al pagarse, el reparto a la fundación.
create function private.after_payment_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into public.payment_events (payment_id, from_status, to_status, actor_id)
    values (new.id, case when tg_op = 'UPDATE' then old.status end, new.status,
            (select auth.uid()));
  end if;
  if tg_op = 'UPDATE' and new.status = 'simulated_paid' and old.status <> 'simulated_paid' then
    insert into public.foundation_contributions (payment_id, foundation_id, kind, amount)
    select new.id, new.foundation_id, c.kind, c.amount
    from (values ('commission_share', new.foundation_share),
                 ('donation', new.extra_donation)) as c (kind, amount)
    where c.amount > 0;
  end if;
  return new;
end;
$$;
revoke execute on function private.after_payment_change() from public, anon, authenticated;

create trigger payments_guard before insert or update on public.payments
for each row execute function private.guard_payment();
create trigger payments_after after insert or update on public.payments
for each row execute function private.after_payment_change();

alter table public.payments enable row level security;
alter table public.payments force row level security;
alter table public.payment_events enable row level security;
alter table public.payment_events force row level security;
alter table public.foundation_contributions enable row level security;
alter table public.foundation_contributions force row level security;

-- El dueño ve sus pagos; el admin, todos. Ni vets ni fundaciones (SPEC HU8.6).
create policy payments_select on public.payments
for select to authenticated
using (owner_id = (select auth.uid()) or (select private.is_admin()));
create policy payment_events_admin_read on public.payment_events
for select to authenticated using ((select private.is_admin()));
create policy foundation_contributions_admin_read on public.foundation_contributions
for select to authenticated using ((select private.is_admin()));

-- Pago simulado de una cotización (fase 5). En la fase 6 el cobro de la visita
-- lo dispara su cierre; esta RPC queda como la única vía de pago y nunca
-- llama a una pasarela.
create function private.pay_quote_simulated(p_quote_id uuid, p_simulate_failure boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_q public.quotes;
  v_payment public.payments;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño puede pagar' using errcode = '42501';
  end if;

  if coalesce(p_simulate_failure, false) then
    -- El intento fallido no consume la cotización (se puede reintentar),
    -- pero sí se valida y queda registrado. Máximo 5 fallos por cotización.
    select * into v_q from public.quotes q
    where q.id = p_quote_id and q.owner_id = v_uid for update;
    if not found or v_q.consumed_at is not null or v_q.expires_at < now() then
      raise exception 'La cotización no existe, venció o ya fue usada' using errcode = '22023';
    end if;
    if (select count(*) from public.payments p where p.quote_id = p_quote_id) >= 5 then
      raise exception 'Demasiados intentos para esta cotización' using errcode = '22023';
    end if;
  else
    v_q := private.consume_quote(p_quote_id, v_uid);
  end if;

  insert into public.payments (owner_id, quote_id, foundation_id, kind,
    service_price, platform_fee, foundation_share, vet_payout, extra_donation, total)
  values (v_uid, v_q.id, v_q.foundation_id, 'visit', v_q.service_price,
    v_q.platform_fee, v_q.foundation_share, v_q.vet_payout, v_q.extra_donation, v_q.total)
  returning * into v_payment;

  update public.payments
  set status = case when coalesce(p_simulate_failure, false)
                    then 'simulated_failed' else 'simulated_paid' end,
      paid_at = case when coalesce(p_simulate_failure, false) then null else now() end
  where id = v_payment.id
  returning * into v_payment;

  return jsonb_build_object(
    'payment_id', v_payment.id, 'status', v_payment.status,
    'total', v_payment.total, 'service_price', v_payment.service_price,
    'platform_fee', v_payment.platform_fee,
    'foundation_share', v_payment.foundation_share,
    'vet_payout', v_payment.vet_payout,
    'extra_donation', v_payment.extra_donation, 'paid_at', v_payment.paid_at);
end;
$$;
revoke execute on function private.pay_quote_simulated(uuid, boolean) from public, anon;
grant execute on function private.pay_quote_simulated(uuid, boolean) to authenticated;

create function public.simulate_payment(p_quote_id uuid, p_simulate_failure boolean default false)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.pay_quote_simulated(p_quote_id, p_simulate_failure);
$$;

-- ---------------------------------------------------------------------------
-- Panel de la fundación: solo totales agregados por mes (sin filas de pago).
-- ---------------------------------------------------------------------------
create function private.foundation_monthly_totals(p_months integer)
returns table (month date, commission_total bigint, donation_total bigint, total bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select date_trunc('month', c.created_at at time zone 'America/Santiago')::date,
         coalesce(sum(c.amount) filter (where c.kind = 'commission_share'), 0)::bigint,
         coalesce(sum(c.amount) filter (where c.kind = 'donation'), 0)::bigint,
         sum(c.amount)::bigint
  from public.foundation_contributions c
  where c.foundation_id = (select private.current_foundation_id())
    and c.created_at >= date_trunc('month', now() at time zone 'America/Santiago')
          at time zone 'America/Santiago'
          - make_interval(months => least(greatest(coalesce(p_months, 12), 1), 60) - 1)
  group by 1
  order by 1 desc;
$$;
revoke execute on function private.foundation_monthly_totals(integer) from public, anon;
grant execute on function private.foundation_monthly_totals(integer) to authenticated;

create function public.foundation_summary(p_months integer default 12)
returns table (month date, commission_total bigint, donation_total bigint, total bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.foundation_monthly_totals(p_months);
$$;

-- ---------------------------------------------------------------------------
-- Privilegios mínimos (sin DELETE; INSERT/UPDATE por columna)
-- ---------------------------------------------------------------------------
revoke all on public.foundations, public.foundation_members, public.vet_bases,
  public.quotes, public.payments, public.payment_events,
  public.foundation_contributions
  from public, anon, authenticated;

grant select on public.foundations, public.foundation_members, public.vet_bases,
  public.quotes, public.payments, public.payment_events,
  public.foundation_contributions to authenticated;
grant insert (name, description, website, active) on public.foundations to authenticated;
grant update (name, description, website, active, is_default)
  on public.foundations to authenticated;
grant insert (user_id, foundation_id, active) on public.foundation_members to authenticated;
grant update (active) on public.foundation_members to authenticated;
grant insert (vet_id, commune_id, lat, lng) on public.vet_bases to authenticated;
grant update (commune_id, lat, lng) on public.vet_bases to authenticated;
grant update (foundation_id) on public.owner_profiles to authenticated;

revoke execute on function public.set_default_foundation(uuid) from public, anon;
grant execute on function public.set_default_foundation(uuid) to authenticated;
revoke execute on function public.quote_visit(uuid, uuid, integer, text, uuid, uuid, integer)
  from public, anon;
grant execute on function public.quote_visit(uuid, uuid, integer, text, uuid, uuid, integer)
  to authenticated;
revoke execute on function public.simulate_payment(uuid, boolean) from public, anon;
grant execute on function public.simulate_payment(uuid, boolean) to authenticated;
revoke execute on function public.foundation_summary(integer) from public, anon;
grant execute on function public.foundation_summary(integer) to authenticated;
