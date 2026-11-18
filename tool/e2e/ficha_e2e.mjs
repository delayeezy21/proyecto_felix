// E2E de la fase 7 (ficha clínica) contra Supabase local: Auth + REST +
// Storage + Edge Function `clinical-attachment-url`, y SQL directo (docker
// exec) solo para simular el paso del tiempo.
// Uso: node tool/e2e/ficha_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
// Crea usuarios ficticios y los borra al final (la ficha es solo inserción:
// su limpieza usa felix.record_maintenance, como el futuro job de borrado).
import { backdateStart, shiftVisit, sqlRunner } from './sql.mjs';

const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;
const sql = sqlRunner(st);
const BUCKET = 'clinical-attachments';

let fails = 0;
const check = (cond, msg) => { console.log(`${cond ? 'OK  ' : 'FALLA'} ${msg}`); if (!cond) fails++; };

async function call(path, { method = 'GET', token, key = PUB, body, prefer, raw, type } = {}) {
  const headers = { apikey: key };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (prefer) headers.Prefer = prefer;
  if (raw !== undefined) headers['Content-Type'] = type ?? 'application/octet-stream';
  else if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(API + path, {
    method, headers, body: raw !== undefined ? raw : body !== undefined ? JSON.stringify(body) : undefined });
  const buf = Buffer.from(await r.arrayBuffer());
  let json; try { json = JSON.parse(buf.toString()); } catch { json = buf.toString(); }
  return { status: r.status, json, buf };
}
const rpc = (name, body, token) => call(`/rest/v1/rpc/${name}`, { method: 'POST', token, body });
const svc = (path, body, method = 'POST') => call(path, { method, key: SRV, token: SRV, body });
const sign = (attachmentId, token) => call('/functions/v1/clinical-attachment-url', {
  method: 'POST', token, body: { attachment_id: attachmentId } });
const upload = (path, token, bytes = PDF) => call(`/storage/v1/object/${BUCKET}/${path}`, {
  method: 'POST', token, raw: bytes, type: 'application/pdf' });
const PDF = Buffer.from('%PDF-1.4\n% receta ficticia de prueba\n%%EOF\n');

const stamp = Date.now();
const created = [];
async function newUser(tag) {
  const email = `${tag}-${stamp}@test.local`;
  const c = await svc('/auth/v1/admin/users', { email, password: 'Felix2026', email_confirm: true });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status}`);
  created.push(c.json.id);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password: 'Felix2026' } });
  return { token: s.json.access_token, id: s.json.user.id };
}

const legal = {
  terms: (await rpc('current_legal_version', { p_kind: 'terms' })).json,
  privacy: (await rpc('current_legal_version', { p_kind: 'privacy' })).json,
};
const register = (u, role, name, communeId = null) => rpc('complete_registration', {
  p_role: role, p_display_name: name, p_phone: null,
  p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: communeId }, u.token);

const tomorrow = new Date(Date.now() + 24 * 3600 * 1000)
  .toLocaleDateString('en-CA', { timeZone: 'America/Santiago' });
let pet;

try {
  const owner = await newUser('dueno-f7');
  const ownerB = await newUser('dueno-b-f7');
  const vet = await newUser('vet-f7');
  const vet2 = await newUser('vet2-f7');
  const admin = await newUser('admin-f7');
  await svc('/rest/v1/user_roles', { user_id: admin.id, role: 'admin' });

  const nunoa = (await call('/rest/v1/communes?select=id&name=eq.%C3%91u%C3%B1oa', { token: owner.token })).json[0].id;
  check((await register(owner, 'owner', 'Ana Ficticia', nunoa)).status === 200, 'el dueño completa su registro');
  check((await register(ownerB, 'owner', 'Beto Ficticio', nunoa)).status === 200, 'otro dueño completa su registro');
  check((await register(vet, 'vet', 'Dra. Ficha')).status === 200, 'el vet completa su registro');
  check((await register(vet2, 'vet', 'Dr. Ajeno')).status === 200, 'otro vet completa su registro');

  const perro = (await call('/rest/v1/species?select=id&slug=eq.perro', { token: owner.token })).json[0].id;
  const general = (await call('/rest/v1/specialties?select=id&slug=eq.general', { token: owner.token })).json[0].id;
  for (const u of [vet, vet2]) {
    await svc(`/rest/v1/vet_profiles?user_id=eq.${u.id}`, { status: 'approved' }, 'PATCH');
    await svc('/rest/v1/vet_species', { vet_id: u.id, species_id: perro });
    await svc('/rest/v1/vet_specialties', { vet_id: u.id, specialty_id: general });
    await svc('/rest/v1/vet_availability', [1, 2, 3, 4, 5, 6, 7].map((d) => ({ vet_id: u.id, weekday: d, start_min: 0, end_min: 1440 })));
  }
  const baseCommune = (await rpc('communes_at_point', { p_lat: -33.3849, p_lng: -70.5974 }, vet.token)).json[0].commune_id;
  await call('/rest/v1/vet_bases', { method: 'POST', token: vet.token,
    body: { vet_id: vet.id, commune_id: baseCommune, lat: -33.3849, lng: -70.5974 } });

  pet = (await call('/rest/v1/pets?select=id', { method: 'POST', token: owner.token, prefer: 'return=representation',
    body: { owner_id: owner.id, name: 'Firulais', species_id: perro } })).json[0].id;
  const addr = (await call('/rest/v1/addresses?select=id', { method: 'POST', token: owner.token,
    prefer: 'return=representation', body: { owner_id: owner.id, label: 'Casa', street_text: 'Av. Ficticia 123',
      commune_id: nunoa, lat: -33.4569, lng: -70.5974 } })).json[0].id;

  // --- Visita: antes de aceptar no hay acceso -----------------------------------------
  const av = await rpc('available_vets', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_date: tomorrow }, owner.token);
  const slot = av.json.find((v) => v.vet_id === vet.id).slots[0];
  const q = (await rpc('quote_visit', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general,
    p_mode: 'scheduled', p_vet_id: vet.id }, owner.token)).json;
  const visit = (await rpc('book_visit', { p_quote_id: q.quote_id, p_vet_id: vet.id, p_pet_id: pet,
    p_address_id: addr, p_scheduled_at: slot }, owner.token)).json.id;
  const record = (token, visitId = null) => rpc('get_pet_record', { p_pet_id: pet, p_visit_id: visitId }, token);
  const tr = (to, token = vet.token) => rpc('transition_visit', { p_visit_id: visit, p_to_status: to }, token);
  const myVisit = async (token) => ((await rpc('my_visits', {}, token)).json ?? []).find((v) => v.id === visit);
  check((await record(vet.token)).status === 403, 'con la visita pendiente el vet no ve la ficha');

  // El dueño escribe una nota (solo notas) y la corrige.
  const add = (token, body) => rpc('add_clinical_entry', body, token);
  const note = await add(owner.token, { p_pet_id: pet, p_kind: 'note', p_title: 'Come poco' });
  check(note.status === 200, 'el dueño agrega una nota');
  const ownerDx = await add(owner.token, { p_pet_id: pet, p_kind: 'diagnosis', p_title: 'Autodiagnóstico' });
  check(ownerDx.status === 403, `el dueño no registra diagnósticos (HTTP ${ownerDx.status})`);
  const fix = await add(owner.token, { p_pet_id: pet, p_kind: 'note', p_title: 'Come poco desde el lunes',
    p_supersedes_id: note.json });
  check(fix.status === 200, 'el dueño corrige su nota con una entrada nueva');

  check((await tr('accepted')).status === 200, 'el vet confirma la visita');
  const acc = await myVisit(vet.token);
  check(acc.record_access === true && acc.record_writable === false && acc.record_until === null,
    'aceptada: el vet ve la ficha (sin vencimiento mientras está activa) pero aún no escribe');
  const r1 = await record(vet.token, visit);
  check(r1.status === 200 && r1.json.entries.length === 2 && r1.json.grants === null,
    'el vet lee la ficha por get_pet_record (sin las autorizaciones del dueño)');
  check(r1.json.entries.find((e) => e.id === note.json)?.superseded_by === fix.json,
    'el historial muestra la nota anterior reemplazada por la corrección');
  const early = await add(vet.token, { p_pet_id: pet, p_kind: 'diagnosis', p_title: 'Prematuro', p_visit_id: visit });
  check(early.status === 403, 'antes de llegar el vet no escribe');

  // --- En atención: escribe, vacuna y adjunto -----------------------------------------
  shiftVisit(sql, visit, "date_trunc('minute', now()) + interval '20 minutes'");
  for (const s of ['en_route', 'arrived', 'in_progress']) check((await tr(s)).status === 200, `el vet pasa a ${s}`);
  const dx = await add(vet.token, { p_pet_id: pet, p_kind: 'diagnosis', p_title: 'Otitis externa',
    p_body: 'Contenido ficticio', p_visit_id: visit, p_specialty_id: general });
  check(dx.status === 200, 'el vet registra un diagnóstico en su visita');
  const vac = await add(vet.token, { p_pet_id: pet, p_kind: 'vaccine', p_title: 'Antirrábica', p_visit_id: visit,
    p_vaccine: { vaccine_name: 'Antirrábica', lot: 'L-0001', applied_on: '2026-01-15', next_due: '2099-01-01' } });
  check(vac.status === 200, 'el vet registra una vacuna con su próxima dosis');
  const vetFixOwner = await add(vet.token, { p_pet_id: pet, p_kind: 'note', p_title: 'x', p_visit_id: visit,
    p_supersedes_id: fix.json });
  check(vetFixOwner.status === 400, 'el vet no corrige la nota del dueño');

  const path = `pets/${pet}/${dx.json}/receta.pdf`;
  check((await upload(path, vet2.token)).status >= 400, 'otro vet no sube adjuntos a la entrada');
  check((await upload(`pets/${pet}/${dx.json}/x.exe`, vet.token)).status >= 400, 'solo PDF, JPG o PNG');
  const up = await upload(path, vet.token);
  check(up.status === 200, `el vet sube el adjunto al bucket privado (HTTP ${up.status})`);
  const att = await call('/rest/v1/entry_attachments?select=id', { method: 'POST', token: vet.token,
    body: { entry_id: dx.json, storage_path: path, file_name: 'receta.pdf', mime: 'application/pdf', size_bytes: PDF.length } });
  check(att.status === 201, `el vet registra el adjunto (HTTP ${att.status})`);
  const attId = (await record(owner.token)).json.entries.find((e) => e.id === dx.json).attachments[0]?.id;
  check(!!attId, 'el adjunto aparece en la ficha');

  // --- Accesos indebidos por REST ----------------------------------------------------
  const direct = await call('/rest/v1/clinical_entries?select=id', { token: vet.token });
  check(direct.status === 200 && direct.json.length === 0, 'el vet no tiene SELECT directo sobre las entradas');
  check((await call('/rest/v1/clinical_entries?select=id', { token: owner.token })).json.length === 4,
    'el dueño lee directo sus 4 entradas');
  for (const [who, token] of [['el vet autor', vet.token], ['el dueño', owner.token]]) {
    const p = await call(`/rest/v1/clinical_entries?id=eq.${dx.json}`, { method: 'PATCH', token, body: { title: 'x' } });
    const d = await call(`/rest/v1/clinical_entries?id=eq.${dx.json}`, { method: 'DELETE', token });
    check(p.status === 403 && d.status === 403, `${who} no actualiza ni borra entradas (HTTP ${p.status}/${d.status})`);
  }
  const logIns = await call('/rest/v1/record_access_log', { method: 'POST', token: owner.token,
    body: { pet_id: pet, actor_role: 'owner', action: 'view', via: 'owner' } });
  check(logIns.status === 403, 'nadie escribe el log por la API');
  check((await record(vet2.token)).status === 403, 'otro vet no lee la ficha');
  check((await record(ownerB.token)).status === 403, 'otro dueño no lee la ficha');
  check((await record(admin.token)).status === 403, 'el admin no lee la ficha');
  check((await add(vet2.token, { p_pet_id: pet, p_kind: 'diagnosis', p_title: 'x', p_visit_id: visit })).status === 403,
    'otro vet no escribe en la visita ajena');
  const anon = await call('/rest/v1/clinical_entries?select=id');
  check(anon.status === 401 || (anon.status === 200 && anon.json.length === 0), `anónimo no lee entradas (HTTP ${anon.status})`);
  check((await call('/rest/v1/rpc/get_pet_record', { method: 'POST', body: { p_pet_id: pet } })).status >= 400,
    'anónimo no llama a get_pet_record');
  for (const [who, token] of [['admin', admin.token]]) {
    const e = await call('/rest/v1/clinical_entries?select=id', { token });
    const l = await call('/rest/v1/record_access_log?select=id', { token });
    check(e.json.length === 0 && l.json.length === 0, `${who}: sin contenido clínico ni log`);
  }
  const stats = await rpc('admin_record_stats', {}, admin.token);
  check(stats.status === 200 && stats.json.entries >= 4, 'el admin ve solo conteos');
  check((await rpc('admin_record_stats', {}, owner.token)).status === 403, 'los conteos son solo del admin');

  // --- Storage y URL firmada ---------------------------------------------------------
  for (const [who, token] of [['el vet', vet.token], ['el dueño', owner.token]]) {
    const get = await call(`/storage/v1/object/authenticated/${BUCKET}/${path}`, { token });
    const sg = await call(`/storage/v1/object/sign/${BUCKET}/${path}`, { method: 'POST', token, body: { expiresIn: 86400 } });
    check(get.status >= 400 && sg.status >= 400,
      `${who} no descarga ni firma directo en Storage (HTTP ${get.status}/${sg.status})`);
  }
  const del = await call(`/storage/v1/object/${BUCKET}/${path}`, { method: 'DELETE', token: vet.token });
  const still = await sign(attId, owner.token);
  check(still.status === 200, `el vet no borra el archivo (HTTP ${del.status})`);
  const sv = await sign(attId, vet.token);
  check(sv.status === 200 && sv.json.expires_in === 60, 'el vet con acceso obtiene una URL firmada de 60 s');
  const tokenPayload = JSON.parse(Buffer.from(new URL(API + sv.json.signed_path).searchParams.get('token').split('.')[1], 'base64url'));
  check(tokenPayload.exp - tokenPayload.iat === 60, 'la firma vence a los 60 s');
  const dl = await call(sv.json.signed_path, {});
  check(dl.status === 200 && dl.buf.equals(PDF), 'la URL firmada descarga el archivo');
  for (const [who, token] of [['otro vet', vet2.token], ['otro dueño', ownerB.token], ['el admin', admin.token]]) {
    check((await sign(attId, token)).status === 404, `${who} no obtiene URL firmada`);
  }
  check((await sign(attId, PUB)).status >= 400, 'sin sesión no hay URL firmada');

  // --- Cierre y ventana de 30 días -----------------------------------------------------
  backdateStart(sql, visit);
  check((await tr('completed')).status === 200, 'el vet completa la visita');
  const done = await myVisit(vet.token);
  const days = (new Date(done.record_until) - Date.now()) / 86400000;
  check(done.record_writable === true && days > 29.9 && days <= 30, 'completada: lee y escribe 30 días más');
  check(done.closed_by_system === false, 'O-6: cerrada por el vet (no por el sistema)');
  sql(`set felix.record_internal = 'on'; update public.record_access_grants set expires_at = now() - interval '1 minute'
       where visit_id = '${visit}'`);
  check((await record(vet.token)).status === 403, 'a los 31 días el vet ya no lee');
  check((await sign(attId, vet.token)).status === 404, 'ni descarga adjuntos');
  check((await add(vet.token, { p_pet_id: pet, p_kind: 'note', p_title: 'Tarde', p_visit_id: visit })).status === 403,
    'ni escribe');

  // --- Autorización del dueño ------------------------------------------------------------
  const exp = new Date(Date.now() + 7 * 86400000).toISOString();
  const g = await call('/rest/v1/record_access_grants?select=id', { method: 'POST', token: owner.token,
    prefer: 'return=representation', body: { pet_id: pet, vet_id: vet2.id, source: 'owner', expires_at: exp } });
  check(g.status === 201, 'el dueño autoriza a otro vet por 7 días');
  const gB = await call('/rest/v1/record_access_grants', { method: 'POST', token: ownerB.token,
    body: { pet_id: pet, vet_id: vet2.id, source: 'owner', expires_at: exp } });
  check(gB.status === 403, 'otro dueño no autoriza sobre una mascota ajena');
  const r2 = await record(vet2.token);
  check(r2.status === 200 && r2.json.access.via === 'owner_grant' && r2.json.can_write === false,
    'el vet autorizado lee (vía owner_grant) pero no escribe');
  check((await sign(attId, vet2.token)).status === 200, 'y descarga adjuntos');
  const ext = await call(`/rest/v1/record_access_grants?id=eq.${g.json[0].id}`, { method: 'PATCH', token: owner.token,
    body: { expires_at: '2099-01-01T00:00:00Z' } });
  check(ext.status === 403, 'el vencimiento no se cambia (solo se revoca)');
  const rv = await call(`/rest/v1/record_access_grants?id=eq.${g.json[0].id}`, { method: 'PATCH', token: owner.token,
    body: { revoked_at: new Date().toISOString() } });
  check(rv.status === 204, 'el dueño revoca la autorización');
  check((await record(vet2.token)).status === 403, 'al revocar, la siguiente lectura falla de inmediato');
  check((await sign(attId, vet2.token)).status === 404, 'y ya no hay URL firmada');

  // --- Quién vio mi ficha ---------------------------------------------------------------
  const log = await rpc('pet_access_log', { p_pet_id: pet }, owner.token);
  const acts = (log.json ?? []).map((l) => `${l.actor_name}:${l.action}:${l.via}`);
  check(acts.includes('Dra. Ficha:view:visit') && acts.includes('Dra. Ficha:download:visit')
    && acts.includes('Dr. Ajeno:view:owner_grant') && acts.includes('Dra. Ficha:create:visit')
    && acts.includes('Tú:grant:owner') && acts.includes('Tú:revoke:owner') && acts.includes('Tú:correct:owner'),
    'el dueño ve quién leyó, descargó, escribió, autorizó y revocó');
  check(!(log.json ?? []).some((l) => l.actor_name === 'Tú' && l.action === 'view'), 'sus propias lecturas no se registran');
  check(((await rpc('pet_access_log', { p_pet_id: pet }, ownerB.token)).json ?? []).length === 0,
    'otro dueño no ve el log ajeno');
} finally {
  if (pet) {
    try {
      const paths = sql(`select name from storage.objects where bucket_id = '${BUCKET}' and name like 'pets/${pet}/%'`)
        .split(/\r?\n/).filter(Boolean);
      if (paths.length) await call(`/storage/v1/object/${BUCKET}`, { method: 'DELETE', key: SRV, token: SRV, body: { prefixes: paths } });
      sql(`set felix.record_maintenance = 'on';
           delete from public.record_access_log where pet_id = '${pet}';
           delete from public.clinical_entries where pet_id = '${pet}';`);
    } catch (e) { console.log(`limpieza de la ficha: ${e.message}`); }
  }
  for (const id of created) {
    await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
  }
}

console.log(fails === 0 ? '\nE2E fase 7: TODO OK' : `\nE2E fase 7: ${fails} fallas`);
process.exit(fails ? 1 : 0);
