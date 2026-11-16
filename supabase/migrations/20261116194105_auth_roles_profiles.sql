-- Fase 1: roles, perfiles, términos, aviso de privacidad y consentimientos.
-- Ver SPEC.md F1/F8 y docs/arquitectura.md §4, §7 y §8.
--
-- Principios:
-- * El rol vive en public.user_roles, nunca en user_metadata.
-- * El registro se completa con la RPC complete_registration (SECURITY INVOKER):
--   las políticas RLS solo permiten crear el propio rol como 'owner' o 'vet'
--   (nunca 'admin') y no existe política UPDATE sobre el rol.
-- * Las tablas nuevas no se exponen solas a la Data API: GRANT explícitos.

-- Supabase concede por defecto ALL sobre tablas nuevas de public a anon y
-- authenticated. Lo quitamos: cada tabla recibe solo los GRANT que necesita.
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on functions from anon, authenticated;

-- Helpers usados por las políticas (deben poder ejecutarse como el usuario).
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------
create table public.user_roles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  role text not null check (role in ('owner', 'vet', 'foundation', 'admin')),
  created_at timestamptz not null default now()
);

-- Rol del usuario actual. SECURITY DEFINER para no recursar en la RLS de
-- user_roles; vive en `private` (no expuesto) y solo mira auth.uid().
create function private.current_app_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select r.role from public.user_roles r where r.user_id = (select auth.uid());
$$;

create function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select private.current_app_role()) = 'admin', false);
$$;

revoke execute on function private.current_app_role() from public, anon;
revoke execute on function private.is_admin() from public, anon;
grant execute on function private.current_app_role() to authenticated;
grant execute on function private.is_admin() to authenticated;

alter table public.user_roles enable row level security;
alter table public.user_roles force row level security;

create policy user_roles_select on public.user_roles
for select to authenticated
using (user_id = (select auth.uid()) or (select private.is_admin()));

-- Autoregistro: solo el propio rol y solo dueño o veterinario.
create policy user_roles_insert_self on public.user_roles
for insert to authenticated
with check (user_id = (select auth.uid()) and role in ('owner', 'vet'));

grant select, insert on public.user_roles to authenticated;

-- ---------------------------------------------------------------------------
-- Versiones de documentos legales (términos y política de privacidad)
-- ---------------------------------------------------------------------------
create table public.legal_versions (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('terms', 'privacy')),
  version text not null,
  effective_from timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (kind, version)
);

create index legal_versions_kind_effective_idx
  on public.legal_versions (kind, effective_from desc);

alter table public.legal_versions enable row level security;
alter table public.legal_versions force row level security;

create policy legal_versions_read on public.legal_versions
for select to anon, authenticated
using (true);

create policy legal_versions_admin_insert on public.legal_versions
for insert to authenticated
with check ((select private.is_admin()));

grant select on public.legal_versions to anon, authenticated;
grant insert on public.legal_versions to authenticated;

-- Versión vigente de un documento legal.
create function public.current_legal_version(p_kind text)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select v.version from public.legal_versions v
  where v.kind = p_kind and v.effective_from <= now()
  order by v.effective_from desc
  limit 1;
$$;

grant execute on function public.current_legal_version(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Perfiles
-- ---------------------------------------------------------------------------
-- Dueño: datos mínimos (sin RUT). La comuna se agrega en la fase 2 (catálogos).
create table public.owner_profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 2 and 60),
  phone text check (phone is null or phone ~ '^\+?[0-9 ]{8,15}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.owner_profiles enable row level security;
alter table public.owner_profiles force row level security;

create policy owner_profiles_select on public.owner_profiles
for select to authenticated
using (user_id = (select auth.uid()) or (select private.is_admin()));

create policy owner_profiles_insert_self on public.owner_profiles
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and (select private.current_app_role()) = 'owner'
);

create policy owner_profiles_update_self on public.owner_profiles
for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

grant select, insert on public.owner_profiles to authenticated;
grant update (display_name, phone) on public.owner_profiles to authenticated;

-- Veterinario: sin RUT. Nace 'pending'; solo el admin cambia el estado (fase 3).
create table public.vet_profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 2 and 60),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'suspended')),
  identity_verified_at timestamptz,
  verified_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index vet_profiles_verified_by_idx on public.vet_profiles (verified_by);
create index vet_profiles_status_idx on public.vet_profiles (status);

alter table public.vet_profiles enable row level security;
alter table public.vet_profiles force row level security;

create policy vet_profiles_select on public.vet_profiles
for select to authenticated
using (user_id = (select auth.uid()) or (select private.is_admin()));

create policy vet_profiles_insert_self on public.vet_profiles
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and status = 'pending'
  and identity_verified_at is null
  and verified_by is null
  and (select private.current_app_role()) = 'vet'
);

create policy vet_profiles_update_self on public.vet_profiles
for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

grant select, insert on public.vet_profiles to authenticated;
-- Solo el nombre es editable por el propio vet; el estado no.
grant update (display_name) on public.vet_profiles to authenticated;

-- updated_at automático.
create function private.touch_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

grant execute on function private.touch_updated_at() to authenticated;

create trigger owner_profiles_touch before update on public.owner_profiles
for each row execute function private.touch_updated_at();
create trigger vet_profiles_touch before update on public.vet_profiles
for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Términos (contrato), aviso de privacidad (información) y consentimientos
-- ---------------------------------------------------------------------------
create table public.terms_acceptances (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  version text not null,
  accepted_at timestamptz not null default now(),
  unique (user_id, version)
);

create table public.privacy_notice_views (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  version text not null,
  shown_at timestamptz not null default now(),
  unique (user_id, version)
);

-- Solo tratamientos opcionales (nunca condición del servicio).
create table public.consents (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  purpose text not null check (purpose in ('marketing')),
  version text not null,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz
);

create index consents_user_idx on public.consents (user_id);
create unique index consents_one_active_idx
  on public.consents (user_id, purpose) where revoked_at is null;

alter table public.terms_acceptances enable row level security;
alter table public.terms_acceptances force row level security;
alter table public.privacy_notice_views enable row level security;
alter table public.privacy_notice_views force row level security;
alter table public.consents enable row level security;
alter table public.consents force row level security;

create policy terms_select on public.terms_acceptances
for select to authenticated
using (user_id = (select auth.uid()) or (select private.is_admin()));

create policy terms_insert_self on public.terms_acceptances
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and version = (select public.current_legal_version('terms'))
);

create policy privacy_views_select on public.privacy_notice_views
for select to authenticated
using (user_id = (select auth.uid()) or (select private.is_admin()));

create policy privacy_views_insert_self on public.privacy_notice_views
for insert to authenticated
with check (
  user_id = (select auth.uid())
  and version = (select public.current_legal_version('privacy'))
);

create policy consents_select on public.consents
for select to authenticated
using (user_id = (select auth.uid()) or (select private.is_admin()));

create policy consents_insert_self on public.consents
for insert to authenticated
with check (user_id = (select auth.uid()) and revoked_at is null);

create policy consents_revoke_self on public.consents
for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()) and revoked_at is not null);

grant select, insert on public.terms_acceptances to authenticated;
grant select, insert on public.privacy_notice_views to authenticated;
grant select, insert on public.consents to authenticated;
grant update (revoked_at) on public.consents to authenticated;

-- ---------------------------------------------------------------------------
-- RPC de registro (SECURITY INVOKER: todo pasa por las políticas de arriba)
-- ---------------------------------------------------------------------------
create function public.complete_registration(
  p_role text,
  p_display_name text,
  p_phone text,
  p_terms_version text,
  p_privacy_version text
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
    insert into public.owner_profiles (user_id, display_name, phone)
      values (v_uid, trim(p_display_name), nullif(trim(p_phone), ''));
  else
    insert into public.vet_profiles (user_id, display_name)
      values (v_uid, trim(p_display_name));
  end if;

  return p_role;
end;
$$;

grant execute on function public.complete_registration(text, text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Privilegios explícitos (por si las tablas recibieron los ALL por defecto)
-- ---------------------------------------------------------------------------
revoke all on public.user_roles, public.legal_versions, public.owner_profiles,
  public.vet_profiles, public.terms_acceptances, public.privacy_notice_views,
  public.consents
  from anon, authenticated;

grant select, insert on public.user_roles to authenticated;
grant select on public.legal_versions to anon, authenticated;
grant insert on public.legal_versions to authenticated;
grant select, insert on public.owner_profiles to authenticated;
grant update (display_name, phone) on public.owner_profiles to authenticated;
grant select, insert on public.vet_profiles to authenticated;
grant update (display_name) on public.vet_profiles to authenticated;
grant select, insert on public.terms_acceptances to authenticated;
grant select, insert on public.privacy_notice_views to authenticated;
grant select, insert on public.consents to authenticated;
grant update (revoked_at) on public.consents to authenticated;

revoke execute on function public.complete_registration(text, text, text, text, text)
  from public, anon;
revoke execute on function public.current_legal_version(text) from public;
grant execute on function public.current_legal_version(text) to anon, authenticated;
