// E2E de la fase 3 (onboarding de vets) contra Supabase local: Auth + REST +
// Storage + Edge Function de purga.
// Uso: node tool/e2e/vet_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;

let fails = 0;
const check = (cond, msg) => { console.log(`${cond ? 'OK  ' : 'FALLA'} ${msg}`); if (!cond) fails++; };

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

const stamp = Date.now();
async function newUser(tag) {
  const email = `${tag}-${stamp}@test.local`;
  const c = await call('/auth/v1/admin/users', { method: 'POST', key: SRV, token: SRV,
    body: { email, password: 'Felix2026', email_confirm: true } });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status}`);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password: 'Felix2026' } });
  return { token: s.json.access_token, id: s.json.user.id };
}

const legal = {
  terms: (await call('/rest/v1/rpc/current_legal_version', { method: 'POST', body: { p_kind: 'terms' } })).json,
  privacy: (await call('/rest/v1/rpc/current_legal_version', { method: 'POST', body: { p_kind: 'privacy' } })).json,
};
async function registerVet(u, name) {
  return call('/rest/v1/rpc/complete_registration', { method: 'POST', token: u.token, body: {
    p_role: 'vet', p_display_name: name, p_phone: null,
    p_terms_version: legal.terms, p_privacy_version: legal.privacy } });
}

const vet = await newUser('vet-e2e');
const other = await newUser('vet-otro');
const owner = await newUser('dueno-e2e');
check((await registerVet(vet, 'Dra. E2E')).status === 200, 'el vet completa el registro');
await registerVet(other, 'Dr. Otro');

// --- Subida de documentos (Storage real) ---------------------------------------
const pdf = new TextEncoder().encode('%PDF-1.4 certificado de prueba');
const jpg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
const titlePath = `${vet.id}/titulo-${stamp}.pdf`;
const idPath = `${vet.id}/cedula-${stamp}.jpg`;

const up1 = await call(`/storage/v1/object/vet-documents/${titlePath}`, { method: 'POST', token: vet.token, raw: pdf, type: 'application/pdf' });
check(up1.status === 200, `el vet sube su certificado (HTTP ${up1.status})`);
const up2 = await call(`/storage/v1/object/vet-documents/${idPath}`, { method: 'POST', token: vet.token, raw: jpg, type: 'image/jpeg' });
check(up2.status === 200, 'el vet sube su cédula');

const big = await call(`/storage/v1/object/vet-documents/${vet.id}/grande.pdf`, { method: 'POST', token: vet.token,
  raw: new Uint8Array(5 * 1024 * 1024 + 10), type: 'application/pdf' });
check(big.status >= 400, `rechaza archivos de más de 5 MB (HTTP ${big.status})`);
const exe = await call(`/storage/v1/object/vet-documents/${vet.id}/virus.exe`, { method: 'POST', token: vet.token,
  raw: new Uint8Array([77, 90]), type: 'application/x-msdownload' });
check(exe.status >= 400, `rechaza tipos no permitidos (HTTP ${exe.status})`);
const foreign = await call(`/storage/v1/object/vet-documents/${other.id}/intruso.pdf`, { method: 'POST', token: vet.token, raw: pdf, type: 'application/pdf' });
check(foreign.status >= 400, 'no sube a la carpeta de otro vet');
const ownerUp = await call(`/storage/v1/object/vet-documents/${owner.id}/x.pdf`, { method: 'POST', token: owner.token, raw: pdf, type: 'application/pdf' });
check(ownerUp.status >= 400, 'un usuario sin rol de vet no sube documentos');

const docs = await call('/rest/v1/vet_documents', { method: 'POST', token: vet.token, prefer: 'return=representation', body: [
  { vet_id: vet.id, kind: 'degree_certificate', storage_path: titlePath, mime: 'application/pdf', size_bytes: pdf.length },
  { vet_id: vet.id, kind: 'id_card_front', storage_path: idPath, mime: 'image/jpeg', size_bytes: jpg.length },
] });
check(docs.status === 201 && docs.json.length === 2, 'el vet registra sus 2 documentos');

const peek = await call(`/storage/v1/object/authenticated/vet-documents/${titlePath}`, { token: other.token });
check(peek.status >= 400, `otro vet no descarga documentos ajenos (HTTP ${peek.status})`);
const peekOwner = await call(`/storage/v1/object/authenticated/vet-documents/${titlePath}`, { token: owner.token });
check(peekOwner.status >= 400, 'un dueño no descarga documentos de vets');

// --- Perfil, especies, especialidades, horario y envío ------------------------------
const species = (await call('/rest/v1/species?select=id&slug=eq.perro', { token: vet.token })).json[0].id;
const specialty = (await call('/rest/v1/specialties?select=id&slug=eq.general', { token: vet.token })).json[0].id;
await call('/rest/v1/vet_species', { method: 'POST', token: vet.token, body: { vet_id: vet.id, species_id: species } });
await call('/rest/v1/vet_specialties', { method: 'POST', token: vet.token, body: { vet_id: vet.id, specialty_id: specialty } });
const av = await call('/rest/v1/vet_availability', { method: 'POST', token: vet.token,
  body: { vet_id: vet.id, weekday: 2, start_min: 540, end_min: 780 } });
check(av.status === 201, 'el vet define un bloque de disponibilidad');

const early = await call('/rest/v1/rpc/submit_vet_application', { method: 'POST', token: vet.token, body: {} });
check(early.status >= 400, 'no se envía con datos incompletos (falta universidad y declaración)');

const prof = await call(`/rest/v1/vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, prefer: 'return=representation',
  body: { university: 'Universidad de Concepción', graduation_year: 2018, title_verification_code: 'ABC-123',
          declaration_accepted_at: new Date().toISOString() } });
check(prof.status === 200, 'el vet completa sus datos y la declaración jurada');

const sub = await call('/rest/v1/rpc/submit_vet_application', { method: 'POST', token: vet.token, body: {} });
check(sub.status === 200, 'el vet envía su solicitud');

const self = await call(`/rest/v1/vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, body: { status: 'approved' } });
check(self.status === 403, `el vet no puede aprobarse a sí mismo (HTTP ${self.status})`);

// --- Revisión del admin ---------------------------------------------------------------
const admin = await newUser('admin-vet');
await call('/rest/v1/user_roles', { method: 'POST', key: SRV, token: SRV, body: { user_id: admin.id, role: 'admin' } });

const sign = await call(`/storage/v1/object/sign/vet-documents/${titlePath}`, { method: 'POST', token: admin.token, body: { expiresIn: 60 } });
check(sign.status === 200 && sign.json.signedURL, 'el admin obtiene un enlace temporal (60 s) al documento');

const ownerReview = await call('/rest/v1/rpc/review_vet_application', { method: 'POST', token: owner.token,
  body: { p_vet_id: vet.id, p_approve: true } });
check(ownerReview.status >= 400, 'un dueño no puede aprobar vets');

const review = await call('/rest/v1/rpc/review_vet_application', { method: 'POST', token: admin.token,
  body: { p_vet_id: vet.id, p_approve: true, p_notes: 'Código verificado en la universidad' } });
check(review.status === 200 && review.json === 'approved', 'el admin aprueba la solicitud');

// --- Purga ------------------------------------------------------------------------------
const noAuth = await fetch(`${API}/functions/v1/purge-vet-documents`, { method: 'POST',
  headers: { Authorization: `Bearer ${vet.token}`, apikey: PUB } });
check(noAuth.status === 403, 'la purga no la puede invocar un usuario');

await call(`/rest/v1/vet_documents?vet_id=eq.${vet.id}`, { method: 'PATCH', key: SRV, token: SRV,
  body: { purge_after: new Date(Date.now() - 1000).toISOString() } });
const purge = await fetch(`${API}/functions/v1/purge-vet-documents`, { method: 'POST',
  headers: { Authorization: `Bearer ${SRV}`, 'Content-Type': 'application/json' }, body: '{}' });
const purgeJson = await purge.json();
check(purge.status === 200 && purgeJson.purged >= 2, `la purga borra los documentos vencidos (${purgeJson.purged})`);

const gone = await call(`/storage/v1/object/authenticated/vet-documents/${titlePath}`, { token: admin.token });
check(gone.status >= 400, 'el archivo ya no existe en Storage');
const meta = await call(`/rest/v1/vet_documents?select=storage_path,purged_at,review_status&vet_id=eq.${vet.id}`, { token: admin.token });
check(meta.json.length === 2 && meta.json.every((d) => d.storage_path === null && d.purged_at && d.review_status === 'accepted'),
  'quedan solo los metadatos (revisado y purgado)');
const verified = await call(`/rest/v1/vet_profiles?select=status,identity_verified_at,verified_by&user_id=eq.${vet.id}`, { token: vet.token });
check(verified.json[0].status === 'approved' && verified.json[0].verified_by === admin.id,
  'el vet queda aprobado y con registro de quién lo verificó');

console.log(fails === 0 ? '\nE2E fase 3: TODO OK' : `\nE2E fase 3: ${fails} fallas`);
process.exit(fails ? 1 : 0);
