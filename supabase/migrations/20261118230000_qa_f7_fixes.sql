-- QA-F7-01 y QA-F7-02 (docs/qa/QA-cdf8eee.md).
-- * QA-F7-01: el guardián de solo inserción permitía a service_role anular
--   FKs por REST (PATCH actor_id/supersedes_id → null). Ahora solo el dueño
--   de la tabla (los ON DELETE SET NULL, que corren como postgres) puede
--   anularlas. La marca de mantenimiento exige además session_user = postgres.
-- * QA-F7-02: TRUNCATE saltaba los triggers por fila. Se revoca y se agrega
--   un trigger BEFORE TRUNCATE.

create or replace function private.forbid_record_change()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  k text;
  v_ok boolean := tg_op = 'UPDATE'
    and current_user not in ('anon', 'authenticated', 'service_role');
begin
  if session_user = 'postgres'
     and current_user not in ('anon', 'authenticated', 'service_role')
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

create function private.forbid_record_truncate()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if session_user = 'postgres'
     and coalesce(current_setting('felix.record_maintenance', true), '') = 'on' then
    return null;
  end if;
  raise exception 'La ficha clínica no se trunca' using errcode = '42501';
end;
$$;
revoke execute on function private.forbid_record_truncate() from public, anon, authenticated;

revoke truncate on public.clinical_entries, public.clinical_vaccines,
  public.entry_attachments, public.record_access_log, public.record_access_grants
  from public, anon, authenticated, service_role;

create trigger clinical_entries_no_truncate before truncate on public.clinical_entries
for each statement execute function private.forbid_record_truncate();
create trigger clinical_vaccines_no_truncate before truncate on public.clinical_vaccines
for each statement execute function private.forbid_record_truncate();
create trigger entry_attachments_no_truncate before truncate on public.entry_attachments
for each statement execute function private.forbid_record_truncate();
create trigger record_access_log_no_truncate before truncate on public.record_access_log
for each statement execute function private.forbid_record_truncate();
