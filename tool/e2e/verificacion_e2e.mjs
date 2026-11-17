// E2E de la verificación asistida del título (docs/verificacion-automatica.md)
// contra Supabase local: Auth + REST + Storage + Edge Function verify-vet-title.
//
// Requiere el PROVEEDOR FALSO (nunca llama a COLMEVET): el edge runtime debe
// tener TITLE_VERIFICATION_PROVIDER=fake, por ejemplo en config.toml:
//   [edge_runtime.secrets]
//   TITLE_VERIFICATION_PROVIDER = "fake"
// Úsalo en un stack aislado (otro project_id y puertos). Borra los usuarios que crea.
//
// Uso: node tool/e2e/verificacion_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;

let fails = 0;
const check = (cond, msg) => { console.log(`${cond ? 'OK   ' : 'FALLA'} ${msg}`); if (!cond) fails++; };

async function call(path, { method = 'GET', token, key = PUB, body, prefer, raw, type } = {}) {
  const headers = { apikey: key };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (prefer) headers.Prefer = prefer;
  if (raw) headers['Content-Type'] = type; else if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(API + path, { method, headers, body: raw ?? (body !== undefined ? JSON.stringify(body) : undefined) });
  const text = await r.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, json };
}
const rpc = (fn, token, body = {}) => call(`/rest/v1/rpc/${fn}`, { method: 'POST', token, body });
const verify = (token, body = {}) => call('/functions/v1/verify-vet-title', { method: 'POST', token, body });

const stamp = Date.now();
const created = [];
async function newUser(tag) {
  const email = `qa-verif-${tag}-${stamp}@test.local`;
  const c = await call('/auth/v1/admin/users', { method: 'POST', key: SRV, token: SRV,
    body: { email, password: 'Felix2026', email_confirm: true } });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status}`);
  created.push(c.json.id);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password: 'Felix2026' } });
  return { token: s.json.access_token, id: c.json.id };
}
const legal = {
  terms: (await rpc('current_legal_version', undefined, { p_kind: 'terms' })).json,
  privacy: (await rpc('current_legal_version', undefined, { p_kind: 'privacy' })).json,
};
const pdf = new TextEncoder().encode('%PDF-1.4 verificacion');

/** Vet ficticio con solicitud completa; si submit, la envía. */
async function vetWithApplication(tag, name, { submit = true, university = 'Universidad de Concepción' } = {}) {
  const u = await newUser(tag);
  await rpc('complete_registration', u.token, { p_role: 'vet', p_display_name: name, p_phone: null,
    p_terms_version: legal.terms, p_privacy_version: legal.privacy });
  if (!submit) return u;
  for (const kind of ['degree_certificate', 'id_card_front']) {
    const path = `${u.id}/${kind}-${stamp}.pdf`;
    await call(`/storage/v1/object/vet-documents/${path}`, { method: 'POST', token: u.token, raw: pdf, type: 'application/pdf' });
    await call('/rest/v1/vet_documents', { method: 'POST', token: u.token,
      body: { vet_id: u.id, kind, storage_path: path, mime: 'application/pdf', size_bytes: pdf.length } });
  }
  const sp = (await call('/rest/v1/species?select=id&slug=eq.perro', { token: u.token })).json[0].id;
  const spec = (await call('/rest/v1/specialties?select=id&slug=eq.general', { token: u.token })).json[0].id;
  await call('/rest/v1/vet_species', { method: 'POST', token: u.token, body: { vet_id: u.id, species_id: sp } });
  await call('/rest/v1/vet_specialties', { method: 'POST', token: u.token, body: { vet_id: u.id, specialty_id: spec } });
  await call(`/rest/v1/vet_profiles?user_id=eq.${u.id}`, { method: 'PATCH', token: u.token,
    body: { university, graduation_year: 2018, title_verification_code: 'ABC-123',
            declaration_accepted_at: new Date().toISOString() } });
  const s = await rpc('submit_vet_application', u.token);
  if (s.status !== 200) throw new Error(`enviar ${tag}: ${s.status} ${JSON.stringify(s.json)}`);
  return u;
}

try {
  check(typeof legal.terms === 'string', 'API local disponible');
  const vet = await vetWithApplication('colegiado', 'Dr. Colegiado Prueba');
  const draft = await vetWithApplication('borrador', 'Dra. Borrador Prueba', { submit: false });
  const failing = await vetWithApplication('falla', 'Dra. Falla Prueba', { university: 'Instituto Inventado' });
  const owner = await newUser('dueno');
  await rpc('complete_registration', owner.token, { p_role: 'owner', p_display_name: 'Dueño QA', p_phone: null,
    p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: (await call('/rest/v1/communes?select=id&limit=1')).json[0]?.id });
  const admin = await newUser('admin');
  await call('/rest/v1/user_roles', { method: 'POST', key: SRV, token: SRV, body: { user_id: admin.id, role: 'admin' } });

  // --- Disparo al enviar (como la app) ------------------------------------------
  const r1 = await verify(vet.token);
  check(r1.status === 200, `el vet dispara la verificación de su solicitud enviada (HTTP ${r1.status})`);
  const bySource = Object.fromEntries((r1.json.results ?? []).map((r) => [r.source, r]));
  check(!!bySource.fake, 'el proveedor falso está activo (TITLE_VERIFICATION_PROVIDER=fake)');
  check(bySource.rules?.outcome === 'match' && bySource.rules?.risk === 'low'
        && bySource.rules?.suggested_checks?.includes('university'),
    'reglas: universidad reconocida, riesgo bajo, sugiere el chequeo de universidad');
  check(bySource.fake?.outcome === 'match' && bySource.fake?.suggested_checks?.includes('colmevet'),
    'proveedor: una coincidencia sugiere el chequeo opcional COLMEVET');
  check(!JSON.stringify(r1.json).toLowerCase().includes('colegiado prueba'), 'la respuesta no trae datos personales');

  const own = await call(`/rest/v1/vet_title_verifications?select=*&vet_id=eq.${vet.id}`, { token: vet.token });
  check(own.status === 200 && own.json.length === 2 && own.json.every((r) => r.run_trigger === 'submit'
        && r.requested_by === vet.id), 'quedan 2 resultados (submit) visibles para el propio vet');
  check(own.json.every((r) => !JSON.stringify(r.evidence).toLowerCase().includes('prueba')),
    'la evidencia guardada no contiene el nombre');

  // --- Autorización ----------------------------------------------------------------
  const anon = await call('/functions/v1/verify-vet-title', { method: 'POST', body: {} });
  check(anon.status === 401, `sin sesión no se puede invocar (HTTP ${anon.status})`);
  const cross = await verify(failing.token, { vet_id: vet.id });
  check(cross.status === 403, `un vet no verifica la solicitud de otro (HTTP ${cross.status})`);
  const ownerCall = await verify(owner.token, { vet_id: vet.id });
  check(ownerCall.status === 403, `un dueño no puede invocarla (HTTP ${ownerCall.status})`);
  const draftCall = await verify(draft.token);
  check(draftCall.status === 409, `una solicitud sin enviar no se verifica (HTTP ${draftCall.status})`);
  const peekOther = await call(`/rest/v1/vet_title_verifications?vet_id=eq.${vet.id}`, { token: failing.token });
  check(peekOther.status === 200 && peekOther.json.length === 0, 'otro vet no ve resultados ajenos');
  const peekOwner = await call(`/rest/v1/vet_title_verifications?vet_id=eq.${vet.id}`, { token: owner.token });
  check(peekOwner.status === 200 && peekOwner.json.length === 0, 'un dueño no ve resultados');
  const forge = await call('/rest/v1/vet_title_verifications', { method: 'POST', token: vet.token,
    body: { vet_id: vet.id, source: 'rules', outcome: 'match', risk: 'low', run_trigger: 'submit', provider_version: 'x' } });
  check(forge.status === 401 || forge.status === 403, `el vet no puede fabricar resultados (HTTP ${forge.status})`);
  const del = await call(`/rest/v1/vet_title_verifications?vet_id=eq.${vet.id}`, { method: 'DELETE', token: admin.token });
  const still = await call(`/rest/v1/vet_title_verifications?vet_id=eq.${vet.id}`, { token: admin.token });
  check(del.status >= 400 && still.json.length === 2, `ni el admin borra resultados (HTTP ${del.status})`);

  // --- Admin y límite de tasa -----------------------------------------------------------
  const badId = await verify(admin.token, { vet_id: 'no-es-uuid' });
  check(badId.status === 400, 'el admin debe indicar un vet_id válido');
  const a1 = await verify(admin.token, { vet_id: vet.id });
  check(a1.status === 200, 'el admin ejecuta la verificación desde la revisión');
  const adminRows = await call(`/rest/v1/vet_title_verifications?select=run_trigger,requested_by&vet_id=eq.${vet.id}&run_trigger=eq.admin`, { token: admin.token });
  check(adminRows.json.length === 2 && adminRows.json.every((r) => r.requested_by === admin.id),
    'queda registrado quién la ejecutó (admin)');
  // QA-20: el admin tiene su propio cupo (10 cada 10 min por solicitud),
  // independiente del cupo del vet (3 cada 10 min).
  const adminRuns = [];
  for (let i = 0; i < 9; i++) adminRuns.push((await verify(admin.token, { vet_id: vet.id })).status);
  const aOver = await verify(admin.token, { vet_id: vet.id });
  check(adminRuns.every((s) => s === 200) && aOver.status === 429,
    `límite del admin: 10 ejecuciones por solicitud cada 10 min (11.ª → HTTP ${aOver.status})`);

  // --- Un proveedor que falla no rompe nada ------------------------------------------------
  const f = await verify(admin.token, { vet_id: failing.id });
  const fs = Object.fromEntries((f.json.results ?? []).map((r) => [r.source, r]));
  check(f.status === 200 && fs.fake?.outcome === 'error' && fs.rules?.outcome === 'no_match' && fs.rules?.risk === 'medium',
    'si el proveedor falla queda "error" y las reglas igual se registran (universidad desconocida → riesgo medio)');

  // --- El flujo manual sigue intacto ------------------------------------------------------
  const rev = await rpc('review_vet_application', admin.token, { p_vet_id: failing.id, p_approve: true,
    p_notes: '[x] El nombre coincide\nVerificación automática: Reglas internas: no_match (riesgo medio)' });
  check(rev.status === 200 && rev.json === 'approved', 'el admin aprueba manualmente aunque la verificación falló');
  const after = await verify(admin.token, { vet_id: failing.id });
  check(after.status === 409, 'una solicitud ya resuelta no se vuelve a verificar');
} finally {
  // Limpieza: borra los usuarios creados (sus filas se van en cascada).
  for (const id of created) {
    await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
  }
}

console.log(fails === 0 ? '\nVerificación asistida: TODO OK' : `\nVerificación asistida: ${fails} fallas`);
process.exit(fails ? 1 : 0);
