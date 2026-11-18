// QA exploratorio de la fase 7 (ficha clínica) contra un Supabase local:
// matriz de accesos por REST, Storage y Edge Function; integridad (solo
// inserción, cadena de supersedes_id, log de lecturas); fugas indirectas;
// ventanas de acceso (día 29/31, cancelación, suspensión, ventana vencida sin
// cron) y O-6 (closed_by_system).
// Uso: node tool/e2e/qa_ficha_exploratorio_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
// Salida: 0 sin defectos, 2 solo con defectos conocidos (DEFECTO), 1 si algo más falla.
// Pausa el job pg_cron `expire-visits` mientras corre y lo reactiva al final.
// Crea usuarios @test.local y los borra al final (la ficha se limpia con
// felix.record_maintenance, como el futuro job de borrado).
import { backdateStart, shiftVisit, sqlRunner, timeTravel } from './sql.mjs';

const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;
const sql = sqlRunner(st);
const BUCKET = 'clinical-attachments';

let fails = 0;
let defects = 0;
const check = (cond, msg, defect) => {
  if (cond) console.log(`OK    ${msg}`);
  else if (defect) { console.log(`DEFECTO ${defect}: ${msg}`); defects++; }
  else { console.log(`FALLA ${msg}`); fails++; }
};

async function call(path, { method = 'GET', token, key = PUB, body, prefer, raw, type, headers: extra } = {}) {
  const headers = { apikey: key, ...extra };
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
const rpc = (name, body, token, opts = {}) => call(`/rest/v1/rpc/${name}`, { method: 'POST', token, body, ...opts });
const svc = (path, body, method = 'POST') => call(path, { method, key: SRV, token: SRV, body });
const sign = (attachmentId, token) => call('/functions/v1/clinical-attachment-url', {
  method: 'POST', token, body: { attachment_id: attachmentId } });
const PDF = Buffer.from('%PDF-1.4\n% documento ficticio de QA\n%%EOF\n');
const upload = (path, token, extra) => call(`/storage/v1/object/${BUCKET}/${path}`, {
  method: 'POST', token, raw: PDF, type: 'application/pdf', headers: extra });
const sqlErr = (q) => { try { sql(q); return 'ok'; } catch (e) { return String(e.stderr ?? e.message).trim(); } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rnd = () => crypto.randomUUID();

const stamp = Date.now();
const created = [];
async function newUser(tag) {
  const email = `qaf7-${tag}-${stamp}@test.local`;
  const c = await svc('/auth/v1/admin/users', { email, password: 'Felix2026', email_confirm: true });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status}`);
  created.push(c.json.id);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password: 'Felix2026' } });
  return { token: s.json.access_token, id: s.json.user.id, tag };
}
const legal = {
  terms: (await rpc('current_legal_version', { p_kind: 'terms' })).json,
  privacy: (await rpc('current_legal_version', { p_kind: 'privacy' })).json,
};
const register = (u, role, name, communeId = null) => rpc('complete_registration', {
  p_role: role, p_display_name: name, p_phone: null,
  p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: communeId }, u.token);
const day = (n) => new Date(Date.now() + n * 86400000).toLocaleDateString('en-CA', { timeZone: 'America/Santiago' });

const pets = [];
sql("select cron.alter_job((select jobid from cron.job where jobname = 'expire-visits'), active := false)");
try {
  const O = await newUser('dueno');
  const OB = await newUser('dueno-b');
  const AD = await newUser('admin');
  const FU = await newUser('fundacion');
  await svc('/rest/v1/user_roles', { user_id: AD.id, role: 'admin' });
  await svc('/rest/v1/user_roles', { user_id: FU.id, role: 'foundation' });
  const nunoa = (await call('/rest/v1/communes?select=id&name=eq.%C3%91u%C3%B1oa', { token: O.token })).json[0].id;
  await register(O, 'owner', 'Dueña QA', nunoa);
  await register(OB, 'owner', 'Dueño B QA', nunoa);
  const perro = (await call('/rest/v1/species?select=id&slug=eq.perro', { token: O.token })).json[0].id;
  const general = (await call('/rest/v1/specialties?select=id&slug=eq.general', { token: O.token })).json[0].id;
  const baseCommune = (await rpc('communes_at_point', { p_lat: -33.3849, p_lng: -70.5974 }, O.token)).json[0].commune_id;
  async function makeVet(tag, name) {
    const u = await newUser(tag);
    await register(u, 'vet', name);
    await svc(`/rest/v1/vet_profiles?user_id=eq.${u.id}`, { status: 'approved' }, 'PATCH');
    await svc('/rest/v1/vet_species', { vet_id: u.id, species_id: perro });
    await svc('/rest/v1/vet_specialties', { vet_id: u.id, specialty_id: general });
    await svc('/rest/v1/vet_availability', [1, 2, 3, 4, 5, 6, 7].map((d) => ({ vet_id: u.id, weekday: d, start_min: 0, end_min: 1440 })));
    await call('/rest/v1/vet_bases', { method: 'POST', token: u.token,
      body: { vet_id: u.id, commune_id: baseCommune, lat: -33.3849, lng: -70.5974 } });
    return u;
  }
  const V = await makeVet('vet', 'Dra. QA');      // vet de la visita principal
  const V2 = await makeVet('vet2', 'Dr. Otro');   // nunca tuvo acceso
  const VC = await makeVet('vetc', 'Dr. Cancelado');
  const VS = await makeVet('vets', 'Dr. Suspendido');
  const VX = await makeVet('vetx', 'Dra. Vencida');
  const VG = await makeVet('vetg', 'Dra. Autorizada');

  const newPet = async (u, name) => {
    const id = (await call('/rest/v1/pets?select=id', { method: 'POST', token: u.token, prefer: 'return=representation',
      body: { owner_id: u.id, name, species_id: perro } })).json[0].id;
    pets.push(id); return id;
  };
  const newAddr = async (u) => (await call('/rest/v1/addresses?select=id', { method: 'POST', token: u.token,
    prefer: 'return=representation', body: { owner_id: u.id, label: 'Casa', street_text: 'Pasaje Ficticio 742',
      commune_id: nunoa, lat: -33.4569, lng: -70.5974 } })).json[0].id;
  const P = await newPet(O, 'Toby');
  const P2 = await newPet(O, 'Michi');
  const PB = await newPet(OB, 'Rex');
  const addr = await newAddr(O);
  const addrB = await newAddr(OB);
  async function book(owner, pet, address, vet, offset) {
    const av = await rpc('available_vets', { p_pet_id: pet, p_address_id: address, p_specialty_id: general, p_date: day(offset) }, owner.token);
    const slot = av.json.find((v) => v.vet_id === vet.id).slots[0];
    const q = (await rpc('quote_visit', { p_pet_id: pet, p_address_id: address, p_specialty_id: general,
      p_mode: 'scheduled', p_vet_id: vet.id }, owner.token)).json;
    return (await rpc('book_visit', { p_quote_id: q.quote_id, p_vet_id: vet.id, p_pet_id: pet,
      p_address_id: address, p_scheduled_at: slot }, owner.token)).json.id;
  }
  const tr = (visit, to, u) => rpc('transition_visit', { p_visit_id: visit, p_to_status: to }, u.token);
  const record = (u, pet = P, visit = null) => rpc('get_pet_record', { p_pet_id: pet, p_visit_id: visit }, u?.token);
  const add = (u, body) => rpc('add_clinical_entry', body, u?.token);
  const myVisit = async (u, id) => {
    const j = (await rpc('my_visits', {}, u.token)).json;
    return Array.isArray(j) ? j.find((v) => v.id === id) : undefined;
  };
  const logCount = (actor, action) => Number(sql(`select count(*) from public.record_access_log
    where actor_id = '${actor}' and action = '${action}'`));

  // --- Preparación: visita principal en curso con entrada, vacuna y adjunto ----------
  const v1 = await book(O, P, addr, V, 2);
  check((await tr(v1, 'accepted', V)).status === 200, 'V acepta la visita principal');
  shiftVisit(sql, v1, "date_trunc('minute', now()) + interval '20 minutes'");
  for (const s of ['en_route', 'arrived', 'in_progress']) await tr(v1, s, V);
  const SECRET = 'Otitis QA secreta';
  const dx = (await add(V, { p_pet_id: P, p_kind: 'diagnosis', p_title: SECRET, p_body: 'cuerpo-clinico-ficticio',
    p_visit_id: v1, p_specialty_id: general })).json;
  const vac = await add(V, { p_pet_id: P, p_kind: 'vaccine', p_title: 'Séxtuple', p_visit_id: v1,
    p_vaccine: { vaccine_name: 'Séxtuple', applied_on: '2026-10-01' } });
  check(typeof dx === 'string' && vac.status === 200, 'V registra diagnóstico y vacuna en su visita');
  const objPath = `pets/${P}/${dx}/${Date.now()}.pdf`;
  check((await upload(objPath, V.token)).status === 200, 'V sube el adjunto con nombre sin PII (timestamp)');
  check((await call('/rest/v1/entry_attachments', { method: 'POST', token: V.token, body: { entry_id: dx,
    storage_path: objPath, file_name: 'examen.pdf', mime: 'application/pdf', size_bytes: PDF.length } })).status === 201,
  'V registra el adjunto');
  const attId = sql(`select id from public.entry_attachments where entry_id = '${dx}'`);
  const ownerNote = (await add(O, { p_pet_id: P, p_kind: 'note', p_title: 'Nota de la dueña' })).json;
  const noteB = (await add(OB, { p_pet_id: PB, p_kind: 'note', p_title: 'Nota de otro dueño' })).json;

  // Acceso por visita de VC (se cancelará) y VS (se suspenderá).
  const vc = await book(O, P, addr, VC, 3);
  await tr(vc, 'accepted', VC);
  const vs = await book(O, P, addr, VS, 4);
  await tr(vs, 'accepted', VS);
  check((await record(VC)).status === 200 && (await record(VS)).status === 200,
    'VC y VS leen la ficha tras aceptar (antes de cancelar/suspender)');
  check((await tr(vc, 'cancelled_owner', O)).status === 200, 'la dueña cancela la visita de VC');
  await svc(`/rest/v1/vet_profiles?user_id=eq.${VS.id}`, { status: 'suspended' }, 'PATCH');
  // VX: visita aceptada cuya ventana venció (no se presentó) sin que corra el cron.
  const vx = await book(O, P2, addr, VX, 2);
  await tr(vx, 'accepted', VX);
  check((await record(VX, P2)).status === 200, 'VX lee la ficha de P2 con la visita aceptada');
  timeTravel(sql, `update public.visits set scheduled_at = now() - interval '61 minutes',
    slot = tstzrange(now() - interval '61 minutes', now() + interval '29 minutes') where id = '${vx}'`);
  // VG: autorización del dueño que se revoca; VE: la misma VG con otra vencida (via SQL).
  const exp7 = new Date(Date.now() + 7 * 86400000).toISOString();
  const gVG = await call('/rest/v1/record_access_grants?select=id', { method: 'POST', token: O.token,
    prefer: 'return=representation', body: { pet_id: P, vet_id: VG.id, source: 'owner', expires_at: exp7 } });
  check(gVG.status === 201, 'la dueña autoriza a VG por 7 días');
  const rVG = await record(VG);
  check(rVG.status === 200 && rVG.json.access?.via === 'owner_grant' && rVG.json.can_write === false,
    'VG lee vía owner_grant y can_write = false');
  check((await add(VG, { p_pet_id: P, p_kind: 'note', p_title: 'x' })).status === 403
    && (await add(VG, { p_pet_id: P, p_kind: 'diagnosis', p_title: 'x', p_visit_id: v1 })).status === 403,
  'VG (solo autorización del dueño) no escribe, ni usando la visita de otro vet');
  check((await sign(attId, VG.token)).status === 200, 'VG descarga adjuntos mientras la autorización está vigente');
  await call(`/rest/v1/record_access_grants?id=eq.${gVG.json[0].id}`, { method: 'PATCH', token: O.token,
    body: { revoked_at: new Date().toISOString() } });
  const VE = await makeVet('vete', 'Dr. Expirado');
  const gVE = await call('/rest/v1/record_access_grants?select=id', { method: 'POST', token: O.token,
    prefer: 'return=representation', body: { pet_id: P, vet_id: VE.id, source: 'owner', expires_at: exp7 } });
  check((await record(VE)).status === 200, 'VE lee con su autorización vigente');
  sql(`set felix.record_internal = 'on'; update public.record_access_grants
       set starts_at = now() - interval '8 days', expires_at = now() - interval '1 minute' where id = '${gVE.json[0].id}'`);

  // --- 1. Matriz de accesos indebidos ---------------------------------------------------
  const profiles = [
    ['otro dueño', OB], ['otro vet', V2], ['vet de visita cancelada', VC], ['vet suspendido', VS],
    ['vet con ventana vencida sin cron', VX], ['vet con autorización revocada', VG],
    ['vet con autorización vencida', VE], ['fundación', FU], ['admin', AD], ['anónimo', null],
  ];
  for (const [who, u] of profiles) {
    const tok = u?.token;
    const pet = u === VX ? P2 : P;
    const reads = [];
    for (const t of ['clinical_entries', 'clinical_vaccines', 'entry_attachments', 'record_access_log', 'record_access_grants']) {
      const r = await call(`/rest/v1/${t}?select=*&pet_id=eq.${pet}`, { token: tok });
      reads.push(r.status === 401 || (r.status === 200 && Array.isArray(r.json) && r.json.length === 0) ? null : `${t}:${r.status}`);
    }
    check(reads.every((x) => x === null), `${who}: no lee entradas, vacunas, adjuntos, log ni autorizaciones (${reads.filter(Boolean).join(',') || 'vacío'})`);
    const gr = await record(u, pet);
    check(gr.status === 401 || gr.status === 403, `${who}: get_pet_record ajeno → ${gr.status}`);
    const w1 = await add(u, { p_pet_id: pet, p_kind: 'diagnosis', p_title: 'intruso', p_visit_id: u === VX ? vx : v1 });
    const w2 = await add(u, { p_pet_id: pet, p_kind: 'note', p_title: 'intruso' });
    const w3 = await add(u, { p_pet_id: P, p_kind: 'diagnosis', p_title: 'corrige', p_visit_id: v1, p_supersedes_id: dx });
    check([w1, w2, w3].every((r) => r.status === 401 || r.status === 403),
      `${who}: no escribe ni corrige entradas ajenas (${w1.status}/${w2.status}/${w3.status})`);
    const pa = await call(`/rest/v1/clinical_entries?id=eq.${dx}`, { method: 'PATCH', token: tok, body: { title: 'x' } });
    const de = await call(`/rest/v1/clinical_entries?id=eq.${dx}`, { method: 'DELETE', token: tok });
    const li = await call('/rest/v1/record_access_log', { method: 'POST', token: tok,
      body: { pet_id: pet, actor_role: 'vet', action: 'view', via: 'visit' } });
    check([pa, de, li].every((r) => r.status === 401 || r.status === 403),
      `${who}: no actualiza, borra ni inserta en el log (${pa.status}/${de.status}/${li.status})`);
    const up = await upload(`pets/${P}/${dx}/intruso.pdf`, tok);
    const dl = await call(`/storage/v1/object/authenticated/${BUCKET}/${objPath}`, { token: tok });
    const sg = await call(`/storage/v1/object/sign/${BUCKET}/${objPath}`, { method: 'POST', token: tok, body: { expiresIn: 60 } });
    check(up.status >= 400 && dl.status >= 400 && sg.status >= 400,
      `${who}: Storage directo sin subir, descargar ni firmar (${up.status}/${dl.status}/${sg.status})`);
    const fs = await sign(attId, tok ?? PUB);
    check(fs.status === 404 || fs.status === 401, `${who}: la Edge Function no firma el adjunto ajeno (${fs.status})`);
  }
  check((await record(VX, P2)).status === 403 && !(await myVisit(VX, vx))?.exact,
    'B4: ventana de la visita aceptada vencida (cron pausado): sin ficha ni dirección');
  const vsVisit = await myVisit(VS, vs);
  check(!vsVisit || vsVisit.record_writable === false, 'el vet suspendido no aparece con escritura en my_visits');

  // El autor y la dueña tampoco modifican nada; Storage directo bloqueado también para ellos.
  for (const [who, u] of [['V (autor, con acceso)', V], ['la dueña', O]]) {
    const pa = await call(`/rest/v1/clinical_entries?id=eq.${dx}`, { method: 'PATCH', token: u.token, body: { title: 'x' } });
    const de = await call(`/rest/v1/clinical_entries?id=eq.${dx}`, { method: 'DELETE', token: u.token });
    const pv = await call(`/rest/v1/clinical_vaccines?entry_id=eq.${vac.json}`, { method: 'PATCH', token: u.token, body: { lot: 'x' } });
    const pt = await call(`/rest/v1/entry_attachments?id=eq.${attId}`, { method: 'PATCH', token: u.token, body: { file_name: 'x.pdf' } });
    const pl = await call(`/rest/v1/record_access_log?pet_id=eq.${P}`, { method: 'DELETE', token: u.token });
    check([pa, de, pv, pt, pl].every((r) => r.status === 403),
      `${who}: 403 al actualizar/borrar entrada, vacuna, adjunto o log (${[pa, de, pv, pt, pl].map((r) => r.status).join('/')})`);
    const ups = await upload(objPath, u.token, { 'x-upsert': 'true' });
    const put = await call(`/storage/v1/object/${BUCKET}/${objPath}`, { method: 'PUT', token: u.token, raw: PDF, type: 'application/pdf' });
    const del = await call(`/storage/v1/object/${BUCKET}/${objPath}`, { method: 'DELETE', token: u.token });
    const lst = await call(`/storage/v1/object/list/${BUCKET}`, { method: 'POST', token: u.token, body: { prefix: `pets/${P}/` } });
    const dl = await call(`/storage/v1/object/authenticated/${BUCKET}/${objPath}`, { token: u.token });
    const objs = Number(sql(`select count(*) from storage.objects where bucket_id = '${BUCKET}' and name = '${objPath}'`));
    check(ups.status >= 400 && put.status >= 400 && dl.status >= 400 && objs === 1
      && (lst.status >= 400 || (Array.isArray(lst.json) && lst.json.length === 0)),
    `${who}: Storage sin sobrescribir, actualizar, borrar, listar ni descargar directo (${ups.status}/${put.status}/${del.status}/${lst.status}/${dl.status}, objeto intacto)`);
  }
  check((await call(`/rest/v1/record_access_grants?pet_id=eq.${P}`, { token: V.token })).json.length === 0,
    'B6: el vet con acceso no lee record_access_grants');
  check(((await rpc('pet_access_log', { p_pet_id: P }, V.token)).json ?? []).length === 0
    && ((await rpc('pet_access_log', { p_pet_id: P }, AD.token)).json ?? []).length === 0,
  'pet_access_log: vacío para el vet y el admin');
  const vGrant = await call(`/rest/v1/record_access_grants?visit_id=eq.${v1}`, { method: 'PATCH', token: O.token,
    prefer: 'return=representation', body: { revoked_at: new Date().toISOString() } });
  check((vGrant.status === 200 && vGrant.json.length === 0) || vGrant.status === 403,
    `la dueña no revoca la autorización de visita (${vGrant.status})`);
  check((await call('/rest/v1/record_access_grants', { method: 'POST', token: O.token,
    body: { pet_id: P, vet_id: V2.id, source: 'visit', expires_at: exp7 } })).status === 403,
  'la dueña no crea autorizaciones source = visit');
  check((await call('/rest/v1/record_access_grants', { method: 'POST', token: V2.token,
    body: { pet_id: P, vet_id: V2.id, source: 'owner', expires_at: exp7 } })).status === 403,
  'un vet no se autoriza a sí mismo');

  // Validaciones de la autorización del dueño.
  const grant = (body, u = O) => call('/rest/v1/record_access_grants', { method: 'POST', token: u.token, body });
  const in30m = new Date(Date.now() + 30 * 60000).toISOString();
  const in366 = new Date(Date.now() + 366 * 86400000).toISOString();
  const gs = [await grant({ pet_id: P, vet_id: V2.id, source: 'owner', expires_at: in30m }),
    await grant({ pet_id: P, vet_id: V2.id, source: 'owner', expires_at: in366 }),
    await grant({ pet_id: P, vet_id: VS.id, source: 'owner', expires_at: exp7 }),
    await grant({ pet_id: P, vet_id: OB.id, source: 'owner', expires_at: exp7 })];
  check(gs.every((r) => r.status === 400), `autorización: < 1 h, > 365 d, vet suspendido o no-vet → 400 (${gs.map((r) => r.status).join('/')})`);
  const gFor = await grant({ pet_id: PB, vet_id: V2.id, source: 'owner', expires_at: exp7 });
  const gNone = await grant({ pet_id: rnd(), vet_id: V2.id, source: 'owner', expires_at: exp7 });
  check(gFor.status === 403 && gNone.status === 403 && gFor.json.message === gNone.json.message,
    'autorizar sobre mascota ajena o inexistente: el mismo 403');
  const rr = await call(`/rest/v1/record_access_grants?id=eq.${gVG.json[0].id}`, { method: 'PATCH', token: O.token,
    body: { revoked_at: new Date().toISOString() } });
  const un = await call(`/rest/v1/record_access_grants?id=eq.${gVG.json[0].id}`, { method: 'PATCH', token: O.token,
    body: { revoked_at: null } });
  const chg = await call(`/rest/v1/record_access_grants?id=eq.${gVG.json[0].id}`, { method: 'PATCH', token: O.token,
    body: { vet_id: V2.id } });
  check(rr.status === 400 && un.status === 400 && chg.status === 403,
    `revocada: no se re-revoca, no se des-revoca ni se cambia de vet (${rr.status}/${un.status}/${chg.status})`);

  // --- 2. Integridad --------------------------------------------------------------------
  // Cadena de supersedes_id.
  const c1 = await add(V, { p_pet_id: P, p_kind: 'diagnosis', p_title: 'Otitis corregida', p_visit_id: v1, p_supersedes_id: dx });
  check(c1.status === 200, 'V corrige su diagnóstico');
  const fork = await add(V, { p_pet_id: P, p_kind: 'diagnosis', p_title: 'bifurcación', p_visit_id: v1, p_supersedes_id: dx });
  check(fork.status === 400, 'no se bifurca: corregir de nuevo la versión reemplazada → 400');
  const race = await Promise.all([1, 2, 3].map((i) => add(V, { p_pet_id: P, p_kind: 'diagnosis',
    p_title: `carrera ${i}`, p_visit_id: v1, p_supersedes_id: c1.json })));
  check(race.filter((r) => r.status === 200).length === 1,
    `correcciones concurrentes de la misma versión: solo una gana (${race.map((r) => r.status).join('/')})`);
  const kind = await add(V, { p_pet_id: P, p_kind: 'note', p_title: 'otro tipo', p_visit_id: v1, p_supersedes_id: ownerNote });
  const kind2 = await add(V, { p_pet_id: P, p_kind: 'consultation', p_title: 'otro tipo', p_visit_id: v1,
    p_supersedes_id: race.find((r) => r.status === 200).json });
  const ghost = await add(V, { p_pet_id: P, p_kind: 'note', p_title: 'fantasma', p_visit_id: v1, p_supersedes_id: rnd() });
  const xpet = await add(V, { p_pet_id: P, p_kind: 'note', p_title: 'otra mascota', p_visit_id: v1, p_supersedes_id: noteB });
  check([kind, kind2, ghost, xpet].every((r) => r.status === 400),
    `corrección de otro autor, otro tipo, inexistente u otra mascota → 400 (${[kind, kind2, ghost, xpet].map((r) => r.status).join('/')})`);
  check(ghost.json.message === xpet.json.message, 'el mensaje no distingue una entrada inexistente de una ajena');
  const selfId = rnd();
  const cyc = await call('/rest/v1/clinical_entries', { method: 'POST', token: V.token, body: { id: selfId, pet_id: P,
    visit_id: v1, author_id: V.id, author_role: 'vet', kind: 'note', title: 'ciclo', supersedes_id: selfId } });
  check(cyc.status === 400, `ciclo (supersedes_id = id propio) → 400 (${cyc.status})`);
  const ownerCorr = await add(O, { p_pet_id: P, p_kind: 'note', p_title: 'dueña corrige al vet', p_supersedes_id: dx });
  check(ownerCorr.status === 400 || ownerCorr.status === 403, `la dueña no corrige entradas del vet (${ownerCorr.status})`);
  const forge = [
    await call('/rest/v1/clinical_entries', { method: 'POST', token: V.token, body: { pet_id: P, visit_id: v1,
      author_id: V2.id, author_role: 'vet', kind: 'note', title: 'suplanta' } }),
    await call('/rest/v1/clinical_entries', { method: 'POST', token: O.token, body: { pet_id: P,
      author_id: O.id, author_role: 'vet', kind: 'diagnosis', title: 'dueña como vet' } }),
    await call('/rest/v1/clinical_entries', { method: 'POST', token: O.token, body: { pet_id: P, visit_id: v1,
      author_id: O.id, author_role: 'owner', kind: 'note', title: 'con visita' } }),
    await call('/rest/v1/clinical_entries', { method: 'POST', token: V.token, body: { pet_id: P, visit_id: v1,
      author_id: V.id, author_role: 'vet', kind: 'note', title: 'fecha', created_at: '2020-01-01T00:00:00Z' } }),
    await add(V, { p_pet_id: P2, p_kind: 'note', p_title: 'otra mascota con mi visita', p_visit_id: v1 }),
  ];
  check(forge.every((r) => r.status === 403), `inserciones forjadas (otro autor, rol falso, visita, created_at, otra mascota) → 403 (${forge.map((r) => r.status).join('/')})`);

  // Solo inserción incluso para service_role y postgres.
  const sp = await svc(`/rest/v1/clinical_entries?id=eq.${dx}`, { title: 'svc' }, 'PATCH');
  const sd = await svc(`/rest/v1/clinical_entries?id=eq.${dx}`, undefined, 'DELETE');
  const sl = await svc(`/rest/v1/record_access_log?pet_id=eq.${P}`, undefined, 'DELETE');
  check([sp, sd, sl].every((r) => r.status >= 400), `service_role por REST no actualiza ni borra (${sp.status}/${sd.status}/${sl.status})`);
  const snull = await svc(`/rest/v1/record_access_log?pet_id=eq.${P}&actor_id=eq.${V.id}`, { actor_id: null }, 'PATCH');
  const snull2 = await svc(`/rest/v1/clinical_entries?id=eq.${c1.json}`, { supersedes_id: null }, 'PATCH');
  check(snull.status >= 400 && snull2.status >= 400,
    `service_role por REST no anula actor_id del log ni supersedes_id (${snull.status}/${snull2.status})`, 'QA-F7-01');
  const pgUpd = sqlErr(`update public.clinical_entries set title = 'pg' where id = '${dx}'`);
  const pgDel = sqlErr(`delete from public.clinical_entries where id = '${dx}'`);
  const pgLog = sqlErr(`delete from public.record_access_log where pet_id = '${P}'`);
  check([pgUpd, pgDel, pgLog].every((e) => e.includes('no se modifica')), 'postgres directo no actualiza ni borra entradas ni log');
  const asAuth = sqlErr(`begin; set local role authenticated; set local felix.record_maintenance = 'on';
    delete from public.record_access_log where pet_id = '${P}'; rollback;`);
  const asSvc = sqlErr(`begin; set local role service_role; set local felix.record_maintenance = 'on';
    delete from public.clinical_entries where id = '${dx}'; rollback;`);
  check(asAuth !== 'ok' && asSvc !== 'ok',
    'felix.record_maintenance no sirve a authenticated ni a service_role (aunque fijen la marca)');
  const trunc = sqlErr(`begin; truncate public.record_access_log; rollback;`);
  check(trunc !== 'ok', `TRUNCATE del log como postgres bloqueado (${trunc === 'ok' ? 'se ejecuta' : 'bloqueado'})`, 'QA-F7-02');
  check(sql(`select has_table_privilege('authenticated', 'public.clinical_entries', 'TRUNCATE')
    or has_table_privilege('authenticated', 'public.record_access_log', 'TRUNCATE')
    or has_table_privilege('anon', 'public.record_access_log', 'TRUNCATE')`) === 'f',
  'anon/authenticated sin TRUNCATE en la ficha y el log');
  const setCfg = await rpc('set_config', { setting_name: 'felix.record_maintenance', new_value: 'on', is_local: true }, V.token);
  check(setCfg.status === 404, `set_config no está expuesto por la API (${setCfg.status})`);
  check(Number(sql(`select count(*) from public.clinical_entries where id = '${dx}' and title = '${SECRET}'`)) === 1,
    'la entrada original sigue intacta');

  // El log no se puede omitir.
  const v0 = logCount(V.id, 'view');
  for (let i = 0; i < 3; i++) await record(V, P, v1);
  check(logCount(V.id, 'view') === v0 + 3, 'cada lectura del vet registra una fila (3 → +3)');
  const get = await call(`/rest/v1/rpc/get_pet_record?p_pet_id=${P}`, { token: V.token });
  const head = await call(`/rest/v1/rpc/get_pet_record?p_pet_id=${P}`, { method: 'HEAD', token: V.token });
  const rb = await rpc('get_pet_record', { p_pet_id: P }, V.token, { prefer: 'tx=rollback' });
  const v3 = logCount(V.id, 'view');
  const ran = [get, rb, head].filter((r) => r.status === 200).length;
  check(v3 === v0 + 3 + ran,
    `GET/HEAD/Prefer tx=rollback no leen sin registrar (GET ${get.status}, HEAD ${head.status}, rollback ${rb.status}, log +${v3 - v0 - 3} de ${ran} respuestas 200)`);
  const d0 = logCount(V.id, 'download');
  const s1 = await sign(attId, V.token);
  const s2 = await sign(attId, V.token);
  check(s1.status === 200 && s2.status === 200 && logCount(V.id, 'download') === d0 + 2, 'cada firma del vet registra una descarga');
  const dOwner = logCount(O.id, 'download');
  check((await sign(attId, O.token)).status === 200 && logCount(O.id, 'download') === dOwner, 'las descargas de la dueña no se registran');
  const signedAt = Date.now();
  const anonDl = await call(s1.json.signed_path, {});
  check(anonDl.status === 200 && anonDl.buf.equals(PDF), 'la URL firmada funciona sin sesión dentro de los 60 s (portador)');

  // --- 3. Fugas indirectas ----------------------------------------------------------------
  const foreign = await record(V2, P);
  const none = await record(V2, rnd());
  check(foreign.status === none.status && foreign.json.message === none.json.message,
    'get_pet_record: mismo error para mascota ajena e inexistente');
  const t = { f: [], n: [] };
  for (let i = 0; i < 15; i++) {
    for (const [k, pid] of [['f', P], ['n', rnd()]]) {
      const a = performance.now(); await record(V2, pid); t[k].push(performance.now() - a);
    }
  }
  const med = (xs) => xs.sort((a, b) => a - b)[xs.length >> 1];
  const dt = Math.abs(med(t.f) - med(t.n));
  check(dt < 15, `tiempos: mediana ajena ${med(t.f).toFixed(1)} ms vs inexistente ${med(t.n).toFixed(1)} ms (Δ ${dt.toFixed(1)} ms)`);
  const wf = await add(V2, { p_pet_id: P, p_kind: 'diagnosis', p_title: 'x', p_visit_id: v1 });
  const wn = await add(V2, { p_pet_id: rnd(), p_kind: 'diagnosis', p_title: 'x', p_visit_id: rnd() });
  const vf = await call('/rest/v1/clinical_vaccines', { method: 'POST', token: V2.token, body: { entry_id: vac.json, vaccine_name: 'x', applied_on: '2026-01-01' } });
  const vn = await call('/rest/v1/clinical_vaccines', { method: 'POST', token: V2.token, body: { entry_id: rnd(), vaccine_name: 'x', applied_on: '2026-01-01' } });
  const af = await call('/rest/v1/entry_attachments', { method: 'POST', token: V2.token, body: { entry_id: dx, storage_path: objPath, file_name: 'a.pdf', mime: 'application/pdf', size_bytes: 1 } });
  const an = await call('/rest/v1/entry_attachments', { method: 'POST', token: V2.token, body: { entry_id: rnd(), storage_path: `pets/${rnd()}/x/a.pdf`, file_name: 'a.pdf', mime: 'application/pdf', size_bytes: 1 } });
  const sf = await sign(attId, V2.token);
  const sn = await sign(rnd(), V2.token);
  const uf = await upload(`pets/${P}/${dx}/z.pdf`, V2.token);
  const un2 = await upload(`pets/${rnd()}/${rnd()}/z.pdf`, V2.token);
  const same = (a, b) => a.status === b.status && JSON.stringify(a.json?.message ?? a.json?.error ?? '') === JSON.stringify(b.json?.message ?? b.json?.error ?? '');
  check(same(wf, wn) && same(vf, vn) && same(af, an) && same(sf, sn) && uf.status === un2.status,
    `entrada, vacuna, adjunto, firma y subida: el mismo error para lo ajeno y lo inexistente (${[wf, vf, af, sf, uf].map((r) => r.status).join('/')})`);
  const stats = await rpc('admin_record_stats', {}, AD.token);
  check(stats.status === 200 && Object.values(stats.json).every((x) => typeof x === 'number')
    && !JSON.stringify(stats.json).includes(SECRET), `admin_record_stats solo conteos (${Object.keys(stats.json ?? {}).join(',')})`);
  for (const [who, u] of [['vet', V], ['dueña', O], ['admin', AD]]) {
    const mv = await rpc('my_visits', {}, u.token);
    const txt = JSON.stringify(mv.json);
    check(!txt.includes(SECRET) && !txt.includes('cuerpo-clinico') && !txt.includes('Séxtuple'),
      `my_visits (${who}) sin contenido clínico`);
  }
  const names = sql(`select name from storage.objects where bucket_id = '${BUCKET}'`).split(/\r?\n/).filter(Boolean);
  check(names.every((n) => /^pets\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/\d+\.(pdf|jpe?g|png)$/.test(n)),
    `nombres en Storage: pets/<uuid>/<uuid>/<timestamp>.<ext> (${names.length} objetos)`);
  const pii = await upload(`pets/${P}/${dx}/Juan Pérez.pdf`, V.token);
  check(pii.status >= 400, `el servidor rechaza nombres con espacios o tildes (${pii.status})`);
  const pub = sql(`select coalesce(string_agg(tablename, ','), '') from pg_publication_tables where pubname = 'supabase_realtime'
    and tablename in ('clinical_entries','clinical_vaccines','entry_attachments','record_access_log','record_access_grants')`);
  check(pub === '', `las tablas de la ficha no están en la publicación de Realtime (${pub || 'ninguna'})`);
  const gql = await call('/graphql/v1', { method: 'POST', token: V.token, body: { query: '{ __typename }' } });
  check(gql.status >= 400, `GraphQL no expuesto (${gql.status})`);

  // --- 4. O-6 y ventanas ---------------------------------------------------------------------
  check((await call(`/rest/v1/visits?id=eq.${v1}`, { method: 'PATCH', token: V.token, body: { closed_by_system: true } })).status === 403
    && (await call(`/rest/v1/visits?id=eq.${v1}`, { method: 'PATCH', token: O.token, body: { closed_by_system: true } })).status === 403,
  'closed_by_system no se fija por REST (vet ni dueña)');
  const svcFlag = await svc(`/rest/v1/visits?id=eq.${v1}`, { closed_by_system: true }, 'PATCH');
  check(svcFlag.status >= 400, `closed_by_system no se fija fuera de una transición, ni con service_role (${svcFlag.status})`);
  // En curso con la ventana vencida y el cron pausado: sin acceso.
  timeTravel(sql, `update public.visits set scheduled_at = now() - interval '9 hours',
    slot = tstzrange(now() - interval '9 hours', now() - interval '450 minutes'), started_at = now() - interval '7 hours' where id = '${v1}'`);
  check((await record(V, P, v1)).status === 403 && (await sign(attId, V.token)).status === 404
    && (await add(V, { p_pet_id: P, p_kind: 'note', p_title: 'tarde', p_visit_id: v1 })).status === 403,
  'en curso con la ventana vencida (cron pausado): sin lectura, descarga ni escritura');
  sql('select private.expire_visits()');
  const sysV = await myVisit(V, v1);
  const sysO = await myVisit(O, v1);
  const sysVx = await myVisit(O, vx);
  check(sysV?.status === 'completed' && sysV.closed_by_system === true && sysO?.closed_by_system === true,
    'O-6: el cron cierra la en curso como completed con closed_by_system (vet y dueña lo ven)');
  check(sysVx?.status !== 'accepted' && sysVx?.closed_by_system === true && (await record(VX, P2)).status === 403,
    `O-6: la aceptada vencida queda ${sysVx?.status} cerrada por el sistema y sin acceso`);
  const days = (new Date(sysV.record_until) - Date.now()) / 86400000;
  check(sysV.record_writable === true && days > 29.9 && days <= 30.01
    && (await add(V, { p_pet_id: P, p_kind: 'note', p_title: 'documenta', p_visit_id: v1 })).status === 200,
  'O-6 (decisión): cerrada por el sistema abre 30 días de lectura y escritura');
  check(Number(sql(`select count(*) from public.payments where visit_id = '${v1}'`)) === 0, 'O-6: sin cobro automático');
  const g1 = sql(`select id from public.record_access_grants where visit_id = '${v1}'`);
  sql(`set felix.record_internal = 'on'; update public.record_access_grants set expires_at = now() + interval '1 day' where id = '${g1}'`);
  check((await record(V, P, v1)).status === 200 && (await sign(attId, V.token)).status === 200, 'día 29: el vet lee y descarga');
  sql(`set felix.record_internal = 'on'; update public.record_access_grants set expires_at = now() - interval '1 day' where id = '${g1}'`);
  check((await record(V, P, v1)).status === 403 && (await sign(attId, V.token)).status === 404
    && (await add(V, { p_pet_id: P, p_kind: 'note', p_title: 'día 31', p_visit_id: v1 })).status === 403
    && (await add(V, { p_pet_id: P, p_kind: 'diagnosis', p_title: 'corr', p_visit_id: v1, p_supersedes_id: c1.json })).status === 403,
  'día 31: sin lectura, descarga, escritura ni corrección');
  const dV = await myVisit(V, v1);
  check(dV.record_access === false && dV.record_writable === false, 'día 31: my_visits marca sin acceso');

  // URL firmada reutilizada después de 60 s.
  const wait = 62000 - (Date.now() - signedAt);
  if (wait > 0) await sleep(wait);
  const late = await call(s1.json.signed_path, {});
  check(late.status >= 400, `la URL firmada vence a los 60 s (HTTP ${late.status} a los ${((Date.now() - signedAt) / 1000).toFixed(0)} s)`);
} finally {
  sql("select cron.alter_job((select jobid from cron.job where jobname = 'expire-visits'), active := true)");
  try {
    for (const pet of pets) {
      const paths = sql(`select name from storage.objects where bucket_id = '${BUCKET}' and name like 'pets/${pet}/%'`)
        .split(/\r?\n/).filter(Boolean);
      if (paths.length) await call(`/storage/v1/object/${BUCKET}`, { method: 'DELETE', key: SRV, token: SRV, body: { prefixes: paths } });
      sql(`set felix.record_maintenance = 'on';
           delete from public.record_access_log where pet_id = '${pet}';
           delete from public.clinical_entries where pet_id = '${pet}';`);
    }
  } catch (e) { console.log(`limpieza de la ficha: ${e.message}`); }
  for (const id of created) await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
}

console.log(fails === 0 && defects === 0 ? '\nQA fase 7: TODO OK'
  : `\nQA fase 7: ${fails} fallas, ${defects} defectos conocidos`);
process.exit(fails ? 1 : defects ? 2 : 0);
