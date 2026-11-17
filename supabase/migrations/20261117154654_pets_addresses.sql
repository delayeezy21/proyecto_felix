-- Fase 4: mascotas y direcciones (PostGIS). Ver SPEC.md HU1.1/HU1.2, §3
-- ("Dirección del dueño") y docs/arquitectura.md §4 y §8.
--
-- Principios:
-- * Solo el dueño lee y escribe sus mascotas y direcciones. El admin NO las ve
--   (minimización: no las necesita para moderar; el microchip solo lo ven el
--   dueño y, desde la fase 7, un vet con acceso vigente vía get_pet_record).
-- * Nada se borra desde la app: se desactiva (`active = false`). El borrado
--   real lo hace el job de la fase 11 (cascada desde owner_profiles).
-- * La dirección se geocodifica UNA vez en el cliente al guardarla; la BD
--   guarda lat/lng y deriva `location geography(Point)` (columna generada).
-- * La dirección exacta la verá el vet asignado solo en la fase 6. Aquí se
--   dejan los helpers internos de "ubicación aproximada" (comuna y distancia
--   redondeada a 0,5 km) sin conceder EXECUTE a nadie.
-- * Escala (5.000 usuarios): índice en toda FK y columna de RLS,
--   `(select auth.uid())` en las políticas, GiST en la geografía y topes por
--   dueño (20 mascotas y 10 direcciones activas).

-- ---------------------------------------------------------------------------
-- Mascotas
-- ---------------------------------------------------------------------------
create table public.pets (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.owner_profiles (user_id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 40),
  species_id integer not null references public.species (id),
  breed_id integer references public.breeds (id),
  sex text not null default 'unknown' check (sex in ('male', 'female', 'unknown')),
  -- Aproximada: la app guarda el día 1 del mes (o del año) estimado.
  birth_date_approx date check (birth_date_approx is null or birth_date_approx >= date '1950-01-01'),
  sterilized boolean not null default false,
  -- ISO 11784/11785: 15 dígitos (SPEC §7, opción A).
  microchip text check (microchip is null or microchip ~ '^[0-9]{15}$'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- La lista del dueño filtra por owner_id y ordena por activas/nombre.
create index pets_owner_idx on public.pets (owner_id, active);
create index pets_species_idx on public.pets (species_id);
create index pets_breed_idx on public.pets (breed_id);

-- ---------------------------------------------------------------------------
-- Direcciones
-- ---------------------------------------------------------------------------
create table public.addresses (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.owner_profiles (user_id) on delete cascade,
  label text not null check (char_length(trim(label)) between 1 and 40),
  street_text text not null check (char_length(trim(street_text)) between 3 and 200),
  details text check (details is null or char_length(details) <= 120),
  commune_id integer not null references public.communes (id),
  -- Chile continental, insular (Juan Fernández, Isla de Pascua) y antártico.
  lat double precision not null check (lat between -90 and -17),
  lng double precision not null check (lng between -110 and -66),
  location extensions.geography(Point, 4326) generated always as (
    extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography
  ) stored,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index addresses_owner_idx on public.addresses (owner_id, active);
create index addresses_commune_idx on public.addresses (commune_id);
-- Matching por cercanía (ST_DWithin) de la fase 6/8.
create index addresses_location_gix on public.addresses using gist (location);

-- ---------------------------------------------------------------------------
-- Guardianes: catálogo activo, raza de la especie, fecha no futura y topes.
-- SECURITY DEFINER para leer catálogos sin depender de la RLS; solo los
-- dispara el trigger (sin EXECUTE para nadie).
-- ---------------------------------------------------------------------------
create function private.guard_pet()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.owner_id is distinct from old.owner_id then
    raise exception 'No se puede cambiar el dueño de una mascota' using errcode = '42501';
  end if;

  if tg_op = 'INSERT' or new.species_id is distinct from old.species_id then
    if not exists (select 1 from public.species s
                   where s.id = new.species_id and s.active) then
      raise exception 'La especie no existe o no está activa' using errcode = '22023';
    end if;
  end if;

  if new.breed_id is not null
     and (tg_op = 'INSERT' or new.breed_id is distinct from old.breed_id
          or new.species_id is distinct from old.species_id) then
    if not exists (select 1 from public.breeds b
                   where b.id = new.breed_id and b.species_id = new.species_id
                     and b.active) then
      raise exception 'La raza no corresponde a la especie o no está activa'
        using errcode = '22023';
    end if;
  end if;

  if new.birth_date_approx is not null and new.birth_date_approx > current_date then
    raise exception 'La fecha de nacimiento no puede ser futura' using errcode = '22023';
  end if;

  new.name := trim(new.name);

  if new.active and (tg_op = 'INSERT' or not old.active) then
    -- Serializa altas del mismo dueño para que el tope no se pueda saltar.
    perform pg_advisory_xact_lock(hashtextextended('pets:' || new.owner_id::text, 0));
    if (select count(*) from public.pets p
        where p.owner_id = new.owner_id and p.active and p.id <> new.id) >= 20 then
      raise exception 'Puedes tener hasta 20 mascotas activas' using errcode = '22023';
    end if;
  end if;

  return new;
end;
$$;
revoke execute on function private.guard_pet() from public, anon, authenticated;

create function private.guard_address()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and new.owner_id is distinct from old.owner_id then
    raise exception 'No se puede cambiar el dueño de una dirección' using errcode = '42501';
  end if;

  new.label := trim(new.label);
  new.street_text := trim(new.street_text);
  new.details := nullif(trim(new.details), '');

  if new.active and (tg_op = 'INSERT' or not old.active) then
    perform pg_advisory_xact_lock(hashtextextended('addresses:' || new.owner_id::text, 0));
    if (select count(*) from public.addresses a
        where a.owner_id = new.owner_id and a.active and a.id <> new.id) >= 10 then
      raise exception 'Puedes tener hasta 10 direcciones activas' using errcode = '22023';
    end if;
  end if;

  return new;
end;
$$;
revoke execute on function private.guard_address() from public, anon, authenticated;

create trigger pets_guard before insert or update on public.pets
for each row execute function private.guard_pet();
create trigger pets_touch before update on public.pets
for each row execute function private.touch_updated_at();
create trigger addresses_guard before insert or update on public.addresses
for each row execute function private.guard_address();
create trigger addresses_touch before update on public.addresses
for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- RLS: solo el dueño (con rol owner). Sin políticas para admin, vet ni anon.
-- ---------------------------------------------------------------------------
alter table public.pets enable row level security;
alter table public.pets force row level security;
alter table public.addresses enable row level security;
alter table public.addresses force row level security;

create policy pets_select_own on public.pets
for select to authenticated
using (owner_id = (select auth.uid()));

create policy pets_insert_own on public.pets
for insert to authenticated
with check (
  owner_id = (select auth.uid())
  and (select private.current_app_role()) = 'owner'
);

create policy pets_update_own on public.pets
for update to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

create policy addresses_select_own on public.addresses
for select to authenticated
using (owner_id = (select auth.uid()));

create policy addresses_insert_own on public.addresses
for insert to authenticated
with check (
  owner_id = (select auth.uid())
  and (select private.current_app_role()) = 'owner'
);

create policy addresses_update_own on public.addresses
for update to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Privilegios mínimos (INSERT y UPDATE por columna; sin DELETE).
-- ---------------------------------------------------------------------------
revoke all on public.pets, public.addresses from public, anon, authenticated;

grant select on public.pets, public.addresses to authenticated;
grant insert (owner_id, name, species_id, breed_id, sex, birth_date_approx,
  sterilized, microchip) on public.pets to authenticated;
grant update (name, species_id, breed_id, sex, birth_date_approx, sterilized,
  microchip, active) on public.pets to authenticated;
grant insert (owner_id, label, street_text, details, commune_id, lat, lng)
  on public.addresses to authenticated;
grant update (label, street_text, details, commune_id, lat, lng, active)
  on public.addresses to authenticated;

-- ---------------------------------------------------------------------------
-- Preparación de la fase 6 (sin EXECUTE para authenticated).
-- Un vet con una oferta solo verá la comuna y la distancia redondeada a
-- 0,5 km; nunca la calle ni las coordenadas. Las RPC de visitas usarán estos
-- helpers después de verificar la oferta.
-- ---------------------------------------------------------------------------
create function private.address_approx(p_address uuid, p_from extensions.geography)
returns table (commune_id integer, commune_name text, distance_km_rounded numeric)
language sql
stable
security definer
set search_path = ''
as $$
  select a.commune_id, c.name,
         round((extensions.st_distance(a.location, p_from) / 1000.0)::numeric * 2) / 2
  from public.addresses a
  join public.communes c on c.id = a.commune_id
  where a.id = p_address;
$$;
revoke execute on function private.address_approx(uuid, extensions.geography)
  from public, anon, authenticated;
