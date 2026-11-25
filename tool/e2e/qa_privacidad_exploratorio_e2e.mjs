// QA exploratorio de la fase 11 (derechos de privacidad, Ley 21.719) contra un
// stack local aislado: Auth + REST + RPC + GraphQL + Storage + Realtime (WebSocket
// real) + Edge Functions, y SQL directo (docker exec) solo para vencer plazos,
// correr los jobs de pg_cron y verificar a mano que no queden restos.
//
// Uso: node tool/e2e/qa_privacidad_exploratorio_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
//
// Crea usuarios *@test.local y lo borra todo al final. Detiene y vuelve a
// levantar el contenedor de Storage del stack para simular la caída (paso B5):
// no lo corras contra el stack compartido. Sale con 0 si todo pasa, 2 si solo
// fallan las verificaciones de defectos abiertos (QA-F11-NN) y 1 si falla algo más.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { backdateStart, shiftVisit, sqlRunner } from './sql.mjs';

const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;
if (/:5432[0-9]$/.test(new URL(API).host)) {
  console.error('Este script detiene Storage: no lo corras contra el stack compartido (5432x).');
  process.exit(1);
}
const sql = sqlRunner(st);
const WIN_DOCKER = 'C:\\Program Files\\Docker\\Docker\\resources\\bin\\docker.exe';
const DOCKER = process.env.DOCKER_BIN || (existsSync(WIN_DOCKER) ? WIN_DOCKER : 'docker');
const BUCKET = 'clinical-attachments';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let fails = 0;
const defects = new Set();
const check = (cond, msg) => { console.log(`${cond ? 'OK  ' : 'FALLA'} ${msg}`); if (!cond) fails++; return cond; };
// Verificación del comportamiento correcto ligada a un defecto abierto.
const expectFixed = (cond, id, msg) => {
  console.log(`${cond ? 'OK  ' : 'DEFECTO'} [${id}] ${msg}`);
  if (!cond) defects.add(id);
  return cond;
};
const info = (msg) => console.log(`INFO ${msg}`);

async function call(path, { method = 'GET', token, key = PUB, body, prefer, raw, type, headers: extra } = {}) {
  const headers = { apikey: key, ...(extra ?? {}) };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (prefer) headers.Prefer = prefer;
  if (raw !== undefined) headers['Content-Type'] = type ?? 'application/octet-stream';
  else if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(API + path, {
    method, headers, body: raw !== undefined ? raw : body !== undefined ? JSON.stringify(body) : undefined });
  const buf = Buffer.from(await r.arrayBuffer());
  let json; try { json = JSON.parse(buf.toString()); } catch { json = buf.toString(); }
  return { status: r.status, json, text: buf.toString() };
}
const rpc = (name, body, token) => call(`/rest/v1/rpc/${name}`, { method: 'POST', token, body });
const svc = (path, body, method = 'POST') => call(path, { method, key: SRV, token: SRV, body });
const isBlocked = (r) => r.status === 403 && (r.json?.hint === 'account_blocked' || /account_blocked/.test(r.text));
const PDF = Buffer.from('%PDF-1.4\n% documento ficticio de QA\n%%EOF\n');
const fn = (name, token, body = {}) => call(`/functions/v1/${name}`, { method: 'POST', token, body });

const stamp = Date.now();
const created = [];
const login = (email) => call('/auth/v1/token?grant_type=password', {
  method: 'POST', body: { email, password: 'Felix2026' } });
async function newUser(tag) {
  const email = `qa11-${tag}-${stamp}@test.local`;
  const c = await svc('/auth/v1/admin/users', { email, password: 'Felix2026', email_confirm: true });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status}`);
  created.push(c.json.id);
  const s = await login(email);
  return { token: s.json.access_token, refresh: s.json.refresh_token, id: s.json.user.id, email, tag };
}
const relogin = async (u) => { const s = await login(u.email); u.token = s.json.access_token; return s; };

// --- Cliente Realtime mínimo (Phoenix vsn 2.0.0, como supabase-js) ----------------------
class Rt {
  constructor(token) { this.token = token; this.msgs = []; this.ref = 0; this.waiters = new Map(); }
  async open() {
    this.ws = new WebSocket(`${API.replace(/^http/, 'ws')}/realtime/v1/websocket?apikey=${PUB}&vsn=2.0.0`);
    await new Promise((res, rej) => { this.ws.onopen = res; this.ws.onerror = rej; });
    this.ws.onmessage = (e) => {
      if (typeof e.data !== 'string') return;
      const raw = JSON.parse(e.data);
      const m = Array.isArray(raw) ? { ref: raw[1], topic: raw[2], event: raw[3], payload: raw[4] } : raw;
      this.msgs.push(m);
      if (m.event === 'phx_reply' && this.waiters.has(m.ref)) { this.waiters.get(m.ref)(m); this.waiters.delete(m.ref); }
    };
    this.hb = setInterval(() => this.push('phoenix', 'heartbeat', {}), 20000);
    return this;
  }
  push(topic, event, payload, joinRef) {
    const ref = String(++this.ref);
    if (event === 'phx_join') joinRef = ref;
    this.ws.send(JSON.stringify([joinRef ?? null, ref, topic, event, payload]));
    return ref;
  }
  wait(ref, ms) { return new Promise((res) => { this.waiters.set(ref, res); setTimeout(() => res(null), ms); }); }
  async join(sub) {
    this.topic = `realtime:${sub}`;
    const payload = { config: { broadcast: { ack: true, self: false }, presence: { key: '', enabled: false },
      postgres_changes: [], private: true }, access_token: this.token };
    this.joinRef = this.push(this.topic, 'phx_join', payload);
    const reply = await this.wait(this.joinRef, 5000);
    await sleep(400);
    const err = this.msgs.find((m) => m.topic === this.topic
      && ((m.event === 'system' && m.payload?.status === 'error') || m.event === 'phx_error' || m.event === 'phx_close'));
    return { ok: reply?.payload?.status === 'ok' && !err, reason: reply?.payload?.response?.reason ?? err?.payload?.message ?? '' };
  }
  send(event, payload) { this.push(this.topic, 'broadcast', { type: 'broadcast', event, payload }, this.joinRef); }
  got(mark) {
    return this.msgs.filter((m) => m.topic === this.topic && m.event === 'broadcast' && m.payload?.payload?.mark === mark).length;
  }
  close() { clearInterval(this.hb); try { this.ws.close(); } catch { /* cerrado */ } }
}
const sockets = [];
const rt = async (u) => { const s = await new Rt(u.token).open(); sockets.push(s); return s; };

// --- Datos base ---------------------------------------------------------------------------
const legal = {
  terms: (await rpc('current_legal_version', { p_kind: 'terms' })).json,
  privacy: (await rpc('current_legal_version', { p_kind: 'privacy' })).json,
};
const register = (u, role, name, communeId = null, phone = null) => rpc('complete_registration', {
  p_role: role, p_display_name: name, p_phone: phone,
  p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: communeId }, u.token);
const tomorrow = () => new Date(Date.now() + 24 * 3600 * 1000).toLocaleDateString('en-CA', { timeZone: 'America/Santiago' });
const HUELLAS = sql("select id from public.foundations where name = 'Fundación Demo Huellas'");
let perro; let general; let nunoa;

async function approvedVet(tag, name, lat = -33.3849, beforeApprove = null) {
  const v = await newUser(tag);
  await register(v, 'vet', name);
  if (beforeApprove) await beforeApprove(v);
  await svc(`/rest/v1/vet_profiles?user_id=eq.${v.id}`, { status: 'approved' }, 'PATCH');
  await svc('/rest/v1/vet_species', { vet_id: v.id, species_id: perro });
  await svc('/rest/v1/vet_specialties', { vet_id: v.id, specialty_id: general });
  await svc('/rest/v1/vet_availability', [1, 2, 3, 4, 5, 6, 7].map((d) => ({ vet_id: v.id, weekday: d, start_min: 0, end_min: 1440 })));
  const bc = (await rpc('communes_at_point', { p_lat: lat, p_lng: -70.5974 }, v.token)).json[0].commune_id;
  await call('/rest/v1/vet_bases', { method: 'POST', token: v.token, body: { vet_id: v.id, commune_id: bc, lat, lng: -70.5974 } });
  return v;
}
async function ownerWithPet(tag, name, phone, petName, street, details = null, microchip = null) {
  const o = await newUser(tag);
  await register(o, 'owner', name, nunoa, phone);
  o.pet = (await call('/rest/v1/pets?select=id', { method: 'POST', token: o.token, prefer: 'return=representation',
    body: { owner_id: o.id, name: petName, species_id: perro, microchip } })).json[0].id;
  o.addr = (await call('/rest/v1/addresses?select=id', { method: 'POST', token: o.token, prefer: 'return=representation',
    body: { owner_id: o.id, label: 'Casa', street_text: street, details, commune_id: nunoa, lat: -33.4569, lng: -70.5974 } })).json[0].id;
  return o;
}
// Visita agendada con el vet, llevada hasta `upTo` (accepted | en_route | in_progress | completed).
async function visitWith(o, v, upTo, { donation = 0, onArrived } = {}) {
  const av = await rpc('available_vets', { p_pet_id: o.pet, p_address_id: o.addr, p_specialty_id: general, p_date: tomorrow() }, o.token);
  const slots = av.json.find((x) => x.vet_id === v.id).slots;
  const q = (await rpc('quote_visit', { p_pet_id: o.pet, p_address_id: o.addr, p_specialty_id: general,
    p_mode: 'scheduled', p_vet_id: v.id, p_extra_donation: donation }, o.token)).json;
  const b = await rpc('book_visit', { p_quote_id: q.quote_id, p_vet_id: v.id, p_pet_id: o.pet,
    p_address_id: o.addr, p_scheduled_at: slots[slots.length - 1] }, o.token);
  const id = b.json.id;
  myVisits.push(id);
  const tr = (to) => rpc('transition_visit', { p_visit_id: id, p_to_status: to }, v.token);
  await tr('accepted');
  if (upTo === 'accepted') return id;
  shiftVisit(sql, id, "date_trunc('minute', now()) + interval '20 minutes'");
  await tr('en_route');
  if (upTo === 'en_route') return id;
  await tr('arrived');
  if (onArrived) await onArrived(id);
  await tr('in_progress');
  if (upTo === 'in_progress') return id;
  backdateStart(sql, id);
  await tr('completed');
  return id;
}
const myVisits = [];
const runJob = () => sql('select private.run_account_deletions()');
const purge = () => call('/functions/v1/purge-privacy-storage', { method: 'POST', key: SRV, token: SRV, body: {} });
const targetsCount = (req) => Number(sql(`select count(*) from public.deletion_targets where request_id = '${req}'`));
const expire = (req) => sql(`update public.deletion_requests set execute_after = now() - interval '1 minute' where id = '${req}'`);
const objExists = async (bucket, path) => (await call(`/storage/v1/object/${bucket}/${path}`, { key: SRV, token: SRV })).status === 200;
// Escaneo manual: TODAS las columnas de texto/uuid/json de TODOS los esquemas (no solo los 4 del
// escaneo del producto), salvo el catálogo de Postgres y la bitácora del propio borrado.
function deepScan(needles) {
  const arr = needles.map((n) => `'${n.replace(/'/g, "''")}'`).join(',');
  return sql(`create function pg_temp.qa_scan(p text[]) returns text language plpgsql as $f$
    declare c record; n text; h bigint; res text := ''; begin
    for c in select ns.nspname s, cl.relname t, a.attname col from pg_class cl
      join pg_namespace ns on ns.oid = cl.relnamespace
      join pg_attribute a on a.attrelid = cl.oid and a.attnum > 0 and not a.attisdropped
      join pg_type ty on ty.oid = a.atttypid
      where cl.relkind in ('r','p') and ns.nspname not in ('pg_catalog','information_schema','pg_toast')
        and ns.nspname not like 'pg_temp%'
        and ty.typname in ('uuid','text','varchar','json','jsonb','_uuid','_text','bytea','name')
        and (ns.nspname, cl.relname) not in (('public','deletion_requests'),('public','deletion_targets'),
             ('private','storage_erasure_queue'))
    loop
      foreach n in array p loop
        execute format('select count(*) from %I.%I where %I::text ilike $1', c.s, c.t, c.col) into h using '%' || n || '%';
        if h > 0 then res := res || c.s || '.' || c.t || '.' || c.col || '~' || n || '=' || h || ' '; end if;
      end loop;
    end loop;
    return res; end $f$;
    select pg_temp.qa_scan(array[${arr}]::text[]);`).split(/\r?\n/).filter((l) => l !== 'CREATE FUNCTION').join('').trim();
}

const toDrop = [];
try {
  const tmp = await newUser('tmp');
  perro = (await call('/rest/v1/species?select=id&slug=eq.perro', { token: tmp.token })).json[0].id;
  general = (await call('/rest/v1/specialties?select=id&slug=eq.general', { token: tmp.token })).json[0].id;
  nunoa = (await call('/rest/v1/communes?select=id&name=eq.%C3%91u%C3%B1oa', { token: tmp.token })).json[0].id;

  const AD = await newUser('admin');
  await svc('/rest/v1/user_roles', { user_id: AD.id, role: 'admin' });
  await relogin(AD);

  // =====================================================================================
  // A. Bloqueo: REST/RPC/GraphQL/Storage/Realtime/Edge Functions/Auth
  // =====================================================================================
  console.log('\n--- A. Bloqueo ---');
  const VA = await approvedVet('vet-a', 'Dra. Bloqueo');
  const OA = await ownerWithPet('dueno-a', 'Olivia Bloqueada', '+56 9 1111 2222', 'Rayo', 'Calle Bloqueo 10');
  const vA = await visitWith(OA, VA, 'en_route');
  const noteA = (await rpc('add_clinical_entry', { p_pet_id: OA.pet, p_kind: 'note', p_title: 'Nota previa' }, OA.token)).json;
  const upBefore = await call(`/storage/v1/object/${BUCKET}/pets/${OA.pet}/${noteA}/antes.pdf`, { method: 'POST', token: OA.token, raw: PDF, type: 'application/pdf' });
  info(`antes del bloqueo el dueño sube un adjunto a su nota: HTTP ${upBefore.status}`);
  // Canal Realtime abierto ANTES del bloqueo (dueño y vet en visit:{id}).
  const sOpenOwner = await rt(OA); const sOpenVet = await rt(VA);
  check((await sOpenOwner.join(`visit:${vA}`)).ok && (await sOpenVet.join(`visit:${vA}`)).ok,
    'antes del bloqueo dueño y vet se unen al canal privado de la visita en camino');
  // Bloqueo aislado: fila insertada por SQL para que la visita siga en camino (así solo la
  // política restrictiva puede rechazar, no el estado de la visita).
  const reqA = sql(`insert into public.deletion_requests (user_id, role) values ('${OA.id}', 'owner') returning id`).split('\n')[0];
  const oldJwt = OA.token;
  const probes = [
    ['GET pets', call('/rest/v1/pets?select=id,microchip', { token: oldJwt })],
    ['GET owner_profiles', call('/rest/v1/owner_profiles?select=*', { token: oldJwt })],
    ['HEAD visits', call('/rest/v1/visits?select=id', { method: 'HEAD', token: oldJwt })],
    ['POST pets', call('/rest/v1/pets', { method: 'POST', token: oldJwt, body: { owner_id: OA.id, name: 'Nuevo', species_id: perro } })],
    ['PATCH owner_profiles', call(`/rest/v1/owner_profiles?user_id=eq.${OA.id}`, { method: 'PATCH', token: oldJwt, body: { display_name: 'Cambio' } })],
    ['DELETE addresses', call(`/rest/v1/addresses?id=eq.${OA.addr}`, { method: 'DELETE', token: oldJwt })],
    ['RPC my_visits', rpc('my_visits', {}, oldJwt)],
    ['RPC my_privacy_status', rpc('my_privacy_status', {}, oldJwt)],
    ['RPC set_consent', rpc('set_consent', { p_purpose: 'marketing', p_granted: true }, oldJwt)],
    ['RPC get_pet_record', rpc('get_pet_record', { p_pet_id: OA.pet }, oldJwt)],
    ['RPC request_account_deletion', rpc('request_account_deletion', {}, oldJwt)],
    ['RPC check_request', rpc('check_request', {}, oldJwt)],
    ['GET rpc/current_legal_version', call('/rest/v1/rpc/current_legal_version?p_kind=privacy', { token: oldJwt })],
    ['GraphQL', call('/graphql/v1', { method: 'POST', token: oldJwt, body: { query: '{ __typename }' } })],
    ['ruta con ..', call('/rest/v1/rpc/my_deletion_request/../../pets?select=id', { token: oldJwt })],
    ['Accept-Profile private', call('/rest/v1/rpc/is_blocked', { method: 'POST', token: oldJwt, body: { p_uid: OA.id }, headers: { 'Content-Profile': 'private' } })],
  ];
  const leaked = [];
  for (const [name, p] of probes) {
    const r = await p;
    // GraphQL (graphql_public) no está expuesto en este proyecto: 406 = sin la API.
    const ok = isBlocked(r) || (name === 'HEAD visits' && r.status === 403) || (name === 'GraphQL' && r.status === 406)
      || (name === 'ruta con ..' && r.status >= 400) || (name === 'Accept-Profile private' && r.status >= 400);
    if (!ok) leaked.push(`${name}→${r.status}`);
    info(`bloqueada, JWT previo: ${name} → HTTP ${r.status} ${typeof r.json === 'object' ? (r.json?.hint ?? r.json?.code ?? '') : ''}`);
  }
  check(leaked.length === 0, `toda REST/RPC/GraphQL de la cuenta bloqueada da 403 account_blocked (fugas: ${leaked.join(', ') || 'ninguna'})`);
  const allowed = [await rpc('my_deletion_request', {}, oldJwt), await rpc('export_my_data', {}, oldJwt),
    await call('/rest/v1/rpc/my_deletion_request', { token: oldJwt })];
  check(allowed.every((r) => r.status === 200), `solo pasan my_deletion_request (POST y GET) y export_my_data (${allowed.map((r) => r.status)})`);
  const upAfter = await call(`/storage/v1/object/${BUCKET}/pets/${OA.pet}/${noteA}/despues.pdf`, { method: 'POST', token: oldJwt, raw: PDF, type: 'application/pdf' });
  const listAfter = await call(`/storage/v1/object/list/${BUCKET}`, { method: 'POST', token: oldJwt, body: { prefix: `pets/${OA.pet}/` } });
  const signAfter = await call(`/storage/v1/object/sign/${BUCKET}/pets/${OA.pet}/${noteA}/antes.pdf`, { method: 'POST', token: oldJwt, body: { expiresIn: 60 } });
  check(upAfter.status >= 400 && !(Array.isArray(listAfter.json) && listAfter.json.length) && signAfter.status >= 400,
    `Storage: subir ${upAfter.status}, listar ${listAfter.status} (${Array.isArray(listAfter.json) ? listAfter.json.length : '-'} objetos), firmar ${signAfter.status}`);
  const attSign = await fn('clinical-attachment-url', oldJwt, { attachment_id: '00000000-0000-4000-8000-000000000001' });
  check(attSign.status >= 400, `Edge Function clinical-attachment-url con el JWT bloqueado → ${attSign.status}`);
  // Realtime: canal nuevo rechazado; el ya abierto sigue (riesgo residual documentado).
  const sNew = await rt(OA);
  const jNew = await sNew.join(`visit:${vA}`);
  check(!jNew.ok, `Realtime: la cuenta bloqueada no se une de nuevo al canal privado (${jNew.reason})`);
  sOpenVet.send('location', { lat: -33.45, lng: -70.6, mark: 'tras-bloqueo' });
  sOpenOwner.send('location', { lat: -33.0, lng: -70.0, mark: 'desde-bloqueado' });
  await sleep(1500);
  info(`RIESGO RESIDUAL Realtime: con el canal abierto antes del bloqueo, el dueño bloqueado recibe ${sOpenOwner.got('tras-bloqueo')} mensaje(s) y el vet recibe ${sOpenVet.got('desde-bloqueado')} enviado(s) por el bloqueado`);
  const restBc = await fetch(`${API}/realtime/v1/api/broadcast`, { method: 'POST',
    headers: { apikey: PUB, Authorization: `Bearer ${oldJwt}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ messages: [{ topic: `visit:${vA}`, event: 'location', private: true, payload: { mark: 'rest-bloq' } }] }) });
  await sleep(1000);
  check(sOpenVet.got('rest-bloq') === 0, `Realtime REST broadcast de la cuenta bloqueada no llega (HTTP ${restBc.status})`);
  sql(`update public.deletion_requests set status = 'cancelled', cancelled_at = now() where id = '${reqA}'`);
  check((await call('/rest/v1/pets?select=id', { token: oldJwt })).status === 200, 'al cancelar, la misma sesión vuelve a funcionar');
  await rpc('transition_visit', { p_visit_id: vA, p_to_status: 'cancelled_owner', p_reason: null }, OA.token);

  // Flujo real (request_account_deletion): sesiones, Auth API, reingreso y cancelación.
  const OB = await ownerWithPet('dueno-b', 'Bruno Gracia', null, 'Toby', 'Calle Gracia 20');
  const reqB = await rpc('request_account_deletion', {}, OB.token);
  check(reqB.status === 200 && reqB.json.status === 'blocked' && reqB.json.cancellable === true
    && Math.abs(new Date(reqB.json.execute_after) - Date.now() - 15 * 86400000) < 120000,
  'acuse inmediato: blocked, cancelable y gracia de 15 días');
  const again = await rpc('request_account_deletion', {}, OB.token);
  info(`pedir el borrado otra vez con la cuenta ya bloqueada → HTTP ${again.status} (bloqueado por el pre-request)`);
  const authPut = await call('/auth/v1/user', { method: 'PUT', token: OB.token, body: { data: { qa: 'x' } } });
  info(`Auth API PUT /user con el JWT previo (sesión revocada) → HTTP ${authPut.status}`);
  const rel = await relogin(OB);
  check(rel.status === 200, 'durante la gracia puede volver a iniciar sesión');
  const authPut2 = await call('/auth/v1/user', { method: 'PUT', token: OB.token, body: { data: { qa_bloqueado: true } } });
  expectFixed(authPut2.status >= 400, 'QA-F11-04',
    `Auth API: la cuenta bloqueada no modifica sus datos de Auth con una sesión nueva (PUT /auth/v1/user → HTTP ${authPut2.status})`);
  check(isBlocked(await call('/rest/v1/pets?select=id', { token: OB.token })), 'con la sesión nueva los datos siguen bloqueados');
  const canB = await rpc('cancel_account_deletion', {}, OB.token);
  check(canB.status === 200 && canB.json.status === 'cancelled' && (await call('/rest/v1/pets?select=id', { token: OB.token })).status === 200,
    'cancelar dentro de la gracia desbloquea la cuenta');
  const canB2 = await rpc('cancel_account_deletion', {}, OB.token);
  check(canB2.status === 400 && canB2.json?.code === '22023', 'cancelar sin solicitud vigente → 22023');

  // Vet en revisión que pide el borrado: ¿sigue el tratamiento por la Edge Function y el admin?
  const VR = await newUser('vet-rev');
  await register(VR, 'vet', 'Dr. Revisión Bloqueado');
  const tp = `${VR.id}/titulo.pdf`; const ip = `${VR.id}/cedula.pdf`;
  await call(`/storage/v1/object/vet-documents/${tp}`, { method: 'POST', token: VR.token, raw: PDF, type: 'application/pdf' });
  await call(`/storage/v1/object/vet-documents/${ip}`, { method: 'POST', token: VR.token, raw: PDF, type: 'application/pdf' });
  await call('/rest/v1/vet_documents', { method: 'POST', token: VR.token, body: [
    { vet_id: VR.id, kind: 'degree_certificate', storage_path: tp, mime: 'application/pdf', size_bytes: PDF.length },
    { vet_id: VR.id, kind: 'id_card_front', storage_path: ip, mime: 'application/pdf', size_bytes: PDF.length }] });
  await call('/rest/v1/vet_species', { method: 'POST', token: VR.token, body: { vet_id: VR.id, species_id: perro } });
  await call('/rest/v1/vet_specialties', { method: 'POST', token: VR.token, body: { vet_id: VR.id, specialty_id: general } });
  await call(`/rest/v1/vet_profiles?user_id=eq.${VR.id}`, { method: 'PATCH', token: VR.token,
    body: { university: 'Universidad de Concepción', graduation_year: 2018, title_verification_code: 'QA-1', declaration_accepted_at: new Date().toISOString() } });
  const subm = await rpc('submit_vet_application', {}, VR.token);
  check(subm.status === 200, 'el vet envía su solicitud de verificación');
  check((await rpc('request_account_deletion', {}, VR.token)).status === 200, 'el vet en revisión pide borrar su cuenta');
  await relogin(VR);
  const nBefore = Number(sql(`select count(*) from public.vet_title_verifications where vet_id = '${VR.id}'`));
  const vt = await fn('verify-vet-title', VR.token, {});
  const nAfter = Number(sql(`select count(*) from public.vet_title_verifications where vet_id = '${VR.id}'`));
  expectFixed(vt.status >= 400 && nAfter === nBefore, 'QA-F11-04',
    `verify-vet-title (clave de servicio) no trata los datos del vet bloqueado (HTTP ${vt.status}, verificaciones ${nBefore}→${nAfter})`);
  const review = await rpc('review_vet_application', { p_vet_id: VR.id, p_approve: true, p_reason: null, p_notes: 'QA' }, AD.token);
  const stVR = sql(`select status from public.vet_profiles where user_id = '${VR.id}'`);
  expectFixed(review.status >= 400 && stVR === 'pending', 'QA-F11-04',
    `el admin no aprueba la solicitud de un vet bloqueado (HTTP ${review.status}, estado ${stVR})`);
  // Re-QA db5f16c: ¿una cuarta vía? El admin escribe directo por REST (sin la RPC) sobre el vet bloqueado.
  const admProf = await call(`/rest/v1/vet_profiles?user_id=eq.${VR.id}`, { method: 'PATCH', token: AD.token,
    prefer: 'return=representation', body: { status: 'approved', reviewed_at: new Date().toISOString(), review_notes: 'QA directo' } });
  const stVR2 = sql(`select status || '|' || coalesce(review_notes, '-') from public.vet_profiles where user_id = '${VR.id}'`);
  expectFixed(admProf.status >= 400 && stVR2 === 'pending|-', 'QA-F11-07',
    `el admin no aprueba ni anota al vet bloqueado con PATCH directo a vet_profiles (HTTP ${admProf.status}, ${stVR2})`);
  const admDoc = await call(`/rest/v1/vet_documents?vet_id=eq.${VR.id}`, { method: 'PATCH', token: AD.token,
    prefer: 'return=representation', body: { review_status: 'accepted' } });
  const docVR = sql(`select string_agg(distinct review_status, ',') from public.vet_documents where vet_id = '${VR.id}'`);
  expectFixed(admDoc.status >= 400 && docVR !== 'accepted', 'QA-F11-07',
    `el admin no revisa los documentos del vet bloqueado con PATCH directo (HTTP ${admDoc.status}, review_status ${docVR})`);
  const admSign = await call(`/storage/v1/object/sign/vet-documents/${tp}`, { method: 'POST', token: AD.token, body: { expiresIn: 60 } });
  info(`el admin firma el título del vet bloqueado: HTTP ${admSign.status} (lectura para auditoría; ver informe)`);
  const vrReq = sql(`select id from public.deletion_requests where user_id = '${VR.id}' and status = 'blocked'`);

  // =====================================================================================
  // B. Borrado completo de un dueño con historia
  // =====================================================================================
  console.log('\n--- B. Borrado del dueño ---');
  const VC = await approvedVet('vet-c', 'Dra. Autora');
  const VC2 = await approvedVet('vet-c2', 'Dr. Autorizado');
  const FM = await newUser('fund');
  await svc('/rest/v1/user_roles', { user_id: FM.id, role: 'foundation' });
  await svc('/rest/v1/foundation_members', { user_id: FM.id, foundation_id: HUELLAS });
  await relogin(FM);
  const OC = await ownerWithPet('dueno-c', 'Ángela Muñoz', '+56 9 8765 4321', 'Ñandú',
    'Avenida Los Álamos 1234', 'Torre B depto 51', '941000011112222');
  const pf = await call(`/rest/v1/owner_profiles?user_id=eq.${OC.id}`, { method: 'PATCH', token: OC.token, body: { foundation_id: HUELLAS } });
  check(pf.status < 300, `el dueño elige la fundación Huellas (HTTP ${pf.status})`);
  const summ = async () => JSON.stringify((await rpc('foundation_summary', { p_months: 12 }, FM.token)).json);
  const BODY = [
    'ÁNGELA MUÑOZ trajo a ÑANDÚ; ángela muñoz y ñandú.',
    'Sin tildes: Angela Munoz y Nandu.',
    'Fonos 987654321, +56987654321, 9 8765 4321, 987 654 321.',
    `Correo ${OC.email.toUpperCase()}.`,
    'Dirección parcial: Los Álamos 1234, Torre B.',
    'Chip 941000011112222. Control en 10 días.',
  ].join(' ');
  let entryC;
  const visitC = await visitWith(OC, VC, 'completed', { donation: 1500, onArrived: async (id) => {
    entryC = (await rpc('add_clinical_entry', { p_pet_id: OC.pet, p_kind: 'diagnosis', p_title: 'Control de ÑANDÚ (Muñoz)',
      p_body: BODY, p_visit_id: id, p_specialty_id: general }, VC.token)).json;
  } });
  check(typeof entryC === 'string', 'el vet escribe un diagnóstico con PII del dueño en variantes');
  const attPath = `pets/${OC.pet}/${entryC}/radiografia.pdf`;
  await call(`/storage/v1/object/${BUCKET}/${attPath}`, { method: 'POST', token: VC.token, raw: PDF, type: 'application/pdf' });
  await call('/rest/v1/entry_attachments', { method: 'POST', token: VC.token,
    body: { entry_id: entryC, storage_path: attPath, file_name: 'radiografia.pdf', mime: 'application/pdf', size_bytes: PDF.length } });
  const payC = await rpc('simulate_payment', { p_visit_id: visitC }, OC.token);
  check(payC.status === 200, 'el dueño paga la visita (simulado) con donación');
  // HU8.6: lo que el vet y la fundación leen del pago.
  const vetPay = await call(`/rest/v1/payments?select=owner_id,extra_donation,total,quote_id&visit_id=eq.${visitC}`, { token: VC.token });
  const vetQuote = await call(`/rest/v1/quotes?select=id,total,extra_donation&owner_id=eq.${OC.id}`, { token: VC.token });
  info(`HU8.6: el vet lee del pago de su visita ${JSON.stringify(vetPay.json)}; cotizaciones del dueño: ${JSON.stringify(vetQuote.json)}`);
  expectFixed(!(vetPay.json?.[0]?.owner_id || vetPay.json?.[0]?.extra_donation), 'QA-F11-05',
    'HU8.6: el vet no ve el dueño ni la donación del pago de su visita');
  // Re-QA db5f16c: QA-F11-05 por las otras vías (REST sin filtro, GraphQL, my_payouts, Realtime).
  const vetPayAll = await call('/rest/v1/payments?select=id', { token: VC.token });
  const gqlPay = await call('/graphql/v1', { method: 'POST', token: VC.token,
    body: { query: '{ paymentsCollection { edges { node { id ownerId extraDonation total } } } }' } });
  const gqlRows = gqlPay.json?.data?.paymentsCollection?.edges ?? [];
  const payouts = await rpc('my_payouts', {}, VC.token);
  const pk = Object.keys(payouts.json?.[0] ?? {}).sort().join(',');
  check(Array.isArray(vetPayAll.json) && vetPayAll.json.length === 0 && gqlRows.length === 0,
    `QA-F11-05: el vet no lee filas de payments por REST ni GraphQL (REST ${vetPayAll.json?.length}, GraphQL ${gqlRows.length})`);
  check(payouts.status === 200 && payouts.json.some((p) => p.visit_id === visitC)
    && pk === 'created_at,kind,paid_at,platform_fee,service_price,status,vet_payout,visit_id',
  `QA-F11-05: my_payouts del vet trae su liquidación sin dueño, total, cotización ni donación (${pk})`);
  const payoutsOwner = await rpc('my_payouts', {}, OC.token);
  const payoutsF = await rpc('my_payouts', {}, FM.token);
  check(payoutsOwner.status === 200 && payoutsOwner.json.length === 0 && payoutsF.status === 200 && payoutsF.json.length === 0,
    'QA-F11-05: my_payouts no devuelve nada al dueño ni a la fundación');
  const pubs = sql("select coalesce(string_agg(schemaname || '.' || tablename, ','), '-') from pg_publication_tables where tablename in ('payments','quotes','payment_events','foundation_contributions')");
  check(pubs === '-', `QA-F11-05: payments, quotes y sus eventos no están en ninguna publicación de Realtime (${pubs})`);
  const fPay = await call('/rest/v1/payments?select=id', { token: FM.token });
  const fQ = await call('/rest/v1/quotes?select=id', { token: FM.token });
  check(Array.isArray(fPay.json) && fPay.json.length === 0 && (fQ.json?.length ?? 0) === 0, 'HU8.6: la fundación no lee pagos ni cotizaciones');
  const chipOther = await call(`/rest/v1/pets?select=microchip&id=eq.${OC.pet}`, { token: VC2.token });
  const chipRecOther = await rpc('get_pet_record', { p_pet_id: OC.pet }, VC2.token);
  const chipF = await call(`/rest/v1/pets?select=microchip&id=eq.${OC.pet}`, { token: FM.token });
  const chipVet = await rpc('get_pet_record', { p_pet_id: OC.pet, p_visit_id: visitC }, VC.token);
  check((chipOther.json?.length ?? 0) === 0 && chipRecOther.status === 403 && (chipF.json?.length ?? 0) === 0
    && JSON.stringify(chipVet.json).includes('941000011112222'),
  'microchip: no lo ven otro vet ni la fundación; sí el vet con acceso vigente (get_pet_record)');
  const myVisitsVet = await rpc('my_visits', {}, VC.token);
  check(!myVisitsVet.text.includes('941000011112222'), 'my_visits del vet no trae el microchip');
  // Autorización del dueño a otro vet + lectura registrada.
  const g = await call('/rest/v1/record_access_grants', { method: 'POST', token: OC.token,
    body: { pet_id: OC.pet, vet_id: VC2.id, source: 'owner', expires_at: new Date(Date.now() + 7 * 86400000).toISOString() } });
  const readC2 = await rpc('get_pet_record', { p_pet_id: OC.pet }, VC2.token);
  check(g.status === 201 && readC2.status === 200, 'el dueño autoriza a otro vet y este lee la ficha (queda en el log)');
  // Visita cancelada con motivo, nota del dueño, push, consentimientos y exportación.
  const visitC2 = await visitWith(OC, VC, 'accepted');
  await rpc('transition_visit', { p_visit_id: visitC2, p_to_status: 'cancelled_owner', p_reason: 'Me mudo de Los Álamos 1234' }, OC.token);
  await rpc('add_clinical_entry', { p_pet_id: OC.pet, p_kind: 'note', p_title: 'Nota de Ángela' }, OC.token);
  check((await rpc('register_push_device', { p_token: `qa-token-${stamp}`, p_platform: 'android' }, OC.token)).status < 300, 'el dueño registra un token push');
  await rpc('set_consent', { p_purpose: 'marketing', p_granted: true }, OC.token);
  // --- Exportación del dueño (HU8.1) ---
  const exO = await rpc('export_my_data', {}, OC.token);
  const eo = exO.json;
  check(exO.status === 200 && eo.format === 'felix-export' && eo.profile?.phone === '+56 9 8765 4321' && eo.pets?.[0]?.microchip
    && eo.addresses?.length === 1 && eo.visits?.length === 2 && eo.clinical_entries?.length >= 2 && eo.payments?.length >= 1
    && eo.consents?.length === 1 && eo.push_devices?.length === 1 && eo.record_access_log?.length >= 1 && eo.record_access_grants?.length === 1,
  'exportación del dueño: perfil, mascota, dirección, ficha, visitas, pagos, consentimientos, push, log y autorizaciones');
  const vetBase = sql(`select lat || ',' || ST_Y(quote_origin::geometry) from public.vet_bases where vet_id = '${VC.id}'`);
  check(!exO.text.includes('-33.3849') && !exO.text.includes(vetBase.split(',')[1].slice(0, 7)) && !/distance_m|quote_origin|vet_payout_?base/.test(exO.text)
    && !exO.text.includes(VC.email) && !exO.text.includes(VC.id),
  'exportación del dueño sin datos del vet (base, origen, distancia, email ni id)');
  const exRow = sql(`select role || '|' || array_length(sections, 1) || '|' ||
      (select string_agg(column_name, ',' order by column_name) from information_schema.columns where table_schema='public' and table_name='data_exports')
    from public.data_exports where user_id = '${OC.id}' order by id desc limit 1`);
  check(/^owner\|\d+\|exported_at,id,role,sections,user_id$/.test(exRow), `la exportación queda registrada sin contenido (${exRow})`);
  // --- Exportación del vet y de la fundación (HU8.5) ---
  const exV = await rpc('export_my_data', {}, VC.token);
  const ownerLeaks = ['8765 4321', 'Álamos', 'Ñandú', 'Muñoz', 'Torre B', OC.email, OC.id, OC.pet, OC.addr, '941000011112222', 'Control en 10']
    .filter((x) => exV.text.toLowerCase().includes(x.toLowerCase()));
  check(exV.status === 200 && exV.json.subject_role === 'vet' && exV.json.base && exV.json.payouts?.length >= 1
    && ownerLeaks.length === 0 && !/extra_donation|"total"/.test(JSON.stringify(exV.json.payouts)),
  `exportación del vet: base, liquidaciones sin total ni donación, sin datos del dueño ni de la ficha (fugas: ${ownerLeaks.join(', ') || 'ninguna'})`);
  const exF = await rpc('export_my_data', {}, FM.token);
  check(exF.status === 200 && exF.json.memberships?.[0]?.foundation === 'Fundación Demo Huellas'
    && !/payments|total|donation|Muñoz/.test(exF.text), 'exportación de la fundación: membresía y nada de pagos ni dueños');
  // --- Solicitud, gracia vencida y job; Storage caído a mitad ---
  const sumBefore = await summ();
  info(`foundation_summary antes del borrado: ${sumBefore}`);
  check(sumBefore.includes('1500') || /donation/.test(sumBefore), 'el resumen de la fundación incluye el aporte del dueño');
  const reqC = (await rpc('request_account_deletion', {}, OC.token)).json.request_id;
  expire(reqC);
  check(runJob().includes('"executing"'), 'vencida la gracia el job empieza y espera a Storage');
  const t1 = targetsCount(reqC);
  check(runJob().includes('"executing"') && targetsCount(reqC) === t1, `reintento sin Storage: sigue executing y no duplica deletion_targets (${t1})`);
  const stoName = execFileSync(DOCKER, ['ps', '--filter', 'name=supabase_storage_', '--filter', `publish=${new URL(API).port}`, '--format', '{{.Names}}']).toString().trim()
    || execFileSync(DOCKER, ['ps', '--format', '{{.Names}}']).toString().split(/\r?\n/).find((n) => n.startsWith('supabase_storage_') && !n.endsWith('proyecto-felix'));
  execFileSync(DOCKER, ['stop', stoName]);
  const down = await purge();
  info(`Edge Function con Storage caído → HTTP ${down.status} ${JSON.stringify(down.json)}`);
  check(runJob().includes('"executing"') && targetsCount(reqC) === t1, 'con Storage caído la solicitud queda en executing, sin duplicar ni perder');
  execFileSync(DOCKER, ['start', stoName]);
  for (let i = 0; i < 30 && (await call('/storage/v1/bucket', { key: SRV, token: SRV })).status !== 200; i++) await sleep(1000);
  // Tabla nueva con user_id creada "después": el escaneo por catálogo debe detectarla.
  sql(`create table public.qa_probe_residue (id bigint generated always as identity primary key, user_id uuid, nota text);
       revoke all on public.qa_probe_residue from anon, authenticated; alter table public.qa_probe_residue enable row level security;
       insert into public.qa_probe_residue (user_id, nota) values ('${OC.id}', 'resto');`);
  toDrop.push('public.qa_probe_residue');
  const up = await purge();
  check(up.status === 200 && up.json.removed >= 1, `Storage de vuelta: la Edge Function borra con la API (${JSON.stringify(up.json)})`);
  const r3 = runJob();
  const residue = sql(`select detail::text from public.deletion_targets where request_id = '${reqC}' and target = 'verification_scan' order by id desc limit 1`);
  check(r3.includes('"executing"') && residue.includes('qa_probe_residue'), `una tabla nueva con user_id entra sola al escaneo y lo hace fallar (${residue})`);
  sql(`delete from public.qa_probe_residue`);
  check(runJob().includes('"done"'), 'sin restos, el job termina (done)');
  const tDone = targetsCount(reqC);
  check(runJob() === '{}' && targetsCount(reqC) === tDone, 'idempotente: correr el job otra vez no cambia nada');
  // Verificación manual (no solo el escaneo del producto).
  const scan = deepScan([OC.id, OC.pet, OC.addr, OC.email, '87654321', '8765 4321', '941000011112222', 'Avenida Los Álamos 1234', 'Torre B depto 51', `qa-token-${stamp}`]);
  info(`escaneo manual en todos los esquemas: ${scan || '(vacío)'}`);
  check(scan === '', 'escaneo manual: ningún esquema guarda el id, mascota, dirección, email, teléfono, microchip ni token');
  check(!(await objExists(BUCKET, attPath)), 'el adjunto ya no existe en Storage (API)');
  const vRow = sql(`select coalesce(owner_id::text,'-')||'|'||coalesce(pet_id::text,'-')||'|'||coalesce(address_id::text,'-')||'|'||commune_id||'|'||species_id||'|'||
      coalesce(cancel_reason,'-')||'|'||coalesce(owner_notes,'-')||'|'||(quote->>'total') from public.visits where id in ('${visitC}','${visitC2}') order by created_at`);
  check(vRow.split('\n').every((l) => l.startsWith(`-|-|-|${nunoa}|${perro}|-|-|`)), `visitas anonimizadas con comuna, especie y montos (${vRow.replace(/\n/g, ' / ')})`);
  check(sql(`select (owner_id is null)::text||':'||total||':'||extra_donation from public.payments where visit_id = '${visitC}' and kind='visit'`)
    === `true:${payC.json.total}:1500`, 'el pago queda sin dueño, con total y donación');
  check((await summ()) === sumBefore, 'foundation_summary() igual antes y después');
  const ret = sql(`select coalesce(pet_id::text,'-')||'|'||(retain_until > now() + interval '1826 days' - interval '2 days')||'|'||title||'|'||body from public.clinical_entries where id = '${entryC}'`);
  info(`entrada retenida: ${ret}`);
  const [rPet, rUntil, rTitle, rBody] = ret.split('|');
  check(rPet === '-' && rUntil === 'true' && !/ñandú|muñoz/i.test(rTitle), 'la entrada del vet queda desvinculada, con +5 años y el título redactado');
  check(!/ángela|muñoz|ñandú|987654321|\+56987654321|9 8765 4321/i.test(rBody) && !rBody.toLowerCase().includes(OC.email.toLowerCase())
    && rBody.includes('Control en 10 días'), 'redactados: nombre y mascota (mayúsculas/tildes), teléfono con y sin +56, email; el contenido clínico queda');
  expectFixed(!/angela|munoz|nandu/i.test(rBody), 'QA-F11-01', 'redacta el nombre y la mascota escritos sin tildes');
  expectFixed(!/Álamos 1234|Torre B/i.test(rBody), 'QA-F11-01', 'redacta la dirección parcial (calle y número sin el prefijo, "Torre B")');
  expectFixed(!/987 654 321/.test(rBody), 'QA-F11-01', 'redacta el teléfono agrupado 3-3-3');
  check(sql(`select count(*) from private.push_devices where token = 'qa-token-${stamp}'`) === '0', 'el token push se borró');
  check(sql(`select count(*) from public.record_access_grants where vet_id = '${VC2.id}'`) === '0', 'las autorizaciones de la ficha se borraron');
  check((await login(OC.email)).status >= 400, 'el dueño borrado ya no inicia sesión');

  // =====================================================================================
  // C. Entradas retenidas (P1) y retención (§8)
  // =====================================================================================
  console.log('\n--- C. Retenidas y retención ---');
  const lst = await rpc('list_my_retained_entries', {}, VC.token);
  check(lst.status === 200 && lst.json.some((e) => e.id === entryC) && !lst.text.includes('Control'), 'el vet autor lista su retenida sin contenido');
  const short = await rpc('request_retained_entry', { p_entry_id: entryC, p_reason: 'corto' }, VC.token);
  const long = await rpc('request_retained_entry', { p_entry_id: entryC, p_reason: 'x'.repeat(501) }, VC.token);
  check(short.json?.code === '22023' && long.json?.code === '22023', 'motivo de menos de 10 o más de 500 caracteres → 22023');
  const nReq = Number(sql(`select count(*) from public.retained_entry_requests where entry_id = '${entryC}'`));
  const okReq = await rpc('request_retained_entry', { p_entry_id: entryC, p_reason: 'Reclamo formal del tutor ante el colegio' }, VC.token);
  check(okReq.status === 200 && okReq.json.body?.includes('Control en 10 días')
    && Number(sql(`select count(*) from public.retained_entry_requests where entry_id = '${entryC}'`)) === nReq + 1,
  'con motivo válido el autor la lee y queda registrada la solicitud');
  const OX = await ownerWithPet('dueno-x', 'Xavier Otro', null, 'Mota', 'Calle Otra 1');
  const others = [['otro vet', VC2], ['admin', AD], ['otro dueño', OX]];
  const outs = [];
  for (const [n, u] of others) {
    const r = await rpc('request_retained_entry', { p_entry_id: entryC, p_reason: 'Quiero ver esta entrada ajena' }, u.token);
    outs.push(`${n}:${r.status}/${r.json?.code}`);
  }
  check(outs.every((o) => o.endsWith('/42501')), `nadie más la lee: ${outs.join(', ')}`);
  check(sql(`select count(*) from public.clinical_entries where id = '${entryC}'`) === '1', 'antes de vencer la retención la entrada sigue');
  sql(`set felix.record_maintenance = 'on'; update public.clinical_entries set retain_until = now() - interval '1 minute' where id = '${entryC}'`);
  // Log > 2 años y token push > 90 días (dueño OX).
  await rpc('register_push_device', { p_token: `qa-old-${stamp}`, p_platform: 'android' }, OX.token);
  await rpc('register_push_device', { p_token: `qa-new-${stamp}`, p_platform: 'android' }, OX.token);
  sql(`update private.push_devices set last_seen_at = now() - interval '91 days' where token = 'qa-old-${stamp}'`);
  const gx = await call('/rest/v1/record_access_grants', { method: 'POST', token: OX.token,
    body: { pet_id: OX.pet, vet_id: VC2.id, source: 'owner', expires_at: new Date(Date.now() + 7 * 86400000).toISOString() } });
  await rpc('get_pet_record', { p_pet_id: OX.pet }, VC2.token);
  await rpc('get_pet_record', { p_pet_id: OX.pet }, VC2.token);
  const logIds = sql(`select string_agg(id::text, ',' order by id) from public.record_access_log where pet_id = '${OX.pet}' and actor_id = '${VC2.id}' and action = 'view'`).split(',');
  sql(`set felix.record_maintenance = 'on'; update public.record_access_log set at = now() - interval '2 years 1 day' where id = ${logIds[0]}`);
  info(`retención: ${sql('select private.run_privacy_retention()')}`);
  check(gx.status === 201 && sql(`select count(*) from public.clinical_entries where id = '${entryC}'`) === '0', 'el job de retención borra la entrada al vencer retain_until');
  check(sql(`select coalesce(actor_id::text, 'null') from public.record_access_log where id = ${logIds[0]}`) === 'null'
    && sql(`select actor_id from public.record_access_log where id = ${logIds[1]}`) === VC2.id, 'record_access_log > 2 años queda sin actor; el reciente lo conserva');
  check(sql(`select string_agg(token, ',') from private.push_devices where user_id = '${OX.id}'`) === `qa-new-${stamp}`, 'token push > 90 días borrado; el reciente queda');
  // M2: adjunto huérfano > 24 h.
  const oxEntry = (await rpc('add_clinical_entry', { p_pet_id: OX.pet, p_kind: 'note', p_title: 'Nota huérfana' }, OX.token)).json;
  const orphanOld = `pets/${OX.pet}/${oxEntry}/huerfano-viejo.pdf`; const orphanNew = `pets/${OX.pet}/${oxEntry}/huerfano-nuevo.pdf`;
  const u1 = await call(`/storage/v1/object/${BUCKET}/${orphanOld}`, { method: 'POST', token: OX.token, raw: PDF, type: 'application/pdf' });
  const u2 = await call(`/storage/v1/object/${BUCKET}/${orphanNew}`, { method: 'POST', token: OX.token, raw: PDF, type: 'application/pdf' });
  sql(`update storage.objects set created_at = now() - interval '25 hours' where bucket_id = '${BUCKET}' and name = '${orphanOld}'`);
  const po = await purge();
  check(u1.status === 200 && u2.status === 200 && po.status === 200 && !(await objExists(BUCKET, orphanOld)) && (await objExists(BUCKET, orphanNew)),
    `M2: la Edge Function borra el huérfano de más de 24 h y deja el reciente (${JSON.stringify(po.json)})`);

  // =====================================================================================
  // D. Vet que borra su cuenta (HU8.5)
  // =====================================================================================
  console.log('\n--- D. Borrado del vet ---');
  let dDoc; let dUp; let dReg;
  const VD = await approvedVet('vet-d', 'Dr. Se Va', -33.3849, async (v) => {
    dDoc = `${v.id}/titulo-${stamp}.pdf`;
    dUp = await call(`/storage/v1/object/vet-documents/${dDoc}`, { method: 'POST', token: v.token, raw: PDF, type: 'application/pdf' });
    dReg = await call('/rest/v1/vet_documents', { method: 'POST', token: v.token, body: { vet_id: v.id, kind: 'degree_certificate', storage_path: dDoc, mime: 'application/pdf', size_bytes: PDF.length } });
  });
  check(dUp.status === 200 && dReg.status === 201, 'el vet subió y registró su certificado (Storage vet-documents)');
  const OD = await ownerWithPet('dueno-d', 'Diana Queda', '+56 9 3333 4444', 'Pelusa', 'Calle Queda 5');
  let entryD;
  const visitD = await visitWith(OD, VD, 'completed', { onArrived: async (id) => {
    entryD = (await rpc('add_clinical_entry', { p_pet_id: OD.pet, p_kind: 'diagnosis', p_title: 'Dermatitis', p_body: 'Tratamiento tópico',
      p_visit_id: id, p_specialty_id: general }, VD.token)).json;
  } });
  const payD = await rpc('simulate_payment', { p_visit_id: visitD }, OD.token);
  const attD = `pets/${OD.pet}/${entryD}/foto.pdf`;
  await call(`/storage/v1/object/${BUCKET}/${attD}`, { method: 'POST', token: VD.token, raw: PDF, type: 'application/pdf' });
  await call('/rest/v1/entry_attachments', { method: 'POST', token: VD.token,
    body: { entry_id: entryD, storage_path: attD, file_name: 'foto.pdf', mime: 'application/pdf', size_bytes: PDF.length } });
  const recBefore = await rpc('get_pet_record', { p_pet_id: OD.pet }, OD.token);
  const nEntries = JSON.stringify(recBefore.json).split('"kind"').length;
  const reqD = (await rpc('request_account_deletion', {}, VD.token)).json.request_id;
  expire(reqD);
  const rD1 = runJob(); await purge(); const rD = runJob();
  check(rD1.includes('"executing"') && rD.includes('"done"'), `el borrado del vet espera a Storage y termina (${rD1} → ${rD})`);
  const recAfter = await rpc('get_pet_record', { p_pet_id: OD.pet }, OD.token);
  const recTxt = JSON.stringify(recAfter.json);
  check(recAfter.status === 200 && recTxt.split('"kind"').length === nEntries && recTxt.includes('MV verificado') && !recTxt.includes('Dr. Se Va')
    && recTxt.includes('Tratamiento tópico'), 'la ficha del dueño conserva las entradas con el autor "MV verificado"');
  check(await objExists(BUCKET, attD), 'el adjunto del vet en la ficha del dueño se conserva');
  check(!(await objExists('vet-documents', dDoc)) && sql(`select count(*) from public.vet_bases where vet_id = '${VD.id}'`) === '0',
    'documentos (Storage) y base del vet borrados');
  check(sql(`select coalesce(vet_id::text,'-')||'|'||(quote ? 'vet_id')::text from public.visits where id = '${visitD}'`) === '-|false'
    && sql(`select coalesce(vet_id::text,'-')||'|'||total from public.payments where visit_id = '${visitD}' and kind='visit'`) === `-|${payD.json.total}`,
  'visita y pago anonimizados del lado del vet (montos intactos)');
  const scanD = deepScan([VD.id, VD.email, 'Dr. Se Va']);
  check(scanD === '', `escaneo manual sin restos del vet (${scanD || 'vacío'})`);

  // =====================================================================================
  // E. Consentimientos y política (HU8.3, HU8.4)
  // =====================================================================================
  console.log('\n--- E. Consentimientos ---');
  const c1 = await rpc('set_consent', { p_purpose: 'marketing', p_granted: true }, OD.token);
  const c2 = await rpc('set_consent', { p_purpose: 'marketing', p_granted: false }, OD.token);
  const c3 = await rpc('set_consent', { p_purpose: 'marketing', p_granted: true }, OD.token);
  check(c1.json.purposes[0].granted && c2.json.purposes[0].granted === false && c2.json.purposes[0].last_revoked_at
    && c3.json.history.length === 2 && c3.json.history.some((h) => h.revoked_at), 'retirar fecha la fila y la historia se conserva al volver a otorgar');
  const bad = await rpc('set_consent', { p_purpose: 'perfilamiento', p_granted: true }, OD.token);
  const badNull = await rpc('set_consent', { p_purpose: 'marketing', p_granted: null }, OD.token);
  check(bad.json?.code === '22023' && badNull.json?.code === '22023', 'finalidad desconocida o valor nulo → 22023');
  await rpc('record_privacy_notice_view', {}, OD.token);
  const v0 = await rpc('my_privacy_status', {}, OD.token);
  sql(`insert into public.legal_versions (kind, version, effective_from) values ('privacy', 'qa-${stamp}', now() - interval '1 second')`);
  const v1 = await rpc('my_privacy_status', {}, OD.token);
  const v2 = await rpc('record_privacy_notice_view', {}, OD.token);
  check(v0.json.must_review === false && v1.json.must_review === true && v1.json.privacy_version === `qa-${stamp}` && v2.json.must_review === false,
    'al subir la versión de la política: must_review true; al verla, false');
  check(v1.json.purposes.every((p) => p.ask === false), 'sin finalidad nueva no se pide consentimiento (ask = false)');
  sql(`delete from public.privacy_notice_views where version = 'qa-${stamp}'; delete from public.legal_versions where version = 'qa-${stamp}'`);

  // Limpieza de la solicitud bloqueada del vet en revisión (se cancela).
  if (vrReq) sql(`update public.deletion_requests set status = 'cancelled', cancelled_at = now() where id = '${vrReq}'`);
} catch (e) {
  console.log(`FALLA excepción: ${e.stack}`);
  fails++;
} finally {
  for (const s of sockets) s.close();
  for (const t of toDrop) { try { sql(`drop table if exists ${t}`); } catch { /* */ } }
  // Limpieza con el propio job de borrado (un dueño con ficha no se puede borrar de Auth
  // directo): cada usuario con rol recibe una solicitud vencida; el resto se borra de Auth.
  try {
    const ids = created.map((x) => `'${x}'`).join(',');
    const t0 = sql('select now()');
    sql(`set felix.record_maintenance = 'on';
      delete from public.clinical_entries where author_id in (${ids}) and pet_id is null;
      update public.deletion_requests set status = 'cancelled', cancelled_at = now()
        where user_id in (${ids}) and status in ('blocked', 'executing');
      insert into public.deletion_requests (user_id, role, execute_after)
        select r.user_id, r.role, now() - interval '1 minute' from public.user_roles r
        where r.user_id in (${ids}) and r.role in ('owner', 'vet', 'foundation');`);
    for (let i = 0; i < 4 && sql(`select count(*) from public.deletion_requests where status in ('blocked','executing') and execute_after <= now()`) !== '0'; i++) {
      runJob(); await purge();
    }
    sql(`delete from auth.users where id in (${ids});
      delete from public.deletion_requests where requested_at >= '${t0}'::timestamptz - interval '2 hours'
        and (user_id is null or user_id in (${ids}));`);
  } catch (e) { console.log(`limpieza: ${e.message.split('\n')[0]}`); }
  // Las visitas y pagos anonimizados (contabilidad) también son datos de esta corrida.
  if (myVisits.length) {
    try {
      const vs = myVisits.map((x) => `'${x}'`).join(',');
      // Solo stack local: supabase_admin para saltar los guardianes (los pagos y visitas no se borran por la API).
      const dbName = execFileSync(DOCKER, ['ps', '--filter', `publish=${new URL(st.DB_URL).port}`, '--format', '{{.Names}}']).toString().trim().split(/\r?\n/)[0];
      const admin = (q) => execFileSync(DOCKER, ['exec', '-i', dbName, 'psql', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-tA', '-c', q]).toString();
      admin(`set session_replication_role = replica;
        delete from public.foundation_contributions where payment_id in (select id from public.payments where visit_id in (${vs}));
        delete from public.payment_events where payment_id in (select id from public.payments where visit_id in (${vs}));
        delete from public.payments where visit_id in (${vs});
        delete from public.visit_offers where visit_id in (${vs});
        delete from public.visit_events where visit_id in (${vs});
        delete from public.visits where id in (${vs});`);
    } catch (e) { console.log(`limpieza de visitas: ${e.message.split('\n')[0]}`); }
  }
  try {
    const left = sql(`select count(*) from auth.users where email like 'qa11-%-${stamp}@test.local'`);
    console.log(`limpieza: quedan ${left} usuarios de esta corrida`);
  } catch { /* */ }
}

const ids = [...defects].sort();
console.log(fails === 0 && ids.length === 0 ? '\nQA exploratorio fase 11: TODO OK'
  : `\nQA exploratorio fase 11: ${fails} fallas, defectos abiertos: ${ids.join(', ') || 'ninguno'}`);
process.exit(fails ? 1 : ids.length ? 2 : 0);
