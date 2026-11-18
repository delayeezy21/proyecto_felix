-- Fase 7: matriz de acceso a la ficha clínica (docs/arquitectura.md §7) y O-6.
--
-- Cada rol se prueba contra cada operación con pg_temp.try, que ejecuta la
-- sentencia en una subtransacción y la deshace: devuelve el valor (o 'ok'),
-- 'denied' (42501) o 'err:<sqlstate>'.
begin;
select plan(59);

-- Fixtures (sin triggers; luego se vuelve a `origin`) -----------------------
insert into auth.users (id, email)
select ('00000000-0000-0000-0000-0000000c7' || k)::uuid, 'f7-' || k || '@test.local'
from unnest(array['a01', 'a02', 'f01', 'f02', 'f03', 'f04', 'f05', 'f06', 'f07', 'f08', 'f09',
                  'f0a', 'f0b', 'b01', 'c01']) k;
set local session_replication_role = replica;
insert into public.user_roles (user_id, role)
select ('00000000-0000-0000-0000-0000000c7' || k)::uuid,
       case when k like 'a%' then 'owner' when k like 'f%' then 'vet'
            when k = 'b01' then 'foundation' else 'admin' end
from unnest(array['a01', 'a02', 'f01', 'f02', 'f03', 'f04', 'f05', 'f06', 'f07', 'f08', 'f09',
                  'f0a', 'f0b', 'b01', 'c01']) k;
insert into public.owner_profiles (user_id, display_name, commune_id)
select ('00000000-0000-0000-0000-0000000c7' || k)::uuid, 'Dueño ' || k,
       (select id from public.communes where name = 'Ñuñoa')
from unnest(array['a01', 'a02']) k;
-- f01 visita en curso · f02 completada hace 29 días · f03 hace 31 días ·
-- f04 autorizado por el dueño · f05 autorización revocada · f06 autorización
-- vencida · f07 sin relación · f08 suspendido con visita en curso ·
-- f09 O-6 (completada por el sistema) · f0a visita cancelada · f0b visita confirmada.
insert into public.vet_profiles (user_id, display_name, status)
select ('00000000-0000-0000-0000-0000000c7' || k)::uuid, 'Dr. ' || k,
       case when k = 'f08' then 'suspended' else 'approved' end
from unnest(array['f01', 'f02', 'f03', 'f04', 'f05', 'f06', 'f07', 'f08', 'f09', 'f0a', 'f0b']) k;
insert into public.foundation_members (user_id, foundation_id)
values ('00000000-0000-0000-0000-0000000c7b01',
        (select id from public.foundations order by is_default desc limit 1));
insert into public.pets (id, owner_id, name, species_id) values
  ('00000000-0000-0000-0000-0000000c7e01', '00000000-0000-0000-0000-0000000c7a01', 'Luna',
   (select id from public.species where slug = 'perro')),
  ('00000000-0000-0000-0000-0000000c7e02', '00000000-0000-0000-0000-0000000c7a02', 'Otro',
   (select id from public.species where slug = 'perro'));

create temp table t_vis (vet text, status text, by_system boolean default false);
insert into t_vis (vet, status) values ('f01', 'in_progress'), ('f02', 'completed'),
  ('f03', 'completed'), ('f08', 'in_progress'), ('f0a', 'cancelled_vet'), ('f0b', 'accepted');
insert into t_vis values ('f09', 'completed', true);
insert into public.visits (id, owner_id, pet_id, vet_id, mode, status, commune_id, species_id,
  specialty_id, foundation_id, scheduled_at, slot, confirm_deadline, quote, accepted_at,
  started_at, completed_at, closed_at, closed_by_system)
select ('00000000-0000-0000-0000-0000000c7d' || substr(vet, 2))::uuid,
       '00000000-0000-0000-0000-0000000c7a01', '00000000-0000-0000-0000-0000000c7e01',
       ('00000000-0000-0000-0000-0000000c7' || vet)::uuid, 'scheduled', status,
       (select id from public.communes where name = 'Ñuñoa'),
       (select id from public.species where slug = 'perro'),
       (select id from public.specialties where slug = 'general'),
       (select id from public.foundations order by is_default desc limit 1),
       now(), tstzrange(now(), now() + interval '90 minutes'), now() - interval '1 day', '{}',
       now() - interval '1 day', case when status = 'in_progress' then now() end,
       case when status = 'completed' then now() end,
       case when status in ('completed', 'cancelled_vet') then now() end, by_system
from t_vis;
insert into public.record_access_grants (pet_id, vet_id, source, visit_id, starts_at, expires_at,
  revoked_at)
select '00000000-0000-0000-0000-0000000c7e01', ('00000000-0000-0000-0000-0000000c7' || vet)::uuid,
       'visit', ('00000000-0000-0000-0000-0000000c7d' || substr(vet, 2))::uuid,
       now() - interval '1 day',
       case vet when 'f02' then now() + interval '1 day' when 'f03' then now() - interval '1 day'
                when 'f09' then now() + interval '30 days' when 'f0a' then now() - interval '1 hour'
       end, null
from t_vis;
insert into public.record_access_grants (pet_id, vet_id, source, starts_at, expires_at, revoked_at)
values
  ('00000000-0000-0000-0000-0000000c7e01', '00000000-0000-0000-0000-0000000c7f04', 'owner',
   now() - interval '1 day', now() + interval '7 days', null),
  ('00000000-0000-0000-0000-0000000c7e01', '00000000-0000-0000-0000-0000000c7f05', 'owner',
   now() - interval '1 day', now() + interval '7 days', now() - interval '1 minute'),
  ('00000000-0000-0000-0000-0000000c7e01', '00000000-0000-0000-0000-0000000c7f06', 'owner',
   now() - interval '8 days', now() - interval '1 minute', null);
insert into public.clinical_entries (id, pet_id, visit_id, author_id, author_role, kind,
  species_id, title, body) values
  ('00000000-0000-0000-0000-0000000c7ee1', '00000000-0000-0000-0000-0000000c7e01',
   '00000000-0000-0000-0000-0000000c7d01', '00000000-0000-0000-0000-0000000c7f01', 'vet',
   'diagnosis', (select id from public.species where slug = 'perro'), 'Otitis', 'Ficticio'),
  ('00000000-0000-0000-0000-0000000c7ee2', '00000000-0000-0000-0000-0000000c7e01', null,
   '00000000-0000-0000-0000-0000000c7a01', 'owner', 'note',
   (select id from public.species where slug = 'perro'), 'Come poco', null),
  ('00000000-0000-0000-0000-0000000c7ee3', '00000000-0000-0000-0000-0000000c7e01',
   '00000000-0000-0000-0000-0000000c7d01', '00000000-0000-0000-0000-0000000c7f01', 'vet',
   'vaccine', (select id from public.species where slug = 'perro'), 'Antirrábica', null);
insert into public.clinical_vaccines (entry_id, pet_id, vaccine_name, applied_on, next_due)
values ('00000000-0000-0000-0000-0000000c7ee3', '00000000-0000-0000-0000-0000000c7e01',
        'Antirrábica', current_date, current_date + 365);
insert into storage.objects (bucket_id, name) values ('clinical-attachments',
  'pets/00000000-0000-0000-0000-0000000c7e01/00000000-0000-0000-0000-0000000c7ee1/rx.pdf');
insert into public.entry_attachments (id, entry_id, pet_id, storage_path, file_name, mime,
  size_bytes, uploaded_by) values
  ('00000000-0000-0000-0000-0000000c7aa1', '00000000-0000-0000-0000-0000000c7ee1',
   '00000000-0000-0000-0000-0000000c7e01',
   'pets/00000000-0000-0000-0000-0000000c7e01/00000000-0000-0000-0000-0000000c7ee1/rx.pdf',
   'rx.pdf', 'application/pdf', 1000, '00000000-0000-0000-0000-0000000c7f01');
insert into public.record_access_log (pet_id, actor_id, actor_role, action, via, visit_id)
values ('00000000-0000-0000-0000-0000000c7e01', '00000000-0000-0000-0000-0000000c7f01', 'vet',
        'view', 'visit', '00000000-0000-0000-0000-0000000c7d01');
set local session_replication_role = origin;

-- Helpers ---------------------------------------------------------------------
create function pg_temp.login(p_k text) returns void language plpgsql as $$
begin
  if p_k = 'anon' then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    set local role anon;
  else
    perform set_config('request.jwt.claims', json_build_object(
      'sub', '00000000-0000-0000-0000-0000000c7' || p_k, 'role', 'authenticated')::text, true);
    set local role authenticated;
  end if;
end;
$$;
create function pg_temp.try(p_sql text) returns text language plpgsql as $$
declare
  v text;
begin
  begin
    if p_sql ~* '^\s*(select|with)' then
      execute p_sql into v;
    else
      execute p_sql;
    end if;
    raise exception using errcode = 'P0001', message = 'felix-rollback',
      detail = coalesce(v, 'ok');
  exception when others then
    if sqlerrm = 'felix-rollback' then
      get stacked diagnostics v = pg_exception_detail;
      return v;
    end if;
    return case sqlstate when '42501' then 'denied' else 'err:' || sqlstate end;
  end;
end;
$$;
-- Matriz: una línea por rol con todas las operaciones.
create function pg_temp.matrix(p_k text) returns text language plpgsql as $$
declare
  p constant text := '00000000-0000-0000-0000-0000000c7e01';
  v text := '00000000-0000-0000-0000-0000000c7d' || coalesce(substr(nullif(p_k, 'anon'), 2), '01');
begin
  return concat_ws(' ',
    'read=' || pg_temp.try('select count(*) from public.clinical_entries'),
    'vac=' || pg_temp.try('select count(*) from public.clinical_vaccines'),
    'att_rows=' || pg_temp.try('select count(*) from public.entry_attachments'),
    'rpc=' || pg_temp.try(format('select public.get_pet_record(%L) is not null', p)),
    'note=' || pg_temp.try(format(
      'select public.add_clinical_entry(%L, ''note'', ''Nota'') is not null', p)),
    'diag=' || pg_temp.try(format(
      'select public.add_clinical_entry(%L, ''diagnosis'', ''Dx'', null, %L) is not null', p,
      case when v like '%c7d0%' and exists (select 1 from pg_temp.t_vis where vet = p_k)
           then v else '00000000-0000-0000-0000-0000000c7d01' end)),
    'upd=' || pg_temp.try('update public.clinical_entries set title = ''x''')
           || '/' || pg_temp.try('update public.clinical_vaccines set lot = ''x''')
           || '/' || pg_temp.try('update public.record_access_log set action = ''view'''),
    'del=' || pg_temp.try('delete from public.clinical_entries')
           || '/' || pg_temp.try('delete from public.entry_attachments')
           || '/' || pg_temp.try('delete from public.record_access_log'),
    'log=' || pg_temp.try('select count(*) from public.record_access_log'),
    'log_ins=' || pg_temp.try(format('insert into public.record_access_log (pet_id, actor_role, '
                                   || 'action, via) values (%L, ''owner'', ''view'', ''owner'')', p)),
    'sto_read=' || pg_temp.try('select count(*) from storage.objects '
                             || 'where bucket_id = ''clinical-attachments'''),
    'sto_up=' || pg_temp.try(format('insert into storage.objects (bucket_id, name) values '
      || '(''clinical-attachments'', ''pets/%s/%s/u.pdf'')', p,
      case when p_k like 'a%' then '00000000-0000-0000-0000-0000000c7ee2'
           else '00000000-0000-0000-0000-0000000c7ee1' end)),
    'att=' || pg_temp.try('select public.authorize_attachment('
                        || '''00000000-0000-0000-0000-0000000c7aa1'') is not null'));
end;
$$;
create function pg_temp.as_role(p_k text) returns text language plpgsql as $$
declare
  v text;
begin
  perform pg_temp.login(p_k);
  v := pg_temp.matrix(p_k);
  reset role;
  return v;
end;
$$;
grant select on pg_temp.t_vis to authenticated, anon;
create temp table t_ids (k text primary key, v uuid);
grant all on t_ids to authenticated;

-- Matriz §7 ------------------------------------------------------------------
select is(pg_temp.as_role('a01'),
  'read=3 vac=1 att_rows=1 rpc=true note=true diag=denied upd=denied/denied/denied '
  'del=denied/denied/denied log=1 log_ins=denied sto_read=0 sto_up=ok att=true',
  'dueño: lee todo (directo y RPC), agrega notas, ve su log, sube adjuntos a sus notas; nunca modifica ni borra');
select is(pg_temp.as_role('a02'),
  'read=0 vac=0 att_rows=0 rpc=denied note=denied diag=denied upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=denied',
  'otro dueño: nada');
select is(pg_temp.as_role('f01'),
  'read=0 vac=0 att_rows=0 rpc=true note=denied diag=true upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=ok att=true',
  'vet con visita en curso: lee solo por RPC, escribe en su visita y sube adjuntos a sus entradas');
select is(pg_temp.as_role('f02'),
  'read=0 vac=0 att_rows=0 rpc=true note=denied diag=true upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=true',
  'vet a los 29 días: lee y escribe en su visita (no sube a entradas ajenas)');
select is(pg_temp.as_role('f03'),
  'read=0 vac=0 att_rows=0 rpc=denied note=denied diag=denied upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=denied',
  'vet a los 31 días: nada');
select is(pg_temp.as_role('f04'),
  'read=0 vac=0 att_rows=0 rpc=true note=denied diag=denied upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=true',
  'vet autorizado por el dueño: solo lee (RPC y adjuntos)');
select is(pg_temp.as_role('f05'),
  'read=0 vac=0 att_rows=0 rpc=denied note=denied diag=denied upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=denied',
  'vet con autorización revocada: nada');
select is(pg_temp.as_role('f06'),
  'read=0 vac=0 att_rows=0 rpc=denied note=denied diag=denied upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=denied',
  'vet con autorización vencida: nada');
select is(pg_temp.as_role('f07'),
  'read=0 vac=0 att_rows=0 rpc=denied note=denied diag=denied upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=denied',
  'otro vet: nada');
select is(pg_temp.as_role('f08'),
  'read=0 vac=0 att_rows=0 rpc=denied note=denied diag=denied upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=denied',
  'vet suspendido (aunque tenga visita en curso): nada');
select is(pg_temp.as_role('f09'),
  'read=0 vac=0 att_rows=0 rpc=true note=denied diag=true upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=true',
  'O-6: visita completada por el sistema abre la ventana de 30 días (lee y escribe)');
select is(pg_temp.as_role('f0a'),
  'read=0 vac=0 att_rows=0 rpc=denied note=denied diag=denied upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=denied',
  'vet con la visita cancelada: el acceso termina al cerrarse');
select is(pg_temp.as_role('f0b'),
  'read=0 vac=0 att_rows=0 rpc=true note=denied diag=denied upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=true',
  'vet con visita confirmada (antes de llegar): lee, pero aún no escribe');
select is(pg_temp.as_role('b01'),
  'read=0 vac=0 att_rows=0 rpc=denied note=denied diag=denied upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=denied',
  'fundación: nada');
select is(pg_temp.as_role('c01'),
  'read=0 vac=0 att_rows=0 rpc=denied note=denied diag=denied upd=denied/denied/denied '
  'del=denied/denied/denied log=0 log_ins=denied sto_read=0 sto_up=denied att=denied',
  'admin: sin contenido clínico ni log');
select is(pg_temp.as_role('anon'),
  'read=denied vac=denied att_rows=denied rpc=denied note=denied diag=denied '
  'upd=denied/denied/denied del=denied/denied/denied log=denied log_ins=denied '
  'sto_read=0 sto_up=denied att=denied',
  'anónimo: nada');

-- Lectura registrada -----------------------------------------------------------
select pg_temp.login('f01');
select ok(public.get_pet_record('00000000-0000-0000-0000-0000000c7e01') -> 'entries' is not null,
  'el vet asignado lee la ficha');
reset role;
select is((select count(*)::int from public.record_access_log
           where actor_id = '00000000-0000-0000-0000-0000000c7f01' and action = 'view'
             and via = 'visit' and visit_id = '00000000-0000-0000-0000-0000000c7d01'), 2,
  'cada lectura del vet queda en el log (actor, vía y visita)');
select pg_temp.login('f04');
select is(public.get_pet_record('00000000-0000-0000-0000-0000000c7e01') -> 'access' ->> 'via',
  'owner_grant', 'el vet autorizado lee con la vía owner_grant');
select is(public.get_pet_record('00000000-0000-0000-0000-0000000c7e01') -> 'grants', 'null'::jsonb,
  'el vet no ve las autorizaciones del dueño');
reset role;
select pg_temp.login('a01');
select is((select count(*)::int from public.get_pet_record('00000000-0000-0000-0000-0000000c7e01') j,
           jsonb_array_elements(j -> 'grants') g), 10, 'el dueño ve todas las autorizaciones');
select is((select count(*)::int from public.pet_access_log('00000000-0000-0000-0000-0000000c7e01')
           where action = 'view'), 4, '"Quién vio mi ficha": el dueño ve las lecturas');
select is((select actor_name from public.pet_access_log('00000000-0000-0000-0000-0000000c7e01')
           where via = 'owner_grant' limit 1), 'Dr. f04', 'con el nombre público del vet');
reset role;
select is((select count(*)::int from public.record_access_log
           where actor_id = '00000000-0000-0000-0000-0000000c7a01' and action = 'view'), 0,
  'las lecturas del propio dueño no se registran');
select pg_temp.login('a02');
select is((select count(*)::int from public.pet_access_log('00000000-0000-0000-0000-0000000c7e01')),
  0, 'otro dueño no ve el log ajeno');
reset role;
select pg_temp.login('f07');
select throws_ok($$ select public.get_pet_record('00000000-0000-0000-0000-0000000c7e99') $$,
  '42501', 'La ficha no existe o no tienes acceso',
  'una mascota inexistente da el mismo error (no revela si existe)');
reset role;

-- Versionado de correcciones ------------------------------------------------
select pg_temp.login('a01');
insert into t_ids values ('c1', public.add_clinical_entry('00000000-0000-0000-0000-0000000c7e01',
  'note', 'Come poco (corregido)', null, null, null, '00000000-0000-0000-0000-0000000c7ee2'));
select is((select e ->> 'superseded_by'
           from jsonb_array_elements(public.get_pet_record('00000000-0000-0000-0000-0000000c7e01')
                                     -> 'entries') e
           where e ->> 'id' = '00000000-0000-0000-0000-0000000c7ee2'),
  (select v::text from t_ids where k = 'c1'),
  'la corrección crea una entrada nueva y el historial muestra la anterior como reemplazada');
select is((select count(*)::int from public.clinical_entries
           where id in ('00000000-0000-0000-0000-0000000c7ee2', (select v from t_ids where k = 'c1'))),
  2, 'ambas versiones se conservan');
select throws_ok($$ select public.add_clinical_entry('00000000-0000-0000-0000-0000000c7e01',
  'note', 'Otra', null, null, null, '00000000-0000-0000-0000-0000000c7ee2') $$,
  '22023', 'Esa entrada ya fue corregida: corrige la versión vigente',
  'no se corrige dos veces la misma versión');
select throws_ok($$ select public.add_clinical_entry('00000000-0000-0000-0000-0000000c7e01',
  'note', 'Ajena', null, null, null, '00000000-0000-0000-0000-0000000c7ee1') $$,
  '22023', 'Solo puedes corregir tus propias entradas, del mismo tipo y mascota',
  'el dueño no corrige un diagnóstico del vet');
select throws_ok($$ insert into public.clinical_entries (pet_id, author_id, author_role, kind, title)
  values ('00000000-0000-0000-0000-0000000c7e01', '00000000-0000-0000-0000-0000000c7a01', 'owner',
          'diagnosis', 'x') $$, '42501', null,
  'el dueño no puede registrar diagnósticos');
reset role;
select is((select count(*)::int from public.record_access_log
           where action = 'correct' and entry_id = (select v from t_ids where k = 'c1')), 1,
  'la corrección queda en el log como correct');
select pg_temp.login('f01');
insert into t_ids values ('d1', public.add_clinical_entry('00000000-0000-0000-0000-0000000c7e01',
  'diagnosis', 'Otitis externa', 'Ficticio', '00000000-0000-0000-0000-0000000c7d01', null,
  '00000000-0000-0000-0000-0000000c7ee1'));
insert into t_ids values ('vac', public.add_clinical_entry('00000000-0000-0000-0000-0000000c7e01',
  'vaccine', 'Óctuple', null, '00000000-0000-0000-0000-0000000c7d01', null, null,
  jsonb_build_object('vaccine_name', 'Óctuple', 'applied_on', current_date,
                     'next_due', current_date + 30)));
select throws_ok($$ select public.add_clinical_entry('00000000-0000-0000-0000-0000000c7e01',
  'vaccine', 'Sin datos', null, '00000000-0000-0000-0000-0000000c7d01') $$, '22023', null,
  'una vacuna exige sus datos');
reset role;
select is((select author_role || '/' || kind || '/' || supersedes_id::text from public.clinical_entries
           where id = (select v from t_ids where k = 'd1')),
  'vet/diagnosis/00000000-0000-0000-0000-0000000c7ee1', 'el vet corrige su diagnóstico');
select is((select vaccine_name || ' ' || (next_due - applied_on) from public.clinical_vaccines
           where entry_id = (select v from t_ids where k = 'vac')), 'Óctuple 30',
  'la vacuna queda con su próxima dosis');
select throws_ok($$ update public.clinical_entries set title = 'x'
  where id = '00000000-0000-0000-0000-0000000c7ee1' $$, '42501',
  'La ficha clínica no se modifica ni se borra: registra una corrección',
  'ni siquiera postgres modifica una entrada fuera del job de borrado');

-- Autorizaciones del dueño -------------------------------------------------
select pg_temp.login('a01');
with g as (
  insert into public.record_access_grants (pet_id, vet_id, source, expires_at)
  values ('00000000-0000-0000-0000-0000000c7e01', '00000000-0000-0000-0000-0000000c7f07', 'owner',
          now() + interval '7 days') returning id)
insert into t_ids select 'g7', id from g;
select throws_ok($$ insert into public.record_access_grants (pet_id, vet_id, source, expires_at)
  values ('00000000-0000-0000-0000-0000000c7e01', '00000000-0000-0000-0000-0000000c7f08', 'owner',
          now() + interval '7 days') $$, '22023', 'El veterinario no está habilitado',
  'no se autoriza a un vet suspendido');
select throws_ok($$ insert into public.record_access_grants (pet_id, vet_id, source, expires_at)
  values ('00000000-0000-0000-0000-0000000c7e01', '00000000-0000-0000-0000-0000000c7f03', 'owner',
          now() + interval '400 days') $$, '22023', null, 'el vencimiento tiene un máximo de 365 días');
select throws_ok($$ insert into public.record_access_grants (pet_id, vet_id, source, visit_id)
  values ('00000000-0000-0000-0000-0000000c7e01', '00000000-0000-0000-0000-0000000c7f03', 'visit',
          '00000000-0000-0000-0000-0000000c7d03') $$, '42501', null,
  'el dueño no crea autorizaciones de visita');
select throws_ok($$ update public.record_access_grants set expires_at = now() + interval '9 days' $$,
  '42501', null, 'el dueño no cambia el vencimiento');
select is(pg_temp.try('with u as (update public.record_access_grants set revoked_at = now() '
  || 'where source = ''visit'' returning 1) select count(*) from u'), '0',
  'el dueño no revoca el acceso de una visita');
reset role;
select pg_temp.login('a02');
select throws_ok($$ insert into public.record_access_grants (pet_id, vet_id, source, expires_at)
  values ('00000000-0000-0000-0000-0000000c7e01', '00000000-0000-0000-0000-0000000c7f07', 'owner',
          now() + interval '7 days') $$, '42501', null, 'otro dueño no autoriza sobre una mascota ajena');
reset role;
select pg_temp.login('f07');
select ok(public.get_pet_record('00000000-0000-0000-0000-0000000c7e01') is not null,
  'autorizado por el dueño, el vet lee');
reset role;
select pg_temp.login('a01');
update public.record_access_grants set revoked_at = now() where id = (select v from t_ids where k = 'g7');
select throws_ok($$ update public.record_access_grants set revoked_at = now()
  where id = (select v from t_ids where k = 'g7') $$, '22023', 'La autorización ya fue revocada',
  'se revoca una sola vez');
reset role;
select pg_temp.login('f07');
select throws_ok($$ select public.get_pet_record('00000000-0000-0000-0000-0000000c7e01') $$, '42501',
  null, 'al revocar, la siguiente lectura falla de inmediato');
reset role;
select is((select string_agg(action, ',' order by id) from public.record_access_log
           where grant_id = (select v from t_ids where k = 'g7')), 'grant,view,revoke',
  'otorgar, leer y revocar quedan en el log');

-- Ciclo de vida del acceso por visita y O-6 --------------------------------
insert into auth.users (id, email)
select ('00000000-0000-0000-0000-0000000c7f' || k)::uuid, 'f7-' || k || '@test.local'
from unnest(array['11', '12', '13']) k;
set local session_replication_role = replica;
insert into public.user_roles (user_id, role)
select ('00000000-0000-0000-0000-0000000c7f' || k)::uuid, 'vet' from unnest(array['11', '12', '13']) k;
insert into public.visits (id, owner_id, pet_id, vet_id, mode, status, commune_id, species_id,
  specialty_id, foundation_id, scheduled_at, slot, confirm_deadline, quote)
select ('00000000-0000-0000-0000-0000000c7d' || k)::uuid,
       '00000000-0000-0000-0000-0000000c7a01', '00000000-0000-0000-0000-0000000c7e01',
       ('00000000-0000-0000-0000-0000000c7f' || k)::uuid, 'scheduled', 'pending_vet',
       (select id from public.communes where name = 'Ñuñoa'),
       (select id from public.species where slug = 'perro'),
       (select id from public.specialties where slug = 'general'),
       (select id from public.foundations order by is_default desc limit 1),
       now() + interval '1 day' * (k::int - 10), tstzrange(now() + interval '1 day' * (k::int - 10),
       now() + interval '1 day' * (k::int - 10) + interval '90 minutes'), now() + interval '1 hour', '{}'
from unnest(array['11', '12', '13']) k;
insert into public.vet_profiles (user_id, display_name, status)
select ('00000000-0000-0000-0000-0000000c7f' || k)::uuid, 'Dr. ' || k, 'approved'
from unnest(array['11', '12', '13']) k;
set local session_replication_role = origin;
select private.apply_transition(('00000000-0000-0000-0000-0000000c7d' || k)::uuid, 'accepted',
  ('00000000-0000-0000-0000-0000000c7f' || k)::uuid, null, 0) from unnest(array['11', '12', '13']) k;
select is((select count(*)::int from public.record_access_grants
           where visit_id in ('00000000-0000-0000-0000-0000000c7d11', '00000000-0000-0000-0000-0000000c7d12',
                              '00000000-0000-0000-0000-0000000c7d13') and expires_at is null), 3,
  'al aceptar nace el acceso, sin vencimiento mientras la visita esté activa');
select private.apply_transition('00000000-0000-0000-0000-0000000c7d11', s,
  '00000000-0000-0000-0000-0000000c7f11', null, 0) from unnest(array['en_route', 'arrived', 'in_progress', 'completed']) s;
select is((select round(extract(epoch from g.expires_at - v.completed_at) / 86400)::int || '/' || v.closed_by_system
           from public.record_access_grants g join public.visits v on v.id = g.visit_id
           where g.visit_id = '00000000-0000-0000-0000-0000000c7d11'), '30/false',
  'al completarla el vet, el acceso vence 30 días después (closed_by_system = false)');
-- O-6: "en curso" que nadie completa; la cierra el cron.
select private.apply_transition('00000000-0000-0000-0000-0000000c7d12', s,
  '00000000-0000-0000-0000-0000000c7f12', null, 0) from unnest(array['en_route', 'arrived', 'in_progress']) s;
set local felix.time_travel = 'on';
update public.visits set started_at = now() - interval '7 hours'
where id = '00000000-0000-0000-0000-0000000c7d12';
set local felix.time_travel = 'off';
select ok(private.expire_visits() >= 1, 'el cron cierra la visita vencida');
select is((select v.status || '/' || v.closed_by_system || '/'
                  || round(extract(epoch from g.expires_at - v.completed_at) / 86400)::int
           from public.record_access_grants g join public.visits v on v.id = g.visit_id
           where g.visit_id = '00000000-0000-0000-0000-0000000c7d12'), 'completed/true/30',
  'O-6: el cierre del sistema queda marcado y abre la misma ventana de 30 días');
select pg_temp.login('f12');
select is((select (j ->> 'closed_by_system') || '/' || (j ->> 'record_writable')
           from public.my_visits(50) j where j ->> 'id' = '00000000-0000-0000-0000-0000000c7d12'),
  'true/true', 'O-6: el vet ve la visita como cerrada por el sistema y puede documentarla');
reset role;
-- Cancelada tras aceptar: el acceso termina al cerrarse.
select private.apply_transition('00000000-0000-0000-0000-0000000c7d13', 'cancelled_vet',
  '00000000-0000-0000-0000-0000000c7f13', 'Ficticio', 0);
select pg_temp.login('f13');
select throws_ok($$ select public.get_pet_record('00000000-0000-0000-0000-0000000c7e01') $$, '42501',
  null, 'una visita cancelada cierra el acceso de inmediato');
reset role;

-- Admin: solo conteos ---------------------------------------------------------
select pg_temp.login('c01');
select ok((public.admin_record_stats() ->> 'entries')::int >= 5, 'el admin ve conteos agregados');
reset role;
select pg_temp.login('a01');
select throws_ok($$ select public.admin_record_stats() $$, '42501', null,
  'solo el admin ve los conteos');
reset role;

-- Revisión de privacidad (B1, B4, B6, B10) ---------------------------------
select pg_temp.login('a02');
select throws_ok($$ select public.add_clinical_entry('00000000-0000-0000-0000-0000000c7e01',
  'note', 'x', null, null, null, '00000000-0000-0000-0000-0000000c7ee2') $$, '42501',
  'No tienes permiso para esta acción',
  'B1: sin autorización, el mismo error genérico (no revela si la entrada existe)');
select throws_ok($$ insert into public.entry_attachments (entry_id, storage_path, file_name, mime,
  size_bytes) values ('00000000-0000-0000-0000-0000000c7ee2', 'pets/x/y/z.pdf', 'z.pdf',
  'application/pdf', 1) $$, '42501', 'No tienes permiso para esta acción',
  'B1: registrar un adjunto ajeno no revela si el archivo existe ni cuántos hay');
reset role;
select pg_temp.login('f04');
select is((select count(*)::int from public.record_access_grants), 0,
  'B6: el vet no lee las autorizaciones (ni las propias)');
reset role;
select pg_temp.login('a01');
select isnt(pg_temp.try('with d as (delete from storage.objects where bucket_id = '
  || '''clinical-attachments'' returning 1) select count(*) from d'), '1',
  'B10: el dueño no borra archivos del bucket');
reset role;
-- B4: visita "en curso" vencida que el cron aún no cierra.
set local felix.time_travel = 'on';
update public.visits set started_at = now() - interval '7 hours'
where id = '00000000-0000-0000-0000-0000000c7d01';
set local felix.time_travel = 'off';
select pg_temp.login('f01');
select is(pg_temp.try($$ select public.get_pet_record('00000000-0000-0000-0000-0000000c7e01') is not null $$),
  'denied', 'B4: vencida la ventana activa, el vet pierde el acceso aunque el cron no la cierre');
reset role;

select * from finish();
rollback;
