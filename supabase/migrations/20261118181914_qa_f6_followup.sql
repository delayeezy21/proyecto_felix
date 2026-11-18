-- Seguimiento de QA fase 6 (docs/qa/QA-680e21c.md).
--
-- QA-F6-07 (Medio): la preselección de 30 vets por KNN no descontaba días
--   libres ni agendas llenas: con 30 vets cercanos de día libre y uno libre
--   más lejos, available_vets devolvía 0. Ahora:
--   * se excluyen de los candidatos los vets con un día libre que cubre todo
--     el día pedido (o sin horario semanal ese día);
--   * los candidatos se ordenan por distancia (KNN sobre quote_origin) y se
--     recorren en bloques de 40 (horarios en una consulta por bloque) hasta
--     reunir 20 con horario libre o agotar el radio: nunca se descarta un vet
--     libre por estar fuera del primer bloque.
-- QA-F6-06 (Bajo): una visita in_progress que nunca se completa quedaba
--   abierta y el vet seguía viendo la dirección exacta y el teléfono.
--   Decisión: expire_visits la cierra como `completed` (borde existente
--   in_progress → completed, actor nulo = sistema) cuando pasan 6 h desde el
--   inicio o 8 h desde la hora agendada, lo primero. La atención sí ocurrió
--   (el vet la inició), así que el desenlace coherente es "completada": el
--   cobro no es automático; el dueño paga (simulado) desde la app como en
--   cualquier visita completada. Además, visit_view deja de entregar `exact`
--   en cuanto vence la ventana activa de cada estado, aunque el cron aún no
--   haya cerrado la visita.

-- ---------------------------------------------------------------------------
-- Ventana activa por estado (misma regla para el cron y para la vista)
-- ---------------------------------------------------------------------------
create function private.visit_progress_limits()
returns table (max_service interval, max_after_schedule interval)
language sql
immutable
set search_path = ''
as $$
  select interval '6 hours', interval '8 hours';
$$;
revoke execute on function private.visit_progress_limits() from public, anon, authenticated;

-- Hasta cuándo una visita abierta se considera activa (null = sin límite
-- calculable, p. ej. urgencias sin hora). Coincide con los cierres de
-- expire_visits: accepted (hora + 1 h), en_route/arrived (hora + 2 h),
-- in_progress (inicio + 6 h u hora + 8 h, lo primero).
create function private.visit_active_until(v public.visits)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select case v.status
    when 'accepted' then v.scheduled_at + (select r.no_show_after from private.visit_rules() r)
    when 'en_route' then v.scheduled_at + (select t.stale_after from private.visit_timing() t)
    when 'arrived' then v.scheduled_at + (select t.stale_after from private.visit_timing() t)
    when 'in_progress' then least(
      v.started_at + (select l.max_service from private.visit_progress_limits() l),
      v.scheduled_at + (select l.max_after_schedule from private.visit_progress_limits() l))
  end;
$$;
revoke execute on function private.visit_active_until(public.visits) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- QA-F6-06: exact solo dentro de la ventana activa
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
      'cancel_reason', v.cancel_reason,
      'service_price', (v.quote ->> 'service_price')::integer,
      'vet_payout', (v.quote ->> 'vet_payout')::integer,
      'pet_name', p.name, 'species_name', sp.name, 'specialty_name', s.name,
      'commune_name', coalesce(ap.commune_name, c.name),
      -- R-1: la distancia sale siempre del origen aproximado (quote_origin).
      'distance_km', coalesce((v.quote ->> 'distance_km')::numeric, ap.distance_km_rounded),
      'paid', exists (select 1 from public.payments pay where pay.visit_id = v.id
                      and pay.kind = 'visit' and pay.status = 'simulated_paid'),
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
  left join lateral private.address_approx(v.address_id, b.quote_origin) ap
    on v.vet_id = p_uid and b.vet_id is not null;
$$;

-- ---------------------------------------------------------------------------
-- QA-F6-06: cierre automático de "en curso" que nunca se completa
-- ---------------------------------------------------------------------------
create or replace function private.expire_visits()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  r record;
  t record;
  l record;
  v_id uuid;
  v_n integer := 0;
begin
  select * into r from private.visit_rules();
  select * into t from private.visit_timing();
  select * into l from private.visit_progress_limits();
  for v_id in
    select v.id from public.visits v
    where v.status = 'pending_vet' and v.confirm_deadline <= now()
    order by v.confirm_deadline
    limit 500
    for update skip locked
  loop
    perform private.apply_transition(v_id, 'expired', null, null, 0);
    v_n := v_n + 1;
  end loop;
  for v_id in
    select v.id from public.visits v
    where v.status = 'accepted' and v.scheduled_at + r.no_show_after <= now()
    order by v.scheduled_at
    limit 500
    for update skip locked
  loop
    perform private.apply_transition(v_id, 'cancelled_vet', null,
      'El veterinario no inició la visita a tiempo (cierre automático).', 0);
    v_n := v_n + 1;
  end loop;
  for v_id in
    select v.id from public.visits v
    where v.status in ('en_route', 'arrived') and v.scheduled_at + t.stale_after <= now()
    order by v.scheduled_at
    limit 500
    for update skip locked
  loop
    perform private.apply_transition(v_id, 'cancelled_vet', null,
      'La atención no comenzó a tiempo (cierre automático, sin cargo).', 0);
    v_n := v_n + 1;
  end loop;
  for v_id in
    select v.id from public.visits v
    where v.status = 'in_progress'
      and (v.started_at + l.max_service <= now()
           or v.scheduled_at + l.max_after_schedule <= now())
    order by v.scheduled_at
    limit 500
    for update skip locked
  loop
    perform private.apply_transition(v_id, 'completed', null, null, 0);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create index visits_in_progress_idx on public.visits (scheduled_at)
  where status = 'in_progress';

-- ---------------------------------------------------------------------------
-- QA-F6-07: candidatos por distancia sin días libres y sin bloque fijo
-- ---------------------------------------------------------------------------
create or replace function private.find_available_vets(
  p_pet_id uuid, p_address_id uuid, p_specialty_id integer, p_date date)
returns setof jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_species integer;
  v_location extensions.geography;
  v_today date := (now() at time zone 'America/Santiago')::date;
  v_max_km integer := (select c.max_distance_km from public.current_pricing_config() c);
  v_day tstzrange;
  v_calls integer;
  v_found integer := 0;
  v_ids uuid[];
  v_n integer;
  v_from integer;
  v_rows integer;
begin
  if v_uid is null or (select private.current_app_role()) is distinct from 'owner' then
    raise exception 'Solo un dueño puede buscar veterinarios' using errcode = '42501';
  end if;

  -- Tope: 30 búsquedas por dueño y minuto (serializado por dueño).
  perform pg_advisory_xact_lock(hashtextextended('available_vets:' || v_uid::text, 0));
  insert into private.search_quota as q (user_id, window_start, calls)
  values (v_uid, now(), 1)
  on conflict (user_id) do update
    set window_start = case when q.window_start <= now() - interval '1 minute'
                            then now() else q.window_start end,
        calls = case when q.window_start <= now() - interval '1 minute'
                     then 1 else q.calls + 1 end
  returning calls into v_calls;
  if v_calls > 30 then
    raise exception 'Demasiadas búsquedas. Espera un minuto.' using errcode = '22023';
  end if;

  select p.species_id into v_species from public.pets p
  where p.id = p_pet_id and p.owner_id = v_uid and p.active;
  if not found then
    raise exception 'La mascota no existe o no está activa' using errcode = '22023';
  end if;
  select a.location into v_location from public.addresses a
  where a.id = p_address_id and a.owner_id = v_uid and a.active;
  if not found then
    raise exception 'La dirección no existe o no está activa' using errcode = '22023';
  end if;
  if p_date is null or p_date < v_today or p_date > v_today + 30 then
    raise exception 'Elige una fecha dentro de los próximos 30 días' using errcode = '22023';
  end if;

  -- El día pedido en hora de Chile.
  v_day := tstzrange(p_date::timestamp at time zone 'America/Santiago',
                     (p_date + 1)::timestamp at time zone 'America/Santiago');

  -- 1) Candidatos compatibles en el radio, ordenados por distancia (KNN sobre
  --    vet_bases_quote_origin_gix), sin los que tienen día libre todo el día.
  select array_agg(x.user_id order by x.knn, x.display_name)
  into v_ids
  from (
    select v.user_id, v.display_name,
           b.quote_origin operator(extensions.<->) v_location as knn
    from public.vet_bases b
    join public.vet_profiles v on v.user_id = b.vet_id and v.status = 'approved'
    join public.vet_species vs on vs.vet_id = b.vet_id and vs.species_id = v_species
    join public.vet_specialties vsp on vsp.vet_id = b.vet_id
                                   and vsp.specialty_id = p_specialty_id
    where extensions.st_dwithin(b.quote_origin, v_location, v_max_km * 1000)
      and exists (select 1 from public.vet_availability a
                  where a.vet_id = b.vet_id and a.weekday = extract(isodow from p_date))
      -- Día libre que cubre todo el día: no es candidato (QA-F6-07).
      and not exists (select 1 from public.vet_time_off t
                      where t.vet_id = b.vet_id and t.period @> v_day)
  ) x;

  -- 2) Paginación por distancia: bloques de 40 candidatos, en orden, hasta
  --    reunir 20 vets con horario libre o agotar el radio. Cada bloque calcula
  --    sus horarios en una sola consulta (el plan de vet_open_slots se
  --    reutiliza dentro del bloque).
  v_n := coalesce(array_length(v_ids, 1), 0);
  v_from := 1;
  while v_from <= v_n and v_found < 20 loop
    return query
    select jsonb_build_object(
             'vet_id', v.user_id,
             'display_name', v.display_name,
             'bio', v.bio,
             -- Desde el origen aproximado (QA-F5-01), redondeada al km.
             'distance_km',
               round(extensions.st_distance(b.quote_origin, v_location) / 1000.0)::integer,
             'slots', s.slots)
    from unnest(v_ids[v_from:v_from + 39]) with ordinality as u (id, ord)
    join public.vet_profiles v on v.user_id = u.id
    join public.vet_bases b on b.vet_id = u.id
    cross join lateral (
      select jsonb_agg(x.starts_at order by x.starts_at) as slots
      from private.vet_open_slots(u.id, p_date) as x (starts_at)) s
    where s.slots is not null
    order by u.ord
    limit 20 - v_found;
    get diagnostics v_rows = row_count;
    v_found := v_found + v_rows;
    v_from := v_from + 40;
  end loop;
end;
$$;
