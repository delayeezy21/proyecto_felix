-- QA de la fase 11 (docs/qa/QA-690dd06.md):
--   QA-F11-05 (HU8.6) el vet no lee filas de payments; sus liquidaciones van
--     por my_payouts() sin dueño, cotización, total ni donación.
--   QA-F11-04 sin tratamiento de una cuenta bloqueada: verify-vet-title (cupo,
--     RPC de servicio y registro), review_vet_application, auth.users (Auth
--     API) y send-push.
--   QA-F11-01 redacción de PII: tildes, mayúsculas, dirección parcial,
--     teléfono en todo formato chileno, email y microchip; sin sobre-redactar.
begin;
select plan(54);
-- QA-F11-02: sesión en UTC+14 (current_date ≠ fecha de Chile, como de 21:00 a 24:00).
set local timezone = 'Etc/GMT-14';

create function pg_temp.u(k text) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-000000180' || k)::uuid $$;
create function pg_temp.login(k text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object(
    'sub', pg_temp.u(k), 'role', 'authenticated')::text, true);
  set local role authenticated;
end;
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end;
$$;

-- Fixtures (sin triggers) -----------------------------------------------------
set local session_replication_role = replica;
insert into auth.users (id, email)
select pg_temp.u(k), 'f11qa-' || k || '@test.local'
from unnest(array['a01', 'b01', 'b02', 'b03', 'c01', 'd01']) k;
insert into public.user_roles (user_id, role)
select pg_temp.u(k), r from (values ('a01', 'owner'), ('b01', 'vet'), ('b02', 'vet'),
  ('b03', 'vet'), ('c01', 'foundation'), ('d01', 'admin')) v (k, r);
insert into public.owner_profiles (user_id, display_name, commune_id)
values (pg_temp.u('a01'), 'Ángela Muñoz', (select id from public.communes where name = 'Ñuñoa'));
insert into public.vet_profiles (user_id, display_name, status, submitted_at) values
  (pg_temp.u('b01'), 'Dra. Liquida', 'approved', null),
  (pg_temp.u('b02'), 'Dr. En Revisión', 'pending', now() - interval '1 day'),
  (pg_temp.u('b03'), 'Dra. Otra', 'approved', null);
insert into public.foundations (id, name, is_default) values (pg_temp.u('fd1'), 'Fundación QA F11', false);
insert into public.foundation_members (user_id, foundation_id) values (pg_temp.u('c01'), pg_temp.u('fd1'));
insert into public.pets (id, owner_id, name, species_id)
values (pg_temp.u('e01'), pg_temp.u('a01'), 'Ñandú', (select id from public.species where slug = 'perro'));
insert into public.addresses (id, owner_id, label, street_text, details, commune_id, lat, lng)
values (pg_temp.u('ad1'), pg_temp.u('a01'), 'Casa', 'Avenida Los Álamos 1234', 'Torre B depto 51',
        (select id from public.communes where name = 'Ñuñoa'), -33.4569, -70.5974);
insert into public.visits (id, owner_id, pet_id, address_id, vet_id, mode, status, commune_id,
  species_id, specialty_id, foundation_id, scheduled_at, slot, confirm_deadline, quote,
  accepted_at, started_at, completed_at, closed_at)
select pg_temp.u('f01'), pg_temp.u('a01'), pg_temp.u('e01'), pg_temp.u('ad1'), pg_temp.u('b01'),
       'scheduled', 'completed', (select id from public.communes where name = 'Ñuñoa'),
       (select id from public.species where slug = 'perro'),
       (select id from public.specialties where slug = 'general'), pg_temp.u('fd1'),
       t, tstzrange(t, t + interval '90 minutes'), t - interval '1 day',
       jsonb_build_object('vet_id', pg_temp.u('b01'), 'service_price', 26990, 'vet_payout', 22941),
       t - interval '1 day', t, t + interval '1 hour', t + interval '1 hour'
from (select now() - interval '3 days' as t) x;
insert into public.payments (id, owner_id, foundation_id, kind, status, provider, service_price,
  platform_fee, foundation_share, vet_payout, extra_donation, total, paid_at, visit_id, vet_id) values
  (pg_temp.u('aa1'), pg_temp.u('a01'), pg_temp.u('fd1'), 'visit', 'simulated_paid', 'simulated',
   26990, 4049, 810, 22941, 1500, 28490, now() - interval '3 days', pg_temp.u('f01'), pg_temp.u('b01'));
insert into public.foundation_contributions (payment_id, foundation_id, kind, amount) values
  (pg_temp.u('aa1'), pg_temp.u('fd1'), 'commission_share', 810),
  (pg_temp.u('aa1'), pg_temp.u('fd1'), 'donation', 1500);
-- b02 (vet en revisión) pidió borrar su cuenta: está bloqueado.
insert into public.deletion_requests (id, user_id, role) values (pg_temp.u('d91'), pg_temp.u('b02'), 'vet');
insert into private.push_devices (token, user_id, platform) values
  ('qa-f11-token-libre', pg_temp.u('b01'), 'android'),
  ('qa-f11-token-bloqueado', pg_temp.u('b02'), 'android');
insert into private.push_outbox (user_id, visit_id, event) values
  (pg_temp.u('b01'), pg_temp.u('f01'), 'visit_completed'),
  (pg_temp.u('b02'), pg_temp.u('f01'), 'visit_completed');
set local session_replication_role = origin;

-- 1. QA-F11-05 (HU8.6) ------------------------------------------------------------
select pg_temp.login('b01');
select is((select count(*)::int from public.payments), 0, 'el vet no lee filas de payments');
select is((select count(*)::int from public.payments where visit_id = pg_temp.u('f01')), 0,
  'ni el pago de su propia visita (dueño, donación, total, cotización)');
select is((select concat_ws(',', visit_id, kind, status, service_price, platform_fee, vet_payout)
           from public.my_payouts()),
  concat_ws(',', pg_temp.u('f01'), 'visit', 'simulated_paid', 26990, 4049, 22941),
  'my_payouts: la liquidación de su visita (servicio, comisión y su pago)');
select ok((select paid_at is not null and created_at is not null from public.my_payouts()),
  'my_payouts trae la fecha del pago');
select is((select count(*)::int from pg_proc p, unnest(p.proargnames) a
           where p.proname = 'my_payouts'
             and a in ('owner_id', 'extra_donation', 'total', 'quote_id', 'foundation_id')), 0,
  'my_payouts no expone dueño, donación, total, cotización ni fundación');
select ok((select (public.export_my_data() -> 'payouts' -> 0) ?& array['vet_payout', 'service_price']
              and not ((public.export_my_data() -> 'payouts' -> 0) ?| array['total', 'extra_donation', 'owner_id'])),
  'la exportación del vet sigue trayendo sus liquidaciones sin total ni donación');
reset role;
select pg_temp.login('b03');
select is((select count(*)::int from public.my_payouts()), 0, 'otro vet no ve esa liquidación');
reset role;
select pg_temp.login('a01');
select is((select extra_donation || ':' || total from public.payments where id = pg_temp.u('aa1')),
  '1500:28490', 'el dueño sigue viendo su pago completo');
select is((select count(*)::int from public.my_payouts()), 0, 'my_payouts no devuelve nada a un dueño');
reset role;
select pg_temp.login('c01');
select is((select count(*)::int from public.payments) + (select count(*)::int from public.my_payouts()), 0,
  'la fundación no ve pagos ni liquidaciones');
select is((select sum(total)::int from public.foundation_summary(12)), 2310,
  'foundation_summary() sigue con los totales (810 + 1500)');
reset role;
select pg_temp.login('d01');
select is((select count(*)::int from public.payments where id = pg_temp.u('aa1')), 1, 'el admin ve el pago');
reset role;
select set_config('request.jwt.claims', '', true);
select is(pg_temp.err($$ select public.my_payouts() $$), 'ok', 'my_payouts sin sesión no falla');
select is((select count(*)::int from public.my_payouts()), 0, '... y no devuelve nada');

-- 2. QA-F11-04: cuenta bloqueada ------------------------------------------------------
-- Admin: review_vet_application.
select pg_temp.login('d01');
select is(pg_temp.err($$ select public.review_vet_application(pg_temp.u('b02'), true, null, 'QA') $$),
  '42501', 'el admin no aprueba la solicitud de un vet bloqueado');
select is(pg_temp.err($$ select public.review_vet_application(pg_temp.u('b02'), false, 'Motivo', null) $$),
  '42501', 'ni la rechaza');
reset role;
select is((select status from public.vet_profiles where user_id = pg_temp.u('b02')), 'pending',
  'la solicitud del vet bloqueado sigue pendiente');
select pg_temp.login('b01');
select is(pg_temp.err($$ select private.assert_subject_not_blocked(pg_temp.u('b02')) $$), 'ok',
  'a quien no es admin el chequeo no le revela el bloqueo de otro');
reset role;

-- verify-vet-title (clave de servicio).
set local role service_role;
select is(public.any_account_blocked(array[pg_temp.u('b02'), pg_temp.u('d01')]), true,
  'any_account_blocked: detecta el vet bloqueado');
select is(public.any_account_blocked(array[pg_temp.u('b01')]), false, 'any_account_blocked: el vet libre no');
select is(public.any_account_blocked('{}'), false, 'any_account_blocked: lista vacía');
select is(pg_temp.err($$ select * from public.reserve_title_verification(pg_temp.u('b02'), false, false) $$),
  '42501', 'no se reserva cupo de verificación para un vet bloqueado');
select is(pg_temp.err($$ select * from public.reserve_title_verification(pg_temp.u('b02'), true, true) $$),
  '42501', 'tampoco a pedido del admin ni con COLMEVET');
reset role;
select is((select count(*)::int from public.title_verification_reservations where vet_id = pg_temp.u('b02')), 0,
  'y no queda ninguna reserva');
select is(pg_temp.err($$ insert into public.vet_title_verifications
    (vet_id, source, outcome, run_trigger, provider_version)
    values (pg_temp.u('b02'), 'rules', 'match', 'submit', 'qa') $$),
  '42501', 'ninguna vía registra una verificación de un vet bloqueado');
select is(pg_temp.err($$ insert into public.vet_title_verifications
    (vet_id, source, outcome, run_trigger, provider_version)
    values (pg_temp.u('b01'), 'rules', 'match', 'admin', 'qa') $$),
  'ok', 'la de un vet no bloqueado se registra');
select pg_temp.login('b01');
select is(pg_temp.err($$ select public.any_account_blocked(array[pg_temp.u('b02')]) $$), '42501',
  'any_account_blocked es solo para service_role');
reset role;

-- Auth API: GoTrue escribe en auth.users.
select is(pg_temp.err($$ update auth.users set raw_user_meta_data = '{"qa": 1}' where id = pg_temp.u('b02') $$),
  '42501', 'la cuenta bloqueada no cambia sus metadatos (PUT /auth/v1/user)');
select is(pg_temp.err($$ update auth.users set email_change = 'otro@test.local' where id = pg_temp.u('b02') $$),
  '42501', 'ni pide cambiar su email');
select is(pg_temp.err($$ update auth.users set email = 'otro@test.local' where id = pg_temp.u('b02') $$),
  '42501', 'ni cambia su email');
select is(pg_temp.err($$ update auth.users set phone = '56987654321' where id = pg_temp.u('b02') $$),
  '42501', 'ni su teléfono');
select is(pg_temp.err($$ update auth.users set encrypted_password = 'x', last_sign_in_at = now(),
    banned_until = now() + interval '1 day' where id = pg_temp.u('b02') $$),
  'ok', 'sí puede cambiar la contraseña e iniciar sesión (para cancelar); el job puede vetarla');
select is(pg_temp.err($$ update auth.users set raw_user_meta_data = '{"qa": 1}' where id = pg_temp.u('b01') $$),
  'ok', 'una cuenta no bloqueada sí cambia sus metadatos');

-- send-push: nada a cuentas bloqueadas.
set local role service_role;
create temp table t_push on commit drop as select * from public.claim_push_batch(500);
reset role;
select is((select string_agg(token, ',' order by token) from t_push where token like 'qa-f11-token-%'),
  'qa-f11-token-libre', 'send-push no recibe tokens de cuentas bloqueadas');
select is((select count(*)::int from private.push_outbox where user_id = pg_temp.u('b02') and sent_at is null), 0,
  'el aviso a la cuenta bloqueada se descarta (no queda pendiente)');

-- O-F11-a (se mantiene): con la cuenta ya bloqueada, pedir el borrado otra vez
-- choca con el pre-request; la app consulta my_deletion_request.
select pg_temp.login('b02');
select set_config('request.path', '/rpc/request_account_deletion', true);
select is(pg_temp.err($$ select public.check_request() $$), '42501',
  'con la cuenta bloqueada, pedir el borrado otra vez da 403 (O-F11-a)');
select set_config('request.path', '/rpc/my_deletion_request', true);
select is(pg_temp.err($$ select public.check_request() $$), 'ok', 'pero sí consulta su solicitud');
reset role;

-- 3. QA-F11-01: redacción (términos como los arma erase_subject) --------------------
create temp table t_terms as select array['f11qa-a01@test.local', 'Ángela Muñoz', 'Ángela', 'Muñoz',
  '+56 9 8765 4321', 'Ñandú', '941000011112222', 'Avenida Los Álamos 1234', 'Torre B depto 51'] as t;
create function pg_temp.r(p text) returns text language sql as $$
  select private.redact_pii(p, (select t from t_terms)) $$;

select is(pg_temp.r('Angela Munoz trajo a Nandu'), '[redactado] trajo a [redactado]',
  'nombre y mascota sin tildes');
select is(pg_temp.r('ÁNGELA MUÑOZ y ÑANDÚ'), '[redactado] y [redactado]', 'nombre y mascota en mayúsculas');
select is(pg_temp.r('aNgElA mUnOz, ñAnDu'), '[redactado], [redactado]', 'mayúsculas mezcladas, sin tildes');
select is(pg_temp.r('Vive en Los Álamos 1234.'), 'Vive en [redactado].', 'calle + número sin el tipo de vía');
select is(pg_temp.r('Los Alamos 1234, Torre B'), '[redactado], [redactado]',
  'calle + número sin tildes y la torre del detalle');
select is(pg_temp.r('Av. Los Alamos #1234, depto 51'), '[redactado], [redactado]',
  'calle abreviada con # y el depto del detalle');
select is(pg_temp.r('Avenida Los Álamos 1234, Torre B depto 51'), '[redactado], [redactado]',
  'la dirección completa');
select is(pg_temp.r('Fono +56 9 8765 4321.'), 'Fono [redactado].', 'teléfono +56 9 8765 4321');
select is(pg_temp.r('Fono 987 654 321.'), 'Fono [redactado].', 'teléfono 987 654 321');
select is(pg_temp.r('Fono 987654321.'), 'Fono [redactado].', 'teléfono 987654321');
select is(pg_temp.r('Fono 9-8765-4321.'), 'Fono [redactado].', 'teléfono 9-8765-4321');
select is(pg_temp.r('Fono +56987654321 o 8765 4321.'), 'Fono [redactado] o [redactado].',
  'teléfono con +56 pegado y sin el 9');
select is(pg_temp.r('Otro fono 912 345 678 o 2 2345 6789.'), 'Otro fono [redactado] o [redactado].',
  'cualquier móvil o fijo chileno, aunque no sea el del dueño');
select is(pg_temp.r('Correo F11QA-A01@TEST.LOCAL.'), 'Correo [redactado].', 'email en mayúsculas');
select is(pg_temp.r('Chip 941 000 011 112 222.'), 'Chip [redactado].', 'microchip con separadores');
select is(pg_temp.r('Otitis externa bilateral, peso 12,5 kg, T° 38,5; amoxicilina 250 mg cada 12 horas '
                    || 'por 10 días. Duerme en casa de campo, piso de cerámica; control en la torre 3 meses.'),
  'Otitis externa bilateral, peso 12,5 kg, T° 38,5; amoxicilina 250 mg cada 12 horas '
  || 'por 10 días. Duerme en casa de campo, piso de cerámica; control en la torre 3 meses.',
  'no sobre-redacta: dosis, pesos, fechas y palabras comunes quedan');
select is(pg_temp.r('Paseo por Los Álamos y la torre B12.'), 'Paseo por Los Álamos y la torre B12.',
  'la calle sin número y otra unidad no se redactan (sin falsos positivos)');

select * from finish();
rollback;
