-- Fase 5 (decisión de negocio, 2026-11-17): la consulta general a domicilio
-- cuesta $26.990 CLP, todo incluido hasta 5 km (10 % menos que los $30.000
-- habituales de la competencia). Desde el km 5 corre el recargo vigente de
-- pricing_config ($500/km). Comisión 15 % → $4.049 (fundación 20 % = $810) y
-- vet $22.941.
--
-- Es un dato de referencia: se cambia aquí (y el admin lo puede ajustar desde
-- su panel; queda en admin_audit_log), nunca fijo en el código.
update public.tariffs t
set base_price = 26990
from public.specialties s
where s.id = t.specialty_id and s.slug = 'general' and t.species_id is null;
