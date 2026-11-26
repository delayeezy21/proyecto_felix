-- Fase 12 · O-F9-d: my_ratings_received ya no entrega visit_id ni la hora
-- exacta de publicación. Con ellos el calificado podía cruzar cada
-- calificación con su visita y deducir quién la hizo. Ahora solo trae el
-- día de publicación (hora de Chile) y se ordena por día y estrellas.
drop function public.my_ratings_received(integer);
drop function private.my_ratings_received(integer);

create function private.my_ratings_received(p_limit integer)
returns table (rater_role text, stars smallint, comment text,
               comment_hidden boolean, published_on date)
language sql
stable
security definer
set search_path = ''
as $$
  select x.rater_role, x.stars,
         case when x.hidden then null else x.comment end, x.hidden,
         (private.rating_public_at(x.published_at, v.completed_at)
            at time zone 'America/Santiago')::date
  from public.ratings x
  join public.visits v on v.id = x.visit_id
  where x.ratee_id = (select auth.uid())
    and private.rating_public_at(x.published_at, v.completed_at) <= now()
    and not private.is_blocked(x.rater_id)
  order by 5 desc, 2 desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;
revoke execute on function private.my_ratings_received(integer) from public, anon;
grant execute on function private.my_ratings_received(integer) to authenticated;

create function public.my_ratings_received(p_limit integer default 50)
returns table (rater_role text, stars smallint, comment text,
               comment_hidden boolean, published_on date)
language sql stable security invoker set search_path = ''
as $$ select * from private.my_ratings_received(p_limit); $$;
revoke execute on function public.my_ratings_received(integer) from public, anon;
grant execute on function public.my_ratings_received(integer) to authenticated;
