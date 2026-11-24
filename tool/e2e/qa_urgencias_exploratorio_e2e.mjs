// QA exploratorio de la fase 8 (urgencias) contra un Supabase local (QA 37c4e3c):
// tandas y radios, concurrencia real de accept_offer (más vets, repeticiones,
// carreras con el vencimiento, la cancelación y otras solicitudes), Realtime
// privado `visit:{id}` con un WebSocket real (protocolo Phoenix de Realtime),
// privacidad (presencia, ofertas, push), precio (tope, versión congelada,
// cargo por cancelación) y las 2 observaciones del Dev App.
// Uso: node tool/e2e/qa_urgencias_exploratorio_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
// Requiere PUSH_PROVIDER = "fake" en [edge_runtime.secrets].
// Salida: 0 sin defectos, 2 solo con defectos conocidos (DEFECTO), 1 si algo más falla.
// Pausa el job pg_cron `dispatch-urgent-visits` mientras corre (las tandas se
// fuerzan con SQL) y lo reactiva al final. Publica una versión de
// pricing_config y luego restaura los valores por defecto.
// Crea usuarios @test.local y los borra al final.
import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { promisify } from 'node:util';
import { sqlRunner, timeTravel } from './sql.mjs';

const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;
const sql = sqlRunner(st);

// SQL asíncrono (para correr el despacho en paralelo con la API).
const WIN_DOCKER = 'C:\\Program Files\\Docker\\Docker\\resources\\bin\\docker.exe';
const DOCKER = process.env.DOCKER_BIN || (existsSync(WIN_DOCKER) ? WIN_DOCKER : 'docker');
const dbName = (await promisify(execFile)(DOCKER, ['ps', '--filter', `publish=${new URL(st.DB_URL).port}`,
  '--format', '{{.Names}}'])).stdout.trim().split(/\r?\n/)[0];
const sqlAsync = async (q) => (await promisify(execFile)(DOCKER,
  ['exec', '-i', dbName, 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-tA', '-c', q])).stdout.trim();

let fails = 0;
let defects = 0;
const check = (cond, msg, defect) => {
  if (cond) console.log(`OK    ${msg}`);
  else if (defect) { console.log(`DEFECTO ${defect}: ${msg}`); defects++; }
  else { console.log(`FALLA ${msg}`); fails++; }
};
const info = (msg) => console.log(`INFO  ${msg}`);

async function call(path, { method = 'GET', token, key = PUB, body, prefer } = {}) {
  const headers = { apikey: key };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (prefer) headers.Prefer = prefer;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(API + path, { method, headers, body: body !== undefined ? JSON.stringify(body) : undefined });
  const text = await r.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, json };
}
const rpc = (name, body, token) => call(`/rest/v1/rpc/${name}`, { method: 'POST', token, body });
const svc = (path, body, method = 'POST') => call(path, { method, key: SRV, token: SRV, body });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; };

const stamp = Date.now();
const created = [];
async function newUser(tag) {
  const email = `qaf8-${tag}-${stamp}@test.local`;
  const c = await svc('/auth/v1/admin/users', { email, password: 'Felix2026', email_confirm: true });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status}`);
  created.push(c.json.id);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password: 'Felix2026' } });
  return { token: s.json.access_token, id: s.json.user.id, tag };
}

// --- Cliente Realtime mínimo (Phoenix, vsn configurable: RT_VSN = 1.0.0 | 2.0.0 (por defecto 2.0.0, como supabase-js y realtime_client)) sobre WebSocket real ------------------
const RT_VSN = process.env.RT_VSN || '2.0.0';
class Rt {
  constructor(token) { this.token = token; this.msgs = []; this.ref = 0; this.waiters = new Map(); }
  async open() {
    this.ws = new WebSocket(`${API.replace(/^http/, 'ws')}/realtime/v1/websocket?apikey=${PUB}&vsn=${RT_VSN}`);
    await new Promise((res, rej) => { this.ws.onopen = res; this.ws.onerror = rej; });
    this.ws.onmessage = (e) => {
      if (typeof e.data !== 'string') { this.msgs.push({ event: 'binary' }); return; }
      const raw = JSON.parse(e.data);
      const m = Array.isArray(raw) ? { join_ref: raw[0], ref: raw[1], topic: raw[2], event: raw[3], payload: raw[4] } : raw;
      this.msgs.push(m);
      if (m.event === 'phx_reply' && this.waiters.has(m.ref)) { this.waiters.get(m.ref)(m); this.waiters.delete(m.ref); }
    };
    this.hb = setInterval(() => this.push('phoenix', 'heartbeat', {}), 20000);
    return this;
  }
  push(topic, event, payload, joinRef) {
    const ref = String(++this.ref);
    if (event === 'phx_join') joinRef = ref; // Phoenix: join_ref = ref del join
    this.ws.send(JSON.stringify(RT_VSN === '1.0.0' ? { topic, event, payload, ref, join_ref: joinRef } : [joinRef ?? null, ref, topic, event, payload]));
    return ref;
  }
  wait(ref, ms) {
    return new Promise((res) => { this.waiters.set(ref, res); setTimeout(() => res(null), ms); });
  }
  async join(sub, priv) {
    this.topic = `realtime:${sub}`;
    const payload = { config: { broadcast: { ack: true, self: false }, presence: { key: '', enabled: false },
      postgres_changes: [], private: priv } };
    if (this.token) payload.access_token = this.token;
    this.joinRef = this.push(this.topic, 'phx_join', payload);
    const reply = await this.wait(this.joinRef, 5000);
    await sleep(400);
    const err = this.msgs.find((m) => m.topic === this.topic
      && ((m.event === 'system' && m.payload?.status === 'error') || m.event === 'phx_error' || m.event === 'phx_close'));
    return { ok: reply?.payload?.status === 'ok' && !err,
      reason: reply?.payload?.response?.reason ?? err?.payload?.message ?? (reply ? '' : 'sin respuesta') };
  }
  send(event, payload) { this.push(this.topic, 'broadcast', { type: 'broadcast', event, payload }, this.joinRef); }
  got(event, mark) {
    return this.msgs.filter((m) => m.topic === this.topic && m.event === 'broadcast' && m.payload?.event === event
      && (mark === undefined || m.payload?.payload?.mark === mark));
  }
  close() { clearInterval(this.hb); try { this.ws.close(); } catch { /* ya cerrado */ } }
}
const sockets = [];
const rt = async (u) => { const s = await new Rt(u?.token).open(); sockets.push(s); return s; };

// ---------------------------------------------------------------------------------------
const HOME = { lat: -33.4569, lng: -70.5974 }; // Ñuñoa (ficticia)
const PROV = { lat: -33.4314, lng: -70.6093 }; // Providencia (ficticia)
const north = (km) => ({ lat: HOME.lat + km / 111.2, lng: HOME.lng });

sql("select cron.alter_job((select jobid from cron.job where jobname = 'dispatch-urgent-visits'), active := false)");
const openVisits = new Map(); // visit_id → token del dueño (limpieza)

try {
  const legal = {
    terms: (await rpc('current_legal_version', { p_kind: 'terms' })).json,
    privacy: (await rpc('current_legal_version', { p_kind: 'privacy' })).json,
  };
  const O = await newUser('dueno');
  const O2 = await newUser('dueno-2');
  const AD = await newUser('admin');
  const commune = async (name) => (await call(`/rest/v1/communes?select=id&name=eq.${encodeURIComponent(name)}`,
    { token: O.token })).json[0].id;
  const nunoa = await commune('Ñuñoa');
  const providencia = await commune('Providencia');
  const register = (u, role, name, communeId = null, phone = null) => rpc('complete_registration', {
    p_role: role, p_display_name: name, p_phone: phone,
    p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: communeId }, u.token);
  const perro = (await call('/rest/v1/species?select=id&slug=eq.perro', { token: O.token })).json[0].id;
  const gato = (await call('/rest/v1/species?select=id&slug=eq.gato', { token: O.token })).json[0].id;
  const general = (await call('/rest/v1/specialties?select=id&slug=eq.general', { token: O.token })).json[0].id;

  await register(O, 'owner', 'QA Dueña Urgente', nunoa, '+56 9 1212 3434');
  await register(O2, 'owner', 'QA Dueño Dos', nunoa, '+56 9 5656 7878');
  await svc('/rest/v1/user_roles', { user_id: AD.id, role: 'admin' });

  const mkVet = async (tag, species = perro) => {
    const u = await newUser(tag);
    await register(u, 'vet', `QA ${tag}`);
    await svc(`/rest/v1/vet_profiles?user_id=eq.${u.id}`, { status: 'approved' }, 'PATCH');
    await svc('/rest/v1/vet_species', { vet_id: u.id, species_id: species });
    await svc('/rest/v1/vet_specialties', { vet_id: u.id, specialty_id: general });
    return u;
  };
  // N1..N6 a 1–4 km; M5 a 8 km; F6 a 15 km; X7 a 25 km; S8 a 0,5 km con presencia vieja;
  // G9 a 0,5 km solo gatos; L1/L2 a ~5,9 y ~6,1 km (fuga por el pago).
  const dist = { N1: 1, N2: 2, N3: 3, N4: 4, N5: 3.5, N6: 2.5, M5: 8, F6: 15, X7: 25, S8: 0.5, G9: 0.5, L1: 5.85, L2: 6.15 };
  const V = {};
  for (const tag of Object.keys(dist)) V[tag] = await mkVet(tag, tag === 'G9' ? gato : perro);
  const online = async (...tags) => {
    for (const [t, u] of Object.entries(V)) {
      if (tags.includes(t)) await rpc('set_vet_presence', { p_online: true, ...{ p_lat: north(dist[t]).lat, p_lng: north(dist[t]).lng } }, u.token);
      else await rpc('set_vet_presence', { p_online: false }, u.token);
    }
  };
  const name = (id) => Object.entries(V).find(([, u]) => u.id === id)?.[0] ?? id;

  const mkPet = async (u, sp = perro) => (await call('/rest/v1/pets?select=id', { method: 'POST', token: u.token,
    prefer: 'return=representation', body: { owner_id: u.id, name: 'Rayo QA', species_id: sp } })).json[0].id;
  const mkAddr = async (u, communeId, p) => (await call('/rest/v1/addresses?select=id', { method: 'POST', token: u.token,
    prefer: 'return=representation', body: { owner_id: u.id, label: 'Casa', street_text: 'Pasaje Ficticio 456',
      details: 'Casa 2', commune_id: communeId, lat: p.lat, lng: p.lng } })).json[0].id;
  const pet = await mkPet(O);
  const addr = await mkAddr(O, nunoa, HOME);
  const pet2 = await mkPet(O2);
  const addr2 = await mkAddr(O2, nunoa, HOME);
  // Dueños dedicados a las rondas de concurrencia (límite de 60 cotizaciones/h por dueño).
  const mkOwner = async (tag) => { const u = await newUser(tag); await register(u, 'owner', `QA ${tag}`, nunoa);
    return [u, await mkPet(u), await mkAddr(u, nunoa, HOME)]; };
  const OA = await mkOwner('dueno-a');
  const OB = await mkOwner('dueno-b');
  const OC = await mkOwner('dueno-c');

  const request = async (u = O, p = pet, a = addr, extra = {}) => {
    const r = await rpc('request_urgent_visit', { p_pet_id: p, p_address_id: a, ...extra }, u.token);
    if (r.json?.id) openVisits.set(r.json.id, u.token);
    return r;
  };
  const offersOf = (visitId) => sql(`select string_agg(vet_id || ':' || status || ':' || batch || ':' || radius_km, ',' order by batch, distance_m)
    from public.visit_offers where visit_id = '${visitId}'`).split(',').filter(Boolean)
    .map((s) => { const [vet, status, batch, radius] = s.split(':'); return { vet: name(vet), status, batch: +batch, radius: +radius }; });
  const expireBatch = (visitId) => sql(`update public.visit_offers set expires_at = now() - interval '1 second'
    where visit_id = '${visitId}' and status = 'pending'`);
  const dispatch = () => sql('select private.dispatch_urgent_visits()');
  const visitRow = (id) => JSON.parse(sql(`select json_build_object('status', status, 'vet_id', vet_id, 'cancel_fee', cancel_fee,
    'closed_by_system', closed_by_system, 'quote', quote) from public.visits where id = '${id}'`));
  const cancel = (id, u = O) => rpc('transition_visit', { p_visit_id: id, p_to_status: 'cancelled_owner' }, u.token);
  const offerId = (visitId, tag) => sql(`select id from public.visit_offers where visit_id = '${visitId}' and vet_id = '${V[tag].id}'`);

  // Dispositivos push (para revisar el payload al final).
  await rpc('register_push_device', { p_token: `qa-f8-owner-${stamp}`, p_platform: 'android' }, O.token);
  await rpc('register_push_device', { p_token: `qa-f8-n1-${stamp}`, p_platform: 'web' }, V.N1.token);

  // ===================================================================================
  // 1. Tandas, radios y tiempos
  // ===================================================================================
  check(sql("select schedule || '/' || active from cron.job where jobname = 'dispatch-urgent-visits'") === '10 seconds/false',
    'pg_cron dispatch-urgent-visits cada 10 s (pausado por este script)');
  await online('N1', 'N2', 'N3', 'N4', 'M5', 'F6', 'X7', 'S8', 'G9');
  sql(`update public.vet_presence set updated_at = now() - interval '3 minutes' where vet_id = '${V.S8.id}'`);
  const u1 = await request();
  const U1 = u1.json?.id;
  check(u1.status === 200 && u1.json.status === 'searching', 'urgencia U1: buscando');
  check(sql(`select confirm_deadline - created_at = interval '10 minutes' from public.visits where id = '${U1}'`) === 't',
    'búsqueda de 10 min (confirm_deadline = creación + 10 min)');
  let offs = offersOf(U1);
  check(offs.map((o) => o.vet).join(',') === 'N1,N2,N3' && offs.every((o) => o.batch === 1 && o.radius === 5),
    `tanda 1: 3 vets más cercanos a ≤ 5 km, sin presencia vieja ni otra especie (${offs.map((o) => o.vet).join(',')})`);
  check(sql(`select bool_and(expires_at - created_at = interval '60 seconds') from public.visit_offers where visit_id = '${U1}'`) === 't',
    'cada oferta vale 60 s');
  expireBatch(U1); dispatch();
  offs = offersOf(U1).filter((o) => o.batch === 2);
  check(offs.map((o) => `${o.vet}@${o.radius}`).join(',') === 'N4@5', `tanda 2: el que queda en 5 km (${JSON.stringify(offs)})`);
  expireBatch(U1); dispatch();
  offs = offersOf(U1).filter((o) => o.batch === 3);
  check(offs.map((o) => `${o.vet}@${o.radius}`).join(',') === 'M5@10', `tanda 3: radio 10 km (${JSON.stringify(offs)})`);
  expireBatch(U1); dispatch();
  offs = offersOf(U1).filter((o) => o.batch === 4);
  check(offs.map((o) => `${o.vet}@${o.radius}`).join(',') === 'F6@20', `tanda 4: radio 20 km (${JSON.stringify(offs)})`);
  const st1 = (await rpc('urgent_search_status', { p_visit_id: U1 }, O.token)).json;
  check(st1?.batches === 4 && st1?.radius_km === 20 && st1?.pending_offers === 1, `estado para el dueño: tanda 4, 20 km (${JSON.stringify(st1)})`);
  expireBatch(U1); dispatch();
  const all1 = offersOf(U1);
  const r1 = visitRow(U1);
  check(r1.status === 'no_vet_found' && r1.closed_by_system && r1.cancel_fee === 0, `agotado 20 km: no_vet_found, sistema, sin cargo (${r1.status})`);
  check(new Set(all1.map((o) => o.vet)).size === all1.length && !all1.some((o) => ['X7', 'S8', 'G9'].includes(o.vet)),
    `sin repetir vets y nunca X7 (25 km), S8 (vieja) ni G9 (gatos): ${all1.map((o) => o.vet).join(',')}`);
  check(((await call(`/rest/v1/payments?select=id&visit_id=eq.${U1}`, { token: O.token })).json ?? []).length === 0
    && sql(`select count(*) from public.payments where visit_id = '${U1}'`) === '0', 'no_vet_found: 0 pagos');
  check((await rpc('simulate_payment', { p_visit_id: U1 }, O.token)).status === 400, 'no_vet_found: simulate_payment rechazado');
  openVisits.delete(U1);

  // 1b. Rechazos: la siguiente tanda sale de inmediato.
  const u2 = await request();
  const U2 = u2.json.id;
  for (const t of ['N1', 'N2']) await rpc('reject_offer', { p_offer_id: offerId(U2, t) }, V[t].token);
  check(offersOf(U2).filter((o) => o.status === 'pending').map((o) => o.vet).join(',') === 'N3', 'con una oferta aún pendiente no sale otra tanda');
  check((await rpc('reject_offer', { p_offer_id: offerId(U2, 'N1') }, V.N1.token)).status === 400, 'rechazar dos veces: 400');
  await rpc('reject_offer', { p_offer_id: offerId(U2, 'N3') }, V.N3.token);
  check(offersOf(U2).filter((o) => o.status === 'pending').map((o) => o.vet).join(',') === 'N4', 'al rechazar la última, la tanda 2 sale de inmediato');
  const c2 = await cancel(U2);
  check(c2.status === 200 && c2.json.cancel_fee === 0, 'cancelar buscando: gratis');
  check(offersOf(U2).find((o) => o.vet === 'N4')?.status === 'cancelled', 'la oferta pendiente queda cancelada');
  check(((await rpc('my_offers', {}, V.N4.token)).json ?? []).length === 0, 'y desaparece de my_offers');
  openVisits.delete(U2);

  // 1c. Permisos básicos.
  check((await rpc('request_urgent_visit', { p_pet_id: pet, p_address_id: addr }, null)).status === 401, 'anónimo no pide urgencias');
  check((await rpc('request_urgent_visit', { p_pet_id: pet, p_address_id: addr }, V.N1.token)).status === 403, 'un vet no pide urgencias');
  check((await rpc('request_urgent_visit', { p_pet_id: pet, p_address_id: addr }, O2.token)).status >= 400, 'mascota y dirección ajenas: rechazado');
  const [d1, d2] = await Promise.all([request(), request()]);
  check([d1.status, d2.status].sort().join(',') === '200,400', `el mismo dueño pide 2 a la vez: solo 1 (${d1.status}, ${d2.status})`);
  const UD = (d1.status === 200 ? d1 : d2).json.id;
  check((await rpc('accept_offer', { p_offer_id: offerId(UD, 'N1') }, O.token)).status === 403, 'el dueño no acepta ofertas');
  const foreign = await rpc('accept_offer', { p_offer_id: offerId(UD, 'N1') }, V.N2.token);
  const ghost = await rpc('accept_offer', { p_offer_id: crypto.randomUUID() }, V.N2.token);
  check(foreign.status === 400 && foreign.json?.message === ghost.json?.message, `oferta ajena = inexistente (${foreign.json?.message})`);
  await cancel(UD); openVisits.delete(UD);

  // ===================================================================================
  // 2. Concurrencia
  // ===================================================================================
  // 2a. 6 vets aceptan a la vez, 8 rondas (3 ofertas del despacho + 3 insertadas por SQL).
  await online('N1', 'N2', 'N3', 'N4', 'N5', 'N6');
  let raceOk = 0;
  const finalQuotes0 = +sql(`select count(*) from public.quotes where owner_id = '${OA[0].id}' and mode = 'urgent' and vet_id is not null`);
  for (let i = 0; i < 8; i++) {
    const r = await request(...OA);
    const id = r.json.id;
    const have = offersOf(id).map((o) => o.vet);
    for (const t of ['N1', 'N2', 'N3', 'N4', 'N5', 'N6'].filter((x) => !have.includes(x))) {
      sql(`insert into public.visit_offers (visit_id, vet_id, batch, radius_km, distance_m, expires_at)
           values ('${id}', '${V[t].id}', 1, 5, 4000, now() + interval '60 seconds')`);
    }
    const tags = ['N1', 'N2', 'N3', 'N4', 'N5', 'N6'];
    const ids = tags.map((t) => offerId(id, t));
    const res = await Promise.all(tags.map((t, k) => rpc('accept_offer', { p_offer_id: ids[k] }, V[t].token)));
    const winners = res.map((x, k) => [x, tags[k]]).filter(([x]) => x.status === 200);
    const losersOk = res.filter((x) => x.status !== 200).every((x) => x.status === 400 && x.json?.hint === 'offer_taken');
    const row = visitRow(id);
    const os = offersOf(id);
    if (winners.length === 1 && losersOk && name(row.vet_id) === winners[0][1] && row.status === 'accepted'
      && os.filter((o) => o.status === 'accepted').length === 1 && os.filter((o) => o.status === 'lost').length === 5) raceOk++;
    else info(`ronda ${i}: ${res.map((x) => x.status + (x.json?.hint ? '/' + x.json.hint : '')).join(' ')} → ${row.status} ${name(row.vet_id)}`);
    await cancel(id, OA[0]); openVisits.delete(id);
  }
  const finalQuotes1 = +sql(`select count(*) from public.quotes where owner_id = '${OA[0].id}' and mode = 'urgent' and vet_id is not null`);
  check(raceOk === 8, `6 vets aceptan a la vez × 8 rondas: siempre 1 ganador, 5 "ya tomada" y ofertas 1 accepted / 5 lost (${raceOk}/8)`);
  check(finalQuotes1 - finalQuotes0 === 8, `una sola cotización final por visita (${finalQuotes1 - finalQuotes0} en 8 rondas)`);

  // 2b. Aceptar justo cuando vence la oferta, con el despacho corriendo a la vez.
  await online('N1');
  const tally = { accepted: 0, expired: 0, other: 0, bad: 0 };
  for (let i = 0; i < 10; i++) {
    const id = (await request(...OB)).json.id;
    sql(`update public.visit_offers set expires_at = now() + interval '700 milliseconds' where visit_id = '${id}'`);
    const oid = offerId(id, 'N1');
    const jitter = 450 + Math.floor(Math.random() * 400);
    const [acc] = await Promise.all([
      sleep(jitter).then(() => rpc('accept_offer', { p_offer_id: oid }, V.N1.token)),
      sleep(650).then(() => sqlAsync('select private.dispatch_urgent_visits()')),
    ]);
    dispatch(); // el despacho paralelo pudo saltarse la visita (skip locked)
    const row = visitRow(id);
    const os = offersOf(id)[0];
    if (acc.status === 200) tally.accepted++; else if (['offer_expired', 'offer_closed'].includes(acc.json?.hint)) tally.expired++; else tally.other++;
    const consistent = acc.status === 200
      ? row.status === 'accepted' && name(row.vet_id) === 'N1' && os.status === 'accepted'
      : row.vet_id === null && os.status === 'expired' && ['searching', 'no_vet_found'].includes(row.status);
    if (!consistent) { tally.bad++; info(`vencimiento ${i}: ${acc.status} ${acc.json?.hint} → ${row.status} oferta ${os.status}`); }
    if (['searching', 'accepted'].includes(row.status)) await cancel(id, OB[0]);
    openVisits.delete(id);
  }
  check(tally.bad === 0 && tally.other === 0,
    `aceptar vs vencimiento (60 s) con despacho en paralelo × 10: estados coherentes (aceptadas ${tally.accepted}, vencidas ${tally.expired})`);

  // 2c. Aceptar vs cancelación del dueño, 10 rondas.
  let cancelOk = 0;
  const outcomes = {};
  for (let i = 0; i < 10; i++) {
    const id = (await request(...OC)).json.id;
    const oid = offerId(id, 'N1');
    const [acc, can] = await Promise.all([
      sleep(i % 2 ? 40 + Math.random() * 20 : Math.random() * 10).then(() => rpc('accept_offer', { p_offer_id: oid }, V.N1.token)),
      sleep(i % 2 ? Math.random() * 10 : 40 + Math.random() * 20).then(() => cancel(id, OC[0])),
    ]);
    const row = visitRow(id);
    const os = offersOf(id)[0];
    const key = `${acc.status}/${can.status}`;
    outcomes[key] = (outcomes[key] ?? 0) + 1;
    const fine = row.status === 'cancelled_owner' && row.cancel_fee === 0 && can.status === 200
      && (acc.status === 200 ? os.status === 'accepted' && name(row.vet_id) === 'N1'
        : acc.json?.hint === 'offer_closed' && row.vet_id === null && os.status === 'cancelled')
      && sql(`select count(*) from public.payments where visit_id = '${id}'`) === '0';
    if (fine) cancelOk++; else info(`cancelar ${i}: ${key} ${acc.json?.hint} → ${row.status} ${row.cancel_fee} oferta ${os.status}`);
    openVisits.delete(id);
  }
  check(cancelOk === 10, `aceptar vs cancelar × 10: siempre cancelled_owner sin cargo y oferta coherente (${JSON.stringify(outcomes)})`);

  // 2d. Dos dueños piden a la vez con un solo vet libre: ¿doble oferta al mismo vet?
  let doubles = 0;
  let blocked = 0;
  for (let i = 0; i < 6; i++) {
    const [a, b] = await Promise.all([request(O, pet, addr), request(O2, pet2, addr2)]);
    const pend = +sql(`select count(*) from public.visit_offers where vet_id = '${V.N1.id}' and status = 'pending'`);
    if (pend === 2) {
      doubles++;
      const acc = await rpc('accept_offer', { p_offer_id: offerId(a.json.id, 'N1') }, V.N1.token);
      if (acc.status !== 200) { blocked++; info(`doble oferta ${i}: aceptar → ${acc.status} "${acc.json?.message}"`); }
    }
    for (const [v, u] of [[a, O], [b, O2]]) {
      if (['searching', 'accepted'].includes(visitRow(v.json.id).status)) await cancel(v.json.id, u);
      openVisits.delete(v.json.id);
    }
  }
  info(`solicitudes simultáneas con 1 vet: doble oferta en ${doubles}/6 rondas, vet bloqueado en ${blocked}`);
  check(blocked === 0, `con dos ofertas simultáneas el vet aún puede aceptar una (${blocked} bloqueos en ${doubles} dobles)`, 'QA-F8-02');

  // ===================================================================================
  // 3. Precio
  // ===================================================================================
  await online('M5');
  const p1 = await request(O, pet, addr, { p_extra_donation: 1000 });
  const P1 = p1.json.id;
  const q0 = p1.json.quote;
  check(q0?.urgent_surcharge === 8097 && q0?.max_total === 26990 + 8097 + 7500 + 1000 && q0?.distance_km == null
    && q0?.max_distance_km === 20, `al pedir: recargo 30 % y "hasta" ${q0?.max_total} (tope a 20 km, + donación)`);
  const cfgReq = sql(`select (select pricing_config_id from public.quotes where id = v.quote_id) from public.visits v where id = '${P1}'`);
  // El admin publica otra versión ANTES de que el vet acepte.
  const newCfg = await call('/rest/v1/pricing_config', { method: 'POST', token: AD.token, body: {
    commission_pct: 20, foundation_pct: 50, urgent_pct: 40, per_km: 900, free_km: 2, cancel_fee: 7000,
    created_by: AD.id, effective_from: new Date(Date.now() - 1000).toISOString() } });
  check(newCfg.status === 201, 'el admin publica una nueva versión de pricing_config durante la búsqueda');
  const offM = (await rpc('my_offers', {}, V.M5.token)).json?.[0];
  const dM = +sql(`select distance_m from public.visit_offers where visit_id = '${P1}'`);
  const billable = Math.max(0, Math.ceil((dM - 5000) / 1000));
  const acc = await rpc('accept_offer', { p_offer_id: offM.offer_id }, V.M5.token);
  const qf = visitRow(P1).quote;
  const cfgFinal = sql(`select pricing_config_id from public.quotes where id = (select quote_id from public.visits where id = '${P1}')`);
  check(acc.status === 200 && cfgFinal === cfgReq, `la cotización final usa la MISMA versión (${cfgReq} → ${cfgFinal})`);
  check(qf.billable_km === billable && qf.total === 26990 + 8097 + 500 * billable + 1000 && qf.total <= q0.max_total,
    `precio final con la distancia de la oferta: ${billable} km × $500 → ${qf.total} ≤ ${q0.max_total}`);
  check(offM.vet_payout === qf.vet_payout && offM.service_price === qf.service_price, 'lo que vio el vet en la oferta = cotización final');
  check(qf.request_quote_id && !('distance_m' in qf), 'visits.quote guarda request_quote_id y no la distancia exacta');
  await rpc('transition_visit', { p_visit_id: P1, p_to_status: 'en_route' }, V.M5.token);
  const cEn = await cancel(P1);
  const fee = (await call(`/rest/v1/payments?select=kind,total&visit_id=eq.${P1}`, { token: O.token })).json ?? [];
  check(cEn.status === 200 && cEn.json.cancel_fee === 5000 && fee.length === 1 && fee[0].kind === 'cancel_fee' && fee[0].total === 5000,
    `cancelar en camino: $5.000 de la versión congelada, no los $7.000 nuevos (${JSON.stringify(fee)})`);
  openVisits.delete(P1);
  // Restaura los valores por defecto (como precios_e2e).
  await call('/rest/v1/pricing_config', { method: 'POST', token: AD.token, body: {
    commission_pct: 15, foundation_pct: 20, urgent_pct: 30, per_km: 500, free_km: 5, cancel_fee: 5000,
    created_by: AD.id, effective_from: new Date(Date.now() - 1000).toISOString() } });
  // Gratis con el vet asignado pero antes de "en camino".
  const p2 = await request();
  await rpc('accept_offer', { p_offer_id: offerId(p2.json.id, 'M5') }, V.M5.token);
  const cAcc = await cancel(p2.json.id);
  check(cAcc.json?.cancel_fee === 0 && sql(`select count(*) from public.payments where visit_id = '${p2.json.id}'`) === '0',
    'cancelar aceptada (antes de en camino): gratis');
  openVisits.delete(p2.json.id);

  // ===================================================================================
  // 4. Privacidad
  // ===================================================================================
  await online('L1', 'L2');
  const pv = await request();
  const PV = pv.json.id;
  const oL1 = (await rpc('my_offers', {}, V.L1.token)).json?.[0];
  const oL2 = (await rpc('my_offers', {}, V.L2.token)).json?.[0];
  check(Object.keys(oL1 ?? {}).sort().join(',') ===
    'batch,commune_name,created_at,distance_km,expires_at,offer_id,service_price,specialty_name,species_name,vet_payout,visit_id'
    && !JSON.stringify(oL1).match(/Pasaje|Rayo|lat|lng/), 'la oferta: solo comuna, distancia, especie, especialidad y montos');
  const dL = sql(`select string_agg(distance_m::text, ',' order by distance_m) from public.visit_offers where visit_id = '${PV}'`);
  info(`L1/L2: distance_km ${oL1?.distance_km} / ${oL2?.distance_km}; distance_m reales ${dL}; vet_payout ${oL1?.vet_payout} / ${oL2?.vet_payout}`);
  check(!(oL1?.distance_km === oL2?.distance_km && oL1?.vet_payout !== oL2?.vet_payout),
    `con la misma distancia a 0,5 km (${oL1?.distance_km}), el pago estimado no revela más precisión (${oL1?.vet_payout} vs ${oL2?.vet_payout})`, 'QA-F8-03');
  await cancel(PV); openVisits.delete(PV);

  const latlng = sql(`select bool_and(abs(extensions.st_y(location::extensions.geometry) * 1000 - round(extensions.st_y(location::extensions.geometry) * 1000)) < 1e-6)
    from public.vet_presence where online and vet_id in (${Object.values(V).map((u) => `'${u.id}'`).join(',')})`);
  check(latlng === 't', 'vet_presence guarda la posición redondeada a 3 decimales');
  for (const [who, u] of [['vet', V.L1], ['dueño', O], ['admin', AD], ['anónimo', null]]) {
    const a = await call('/rest/v1/vet_presence?select=location', { token: u?.token });
    const b = await call('/rest/v1/vet_presence?select=*', { token: u?.token });
    const c = await call('/rest/v1/visit_offers?select=distance_m', { token: u?.token });
    const d = await call('/rest/v1/visit_offers?select=*', { token: u?.token });
    check(a.status >= 400 && b.status >= 400 && c.status >= 400 && d.status >= 400,
      `${who}: vet_presence.location y visit_offers.distance_m no se leen por REST (${a.status}/${b.status}/${c.status}/${d.status})`);
    const g = await call('/graphql/v1', { method: 'POST', token: u?.token, body: {
      query: '{ vetPresenceCollection { edges { node { location } } } visitOffersCollection { edges { node { distanceM } } } }' } });
    check(!JSON.stringify(g.json).match(/"location":"|"distanceM":\d/), `${who}: tampoco por GraphQL (HTTP ${g.status})`);
  }
  const qOwn = await call('/rest/v1/quotes?select=distance_m&limit=1', { token: O.token });
  check(qOwn.status >= 400, `quotes.distance_m no se lee (HTTP ${qOwn.status})`);
  check((await call('/rest/v1/push_outbox?select=*', { token: O.token })).status >= 400
    && (await rpc('claim_push_batch', { p_limit: 5 }, O.token)).status >= 400
    && (await rpc('drop_push_tokens', { p_tokens: ['x'] }, O.token)).status >= 400, 'cola push y RPC de servicio: cerradas al usuario');
  check((await call('/functions/v1/send-push', { method: 'POST', body: {} })).status === 403, 'send-push con la clave pública: 403');

  // urgent_search_status: ajena, inexistente, agendada propia y como vet (¿fuga por mensaje o tiempo?).
  const su = await request();
  const SU = su.json.id;
  const t = { mine: [], foreign: [], ghost: [] };
  for (let i = 0; i < 25; i++) {
    for (const [k, id, u] of [['mine', SU, O], ['foreign', SU, O2], ['ghost', crypto.randomUUID(), O2]]) {
      const t0 = performance.now();
      const r = await rpc('urgent_search_status', { p_visit_id: id }, u.token);
      t[k].push(performance.now() - t0);
      if (i === 0) t[k + 'Res'] = `${r.status} ${JSON.stringify(r.json)}`;
    }
  }
  check(t.foreignRes === t.ghostRes && t.foreignRes === '200 null', `estado ajeno = inexistente (${t.foreignRes})`);
  check((await rpc('urgent_search_status', { p_visit_id: SU }, V.N1.token)).json === null, 'un vet tampoco lee el estado');
  check(Math.abs(median(t.foreign) - median(t.ghost)) < 3,
    `sin diferencia de tiempo útil: ajena ${median(t.foreign).toFixed(1)} ms vs inexistente ${median(t.ghost).toFixed(1)} ms (propia ${median(t.mine).toFixed(1)} ms)`);
  await cancel(SU); openVisits.delete(SU);

  // ===================================================================================
  // 5. Realtime privado visit:{id} con WebSocket real
  // ===================================================================================
  await online('N1', 'N2');
  // R2: visita de O2 con N2 en camino (vet y dueño "de otra visita").
  const r2 = await request(O2, pet2, addr2);
  const R2 = r2.json.id;
  const offR2 = (await rpc('my_offers', {}, V.N2.token)).json.find((o) => o.visit_id === R2);
  // R2 se ofrece a N1 y N2: acepta N2.
  await rpc('accept_offer', { p_offer_id: offR2.offer_id }, V.N2.token);
  await rpc('transition_visit', { p_visit_id: R2, p_to_status: 'en_route' }, V.N2.token);
  const rr = await request();
  const R = rr.json.id;
  await rpc('accept_offer', { p_offer_id: offerId(R, 'N1') }, V.N1.token);
  const topic = `visit:${R}`;
  const early = await (await rt(O)).join(topic, true);
  check(!early.ok, `con la visita aceptada (aún no en camino) el dueño no se une (${early.reason})`);
  await rpc('transition_visit', { p_visit_id: R, p_to_status: 'en_route' }, V.N1.token);

  const sOwner = await rt(O); const jOwner = await sOwner.join(topic, true);
  const sVet = await rt(V.N1); const jVet = await sVet.join(topic, true);
  check(jOwner.ok && jVet.ok, `en camino: el dueño y el vet asignado se unen (${jOwner.reason}|${jVet.reason})`);
  const intruders = [['tercero (otro dueño)', O2], ['vet de otra visita', V.N2], ['vet sin visita', V.N3], ['admin', AD], ['anónimo', null]];
  const priv = [];
  for (const [who, u] of intruders) {
    const s = await rt(u);
    const j = await s.join(topic, true);
    priv.push([who, s]);
    check(!j.ok, `${who}: no se une al canal privado (${j.reason})`);
  }
  // Canal público con el mismo nombre (private: false).
  const pub = [];
  for (const [who, u] of [['tercero', O2], ['anónimo', null]]) {
    const s = await rt(u);
    const j = await s.join(topic, false);
    pub.push([who, s]);
    info(`${who}: unión al canal PÚBLICO ${topic} → ${j.ok ? 'aceptada' : 'rechazada'} ${j.reason}`);
  }
  await sleep(500);
  sVet.send('location', { lat: -33.45, lng: -70.6, at: new Date().toISOString(), mark: 'v1' });
  sOwner.send('location', { lat: -33.0, lng: -70.0, at: new Date().toISOString(), mark: 'o1' });
  const vetTok = V.N1.token;
  const restPub = (token, mark, privFlag = true) => fetch(`${API}/realtime/v1/api/broadcast`, { method: 'POST',
    headers: { apikey: PUB, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ messages: [{ topic, event: 'location', private: privFlag, payload: { lat: -33.1, lng: -70.1, mark } }] }) })
    .then((r) => r.status);
  const restO2 = await restPub(O2.token, 'x1');
  const restOwner = await restPub(O.token, 'o2');
  const restVet = await restPub(vetTok, 'v2');
  await sleep(1500);
  if (sOwner.got('location', 'v1').length !== 1) info('vet WS: ' + JSON.stringify(sVet.msgs.filter((m) => m.event !== 'presence_state').slice(-4)));
  check(sOwner.got('location', 'v1').length === 1, 'el dueño recibe la posición del vet (WebSocket)');
  check(sOwner.got('location', 'v2').length === 1, `y la que el vet manda por la API REST de broadcast (HTTP ${restVet})`);
  check(sVet.got('location', 'o1').length === 0 && sVet.got('location', 'o2').length === 0,
    `solo envía el vet: lo que manda el dueño no llega (REST ${restOwner})`);
  check(sOwner.got('location', 'x1').length === 0 && sVet.got('location', 'x1').length === 0, `un tercero no inyecta por REST (HTTP ${restO2})`);
  const leaked = [...priv, ...pub].filter(([, s]) => s.got('location').length > 0).map(([w]) => w);
  check(leaked.length === 0, `nadie más recibe (ni en el canal público homónimo): ${leaked.join(', ') || 'ninguno'}`);

  // Sale de en_route con el canal abierto.
  await rpc('transition_visit', { p_visit_id: R, p_to_status: 'arrived' }, V.N1.token);
  await sleep(300);
  sVet.send('location', { lat: -33.45, lng: -70.6, at: new Date().toISOString(), mark: 'after' });
  const restAfter = await restPub(vetTok, 'after-rest');
  await sleep(1500);
  const keepWs = sOwner.got('location', 'after').length;
  const keepRest = sOwner.got('location', 'after-rest').length;
  info(`tras "llegó" con el canal abierto: el dueño recibe por WebSocket ${keepWs}, por REST ${keepRest} (HTTP ${restAfter})`);
  const late = await (await rt(O)).join(topic, true);
  check(!late.ok, `tras "llegó", un nuevo join se rechaza (${late.reason})`);
  check(keepRest === 0, 'tras "llegó", la API REST ya no publica en el canal');
  for (const s of sockets) s.close();
  await rpc('transition_visit', { p_visit_id: R, p_to_status: 'cancelled_vet' }, V.N1.token);
  await rpc('transition_visit', { p_visit_id: R2, p_to_status: 'cancelled_vet' }, V.N2.token);
  openVisits.delete(R); openVisits.delete(R2);

  // ===================================================================================
  // 6. Observaciones del Dev App: dirección para "Agendar primera hora libre"
  // ===================================================================================
  await online();
  const addrProv = await mkAddr(O, providencia, PROV); // misma etiqueta y calle, otra comuna
  const nv = await request(O, pet, addrProv);
  const view = ((await rpc('my_visits', {}, O.token)).json ?? []).find((v) => v.id === nv.json.id);
  const mine = (await call(`/rest/v1/addresses?select=id,label,street_text,active&owner_id=eq.${O.id}`, { token: O.token })).json;
  const matches = mine.filter((a) => a.active && a.label === view?.address_label && a.street_text === view?.address_text);
  info(`no_vet_found en Providencia: my_visits trae address_id=${'address_id' in (view ?? {})}, ${matches.length} direcciones coinciden por etiqueta y calle; la primera es ${matches[0]?.id === addrProv ? 'la correcta' : 'la de Ñuñoa'}`);
  check(view?.status === 'no_vet_found', 'sin vets en línea: no_vet_found de inmediato');
  check('address_id' in (view ?? {}) || matches.length === 1,
    'la app puede identificar la dirección de la urgencia para "Agendar primera hora libre"', 'QA-F8-04');
  openVisits.delete(nv.json.id);

  // ===================================================================================
  // 7. Push (fake): solo visit_id + evento
  // ===================================================================================
  const push = await call('/functions/v1/send-push', { method: 'POST', key: SRV, token: SRV, body: {} });
  const del = push.json?.delivered ?? [];
  const evs = [...new Set(del.map((d) => d.data?.event))].sort();
  check(push.status === 200 && del.length > 0 && del.every((d) => Object.keys(d.data).sort().join(',') === 'event,visit_id'),
    `send-push (fake): ${del.length} avisos, todos con solo visit_id + evento (${evs.join(', ')})`);
  check(!JSON.stringify(push.json).match(/qa-f8-|Pasaje|Rayo|Ñuñoa/), 'la respuesta no trae tokens ni datos personales');

  // ===================================================================================
  // 8. pg_cron real cada 10 s
  // ===================================================================================
  await online('N1');
  const cr = await request();
  const CR = cr.json.id;
  timeTravel(sql, `update public.visits set confirm_deadline = now() - interval '1 second' where id = '${CR}'`);
  sql("select cron.alter_job((select jobid from cron.job where jobname = 'dispatch-urgent-visits'), active := true)");
  const t0 = Date.now();
  let closed = false;
  while (Date.now() - t0 < 30000 && !closed) { await sleep(1000); closed = visitRow(CR).status === 'no_vet_found'; }
  check(closed, `el job reactivado cierra la búsqueda vencida en ${((Date.now() - t0) / 1000).toFixed(0)} s (≤ 10 s + margen)`);
  openVisits.delete(CR);
} finally {
  sql("select cron.alter_job((select jobid from cron.job where jobname = 'dispatch-urgent-visits'), active := true)");
  for (const s of sockets) s.close();
  for (const [id, token] of openVisits) {
    try {
      const s = visitRow(id).status;
      if (['searching', 'accepted', 'en_route'].includes(s)) await rpc('transition_visit', { p_visit_id: id, p_to_status: 'cancelled_owner' }, token);
    } catch { /* limpieza */ }
  }
  for (const id of created) await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
}

console.log(fails === 0 && defects === 0 ? '\nQA fase 8: TODO OK'
  : `\nQA fase 8: ${fails} fallas, ${defects} defectos conocidos`);
process.exit(fails ? 1 : defects ? 2 : 0);
