-- Re-QA db5f16c (docs/qa/QA-db5f16c.md):
--   QA-F11-07: el admin no trata los datos de un vet bloqueado por ninguna vía
--     directa (UPDATE a vet_profiles / vet_documents / foundation_members).
--   O-F11-h (decidido: se bloquea): el admin tampoco lee ni firma la URL de los
--     documentos de un vet bloqueado. Las purgas (service_role) no cambian.
--   QA-F11-08: "dpto", "dpto." y "departamento" se redactan como "depto".

-- ===========================================================================
-- QA-F11-07 / O-F11-h
-- ===========================================================================

-- Para políticas RLS: true si quien consulta puede tratar los datos del
-- titular. Al admin le responde 42501 si el titular está bloqueado (en vez de
-- ocultar la fila, para que un PATCH directo falle igual que la RPC). A quien
-- no es admin le responde true: su acceso lo deciden las demás condiciones.
create function private.admin_may_treat(p_uid uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_subject_not_blocked(p_uid);
  return true;
end;
$$;
revoke execute on function private.admin_may_treat(uuid) from public, anon;
grant execute on function private.admin_may_treat(uuid) to authenticated;

-- Para Storage: ¿el dueño de la carpeta (primer segmento = id) está bloqueado?
-- Filtra sin error (Storage responde "no encontrado").
create function private.folder_owner_blocked(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.deletion_requests d
    where d.user_id::text = (storage.foldername(p_name))[1]
      and d.status in ('blocked', 'executing'));
$$;
revoke execute on function private.folder_owner_blocked(text) from public, anon;
grant execute on function private.folder_owner_blocked(text) to authenticated;

-- vet_profiles: el chequeo de bloqueo va antes de dejar pasar al admin.
-- Igual que 20261117010145 (QA-10, QA-02) más ese control.
create or replace function private.guard_vet_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null
     or coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon') then
    return new;
  end if;
  if private.is_blocked(old.user_id) then
    raise exception 'La cuenta tiene una solicitud de eliminación: no se puede tratar'
      using errcode = '42501', hint = 'account_blocked';
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

-- vet_documents: el admin no lee ni revisa los documentos de un vet bloqueado.
drop policy vet_documents_read on public.vet_documents;
create policy vet_documents_read on public.vet_documents
for select to authenticated
using (vet_id = (select auth.uid())
       or ((select private.is_admin()) and private.admin_may_treat(vet_id)));

drop policy vet_documents_admin_update on public.vet_documents;
create policy vet_documents_admin_update on public.vet_documents
for update to authenticated
using ((select private.is_admin()) and private.admin_may_treat(vet_id))
with check ((select private.is_admin()) and private.admin_may_treat(vet_id));

-- Storage: el admin no descarga ni firma URL del título de un vet bloqueado.
drop policy vet_documents_storage_read on storage.objects;
create policy vet_documents_storage_read on storage.objects
for select to authenticated
using (
  bucket_id = 'vet-documents'
  and ((storage.foldername(name))[1] = (select auth.uid())::text
       or ((select private.is_admin()) and not private.folder_owner_blocked(name)))
);

-- foundation_members: el admin no da de alta ni modifica la membresía de una
-- cuenta bloqueada (mismo criterio).
create function private.guard_foundation_member_blocked()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null
     or coalesce(current_setting('role', true), 'none') not in ('authenticated', 'anon') then
    return new;
  end if;
  perform private.assert_subject_not_blocked(new.user_id);
  if tg_op = 'UPDATE' then
    perform private.assert_subject_not_blocked(old.user_id);
  end if;
  return new;
end;
$$;
revoke execute on function private.guard_foundation_member_blocked() from public, anon, authenticated;
create trigger foundation_members_not_blocked
before insert or update on public.foundation_members
for each row execute function private.guard_foundation_member_blocked();

-- ===========================================================================
-- QA-F11-08: sinónimos de "departamento" en la redacción.
-- Igual que 20261125120000 salvo la unidad: "depto", "dpto", "dpto.",
-- "dpt", "depa" y "departamento" se tratan como la misma palabra.
-- ===========================================================================
create or replace function private.pii_term_patterns(p_terms text[])
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
    '(?:torre|depto|dpto|dpt|departamento|depa|casa|oficina|of|piso|block|blk|lote|sitio|parcela|edificio|local)';
  v_dept constant text := '(?:departamento|depto|dpto|dpt|depa)';
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
    for v_m in
      select regexp_matches(t, '(?<![[:alnum:]])(' || v_unit
        || ')\.?[[:space:]]*([0-9][[:alnum:]-]*|[[:alpha:]])(?![[:alnum:]])', 'gi')
    loop
      v_out := v_out || (
        '(?<![[:alnum:]])'
        || case when lower(v_m[1]) ~ ('^' || v_dept || '$') then v_dept
                else private.pii_term_regex(v_m[1]) end
        || '\.?[[:space:]]*'
        || private.pii_term_regex(v_m[2]) || '(?![[:alnum:]])');
    end loop;
  end loop;
  return query select distinct x from unnest(v_out) x;
end;
$$;
revoke execute on function private.pii_term_patterns(text[]) from public, anon, authenticated;
