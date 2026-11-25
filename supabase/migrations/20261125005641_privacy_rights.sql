-- Fase 11: derechos de privacidad (Ley 21.719). SPEC §F8 (HU8.1 a HU8.6, P1, P2)
-- y docs/arquitectura.md §8.
--
-- * Exportación (export_my_data) por rol, registrada en data_exports.
-- * Consentimientos opcionales y versión de la política (my_privacy_status,
--   set_consent, record_privacy_notice_view).
-- * Borrado: request_account_deletion → cuenta bloqueada (pre-request de
--   PostgREST + políticas restrictivas en Storage y Realtime), sesiones
--   revocadas, visitas abiertas canceladas sin cargo y presencia offline;
--   cancel_account_deletion dentro de la gracia de 15 días.
-- * Job idempotente (pg_cron) que, vencida la gracia, recorre deletion_targets:
--   BD, Storage (vía la Edge Function purge-privacy-storage), FCM, logs y
--   auth; desvincula y redacta las entradas de vets (P1, M3), seudonimiza al
--   vet autor (HU8.5) y termina con un escaneo por catálogo.
-- * Retención (log 2 años, entradas retenidas al vencer, tokens 90 días,
--   adjuntos huérfanos 24 h = M2) y escaneo periódico de PII.

-- ---------------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------------
create table public.deletion_requests (
  id uuid primary key default gen_random_uuid(),
  -- Se anula al terminar (el usuario ya no existe).
  user_id uuid references auth.users (id) on delete set null,
  role text not null check (role in ('owner', 'vet', 'foundation')),
  status text not null default 'blocked'
    check (status in ('blocked', 'executing', 'done', 'cancelled')),
  requested_at timestamptz not null default now(),
  execute_after timestamptz not null default now() + interval '15 days',
  cancelled_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  -- Interno del job (no se expone): mascotas del titular para el escaneo final.
  subject_pet_ids uuid[],
  -- Resumen sin PII: conteos por sistema y resultado del escaneo.
  report jsonb
);
create unique index deletion_requests_one_active_idx
  on public.deletion_requests (user_id) where status in ('blocked', 'executing');
create index deletion_requests_user_idx on public.deletion_requests (user_id);
create index deletion_requests_due_idx
  on public.deletion_requests (execute_after) where status in ('blocked', 'executing');

create table public.deletion_targets (
  id bigint generated always as identity primary key,
  request_id uuid not null references public.deletion_requests (id) on delete cascade,
  system text not null check (system in ('db', 'storage', 'fcm', 'logs', 'auth')),
  target text not null,
  action text not null check (action in ('delete', 'anonymize', 'retain', 'verify', 'cancel')),
  affected integer not null default 0,
  retained_reason text,
  created_at timestamptz not null default now(),
  ack_at timestamptz,
  verified_at timestamptz,
  detail jsonb
);
create index deletion_targets_request_idx on public.deletion_targets (request_id);

create table public.data_exports (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null,
  sections text[] not null,
  exported_at timestamptz not null default now()
);
create index data_exports_user_idx on public.data_exports (user_id);

-- Solicitudes del vet autor para consultar una entrada retenida (P1).
create table public.retained_entry_requests (
  id bigint generated always as identity primary key,
  entry_id uuid references public.clinical_entries (id) on delete set null,
  vet_id uuid not null references auth.users (id) on delete cascade,
  reason text not null check (char_length(trim(reason)) between 10 and 500),
  requested_at timestamptz not null default now()
);
create index retained_entry_requests_vet_idx on public.retained_entry_requests (vet_id);
create index retained_entry_requests_entry_idx on public.retained_entry_requests (entry_id);

-- Hallazgos del escaneo de PII en texto libre (solo admin, sin el valor completo).
create table public.pii_scan_findings (
  id bigint generated always as identity primary key,
  table_name text not null,
  column_name text not null,
  row_pk text not null,
  kind text not null check (kind in ('email', 'phone', 'rut')),
  masked text not null,
  found_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique (table_name, column_name, row_pk, kind)
);

-- Cola interna de objetos de Storage por borrar (la Edge Function los borra
-- con la API de Storage; el job confirma contra storage.objects).
create table private.storage_erasure_queue (
  id bigint generated always as identity primary key,
  request_id uuid not null references public.deletion_requests (id) on delete cascade,
  bucket_id text not null,
  object_name text not null,
  enqueued_at timestamptz not null default now(),
  unique (bucket_id, object_name)
);
create index storage_erasure_queue_request_idx on private.storage_erasure_queue (request_id);

revoke all on public.deletion_requests, public.deletion_targets, public.data_exports,
  public.retained_entry_requests, public.pii_scan_findings from anon, authenticated;
revoke all on private.storage_erasure_queue from public, anon, authenticated, service_role;

alter table public.deletion_requests enable row level security;
alter table public.deletion_requests force row level security;
alter table public.deletion_targets enable row level security;
alter table public.deletion_targets force row level security;
alter table public.data_exports enable row level security;
alter table public.data_exports force row level security;
alter table public.retained_entry_requests enable row level security;
alter table public.retained_entry_requests force row level security;
alter table public.pii_scan_findings enable row level security;
alter table public.pii_scan_findings force row level security;
alter table private.storage_erasure_queue enable row level security;
alter table private.storage_erasure_queue force row level security;

-- Lectura: la propia solicitud (sin columnas internas) o el admin; todo lo
-- escribe el servidor.
grant select (id, user_id, role, status, requested_at, execute_after, cancelled_at,
  started_at, completed_at) on public.deletion_requests to authenticated;
create policy deletion_requests_select on public.deletion_requests
for select to authenticated
using (user_id = (select auth.uid()) or (select private.is_admin()));

grant select on public.deletion_targets to authenticated;
create policy deletion_targets_admin on public.deletion_targets
for select to authenticated using ((select private.is_admin()));

grant select on public.data_exports to authenticated;
create policy data_exports_select on public.data_exports
for select to authenticated using (user_id = (select auth.uid()));

grant select on public.retained_entry_requests to authenticated;
create policy retained_entry_requests_select on public.retained_entry_requests
for select to authenticated
using (vet_id = (select auth.uid()) or (select private.is_admin()));

grant select on public.pii_scan_findings to authenticated;
grant update (resolved_at) on public.pii_scan_findings to authenticated;
create policy pii_scan_findings_admin_read on public.pii_scan_findings
for select to authenticated using ((select private.is_admin()));
create policy pii_scan_findings_admin_resolve on public.pii_scan_findings
for update to authenticated
using ((select private.is_admin())) with check ((select private.is_admin()));

-- ---------------------------------------------------------------------------
-- 2. Cuenta bloqueada
-- ---------------------------------------------------------------------------
create function private.is_blocked(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_uid is not null and exists (
    select 1 from public.deletion_requests d
    where d.user_id = p_uid and d.status in ('blocked', 'executing'));
$$;
revoke execute on function private.is_blocked(uuid) from public, anon, authenticated;

create function private.account_blocked()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_blocked((select auth.uid()));
$$;
revoke execute on function private.account_blocked() from public, anon;
grant execute on function private.account_blocked() to authenticated;

-- Pre-request de PostgREST: una cuenta bloqueada solo puede ver su solicitud,
-- cancelarla o exportar sus datos. Cubre toda la REST y las RPC (también con
-- un JWT emitido antes del bloqueo, que vive hasta 1 h).
create function public.check_request()
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    return;
  end if;
  if coalesce(current_setting('request.path', true), '') in
     ('/rpc/my_deletion_request', '/rpc/cancel_account_deletion', '/rpc/export_my_data') then
    return;
  end if;
  if (select private.account_blocked()) then
    raise exception 'Tu cuenta está bloqueada por una solicitud de eliminación'
      using errcode = '42501', hint = 'account_blocked';
  end if;
end;
$$;
revoke execute on function public.check_request() from public;
grant execute on function public.check_request() to anon, authenticated;

alter role authenticator set pgrst.db_pre_request = 'public.check_request';
notify pgrst, 'reload config';

-- Storage y Realtime no pasan por PostgREST: políticas restrictivas.
create policy privacy_blocked_storage on storage.objects
as restrictive for all to authenticated
using (not (select private.account_blocked()))
with check (not (select private.account_blocked()));
create policy privacy_blocked_realtime on realtime.messages
as restrictive for all to authenticated
using (not (select private.account_blocked()))
with check (not (select private.account_blocked()));

-- Sin tratamiento de terceros sobre la cuenta bloqueada: el vet no lee ni
-- escribe la ficha de un dueño bloqueado y un vet bloqueado no ofrece horas.
create or replace function private.vet_record_grant(p_pet uuid)
returns public.record_access_grants
language sql
stable
security definer
set search_path = ''
as $$
  select g.* from public.record_access_grants g
  join public.vet_profiles v on v.user_id = g.vet_id and v.status = 'approved'
  join public.user_roles r on r.user_id = g.vet_id and r.role = 'vet'
  join public.pets p on p.id = g.pet_id
  left join public.visits vi on vi.id = g.visit_id
  where g.pet_id = p_pet
    and g.vet_id = (select auth.uid())
    and g.revoked_at is null
    and g.starts_at <= now()
    and not private.is_blocked(p.owner_id)
    and (g.expires_at > now()
         or (g.expires_at is null and vi.id is not null
             and now() < coalesce(private.visit_active_until(vi), 'infinity')))
  order by (g.source = 'visit') desc, g.expires_at desc nulls first
  limit 1;
$$;

create or replace function private.vet_can_write(p_pet uuid, p_visit uuid)
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
    join public.pets p on p.id = g.pet_id
    where g.source = 'visit'
      and g.visit_id = p_visit
      and g.pet_id = p_pet
      and g.vet_id = (select auth.uid())
      and vi.vet_id = g.vet_id and vi.pet_id = p_pet
      and vi.status in ('arrived', 'in_progress', 'completed')
      and g.revoked_at is null
      and g.starts_at <= now()
      and not private.is_blocked(p.owner_id)
      and (g.expires_at > now()
           or (g.expires_at is null
               and now() < coalesce(private.visit_active_until(vi), 'infinity'))));
$$;

create or replace function private.vet_open_slots(p_vet uuid, p_date date)
returns setof timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  with r as (select * from private.visit_rules()),
  c as (
    select distinct
      (p_date::timestamp + make_interval(mins => g.mins)) at time zone 'America/Santiago'
        as starts_at
    from r
    cross join lateral generate_series(0, 1440 - r.step_min, r.step_min) as g (mins)
    where exists (select 1 from public.vet_availability a
                  where a.vet_id = p_vet and a.weekday = extract(isodow from p_date)
                    and a.start_min <= g.mins and a.end_min >= g.mins + r.service_min)
  )
  select c.starts_at
  from c, r
  where c.starts_at >= now() + r.min_lead
    and c.starts_at <= now() + r.horizon
    and not private.is_blocked(p_vet)
    and not exists (
      select 1 from public.vet_time_off t
      where t.vet_id = p_vet
        and t.period && tstzrange(c.starts_at, c.starts_at + make_interval(mins => r.service_min)))
    and not exists (
      select 1 from public.visits v
      where v.vet_id = p_vet
        and v.status in ('pending_vet', 'accepted', 'en_route', 'arrived', 'in_progress')
        and v.slot && tstzrange(c.starts_at,
                                c.starts_at + make_interval(mins => r.service_min + r.travel_min)))
  order by c.starts_at;
$$;

create or replace function private.vet_slot_ok(p_vet uuid, p_start timestamptz)
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
    and not private.is_blocked(p_vet)
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

-- El guardián de visitas deja al job de borrado anular los vínculos personales.
create or replace function private.guard_visit()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_in_transition boolean :=
    coalesce(current_setting('felix.visit_transition', true), '') = 'on';
  v_time_travel boolean :=
    session_user = 'postgres'
    and coalesce(current_setting('felix.time_travel', true), '') = 'on';
  v_urgent_accept boolean;
  -- Fase 11: el job de borrado (sesión postgres + felix.privacy_erasure) solo
  -- puede anular los vínculos personales y el texto libre de la visita.
  v_erasure boolean :=
    session_user = 'postgres'
    and coalesce(current_setting('felix.privacy_erasure', true), '') = 'on';
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

  if v_erasure then
    if (to_jsonb(new) - array['owner_id', 'pet_id', 'address_id', 'vet_id', 'quote_id',
                              'owner_notes', 'cancel_reason', 'quote', 'updated_at'])
       = (to_jsonb(old) - array['owner_id', 'pet_id', 'address_id', 'vet_id', 'quote_id',
                                'owner_notes', 'cancel_reason', 'quote', 'updated_at'])
       and (new.owner_id is null or new.owner_id = old.owner_id)
       and (new.pet_id is null or new.pet_id = old.pet_id)
       and (new.address_id is null or new.address_id = old.address_id)
       and (new.vet_id is null or new.vet_id = old.vet_id)
       and (new.quote_id is null or new.quote_id = old.quote_id)
       and (new.owner_notes is null or new.owner_notes = old.owner_notes)
       and (new.cancel_reason is null or new.cancel_reason = old.cancel_reason)
       and (new.quote = old.quote or new.quote = old.quote - 'vet_id') then
      new.updated_at := now();
      return new;
    end if;
    raise exception 'El borrado solo anula los vínculos personales de la visita'
      using errcode = '42501';
  end if;

  v_urgent_accept := v_in_transition and old.mode = 'urgent' and old.status = 'searching'
                     and new.status = 'accepted' and old.scheduled_at is null
                     and old.vet_id is null and new.vet_id is not null;

  if (new.mode, new.commune_id, new.species_id, new.specialty_id,
      new.foundation_id, new.owner_notes, new.is_preventive, new.created_at)
     is distinct from
     (old.mode, old.commune_id, old.species_id, old.specialty_id,
      old.foundation_id, old.owner_notes, old.is_preventive, old.created_at)
     or (new.quote is distinct from old.quote and not v_urgent_accept)
     or (new.owner_id is distinct from old.owner_id and new.owner_id is not null)
     or (new.pet_id is distinct from old.pet_id and new.pet_id is not null)
     or (new.address_id is distinct from old.address_id and new.address_id is not null)
     or (new.vet_id is distinct from old.vet_id and new.vet_id is not null
         and old.vet_id is not null)
     or (new.quote_id is distinct from old.quote_id and new.quote_id is not null
         and not v_urgent_accept) then
    raise exception 'Los datos y el precio de una visita no se modifican' using errcode = '42501';
  end if;

  if (new.scheduled_at, new.slot, new.confirm_deadline)
     is distinct from (old.scheduled_at, old.slot, old.confirm_deadline)
     and not v_time_travel
     and not (v_urgent_accept and new.confirm_deadline is not distinct from old.confirm_deadline
              and new.scheduled_at is not null and lower(new.slot) = new.scheduled_at) then
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
$function$;

-- ---------------------------------------------------------------------------
-- 3. Consentimientos opcionales y versión de la política (HU8.3, HU8.4)
-- ---------------------------------------------------------------------------
-- Catálogo de finalidades opcionales (la ubicación y el servicio se basan en
-- el contrato, no en el consentimiento). Una finalidad nueva entra aquí y en
-- el check de consents.purpose, con su fecha de introducción.
create function public.consent_purposes()
returns table (purpose text, description text, introduced_at timestamptz)
language sql
immutable
security invoker
set search_path = ''
as $$
  values ('marketing'::text,
          'Comunicaciones comerciales y novedades de Felix'::text,
          '2026-11-16 00:00:00-03'::timestamptz);
$$;
grant execute on function public.consent_purposes() to anon, authenticated;

create function public.my_privacy_status()
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_current text := public.current_legal_version('privacy');
  v_last text;
  v_first timestamptz;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;
  select v.version into v_last from public.privacy_notice_views v
  where v.user_id = v_uid order by v.shown_at desc, v.id desc limit 1;
  select min(v.shown_at) into v_first from public.privacy_notice_views v
  where v.user_id = v_uid;
  return jsonb_build_object(
    'privacy_version', v_current,
    'last_seen_version', v_last,
    'must_review', v_current is not null and v_current is distinct from v_last,
    'terms_version', public.current_legal_version('terms'),
    'purposes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'purpose', p.purpose, 'description', p.description,
        'granted', c.id is not null, 'granted_at', c.granted_at,
        'last_revoked_at', (select max(h.revoked_at) from public.consents h
                            where h.user_id = v_uid and h.purpose = p.purpose),
        -- Finalidad nueva (posterior al alta) que nunca se ha respondido: pedirla.
        'ask', c.id is null and v_first is not null and p.introduced_at > v_first
               and not exists (select 1 from public.consents h
                               where h.user_id = v_uid and h.purpose = p.purpose))
        order by p.purpose)
      from public.consent_purposes() p
      left join public.consents c
        on c.user_id = v_uid and c.purpose = p.purpose and c.revoked_at is null), '[]'),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('purpose', c.purpose, 'version', c.version,
               'granted_at', c.granted_at, 'revoked_at', c.revoked_at)
             order by c.granted_at desc, c.id desc)
      from public.consents c where c.user_id = v_uid), '[]'));
end;
$$;
revoke execute on function public.my_privacy_status() from public, anon;
grant execute on function public.my_privacy_status() to authenticated;

-- Otorga o retira; retirar solo fecha la fila vigente (la historia queda).
create function public.set_consent(p_purpose text, p_granted boolean)
returns jsonb
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
  if p_granted is null
     or not exists (select 1 from public.consent_purposes() p where p.purpose = p_purpose) then
    raise exception 'Finalidad opcional desconocida' using errcode = '22023';
  end if;
  if p_granted then
    if not exists (select 1 from public.consents c
                   where c.user_id = v_uid and c.purpose = p_purpose and c.revoked_at is null) then
      insert into public.consents (user_id, purpose, version)
      values (v_uid, p_purpose, coalesce(public.current_legal_version('privacy'), 'n/a'));
    end if;
  else
    update public.consents set revoked_at = now()
    where user_id = v_uid and purpose = p_purpose and revoked_at is null;
  end if;
  return public.my_privacy_status();
end;
$$;
revoke execute on function public.set_consent(text, boolean) from public, anon;
grant execute on function public.set_consent(text, boolean) to authenticated;

-- Registra que se mostró la versión vigente (información, no consentimiento).
create function public.record_privacy_notice_view()
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_current text := public.current_legal_version('privacy');
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;
  if v_current is not null then
    insert into public.privacy_notice_views (user_id, version)
    values (v_uid, v_current)
    on conflict (user_id, version) do nothing;
  end if;
  return public.my_privacy_status();
end;
$$;
revoke execute on function public.record_privacy_notice_view() from public, anon;
grant execute on function public.record_privacy_notice_view() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Exportación (HU8.1, HU8.5)
-- ---------------------------------------------------------------------------
create function private.export_my_data()
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
                  order by d.created_at) from private.push_devices d where d.user_id = v_uid), '[]'));

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
                    'platform_fee', pa.platform_fee, 'foundation_share', pa.foundation_share,
                    'extra_donation', pa.extra_donation, 'total', pa.total,
                    'foundation', f.name, 'created_at', pa.created_at, 'paid_at', pa.paid_at)
                    order by pa.created_at)
                    from public.payments pa join public.foundations f on f.id = pa.foundation_id
                    where pa.owner_id = v_uid), '[]'));
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
                 'service_price', (vi.quote ->> 'service_price')::integer,
                 'vet_payout', (vi.quote ->> 'vet_payout')::integer)
                 order by vi.created_at)
                 from public.visits vi
                 join public.communes c on c.id = vi.commune_id
                 join public.species s on s.id = vi.species_id
                 join public.specialties sp on sp.id = vi.specialty_id
                 where vi.vet_id = v_uid), '[]'),
      -- Liquidaciones: sin el dueño, el total ni su donación (HU8.6).
      'payouts', coalesce((select jsonb_agg(jsonb_build_object('visit_id', pa.visit_id,
                 'kind', pa.kind, 'status', pa.status, 'service_price', pa.service_price,
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
                 from public.retained_entry_requests r where r.vet_id = v_uid), '[]'));
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
revoke execute on function private.export_my_data() from public, anon;
grant execute on function private.export_my_data() to authenticated;

create function public.export_my_data()
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.export_my_data();
$$;
revoke execute on function public.export_my_data() from public, anon;
grant execute on function public.export_my_data() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Solicitud de borrado, bloqueo y cancelación (HU8.2, HU8.5, P2)
-- ---------------------------------------------------------------------------
create function private.log_target(p_req uuid, p_system text, p_target text, p_action text,
  p_affected integer, p_reason text default null, p_ack boolean default true)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.deletion_targets (request_id, system, target, action, affected,
    retained_reason, ack_at, verified_at)
  values (p_req, p_system, p_target, p_action, coalesce(p_affected, 0), p_reason,
          case when p_ack then now() end, case when p_ack then now() end);
$$;
revoke execute on function private.log_target(uuid, text, text, text, integer, text, boolean)
  from public, anon, authenticated;

create function private.deletion_view(d public.deletion_requests)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when d.id is null then null else jsonb_build_object(
    'request_id', d.id, 'status', d.status, 'requested_at', d.requested_at,
    'execute_after', d.execute_after, 'cancelled_at', d.cancelled_at,
    'cancellable', d.status = 'blocked' and now() < d.execute_after) end;
$$;
revoke execute on function private.deletion_view(public.deletion_requests)
  from public, anon, authenticated;

-- Cierra lo abierto del titular sin cargo. Lo que está en atención (dueño:
-- llegó/en curso; vet: en curso) termina solo y el job espera.
create function private.close_open_activity(p_uid uuid, p_role text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v record;
  v_n integer := 0;
  v_reason constant text := 'Cuenta en proceso de eliminación (sin cargo).';
begin
  if p_role = 'owner' then
    for v in select id from public.visits
             where owner_id = p_uid
               and status in ('searching', 'pending_vet', 'accepted', 'en_route')
             for update
    loop
      perform private.apply_transition(v.id, 'cancelled_owner', p_uid, v_reason, 0);
      v_n := v_n + 1;
    end loop;
  elsif p_role = 'vet' then
    for v in select id, status from public.visits
             where vet_id = p_uid and status in ('pending_vet', 'accepted', 'en_route', 'arrived')
             for update
    loop
      perform private.apply_transition(v.id,
        case when v.status = 'pending_vet' then 'rejected' else 'cancelled_vet' end,
        p_uid, v_reason, 0);
      v_n := v_n + 1;
    end loop;
    update public.visit_offers set status = 'rejected', responded_at = now()
    where vet_id = p_uid and status = 'pending';
    update public.vet_presence set online = false, location = null, updated_at = now()
    where vet_id = p_uid;
  end if;
  return v_n;
end;
$$;
revoke execute on function private.close_open_activity(uuid, text) from public, anon, authenticated;

create function private.request_account_deletion()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
  v_n integer;
  d public.deletion_requests;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;
  select r.role into v_role from public.user_roles r where r.user_id = v_uid;
  if v_role is null or v_role = 'admin' then
    raise exception 'Esta cuenta se elimina por soporte' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('deletion:' || v_uid::text, 0));
  select * into d from public.deletion_requests
  where user_id = v_uid and status in ('blocked', 'executing');
  if not found then
    insert into public.deletion_requests (user_id, role) values (v_uid, v_role)
    returning * into d;
    perform private.log_target(d.id, 'db', 'visits abiertas (sin cargo)', 'cancel',
      private.close_open_activity(v_uid, v_role));
  end if;
  -- Revoca las sesiones: los refresh tokens dejan de servir de inmediato. El
  -- JWT vigente (hasta 1 h) queda frenado por public.check_request.
  delete from auth.refresh_tokens where user_id = v_uid::text;
  delete from auth.sessions where user_id = v_uid;
  get diagnostics v_n = row_count;
  perform private.log_target(d.id, 'auth', 'auth.sessions', 'delete', v_n);
  return private.deletion_view(d);
end;
$$;
revoke execute on function private.request_account_deletion() from public, anon;
grant execute on function private.request_account_deletion() to authenticated;

create function private.cancel_account_deletion()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  d public.deletion_requests;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;
  select * into d from public.deletion_requests
  where user_id = v_uid and status in ('blocked', 'executing') for update;
  if not found then
    raise exception 'No hay una solicitud de eliminación vigente' using errcode = '22023';
  end if;
  if d.status <> 'blocked' or now() >= d.execute_after then
    raise exception 'El período de gracia terminó: la eliminación ya está en curso'
      using errcode = '22023';
  end if;
  update public.deletion_requests set status = 'cancelled', cancelled_at = now()
  where id = d.id returning * into d;
  return private.deletion_view(d);
end;
$$;
revoke execute on function private.cancel_account_deletion() from public, anon;
grant execute on function private.cancel_account_deletion() to authenticated;

create function private.my_deletion_request()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select private.deletion_view(d) from public.deletion_requests d
  where d.user_id = (select auth.uid())
  order by d.requested_at desc limit 1;
$$;
revoke execute on function private.my_deletion_request() from public, anon;
grant execute on function private.my_deletion_request() to authenticated;

create function public.request_account_deletion()
returns jsonb language sql security invoker set search_path = ''
as $$ select private.request_account_deletion(); $$;
create function public.cancel_account_deletion()
returns jsonb language sql security invoker set search_path = ''
as $$ select private.cancel_account_deletion(); $$;
create function public.my_deletion_request()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.my_deletion_request(); $$;
revoke execute on function public.request_account_deletion() from public, anon;
revoke execute on function public.cancel_account_deletion() from public, anon;
revoke execute on function public.my_deletion_request() from public, anon;
grant execute on function public.request_account_deletion() to authenticated;
grant execute on function public.cancel_account_deletion() to authenticated;
grant execute on function public.my_deletion_request() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. PII en texto libre: patrones, redacción (M3) y escaneo
-- ---------------------------------------------------------------------------
create function private.pii_patterns()
returns table (kind text, pattern text)
language sql
immutable
set search_path = ''
as $$
  values
    ('email'::text, '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'::text),
    -- Móvil (9) o fijo de Santiago (2), con o sin +56 y separadores.
    ('phone', '(?<![0-9])(?:\+?56[ .-]?)?[29][ .-]?[0-9]{4}[ .-]?[0-9]{4}(?![0-9])'),
    ('rut', '(?<![0-9.])[0-9]{1,2}\.?[0-9]{3}\.?[0-9]{3}-[0-9kK](?![[:alnum:]])');
$$;
revoke execute on function private.pii_patterns() from public, anon, authenticated;

-- Reemplaza los términos conocidos (palabra completa, sin mayúsculas) y los
-- patrones de PII por [redactado].
create function private.redact_pii(p_text text, p_terms text[])
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := p_text;
  t text;
  p record;
begin
  if v is null then
    return null;
  end if;
  -- Primero los patrones (un nombre dentro de un email no debe romperlo).
  for p in select * from private.pii_patterns() loop
    v := regexp_replace(v, p.pattern, '[redactado]', 'g');
  end loop;
  -- Los términos más largos primero ("Ana Pérez" antes que "Ana").
  for t in select x from unnest(coalesce(p_terms, '{}')) x
           order by char_length(x) desc nulls last loop
    t := trim(t);
    if t is not null and char_length(t) >= 3 then
      v := regexp_replace(v,
        '(?<![[:alnum:]])' || regexp_replace(t, '([][\\^$.|?*+(){}])', '\\\1', 'g')
          || '(?![[:alnum:]])',
        '[redactado]', 'gi');
    end if;
  end loop;
  return v;
end;
$$;
revoke execute on function private.redact_pii(text, text[]) from public, anon, authenticated;

-- Escaneo periódico: columnas de texto de public descubiertas por catálogo,
-- salvo las que guardan contacto por diseño. Guarda solo un valor enmascarado.
create function private.run_pii_scan()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  c record;
  p record;
  v_n integer := 0;
  v_rows integer;
begin
  for c in
    select cl.relname as tbl, a.attname as col, pk.attname as pk
    from pg_class cl
    join pg_namespace n on n.oid = cl.relnamespace and n.nspname = 'public'
    join pg_attribute a on a.attrelid = cl.oid and a.attnum > 0 and not a.attisdropped
    join pg_type ty on ty.oid = a.atttypid and ty.typname in ('text', 'varchar')
    join pg_index i on i.indrelid = cl.oid and i.indisprimary and i.indnatts = 1
    join pg_attribute pk on pk.attrelid = cl.oid and pk.attnum = i.indkey[0]
    where cl.relkind = 'r'
      and (cl.relname, a.attname) not in (
        ('owner_profiles', 'phone'), ('emergency_clinics', 'phone'),
        ('emergency_clinics', 'address'), ('foundations', 'website'),
        ('addresses', 'street_text'), ('pii_scan_findings', 'masked'),
        ('vet_profiles', 'title_verification_code'))
      and cl.relname not in ('legal_versions', 'admin_audit_log')
  loop
    for p in select * from private.pii_patterns() loop
      execute format(
        'insert into public.pii_scan_findings (table_name, column_name, row_pk, kind, masked)
         select %L, %L, t.%I::text, %L,
                left(regexp_substr(t.%I, %L), 2) || ''***''
         from public.%I t where t.%I ~ %L
         on conflict (table_name, column_name, row_pk, kind) do nothing',
        c.tbl, c.col, c.pk, p.kind, c.col, p.pattern, c.tbl, c.col, p.pattern);
      get diagnostics v_rows = row_count;
      v_n := v_n + v_rows;
    end loop;
  end loop;
  return v_n;
end;
$$;
revoke execute on function private.run_pii_scan() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Escaneo de verificación: toda columna uuid/texto/json de public, private,
--    auth y storage (descubierta por catálogo, así una tabla futura no se
--    escapa) se busca por el user_id y los pet_id del titular.
-- ---------------------------------------------------------------------------
create function private.privacy_residue(p_ids uuid[])
returns table (table_name text, column_name text, hits bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c record;
  v_hits bigint;
  v_like text[] := array(select '%' || x::text || '%' from unnest(p_ids) x);
begin
  for c in
    select n.nspname as sch, cl.relname as tbl, a.attname as col, ty.typname as typ
    from pg_class cl
    join pg_namespace n on n.oid = cl.relnamespace
    join pg_attribute a on a.attrelid = cl.oid and a.attnum > 0 and not a.attisdropped
    join pg_type ty on ty.oid = a.atttypid
    where cl.relkind in ('r', 'p')
      and n.nspname in ('public', 'private', 'auth', 'storage')
      and ty.typname in ('uuid', 'text', 'varchar', 'json', 'jsonb', '_uuid')
      -- Bitácora del propio borrado y tablas del sistema sin datos de titulares.
      and (n.nspname, cl.relname) not in (
        ('public', 'deletion_requests'), ('public', 'deletion_targets'),
        ('private', 'storage_erasure_queue'), ('auth', 'schema_migrations'),
        ('storage', 'migrations'))
  loop
    if c.typ = 'uuid' then
      execute format('select count(*) from %I.%I where %I = any ($1)', c.sch, c.tbl, c.col)
        into v_hits using p_ids;
    elsif c.typ = '_uuid' then
      execute format('select count(*) from %I.%I where %I && $1', c.sch, c.tbl, c.col)
        into v_hits using p_ids;
    else
      execute format('select count(*) from %I.%I where %I::text like any ($1)',
                     c.sch, c.tbl, c.col)
        into v_hits using v_like;
    end if;
    if v_hits > 0 then
      table_name := c.sch || '.' || c.tbl;
      column_name := c.col;
      hits := v_hits;
      return next;
    end if;
  end loop;
end;
$$;
revoke execute on function private.privacy_residue(uuid[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. Job de borrado (HU8.2, HU8.5, P1, M1, M3)
-- ---------------------------------------------------------------------------

-- Fase de BD (una sola vez por solicitud, dentro de la transacción del job).
create function private.erase_subject(p_req uuid)
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
  v_t := 'public.ratings';
  if to_regclass(v_t) is not null then
    execute 'delete from public.ratings where rater_id = $1 or ratee_id = $1' using v_uid;
    get diagnostics v_n = row_count;
    perform private.log_target(p_req, 'db', 'ratings (hechas y recibidas)', 'delete', v_n);
  else
    perform private.log_target(p_req, 'db', 'ratings (hechas y recibidas)', 'delete', 0,
      'La tabla aún no existe (fase 9)');
  end if;

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
revoke execute on function private.erase_subject(uuid) from public, anon, authenticated;

-- Avanza una solicitud. Idempotente: done/cancelled no cambian; executing
-- espera a que Storage confirme y luego borra auth.users y verifica.
create function private.process_deletion(p_req uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.deletion_requests;
  v_pending integer;
  v_residue jsonb;
  v_subject uuid;
begin
  select * into d from public.deletion_requests where id = p_req for update skip locked;
  if not found or d.status not in ('blocked', 'executing') then
    return coalesce(d.status, 'locked');
  end if;
  if d.status = 'blocked' and d.execute_after > now() then
    return 'blocked';
  end if;

  perform set_config('felix.record_maintenance', 'on', true);

  if d.status = 'blocked' then
    -- Lo cancelable se cierra de nuevo; lo que está en atención se espera.
    perform private.close_open_activity(d.user_id, d.role);
    if exists (select 1 from public.visits v
               where (v.owner_id = d.user_id and v.status in ('arrived', 'in_progress'))
                  or (v.vet_id = d.user_id and v.status = 'in_progress')) then
      return 'blocked';
    end if;
    update public.deletion_requests set status = 'executing', started_at = now()
    where id = p_req;
    -- Vencida la gracia ya no se puede cancelar: tampoco iniciar sesión.
    update auth.users set banned_until = now() + interval '100 years' where id = d.user_id;
    delete from auth.refresh_tokens where user_id = d.user_id::text;
    delete from auth.sessions where user_id = d.user_id;
    perform set_config('felix.privacy_erasure', 'on', true);
    perform private.erase_subject(p_req);
    select * into d from public.deletion_requests where id = p_req;
  end if;
  perform set_config('felix.privacy_erasure', 'on', true);

  -- Storage: la Edge Function borra con la API; aquí se confirma.
  select count(*) into v_pending
  from private.storage_erasure_queue q
  join storage.objects o on o.bucket_id = q.bucket_id and o.name = q.object_name
  where q.request_id = p_req;
  if v_pending > 0 then
    return 'executing';
  end if;
  update public.deletion_targets set ack_at = now(), verified_at = now()
  where request_id = p_req and system = 'storage' and ack_at is null;
  delete from private.storage_erasure_queue where request_id = p_req;

  -- Al final, el usuario de Auth (identidades y sesiones en cascada). El uuid
  -- (opaco) queda en report solo mientras el escaneo no salga limpio.
  v_subject := coalesce(d.user_id, (d.report ->> 'subject')::uuid);
  if d.user_id is not null then
    update public.deletion_requests
    set report = coalesce(report, '{}') || jsonb_build_object('subject', d.user_id)
    where id = p_req;
    delete from auth.flow_state where user_id = d.user_id;
    delete from auth.users where id = d.user_id;
    perform private.log_target(p_req, 'auth', 'auth.users', 'delete', 1);
  end if;
  delete from auth.audit_log_entries where payload::text like '%' || v_subject::text || '%';

  select coalesce(jsonb_agg(jsonb_build_object('table', r.table_name, 'column', r.column_name,
                  'hits', r.hits)), '[]')
  into v_residue
  from private.privacy_residue(array[v_subject] || coalesce(d.subject_pet_ids, '{}')) r;
  insert into public.deletion_targets (request_id, system, target, action, affected,
    ack_at, verified_at, detail)
  values (p_req, 'db', 'verification_scan', 'verify', jsonb_array_length(v_residue), now(),
          case when v_residue = '[]' then now() end, v_residue);

  if v_residue <> '[]' then
    -- Queda en executing (el admin ve el detalle) y el job reintenta.
    update public.deletion_requests
    set report = coalesce(report, '{}') || jsonb_build_object('residue', v_residue)
    where id = p_req;
    return 'executing';
  end if;

  update public.deletion_requests
  set status = 'done', completed_at = now(), user_id = null, subject_pet_ids = null,
      report = jsonb_build_object(
        'deleted', (select coalesce(sum(t.affected), 0) from public.deletion_targets t
                    where t.request_id = p_req and t.action = 'delete'),
        'anonymized', (select coalesce(sum(t.affected), 0) from public.deletion_targets t
                       where t.request_id = p_req and t.action = 'anonymize'),
        'retained', (select coalesce(sum(t.affected), 0) from public.deletion_targets t
                     where t.request_id = p_req and t.action = 'retain'),
        'scan', 'clean')
  where id = p_req;
  return 'done';
end;
$$;
revoke execute on function private.process_deletion(uuid) from public, anon, authenticated;

create function private.run_account_deletions(p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_out jsonb := '{}';
  v_status text;
begin
  for r in
    select d.id from public.deletion_requests d
    where d.status = 'executing'
       or (d.status = 'blocked' and d.execute_after <= now())
    order by d.execute_after
    limit least(greatest(coalesce(p_limit, 20), 1), 200)
  loop
    v_status := private.process_deletion(r.id);
    v_out := v_out || jsonb_build_object(v_status,
               coalesce((v_out ->> v_status)::integer, 0) + 1);
  end loop;
  return v_out;
end;
$$;
revoke execute on function private.run_account_deletions(integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 9. Storage: candidatos para la Edge Function (solo service_role)
-- ---------------------------------------------------------------------------
create function private.privacy_storage_due(p_limit integer default 100)
returns table (bucket_id text, name text, reason text)
language sql
stable
security definer
set search_path = ''
as $$
  (select q.bucket_id, q.object_name, 'erasure'::text
   from private.storage_erasure_queue q
   join storage.objects o on o.bucket_id = q.bucket_id and o.name = q.object_name
   order by q.id)
  union all
  -- M2: adjuntos subidos sin fila en entry_attachments por más de 24 h.
  (select o.bucket_id, o.name, 'orphan'::text
   from storage.objects o
   where o.bucket_id = 'clinical-attachments'
     and o.created_at < now() - interval '24 hours'
     and not exists (select 1 from public.entry_attachments a where a.storage_path = o.name)
     and not exists (select 1 from private.storage_erasure_queue q
                     where q.bucket_id = o.bucket_id and q.object_name = o.name))
  limit least(greatest(coalesce(p_limit, 100), 1), 1000);
$$;
revoke execute on function private.privacy_storage_due(integer) from public, anon, authenticated;
grant execute on function private.privacy_storage_due(integer) to service_role;

create function public.privacy_storage_candidates(p_limit integer default 100)
returns table (bucket_id text, name text, reason text)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.privacy_storage_due(p_limit);
$$;
revoke execute on function public.privacy_storage_candidates(integer) from public, anon, authenticated;
grant execute on function public.privacy_storage_candidates(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 10. Entradas retenidas: acceso del vet autor con solicitud registrada (P1)
-- ---------------------------------------------------------------------------
create function private.list_my_retained_entries()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('id', e.id, 'created_at', e.created_at, 'kind', e.kind,
           'species', s.name, 'retain_until', e.retain_until)
  from public.clinical_entries e
  join public.species s on s.id = e.species_id
  where e.author_id = (select auth.uid()) and e.author_role = 'vet'
    and e.pet_id is null and e.retain_until > now()
    and (select private.current_app_role()) = 'vet'
  order by e.created_at desc;
$$;
revoke execute on function private.list_my_retained_entries() from public, anon;
grant execute on function private.list_my_retained_entries() to authenticated;

create function private.request_retained_entry(p_entry_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  e public.clinical_entries;
begin
  select * into e from public.clinical_entries c
  where c.id = p_entry_id and c.author_id = v_uid and c.author_role = 'vet'
    and c.pet_id is null and c.retain_until > now()
    and (select private.current_app_role()) = 'vet';
  if v_uid is null or not found then
    raise exception 'No tienes acceso a esa entrada' using errcode = '42501';
  end if;
  if p_reason is null or char_length(trim(p_reason)) not between 10 and 500 then
    raise exception 'Indica el motivo de la consulta (10 a 500 caracteres)' using errcode = '22023';
  end if;
  insert into public.retained_entry_requests (entry_id, vet_id, reason)
  values (e.id, v_uid, trim(p_reason));
  return jsonb_build_object('id', e.id, 'created_at', e.created_at, 'kind', e.kind,
    'species', (select s.name from public.species s where s.id = e.species_id),
    'specialty', (select s.name from public.specialties s where s.id = e.specialty_id),
    'title', e.title, 'body', e.body, 'retain_until', e.retain_until,
    'vaccine', (select jsonb_build_object('vaccine_name', v.vaccine_name, 'lot', v.lot,
                  'applied_on', v.applied_on, 'next_due', v.next_due)
                from public.clinical_vaccines v where v.entry_id = e.id));
end;
$$;
revoke execute on function private.request_retained_entry(uuid, text) from public, anon;
grant execute on function private.request_retained_entry(uuid, text) to authenticated;

create function public.list_my_retained_entries()
returns setof jsonb language sql stable security invoker set search_path = ''
as $$ select * from private.list_my_retained_entries(); $$;
create function public.request_retained_entry(p_entry_id uuid, p_reason text)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.request_retained_entry(p_entry_id, p_reason); $$;
revoke execute on function public.list_my_retained_entries() from public, anon;
revoke execute on function public.request_retained_entry(uuid, text) from public, anon;
grant execute on function public.list_my_retained_entries() to authenticated;
grant execute on function public.request_retained_entry(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. Retención (arquitectura §8)
-- ---------------------------------------------------------------------------
create function private.run_privacy_retention()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expired integer;
  v_log integer;
  v_tokens integer;
begin
  perform set_config('felix.record_maintenance', 'on', true);
  -- Entradas retenidas (P1) al vencer retain_until.
  delete from public.clinical_entries where pet_id is null and retain_until <= now();
  get diagnostics v_expired = row_count;
  -- record_access_log: más de 2 años → sin actor.
  update public.record_access_log set actor_id = null
  where actor_id is not null and at < now() - interval '2 years';
  get diagnostics v_log = row_count;
  -- Tokens push sin uso en 90 días.
  delete from private.push_devices where last_seen_at < now() - interval '90 days';
  get diagnostics v_tokens = row_count;
  perform set_config('felix.record_maintenance', 'off', true);
  return jsonb_build_object('retained_entries_deleted', v_expired,
    'access_log_anonymized', v_log, 'push_tokens_deleted', v_tokens);
end;
$$;
revoke execute on function private.run_privacy_retention() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 12. pg_cron
-- ---------------------------------------------------------------------------
select cron.schedule('privacy-deletions', '*/10 * * * *',
  'select private.run_account_deletions()');
select cron.schedule('privacy-retention', '41 3 * * *',
  'select private.run_privacy_retention()');
select cron.schedule('pii-scan', '53 4 * * *', 'select private.run_pii_scan()');
-- Storage (borrado y huérfanos de la ficha) vía Edge Function, solo si hay
-- candidatos y existen los secretos de Vault.
select cron.schedule(
  'purge-privacy-storage',
  '*/10 * * * *',
  $cron$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/purge-privacy-storage',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' ||
        (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000)
  where exists (select 1 from private.privacy_storage_due(1))
    and exists (select 1 from vault.decrypted_secrets where name = 'project_url')
    and exists (select 1 from vault.decrypted_secrets where name = 'service_role_key');
  $cron$
);
