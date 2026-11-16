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
  ('Clínica Demo 24h Sur', 'Concepción', 'Calle Demo 321', '+56 41 200 0004')
) as t (name, commune, address, phone)
join public.communes c on c.name = t.commune;
