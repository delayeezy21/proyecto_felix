-- Fase 9: calificaciones y cancelaciones (SPEC F7, HU7.1 a HU7.4).
--
-- Matriz: dueño (a01), otro dueño (a02), dueño bloqueado (a03), vet asignado
-- (f01), otro vet (f02), vet que cancela (f03), vet bloqueado (f04), vets de
-- la tabla de cargos (f05…f0b), admin (c01) y anónimo.
begin;
select plan(87);
-- Sesión en UTC+14: las ventanas no dependen de la zona horaria.
set local timezone = 'Etc/GMT-14';

create function pg_temp.u(p_k text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-0000000c9' || p_k)::uuid;
$$;

-- Fixtures ------------------------------------------------------------------
insert into auth.users (id, email)
select pg_temp.u(k), 'f9-' || k || '@test.local'
from unnest(array['a01', 'a02', 'a03', 'f01', 'f02', 'f03', 'f04', 'f05', 'f06', 'f07', 'f08',
                  'f09', 'f0a', 'f0b', 'c01']) k;
insert into public.pricing_config
  (commission_pct, foundation_pct, urgent_pct, per_km, free_km, cancel_fee, cancel_free_hours,
   effective_from)
values (15, 20, 30, 500, 5, 5000, 2, now() - interval '2 seconds');
set local session_replication_role = replica;
insert into public.user_roles (user_id, role)
select pg_temp.u(k), case when k like 'a%' then 'owner' when k like 'f%' then 'vet' else 'admin' end
from unnest(array['a01', 'a02', 'a03', 'f01', 'f02', 'f03', 'f04', 'f05', 'f06', 'f07', 'f08',
                  'f09', 'f0a', 'f0b', 'c01']) k;
insert into public.owner_profiles (user_id, display_name, commune_id)
select pg_temp.u(k), 'Dueño ' || k, (select id from public.communes where name = 'Ñuñoa')
from unnest(array['a01', 'a02', 'a03']) k;
insert into public.vet_profiles (user_id, display_name, status)
select pg_temp.u(k), 'Dr. ' || k, 'approved'
from unnest(array['f01', 'f02', 'f03', 'f04', 'f05', 'f06', 'f07', 'f08', 'f09', 'f0a', 'f0b']) k;
insert into public.pets (id, owner_id, name, species_id)
select pg_temp.u('e' || substr(k, 2)), pg_temp.u(k), 'Mascota ' || k,
       (select id from public.species where slug = 'perro')
from unnest(array['a01', 'a02', 'a03']) k;

create temp table t_vis (k text, owner text, vet text, mode text, status text,
  at_off interval, done_ago interval, by_system boolean default false);
insert into t_vis (k, owner, vet, mode, status, at_off, done_ago) values
  -- Calificaciones con el vet f01.
  ('d01', 'a01', 'f01', 'scheduled', 'completed', '-26 hours', '24 hours'),
  ('d02', 'a01', 'f01', 'scheduled', 'completed', '-194 hours', '192 hours'),
  ('d03', 'a01', 'f01', 'scheduled', 'accepted', '48 hours', null),
  ('d04', 'a01', 'f01', 'scheduled', 'completed', '-146 hours', '144 hours'),
  ('d05', 'a03', 'f01', 'scheduled', 'completed', '-30 hours', '28 hours'),
  ('d06', 'a01', 'f01', 'scheduled', 'completed', '-32 hours', '20 hours'),
  ('d07', 'a02', 'f01', 'scheduled', 'completed', '-34 hours', '22 hours'),
  -- Cancelaciones del vet f03: una de hace 31 días (no cuenta), una cerrada
  -- por el sistema hace 5 días (cuenta) y tres confirmadas.
  ('b01', 'a01', 'f03', 'scheduled', 'cancelled_vet', '-746 hours', '744 hours'),
  ('b02', 'a01', 'f03', 'scheduled', 'cancelled_vet', '-122 hours', '120 hours'),
  ('b03', 'a01', 'f03', 'scheduled', 'accepted', '24 hours', null),
  ('b04', 'a01', 'f03', 'scheduled', 'accepted', '48 hours', null),
  ('b05', 'a01', 'f03', 'scheduled', 'accepted', '72 hours', null),
  ('b06', 'a01', 'f04', 'scheduled', 'accepted', '24 hours', null),
  ('b07', 'a01', 'f04', 'scheduled', 'accepted', '48 hours', null),
  ('b08', 'a01', 'f04', 'scheduled', 'accepted', '72 hours', null),
  -- HU7.3: tabla de cargos por estado y hora.
  ('d11', 'a01', 'f05', 'scheduled', 'pending_vet', '1 hour', null),
  ('d12', 'a01', 'f06', 'scheduled', 'accepted', '3 hours', null),
  ('d13', 'a01', 'f07', 'scheduled', 'accepted', '1 hour', null),
  ('d14', 'a01', 'f08', 'scheduled', 'en_route', '1 hour', null),
  ('d15', 'a01', 'f09', 'scheduled', 'en_route', '-40 minutes', null),
  ('d16', 'a01', 'f0a', 'urgent', 'accepted', '10 minutes', null),
  ('d17', 'a01', 'f0b', 'urgent', 'en_route', '10 minutes', null);
update t_vis set by_system = true where k in ('d06', 'b02');
insert into public.visits (id, owner_id, pet_id, vet_id, mode, status, commune_id, species_id,
  specialty_id, foundation_id, scheduled_at, slot, confirm_deadline, quote, accepted_at,
  started_at, completed_at, closed_at, closed_by_system)
select pg_temp.u(k), pg_temp.u(owner), pg_temp.u('e' || substr(owner, 2)), pg_temp.u(vet),
       mode, status,
       (select id from public.communes where name = 'Ñuñoa'),
       (select id from public.species where slug = 'perro'),
       (select id from public.specialties where slug = 'general'),
       (select id from public.foundations order by is_default desc limit 1),
       now() + at_off, tstzrange(now() + at_off, now() + at_off + interval '90 minutes'),
       now() + at_off - interval '3 hours', '{}', now() - interval '200 hours',
       case when status = 'completed' then now() - done_ago - interval '1 hour' end,
       case when status = 'completed' then now() - done_ago end,
       case when status in ('completed', 'cancelled_vet') then now() - done_ago end, by_system
from t_vis;
-- Calificación ya publicada del dueño bloqueado (a03) hacia f01.
insert into public.ratings (visit_id, rater_id, ratee_id, rater_role, stars, comment, published_at)
values (pg_temp.u('d05'), pg_temp.u('a03'), pg_temp.u('f01'), 'owner', 1, 'De cuenta bloqueada',
        now() - interval '1 hour');
insert into public.deletion_requests (user_id, role) values
  (pg_temp.u('a03'), 'owner'), (pg_temp.u('f04'), 'vet');
set local session_replication_role = origin;

-- Helpers ---------------------------------------------------------------------
create function pg_temp.login(p_k text) returns void language plpgsql as $$
begin
  if p_k = 'anon' then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    set local role anon;
  else
    perform set_config('request.jwt.claims', json_build_object(
      'sub', pg_temp.u(p_k), 'role', 'authenticated')::text, true);
    set local role authenticated;
  end if;
end;
$$;
-- Ejecuta en una subtransacción y la deshace: 'ok', 'denied' (42501) o 'err:<sqlstate>'.
create function pg_temp.try(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  raise exception using errcode = 'P0001', message = 'ok';
exception
  when sqlstate 'P0001' then
    return case when sqlerrm = 'ok' then 'ok' else 'err:P0001' end;
  when insufficient_privilege then return 'denied';
  when others then return 'err:' || sqlstate;
end;
$$;
create function pg_temp.rate(p_k text, p_stars integer, p_comment text default null)
returns jsonb language sql as $$
  select public.rate_visit(pg_temp.u(p_k), p_stars, p_comment);
$$;
create function pg_temp.st(p_k text) returns jsonb language sql as $$
  select public.visit_rating_status(pg_temp.u(p_k));
$$;
create function pg_temp.rid(p_visit text, p_rater text) returns uuid language sql security definer as $$
  select id from public.ratings where visit_id = pg_temp.u(p_visit) and rater_id = pg_temp.u(p_rater);
$$;

-- Estructura -------------------------------------------------------------------
select ok(not has_table_privilege('authenticated', 'public.ratings', 'SELECT')
          and not has_table_privilege('authenticated', 'public.vet_cancel_alerts', 'SELECT')
          and not has_table_privilege('anon', 'public.ratings', 'SELECT'),
  'ratings y vet_cancel_alerts no se leen directo: solo por RPC');
select ok((select bool_and(c.relrowsecurity and c.relforcerowsecurity) from pg_class c
           where c.oid in ('public.ratings'::regclass, 'public.vet_cancel_alerts'::regclass)),
  'RLS habilitada y forzada en las tablas nuevas');
select is_empty($$ select p from unnest(array['public.rate_visit(uuid,integer,text)',
    'public.visit_rating_status(uuid)', 'public.my_ratings_received(integer)',
    'public.my_rating_summary()', 'public.vet_rating_summary(uuid)',
    'public.admin_list_ratings(integer)', 'public.admin_set_rating_hidden(uuid,boolean)',
    'public.admin_list_cancel_alerts(boolean)', 'public.admin_review_cancel_alert(uuid)']) p
  where has_function_privilege('anon', p, 'EXECUTE') $$,
  'anon no ejecuta ninguna RPC de la fase 9');
select is_empty($$ select p from unnest(array['private.rating_stats(uuid,text)',
    'private.vet_dispatch_rating(uuid)', 'private.vet_cancel_count_30d(uuid)',
    'private.track_vet_cancel()', 'private.rating_status_json(public.visits,uuid)']) p
  where has_function_privilege('authenticated', p, 'EXECUTE') $$,
  'los helpers internos no se ejecutan desde la API');

-- HU7.1: quién califica, una vez y dentro de 7 días ---------------------------------
select pg_temp.login('anon');
select is(pg_temp.try($$ select pg_temp.rate('d01', 5) $$), 'denied', 'anónimo: no califica');
reset role;
select pg_temp.login('c01');
select is(pg_temp.try($$ select pg_temp.rate('d01', 5) $$), 'denied', 'admin: no es participante');
reset role;
select pg_temp.login('f02');
select is(pg_temp.try($$ select pg_temp.rate('d01', 5) $$), 'denied', 'otro vet: no califica');
select is(pg_temp.try($$ select pg_temp.st('d01') $$), 'denied',
  'otro vet: no ve el estado de la calificación');
reset role;
select pg_temp.login('a02');
select is(pg_temp.try($$ select pg_temp.rate('d01', 5) $$), 'denied', 'otro dueño: no califica');
select is(pg_temp.try($$ select public.rate_visit(gen_random_uuid(), 5) $$), 'denied',
  'una visita inexistente responde igual que una ajena');
reset role;
select pg_temp.login('a01');
select is(pg_temp.try($$ select pg_temp.rate('d01', 0) $$), 'err:22023', '0 estrellas: rechazado');
select is(pg_temp.try($$ select pg_temp.rate('d01', 6) $$), 'err:22023', '6 estrellas: rechazado');
select is(pg_temp.try(format('select pg_temp.rate(%L, 4, %L)', 'd01', repeat('x', 501))),
  'err:22023', 'comentario de 501 caracteres: rechazado');
select is(pg_temp.st('d01') ->> 'can_rate', 'true', 'el dueño puede calificar una visita completada');
select is((pg_temp.rate('d01', 5, '  Excelente atención  ') -> 'mine' ->> 'comment'),
  'Excelente atención', 'el dueño califica (comentario recortado)');
select is(pg_temp.try($$ select pg_temp.rate('d01', 3) $$), 'err:23505', 'una sola vez por participante');
select is(pg_temp.st('d01') ->> 'can_rate', 'false', 'ya calificó: can_rate = false');
select is(pg_temp.try($$ select pg_temp.rate('d02', 5) $$), 'err:22023',
  'pasados 7 días desde que se completó: rechazado');
select is(pg_temp.try($$ select pg_temp.rate('d03', 5) $$), 'err:22023',
  'una visita no completada no se califica');
select is((pg_temp.rate('d06', 2) -> 'mine' ->> 'stars'), '2',
  'una visita completada por el sistema también se califica');
reset role;
select is((select count(*)::int from public.ratings where visit_id = pg_temp.u('d01')), 1,
  'queda una fila por calificación');

-- HU7.2: publicación diferida ------------------------------------------------------
select pg_temp.login('f01');
select is(pg_temp.st('d01') -> 'theirs', 'null'::jsonb,
  'el vet no ve la calificación del dueño mientras él no califique');
select is((select count(*)::int from public.my_ratings_received()), 0,
  'el vet no tiene calificaciones publicadas todavía');
reset role;
select pg_temp.login('a01');
select ok((pg_temp.st('d01') -> 'mine' ->> 'publishes_at')::timestamptz
          between now() + interval '143 hours' and now() + interval '145 hours',
  'sin la contraparte, se publica al cumplirse 7 días desde la visita');
reset role;
select pg_temp.login('f01');
select is(pg_temp.rate('d01', 4, 'Dueño amable') -> 'theirs' ->> 'stars', '5',
  'cuando califica el segundo, ambas se publican al tiempo');
reset role;
select pg_temp.login('a01');
select is(pg_temp.st('d01') -> 'theirs' ->> 'stars', '4', 'el dueño ve la calificación del vet');
select is((pg_temp.rate('d04', 4) -> 'mine' ->> 'stars'), '4', 'el dueño califica la visita d04');
reset role;
select pg_temp.login('f01');
select is(pg_temp.st('d04') -> 'theirs', 'null'::jsonb, 'd04: oculta antes de los 7 días');
reset role;
-- Pasa el tiempo: la visita se completó hace 7 días y 1 hora.
set local session_replication_role = replica;
update public.visits set completed_at = now() - interval '169 hours',
  closed_at = now() - interval '169 hours' where id = pg_temp.u('d04');
set local session_replication_role = origin;
select pg_temp.login('f01');
select is(pg_temp.st('d04') -> 'theirs' ->> 'stars', '4',
  'd04: a los 7 días se publica aunque el vet no calificó');
select is(pg_temp.st('d04') ->> 'can_rate', 'false', 'd04: el vet ya no puede calificar');
select is(pg_temp.try($$ select pg_temp.rate('d04', 5) $$), 'err:22023', 'd04: plazo vencido');
select is((select string_agg(visit_id::text || ':' || stars, ',' order by stars desc)
           from public.my_ratings_received()),
  pg_temp.u('d01') || ':5,' || pg_temp.u('d04') || ':4',
  'el vet ve solo las publicadas (d06 sigue ciega, d05 es de una cuenta bloqueada)');
select ok(not exists (select 1 from public.my_ratings_received() where rater_role <> 'owner'),
  'el vet solo recibe calificaciones de dueños');

-- Cuentas bloqueadas -------------------------------------------------------------
select is(pg_temp.try($$ select pg_temp.rate('d05', 5) $$), 'err:22023',
  'no se califica a una cuenta bloqueada (22023, no 42501: no es mi bloqueo)');
select is(pg_temp.st('d05') -> 'theirs', 'null'::jsonb,
  'la calificación de una cuenta bloqueada no se muestra');
reset role;
select pg_temp.login('a03');
select is(pg_temp.try($$ select pg_temp.rate('d05', 5) $$), 'denied',
  'una cuenta bloqueada no califica (aunque falle el pre-request)');
reset role;
select pg_temp.login('f02');
select is((select count(*)::int from public.my_ratings_received()), 0,
  'otro vet no ve calificaciones ajenas');
reset role;

-- Promedio y despacho ---------------------------------------------------------------
select is((select rating_avg is null and rating_count = 2 from private.rating_stats(pg_temp.u('f01'), 'owner')),
  true, 'con 2 calificaciones publicadas no hay promedio');
select is(private.vet_dispatch_rating(pg_temp.u('f01')), 3.0, 'con menos de 3, el despacho usa 3,0');
select pg_temp.login('a02');
select is((pg_temp.rate('d07', 1) -> 'mine' ->> 'stars'), '1', 'otro dueño califica d07');
reset role;
select pg_temp.login('f01');
select is((pg_temp.rate('d07', 5) -> 'theirs' ->> 'stars'), '1', 'd07 queda publicada');
reset role;
select is((select rating_avg || '/' || rating_count from private.rating_stats(pg_temp.u('f01'), 'owner')),
  '3.33/3', 'promedio de las 3 publicadas del dueño hacia el vet (5, 4, 1; sin d06 ni d05)');
select is(private.vet_dispatch_rating(pg_temp.u('f01')), 3.33, 'el despacho usa el promedio');
select is(private.vet_dispatch_rating(pg_temp.u('f02')), 3.0, 'un vet sin calificaciones queda neutro');
select is(private.vet_dispatch_rating(null), null, 'sin vet no hay calificación');
select is((select rating_count from private.rating_stats(pg_temp.u('a01'), 'vet')), 1,
  'las calificaciones del vet al dueño no entran en el promedio del vet');
select pg_temp.login('a01');
select is(public.vet_rating_summary(pg_temp.u('f01')) - 'vet_id',
  '{"rating_avg": 3.33, "rating_count": 3}'::jsonb, 'el dueño ve solo el agregado del vet');
select is(public.vet_rating_summary(pg_temp.u('f04')), null, 'de un vet bloqueado no hay resumen');
reset role;
select pg_temp.login('f01');
select is(public.my_rating_summary() ->> 'rating_avg', '3.33', 'el vet ve su promedio');
reset role;

-- Moderación del admin -----------------------------------------------------------------
select pg_temp.login('f01');
select is(pg_temp.try(format('select public.admin_set_rating_hidden(%L)', pg_temp.rid('d01', 'a01'))),
  'denied', 'el vet no oculta comentarios');
select is(pg_temp.try('select public.admin_list_ratings()'), 'denied', 'el vet no lista calificaciones');
reset role;
select pg_temp.login('c01');
select is((select count(*)::int from public.admin_list_ratings() where visit_id = pg_temp.u('d05')), 0,
  'el admin no ve calificaciones de cuentas bloqueadas');
select is((select count(*)::int from public.admin_list_ratings()
           where visit_id in (pg_temp.u('d01'), pg_temp.u('d04'), pg_temp.u('d06'), pg_temp.u('d07'))), 6,
  'el admin ve las demás (también las aún no publicadas)');
select is(public.admin_set_rating_hidden(pg_temp.rid('d01', 'a01')) ->> 'hidden', 'true',
  'el admin oculta un comentario');
select is(pg_temp.try(format('select public.admin_set_rating_hidden(%L)', pg_temp.rid('d05', 'a03'))),
  'denied', 'el admin no trata la calificación de una cuenta bloqueada');
reset role;
select ok(exists (select 1 from public.admin_audit_log where table_name = 'ratings'
                  and row_pk = pg_temp.rid('d01', 'a01')::text and actor_id = pg_temp.u('c01')
                  and (new_data ->> 'hidden')::boolean),
  'ocultar queda en admin_audit_log');
select pg_temp.login('f01');
select is((select concat_ws('/', stars, coalesce(comment, 'null'), comment_hidden)
           from public.my_ratings_received() where visit_id = pg_temp.u('d01')),
  '5/null/t', 'el calificado ya no ve el comentario oculto (las estrellas siguen)');
reset role;
select is((select rating_avg from private.rating_stats(pg_temp.u('f01'), 'owner')), 3.33,
  'ocultar el comentario no cambia el promedio');

-- HU7.4: alerta con 3 cancelaciones en 30 días -------------------------------------------
select pg_temp.login('f03');
select is((public.transition_visit(pg_temp.u('b03'), 'cancelled_vet') ->> 'cancel_fee')::int, 0,
  'la cancelación del vet no tiene cargo');
reset role;
select is(private.vet_cancel_count_30d(pg_temp.u('f03')), 2,
  'cuenta la del vet y la cerrada por el sistema; no la de hace 31 días');
select is((select count(*)::int from public.vet_cancel_alerts where vet_id = pg_temp.u('f03')), 0,
  'con 2 no hay alerta');
select pg_temp.login('f03');
select is(public.transition_visit(pg_temp.u('b04'), 'cancelled_vet') ->> 'status', 'cancelled_vet',
  'tercera cancelación');
select is(public.my_rating_summary() ->> 'cancel_count_30d', '3', 'el vet ve su contador');
select is(pg_temp.try('select public.admin_list_cancel_alerts()'), 'denied',
  'el vet no lista alertas');
reset role;
select is((select cancel_count from public.vet_cancel_alerts
           where vet_id = pg_temp.u('f03') and reviewed_at is null), 3, 'con 3 se abre una alerta');
select pg_temp.login('f02');
select is(public.my_rating_summary() ->> 'cancel_count_30d', '0', 'otro vet ve solo su contador');
reset role;
select pg_temp.login('a01');
select is(public.my_rating_summary() -> 'cancel_count_30d', 'null'::jsonb,
  'el dueño no tiene contador de cancelaciones');
reset role;
select pg_temp.login('c01');
select is((select cancel_count || '/' || cancel_count_30d || '/' || vet_name
           from public.admin_list_cancel_alerts() where vet_id = pg_temp.u('f03')),
  '3/3/Dr. f03', 'el admin ve la alerta en su panel');
select ok((public.admin_review_cancel_alert((select id from public.admin_list_cancel_alerts()
           where vet_id = pg_temp.u('f03'))) ->> 'reviewed_at') is not null,
  'el admin marca la alerta como revisada');
select is((select count(*)::int from public.admin_list_cancel_alerts() where vet_id = pg_temp.u('f03')), 0,
  'una alerta revisada sale de la lista por defecto');
select is((select count(*)::int from public.admin_list_cancel_alerts(true) where vet_id = pg_temp.u('f03')), 1,
  'sigue en el historial');
reset role;
select ok(exists (select 1 from public.admin_audit_log where table_name = 'vet_cancel_alerts'
                  and actor_id = pg_temp.u('c01')), 'revisar queda en admin_audit_log');
select pg_temp.login('f03');
select is(public.transition_visit(pg_temp.u('b05'), 'cancelled_vet') ->> 'status', 'cancelled_vet',
  'cuarta cancelación');
reset role;
select is((select cancel_count from public.vet_cancel_alerts
           where vet_id = pg_temp.u('f03') and reviewed_at is null), 4,
  'después de revisada, una nueva cancelación abre otra alerta');
-- Vet bloqueado: sus cancelaciones (al pedir el borrado) no generan alertas.
select private.apply_transition(pg_temp.u(k), 'cancelled_vet', pg_temp.u('f04'), null, 0)
from unnest(array['b06', 'b07', 'b08']) k;
select is((select count(*)::int from public.vet_cancel_alerts where vet_id = pg_temp.u('f04')), 0,
  'un vet bloqueado no genera alertas');

-- HU7.3: cargo según estado y hora (reglas de la fase 6) ----------------------------------
select is((select string_agg(t.k || '=' || private.cancel_fee_for(v, now()), ',' order by t.k)
           from t_vis t join public.visits v on v.id = pg_temp.u(t.k) where t.k like 'd1%'),
  'd11=0,d12=0,d13=5000,d14=5000,d15=0,d16=0,d17=5000',
  'pendiente, > 2 h, ≤ 2 h, en camino, en camino tarde, urgencia antes y después de en camino');
select pg_temp.login('a01');
select is((public.transition_visit(pg_temp.u('d13'), 'cancelled_owner') ->> 'cancel_fee')::int, 5000,
  'el dueño cancela a menos de 2 h: $5.000');
reset role;
select is((select concat_ws(',', kind, status, total) from public.payments
           where visit_id = pg_temp.u('d13')), 'cancel_fee,simulated_paid,5000',
  'el cargo queda como pago simulado cancel_fee');
select is((select count(*)::int from public.payments where visit_id = pg_temp.u('b03')), 0,
  'la cancelación del vet no genera pago');

-- Privacidad: exportación y borrado -------------------------------------------------------
select pg_temp.login('a01');
select is((select jsonb_array_length(j -> 'ratings_given') || '/' || jsonb_array_length(j -> 'ratings_received')
           from (select public.export_my_data() j) e), '3/1',
  'la exportación del dueño trae sus calificaciones hechas y las recibidas publicadas');
reset role;
select pg_temp.login('f01');
select ok(not exists (select 1 from jsonb_array_elements(public.export_my_data() -> 'ratings_received') x
                      where x ->> 'visit_id' = pg_temp.u('d05')::text),
  'QA-F9-01: la exportación no trae calificaciones de una cuenta bloqueada');
reset role;
select pg_temp.login('f03');
select is(jsonb_array_length(public.export_my_data() -> 'cancel_alerts'), 2,
  'la exportación del vet trae sus alertas');
reset role;
-- Borrado del dueño a02 (calificó d07 y fue calificado) y del vet f03 (alertas).
insert into public.deletion_requests (user_id, role, execute_after) values
  (pg_temp.u('a02'), 'owner', now() - interval '1 minute'),
  (pg_temp.u('f03'), 'vet', now() - interval '1 minute');
select is(private.run_account_deletions(), '{"done": 2}'::jsonb, 'el job borra ambas cuentas');
select is((select count(*)::int from public.ratings
           where pg_temp.u('a02') in (rater_id, ratee_id)), 0,
  'se borran las calificaciones hechas y recibidas');
select is((select string_agg(t.target || ':' || t.affected, ',' order by t.target)
           from public.deletion_targets t join public.deletion_requests d on d.id = t.request_id
           where t.target in ('ratings (hechas y recibidas)', 'vet_cancel_alerts')
             and d.role in ('owner', 'vet') and d.status = 'done'
             and t.affected > 0),
  'ratings (hechas y recibidas):2,vet_cancel_alerts:2', 'deletion_targets registra ambos pasos');
select is((select count(*)::int from public.vet_cancel_alerts where vet_id = pg_temp.u('f03')), 0,
  'se borran las alertas del vet');
select is_empty($$ select * from private.privacy_residue(array[pg_temp.u('a02'), pg_temp.u('f03')]) $$,
  'el escaneo final no encuentra restos');

select * from finish();
rollback;
