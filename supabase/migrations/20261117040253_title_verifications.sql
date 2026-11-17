-- Verificación asistida del título de veterinarios (docs/verificacion-automatica.md).
--
-- La Edge Function verify-vet-title ejecuta proveedores de verificación
-- (reglas internas, COLMEVET opcional, falso para tests) y guarda aquí el
-- resultado. El admin sigue decidiendo: los resultados solo sugieren chequeos.
-- Evidencia mínima: nunca nombres, RUT ni datos de terceros (homónimos).

create table public.vet_title_verifications (
  id uuid primary key default gen_random_uuid(),
  vet_id uuid not null references public.vet_profiles (user_id) on delete cascade,
  source text not null check (source in ('rules', 'colmevet', 'fake')),
  outcome text not null
    check (outcome in ('match', 'no_match', 'ambiguous', 'error', 'skipped')),
  -- Riesgo según las reglas internas. null = la fuente no evalúa riesgo
  -- (COLMEVET: la colegiatura es voluntaria, no aparecer no es una alerta).
  risk text check (risk is null or risk in ('low', 'medium', 'high')),
  -- Chequeos de la lista del admin que el proveedor sugiere marcar.
  -- 'name' y 'code' no están: los confirma siempre una persona.
  suggested_checks text[] not null default '{}'
    check (suggested_checks <@ array['university', 'colmevet']::text[]),
  -- Evidencia mínima (contadores, códigos HTTP, banderas). Tamaño acotado.
  evidence jsonb not null default '{}'::jsonb
    check (jsonb_typeof(evidence) = 'object' and pg_column_size(evidence) <= 1024),
  run_trigger text not null check (run_trigger in ('submit', 'admin')),
  requested_by uuid references auth.users (id) on delete set null,
  provider_version text not null check (char_length(provider_version) between 1 and 40),
  created_at timestamptz not null default now()
);

comment on table public.vet_title_verifications is
  'Resultados de la verificación asistida del título (solo inserción, vía Edge Function).';

create index vet_title_verifications_vet_idx
  on public.vet_title_verifications (vet_id, created_at desc);
create index vet_title_verifications_requested_by_idx
  on public.vet_title_verifications (requested_by);
create index vet_title_verifications_source_created_idx
  on public.vet_title_verifications (source, created_at desc);

alter table public.vet_title_verifications enable row level security;
alter table public.vet_title_verifications force row level security;

-- El vet ve sus propios resultados (derecho de acceso, Ley 21.719); el admin, todos.
create policy vet_title_verifications_read on public.vet_title_verifications
for select to authenticated
using (vet_id = (select auth.uid()) or (select private.is_admin()));

-- Privilegios: authenticated solo lee; la Edge Function (service_role) solo
-- lee e inserta. Nadie actualiza ni borra (las filas se van con el vet).
revoke all on public.vet_title_verifications from public, anon, authenticated, service_role;
grant select on public.vet_title_verifications to authenticated;
grant select, insert on public.vet_title_verifications to service_role;

-- ---------------------------------------------------------------------------
-- Límite de tasa (lo consulta la Edge Function antes de cada ejecución):
--   * 3 ejecuciones por vet cada 10 minutos (cuenta las filas de 'rules',
--     que se inserta en toda ejecución).
--   * 20 consultas a COLMEVET por minuto en todo el sistema.
-- ---------------------------------------------------------------------------
create function private.title_verification_quota(p_vet_id uuid)
returns table (vet_ok boolean, colmevet_ok boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select count(*) from public.vet_title_verifications t
      where t.vet_id = p_vet_id and t.source = 'rules'
        and t.created_at > now() - interval '10 minutes') < 3,
    (select count(*) from public.vet_title_verifications t
      where t.source = 'colmevet'
        and t.created_at > now() - interval '1 minute') < 20;
$$;
revoke execute on function private.title_verification_quota(uuid) from public, anon, authenticated;
grant execute on function private.title_verification_quota(uuid) to service_role;

create function public.title_verification_quota(p_vet_id uuid)
returns table (vet_ok boolean, colmevet_ok boolean)
language sql
stable
security invoker
set search_path = ''
as $$
  select * from private.title_verification_quota(p_vet_id);
$$;
revoke execute on function public.title_verification_quota(uuid) from public, anon, authenticated;
grant execute on function public.title_verification_quota(uuid) to service_role;
