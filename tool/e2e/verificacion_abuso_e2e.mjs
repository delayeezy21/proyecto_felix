// QA: abuso y bordes de la Edge Function verify-vet-title (verificación
// asistida). Complementa tool/e2e/verificacion_e2e.mjs.
//
// SOLO en un stack aislado con TITLE_VERIFICATION_PROVIDER=fake: nunca llama a
// COLMEVET ni a otros sitios externos. Ver docs/qa/QA-verificacion-*.md.
//
// Uso: node tool/e2e/verificacion_abuso_e2e.mjs "<status json del stack aislado>"
//
// OK = esperado · DEFECTO <ID> = defecto conocido (sale con código 2).
const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;
if (/:5432[0-9]$/.test(new URL(API).host)) {
  throw new Error('Este script es para un stack aislado (no el compartido de puertos 543xx).');
}

let fails = 0;
let defects = 0;
const check = (cond, msg) => { console.log(`${cond ? 'OK     ' : 'FALLA  '} ${msg}`); if (!cond) fails++; };
const known = (cond, id, msg) => { console.log(`${cond ? 'OK     ' : `DEFECTO ${id}`} ${msg}`); if (!cond) defects++; };

async function call(path, { method = 'GET', token, key = PUB, body, raw, type, headers: extra } = {}) {
  const headers = { apikey: key, ...extra };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (raw !== undefined) headers['Content-Type'] = type;
  else if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(API + path, { method, headers, body: raw ?? (body !== undefined ? JSON.stringify(body) : undefined) });
  const text = await r.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, json };
}
const rest = (p, o) => call(`/rest/v1/${p}`, o);
const rpc = (fn, token, body = {}) => rest(`rpc/${fn}`, { method: 'POST', token, body });
const verify = (token, body = {}) => call('/functions/v1/verify-vet-title', { method: 'POST', token, body });

const stamp = Date.now();
const created = [];
async function newUser(tag) {
  const email = `qa-abuso-${tag}-${stamp}@test.local`;
  const c = await call('/auth/v1/admin/users', { method: 'POST', key: SRV, token: SRV,
    body: { email, password: 'Felix2026', email_confirm: true } });
  created.push(c.json.id);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password: 'Felix2026' } });
  return { token: s.json.access_token, id: c.json.id };
}
const legal = {
  terms: (await rpc('current_legal_version', undefined, { p_kind: 'terms' })).json,
  privacy: (await rpc('current_legal_version', undefined, { p_kind: 'privacy' })).json,
};
const pdf = new TextEncoder().encode('%PDF-1.4 qa');

async function submittedVet(tag, name) {
  const u = await newUser(tag);
  await rpc('complete_registration', u.token, { p_role: 'vet', p_display_name: name, p_phone: null,
    p_terms_version: legal.terms, p_privacy_version: legal.privacy });
  for (const kind of ['degree_certificate', 'id_card_front']) {
    const path = `${u.id}/${kind}-${stamp}.pdf`;
    await call(`/storage/v1/object/vet-documents/${path}`, { method: 'POST', token: u.token, raw: pdf, type: 'application/pdf' });
    await rest('vet_documents', { method: 'POST', token: u.token,
      body: { vet_id: u.id, kind, storage_path: path, mime: 'application/pdf', size_bytes: pdf.length } });
  }
  const perro = (await rest('species?select=id&slug=eq.perro', { token: u.token })).json[0].id;
  const general = (await rest('specialties?select=id&slug=eq.general', { token: u.token })).json[0].id;
  await rest('vet_species', { method: 'POST', token: u.token, body: { vet_id: u.id, species_id: perro } });
  await rest('vet_specialties', { method: 'POST', token: u.token, body: { vet_id: u.id, specialty_id: general } });
  await rest(`vet_profiles?user_id=eq.${u.id}`, { method: 'PATCH', token: u.token, body: {
    university: 'Universidad de Chile', graduation_year: 2015, declaration_accepted_at: new Date().toISOString() } });
  const s = await rpc('submit_vet_application', u.token);
  if (s.status !== 200) throw new Error(`envío ${tag}: ${JSON.stringify(s.json)}`);
  return u;
}
const rulesRows = async (vetId) =>
  (await rest(`vet_title_verifications?select=id&source=eq.rules&vet_id=eq.${vetId}`, { key: SRV, token: SRV })).json.length;

try {
  const admin = await newUser('admin');
  await rest('user_roles', { method: 'POST', key: SRV, token: SRV, body: { user_id: admin.id, role: 'admin' } });

  // --- Autenticación y entradas -------------------------------------------
  const vet = await submittedVet('vet', 'Dra. Ana Colegiado Prueba');
  const pubAsJwt = await verify(PUB);
  check(pubAsJwt.status === 401, `la clave publicable como token no autoriza (HTTP ${pubAsJwt.status})`);
  const garbage = await verify('xxx.yyy.zzz');
  check(garbage.status === 401, `un JWT inválido no autoriza (HTTP ${garbage.status})`);
  const get = await call('/functions/v1/verify-vet-title', { method: 'GET', token: vet.token });
  check(get.status === 405, `GET → 405 (HTTP ${get.status})`);
  const badJson = await call('/functions/v1/verify-vet-title', { method: 'POST', token: admin.token, raw: '{no json', type: 'application/json' });
  check(badJson.status === 400 && badJson.json.error === 'invalid_vet_id', `JSON inválido del admin → 400 (HTTP ${badJson.status})`);
  const injected = await verify(admin.token, { vet_id: "' or 1=1 --" });
  check(injected.status === 400, 'vet_id no UUID → 400');
  const ghost = await verify(admin.token, { vet_id: '00000000-0000-0000-0000-000000000000' });
  check(ghost.status === 409, `vet inexistente → 409 (HTTP ${ghost.status})`);
  const foundation = await newUser('fundacion');
  await rest('user_roles', { method: 'POST', key: SRV, token: SRV, body: { user_id: foundation.id, role: 'foundation' } });
  check((await verify(foundation.token)).status === 403, 'una fundación no puede invocarla');
  const own = await verify(vet.token, { vet_id: vet.id });
  check(own.status === 200, 'el vet puede indicar su propio vet_id');
  check(JSON.stringify(own.json).indexOf('Ana') < 0, 'la respuesta no repite el nombre del vet');

  // --- Límite de tasa bajo concurrencia ------------------------------------
  const burstVet = await submittedVet('rafaga', 'Dr. Bruno Rafaga Prueba');
  const burst = await Promise.all(Array.from({ length: 10 }, () => verify(burstVet.token)));
  const okCount = burst.filter((r) => r.status === 200).length;
  const rows = await rulesRows(burstVet.id);
  known(rows <= 3, 'QA-19',
    `10 invocaciones simultáneas respetan el límite de 3 por vet (200: ${okCount}, filas: ${rows})`);

  // --- La cuota del vet bloquea al admin ------------------------------------
  const spamVet = await submittedVet('spam', 'Dra. Carla Spam Prueba');
  for (let i = 0; i < 3; i++) await verify(spamVet.token);
  const adminRun = await verify(admin.token, { vet_id: spamVet.id });
  known(adminRun.status === 200, 'QA-20',
    `el admin puede ejecutar la verificación aunque el vet haya gastado su cuota (HTTP ${adminRun.status})`);

  // --- Timeout del proveedor --------------------------------------------------
  const slowVet = await submittedVet('lento', 'Dr. Diego Lento Prueba');
  const t0 = Date.now();
  const slow = await verify(slowVet.token);
  const secs = (Date.now() - t0) / 1000;
  const fake = slow.json.results?.find((r) => r.source === 'fake');
  check(slow.status === 200 && fake?.outcome === 'error' && secs < 12,
    `proveedor lento: corta por timeout y queda "error" (${secs.toFixed(1)} s)`);
  const rulesSlow = slow.json.results?.find((r) => r.source === 'rules');
  check(rulesSlow?.outcome === 'match', 'las reglas igual quedan registradas');

  // --- Nadie escribe la tabla salvo service_role -----------------------------
  const forge = await rest('vet_title_verifications', { method: 'POST', token: admin.token, body: {
    vet_id: vet.id, source: 'colmevet', outcome: 'match', suggested_checks: ['colmevet'],
    run_trigger: 'admin', provider_version: 'x' } });
  check(forge.status === 401 || forge.status === 403, `ni el admin fabrica resultados por REST (HTTP ${forge.status})`);
  const upd = await rest(`vet_title_verifications?vet_id=eq.${vet.id}`, { method: 'PATCH', token: admin.token, body: { outcome: 'match' } });
  check(upd.status === 401 || upd.status === 403, 'nadie modifica resultados');
  const anonRead = await rest('vet_title_verifications?select=id&limit=1');
  check(anonRead.status === 401 || (anonRead.status === 200 && anonRead.json.length === 0), 'anónimo no lee resultados');
  const quota = await rpc('reserve_title_verification', vet.token, { p_vet_id: vet.id, p_by_admin: false, p_colmevet: false });
  check(quota.status >= 400, 'un usuario no consulta la cuota');
  const bigEvidence = await rest('vet_title_verifications', { method: 'POST', key: SRV, token: SRV, body: {
    vet_id: vet.id, source: 'rules', outcome: 'match', evidence: { x: 'a'.repeat(2000) },
    run_trigger: 'admin', provider_version: 'x' } });
  check(bigEvidence.status === 400, 'evidencia > 1 KB rechazada incluso para service_role');
  const badCheck = await rest('vet_title_verifications', { method: 'POST', key: SRV, token: SRV, body: {
    vet_id: vet.id, source: 'rules', outcome: 'match', suggested_checks: ['name'],
    run_trigger: 'admin', provider_version: 'x' } });
  check(badCheck.status === 400, "ningún proveedor puede sugerir el chequeo 'name'");
} finally {
  for (const id of created) {
    const objs = await call('/storage/v1/object/list/vet-documents', { method: 'POST', key: SRV, token: SRV, body: { prefix: id } });
    const names = Array.isArray(objs.json) ? objs.json.map((o) => `${id}/${o.name}`) : [];
    if (names.length) await call('/storage/v1/object/vet-documents', { method: 'DELETE', key: SRV, token: SRV, body: { prefixes: names } });
  }
  for (const id of [...created].reverse()) await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
}

console.log(`\nAbuso verify-vet-title: ${fails} FALLA(s), ${defects} DEFECTO(s).`);
process.exit(fails ? 1 : defects ? 2 : 0);
