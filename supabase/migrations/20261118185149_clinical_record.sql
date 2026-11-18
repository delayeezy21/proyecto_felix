-- Fase 7: ficha clínica con acceso controlado (SPEC F3, docs/arquitectura.md §7).
--
-- Principios:
-- * Solo inserción: clinical_entries, clinical_vaccines, entry_attachments y
--   record_access_log no tienen UPDATE ni DELETE para nadie de la API (ni el
--   autor). Una corrección es una entrada nueva con `supersedes_id`.
-- * El dueño lee todo lo de sus mascotas (SELECT directo o get_pet_record) y
--   su log. El vet NO tiene SELECT directo: lee solo con get_pet_record, que
--   registra cada lectura en record_access_log.
-- * Acceso del vet = record_access_grants vigente:
--     - source 'visit': nace al aceptar la visita (expires_at null mientras
--       está activa); al completarla vence 30 días después; si la visita se
--       cancela, vence al cerrarse.
--     - source 'owner': la otorga el dueño, con vencimiento obligatorio
--       (máx. 365 días) y revocable.
-- * El vet escribe solo en visitas propias (desde "llegó") con la ventana de
--   esa visita vigente. Con una autorización del dueño solo lee.
-- * Otro vet, la fundación y el admin no ven nada clínico; el admin solo ve
--   conteos (admin_record_stats).
-- * Adjuntos en el bucket privado `clinical-attachments`
--   (pets/{pet}/{entry}/{archivo}). Nadie de la API lee storage.objects de
--   este bucket: la descarga es por URL firmada de 60 s que emite la Edge
--   Function `clinical-attachment-url` tras authorize_attachment (verifica el
--   acceso vigente y registra la descarga).
--
-- O-6 (QA fase 6): una visita cerrada por el sistema queda marcada con
--   visits.closed_by_system = true (se conserva el estado: `completed` para
--   "en curso" vencida, `cancelled_vet`/`expired` para las demás). Decisión:
--   una `completed` cerrada por el sistema SÍ abre la ventana de 30 días y
--   el vet puede registrar entradas en ella, porque la atención empezó
--   (in_progress) y documentarla es de interés clínico del animal; el dueño
--   la ve marcada como "cerrada automáticamente". Las cancelaciones (de
--   cualquiera, incluido el sistema) cierran el acceso al instante.

-- ---------------------------------------------------------------------------
-- Parámetros
-- ---------------------------------------------------------------------------
create function private.record_rules()
returns table (post_visit interval, max_owner_grant interval, max_attachments integer)
language sql
immutable
set search_path = ''
as $$
  select interval '30 days', interval '365 days', 5;
$$;
revoke execute on function private.record_rules() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- O-6: cierre por el sistema
-- ---------------------------------------------------------------------------
alter table public.visits add column closed_by_system boolean not null default false;

-- Igual que la versión de 20261118124201, más closed_by_system como dato del
-- ciclo de vida (solo cambia dentro de una transición).
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
    if new.closed_by_system then
      raise exception 'Una visita nace abierta' using errcode = '22023';
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

-- Actor nulo = sistema (expire_visits): la visita queda marcada.
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
  v_closes boolean := p_to in ('completed', 'rejected', 'expired', 'no_vet_found',
                               'cancelled_owner', 'cancelled_vet');
begin
  select status into v_from from public.visits where id = p_visit;
  perform set_config('felix.visit_transition', 'on', true);
  update public.visits
  set status = p_to,
      accepted_at = case when p_to = 'accepted' then now() else accepted_at end,
      started_at = case when p_to = 'in_progress' then now() else started_at end,
      completed_at = case when p_to = 'completed' then now() else completed_at end,
      closed_at = case when v_closes then now() else closed_at end,
      closed_by_system = case when v_closes then p_actor is null else closed_by_system end,
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

-- Histórico: las "en curso" cerradas por el cron antes de esta migración.
alter table public.visits disable trigger visits_guard;
update public.visits v set closed_by_system = true
where exists (select 1 from public.visit_events e
              where e.visit_id = v.id and e.to_status = v.status and e.actor_id is null
                and e.to_status in ('completed', 'rejected', 'expired', 'no_vet_found',
                                    'cancelled_owner', 'cancelled_vet'));
alter table public.visits enable trigger visits_guard;

-- ---------------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------------
create table public.record_access_grants (
  id uuid primary key default gen_random_uuid(),
  pet_id uuid not null references public.pets (id) on delete cascade,
  vet_id uuid not null references public.vet_profiles (user_id) on delete cascade,
  source text not null check (source in ('visit', 'owner')),
  visit_id uuid references public.visits (id) on delete cascade,
  granted_by uuid references auth.users (id) on delete set null,
  starts_at timestamptz not null default now(),
  -- null = mientras la visita esté activa (solo source 'visit').
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  constraint record_access_grants_source_fields check (
    (source = 'visit' and visit_id is not null)
    or (source = 'owner' and visit_id is null and expires_at is not null))
);
create unique index record_access_grants_visit_uidx on public.record_access_grants (visit_id)
  where source = 'visit';
create index record_access_grants_pet_vet_idx on public.record_access_grants (pet_id, vet_id);
create index record_access_grants_vet_idx on public.record_access_grants (vet_id);
create index record_access_grants_granted_by_idx on public.record_access_grants (granted_by);

create table public.clinical_entries (
  id uuid primary key default gen_random_uuid(),
  -- Null solo en entradas desvinculadas por el job de borrado (fase 11).
  pet_id uuid references public.pets (id) on delete set null,
  visit_id uuid references public.visits (id) on delete set null,
  author_id uuid references auth.users (id) on delete set null,
  author_role text not null check (author_role in ('vet', 'owner')),
  kind text not null check (kind in ('consultation', 'vaccine', 'diagnosis', 'note')),
  specialty_id integer references public.specialties (id),
  species_id integer not null references public.species (id),
  title text not null check (char_length(trim(title)) between 1 and 120),
  body text check (body is null or char_length(body) <= 4000),
  supersedes_id uuid references public.clinical_entries (id) on delete set null,
  created_at timestamptz not null default now(),
  retain_until timestamptz,
  constraint clinical_entries_owner_kind check (author_role = 'vet' or kind = 'note'),
  constraint clinical_entries_detached check (pet_id is not null or retain_until is not null)
);
-- Cada versión se corrige una sola vez: el historial es una cadena lineal.
create unique index clinical_entries_supersedes_uidx on public.clinical_entries (supersedes_id);
create index clinical_entries_pet_idx on public.clinical_entries (pet_id, created_at desc);
create index clinical_entries_visit_idx on public.clinical_entries (visit_id);
create index clinical_entries_author_idx on public.clinical_entries (author_id);
create index clinical_entries_specialty_idx on public.clinical_entries (specialty_id);
create index clinical_entries_species_idx on public.clinical_entries (species_id);

create table public.clinical_vaccines (
  entry_id uuid primary key references public.clinical_entries (id) on delete cascade,
  pet_id uuid references public.pets (id) on delete set null,
  vaccine_name text not null check (char_length(trim(vaccine_name)) between 2 and 80),
  lot text check (lot is null or char_length(lot) <= 40),
  applied_on date not null,
  next_due date,
  created_at timestamptz not null default now(),
  constraint clinical_vaccines_dates check (next_due is null or next_due > applied_on)
);
create index clinical_vaccines_pet_idx on public.clinical_vaccines (pet_id, applied_on desc);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('clinical-attachments', 'clinical-attachments', false, 5242880,
  array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

create table public.entry_attachments (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.clinical_entries (id) on delete cascade,
  pet_id uuid references public.pets (id) on delete set null,
  storage_path text not null unique,
  file_name text not null check (char_length(file_name) between 1 and 120),
  mime text not null check (mime in ('application/pdf', 'image/jpeg', 'image/png')),
  size_bytes integer not null check (size_bytes between 1 and 5242880),
  uploaded_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);
create index entry_attachments_entry_idx on public.entry_attachments (entry_id);
create index entry_attachments_pet_idx on public.entry_attachments (pet_id);
create index entry_attachments_uploaded_by_idx on public.entry_attachments (uploaded_by);

-- Sin datos clínicos: quién, cuándo, qué acción y por qué vía.
create table public.record_access_log (
  id bigint generated always as identity primary key,
  pet_id uuid not null references public.pets (id) on delete cascade,
  entry_id uuid references public.clinical_entries (id) on delete set null,
  actor_id uuid references auth.users (id) on delete set null,
  actor_role text not null check (actor_role in ('owner', 'vet', 'system')),
  action text not null check (action in ('view', 'download', 'create', 'correct', 'grant',
                                         'revoke', 'export')),
  via text not null check (via in ('owner', 'visit', 'owner_grant')),
  visit_id uuid references public.visits (id) on delete set null,
  grant_id uuid references public.record_access_grants (id) on delete set null,
  at timestamptz not null default now()
);
create index record_access_log_pet_idx on public.record_access_log (pet_id, at desc);
create index record_access_log_entry_idx on public.record_access_log (entry_id);
create index record_access_log_actor_idx on public.record_access_log (actor_id);
create index record_access_log_visit_idx on public.record_access_log (visit_id);
create index record_access_log_grant_idx on public.record_access_log (grant_id);
create index record_access_log_at_idx on public.record_access_log (at);

-- ---------------------------------------------------------------------------
-- Helpers de acceso (SECURITY DEFINER, solo en private)
-- ---------------------------------------------------------------------------
-- Autorización vigente del vet actual sobre la mascota (prioriza la de una
-- visita). Sin EXECUTE para la app: la usan get_pet_record y authorize_attachment.
create function private.vet_record_grant(p_pet uuid)
returns public.record_access_grants
language sql
stable
security definer
set search_path = ''
as $$
  select g.* from public.record_access_grants g
  join public.vet_profiles v on v.user_id = g.vet_id and v.status = 'approved'
  join public.user_roles r on r.user_id = g.vet_id and r.role = 'vet'
  left join public.visits vi on vi.id = g.visit_id
  where g.pet_id = p_pet
    and g.vet_id = (select auth.uid())
    and g.revoked_at is null
    and g.starts_at <= now()
    -- Sin vencimiento = visita activa: vale solo dentro de su ventana
    -- (private.visit_active_until), aunque el cron aún no la cierre.
    and (g.expires_at > now()
         or (g.expires_at is null and vi.id is not null
             and now() < coalesce(private.visit_active_until(vi), 'infinity')))
  order by (g.source = 'visit') desc, g.expires_at desc nulls first
  limit 1;
$$;
revoke execute on function private.vet_record_grant(uuid) from public, anon, authenticated;

-- ¿Puede el vet actual escribir en la ficha de p_pet dentro de la visita
-- p_visit? Visita propia, desde "llegó", con su ventana vigente.
create function private.vet_can_write(p_pet uuid, p_visit uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.record_access_grants g
    join public.visits vi on vi.id = g.visit_id
    join public.vet_profiles v on v.user_id = g.vet_id and v.status = 'approved'
    join public.user_roles r on r.user_id = g.vet_id and r.role = 'vet'
    where g.source = 'visit'
      and g.visit_id = p_visit
      and g.pet_id = p_pet
      and g.vet_id = (select auth.uid())
      and vi.vet_id = g.vet_id and vi.pet_id = p_pet
      and vi.status in ('arrived', 'in_progress', 'completed')
      and g.revoked_at is null
      and g.starts_at <= now()
      and (g.expires_at > now()
           or (g.expires_at is null
               and now() < coalesce(private.visit_active_until(vi), 'infinity'))));
$$;
revoke execute on function private.vet_can_write(uuid, uuid) from public, anon;
grant execute on function private.vet_can_write(uuid, uuid) to authenticated;

-- ¿El usuario actual puede agregar vacuna o adjuntos a esta entrada? Debe ser
-- su autor y conservar el derecho a escribir (dueño de la mascota, o vet con
-- la ventana de la visita vigente).
create function private.entry_writable(p_entry uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.clinical_entries e
    where e.id = p_entry
      and e.author_id = (select auth.uid())
      and e.pet_id is not null
      and ((e.author_role = 'owner'
            and exists (select 1 from public.pets p
                        where p.id = e.pet_id and p.owner_id = (select auth.uid())))
           or (e.author_role = 'vet' and private.vet_can_write(e.pet_id, e.visit_id))));
$$;
revoke execute on function private.entry_writable(uuid) from public, anon;
grant execute on function private.entry_writable(uuid) to authenticated;

-- Política de subida a Storage: pets/{pet}/{entry}/{archivo} con la entrada
-- de esa mascota y escribible por quien sube.
create function private.can_upload_clinical(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_parts text[] := string_to_array(p_name, '/');
  v_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
begin
  if array_length(v_parts, 1) <> 4 or v_parts[1] <> 'pets'
     or v_parts[2] !~ v_uuid or v_parts[3] !~ v_uuid
     or v_parts[4] !~ '^[A-Za-z0-9._-]{1,100}\.(pdf|jpg|jpeg|png)$' then
    return false;
  end if;
  return exists (select 1 from public.clinical_entries e
                 where e.id = v_parts[3]::uuid and e.pet_id = v_parts[2]::uuid)
         and private.entry_writable(v_parts[3]::uuid);
end;
$$;
revoke execute on function private.can_upload_clinical(text) from public, anon;
grant execute on function private.can_upload_clinical(text) to authenticated;

-- Registro interno en el log (sin EXECUTE para la app).
create function private.log_record_access(
  p_pet uuid, p_action text, p_via text, p_entry uuid default null,
  p_visit uuid default null, p_grant uuid default null)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  insert into public.record_access_log
    (pet_id, entry_id, actor_id, actor_role, action, via, visit_id, grant_id)
  values (p_pet, p_entry, (select auth.uid()),
          case when (select auth.uid()) is null then 'system'
               when p_via = 'owner' then 'owner' else 'vet' end,
          p_action, p_via, p_visit, p_grant);
$$;
revoke execute on function private.log_record_access(uuid, text, text, uuid, uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Guardianes (triggers; sin EXECUTE para nadie)
-- ---------------------------------------------------------------------------
-- Solo inserción, incluso para el autor. Fuera de la API solo se permite que
-- una FK pase a null (ON DELETE SET NULL; p. ej., al borrar una cuenta el
-- autor queda seudonimizado). El job de borrado (fase 11) corre fuera de la
-- API con felix.record_maintenance = 'on'. TG_ARGV = columnas anulables.
create function private.forbid_record_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  k text;
  v_ok boolean := tg_op = 'UPDATE' and current_user not in ('anon', 'authenticated');
begin
  if current_user not in ('anon', 'authenticated', 'service_role')
     and coalesce(current_setting('felix.record_maintenance', true), '') = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if v_ok then
    v_ok := (to_jsonb(new) - tg_argv) = (to_jsonb(old) - tg_argv);
    foreach k in array tg_argv loop
      v_ok := v_ok and (to_jsonb(new) -> k = to_jsonb(old) -> k
                        or jsonb_typeof(to_jsonb(new) -> k) = 'null');
    end loop;
    if v_ok then
      return new;
    end if;
  end if;
  raise exception 'La ficha clínica no se modifica ni se borra: registra una corrección'
    using errcode = '42501';
end;
$$;
revoke execute on function private.forbid_record_change() from public, anon, authenticated;

create function private.guard_clinical_entry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev public.clinical_entries;
begin
  -- Primero la autorización: sin ella, el mismo 42501 genérico (no revela si
  -- existen la mascota o la entrada que se quiere corregir).
  if (select auth.uid()) is not null
     and not (new.author_id = (select auth.uid())
              and ((new.author_role = 'owner'
                    and exists (select 1 from public.pets p
                                where p.id = new.pet_id and p.owner_id = (select auth.uid())))
                   or (new.author_role = 'vet'
                       and private.vet_can_write(new.pet_id, new.visit_id)))) then
    raise exception 'No tienes permiso para esta acción' using errcode = '42501';
  end if;
  new.created_at := now();
  new.retain_until := null;
  select p.species_id into new.species_id from public.pets p where p.id = new.pet_id;
  if new.species_id is null then
    raise exception 'La mascota no existe' using errcode = '22023';
  end if;
  if new.specialty_id is not null
     and not exists (select 1 from public.specialties s where s.id = new.specialty_id and s.active) then
    raise exception 'Especialidad no válida' using errcode = '22023';
  end if;
  if new.supersedes_id is not null then
    select * into v_prev from public.clinical_entries where id = new.supersedes_id;
    if not found or v_prev.pet_id is distinct from new.pet_id
       or v_prev.author_id is distinct from new.author_id
       or v_prev.kind <> new.kind then
      raise exception 'Solo puedes corregir tus propias entradas, del mismo tipo y mascota'
        using errcode = '22023';
    end if;
    if exists (select 1 from public.clinical_entries c where c.supersedes_id = v_prev.id) then
      raise exception 'Esa entrada ya fue corregida: corrige la versión vigente'
        using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function private.guard_clinical_entry() from public, anon, authenticated;

create function private.log_clinical_entry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.pet_id is not null then
    perform private.log_record_access(new.pet_id,
      case when new.supersedes_id is null then 'create' else 'correct' end,
      case new.author_role when 'owner' then 'owner' else 'visit' end,
      new.id, new.visit_id, null);
  end if;
  return null;
end;
$$;
revoke execute on function private.log_clinical_entry() from public, anon, authenticated;

create function private.guard_clinical_vaccine()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.clinical_entries;
begin
  if (select auth.uid()) is not null and not private.entry_writable(new.entry_id) then
    raise exception 'No tienes permiso para esta acción' using errcode = '42501';
  end if;
  select * into e from public.clinical_entries where id = new.entry_id;
  if not found or e.kind <> 'vaccine' then
    raise exception 'La vacuna debe ir en una entrada de tipo vacuna' using errcode = '22023';
  end if;
  if new.applied_on > (now() at time zone 'America/Santiago')::date then
    raise exception 'La fecha de aplicación no puede ser futura' using errcode = '22023';
  end if;
  new.pet_id := e.pet_id;
  new.created_at := now();
  return new;
end;
$$;
revoke execute on function private.guard_clinical_vaccine() from public, anon, authenticated;

create function private.guard_entry_attachment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.clinical_entries;
begin
  if (select auth.uid()) is not null and not private.entry_writable(new.entry_id) then
    raise exception 'No tienes permiso para esta acción' using errcode = '42501';
  end if;
  select * into e from public.clinical_entries where id = new.entry_id;
  if not found or new.storage_path not like
       'pets/' || e.pet_id::text || '/' || e.id::text || '/%' then
    raise exception 'Ruta de adjunto no válida' using errcode = '22023';
  end if;
  if not exists (select 1 from storage.objects o
                 where o.bucket_id = 'clinical-attachments' and o.name = new.storage_path) then
    raise exception 'Primero sube el archivo' using errcode = '22023';
  end if;
  if (select count(*) from public.entry_attachments a where a.entry_id = e.id)
     >= (select r.max_attachments from private.record_rules() r) then
    raise exception 'Máximo 5 adjuntos por entrada' using errcode = '22023';
  end if;
  new.pet_id := e.pet_id;
  new.uploaded_by := (select auth.uid());
  new.created_at := now();
  return new;
end;
$$;
revoke execute on function private.guard_entry_attachment() from public, anon, authenticated;

-- Autorizaciones: el dueño crea (source 'owner') y solo revoca. Las de
-- visita las mantienen los triggers de la visita (felix.record_internal).
create function private.guard_record_grant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_internal boolean := coalesce(current_setting('felix.record_internal', true), '') = 'on';
begin
  if v_internal then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.source <> 'owner' then
      raise exception 'Las autorizaciones de visita las crea el sistema' using errcode = '42501';
    end if;
    -- Antes que cualquier otra validación: no revelar nada de mascotas ajenas.
    if not exists (select 1 from public.pets p
                   where p.id = new.pet_id and p.owner_id = (select auth.uid())) then
      raise exception 'No tienes permiso para esta acción' using errcode = '42501';
    end if;
    if not exists (select 1 from public.vet_profiles v
                   join public.user_roles r on r.user_id = v.user_id and r.role = 'vet'
                   where v.user_id = new.vet_id and v.status = 'approved') then
      raise exception 'El veterinario no está habilitado' using errcode = '22023';
    end if;
    if new.expires_at <= now() + interval '1 hour'
       or new.expires_at > now() + (select r.max_owner_grant from private.record_rules() r) then
      raise exception 'El vencimiento debe estar entre 1 hora y 365 días' using errcode = '22023';
    end if;
    if exists (select 1 from public.record_access_grants g
               where g.pet_id = new.pet_id and g.vet_id = new.vet_id and g.source = 'owner'
                 and g.revoked_at is null and g.expires_at > now()) then
      raise exception 'Ese veterinario ya tiene una autorización vigente' using errcode = '22023';
    end if;
    new.granted_by := (select auth.uid());
    new.starts_at := now();
    new.revoked_at := null;
    new.created_at := now();
    return new;
  end if;
  -- UPDATE (solo revoked_at por grants de columna): una vez y con la hora del servidor.
  if old.revoked_at is not null then
    raise exception 'La autorización ya fue revocada' using errcode = '22023';
  end if;
  if new.revoked_at is null then
    raise exception 'Solo se puede revocar' using errcode = '22023';
  end if;
  new.revoked_at := now();
  return new;
end;
$$;
revoke execute on function private.guard_record_grant() from public, anon, authenticated;

create function private.log_record_grant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.source = 'owner' and tg_op = 'INSERT' then
    perform private.log_record_access(new.pet_id, 'grant', 'owner', null, null, new.id);
  elsif new.source = 'owner' and old.revoked_at is null and new.revoked_at is not null then
    perform private.log_record_access(new.pet_id, 'revoke', 'owner', null, null, new.id);
  end if;
  return null;
end;
$$;
revoke execute on function private.log_record_grant() from public, anon, authenticated;

-- Ciclo de vida del acceso por visita.
create function private.sync_visit_grant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status is not distinct from old.status then
    return null;
  end if;
  perform set_config('felix.record_internal', 'on', true);
  if new.status = 'accepted' and new.vet_id is not null and new.pet_id is not null then
    insert into public.record_access_grants (pet_id, vet_id, source, visit_id, starts_at)
    values (new.pet_id, new.vet_id, 'visit', new.id, coalesce(new.accepted_at, now()))
    on conflict (visit_id) where source = 'visit' do nothing;
  elsif new.status = 'completed' then
    update public.record_access_grants
    set expires_at = coalesce(new.completed_at, now())
                     + (select r.post_visit from private.record_rules() r)
    where visit_id = new.id and source = 'visit';
  elsif new.status in ('cancelled_owner', 'cancelled_vet', 'rejected', 'expired',
                       'no_vet_found') then
    update public.record_access_grants
    set expires_at = least(coalesce(expires_at, now()), now())
    where visit_id = new.id and source = 'visit';
  end if;
  perform set_config('felix.record_internal', 'off', true);
  return null;
end;
$$;
revoke execute on function private.sync_visit_grant() from public, anon, authenticated;

create trigger visits_record_grant after update of status on public.visits
for each row execute function private.sync_visit_grant();

create trigger clinical_entries_guard before insert on public.clinical_entries
for each row execute function private.guard_clinical_entry();
create trigger clinical_entries_log after insert on public.clinical_entries
for each row execute function private.log_clinical_entry();
create trigger clinical_vaccines_guard before insert on public.clinical_vaccines
for each row execute function private.guard_clinical_vaccine();
create trigger entry_attachments_guard before insert on public.entry_attachments
for each row execute function private.guard_entry_attachment();
create trigger record_access_grants_guard before insert or update on public.record_access_grants
for each row execute function private.guard_record_grant();
create trigger record_access_grants_log after insert or update on public.record_access_grants
for each row execute function private.log_record_grant();

create trigger clinical_entries_immutable before update or delete on public.clinical_entries
for each row execute function private.forbid_record_change('visit_id', 'author_id', 'supersedes_id');
create trigger clinical_vaccines_immutable before update or delete on public.clinical_vaccines
for each row execute function private.forbid_record_change('pet_id');
create trigger entry_attachments_immutable before update or delete on public.entry_attachments
for each row execute function private.forbid_record_change('pet_id', 'uploaded_by');
create trigger record_access_log_immutable before update or delete on public.record_access_log
for each row execute function private.forbid_record_change('entry_id', 'actor_id', 'visit_id', 'grant_id');

-- Acceso de visitas ya aceptadas o completadas hace menos de 30 días.
select set_config('felix.record_internal', 'on', true);
insert into public.record_access_grants (pet_id, vet_id, source, visit_id, starts_at, expires_at)
select v.pet_id, v.vet_id, 'visit', v.id, coalesce(v.accepted_at, v.created_at),
       case when v.status = 'completed'
            then coalesce(v.completed_at, v.closed_at, now()) + interval '30 days' end
from public.visits v
where v.pet_id is not null and v.vet_id is not null
  and (v.status in ('accepted', 'en_route', 'arrived', 'in_progress')
       or (v.status = 'completed'
           and coalesce(v.completed_at, v.closed_at, now()) > now() - interval '30 days'));
select set_config('felix.record_internal', 'off', true);

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.record_access_grants enable row level security;
alter table public.record_access_grants force row level security;
alter table public.clinical_entries enable row level security;
alter table public.clinical_entries force row level security;
alter table public.clinical_vaccines enable row level security;
alter table public.clinical_vaccines force row level security;
alter table public.entry_attachments enable row level security;
alter table public.entry_attachments force row level security;
alter table public.record_access_log enable row level security;
alter table public.record_access_log force row level security;

-- Lectura directa: solo el dueño (el vet lee vía get_pet_record).
create policy clinical_entries_select_owner on public.clinical_entries
for select to authenticated
using (exists (select 1 from public.pets p
               where p.id = pet_id and p.owner_id = (select auth.uid())));
create policy clinical_vaccines_select_owner on public.clinical_vaccines
for select to authenticated
using (exists (select 1 from public.pets p
               where p.id = pet_id and p.owner_id = (select auth.uid())));
create policy entry_attachments_select_owner on public.entry_attachments
for select to authenticated
using (exists (select 1 from public.pets p
               where p.id = pet_id and p.owner_id = (select auth.uid())));
create policy record_access_log_select_owner on public.record_access_log
for select to authenticated
using (exists (select 1 from public.pets p
               where p.id = pet_id and p.owner_id = (select auth.uid())));
-- Solo el dueño ve las autorizaciones de sus mascotas. El vet no las lee
-- (minimización): su acceso le llega en get_pet_record y en my_visits.
create policy record_access_grants_select on public.record_access_grants
for select to authenticated
using (exists (select 1 from public.pets p
               where p.id = pet_id and p.owner_id = (select auth.uid())));

-- Escritura (una sola política permisiva): el dueño, notas sin visita; el
-- vet, en su visita y con la ventana vigente.
create policy clinical_entries_insert on public.clinical_entries
for insert to authenticated
with check (
  author_id = (select auth.uid())
  and ((author_role = 'owner' and kind = 'note' and visit_id is null
        and (select private.current_app_role()) = 'owner'
        and exists (select 1 from public.pets p
                    where p.id = pet_id and p.owner_id = (select auth.uid())))
       or (author_role = 'vet' and visit_id is not null
           and (select private.vet_can_write(pet_id, visit_id)))));

create policy clinical_vaccines_insert on public.clinical_vaccines
for insert to authenticated
with check ((select private.entry_writable(entry_id)));
create policy entry_attachments_insert on public.entry_attachments
for insert to authenticated
with check ((select private.entry_writable(entry_id)));

create policy record_access_grants_insert_owner on public.record_access_grants
for insert to authenticated
with check (
  source = 'owner' and visit_id is null and expires_at is not null
  and (select private.current_app_role()) = 'owner'
  and exists (select 1 from public.pets p
              where p.id = pet_id and p.owner_id = (select auth.uid())));
create policy record_access_grants_revoke_owner on public.record_access_grants
for update to authenticated
using (source = 'owner'
       and exists (select 1 from public.pets p
                   where p.id = pet_id and p.owner_id = (select auth.uid())))
with check (source = 'owner'
            and exists (select 1 from public.pets p
                        where p.id = pet_id and p.owner_id = (select auth.uid())));

-- Storage: solo subida (con entrada escribible). Sin lectura, actualización
-- ni borrado desde la API: la descarga es por URL firmada de 60 s.
create policy clinical_attachments_storage_insert on storage.objects
for insert to authenticated
with check (bucket_id = 'clinical-attachments'
            and (select private.can_upload_clinical(name)));

-- ---------------------------------------------------------------------------
-- Privilegios
-- ---------------------------------------------------------------------------
revoke all on public.record_access_grants, public.clinical_entries, public.clinical_vaccines,
  public.entry_attachments, public.record_access_log from anon, authenticated;
grant select on public.record_access_grants, public.clinical_entries, public.clinical_vaccines,
  public.entry_attachments, public.record_access_log to authenticated;
grant insert (id, pet_id, visit_id, author_id, author_role, kind, specialty_id, title, body,
  supersedes_id) on public.clinical_entries to authenticated;
grant insert (entry_id, vaccine_name, lot, applied_on, next_due)
  on public.clinical_vaccines to authenticated;
grant insert (id, entry_id, storage_path, file_name, mime, size_bytes)
  on public.entry_attachments to authenticated;
grant insert (pet_id, vet_id, source, expires_at) on public.record_access_grants to authenticated;
grant update (revoked_at) on public.record_access_grants to authenticated;

-- ---------------------------------------------------------------------------
-- RPC
-- ---------------------------------------------------------------------------
-- Ficha completa. Dueño: sin registro (es su propia ficha). Vet: requiere
-- autorización vigente y cada lectura queda en record_access_log. Sin acceso,
-- el mismo error que si la mascota no existiera.
create function private.get_pet_record(p_pet_id uuid, p_visit_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_pet public.pets;
  v_grant public.record_access_grants;
  v_viewer text;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'Inicia sesión para continuar' using errcode = '42501';
  end if;
  select * into v_pet from public.pets where id = p_pet_id;
  if found and v_pet.owner_id = v_uid then
    v_viewer := 'owner';
  elsif found and (select private.current_app_role()) = 'vet' then
    v_grant := private.vet_record_grant(p_pet_id);
    if v_grant.id is not null then
      v_viewer := 'vet';
    end if;
  end if;
  if v_viewer is null then
    raise exception 'La ficha no existe o no tienes acceso' using errcode = '42501';
  end if;
  if v_viewer = 'vet' then
    perform private.log_record_access(p_pet_id, 'view',
      case v_grant.source when 'visit' then 'visit' else 'owner_grant' end,
      null, v_grant.visit_id, v_grant.id);
  end if;

  select jsonb_build_object(
    'viewer', v_viewer,
    'pet', jsonb_build_object(
      'id', v_pet.id, 'name', v_pet.name, 'species_name', sp.name, 'breed_name', b.name,
      'sex', v_pet.sex, 'birth_date_approx', v_pet.birth_date_approx,
      'sterilized', v_pet.sterilized, 'microchip', v_pet.microchip),
    'access', case when v_viewer = 'vet' then jsonb_build_object(
      'via', case v_grant.source when 'visit' then 'visit' else 'owner_grant' end,
      'until', v_grant.expires_at) end,
    'can_write', case when v_viewer = 'owner' then true
                      else coalesce(private.vet_can_write(p_pet_id, p_visit_id), false) end,
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id, 'kind', e.kind, 'title', e.title, 'body', e.body,
        'author_role', e.author_role,
        'author_name', case when e.author_role = 'vet' then coalesce(vp.display_name, 'MV verificado') end,
        'mine', e.author_id = v_uid,
        'visit_id', e.visit_id, 'specialty_name', s.name, 'created_at', e.created_at,
        'supersedes_id', e.supersedes_id,
        'superseded_by', (select c.id from public.clinical_entries c where c.supersedes_id = e.id),
        'vaccine', (select jsonb_build_object('vaccine_name', cv.vaccine_name, 'lot', cv.lot,
                                              'applied_on', cv.applied_on, 'next_due', cv.next_due)
                    from public.clinical_vaccines cv where cv.entry_id = e.id),
        'attachments', coalesce((
          select jsonb_agg(jsonb_build_object('id', a.id, 'file_name', a.file_name,
                                              'mime', a.mime, 'size_bytes', a.size_bytes)
                           order by a.created_at)
          from public.entry_attachments a where a.entry_id = e.id), '[]'::jsonb))
        order by e.created_at desc)
      from public.clinical_entries e
      left join public.vet_profiles vp on vp.user_id = e.author_id and e.author_role = 'vet'
      left join public.specialties s on s.id = e.specialty_id
      where e.pet_id = p_pet_id), '[]'::jsonb),
    'grants', case when v_viewer = 'owner' then coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', g.id, 'vet_id', g.vet_id, 'vet_name', gv.display_name, 'source', g.source,
        'starts_at', g.starts_at, 'expires_at', g.expires_at, 'revoked_at', g.revoked_at,
        'active', g.revoked_at is null and (g.expires_at is null or g.expires_at > now()))
        order by g.created_at desc)
      from public.record_access_grants g
      left join public.vet_profiles gv on gv.user_id = g.vet_id
      where g.pet_id = p_pet_id), '[]'::jsonb) end)
  into v_result
  from (select 1) one
  left join public.species sp on sp.id = v_pet.species_id
  left join public.breeds b on b.id = v_pet.breed_id;
  return v_result;
end;
$$;
revoke execute on function private.get_pet_record(uuid, uuid) from public, anon;
grant execute on function private.get_pet_record(uuid, uuid) to authenticated;

create function public.get_pet_record(p_pet_id uuid, p_visit_id uuid default null)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.get_pet_record(p_pet_id, p_visit_id);
$$;
revoke execute on function public.get_pet_record(uuid, uuid) from public, anon;
grant execute on function public.get_pet_record(uuid, uuid) to authenticated;

-- Descarga de un adjunto: verifica el acceso vigente, registra la descarga
-- (vet) y devuelve la ruta. Solo la usa la Edge Function que firma la URL.
create function private.authorize_attachment(p_attachment_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  a public.entry_attachments;
  v_grant public.record_access_grants;
begin
  select * into a from public.entry_attachments where id = p_attachment_id;
  if v_uid is null or not found or a.pet_id is null then
    raise exception 'El adjunto no existe o no tienes acceso' using errcode = '42501';
  end if;
  if exists (select 1 from public.pets p where p.id = a.pet_id and p.owner_id = v_uid) then
    return a.storage_path;
  end if;
  if (select private.current_app_role()) = 'vet' then
    v_grant := private.vet_record_grant(a.pet_id);
    if v_grant.id is not null then
      perform private.log_record_access(a.pet_id, 'download',
        case v_grant.source when 'visit' then 'visit' else 'owner_grant' end,
        a.entry_id, v_grant.visit_id, v_grant.id);
      return a.storage_path;
    end if;
  end if;
  raise exception 'El adjunto no existe o no tienes acceso' using errcode = '42501';
end;
$$;
revoke execute on function private.authorize_attachment(uuid) from public, anon;
grant execute on function private.authorize_attachment(uuid) to authenticated;

create function public.authorize_attachment(p_attachment_id uuid)
returns text
language sql
volatile
security invoker
set search_path = ''
as $$
  select private.authorize_attachment(p_attachment_id);
$$;
revoke execute on function public.authorize_attachment(uuid) from public, anon;
grant execute on function public.authorize_attachment(uuid) to authenticated;

-- "Quién vio mi ficha": solo el dueño, con el nombre público del vet.
create function private.pet_access_log(p_pet_id uuid, p_limit integer)
returns table (at timestamptz, action text, via text, actor_role text, actor_name text,
               entry_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select l.at, l.action, l.via, l.actor_role,
         case when l.actor_id = (select auth.uid()) then 'Tú'
              when l.actor_role = 'vet' then coalesce(v.display_name, 'MV verificado')
              else 'Sistema' end,
         l.entry_id
  from public.record_access_log l
  join public.pets p on p.id = l.pet_id and p.owner_id = (select auth.uid())
  left join public.vet_profiles v on v.user_id = l.actor_id
  where l.pet_id = p_pet_id
  order by l.at desc, l.id desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
$$;
revoke execute on function private.pet_access_log(uuid, integer) from public, anon;
grant execute on function private.pet_access_log(uuid, integer) to authenticated;

create function public.pet_access_log(p_pet_id uuid, p_limit integer default 100)
returns table (at timestamptz, action text, via text, actor_role text, actor_name text,
               entry_id uuid)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.pet_access_log(p_pet_id, p_limit);
$$;
revoke execute on function public.pet_access_log(uuid, integer) from public, anon;
grant execute on function public.pet_access_log(uuid, integer) to authenticated;

-- Entrada (y su vacuna) en una sola transacción. SECURITY INVOKER: aplica la
-- RLS de cada tabla. El id se genera aquí porque el vet no puede leer la fila
-- recién insertada (sin SELECT directo).
create function public.add_clinical_entry(
  p_pet_id uuid,
  p_kind text,
  p_title text,
  p_body text default null,
  p_visit_id uuid default null,
  p_specialty_id integer default null,
  p_supersedes_id uuid default null,
  p_vaccine jsonb default null)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_role text := (select private.current_app_role());
begin
  if v_role not in ('owner', 'vet') then
    raise exception 'No tienes permiso para esta acción' using errcode = '42501';
  end if;
  if (p_kind = 'vaccine') <> (p_vaccine is not null) then
    raise exception 'Una vacuna requiere sus datos (y solo una vacuna los lleva)'
      using errcode = '22023';
  end if;
  insert into public.clinical_entries
    (id, pet_id, visit_id, author_id, author_role, kind, specialty_id, title, body, supersedes_id)
  values (v_id, p_pet_id, p_visit_id, (select auth.uid()), v_role, p_kind, p_specialty_id,
          trim(p_title), nullif(trim(p_body), ''), p_supersedes_id);
  if p_vaccine is not null then
    insert into public.clinical_vaccines (entry_id, vaccine_name, lot, applied_on, next_due)
    values (v_id, trim(p_vaccine ->> 'vaccine_name'), nullif(trim(p_vaccine ->> 'lot'), ''),
            (p_vaccine ->> 'applied_on')::date, (p_vaccine ->> 'next_due')::date);
  end if;
  return v_id;
end;
$$;
revoke execute on function public.add_clinical_entry(uuid, text, text, text, uuid, integer, uuid, jsonb)
  from public, anon;
grant execute on function public.add_clinical_entry(uuid, text, text, text, uuid, integer, uuid, jsonb)
  to authenticated;

-- Admin: solo conteos, sin contenido clínico.
create function private.record_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (select private.is_admin()) then
    raise exception 'No tienes permiso para esta acción' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'entries', (select count(*) from public.clinical_entries),
    'entries_30d', (select count(*) from public.clinical_entries
                    where created_at > now() - interval '30 days'),
    'attachments', (select count(*) from public.entry_attachments),
    'views_30d', (select count(*) from public.record_access_log
                  where action in ('view', 'download') and at > now() - interval '30 days'),
    'active_owner_grants', (select count(*) from public.record_access_grants
                            where source = 'owner' and revoked_at is null and expires_at > now()),
    'active_visit_grants', (select count(*) from public.record_access_grants
                            where source = 'visit' and revoked_at is null
                              and (expires_at is null or expires_at > now())));
end;
$$;
revoke execute on function private.record_stats() from public, anon;
grant execute on function private.record_stats() to authenticated;

create function public.admin_record_stats()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select private.record_stats();
$$;
revoke execute on function public.admin_record_stats() from public, anon;
grant execute on function public.admin_record_stats() to authenticated;

-- ---------------------------------------------------------------------------
-- Vista de la visita: pet_id/vet_id, cierre por el sistema y acceso a la ficha
-- (igual que 20261118181914 más esos campos).
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
