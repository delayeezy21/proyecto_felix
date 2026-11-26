-- Beta local en San Miguel (Santiago): deja a los usuarios demo listos para
-- probar desde esa comuna. Idempotente y SOLO para el stack local
-- (datos ficticios). Ejecutar como postgres:
--   docker exec -i supabase_db_proyecto-felix psql -U postgres -v ON_ERROR_STOP=1 < tool/demo/beta_san_miguel.sql
begin;

-- Punto de partida de Dr Boby (demo@felix.local) en San Miguel, cerca de la
-- Municipalidad. El desplazamiento fijo de quote_origin (1–2 km) se conserva.
update public.vet_bases vb
set commune_id = c.id, lat = -33.4970, lng = -70.6510, updated_at = now()
from auth.users u, public.communes c
where vb.vet_id = u.id and u.email = 'demo@felix.local' and c.name = 'San Miguel';

-- El dueño demo usa por defecto su dirección activa de San Miguel; las demás
-- direcciones demo de otras comunas quedan inactivas (no se borran).
update public.addresses a
set active = (c.name = 'San Miguel')
from auth.users u, public.communes c
where a.owner_id = u.id and u.email = 'dueno@felix.local' and c.id = a.commune_id;

-- Clínica 24 h FICTICIA en San Miguel (también está en seed.sql).
insert into public.emergency_clinics (name, commune_id, address, phone)
select 'Clínica Demo 24h San Miguel', c.id, 'Avenida Inventada 555', '+56 2 2000 0005'
from public.communes c
where c.name = 'San Miguel'
  and not exists (select 1 from public.emergency_clinics e where e.name = 'Clínica Demo 24h San Miguel');

-- Dr Boby atiende consultas agendadas: Medicina general y Vacunación y
-- prevención (además de Urgencias). Sin especialidad general no aparece al
-- agendar una consulta normal.
insert into public.vet_specialties (vet_id, specialty_id)
select u.id, sp.id
from auth.users u, public.specialties sp
where u.email = 'demo@felix.local'
  and sp.name in ('Medicina general', 'Vacunación y prevención', 'Urgencias')
on conflict do nothing;

commit;

-- Resumen
select u.email, c.name as comuna, vb.lat, vb.lng
from public.vet_bases vb join auth.users u on u.id = vb.vet_id
join public.communes c on c.id = vb.commune_id
where u.email = 'demo@felix.local';
select a.label, c.name as comuna, a.active
from public.addresses a join auth.users u on u.id = a.owner_id
join public.communes c on c.id = a.commune_id
where u.email = 'dueno@felix.local';
