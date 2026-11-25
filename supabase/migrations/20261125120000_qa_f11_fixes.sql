-- QA de la fase 11 (docs/qa/QA-690dd06.md): QA-F11-05, QA-F11-04, QA-F11-01.
-- No cambia migraciones aplicadas: reemplaza funciones y políticas.

-- ===========================================================================
-- QA-F11-05 (HU8.6): el vet ya no lee filas de payments. Ve sus liquidaciones
-- solo por my_payouts(): visita, tipo, estado, servicio, comisión y su pago,
-- sin el dueño, la cotización, el total ni la donación del dueño.
-- ===========================================================================
drop policy payments_select on public.payments;
create policy payments_select on public.payments
for select to authenticated
using (owner_id = (select auth.uid()) or (select private.is_admin()));

create function private.my_payouts(p_limit integer)
returns table (
  visit_id uuid, kind text, status text, service_price integer,
  platform_fee integer, vet_payout integer, created_at timestamptz, paid_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select pa.visit_id, pa.kind, pa.status, pa.service_price, pa.platform_fee,
         pa.vet_payout, pa.created_at, pa.paid_at
  from public.payments pa
  where pa.vet_id = (select auth.uid())
    and (select private.current_app_role()) = 'vet'
  order by pa.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
$$;
revoke execute on function private.my_payouts(integer) from public, anon;
grant execute on function private.my_payouts(integer) to authenticated;

create function public.my_payouts(p_limit integer default 100)
returns table (
  visit_id uuid, kind text, status text, service_price integer,
  platform_fee integer, vet_payout integer, created_at timestamptz, paid_at timestamptz)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.my_payouts(p_limit);
$$;
revoke execute on function public.my_payouts(integer) from public, anon;
grant execute on function public.my_payouts(integer) to authenticated;

-- ===========================================================================
-- QA-F11-04: sin tratamiento de una cuenta bloqueada fuera de PostgREST.
-- ===========================================================================

-- Para las Edge Functions (clave de servicio): ¿alguno de estos titulares
-- está bloqueado? Solo service_role.
grant execute on function private.is_blocked(uuid) to service_role;
create function public.any_account_blocked(p_user_ids uuid[])
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (select 1 from unnest(coalesce(p_user_ids, '{}')) x
                 where private.is_blocked(x));
$$;
revoke execute on function public.any_account_blocked(uuid[]) from public, anon, authenticated;
grant execute on function public.any_account_blocked(uuid[]) to service_role;

-- Para RPC SECURITY INVOKER del admin: rechaza si el titular está bloqueado.
-- A quien no es admin no le responde nada (no revela el estado de otro).
create function private.assert_subject_not_blocked(p_uid uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select private.is_admin()) and private.is_blocked(p_uid) then
    raise exception 'La cuenta tiene una solicitud de eliminación: no se puede tratar'
      using errcode = '42501', hint = 'account_blocked';
  end if;
end;
$$;
revoke execute on function private.assert_subject_not_blocked(uuid) from public, anon;
grant execute on function private.assert_subject_not_blocked(uuid) to authenticated;

-- verify-vet-title: la reserva del cupo (antes de llamar a un proveedor y de
-- registrar nada) se niega si el vet está bloqueado. Igual que
-- 20261117111904 más ese control.
create or replace function private.reserve_title_verification(
  p_vet_id uuid,
  p_by_admin boolean,
  p_colmevet boolean
)
returns table (vet_ok boolean, colmevet_ok boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_kind text := case when p_by_admin then 'admin' else 'vet' end;
  v_limit integer := case when p_by_admin then 10 else 3 end;
  v_ok boolean;
  v_colmevet_ok boolean := false;
begin
  if private.is_blocked(p_vet_id) then
    raise exception 'La cuenta tiene una solicitud de eliminación: no se puede tratar'
      using errcode = '42501', hint = 'account_blocked';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('title-verif:' || v_kind || ':' || p_vet_id::text, 0));
  select count(*) < v_limit into v_ok
  from public.title_verification_reservations r
  where r.vet_id = p_vet_id and r.kind = v_kind
    and r.created_at > now() - interval '10 minutes';

  if not v_ok then
    return query select false, false;
    return;
  end if;
  insert into public.title_verification_reservations (vet_id, kind) values (p_vet_id, v_kind);

  if p_colmevet then
    perform pg_advisory_xact_lock(hashtextextended('title-verif:colmevet', 0));
    select count(*) < 20 into v_colmevet_ok
    from public.title_verification_reservations r
    where r.kind = 'colmevet' and r.created_at > now() - interval '1 minute';
    if v_colmevet_ok then
      insert into public.title_verification_reservations (vet_id, kind)
      values (p_vet_id, 'colmevet');
    end if;
  end if;

  return query select true, v_colmevet_ok;
end;
$$;

-- Y ninguna verificación se registra para un vet bloqueado (por si otra vía
-- con la clave de servicio se salta la reserva).
create function private.guard_title_verification_blocked()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.is_blocked(new.vet_id) then
    raise exception 'La cuenta tiene una solicitud de eliminación: no se puede tratar'
      using errcode = '42501', hint = 'account_blocked';
  end if;
  return new;
end;
$$;
revoke execute on function private.guard_title_verification_blocked() from public, anon, authenticated;
create trigger vet_title_verifications_not_blocked
before insert on public.vet_title_verifications
for each row execute function private.guard_title_verification_blocked();

-- El admin no revisa (aprueba ni rechaza) la solicitud de un vet bloqueado.
-- Igual que 20261117010145 (QA-02) más ese control.
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
  perform private.assert_subject_not_blocked(p_vet_id);
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

-- Auth API (PUT /auth/v1/user con una sesión nueva): GoTrue escribe en
-- auth.users con su propio rol, sin pasar por PostgREST. Este trigger rechaza
-- que una cuenta bloqueada cambie sus metadatos, su email o su teléfono
-- (también los cambios pendientes). La contraseña sí se puede cambiar: la
-- recuperación debe seguir sirviendo para entrar y cancelar. GoTrue responde
-- 500 ("Database error updating user") y no guarda nada.
create function private.guard_blocked_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.is_blocked(old.id)
     and (new.raw_user_meta_data, new.email, new.phone, new.email_change, new.phone_change)
         is distinct from
         (old.raw_user_meta_data, old.email, old.phone, old.email_change, old.phone_change) then
    raise exception 'La cuenta tiene una solicitud de eliminación: no se puede modificar'
      using errcode = '42501', hint = 'account_blocked';
  end if;
  return new;
end;
$$;
revoke execute on function private.guard_blocked_auth_user() from public, anon, authenticated;
create trigger felix_blocked_account_guard
before update on auth.users
for each row execute function private.guard_blocked_auth_user();

-- send-push (clave de servicio): no se envían avisos a cuentas bloqueadas.
-- Igual que 20261124213036 más ese filtro (lo bloqueado se descarta).
create or replace function private.claim_push_batch(p_limit integer)
returns table (id bigint, token text, platform text, visit_id uuid, event text)
language sql
volatile
security definer
set search_path = ''
as $$
  with c as (
    select o.id from private.push_outbox o
    where o.sent_at is null
    order by o.id
    limit least(greatest(coalesce(p_limit, 100), 1), 500)
    for update skip locked
  ), m as (
    update private.push_outbox o set sent_at = now()
    from c where o.id = c.id
    returning o.id, o.user_id, o.visit_id, o.event
  )
  select m.id, d.token, d.platform, m.visit_id, m.event
  from m join private.push_devices d on d.user_id = m.user_id
  where not private.is_blocked(m.user_id)
  order by m.id;
$$;

-- ===========================================================================
-- QA-F11-01: redacción de PII (M3) más amplia en las entradas retenidas.
-- ===========================================================================

-- Teléfono: también agrupado 3-3-3 ("987 654 321"), sin comerse un microchip.
create or replace function private.pii_patterns()
returns table (kind text, pattern text)
language sql
immutable
set search_path = ''
as $$
  values
    ('email'::text, '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'::text),
    -- Móvil (9) o fijo de Santiago (2), con o sin +56 y separadores (1-4-4 o 3-3-3).
    ('phone', '(?<![0-9])(?<![0-9][ .-])(?:\+?56[ .-]?)?(?:[29][ .-]?[0-9]{4}[ .-]?[0-9]{4}|[29][0-9]{2}[ .-][0-9]{3}[ .-][0-9]{3})(?![0-9])(?![ .-][0-9])'),
    ('rut', '(?<![0-9.])[0-9]{1,2}\.?[0-9]{3}\.?[0-9]{3}-[0-9kK](?![[:alnum:]])');
$$;

-- Patrón de un término que ignora tildes (y la ñ) y mayúsculas, con
-- cualquier espacio entre palabras. Conserva la longitud del texto original.
create function private.pii_term_regex(p_term text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(
           replace(replace(replace(replace(replace(replace(replace(
             regexp_replace(
               translate(lower(trim(p_term)),
                         'áàâäãéèêëíìîïóòôöõúùûüñç', 'aaaaaeeeeiiiiooooouuuunc'),
               '([][\\^$.|?*+(){}])', '\\\1', 'g'),
             'a', '[aáàâäã]'), 'e', '[eéèêë]'), 'i', '[iíìîï]'), 'o', '[oóòôöõ]'),
             'u', '[uúùûü]'), 'n', '[nñ]'), 'c', '[cç]'),
           '[[:space:]]+', '[[:space:]]+', 'g');
$$;
revoke execute on function private.pii_term_regex(text) from public, anon, authenticated;

-- Patrones derivados de los términos del titular, de más largo a más corto:
--   * números (teléfono, microchip): sus dígitos con cualquier separador y,
--     en un teléfono, con o sin +56 y con o sin el 9 inicial;
--   * texto: el término completo sin tildes ni mayúsculas;
--   * dirección: la calle sin el tipo de vía + el número ("Los Álamos 1234",
--     "Av. Los Alamos #1234") y cada unidad de los detalles ("Torre B",
--     "depto 51"). Nunca la calle sola ni una palabra suelta del detalle.
create function private.pii_term_patterns(p_terms text[])
returns table (pattern text)
language plpgsql
immutable
set search_path = ''
as $$
declare
  t text;
  v_digits text;
  v_core text;
  v_m text[];
  v_out text[] := '{}';
  v_via constant text :=
    '(?:avenida|avda|av|calle|pasaje|psje|pje|camino|cam|ruta|diagonal|costanera|callej[oó]n)';
  v_unit constant text :=
    '(?:torre|depto|dpto|departamento|depa|casa|oficina|of|piso|block|blk|lote|sitio|parcela|edificio|local)';
begin
  foreach t in array coalesce(p_terms, '{}') loop
    t := trim(t);
    continue when t is null or t = '';
    v_digits := regexp_replace(t, '[^0-9]', '', 'g');
    if t ~ '^[+0-9 ().-]+$' then
      continue when char_length(v_digits) < 8;
      if char_length(v_digits) = 11 and left(v_digits, 2) = '56' then
        v_digits := substr(v_digits, 3);
      end if;
      v_out := v_out || (
        '(?<![0-9])(?:\+?56[ .()-]*)?'
        || case when char_length(v_digits) = 9 and left(v_digits, 1) = '9'
                then '(?:9[ .()-]*)?' || array_to_string(
                       regexp_split_to_array(substr(v_digits, 2), ''), '[ .()-]*')
                else array_to_string(regexp_split_to_array(v_digits, ''), '[ .()-]*') end
        || '(?![0-9])');
      continue;
    end if;
    if char_length(t) >= 3 then
      v_out := v_out || ('(?<![[:alnum:]])' || private.pii_term_regex(t) || '(?![[:alnum:]])');
    end if;
    -- Calle + número (con o sin tipo de vía y "#", "N°" o "nro").
    v_core := regexp_replace(t, '^' || v_via || '(?:\.[[:space:]]*|[[:space:]]+)', '', 'i');
    v_m := regexp_match(v_core, '^([^0-9]*[[:alpha:]][^0-9]*)([0-9]+)');
    if v_m is not null then
      v_core := regexp_replace(v_m[1],
        '[[:space:],]*(?:#|n[°º.]|nro\.?|n[uú]mero)?[[:space:]]*$', '', 'i');
      if v_core ~ '[[:alpha:]]{3}' then
        v_out := v_out || (
          '(?<![[:alnum:]])(?:' || v_via || '(?:\.[[:space:]]*|[[:space:]]+))?'
          || private.pii_term_regex(v_core)
          || '[[:space:]]*,?[[:space:]]*(?:(?:#|n[°º.]|nro\.?|n[uú]mero)[[:space:]]*)?'
          || v_m[2] || '(?![0-9])');
      end if;
    end if;
    -- Unidades del detalle: "Torre B", "depto 51", "casa 3".
    for v_m in
      select regexp_matches(t, '(?<![[:alnum:]])(' || v_unit
        || ')\.?[[:space:]]*([0-9][[:alnum:]-]*|[[:alpha:]])(?![[:alnum:]])', 'gi')
    loop
      v_out := v_out || (
        '(?<![[:alnum:]])' || private.pii_term_regex(v_m[1]) || '\.?[[:space:]]*'
        || private.pii_term_regex(v_m[2]) || '(?![[:alnum:]])');
    end loop;
  end loop;
  return query select distinct x from unnest(v_out) x;
end;
$$;
revoke execute on function private.pii_term_patterns(text[]) from public, anon, authenticated;

-- Reemplaza la PII por [redactado]: primero el email (un nombre dentro de un
-- email no debe romperlo), luego los números del titular, un microchip
-- cualquiera (15 dígitos), los patrones de teléfono y RUT, y al final los
-- términos de texto (los más largos primero: "Ana Pérez" antes que "Ana").
create or replace function private.redact_pii(p_text text, p_terms text[])
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := p_text;
  p text;
begin
  if v is null then
    return null;
  end if;
  v := regexp_replace(v, (select x.pattern from private.pii_patterns() x where x.kind = 'email'),
                      '[redactado]', 'g');
  for p in select x.pattern from private.pii_term_patterns(p_terms) x
           where x.pattern like '(?<![0-9])%' order by char_length(x.pattern) desc loop
    v := regexp_replace(v, p, '[redactado]', 'g');
  end loop;
  v := regexp_replace(v, '(?<![0-9])[0-9]{3}(?:[ .-]?[0-9]{3}){4}(?![0-9])', '[redactado]', 'g');
  for p in select x.pattern from private.pii_patterns() x where x.kind <> 'email' loop
    v := regexp_replace(v, p, '[redactado]', 'g');
  end loop;
  for p in select x.pattern from private.pii_term_patterns(p_terms) x
           where x.pattern not like '(?<![0-9])%' order by char_length(x.pattern) desc loop
    v := regexp_replace(v, p, '[redactado]', 'gi');
  end loop;
  return v;
end;
$$;
