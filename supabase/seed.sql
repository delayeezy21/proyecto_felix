-- Semillas ficticias para desarrollo local (nunca datos reales).
-- Se completan desde la fase 2 (catálogos) en adelante.

-- Versiones legales vigentes (textos en assets/legal/).
insert into public.legal_versions (kind, version, effective_from) values
  ('terms', '2026-11-16', '2026-11-16'),
  ('privacy', '2026-11-16', '2026-11-16')
on conflict (kind, version) do nothing;

-- Clínicas 24 h FICTICIAS (demo). Nunca datos de clínicas reales en semillas.
insert into public.emergency_clinics (name, commune_id, address, phone)
select t.name, c.id, t.address, t.phone
from (values
  ('Clínica Demo 24h Centro', 'Santiago', 'Calle Ficticia 123', '+56 2 2000 0001'),
  ('Clínica Demo 24h Oriente', 'Providencia', 'Avenida Ejemplo 456', '+56 2 2000 0002'),
  ('Clínica Demo 24h Costa', 'Viña del Mar', 'Pasaje Prueba 789', '+56 32 200 0003'),
  ('Clínica Demo 24h Sur', 'Concepción', 'Calle Demo 321', '+56 41 200 0004'),
  ('Clínica Demo 24h San Miguel', 'San Miguel', 'Avenida Inventada 555', '+56 2 2000 0005')
) as t (name, commune, address, phone)
join public.communes c on c.name = t.commune;

-- Fundaciones FICTICIAS (demo, fase 5). La primera es la por defecto.
-- Los miembros (rol `foundation`) se crean por SQL, igual que el admin.
insert into public.foundations (name, description, is_default) values
  ('Fundación Demo Patitas', 'Rescate y esterilización (datos ficticios).', true),
  ('Fundación Demo Bigotes', 'Colonias felinas (datos ficticios).', false),
  ('Fundación Demo Huellas', 'Adopción responsable (datos ficticios).', false)
on conflict (name) do nothing;

-- Miembro de fundación DEMO (fase 6). Solo para desarrollo local: el seed
-- nunca se aplica en la nube (docs/despliegue-beta.md). Ingreso:
-- fundacion.patitas@demo.felix.test / FelixDemo2026 (contraseña ficticia).
insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change)
values ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-00000000de01',
  'authenticated', 'authenticated', 'fundacion.patitas@demo.felix.test',
  extensions.crypt('FelixDemo2026', extensions.gen_salt('bf')), now(),
  '{"provider": "email", "providers": ["email"]}', '{}', now(), now(), '', '', '', '')
on conflict (id) do nothing;
insert into auth.identities (provider_id, user_id, identity_data, provider,
  last_sign_in_at, created_at, updated_at)
values ('00000000-0000-0000-0000-00000000de01', '00000000-0000-0000-0000-00000000de01',
  '{"sub": "00000000-0000-0000-0000-00000000de01", "email": "fundacion.patitas@demo.felix.test", "email_verified": true}',
  'email', now(), now(), now())
on conflict do nothing;
insert into public.user_roles (user_id, role)
values ('00000000-0000-0000-0000-00000000de01', 'foundation')
on conflict (user_id) do nothing;
insert into public.foundation_members (user_id, foundation_id)
select '00000000-0000-0000-0000-00000000de01', f.id
from public.foundations f where f.name = 'Fundación Demo Patitas'
on conflict (user_id) do nothing;

-- Aportes DEMO para el panel de la fundación: tres pagos simulados ya
-- anonimizados (sin dueño, visita ni vet) en los últimos tres meses. El pago
-- nace pendiente y al pagarse el trigger crea los aportes; luego se fecha el
-- aporte como el pago para que el detalle por mes tenga datos.
do $$
declare
  f uuid := (select id from public.foundations where name = 'Fundación Demo Patitas');
  m integer;
  p uuid;
begin
  if f is null or exists (select 1 from public.payments where foundation_id = f) then
    return;
  end if;
  for m in 0..2 loop
    insert into public.payments (foundation_id, kind, service_price, platform_fee,
      foundation_share, vet_payout, extra_donation, total, created_at)
    values (f, 'visit', 26990, 4049, 810, 22941, 1000 * m, 26990 + 1000 * m,
      now() - make_interval(months => m))
    returning id into p;
    update public.payments set status = 'simulated_paid', paid_at = now() where id = p;
    update public.foundation_contributions
    set created_at = now() - make_interval(months => m) where payment_id = p;
  end loop;
end;
$$;
