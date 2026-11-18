-- QA-F7-01 y QA-F7-02: service_role no anula FKs de la ficha y nadie trunca.
begin;
select plan(9);

select ok(not has_table_privilege('service_role', 'public.record_access_log', 'TRUNCATE'),
  'service_role sin TRUNCATE en record_access_log');
select ok(not has_table_privilege('service_role', 'public.clinical_entries', 'TRUNCATE'),
  'service_role sin TRUNCATE en clinical_entries');
select ok(not has_table_privilege('authenticated', 'public.entry_attachments', 'TRUNCATE'),
  'authenticated sin TRUNCATE en entry_attachments');

select has_trigger('public', 'clinical_entries', 'clinical_entries_no_truncate', 'trigger de TRUNCATE en clinical_entries');
select has_trigger('public', 'clinical_vaccines', 'clinical_vaccines_no_truncate', 'trigger de TRUNCATE en clinical_vaccines');
select has_trigger('public', 'entry_attachments', 'entry_attachments_no_truncate', 'trigger de TRUNCATE en entry_attachments');
select has_trigger('public', 'record_access_log', 'record_access_log_no_truncate', 'trigger de TRUNCATE en record_access_log');

-- Aunque postgres lo intente (sin la marca de mantenimiento), TRUNCATE falla.
select throws_ok($$ truncate public.record_access_log $$, '42501', null,
  'TRUNCATE del log rechazado sin la marca de mantenimiento');

-- QA-F7-01: service_role no puede anular una FK (actor_id) del log.
select ok(
  position('''service_role''' in pg_get_functiondef('private.forbid_record_change()'::regprocedure)) > 0
  and position('session_user' in pg_get_functiondef('private.forbid_record_change()'::regprocedure)) > 0,
  'el guardián excluye service_role y exige session_user para el mantenimiento');

select * from finish();
rollback;
