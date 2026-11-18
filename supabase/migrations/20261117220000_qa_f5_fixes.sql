-- Correcciones de QA fase 5 (docs/qa/QA-9897476.md).
--
-- QA-F5-01 (Alto): el dueño podía leer quotes.distance_m (metros exactos) y
-- trilaterar la base del vet con ~7 m de error. Redondear no basta: moviendo
-- su dirección (puede editar lat/lng) y mirando cuándo cambia el valor
-- redondeado o los km facturables, un atacante encuentra el borde del
-- redondeo y recupera la distancia exacta; con 60 cotizaciones/h (1.440 al
-- día) eso es trivial para cualquier granularidad. Por eso:
--   1. La distancia se mide desde un ORIGEN APROXIMADO del vet: su base
--      desplazada por un vector aleatorio de 1 a 2 km (rumbo uniforme),
--      generado al crear la base y que no cambia después (si cambiara en cada
--      guardado, promediando varios orígenes se llegaría a la base real). Lo
--      máximo que se puede trilaterar es ese punto falso; la base real queda
--      en un anillo de 1–2 km a su alrededor (~9,4 km²). Costo: el recargo
--      puede variar ±2 km (±$1.000 con $500/km), aceptable y documentado.
--   2. distance_m deja de ser legible por la API (grants por columna) y el
--      cliente solo recibe distance_km redondeada al km.
-- QA-F5-02 (Medio): vet_bases se valida contra commune_boundaries (Chile y
-- comuna) y la cotización tiene una distancia máxima configurable
-- (pricing_config.max_distance_km, 30 km por defecto: cruza el Gran
-- Santiago de punta a punta —Maipú–Las Condes ≈ 25 km— con un recargo
-- máximo de 25 × $500 = $12.500, ~46 % de la consulta; más lejos el
-- traslado supera la hora y la visita deja de ser razonable. Las urgencias
-- ya se limitan a 20 km por el despacho).

-- ---------------------------------------------------------------------------
-- QA-F5-01: origen aproximado del vet
-- ---------------------------------------------------------------------------
alter table public.vet_bases
  add column fuzz_dlat double precision not null default 0,
  add column fuzz_dlng double precision not null default 0;

alter table public.vet_bases
  add column quote_origin extensions.geography(Point, 4326) generated always as (
    extensions.st_setsrid(
      extensions.st_makepoint(lng + fuzz_dlng, lat + fuzz_dlat), 4326)::extensions.geography
  ) stored;

-- Desplazamiento aleatorio de 1 a 2 km (en grados, según la latitud).
create function private.vet_base_offset(p_lat double precision)
returns table (dlat double precision, dlng double precision)
language sql
volatile
security invoker
set search_path = ''
as $$
  with r as (select 1000 + random() * 1000 as m, random() * 2 * pi() as t)
  select r.m * cos(r.t) / 111320.0,
         r.m * sin(r.t) / (111320.0 * cos(radians(p_lat)))
  from r;
$$;
revoke execute on function private.vet_base_offset(double precision)
  from public, anon, authenticated;

-- Valida Chile y comuna (como guard_address) y fija el desplazamiento al
-- crear la base. SECURITY DEFINER para usar los helpers de la fase 4.
create function private.guard_vet_base()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.vet_id is distinct from old.vet_id then
    raise exception 'No se puede cambiar el vet de una base' using errcode = '42501';
  end if;
  -- La autorización va antes que la validación geográfica (este trigger corre
  -- antes que el WITH CHECK de la RLS): nadie crea la base de otro vet.
  if coalesce(current_setting('role', true), 'none') = 'authenticated'
     and new.vet_id is distinct from (select auth.uid()) then
    raise exception 'Solo el propio vet define su base' using errcode = '42501';
  end if;
  if tg_op = 'INSERT'
     or (new.lat, new.lng, new.commune_id) is distinct from (old.lat, old.lng, old.commune_id) then
    if not coalesce(private.point_in_chile(new.lat, new.lng), false) then
      raise exception 'La ubicación debe estar en Chile' using errcode = '22023';
    end if;
    if not coalesce(private.point_in_commune(new.commune_id, new.lat, new.lng), false) then
      raise exception 'La ubicación marcada no está en la comuna elegida'
        using errcode = '22023';
    end if;
  end if;
  if tg_op = 'INSERT' then
    select o.dlat, o.dlng into new.fuzz_dlat, new.fuzz_dlng
    from private.vet_base_offset(new.lat) o;
  end if;
  return new;
end;
$$;
revoke execute on function private.guard_vet_base() from public, anon, authenticated;

create trigger vet_bases_guard before insert or update on public.vet_bases
for each row execute function private.guard_vet_base();

-- Bases existentes (solo entornos de desarrollo): reciben su desplazamiento.
update public.vet_bases b
set (fuzz_dlat, fuzz_dlng) = (select o.dlat, o.dlng from private.vet_base_offset(b.lat) o);

-- distance_m no es legible por la API (ni para el admin): SELECT por columna.
revoke select on public.quotes from authenticated;
grant select (id, owner_id, pet_id, address_id, vet_id, species_id, specialty_id,
  commune_id, mode, pricing_config_id, foundation_id, base_price, urgent_surcharge,
  billable_km, distance_surcharge, discount, service_price, platform_fee,
  foundation_share, vet_payout, extra_donation, total, created_at, expires_at,
  consumed_at) on public.quotes to authenticated;

-- ---------------------------------------------------------------------------
-- QA-F5-02: distancia máxima de atención (versionada en pricing_config)
-- ---------------------------------------------------------------------------
alter table public.pricing_config
  add column max_distance_km integer not null default 30
    check (max_distance_km between 1 and 500);

-- ---------------------------------------------------------------------------
-- Funciones redefinidas (quote_snapshot, quote_for, create_quote)
-- ---------------------------------------------------------------------------
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
    -- Al cliente: distancia desde el origen aproximado, redondeada al km.
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
    'currency', 'CLP',
    'created_at', q.created_at,
    'expires_at', q.expires_at
  );
$$;

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
    v_cfg.per_km, v_cfg.free_km, 0, false, false, v_cfg.commission_on_distance) b
  returning * into v_q;

  return v_q;
end;
$$;

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
  v_q public.quotes;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño puede cotizar' using errcode = '42501';
  end if;
  v_q := private.quote_for(
    v_uid, p_pet_id, p_address_id, p_specialty_id, p_mode, p_vet_id,
    (select b.quote_origin from public.vet_bases b where b.vet_id = p_vet_id),
    p_foundation_id, p_extra_donation);
  return private.quote_snapshot(v_q);
end;
$$;
