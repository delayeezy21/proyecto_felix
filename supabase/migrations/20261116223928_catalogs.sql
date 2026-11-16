-- Fase 2: catálogos (regiones, comunas, especies, razas, especialidades,
-- tarifas, parámetros de precio, clínicas 24 h) y auditoría de admin.
-- Ver SPEC.md F6 y docs/arquitectura.md §4.
--
-- * Los datos de referencia (regiones, comunas, especies, especialidades,
--   tarifas y parámetros por defecto) van en la migración: también existen en
--   producción. Los datos demo (clínicas) van en seed.sql.
-- * Lectura: authenticated ve los ítems activos; el admin ve todo.
-- * Escritura: solo admin. No hay DELETE: se desactiva (`active = false`).
-- * pricing_config es versionada: solo INSERT, nunca UPDATE.

-- ---------------------------------------------------------------------------
-- Auditoría de cambios del admin (la usan también las fases siguientes)
-- ---------------------------------------------------------------------------
create table public.admin_audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users (id) on delete set null,
  table_name text not null,
  row_pk text not null,
  action text not null check (action in ('INSERT', 'UPDATE')),
  old_data jsonb,
  new_data jsonb,
  at timestamptz not null default now()
);

create index admin_audit_log_actor_idx on public.admin_audit_log (actor_id);
create index admin_audit_log_at_idx on public.admin_audit_log (at desc);

alter table public.admin_audit_log enable row level security;
alter table public.admin_audit_log force row level security;

create policy admin_audit_log_admin_read on public.admin_audit_log
for select to authenticated
using ((select private.is_admin()));

-- Trigger genérico: registra quién cambió qué. SECURITY DEFINER porque los
-- usuarios no pueden escribir en el log directamente.
create function private.log_admin_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.admin_audit_log (actor_id, table_name, row_pk, action, old_data, new_data)
  values (
    (select auth.uid()),
    tg_table_name,
    coalesce(to_jsonb(new) ->> 'id', to_jsonb(new)::text),
    tg_op,
    case when tg_op = 'UPDATE' then to_jsonb(old) end,
    to_jsonb(new)
  );
  return new;
end;
$$;

revoke execute on function private.log_admin_change() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Regiones y comunas (16 regiones, 346 comunas). Región = código CUT.
-- ---------------------------------------------------------------------------
create table public.regions (
  id smallint primary key,
  name text not null unique,
  sort smallint not null unique
);

create table public.communes (
  id integer generated always as identity primary key,
  region_id smallint not null references public.regions (id),
  name text not null,
  unique (region_id, name)
);

create index communes_region_idx on public.communes (region_id);

insert into public.regions (id, name, sort) values
  (15, 'Arica y Parinacota', 1),
  (1, 'Tarapacá', 2),
  (2, 'Antofagasta', 3),
  (3, 'Atacama', 4),
  (4, 'Coquimbo', 5),
  (5, 'Valparaíso', 6),
  (13, 'Metropolitana de Santiago', 7),
  (6, 'Libertador General Bernardo O''Higgins', 8),
  (7, 'Maule', 9),
  (16, 'Ñuble', 10),
  (8, 'Biobío', 11),
  (9, 'La Araucanía', 12),
  (14, 'Los Ríos', 13),
  (10, 'Los Lagos', 14),
  (11, 'Aysén del General Carlos Ibáñez del Campo', 15),
  (12, 'Magallanes y de la Antártica Chilena', 16);

insert into public.communes (region_id, name)
select r, unnest(c) from (values
  (15, array['Arica', 'Camarones', 'Putre', 'General Lagos']),
  (1, array['Iquique', 'Alto Hospicio', 'Pozo Almonte', 'Camiña', 'Colchane',
    'Huara', 'Pica']),
  (2, array['Antofagasta', 'Mejillones', 'Sierra Gorda', 'Taltal', 'Calama',
    'Ollagüe', 'San Pedro de Atacama', 'Tocopilla', 'María Elena']),
  (3, array['Copiapó', 'Caldera', 'Tierra Amarilla', 'Chañaral',
    'Diego de Almagro', 'Vallenar', 'Alto del Carmen', 'Freirina', 'Huasco']),
  (4, array['La Serena', 'Coquimbo', 'Andacollo', 'La Higuera', 'Paiguano',
    'Vicuña', 'Illapel', 'Canela', 'Los Vilos', 'Salamanca', 'Ovalle',
    'Combarbalá', 'Monte Patria', 'Punitaqui', 'Río Hurtado']),
  (5, array['Valparaíso', 'Casablanca', 'Concón', 'Juan Fernández',
    'Puchuncaví', 'Quintero', 'Viña del Mar', 'Isla de Pascua', 'Los Andes',
    'Calle Larga', 'Rinconada', 'San Esteban', 'La Ligua', 'Cabildo', 'Papudo',
    'Petorca', 'Zapallar', 'Quillota', 'La Calera', 'Hijuelas', 'La Cruz',
    'Nogales', 'San Antonio', 'Algarrobo', 'Cartagena', 'El Quisco', 'El Tabo',
    'Santo Domingo', 'San Felipe', 'Catemu', 'Llaillay', 'Panquehue',
    'Putaendo', 'Santa María', 'Quilpué', 'Limache', 'Olmué',
    'Villa Alemana']),
  (13, array['Santiago', 'Cerrillos', 'Cerro Navia', 'Conchalí', 'El Bosque',
    'Estación Central', 'Huechuraba', 'Independencia', 'La Cisterna',
    'La Florida', 'La Granja', 'La Pintana', 'La Reina', 'Las Condes',
    'Lo Barnechea', 'Lo Espejo', 'Lo Prado', 'Macul', 'Maipú', 'Ñuñoa',
    'Pedro Aguirre Cerda', 'Peñalolén', 'Providencia', 'Pudahuel', 'Quilicura',
    'Quinta Normal', 'Recoleta', 'Renca', 'San Joaquín', 'San Miguel',
    'San Ramón', 'Vitacura', 'Puente Alto', 'Pirque', 'San José de Maipo',
    'Colina', 'Lampa', 'Tiltil', 'San Bernardo', 'Buin', 'Calera de Tango',
    'Paine', 'Melipilla', 'Alhué', 'Curacaví', 'María Pinto', 'San Pedro',
    'Talagante', 'El Monte', 'Isla de Maipo', 'Padre Hurtado', 'Peñaflor']),
  (6, array['Rancagua', 'Codegua', 'Coinco', 'Coltauco', 'Doñihue', 'Graneros',
    'Las Cabras', 'Machalí', 'Malloa', 'Mostazal', 'Olivar', 'Peumo',
    'Pichidegua', 'Quinta de Tilcoco', 'Rengo', 'Requínoa', 'San Vicente',
    'Pichilemu', 'La Estrella', 'Litueche', 'Marchigüe', 'Navidad', 'Paredones',
    'San Fernando', 'Chépica', 'Chimbarongo', 'Lolol', 'Nancagua', 'Palmilla',
    'Peralillo', 'Placilla', 'Pumanque', 'Santa Cruz']),
  (7, array['Talca', 'Constitución', 'Curepto', 'Empedrado', 'Maule',
    'Pelarco', 'Pencahue', 'Río Claro', 'San Clemente', 'San Rafael',
    'Cauquenes', 'Chanco', 'Pelluhue', 'Curicó', 'Hualañé', 'Licantén',
    'Molina', 'Rauco', 'Romeral', 'Sagrada Familia', 'Teno', 'Vichuquén',
    'Linares', 'Colbún', 'Longaví', 'Parral', 'Retiro', 'San Javier',
    'Villa Alegre', 'Yerbas Buenas']),
  (16, array['Chillán', 'Bulnes', 'Chillán Viejo', 'El Carmen', 'Pemuco',
    'Pinto', 'Quillón', 'San Ignacio', 'Yungay', 'Quirihue', 'Cobquecura',
    'Coelemu', 'Ninhue', 'Portezuelo', 'Ránquil', 'Treguaco', 'San Carlos',
    'Coihueco', 'Ñiquén', 'San Fabián', 'San Nicolás']),
  (8, array['Concepción', 'Coronel', 'Chiguayante', 'Florida', 'Hualqui',
    'Lota', 'Penco', 'San Pedro de la Paz', 'Santa Juana', 'Talcahuano', 'Tomé',
    'Hualpén', 'Lebu', 'Arauco', 'Cañete', 'Contulmo', 'Curanilahue',
    'Los Álamos', 'Tirúa', 'Los Ángeles', 'Antuco', 'Cabrero', 'Laja',
    'Mulchén', 'Nacimiento', 'Negrete', 'Quilaco', 'Quilleco', 'San Rosendo',
    'Santa Bárbara', 'Tucapel', 'Yumbel', 'Alto Biobío']),
  (9, array['Temuco', 'Carahue', 'Cunco', 'Curarrehue', 'Freire', 'Galvarino',
    'Gorbea', 'Lautaro', 'Loncoche', 'Melipeuco', 'Nueva Imperial',
    'Padre Las Casas', 'Perquenco', 'Pitrufquén', 'Pucón', 'Saavedra',
    'Teodoro Schmidt', 'Toltén', 'Vilcún', 'Villarrica', 'Cholchol', 'Angol',
    'Collipulli', 'Curacautín', 'Ercilla', 'Lonquimay', 'Los Sauces', 'Lumaco',
    'Purén', 'Renaico', 'Traiguén', 'Victoria']),
  (14, array['Valdivia', 'Corral', 'Lanco', 'Los Lagos', 'Máfil', 'Mariquina',
    'Paillaco', 'Panguipulli', 'La Unión', 'Futrono', 'Lago Ranco',
    'Río Bueno']),
  (10, array['Puerto Montt', 'Calbuco', 'Cochamó', 'Fresia', 'Frutillar',
    'Los Muermos', 'Llanquihue', 'Maullín', 'Puerto Varas', 'Castro', 'Ancud',
    'Chonchi', 'Curaco de Vélez', 'Dalcahue', 'Puqueldón', 'Queilén', 'Quellón',
    'Quemchi', 'Quinchao', 'Osorno', 'Puerto Octay', 'Purranque', 'Puyehue',
    'Río Negro', 'San Juan de la Costa', 'San Pablo', 'Chaitén', 'Futaleufú',
    'Hualaihué', 'Palena']),
  (11, array['Coyhaique', 'Lago Verde', 'Aysén', 'Cisnes', 'Guaitecas',
    'Cochrane', 'O''Higgins', 'Tortel', 'Chile Chico', 'Río Ibáñez']),
  (12, array['Punta Arenas', 'Laguna Blanca', 'Río Verde', 'San Gregorio',
    'Cabo de Hornos', 'Antártica', 'Porvenir', 'Primavera', 'Timaukel',
    'Natales', 'Torres del Paine'])
) as t (r, c);

-- ---------------------------------------------------------------------------
-- Especies, razas y especialidades
-- ---------------------------------------------------------------------------
create table public.species (
  id integer generated always as identity primary key,
  slug text not null unique check (slug ~ '^[a-z_]+$'),
  name text not null unique check (char_length(name) between 2 and 60),
  sort smallint not null default 100,
  active boolean not null default true
);

create table public.breeds (
  id integer generated always as identity primary key,
  species_id integer not null references public.species (id),
  name text not null check (char_length(name) between 2 and 60),
  active boolean not null default true,
  unique (species_id, name)
);

create index breeds_species_idx on public.breeds (species_id);

create table public.specialties (
  id integer generated always as identity primary key,
  slug text not null unique check (slug ~ '^[a-z_]+$'),
  name text not null unique check (char_length(name) between 2 and 60),
  sort smallint not null default 100,
  active boolean not null default true
);

-- Qué especialidades aplican a qué especies.
create table public.species_specialties (
  species_id integer not null references public.species (id),
  specialty_id integer not null references public.specialties (id),
  primary key (species_id, specialty_id)
);

create index species_specialties_specialty_idx
  on public.species_specialties (specialty_id);

insert into public.species (slug, name, sort) values
  ('perro', 'Perro', 1),
  ('gato', 'Gato', 2),
  ('conejo', 'Conejo', 3),
  ('huron', 'Hurón', 4),
  ('ave', 'Aves', 5),
  ('reptil', 'Reptiles', 6),
  ('roedor', 'Roedores pequeños', 7),
  ('equino', 'Equinos', 8),
  ('otro_exotico', 'Otros exóticos', 9);

insert into public.breeds (species_id, name)
select s.id, unnest(b) from (values
  ('perro', array['Mestizo', 'Labrador Retriever', 'Golden Retriever',
    'Pastor Alemán', 'Poodle', 'Bulldog Francés', 'Beagle', 'Chihuahua',
    'Schnauzer', 'Border Collie']),
  ('gato', array['Doméstico de pelo corto', 'Doméstico de pelo largo',
    'Siamés', 'Persa', 'Maine Coon', 'Bengalí']),
  ('conejo', array['Mestizo', 'Belier', 'Cabeza de León', 'Rex']),
  ('equino', array['Caballo Chileno', 'Fina Sangre de Carrera',
    'Cuarto de Milla', 'Mestizo'])
) as t (slug, b)
join public.species s on s.slug = t.slug;

insert into public.specialties (slug, name, sort) values
  ('general', 'Medicina general', 1),
  ('urgencias', 'Urgencias', 2),
  ('prevencion', 'Vacunación y prevención', 3),
  ('dermatologia', 'Dermatología', 4),
  ('traumatologia', 'Traumatología y ortopedia', 5),
  ('cardiologia', 'Cardiología', 6),
  ('oftalmologia', 'Oftalmología', 7),
  ('odontologia', 'Odontología', 8),
  ('exoticos', 'Medicina de animales exóticos', 9),
  ('equina', 'Medicina equina', 10),
  ('comportamiento', 'Etología y comportamiento', 11),
  ('nutricion', 'Nutrición', 12);

insert into public.species_specialties (species_id, specialty_id)
select sp.id, es.id
from (values
  -- Especialidades transversales: todas las especies.
  ('general', null::text[]),
  ('urgencias', null),
  ('prevencion', null),
  ('nutricion', null),
  ('dermatologia', array['perro', 'gato', 'conejo', 'huron']),
  ('traumatologia', array['perro', 'gato', 'equino']),
  ('cardiologia', array['perro', 'gato']),
  ('oftalmologia', array['perro', 'gato', 'equino']),
  ('odontologia', array['perro', 'gato', 'conejo', 'huron', 'equino']),
  ('comportamiento', array['perro', 'gato']),
  ('exoticos', array['conejo', 'huron', 'ave', 'reptil', 'roedor', 'otro_exotico']),
  ('equina', array['equino'])
) as m (specialty, species_slugs)
join public.specialties es on es.slug = m.specialty
join public.species sp on m.species_slugs is null or sp.slug = any (m.species_slugs);

-- ---------------------------------------------------------------------------
-- Tarifas base (CLP). species_id null = vale para todas las especies.
-- ---------------------------------------------------------------------------
create table public.tariffs (
  id integer generated always as identity primary key,
  specialty_id integer not null references public.specialties (id),
  species_id integer references public.species (id),
  base_price integer not null check (base_price > 0),
  active boolean not null default true,
  unique nulls not distinct (specialty_id, species_id)
);

create index tariffs_species_idx on public.tariffs (species_id);

insert into public.tariffs (specialty_id, base_price)
select s.id, t.price from (values
  ('general', 25000), ('urgencias', 35000), ('prevencion', 20000),
  ('dermatologia', 35000), ('traumatologia', 40000), ('cardiologia', 45000),
  ('oftalmologia', 40000), ('odontologia', 40000), ('exoticos', 35000),
  ('equina', 60000), ('comportamiento', 30000), ('nutricion', 25000)
) as t (slug, price)
join public.specialties s on s.slug = t.slug;

-- Tarifa vigente: la específica de la especie si existe; si no, la general.
create function public.base_tariff(p_species_id integer, p_specialty_id integer)
returns integer
language sql
stable
security invoker
set search_path = ''
as $$
  select t.base_price from public.tariffs t
  where t.specialty_id = p_specialty_id
    and t.active
    and (t.species_id = p_species_id or t.species_id is null)
  order by t.species_id nulls last
  limit 1;
$$;

-- ---------------------------------------------------------------------------
-- Parámetros económicos versionados (solo INSERT)
-- ---------------------------------------------------------------------------
create table public.pricing_config (
  id integer generated always as identity primary key,
  commission_pct numeric(5, 2) not null check (commission_pct between 0 and 100),
  foundation_pct numeric(5, 2) not null check (foundation_pct between 0 and 100),
  urgent_pct numeric(5, 2) not null check (urgent_pct between 0 and 300),
  per_km integer not null check (per_km >= 0),
  free_km integer not null check (free_km >= 0),
  cancel_fee integer not null check (cancel_fee >= 0),
  effective_from timestamptz not null default now(),
  created_by uuid references auth.users (id) on delete set null
    default auth.uid(),
  created_at timestamptz not null default now()
);

create index pricing_config_effective_idx on public.pricing_config (effective_from desc);
create index pricing_config_created_by_idx on public.pricing_config (created_by);

insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee, effective_from)
values (15, 20, 30, 500, 5, 5000, '2026-11-16');

create function public.current_pricing_config()
returns setof public.pricing_config
language sql
stable
security invoker
set search_path = ''
as $$
  select * from public.pricing_config
  where effective_from <= now()
  order by effective_from desc, id desc
  limit 1;
$$;

-- ---------------------------------------------------------------------------
-- Clínicas 24 h (alternativa cuando no hay vet para una urgencia)
-- ---------------------------------------------------------------------------
create table public.emergency_clinics (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 80),
  commune_id integer not null references public.communes (id),
  address text not null check (char_length(address) between 3 and 120),
  phone text not null check (phone ~ '^\+?[0-9 ]{8,15}$'),
  open_24h boolean not null default true,
  active boolean not null default true
);

create index emergency_clinics_commune_idx on public.emergency_clinics (commune_id);

-- ---------------------------------------------------------------------------
-- Comuna del dueño (SPEC HU1.1) y registro con comuna
-- ---------------------------------------------------------------------------
alter table public.owner_profiles
  add column commune_id integer references public.communes (id);

create index owner_profiles_commune_idx on public.owner_profiles (commune_id);

drop function public.complete_registration(text, text, text, text, text);

create function public.complete_registration(
  p_role text,
  p_display_name text,
  p_phone text,
  p_terms_version text,
  p_privacy_version text,
  p_commune_id integer default null
)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;
  if p_role not in ('owner', 'vet') then
    raise exception 'Rol no permitido: %', p_role using errcode = '22023';
  end if;
  if p_role = 'owner' and p_commune_id is null then
    raise exception 'La comuna es obligatoria' using errcode = '22023';
  end if;
  if p_terms_version is distinct from public.current_legal_version('terms') then
    raise exception 'Versión de términos no vigente' using errcode = '22023';
  end if;
  if p_privacy_version is distinct from public.current_legal_version('privacy') then
    raise exception 'Versión de la política de privacidad no vigente'
      using errcode = '22023';
  end if;

  insert into public.user_roles (user_id, role) values (v_uid, p_role);
  insert into public.terms_acceptances (user_id, version)
    values (v_uid, p_terms_version);
  insert into public.privacy_notice_views (user_id, version)
    values (v_uid, p_privacy_version)
    on conflict (user_id, version) do nothing;

  if p_role = 'owner' then
    insert into public.owner_profiles (user_id, display_name, phone, commune_id)
      values (v_uid, trim(p_display_name), nullif(trim(p_phone), ''), p_commune_id);
  else
    insert into public.vet_profiles (user_id, display_name)
      values (v_uid, trim(p_display_name));
  end if;

  return p_role;
end;
$$;

-- ---------------------------------------------------------------------------
-- RLS, triggers de auditoría y privilegios
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  -- Catálogos con columna `active`: lectura de activos o admin; escritura admin.
  foreach t in array array['species', 'breeds', 'specialties', 'tariffs', 'emergency_clinics'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (active or (select private.is_admin()))', t || '_read', t);
    execute format(
      'create policy %I on public.%I for insert to authenticated
         with check ((select private.is_admin()))', t || '_admin_insert', t);
    execute format(
      'create policy %I on public.%I for update to authenticated
         using ((select private.is_admin())) with check ((select private.is_admin()))',
      t || '_admin_update', t);
    execute format(
      'create trigger %I after insert or update on public.%I
         for each row execute function private.log_admin_change()', t || '_audit', t);
  end loop;

  -- Catálogos fijos (sin `active`): lectura para todos los autenticados.
  foreach t in array array['regions', 'communes', 'species_specialties'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (true)',
      t || '_read', t);
  end loop;
end;
$$;

-- species_specialties: el admin puede agregar relaciones (no se borran).
create policy species_specialties_admin_insert on public.species_specialties
for insert to authenticated
with check ((select private.is_admin()));

create trigger species_specialties_audit after insert on public.species_specialties
for each row execute function private.log_admin_change();

-- pricing_config: lectura para autenticados, inserción solo admin, sin UPDATE.
alter table public.pricing_config enable row level security;
alter table public.pricing_config force row level security;

create policy pricing_config_read on public.pricing_config
for select to authenticated using (true);

create policy pricing_config_admin_insert on public.pricing_config
for insert to authenticated
with check ((select private.is_admin()) and created_by = (select auth.uid()));

create trigger pricing_config_audit after insert on public.pricing_config
for each row execute function private.log_admin_change();

-- Privilegios mínimos.
revoke all on public.admin_audit_log, public.regions, public.communes,
  public.species, public.breeds, public.specialties, public.species_specialties,
  public.tariffs, public.pricing_config, public.emergency_clinics
  from anon, authenticated;

grant select on public.admin_audit_log to authenticated;
grant select on public.regions, public.communes, public.species_specialties
  to authenticated;
grant insert on public.species_specialties to authenticated;
grant select, insert on public.species, public.breeds, public.specialties,
  public.tariffs, public.emergency_clinics, public.pricing_config
  to authenticated;
grant update (name, sort, active) on public.species, public.specialties to authenticated;
grant update (name, active) on public.breeds to authenticated;
grant update (base_price, active) on public.tariffs to authenticated;
grant update (name, commune_id, address, phone, open_24h, active)
  on public.emergency_clinics to authenticated;

grant update (commune_id) on public.owner_profiles to authenticated;

revoke execute on function public.base_tariff(integer, integer) from public, anon;
grant execute on function public.base_tariff(integer, integer) to authenticated;
revoke execute on function public.current_pricing_config() from public, anon;
grant execute on function public.current_pricing_config() to authenticated;
revoke execute on function
  public.complete_registration(text, text, text, text, text, integer) from public, anon;
grant execute on function
  public.complete_registration(text, text, text, text, text, integer) to authenticated;
