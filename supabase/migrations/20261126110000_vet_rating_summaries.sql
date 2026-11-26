-- Fase 12 · O-F9-b: el promedio de varios vets en una sola llamada (la
-- pantalla "Agendar" pedía uno por vet, hasta 20). Mismas reglas que
-- vet_rating_summary: solo vets aprobados y no bloqueados, solo el agregado.
create function private.vet_rating_summaries(p_vet_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    return '[]'::jsonb;
  end if;
  if coalesce(cardinality(p_vet_ids), 0) > 50 then
    raise exception 'Máximo 50 veterinarios por consulta' using errcode = '22023';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('vet_id', p.user_id, 'rating_avg', s.rating_avg,
                                        'rating_count', s.rating_count))
    from public.vet_profiles p
    cross join lateral private.rating_stats(p.user_id, 'owner') s
    where p.user_id = any (p_vet_ids) and p.status = 'approved'
      and not private.is_blocked(p.user_id)), '[]'::jsonb);
end;
$$;
revoke execute on function private.vet_rating_summaries(uuid[]) from public, anon;
grant execute on function private.vet_rating_summaries(uuid[]) to authenticated;

create function public.vet_rating_summaries(p_vet_ids uuid[])
returns jsonb language sql stable security invoker set search_path = ''
as $$ select private.vet_rating_summaries(p_vet_ids); $$;
revoke execute on function public.vet_rating_summaries(uuid[]) from public, anon;
grant execute on function public.vet_rating_summaries(uuid[]) to authenticated;
