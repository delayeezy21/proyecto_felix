-- QA-19 y QA-20 (docs/qa/QA-verificacion-2efeef8.md):
-- * QA-19: la cuota se revisaba con un SELECT y se insertaba después, sin
--   bloqueo: con peticiones simultáneas se superaba el límite. Ahora la
--   reserva es atómica (advisory lock por vet y global para COLMEVET) y se
--   registra en una tabla propia antes de ejecutar los proveedores.
-- * QA-20: el vet y el admin compartían la cuota. Ahora tienen cupos separados:
--   vet 3 cada 10 min (al enviar) y admin 10 cada 10 min por solicitud.

create table public.title_verification_reservations (
  id bigint generated always as identity primary key,
  vet_id uuid not null references public.vet_profiles (user_id) on delete cascade,
  kind text not null check (kind in ('vet', 'admin', 'colmevet')),
  created_at timestamptz not null default now()
);

create index title_verification_reservations_lookup_idx
  on public.title_verification_reservations (vet_id, kind, created_at desc);
create index title_verification_reservations_kind_idx
  on public.title_verification_reservations (kind, created_at desc);

-- Solo la Edge Function (service_role) la usa: nadie más la ve ni la escribe.
alter table public.title_verification_reservations enable row level security;
alter table public.title_verification_reservations force row level security;
revoke all on public.title_verification_reservations from anon, authenticated;

-- Reserva atómica: dentro de la transacción de la llamada, el advisory lock
-- serializa las peticiones del mismo vet (y las de COLMEVET globalmente).
create function private.reserve_title_verification(
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
revoke execute on function private.reserve_title_verification(uuid, boolean, boolean)
  from public, anon, authenticated;
grant execute on function private.reserve_title_verification(uuid, boolean, boolean)
  to service_role;

create function public.reserve_title_verification(
  p_vet_id uuid,
  p_by_admin boolean,
  p_colmevet boolean
)
returns table (vet_ok boolean, colmevet_ok boolean)
language sql
volatile
security invoker
set search_path = ''
as $$
  select * from private.reserve_title_verification(p_vet_id, p_by_admin, p_colmevet);
$$;
revoke execute on function public.reserve_title_verification(uuid, boolean, boolean)
  from public, anon, authenticated;
grant execute on function public.reserve_title_verification(uuid, boolean, boolean)
  to service_role;

-- La función de solo lectura anterior queda obsoleta.
drop function public.title_verification_quota(uuid);
drop function private.title_verification_quota(uuid);
