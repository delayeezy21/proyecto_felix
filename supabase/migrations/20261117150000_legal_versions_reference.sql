-- Versiones legales vigentes como dato de referencia (docs/despliegue-beta.md).
--
-- Hasta ahora solo existían en seed.sql, que no se aplica en la nube: sin estas
-- filas, current_legal_version() devuelve null y complete_registration no
-- puede registrar a nadie. Los textos están en assets/legal/.
-- Idempotente: seed.sql inserta las mismas filas con "on conflict do nothing".
insert into public.legal_versions (kind, version, effective_from) values
  ('terms', '2026-11-16', '2026-11-16'),
  ('privacy', '2026-11-16', '2026-11-16')
on conflict (kind, version) do nothing;
