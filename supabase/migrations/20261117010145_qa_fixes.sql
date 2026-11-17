-- Correcciones del QA de la versión c251867 (docs/qa/QA-c251867.md).
-- QA-02 (Alto), QA-12, QA-01, QA-06, QA-10 (Medios), QA-03, QA-04, QA-05, QA-09 (Bajos).

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
-- ¿El vet actual puede editar su solicitud? (borrador o rechazada, sin enviar)
create function private.vet_can_edit_application()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.vet_profiles v
    where v.user_id = (select auth.uid())
      and v.status in ('pending', 'rejected')
      and v.submitted_at is null
  );
$$;
revoke execute on function private.vet_can_edit_application() from public, anon;
grant execute on function private.vet_can_edit_application() to authenticated;

-- ¿La solicitud del vet actual está en revisión?
create function private.vet_in_review()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.vet_profiles v
    where v.user_id = (select auth.uid())
      and v.status = 'pending' and v.submitted_at is not null
  );
$$;
revoke execute on function private.vet_in_review() from public, anon;
grant execute on function private.vet_in_review() to authenticated;

-- ---------------------------------------------------------------------------
-- QA-02 + QA-10: guardián de vet_profiles
--   * La declaración y la fecha de envío no se tocan en revisión ni tras aprobar.
--   * Contextos de confianza (SQL de mantención, clave de servicio, cascadas
--     como ON DELETE SET NULL de verified_by) no tienen auth.uid(): se permiten.
-- ---------------------------------------------------------------------------
create or replace function private.guard_vet_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  -- QA-10: contextos de confianza → sin restricciones. Son los que no actúan
  -- como usuario final de la API: sin auth.uid(), o con un rol activo distinto
  -- de authenticated/anon (service_role, SQL de mantención, cascadas).
  if v_uid is null
     or coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon') then
    return new;
  end if;
  if coalesce((select private.is_admin()), false) then
    return new;
  end if;

  if (new.identity_verified_at, new.verified_by, new.reviewed_at,
      new.review_notes, new.rejection_reason)
     is distinct from
     (old.identity_verified_at, old.verified_by, old.reviewed_at,
      old.review_notes, old.rejection_reason) then
    raise exception 'Solo un administrador puede modificar la revisión'
      using errcode = '42501';
  end if;

  if new.status is distinct from old.status
     and not (old.status = 'rejected' and new.status = 'pending'
              and new.submitted_at is not null) then
    raise exception 'Solo un administrador puede cambiar el estado'
      using errcode = '42501';
  end if;

  -- QA-02: evidencia de la verificación inmutable en revisión o tras aprobar.
  if (old.status = 'approved' or old.submitted_at is not null) then
    if new.declaration_accepted_at is distinct from old.declaration_accepted_at then
      raise exception 'La declaración jurada no se puede modificar después de enviar la solicitud'
        using errcode = '42501';
    end if;
    if new.submitted_at is distinct from old.submitted_at then
      raise exception 'La solicitud ya fue enviada' using errcode = '42501';
    end if;
  end if;

  if (new.university, new.graduation_year, new.foreign_degree,
      new.title_verification_code, new.display_name)
     is distinct from
     (old.university, old.graduation_year, old.foreign_degree,
      old.title_verification_code, old.display_name)
     and (old.status = 'approved' or old.submitted_at is not null) then
    raise exception 'Los datos profesionales no se pueden editar en revisión o tras la aprobación'
      using errcode = '42501';
  end if;

  if new.submitted_at is not null and old.submitted_at is null then
    perform private.assert_vet_requirements(new);
  end if;

  return new;
end;
$$;

-- Requisitos para enviar o aprobar (una sola fuente de verdad).
create function private.assert_vet_requirements(p public.vet_profiles)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p.university is null or p.graduation_year is null then
    raise exception 'Faltan la universidad o el año de titulación' using errcode = '22023';
  end if;
  if p.declaration_accepted_at is null then
    raise exception 'Falta la declaración jurada' using errcode = '22023';
  end if;
  if not exists (select 1 from public.vet_documents d
                 where d.vet_id = p.user_id and d.kind = 'degree_certificate'
                   and d.purged_at is null) then
    raise exception 'Falta el certificado de título' using errcode = '22023';
  end if;
  if not exists (select 1 from public.vet_documents d
                 where d.vet_id = p.user_id and d.kind = 'id_card_front'
                   and d.purged_at is null) then
    raise exception 'Falta la cédula de identidad' using errcode = '22023';
  end if;
  if not exists (select 1 from public.vet_species s where s.vet_id = p.user_id) then
    raise exception 'Elige al menos una especie' using errcode = '22023';
  end if;
  if not exists (select 1 from public.vet_specialties s where s.vet_id = p.user_id) then
    raise exception 'Elige al menos una especialidad' using errcode = '22023';
  end if;
end;
$$;
revoke execute on function private.assert_vet_requirements(public.vet_profiles)
  from public, anon;
-- Lo usa review_vet_application (SECURITY INVOKER, ejecutada por el admin).
grant execute on function private.assert_vet_requirements(public.vet_profiles)
  to authenticated;

-- QA-02: al aprobar se revalidan los requisitos.
create or replace function public.review_vet_application(
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
  v_profile public.vet_profiles;
begin
  if not coalesce((select private.is_admin()), false) then
    raise exception 'Solo un administrador puede revisar solicitudes' using errcode = '42501';
  end if;
  if not p_approve and nullif(trim(p_reason), '') is null then
    raise exception 'El rechazo requiere un motivo' using errcode = '22023';
  end if;

  select * into v_profile from public.vet_profiles
   where user_id = p_vet_id and status = 'pending' and submitted_at is not null
   for update;
  if not found then
    raise exception 'La solicitud no existe o no está pendiente de revisión'
      using errcode = '22023';
  end if;
  if p_approve then
    perform private.assert_vet_requirements(v_profile);
  end if;

  update public.vet_profiles
     set status = case when p_approve then 'approved' else 'rejected' end,
         identity_verified_at = case when p_approve then now() end,
         verified_by = case when p_approve then (select auth.uid()) end,
         reviewed_at = now(),
         review_notes = nullif(trim(p_notes), ''),
         rejection_reason = case when p_approve then null else trim(p_reason) end,
         submitted_at = case when p_approve then submitted_at end
   where user_id = p_vet_id
  returning status into v_status;

  update public.vet_documents
     set review_status = case when p_approve then 'accepted' else 'rejected' end,
         purge_after = now() + case when p_approve then interval '7 days'
                                    else interval '30 days' end
   where vet_id = p_vet_id and purged_at is null;

  return v_status;
end;
$$;

-- ---------------------------------------------------------------------------
-- QA-12: especies y especialidades bloqueadas mientras la solicitud está en revisión
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['vet_species', 'vet_specialties'] loop
    execute format(
      'create policy %I on public.%I as restrictive for insert to authenticated
         with check (not (select private.vet_in_review()))', t || '_not_in_review_ins', t);
    execute format(
      'create policy %I on public.%I as restrictive for delete to authenticated
         using (not (select private.vet_in_review()))', t || '_not_in_review_del', t);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- QA-03 + QA-06 + QA-09: documentos
-- ---------------------------------------------------------------------------
-- QA-09: un archivo se registra una sola vez.
alter table public.vet_documents
  add constraint vet_documents_storage_path_key unique (storage_path);

-- QA-06: todo documento nace con plazo de retención (borrador = 90 días); la
-- revisión lo reemplaza por 7 o 30 días. La purga omite solicitudes en revisión.
-- El vet solo puede enviar estas columnas: si intenta fijar review_status,
-- purge_after o purged_at recibe 403 (privilegio por columna).
alter table public.vet_documents
  alter column purge_after set default (now() + interval '90 days');
revoke insert on public.vet_documents from authenticated;
grant insert (vet_id, kind, storage_path, mime, size_bytes)
  on public.vet_documents to authenticated;

-- QA-03: solo con la solicitud editable (no en revisión ni aprobada).
drop policy vet_documents_insert_self on public.vet_documents;
create policy vet_documents_insert_self on public.vet_documents
for insert to authenticated
with check (
  vet_id = (select auth.uid())
  and (select private.vet_can_edit_application())
  and exists (select 1 from storage.objects o
              where o.bucket_id = 'vet-documents' and o.name = storage_path)
);

drop policy vet_documents_storage_insert on storage.objects;
create policy vet_documents_storage_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'vet-documents'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and (select private.vet_can_edit_application())
);

-- QA-06 (huérfanos): el vet NO borra archivos del bucket. Un archivo subido
-- cuyo registro falló lo borra la purga del servidor pasadas 24 h.
create function private.vet_orphan_objects(p_limit integer default 100)
returns table (name text)
language sql
stable
security definer
set search_path = ''
as $$
  select o.name from storage.objects o
  where o.bucket_id = 'vet-documents'
    and o.created_at < now() - interval '24 hours'
    and not exists (select 1 from public.vet_documents d where d.storage_path = o.name)
  limit p_limit;
$$;
revoke execute on function private.vet_orphan_objects(integer) from public, anon, authenticated;
grant execute on function private.vet_orphan_objects(integer) to service_role;

create function public.purge_orphan_candidates(p_limit integer default 100)
returns table (name text)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.vet_orphan_objects(p_limit);
$$;
revoke execute on function public.purge_orphan_candidates(integer) from public, anon, authenticated;
grant execute on function public.purge_orphan_candidates(integer) to service_role;

-- Vista para la purga: documentos vencidos de solicitudes que NO están en revisión.
create function private.vet_documents_due(p_limit integer default 100)
returns table (id uuid, storage_path text)
language sql
stable
security definer
set search_path = ''
as $$
  select d.id, d.storage_path
  from public.vet_documents d
  join public.vet_profiles v on v.user_id = d.vet_id
  where d.purged_at is null and d.storage_path is not null
    and d.purge_after <= now()
    and not (v.status = 'pending' and v.submitted_at is not null)
  order by d.purge_after
  limit p_limit;
$$;
revoke execute on function private.vet_documents_due(integer) from public, anon, authenticated;
grant usage on schema private to service_role;
grant execute on function private.vet_documents_due(integer) to service_role;

-- RPC pública solo para el rol de servicio (la Edge Function).
create function public.purge_candidates(p_limit integer default 100)
returns table (id uuid, storage_path text)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.vet_documents_due(p_limit);
$$;
revoke execute on function public.purge_candidates(integer) from public, anon, authenticated;
grant execute on function public.purge_candidates(integer) to service_role;

-- ---------------------------------------------------------------------------
-- QA-01: rol y perfil solo con términos aceptados (vigentes) y, el dueño, con comuna
-- ---------------------------------------------------------------------------
create function private.has_current_terms()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.terms_acceptances t
    where t.user_id = (select auth.uid())
      and t.version = public.current_legal_version('terms')
  ) and exists (
    select 1 from public.privacy_notice_views p
    where p.user_id = (select auth.uid())
      and p.version = public.current_legal_version('privacy')
  );
$$;
revoke execute on function private.has_current_terms() from public, anon;
grant execute on function private.has_current_terms() to authenticated;

drop policy user_roles_insert_self on public.user_roles;
create policy user_roles_insert_self on public.user_roles
for insert to authenticated
with check (
  user_id = (select auth.uid()) and role in ('owner', 'vet')
  and (select private.has_current_terms())
);

drop policy owner_profiles_insert_self on public.owner_profiles;
create policy owner_profiles_insert_self on public.owner_profiles
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and (select private.current_app_role()) = 'owner'
  and commune_id is not null
);

-- complete_registration: primero términos y aviso, después rol y perfil.
create or replace function public.complete_registration(
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
  if exists (select 1 from public.user_roles r where r.user_id = v_uid) then
    raise exception 'Tu cuenta ya completó el registro' using errcode = '23505';
  end if;

  insert into public.terms_acceptances (user_id, version)
    values (v_uid, p_terms_version)
    on conflict (user_id, version) do nothing;
  insert into public.privacy_notice_views (user_id, version)
    values (v_uid, p_privacy_version)
    on conflict (user_id, version) do nothing;
  insert into public.user_roles (user_id, role) values (v_uid, p_role);

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
-- QA-04: la comuna del dueño no se puede vaciar una vez definida
-- ---------------------------------------------------------------------------
create function private.guard_owner_profile()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if old.commune_id is not null and new.commune_id is null then
    raise exception 'La comuna es obligatoria' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke execute on function private.guard_owner_profile() from public, anon, authenticated;

create trigger owner_profiles_guard before update on public.owner_profiles
for each row execute function private.guard_owner_profile();

-- ---------------------------------------------------------------------------
-- QA-05: un consentimiento retirado no se vuelve a modificar
-- ---------------------------------------------------------------------------
drop policy consents_revoke_self on public.consents;
create policy consents_revoke_self on public.consents
for update to authenticated
using (user_id = (select auth.uid()) and revoked_at is null)
with check (user_id = (select auth.uid()) and revoked_at is not null);
