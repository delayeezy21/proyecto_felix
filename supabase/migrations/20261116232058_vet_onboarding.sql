-- Fase 3: onboarding y verificación de veterinarios.
-- Ver SPEC.md F1 (HU1.3–HU1.5) y docs/arquitectura.md §4 y §8.
--
-- Verificación (en Chile no hay un registro público oficial de veterinarios):
--   certificado de título + cédula (anverso) + opcional COLMEVET, declaración
--   jurada simple y revisión humana del admin con lista de chequeo.
-- Privacidad: documentos en bucket privado; se purgan 7 días tras la revisión
--   (30 si se rechaza, ventana de apelación). Queda solo el metadato.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- El log de admin solo registra acciones de admins (los vets también editan
-- tablas auditadas, como vet_profiles).
create or replace function private.log_admin_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not coalesce((select private.is_admin()), false) then
    return new;
  end if;
  insert into public.admin_audit_log (actor_id, table_name, row_pk, action, old_data, new_data)
  values (
    (select auth.uid()),
    tg_table_name,
    coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'user_id', to_jsonb(new)::text),
    tg_op,
    case when tg_op = 'UPDATE' then to_jsonb(old) end,
    to_jsonb(new)
  );
  return new;
end;
$$;

revoke execute on function private.log_admin_change() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Datos profesionales del vet
-- ---------------------------------------------------------------------------
alter table public.vet_profiles
  add column bio text check (bio is null or char_length(bio) <= 500),
  add column university text check (university is null or char_length(university) between 3 and 120),
  add column graduation_year smallint check (graduation_year is null or graduation_year between 1950 and 2100),
  add column foreign_degree boolean not null default false,
  add column title_verification_code text
    check (title_verification_code is null or char_length(title_verification_code) between 3 and 60),
  add column declaration_accepted_at timestamptz,
  add column submitted_at timestamptz,
  add column reviewed_at timestamptz,
  add column review_notes text check (review_notes is null or char_length(review_notes) <= 1000),
  add column rejection_reason text check (rejection_reason is null or char_length(rejection_reason) <= 500);

create policy vet_profiles_admin_update on public.vet_profiles
for update to authenticated
using ((select private.is_admin()))
with check ((select private.is_admin()));

-- ---------------------------------------------------------------------------
-- Especies, especialidades y disponibilidad del vet
-- ---------------------------------------------------------------------------
create table public.vet_species (
  vet_id uuid not null references public.vet_profiles (user_id) on delete cascade,
  species_id integer not null references public.species (id),
  primary key (vet_id, species_id)
);
create index vet_species_species_idx on public.vet_species (species_id);

create table public.vet_specialties (
  vet_id uuid not null references public.vet_profiles (user_id) on delete cascade,
  specialty_id integer not null references public.specialties (id),
  primary key (vet_id, specialty_id)
);
create index vet_specialties_specialty_idx on public.vet_specialties (specialty_id);

-- Bloques semanales en minutos desde las 00:00 (weekday ISO: 1 = lunes).
create table public.vet_availability (
  id uuid primary key default gen_random_uuid(),
  vet_id uuid not null references public.vet_profiles (user_id) on delete cascade,
  weekday smallint not null check (weekday between 1 and 7),
  start_min smallint not null check (start_min between 0 and 1439),
  end_min smallint not null check (end_min between 1 and 1440),
  check (start_min < end_min),
  constraint vet_availability_no_overlap exclude using gist (
    vet_id with =,
    weekday with =,
    int4range(start_min, end_min) with &&
  )
);
create index vet_availability_vet_idx on public.vet_availability (vet_id);

-- ---------------------------------------------------------------------------
-- Documentos de verificación
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('vet-documents', 'vet-documents', false, 5242880,
  array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

create table public.vet_documents (
  id uuid primary key default gen_random_uuid(),
  vet_id uuid not null references public.vet_profiles (user_id) on delete cascade,
  kind text not null check (kind in ('degree_certificate', 'id_card_front', 'colmevet', 'other')),
  storage_path text check (storage_path is null or storage_path like vet_id::text || '/%'),
  mime text not null check (mime in ('application/pdf', 'image/jpeg', 'image/png')),
  size_bytes integer not null check (size_bytes between 1 and 5242880),
  uploaded_at timestamptz not null default now(),
  review_status text not null default 'pending'
    check (review_status in ('pending', 'accepted', 'rejected')),
  purge_after timestamptz,
  purged_at timestamptz
);
create index vet_documents_vet_idx on public.vet_documents (vet_id);
create index vet_documents_purge_idx on public.vet_documents (purge_after)
  where purged_at is null and purge_after is not null;

-- Estado del vet actual (para políticas de Storage y de datos propios).
create function private.current_vet_status()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select v.status from public.vet_profiles v where v.user_id = (select auth.uid());
$$;
revoke execute on function private.current_vet_status() from public, anon;
grant execute on function private.current_vet_status() to authenticated;

-- ---------------------------------------------------------------------------
-- Guardián de vet_profiles: campos de revisión solo los cambia el admin;
-- el envío a revisión exige requisitos completos.
-- ---------------------------------------------------------------------------
create function private.guard_vet_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_is_admin boolean := coalesce((select private.is_admin()), false);
begin
  if v_is_admin then
    return new;
  end if;

  -- Campos de la revisión: nunca los cambia el propio vet.
  if (new.identity_verified_at, new.verified_by, new.reviewed_at,
      new.review_notes, new.rejection_reason)
     is distinct from
     (old.identity_verified_at, old.verified_by, old.reviewed_at,
      old.review_notes, old.rejection_reason) then
    raise exception 'Solo un administrador puede modificar la revisión'
      using errcode = '42501';
  end if;

  -- Estado: el vet solo puede volver de 'rejected' a 'pending' al reenviar.
  if new.status is distinct from old.status
     and not (old.status = 'rejected' and new.status = 'pending'
              and new.submitted_at is not null) then
    raise exception 'Solo un administrador puede cambiar el estado'
      using errcode = '42501';
  end if;

  -- Datos profesionales bloqueados tras la aprobación o mientras está en revisión.
  if (new.university, new.graduation_year, new.foreign_degree,
      new.title_verification_code, new.display_name)
     is distinct from
     (old.university, old.graduation_year, old.foreign_degree,
      old.title_verification_code, old.display_name)
     and (old.status = 'approved' or old.submitted_at is not null) then
    raise exception 'Los datos profesionales no se pueden editar en revisión o tras la aprobación'
      using errcode = '42501';
  end if;

  -- Envío a revisión: requisitos completos.
  if new.submitted_at is not null and old.submitted_at is null then
    if new.university is null or new.graduation_year is null then
      raise exception 'Faltan la universidad o el año de titulación' using errcode = '22023';
    end if;
    if new.declaration_accepted_at is null then
      raise exception 'Falta la declaración jurada' using errcode = '22023';
    end if;
    if not exists (select 1 from public.vet_documents d
                   where d.vet_id = new.user_id and d.kind = 'degree_certificate'
                     and d.purged_at is null) then
      raise exception 'Falta el certificado de título' using errcode = '22023';
    end if;
    if not exists (select 1 from public.vet_documents d
                   where d.vet_id = new.user_id and d.kind = 'id_card_front'
                     and d.purged_at is null) then
      raise exception 'Falta la cédula de identidad' using errcode = '22023';
    end if;
    if not exists (select 1 from public.vet_species s where s.vet_id = new.user_id) then
      raise exception 'Elige al menos una especie' using errcode = '22023';
    end if;
    if not exists (select 1 from public.vet_specialties s where s.vet_id = new.user_id) then
      raise exception 'Elige al menos una especialidad' using errcode = '22023';
    end if;
  end if;

  -- Retirar el envío solo si sigue pendiente (no después de revisado).
  if new.submitted_at is null and old.submitted_at is not null then
    raise exception 'La solicitud ya fue enviada' using errcode = '42501';
  end if;

  return new;
end;
$$;
revoke execute on function private.guard_vet_profile() from public, anon, authenticated;

create trigger vet_profiles_guard before update on public.vet_profiles
for each row execute function private.guard_vet_profile();

create trigger vet_profiles_audit after update on public.vet_profiles
for each row execute function private.log_admin_change();

-- ---------------------------------------------------------------------------
-- RPC: el vet envía su solicitud (las validaciones están en el guardián)
-- ---------------------------------------------------------------------------
create function public.submit_vet_application()
returns timestamptz
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_at timestamptz;
begin
  update public.vet_profiles
     set submitted_at = now(),
         status = case when status = 'rejected' then 'pending' else status end
   where user_id = v_uid and submitted_at is null
     and status in ('pending', 'rejected')
  returning submitted_at into v_at;
  if v_at is null then
    raise exception 'No hay una solicitud que enviar' using errcode = '22023';
  end if;
  return v_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: el admin aprueba o rechaza
-- ---------------------------------------------------------------------------
create function public.review_vet_application(
  p_vet_id uuid,
  p_approve boolean,
  p_reason text default null,
  p_notes text default null
)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_status text;
begin
  if not coalesce((select private.is_admin()), false) then
    raise exception 'Solo un administrador puede revisar solicitudes' using errcode = '42501';
  end if;
  if not p_approve and nullif(trim(p_reason), '') is null then
    raise exception 'El rechazo requiere un motivo' using errcode = '22023';
  end if;

  update public.vet_profiles
     set status = case when p_approve then 'approved' else 'rejected' end,
         identity_verified_at = case when p_approve then now() end,
         verified_by = case when p_approve then (select auth.uid()) end,
         reviewed_at = now(),
         review_notes = nullif(trim(p_notes), ''),
         rejection_reason = case when p_approve then null else trim(p_reason) end,
         -- Rechazado: debe corregir y reenviar.
         submitted_at = case when p_approve then submitted_at end
   where user_id = p_vet_id and status = 'pending' and submitted_at is not null
  returning status into v_status;

  if v_status is null then
    raise exception 'La solicitud no existe o no está pendiente de revisión'
      using errcode = '22023';
  end if;

  -- Programa la purga de los documentos revisados (7 días; 30 si se rechaza).
  update public.vet_documents
     set review_status = case when p_approve then 'accepted' else 'rejected' end,
         purge_after = now() + case when p_approve then interval '7 days'
                                    else interval '30 days' end
   where vet_id = p_vet_id and purged_at is null;

  return v_status;
end;
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.vet_species enable row level security;
alter table public.vet_species force row level security;
alter table public.vet_specialties enable row level security;
alter table public.vet_specialties force row level security;
alter table public.vet_availability enable row level security;
alter table public.vet_availability force row level security;
alter table public.vet_documents enable row level security;
alter table public.vet_documents force row level security;

do $$
declare
  t text;
begin
  foreach t in array array['vet_species', 'vet_specialties', 'vet_availability'] loop
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (vet_id = (select auth.uid()) or (select private.is_admin()))',
      t || '_read', t);
    execute format(
      'create policy %I on public.%I for insert to authenticated
         with check (vet_id = (select auth.uid())
                     and (select private.current_vet_status()) is not null)',
      t || '_insert_self', t);
    execute format(
      'create policy %I on public.%I for delete to authenticated
         using (vet_id = (select auth.uid()))',
      t || '_delete_self', t);
  end loop;
end;
$$;

-- Solo especies y especialidades activas.
create policy vet_species_active on public.vet_species
as restrictive for insert to authenticated
with check (exists (select 1 from public.species s where s.id = species_id and s.active));
create policy vet_specialties_active on public.vet_specialties
as restrictive for insert to authenticated
with check (exists (select 1 from public.specialties s where s.id = specialty_id and s.active));

create policy vet_documents_read on public.vet_documents
for select to authenticated
using (vet_id = (select auth.uid()) or (select private.is_admin()));

-- El vet registra un documento que ya subió a su carpeta del bucket, mientras
-- su solicitud no está enviada ni aprobada.
create policy vet_documents_insert_self on public.vet_documents
for insert to authenticated
with check (
  vet_id = (select auth.uid())
  and purge_after is null and purged_at is null and review_status = 'pending'
  and (select private.current_vet_status()) in ('pending', 'rejected')
  and exists (select 1 from storage.objects o
              where o.bucket_id = 'vet-documents' and o.name = storage_path)
);

create policy vet_documents_admin_update on public.vet_documents
for update to authenticated
using ((select private.is_admin()))
with check ((select private.is_admin()));

-- Storage: carpeta = id del vet.
create policy vet_documents_storage_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'vet-documents'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and (select private.current_vet_status()) in ('pending', 'rejected')
);

create policy vet_documents_storage_read on storage.objects
for select to authenticated
using (
  bucket_id = 'vet-documents'
  and ((storage.foldername(name))[1] = (select auth.uid())::text
       or (select private.is_admin()))
);

-- ---------------------------------------------------------------------------
-- Privilegios
-- ---------------------------------------------------------------------------
revoke all on public.vet_species, public.vet_specialties, public.vet_availability,
  public.vet_documents from anon, authenticated;

grant select, insert, delete on public.vet_species, public.vet_specialties,
  public.vet_availability to authenticated;
grant select, insert on public.vet_documents to authenticated;
grant update (review_status, purge_after) on public.vet_documents to authenticated;

grant update (bio, university, graduation_year, foreign_degree,
  title_verification_code, declaration_accepted_at, submitted_at, status,
  identity_verified_at, verified_by, reviewed_at, review_notes, rejection_reason)
  on public.vet_profiles to authenticated;

revoke execute on function public.submit_vet_application() from public, anon;
grant execute on function public.submit_vet_application() to authenticated;
revoke execute on function public.review_vet_application(uuid, boolean, text, text)
  from public, anon;
grant execute on function public.review_vet_application(uuid, boolean, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Purga programada de documentos (Edge Function purge-vet-documents).
-- Borrar filas de storage.objects por SQL NO borra el archivo: la purga real
-- la hace la Edge Function con la API de Storage. pg_cron la invoca cada hora
-- si existen los secretos de Vault 'project_url' y 'service_role_key'.
-- ---------------------------------------------------------------------------
select cron.schedule(
  'purge-vet-documents',
  '0 * * * *',
  $cron$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/purge-vet-documents',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' ||
        (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000)
  where exists (select 1 from vault.decrypted_secrets where name = 'project_url')
    and exists (select 1 from vault.decrypted_secrets where name = 'service_role_key');
  $cron$
);

-- Una sola política UPDATE en vet_profiles (propio o admin). Qué columnas puede
-- tocar cada uno lo decide private.guard_vet_profile().
drop policy vet_profiles_update_self on public.vet_profiles;
drop policy vet_profiles_admin_update on public.vet_profiles;
create policy vet_profiles_update on public.vet_profiles
for update to authenticated
using (user_id = (select auth.uid()) or (select private.is_admin()))
with check (user_id = (select auth.uid()) or (select private.is_admin()));
