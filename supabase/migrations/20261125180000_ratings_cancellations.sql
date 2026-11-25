-- Fase 9: calificaciones y cancelaciones (SPEC F7, HU7.1 a HU7.4;
-- docs/arquitectura.md §4, §6 y "Fase 9").
--
-- Decisiones:
-- * Publicación diferida POR CONSULTA (sin pg_cron): una calificación es
--   visible para la contraparte desde `coalesce(published_at, completed_at +
--   168 h)`. `rate_visit` fija `published_at = now()` en ambas filas cuando
--   califica el segundo participante. Así no hay desfase entre corridas de un
--   job y la regla se prueba moviendo solo `visits.completed_at`.
-- * Las ventanas se miden en horas (168 h / 720 h), no en días, para que el
--   cambio de horario de Chile no las alargue ni acorte una hora.
-- * `hidden` oculta el COMENTARIO (SPEC: "el admin puede ocultar
--   comentarios"): las estrellas siguen visibles y cuentan en el promedio.
-- * `rating_avg` y `cancel_count_30d` se calculan al consultar (no son
--   columnas de `vet_profiles`): dependen del reloj y una columna quedaría
--   desactualizada sin un job.
-- * Promedio del vet: solo calificaciones publicadas del dueño hacia el vet,
--   sin las de cuentas bloqueadas. Con menos de 3 el promedio es nulo y el
--   despacho usa 3,0 (neutro).
-- * Cancelaciones del vet: cuentan las `cancelled_vet` decididas por el vet y
--   las que cerró el sistema por no marcar "en camino" o no avanzar (también
--   son incumplimiento: SPEC "baja su tasa de cumplimiento"). Ventana móvil de
--   720 h por `closed_at`. Con 3 o más hay una alerta abierta por vet.

-- ---------------------------------------------------------------------------
-- 1. Reglas
-- ---------------------------------------------------------------------------
create function private.rating_rules()
returns table (rating_window interval, min_ratings integer, neutral_rating numeric,
               cancel_window interval, cancel_alert_at integer)
language sql
immutable
set search_path = ''
as $$
  select interval '168 hours', 3, 3.0::numeric, interval '720 hours', 3;
$$;
revoke execute on function private.rating_rules() from public, anon, authenticated;

-- Momento desde el que la contraparte ve una calificación.
create function private.rating_public_at(p_published_at timestamptz, p_completed_at timestamptz)
returns timestamptz
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_published_at,
                  p_completed_at + (select r.rating_window from private.rating_rules() r));
$$;
revoke execute on function private.rating_public_at(timestamptz, timestamptz)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Tablas (sin acceso directo: solo RPC)
-- ---------------------------------------------------------------------------
create table public.ratings (
  id uuid primary key default gen_random_uuid(),
  visit_id uuid not null references public.visits (id) on delete cascade,
  rater_id uuid not null references auth.users (id) on delete cascade,
  ratee_id uuid not null references auth.users (id) on delete cascade,
  rater_role text not null check (rater_role in ('owner', 'vet')),
  stars smallint not null check (stars between 1 and 5),
  comment text check (comment is null or char_length(comment) between 1 and 500),
  hidden boolean not null default false,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  constraint ratings_one_per_rater unique (visit_id, rater_id),
  constraint ratings_not_self check (rater_id <> ratee_id)
);
create index ratings_ratee_idx on public.ratings (ratee_id, rater_role);
create index ratings_rater_idx on public.ratings (rater_id);

alter table public.ratings enable row level security;
alter table public.ratings force row level security;
revoke all on public.ratings from public, anon, authenticated;

-- El admin oculta comentarios: queda en admin_audit_log.
create trigger ratings_audit after update on public.ratings
for each row execute function private.log_admin_change();

create table public.vet_cancel_alerts (
  id uuid primary key default gen_random_uuid(),
  vet_id uuid not null references public.vet_profiles (user_id) on delete cascade,
  cancel_count integer not null check (cancel_count > 0),
  first_cancel_at timestamptz not null,
  last_cancel_at timestamptz not null,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users (id) on delete set null
);
-- Una sola alerta abierta por vet.
create unique index vet_cancel_alerts_open_uq on public.vet_cancel_alerts (vet_id)
  where reviewed_at is null;
create index vet_cancel_alerts_vet_idx on public.vet_cancel_alerts (vet_id, created_at desc);
create index vet_cancel_alerts_reviewed_by_idx on public.vet_cancel_alerts (reviewed_by);

alter table public.vet_cancel_alerts enable row level security;
alter table public.vet_cancel_alerts force row level security;
revoke all on public.vet_cancel_alerts from public, anon, authenticated;

create trigger vet_cancel_alerts_audit after update on public.vet_cancel_alerts
for each row execute function private.log_admin_change();

create index visits_vet_cancelled_idx on public.visits (vet_id, closed_at)
  where status = 'cancelled_vet';

-- ---------------------------------------------------------------------------
-- 3. Promedios y despacho
-- ---------------------------------------------------------------------------
create function private.rating_stats(p_ratee uuid, p_rater_role text)
returns table (rating_avg numeric, rating_count integer)
language sql
stable
security definer
set search_path = ''
as $$
  select case when count(*) >= (select r.min_ratings from private.rating_rules() r)
              then round(avg(x.stars), 2) end,
         count(*)::integer
  from public.ratings x
  join public.visits v on v.id = x.visit_id
  where x.ratee_id = p_ratee and x.rater_role = p_rater_role
    and private.rating_public_at(x.published_at, v.completed_at) <= now()
    and not private.is_blocked(x.rater_id);
$$;
revoke execute on function private.rating_stats(uuid, text) from public, anon, authenticated;

-- Fase 9: reemplaza el 3,0 fijo de la fase 8 por el promedio publicado
-- (neutro mientras haya menos de 3). Solo el valor agregado entra al orden.
create or replace function private.vet_dispatch_rating(p_vet uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select case when p_vet is null then null
    else coalesce((select s.rating_avg from private.rating_stats(p_vet, 'owner') s),
                  (select r.neutral_rating from private.rating_rules() r)) end;
$$;
revoke execute on function private.vet_dispatch_rating(uuid) from public, anon, authenticated;

create function private.vet_cancel_count_30d(p_vet uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer from public.visits v
  where v.vet_id = p_vet and v.status = 'cancelled_vet'
    and v.closed_at > now() - (select r.cancel_window from private.rating_rules() r);
$$;
revoke execute on function private.vet_cancel_count_30d(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Alerta de cancelaciones (HU7.4)
-- ---------------------------------------------------------------------------
create function private.track_vet_cancel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
  v_first timestamptz;
begin
  -- Una cuenta bloqueada no se trata (sus visitas se cancelan al pedir el borrado).
  if new.vet_id is null or private.is_blocked(new.vet_id) then
    return null;
  end if;
  select count(*)::integer, min(v.closed_at) into v_n, v_first
  from public.visits v
  where v.vet_id = new.vet_id and v.status = 'cancelled_vet'
    and v.closed_at > now() - (select r.cancel_window from private.rating_rules() r);
  if v_n >= (select r.cancel_alert_at from private.rating_rules() r) then
    insert into public.vet_cancel_alerts (vet_id, cancel_count, first_cancel_at, last_cancel_at)
    values (new.vet_id, v_n, v_first, coalesce(new.closed_at, now()))
    on conflict (vet_id) where reviewed_at is null
    do update set cancel_count = excluded.cancel_count,
                  first_cancel_at = excluded.first_cancel_at,
                  last_cancel_at = excluded.last_cancel_at;
  end if;
  return null;
end;
$$;
revoke execute on function private.track_vet_cancel() from public, anon, authenticated;

create trigger visits_vet_cancel_alert
after update of status on public.visits
for each row
when (new.status = 'cancelled_vet' and old.status is distinct from new.status)
execute function private.track_vet_cancel();

-- ---------------------------------------------------------------------------
-- 5. RPC de calificaciones (HU7.1 y HU7.2)
-- ---------------------------------------------------------------------------

-- Estado de la calificación de una visita para uno de sus participantes.
create function private.rating_status_json(v public.visits, p_uid uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with ctx as (
    select case when p_uid = v.owner_id then 'owner' else 'vet' end as my_role,
           case when p_uid = v.owner_id then v.vet_id else v.owner_id end as other,
           case when v.status = 'completed' and v.completed_at is not null
                then v.completed_at + (select r.rating_window from private.rating_rules() r)
           end as rate_until
  )
  select jsonb_build_object(
    'visit_id', v.id,
    'my_role', c.my_role,
    'rate_until', c.rate_until,
    'can_rate', c.rate_until is not null and now() < c.rate_until and c.other is not null
                and not private.is_blocked(p_uid) and not private.is_blocked(c.other)
                and not exists (select 1 from public.ratings x
                                where x.visit_id = v.id and x.rater_id = p_uid),
    'mine', (select jsonb_build_object('stars', x.stars, 'comment', x.comment,
                      'hidden', x.hidden, 'created_at', x.created_at,
                      'publishes_at', private.rating_public_at(x.published_at, v.completed_at))
             from public.ratings x where x.visit_id = v.id and x.rater_id = p_uid),
    'theirs', (select jsonb_build_object('stars', x.stars,
                        'comment', case when x.hidden then null else x.comment end,
                        'comment_hidden', x.hidden,
                        'published_at', private.rating_public_at(x.published_at, v.completed_at))
               from public.ratings x
               where x.visit_id = v.id and x.rater_id = c.other and x.ratee_id = p_uid
                 and private.rating_public_at(x.published_at, v.completed_at) <= now()
                 and not private.is_blocked(x.rater_id)))
  from ctx c;
$$;
revoke execute on function private.rating_status_json(public.visits, uuid)
  from public, anon, authenticated;

create function private.visit_rating_status(p_visit_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v public.visits;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;
  select * into v from public.visits where id = p_visit_id;
  if v.id is null or (v_uid is distinct from v.owner_id and v_uid is distinct from v.vet_id) then
    raise exception 'No participaste en esta visita' using errcode = '42501';
  end if;
  return private.rating_status_json(v, v_uid);
end;
$$;
revoke execute on function private.visit_rating_status(uuid) from public, anon;
grant execute on function private.visit_rating_status(uuid) to authenticated;

create function private.rate_visit(p_visit_id uuid, p_stars integer, p_comment text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v public.visits;
  v_role text;
  v_ratee uuid;
  v_comment text := nullif(btrim(p_comment), '');
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;
  -- Bloquea la visita: si ambos califican a la vez, el segundo ve al primero
  -- y publica las dos.
  select * into v from public.visits where id = p_visit_id for update;
  if v.id is null or (v_uid is distinct from v.owner_id and v_uid is distinct from v.vet_id) then
    raise exception 'No participaste en esta visita' using errcode = '42501';
  end if;
  v_role := case when v_uid = v.owner_id then 'owner' else 'vet' end;
  v_ratee := case when v_role = 'owner' then v.vet_id else v.owner_id end;
  if private.is_blocked(v_uid) then
    raise exception 'Tu cuenta está bloqueada por una solicitud de eliminación'
      using errcode = '42501', hint = 'account_blocked';
  end if;
  -- La otra parte bloqueada no es MI bloqueo: 22023 (HTTP 400) y otro hint,
  -- para que AccountBlockedHttpClient no lleve al usuario a /account-blocked.
  if private.is_blocked(v_ratee) then
    raise exception 'La otra cuenta tiene una solicitud de eliminación: no se puede calificar'
      using errcode = '22023', hint = 'counterpart_blocked';
  end if;
  if v.status <> 'completed' or v.completed_at is null or v_ratee is null then
    raise exception 'Solo se califican visitas completadas' using errcode = '22023';
  end if;
  if now() >= v.completed_at + (select r.rating_window from private.rating_rules() r) then
    raise exception 'El plazo para calificar venció (7 días)' using errcode = '22023';
  end if;
  if p_stars is null or p_stars not between 1 and 5 then
    raise exception 'La calificación va de 1 a 5 estrellas' using errcode = '22023';
  end if;
  if char_length(v_comment) > 500 then
    raise exception 'El comentario admite hasta 500 caracteres' using errcode = '22023';
  end if;
  if exists (select 1 from public.ratings x where x.visit_id = v.id and x.rater_id = v_uid) then
    raise exception 'Ya calificaste esta visita' using errcode = '23505';
  end if;

  insert into public.ratings (visit_id, rater_id, ratee_id, rater_role, stars, comment)
  values (v.id, v_uid, v_ratee, v_role, p_stars, v_comment);

  -- Ambos calificaron: se publican las dos.
  if exists (select 1 from public.ratings x where x.visit_id = v.id and x.rater_id = v_ratee) then
    update public.ratings set published_at = now()
    where visit_id = v.id and published_at is null;
  end if;
  return private.rating_status_json(v, v_uid);
end;
$$;
revoke execute on function private.rate_visit(uuid, integer, text) from public, anon;
grant execute on function private.rate_visit(uuid, integer, text) to authenticated;

-- Calificaciones recibidas y publicadas (sin quién las hizo).
create function private.my_ratings_received(p_limit integer)
returns table (visit_id uuid, rater_role text, stars smallint, comment text,
               comment_hidden boolean, published_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select x.visit_id, x.rater_role, x.stars,
         case when x.hidden then null else x.comment end, x.hidden,
         private.rating_public_at(x.published_at, v.completed_at)
  from public.ratings x
  join public.visits v on v.id = x.visit_id
  where x.ratee_id = (select auth.uid())
    and private.rating_public_at(x.published_at, v.completed_at) <= now()
    and not private.is_blocked(x.rater_id)
  order by 6 desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;
revoke execute on function private.my_ratings_received(integer) from public, anon;
grant execute on function private.my_ratings_received(integer) to authenticated;

-- Resumen propio: promedio recibido y, si es vet, cancelaciones en 30 días.
create function private.my_rating_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_role text;
  s record;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '28000';
  end if;
  select r.role into v_role from public.user_roles r where r.user_id = v_uid;
  select * into s from private.rating_stats(v_uid,
    case when v_role = 'vet' then 'owner' else 'vet' end);
  return jsonb_build_object(
    'rating_avg', s.rating_avg, 'rating_count', s.rating_count,
    'min_ratings', (select r.min_ratings from private.rating_rules() r),
    'cancel_count_30d', case when v_role = 'vet' then private.vet_cancel_count_30d(v_uid) end);
end;
$$;
revoke execute on function private.my_rating_summary() from public, anon;
grant execute on function private.my_rating_summary() to authenticated;

-- Promedio público de un vet aprobado (solo el agregado).
create function private.vet_rating_summary(p_vet_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('vet_id', p.user_id, 'rating_avg', s.rating_avg,
                            'rating_count', s.rating_count)
  from public.vet_profiles p
  cross join lateral private.rating_stats(p.user_id, 'owner') s
  where p.user_id = p_vet_id and p.status = 'approved' and not private.is_blocked(p.user_id)
    and (select auth.uid()) is not null;
$$;
revoke execute on function private.vet_rating_summary(uuid) from public, anon;
grant execute on function private.vet_rating_summary(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. RPC del admin (moderación y alertas)
-- ---------------------------------------------------------------------------
create function private.admin_list_ratings(p_limit integer)
returns table (id uuid, visit_id uuid, rater_id uuid, ratee_id uuid, rater_role text,
               stars smallint, comment text, hidden boolean, created_at timestamptz,
               publishes_at timestamptz, published boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not coalesce((select private.is_admin()), false) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  return query
  select x.id, x.visit_id, x.rater_id, x.ratee_id, x.rater_role, x.stars, x.comment, x.hidden,
         x.created_at, private.rating_public_at(x.published_at, v.completed_at),
         private.rating_public_at(x.published_at, v.completed_at) <= now()
  from public.ratings x
  join public.visits v on v.id = x.visit_id
  where not private.is_blocked(x.rater_id) and not private.is_blocked(x.ratee_id)
  order by x.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end;
$$;
revoke execute on function private.admin_list_ratings(integer) from public, anon;
grant execute on function private.admin_list_ratings(integer) to authenticated;

create function private.admin_set_rating_hidden(p_rating_id uuid, p_hidden boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  x public.ratings;
begin
  if not coalesce((select private.is_admin()), false) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  select * into x from public.ratings where id = p_rating_id for update;
  if x.id is null then
    raise exception 'Calificación no encontrada' using errcode = '22023';
  end if;
  perform private.assert_subject_not_blocked(x.rater_id);
  perform private.assert_subject_not_blocked(x.ratee_id);
  if x.hidden is distinct from coalesce(p_hidden, true) then
    update public.ratings set hidden = coalesce(p_hidden, true) where id = x.id
    returning * into x;
  end if;
  return jsonb_build_object('id', x.id, 'hidden', x.hidden);
end;
$$;
revoke execute on function private.admin_set_rating_hidden(uuid, boolean) from public, anon;
grant execute on function private.admin_set_rating_hidden(uuid, boolean) to authenticated;

create function private.admin_list_cancel_alerts(p_include_reviewed boolean)
returns table (id uuid, vet_id uuid, vet_name text, cancel_count integer,
               cancel_count_30d integer, first_cancel_at timestamptz,
               last_cancel_at timestamptz, created_at timestamptz, reviewed_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not coalesce((select private.is_admin()), false) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  return query
  select a.id, a.vet_id, p.display_name, a.cancel_count, private.vet_cancel_count_30d(a.vet_id),
         a.first_cancel_at, a.last_cancel_at, a.created_at, a.reviewed_at
  from public.vet_cancel_alerts a
  join public.vet_profiles p on p.user_id = a.vet_id
  where (coalesce(p_include_reviewed, false) or a.reviewed_at is null)
    and not private.is_blocked(a.vet_id)
  order by a.reviewed_at is not null, a.last_cancel_at desc;
end;
$$;
revoke execute on function private.admin_list_cancel_alerts(boolean) from public, anon;
grant execute on function private.admin_list_cancel_alerts(boolean) to authenticated;

create function private.admin_review_cancel_alert(p_alert_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  a public.vet_cancel_alerts;
begin
  if not coalesce((select private.is_admin()), false) then
    raise exception 'Solo el administrador' using errcode = '42501';
  end if;
  select * into a from public.vet_cancel_alerts where id = p_alert_id for update;
  if a.id is null then
    raise exception 'Alerta no encontrada' using errcode = '22023';
  end if;
  perform private.assert_subject_not_blocked(a.vet_id);
  if a.reviewed_at is null then
    update public.vet_cancel_alerts
    set reviewed_at = now(), reviewed_by = (select auth.uid())
    where id = a.id returning * into a;
  end if;
  return jsonb_build_object('id', a.id, 'vet_id', a.vet_id, 'reviewed_at', a.reviewed_at);
end;
$$;
revoke execute on function private.admin_review_cancel_alert(uuid) from public, anon;
grant execute on function private.admin_review_cancel_alert(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Envoltorios públicos (SECURITY INVOKER)
-- ---------------------------------------------------------------------------
create function public.rate_visit(p_visit_id uuid, p_stars integer, p_comment text default null)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.rate_visit(p_visit_id, p_stars, p_comment); $$;

create function public.visit_rating_status(p_visit_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.visit_rating_status(p_visit_id); $$;

create function public.my_ratings_received(p_limit integer default 50)
returns table (visit_id uuid, rater_role text, stars smallint, comment text,
               comment_hidden boolean, published_at timestamptz)
language sql stable security invoker set search_path = ''
as $$ select * from private.my_ratings_received(p_limit); $$;

create function public.my_rating_summary()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.my_rating_summary(); $$;

create function public.vet_rating_summary(p_vet_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.vet_rating_summary(p_vet_id); $$;

create function public.admin_list_ratings(p_limit integer default 100)
returns table (id uuid, visit_id uuid, rater_id uuid, ratee_id uuid, rater_role text,
               stars smallint, comment text, hidden boolean, created_at timestamptz,
               publishes_at timestamptz, published boolean)
language sql stable security invoker set search_path = ''
as $$ select * from private.admin_list_ratings(p_limit); $$;

create function public.admin_set_rating_hidden(p_rating_id uuid, p_hidden boolean default true)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.admin_set_rating_hidden(p_rating_id, p_hidden); $$;

create function public.admin_list_cancel_alerts(p_include_reviewed boolean default false)
returns table (id uuid, vet_id uuid, vet_name text, cancel_count integer,
               cancel_count_30d integer, first_cancel_at timestamptz,
               last_cancel_at timestamptz, created_at timestamptz, reviewed_at timestamptz)
language sql stable security invoker set search_path = ''
as $$ select * from private.admin_list_cancel_alerts(p_include_reviewed); $$;

create function public.admin_review_cancel_alert(p_alert_id uuid)
returns jsonb language sql volatile security invoker set search_path = ''
as $$ select private.admin_review_cancel_alert(p_alert_id); $$;

revoke execute on function public.rate_visit(uuid, integer, text), public.visit_rating_status(uuid),
  public.my_ratings_received(integer), public.my_rating_summary(), public.vet_rating_summary(uuid),
  public.admin_list_ratings(integer), public.admin_set_rating_hidden(uuid, boolean),
  public.admin_list_cancel_alerts(boolean), public.admin_review_cancel_alert(uuid)
  from public, anon;
grant execute on function public.rate_visit(uuid, integer, text), public.visit_rating_status(uuid),
  public.my_ratings_received(integer), public.my_rating_summary(), public.vet_rating_summary(uuid),
  public.admin_list_ratings(integer), public.admin_set_rating_hidden(uuid, boolean),
  public.admin_list_cancel_alerts(boolean), public.admin_review_cancel_alert(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Privacidad: exportación y borrado (arquitectura §8.2)
-- ---------------------------------------------------------------------------
-- Igual que en 20261125005641_privacy_rights.sql, más las calificaciones y las alertas.
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
revoke execute on function private.export_my_data() from public, anon;
grant execute on function private.export_my_data() to authenticated;

-- Igual que en 20261125005641_privacy_rights.sql; borra las calificaciones (hechas y
-- recibidas) con un paso fijo y las alertas del vet antes de su perfil.
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
revoke execute on function private.erase_subject(uuid) from public, anon, authenticated;
