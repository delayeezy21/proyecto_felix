-- Semillas ficticias para desarrollo local (nunca datos reales).
-- Se completan desde la fase 2 (catálogos) en adelante.

-- Versiones legales vigentes (textos en assets/legal/).
insert into public.legal_versions (kind, version, effective_from) values
  ('terms', '2026-11-16', '2026-11-16'),
  ('privacy', '2026-11-16', '2026-11-16')
on conflict (kind, version) do nothing;
