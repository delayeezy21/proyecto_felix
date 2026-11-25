-- Re-QA de la fase 11 (docs/qa/QA-db5f16c.md), pruebas agregadas por QA:
--   QA-F11-01: variantes de PII que no cubre 180 (N°, "nro.", puntos y
--     paréntesis en el teléfono, "Depto.", salto de línea) y casos negativos
--     clínicos (el número de la casa o del depto sueltos, nombres parecidos).
--   QA-F11-07 (abierto): el admin aprueba o anota a un vet bloqueado con
--     UPDATE directo a vet_profiles / vet_documents (sin pasar por la RPC).
--   QA-F11-08 (abierto, Bajo): "dpto 51" y "departamento 51" no se redactan.
-- Los casos de defectos abiertos van como todo(): no rompen la suite.
begin;
select plan(17);

create function pg_temp.u(k text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-000000190' || k)::uuid $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end;
$$;

-- 1. QA-F11-01: variantes nuevas ------------------------------------------------
create temp table t_terms as select array['f11qa-a01@test.local', 'Ángela Muñoz', 'Ángela', 'Muñoz',
  '+56 9 8765 4321', 'Ñandú', '941000011112222', 'Avenida Los Álamos 1234', 'Torre B depto 51'] as t;
create function pg_temp.r(p text) returns text language sql as $$
  select private.redact_pii(p, (select t from t_terms)) $$;

select is(pg_temp.r('Vive en Los Álamos N° 1234.'), 'Vive en [redactado].', 'calle con N° antes del número');
select is(pg_temp.r('Vive en Los Alamos nro. 1234.'), 'Vive en [redactado].', 'calle con "nro." y sin tildes');
select is(pg_temp.r('Fono 9.8765.4321.'), 'Fono [redactado].', 'teléfono con puntos');
select is(pg_temp.r('Fono +56 (9) 8765-4321.'), 'Fono [redactado].', 'teléfono con paréntesis');
select is(pg_temp.r('Dejar en Depto. 51.'), 'Dejar en [redactado].', 'depto abreviado con punto');
select is(pg_temp.r(E'Llamar a Angela\nMunoz.'), 'Llamar a [redactado].', 'nombre partido por un salto de línea');
-- Negativos clínicos: sin sobre-redactar.
select is(pg_temp.r('Vacuna lote 1234; 51 mg; control en Los Álamos sin número.'),
  'Vacuna lote 1234; 51 mg; control en Los Álamos sin número.',
  'el número de la casa o del depto sueltos (lote, dosis) no se redactan');
select is(pg_temp.r('Angelina y Muñozo no son la dueña; Ñandúes no aplica.'),
  'Angelina y Muñozo no son la dueña; Ñandúes no aplica.',
  'palabras que contienen el nombre o la mascota no se redactan');
select is(pg_temp.r('Microchip no leído; 15 ml de suero en 941 segundos.'),
  'Microchip no leído; 15 ml de suero en 941 segundos.',
  'cifras clínicas cortas no se confunden con microchip ni teléfono');

select todo('QA-F11-08: otras abreviaturas de la unidad', 2);
select is(pg_temp.r('Dejar en dpto 51.'), 'Dejar en [redactado].', 'depto como "dpto"');
select is(pg_temp.r('Dejar en departamento 51.'), 'Dejar en [redactado].', 'depto como "departamento"');

-- 2. QA-F11-07: el admin y un vet bloqueado ----------------------------------------
set local session_replication_role = replica;
insert into auth.users (id, email)
select pg_temp.u(k), 'f11qa190-' || k || '@test.local' from unnest(array['b01', 'b02', 'd01']) k;
insert into public.user_roles (user_id, role) values
  (pg_temp.u('b01'), 'vet'), (pg_temp.u('b02'), 'vet'), (pg_temp.u('d01'), 'admin');
insert into public.vet_profiles (user_id, display_name, status, submitted_at) values
  (pg_temp.u('b01'), 'Dr. Libre', 'pending', now() - interval '1 day'),
  (pg_temp.u('b02'), 'Dr. Bloqueado', 'pending', now() - interval '1 day');
insert into public.vet_documents (vet_id, kind, storage_path, mime, size_bytes) values
  (pg_temp.u('b01'), 'degree_certificate', pg_temp.u('b01') || '/t.pdf', 'application/pdf', 10),
  (pg_temp.u('b02'), 'degree_certificate', pg_temp.u('b02') || '/t.pdf', 'application/pdf', 10);
insert into public.deletion_requests (user_id, role) values (pg_temp.u('b02'), 'vet');
set local session_replication_role = origin;

select set_config('request.jwt.claims', json_build_object(
  'sub', pg_temp.u('d01'), 'role', 'authenticated')::text, true);
set local role authenticated;

-- Control: con un vet no bloqueado el admin sí puede (no es un falso positivo).
select is(pg_temp.err(format($$ update public.vet_documents set review_status = 'accepted'
  where vet_id = %L $$, pg_temp.u('b01'))), 'ok', 'control: el admin revisa el documento de un vet libre');
select is(pg_temp.err(format($$ update public.vet_profiles set review_notes = 'QA'
  where user_id = %L $$, pg_temp.u('b01'))), 'ok', 'control: el admin anota a un vet libre');

select todo('QA-F11-07: el bloqueo no cubre el UPDATE directo del admin', 4);
select is(pg_temp.err(format($$ update public.vet_profiles set status = 'approved', reviewed_at = now()
  where user_id = %L $$, pg_temp.u('b02'))), '42501', 'el admin no aprueba al vet bloqueado por UPDATE directo');
select is(pg_temp.err(format($$ update public.vet_profiles set review_notes = 'QA'
  where user_id = %L $$, pg_temp.u('b02'))), '42501', 'el admin no anota al vet bloqueado por UPDATE directo');
select is(pg_temp.err(format($$ update public.vet_documents set review_status = 'accepted'
  where vet_id = %L $$, pg_temp.u('b02'))), '42501', 'el admin no revisa los documentos del vet bloqueado');
reset role;
select is((select status from public.vet_profiles where user_id = pg_temp.u('b02')), 'pending',
  'el vet bloqueado sigue pending');

select * from finish();
rollback;
