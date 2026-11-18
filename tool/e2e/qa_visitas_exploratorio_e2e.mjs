// QA exploratorio de la fase 6 (visitas agendadas) contra Supabase local:
// Auth + REST, y SQL directo (docker exec) solo para simular el paso del
// tiempo. Complementa visitas_e2e.mjs con la matriz de transiciones por rol,
// carreras, bordes de la reserva, privacidad por estado, cargo con la
// configuración congelada y los trabajos programados.
//
// Uso: node tool/e2e/qa_visitas_exploratorio_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
//
// Convención: OK / FALLA (código 1) / DEFECTO <id> (código 2, documentado en
// docs/qa/; pasa a OK solo cuando se corrige). Correr DESPUÉS de
// `supabase test db`: publica versiones de pricing_config.
// Solo crea usuarios *@test.local y los borra al final.
import { sqlRunner } from './sql.mjs';

const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;
const sql = sqlRunner(st);

let fails = 0;
let defects = 0;
const check = (cond, msg) => { console.log(`${cond ? 'OK     ' : 'FALLA  '} ${msg}`); if (!cond) fails++; };
const known = (cond, id, msg) => { console.log(`${cond ? 'OK     ' : `DEFECTO ${id}`} ${msg}`); if (!cond) defects++; };

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
const rest = (p, o) => call(`/rest/v1/${p}`, o);
const rpc = (name, body, token) => call(`/rest/v1/rpc/${name}`, { method: 'POST', token, body });
const srv = { key: SRV, token: SRV };

const stamp = Date.now();
const created = [];
async function newUser(tag) {
  const email = `qa-f6-${tag}-${stamp}@test.local`;
  const c = await call('/auth/v1/admin/users', { method: 'POST', ...srv, body: { email, password: 'Felix2026', email_confirm: true } });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status}`);
  created.push(c.json.id);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password: 'Felix2026' } });
  return { token: s.json.access_token, id: c.json.id, tag };
}
const legal = {
  terms: (await rpc('current_legal_version', { p_kind: 'terms' })).json,
  privacy: (await rpc('current_legal_version', { p_kind: 'privacy' })).json,
};
const register = (u, role, commune = null, phone = null) => rpc('complete_registration', {
  p_role: role, p_display_name: `QA ${u.tag}`, p_phone: phone,
  p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: commune }, u.token);
const cAt = async (lat, lng, tok) => (await rpc('communes_at_point', { p_lat: lat, p_lng: lng }, tok)).json[0].commune_id;
const chile = (d) => d.toLocaleDateString('en-CA', { timeZone: 'America/Santiago' });
const tomorrow = chile(new Date(Date.now() + 24 * 3600 * 1000));
const dayAfter = chile(new Date(Date.now() + 48 * 3600 * 1000));
const shift = (id, expr) => sql(`update public.visits set scheduled_at = ${expr},
  slot = tstzrange(${expr}, ${expr} + interval '90 minutes') where id = '${id}'`);

try {
  const general = (await rest('specialties?select=id&slug=eq.general', srv)).json[0].id;
  const perro = (await rest('species?select=id&slug=eq.perro', srv)).json[0].id;
  const users = await Promise.all(['a', 'b', 'c', 'd', 'v', 'w', 'pend', 'nobase', 'far', 'admin', 'fund'].map(newUser));
  const [a, b, c, d, V, W, pend, nobase, far, admin, fund] = users;
  await rest('user_roles', { method: 'POST', ...srv, body: { user_id: admin.id, role: 'admin' } });
  await rest('user_roles', { method: 'POST', ...srv, body: { user_id: fund.id, role: 'foundation' } });
  const fDemo = (await rest('foundations?select=id&is_default=is.true', srv)).json[0].id;
  await rest('foundation_members', { method: 'POST', token: admin.token, body: { user_id: fund.id, foundation_id: fDemo } });

  const nunoa = await cAt(-33.4569, -70.5974, a.token);
  for (const o of [a, b, c, d]) await register(o, 'owner', nunoa, '+56 9 2222 3333');
  for (const v of [V, W, pend, nobase, far]) await register(v, 'vet');
  for (const v of [V, W, nobase, far]) await rest(`vet_profiles?user_id=eq.${v.id}`, { method: 'PATCH', ...srv, body: { status: 'approved' } });
  for (const v of [V, W, pend, nobase, far]) {
    await rest('vet_species', { method: 'POST', ...srv, body: { vet_id: v.id, species_id: perro } });
    await rest('vet_specialties', { method: 'POST', ...srv, body: { vet_id: v.id, specialty_id: general } });
    await rest('vet_availability', { method: 'POST', ...srv, body: [1, 2, 3, 4, 5, 6, 7].map((x) => ({ vet_id: v.id, weekday: x, start_min: 0, end_min: 1440 })) });
  }
  for (const v of [V, W, pend]) {
    await rest('vet_bases', { method: 'POST', token: v.token, body: { vet_id: v.id, commune_id: await cAt(-33.42, -70.58, v.token), lat: -33.42, lng: -70.58 } });
  }
  // Base de "far" en Valparaíso (~100 km).
  await rest('vet_bases', { method: 'POST', token: far.token, body: { vet_id: far.id, commune_id: await cAt(-33.0458, -71.6197, far.token), lat: -33.0458, lng: -71.6197 } });

  const pets = {}; const addrs = {};
  for (const o of [a, b, c, d]) {
    pets[o.tag] = (await rest('pets?select=id', { method: 'POST', token: o.token, prefer: 'return=representation', body: { owner_id: o.id, name: `QA ${o.tag}`, species_id: perro } })).json[0].id;
    addrs[o.tag] = (await rest('addresses?select=id', { method: 'POST', token: o.token, prefer: 'return=representation',
      body: { owner_id: o.id, label: 'Casa', street_text: `Calle Secreta ${o.tag} 742`, details: 'Depto 9', commune_id: nunoa, lat: -33.4569, lng: -70.5974 } })).json[0].id;
  }
  const quote = async (o, vet, extra = {}) => (await rpc('quote_visit', { p_pet_id: pets[o.tag], p_address_id: addrs[o.tag],
    p_specialty_id: general, p_mode: 'scheduled', p_vet_id: vet?.id ?? null, ...extra }, o.token));
  const book = (o, q, vet, when, extra = {}) => rpc('book_visit', { p_quote_id: q.quote_id, p_vet_id: vet.id,
    p_pet_id: pets[o.tag], p_address_id: addrs[o.tag], p_scheduled_at: when, ...extra }, o.token);
  const tr = (id, to, tok, reason = null) => rpc('transition_visit', { p_visit_id: id, p_to_status: to, p_reason: reason }, tok);
  const mv = async (id, tok) => ((await rpc('my_visits', { p_limit: 200 }, tok)).json ?? []).find((x) => x.id === id);
  const slotsOf = async (o, vet, date = tomorrow) => ((await rpc('available_vets', { p_pet_id: pets[o.tag], p_address_id: addrs[o.tag],
    p_specialty_id: general, p_date: date }, o.token)).json ?? []).find((x) => x.vet_id === vet.id)?.slots ?? [];
  const days = [1, 2, 3, 4, 5, 6].map((n) => chile(new Date(Date.now() + n * 24 * 3600 * 1000)));
  const slotsV = [];
  for (const dd of days) slotsV.push(...await slotsOf(a, V, dd));
  const slotsW = await slotsOf(a, W);
  check(slotsV.length >= 30 && slotsW.length >= 30, `V y W ofrecen horarios mañana (${slotsV.length}/${slotsW.length})`);
  let iV = 0; let iW = 0;
  const nextV = () => { const s = slotsV[iV]; iV += 3; return s; };
  const nextW = () => { const s = slotsW[iW]; iW += 4; return s; };
  const newVisit = async (o, vet = V) => {
    const q = (await quote(o, vet)).json;
    const r = await book(o, q, vet, vet === V ? nextV() : nextW());
    if (r.status !== 200) throw new Error(`book ${o.tag}: ${r.status} ${JSON.stringify(r.json)}`);
    return r.json.id;
  };

  // ==== 1. Máquina de estados ==========================================================
  const v1 = await newVisit(a);
  const all = ['searching', 'pending_vet', 'accepted', 'en_route', 'arrived', 'in_progress', 'completed', 'rejected',
    'expired', 'no_vet_found', 'cancelled_owner', 'cancelled_vet', 'foo', ''];
  // Desde pending_vet: dueño solo cancelled_owner; vet solo accepted/rejected.
  const okOwner = new Set(['cancelled_owner']); const okVet = new Set(['accepted', 'rejected']);
  let badOwner = 0; let badVet = 0; let badW = 0; let badAdmin = 0;
  for (const to of all) {
    if (!okOwner.has(to) && (await tr(v1, to, a.token)).status < 400) badOwner++;
    if (!okVet.has(to) && (await tr(v1, to, V.token)).status < 400) badVet++;
    if ((await tr(v1, to, W.token)).status < 400) badW++;
    if ((await tr(v1, to, admin.token)).status < 400) badAdmin++;
  }
  check(badOwner + badVet + badW + badAdmin === 0, `pending_vet: 0 transiciones inválidas aceptadas (dueño ${badOwner}, vet ${badVet}, otro vet ${badW}, admin ${badAdmin}; ${all.length} destinos)`);
  check((await tr(v1, 'accepted', fund.token)).status >= 400 && (await tr(v1, 'accepted', b.token)).status >= 400
    && (await tr(v1, 'accepted', undefined)).status === 401, 'fundación, otro dueño y anónimo no transicionan');
  const st1 = (await rest(`visits?select=status&id=eq.${v1}`, { token: a.token })).json[0].status;
  check(st1 === 'pending_vet', `tras el barrido la visita sigue en pending_vet (${st1})`);

  // Escritura directa.
  const direct = [
    ['PATCH visits.status (dueño)', rest(`visits?id=eq.${v1}`, { method: 'PATCH', token: a.token, body: { status: 'cancelled_owner' } })],
    ['PATCH visits.status (vet)', rest(`visits?id=eq.${v1}`, { method: 'PATCH', token: V.token, body: { status: 'completed' } })],
    ['PATCH visits.scheduled_at (vet)', rest(`visits?id=eq.${v1}`, { method: 'PATCH', token: V.token, body: { scheduled_at: new Date().toISOString() } })],
    ['PATCH visits (admin)', rest(`visits?id=eq.${v1}`, { method: 'PATCH', token: admin.token, body: { status: 'completed' } })],
    ['DELETE visits (dueño)', rest(`visits?id=eq.${v1}`, { method: 'DELETE', token: a.token })],
    ['INSERT visit_events (vet)', rest('visit_events', { method: 'POST', token: V.token, body: { visit_id: v1, to_status: 'completed' } })],
    ['PATCH visit_events (admin)', rest(`visit_events?visit_id=eq.${v1}`, { method: 'PATCH', token: admin.token, body: { to_status: 'completed' } })],
    ['DELETE visit_events (admin)', rest(`visit_events?visit_id=eq.${v1}`, { method: 'DELETE', token: admin.token })],
  ];
  for (const [msg, p] of direct) { const r = await p; check(r.status === 403, `${msg} rechazado (HTTP ${r.status})`); }
  // Ni postgres sin la marca de transición puede cambiar el estado.
  let pgBlocked = false;
  try { sql(`update public.visits set status = 'completed' where id = '${v1}'`); } catch (e) { pgBlocked = /transition_visit/.test(String(e.stderr ?? e)); }
  check(pgBlocked, 'un UPDATE de estado como postgres (sin transition_visit) también se rechaza');

  // Carrera: confirmar dos veces.
  const v2 = await newVisit(b);
  const twice = await Promise.all([tr(v2, 'accepted', V.token), tr(v2, 'accepted', V.token), tr(v2, 'rejected', V.token)]);
  const ev2 = sql(`select string_agg(coalesce(from_status,'-')||'>'||to_status, ',' order by id) from public.visit_events where visit_id = '${v2}'`);
  check(twice.filter((r) => r.status === 200).length === 1 && ev2.split(',').length === 2,
    `confirmar×2 + rechazar en paralelo: 1 gana (${twice.map((r) => r.status).join(',')}; eventos ${ev2})`);
  // Carrera: dueño cancela mientras el vet confirma (más de 2 h antes → gratis).
  const v3 = await newVisit(c);
  const cr = await Promise.all([tr(v3, 'cancelled_owner', c.token), tr(v3, 'accepted', V.token)]);
  const v3s = await mv(v3, c.token);
  const ev3 = sql(`select string_agg(coalesce(from_status,'-')||'>'||to_status, ',' order by id) from public.visit_events where visit_id = '${v3}'`);
  check(v3s.status === 'cancelled_owner' && v3s.cancel_fee === 0 && ['-' + '>pending_vet,pending_vet>cancelled_owner', '-' + '>pending_vet,pending_vet>accepted,accepted>cancelled_owner'].includes(ev3),
    `cancelar vs confirmar en paralelo: estado ${v3s.status}, cargo ${v3s.cancel_fee}, eventos ${ev3} (${cr.map((r) => r.status).join(',')})`);
  // Carrera: dos dueños reservan el mismo horario; y bordes del traslado.
  const sameSlot = slotsW[20];
  const [qa1, qb1] = [(await quote(a, W)).json, (await quote(b, W)).json];
  const race = await Promise.all([book(a, qa1, W, sameSlot), book(b, qb1, W, sameSlot)]);
  check(race.map((r) => r.status).sort().join(',') === '200,400', `mismo horario en paralelo: ${race.map((r) => r.status).join(',')}`);
  const loser = race[0].status === 200 ? [b, qb1] : [a, qa1];
  const qConsumed = sql(`select consumed_at is null from public.quotes where id = '${loser[1].quote_id}'`);
  check(qConsumed === 't', 'la cotización del perdedor no queda consumida (puede reintentar)');
  const plus = (iso, m) => new Date(new Date(iso).getTime() + m * 60000).toISOString();
  const q60 = (await quote(loser[0], W)).json;
  check((await book(loser[0], q60, W, plus(sameSlot, 60))).status === 400, 'a +60 min (dentro del traslado) se rechaza');
  check((await book(loser[0], q60, W, plus(sameSlot, -60))).status === 400, 'a −60 min también');
  check((await book(loser[0], q60, W, plus(sameSlot, 90))).status === 200, 'a +90 min sí se puede');

  // ==== 2. Reserva: bordes ============================================================
  const qA = (await quote(a, V)).json;
  check((await book(b, qA, V, slotsV[1])).status === 400, 'B no reserva con la cotización de A');
  const qW = (await quote(a, W)).json;
  check((await book(a, qW, V, slotsV[1])).status === 400, 'cotización de W no sirve para V');
  const qU = (await rpc('quote_visit', { p_pet_id: pets.a, p_address_id: addrs.a, p_specialty_id: general, p_mode: 'urgent' }, a.token)).json;
  check((await book(a, qU, V, slotsV[1])).status === 400, 'una cotización urgente no reserva agendada');
  const qE = (await quote(a, V)).json;
  sql(`set session_replication_role = replica; update public.quotes set expires_at = now() - interval '1 minute' where id = '${qE.quote_id}'`);
  const exp = await book(a, qE, V, slotsV[1]);
  check(exp.status === 400 && /venció/.test(exp.json.message), `cotización vencida rechazada (${exp.json.message})`);
  const qT = (await quote(a, V)).json;
  const soon = new Date(Math.ceil((Date.now() + 2 * 3600e3) / 1800e3) * 1800e3).toISOString();
  check((await book(a, qT, V, soon)).status === 400, `con menos de 3 h de anticipación se rechaza (${soon})`);
  check((await book(a, qT, V, plus(slotsV[1], 15))).status === 400, 'un horario no alineado a 30 min se rechaza');
  check((await book(a, qT, V, plus(slotsV[1], 0.5))).status === 400, 'un horario con segundos se rechaza');
  const in40 = new Date(Math.ceil((Date.now() + 40 * 86400e3) / 1800e3) * 1800e3).toISOString();
  check((await book(a, qT, V, in40)).status === 400, 'a más de 30 días se rechaza');
  check((await book(a, qT, V, slotsV[1], { p_notes: 'x'.repeat(301) })).status === 400, 'nota de más de 300 caracteres rechazada');
  const qTc = sql(`select consumed_at is null from public.quotes where id = '${qT.quote_id}'`);
  check(qTc === 't', 'los intentos fallidos no consumen la cotización');
  // Fuera del horario semanal del vet.
  sql(`delete from public.vet_availability where vet_id = '${W.id}'; insert into public.vet_availability (vet_id, weekday, start_min, end_min) select '${W.id}', g, 540, 780 from generate_series(1,7) g`);
  const slotsW2 = await slotsOf(a, W, dayAfter);
  const qH = (await quote(a, W)).json;
  const at15 = new Date(`${dayAfter}T15:00:00-03:00`).toISOString();
  const okHours = slotsW2.every((s) => { const [h, m] = new Date(s).toLocaleTimeString('en-GB', { timeZone: 'America/Santiago', hour12: false }).split(':').map(Number); return h * 60 + m >= 540 && h * 60 + m + 60 <= 780; });
  check(okHours && slotsW2.length === 7, `con horario 9:00–13:00 solo se ofrecen inicios de 9:00 a 12:00 (${slotsW2.length})`);
  check((await book(a, qH, W, at15)).status === 400, 'reservar a las 15:00 (fuera del horario) se rechaza');
  // Día libre.
  const off = await rpc('add_time_off', { p_from: dayAfter, p_to: dayAfter }, W.token);
  check(off.status === 200 && (await slotsOf(a, W, dayAfter)).length === 0, 'con un día libre el vet no ofrece horarios');
  check((await book(a, qH, W, slotsW2[0])).status === 400, 'reservar en el día libre se rechaza');
  // Vet suspendido después de cotizar.
  const qS = (await quote(d, W)).json;
  await rest(`vet_profiles?user_id=eq.${W.id}`, { method: 'PATCH', ...srv, body: { status: 'suspended' } });
  const susp = await book(d, qS, W, nextW());
  check(susp.status === 400, `vet suspendido tras cotizar: reserva rechazada (HTTP ${susp.status})`);
  await rest(`vet_profiles?user_id=eq.${W.id}`, { method: 'PATCH', ...srv, body: { status: 'approved' } });
  // Fuera del radio.
  check((await quote(a, far)).status === 400 && (await slotsOf(a, far)).length === 0, 'vet a ~100 km: no se cotiza ni aparece en available_vets');
  // Vet aprobado SIN punto de partida.
  const qN = await quote(a, nobase);
  const bN = qN.status === 200 ? await book(a, qN.json, nobase, slotsV[40]) : { status: qN.status };
  known(qN.status === 400 || bN.status === 400, 'QA-F6-01',
    `un vet sin punto de partida no se cotiza ni se reserva (cotización ${qN.status}, distancia ${qN.json?.distance_km}, recargo ${qN.json?.distance_surcharge}; reserva ${bN.status})`);
  if (bN.status === 200) await tr(bN.json.id, 'cancelled_owner', a.token);
  // Tope de visitas abiertas (5).
  const open = [];
  for (let i = 0; i < 6; i++) {
    const q = (await quote(d, V)).json;
    open.push((await book(d, q, V, nextV())).status);
  }
  const dOpen = Number(sql(`select count(*) from public.visits where owner_id = '${d.id}' and status in ('pending_vet','accepted','en_route','arrived','in_progress')`));
  check(dOpen === 5 && open[open.length - 1] === 400, `tope de 5 visitas abiertas por dueño (${open.join(',')}; abiertas ${dOpen})`);

  // ==== 3. Privacidad por estado ======================================================
  const ownerKeys = (x) => Object.keys(x).sort().join(',');
  const seen = {};
  const expose = async (id, label) => {
    const vv = await mv(id, V.token);
    seen[label] = vv ? { exact: !!vv.exact, phone: vv.exact?.owner_phone ?? null, street: vv.exact?.street_text ?? null } : null;
  };
  const p1 = await newVisit(b); await expose(p1, 'pending_vet');
  await tr(p1, 'accepted', V.token); await expose(p1, 'accepted');
  shift(p1, "now() + interval '30 minutes'");
  for (const s of ['en_route', 'arrived', 'in_progress']) { await tr(p1, s, V.token); await expose(p1, s); }
  await tr(p1, 'completed', V.token); await expose(p1, 'completed');
  const p2 = await newVisit(b); await tr(p2, 'rejected', V.token, 'Sin cupo'); await expose(p2, 'rejected');
  const p3 = await newVisit(b); await tr(p3, 'accepted', V.token); await tr(p3, 'cancelled_owner', b.token); await expose(p3, 'cancelled_owner');
  const p4 = await newVisit(b); await tr(p4, 'accepted', V.token); await tr(p4, 'cancelled_vet', V.token, 'Imprevisto'); await expose(p4, 'cancelled_vet');
  const p5 = await newVisit(b);
  sql(`update public.visits set confirm_deadline = now() - interval '1 minute' where id = '${p5}'; select private.expire_visits();`);
  await expose(p5, 'expired');
  const expect = { pending_vet: false, accepted: true, en_route: true, arrived: true, in_progress: true, completed: false, rejected: false, cancelled_owner: false, cancelled_vet: false, expired: false };
  const wrong = Object.entries(expect).filter(([k, e]) => !seen[k] || seen[k].exact !== e || (e && seen[k].phone !== '+56 9 2222 3333'));
  check(wrong.length === 0, `dirección exacta y teléfono solo en accepted…in_progress (${Object.entries(seen).map(([k, x]) => `${k}:${x?.exact ? 'sí' : 'no'}`).join(' ')})`);
  check(!(await mv(p1, W.token)) && ((await rest(`visits?select=id&id=eq.${p1}`, { token: W.token })).json ?? []).length === 0, 'otro vet no ve la visita (ni my_visits ni la tabla)');
  const ov = await mv(p1, b.token);
  const leakKeys = Object.keys(ov).filter((k) => /commune|base|origin|lat|lng|vet_(phone|commune|bio)/.test(k) && k !== 'commune_name');
  check(leakKeys.length === 0 && ov.commune_name === 'Ñuñoa', `R-1: el dueño ve solo la comuna de SU dirección, nada de la base del vet (claves: ${ownerKeys(ov)})`);
  check(ov.quote.distance_km === undefined || Number.isInteger(ov.quote.distance_km), 'el snapshot del dueño trae distance_km entero (desde quote_origin)');
  for (const [who, u] of [['fundación', fund], ['admin', admin]]) {
    const m = await rpc('my_visits', { p_limit: 200 }, u.token);
    const t = await rest('visits?select=id', { token: u.token });
    check(m.status === 200 && m.json.length === 0 && t.json.length === 0, `${who}: 0 visitas en my_visits y en la tabla`);
  }
  const admEv = await rest(`visit_events?select=visit_id,actor_id,to_status,at&visit_id=eq.${p1}`, { token: admin.token });
  known(admEv.json.length === 0, 'QA-F6-02', `el admin NO lee el historial individual de una visita (visit_events: ${admEv.json.length} filas con actor_id y hora)`);
  const admTO = await rest(`vet_time_off?select=vet_id,period`, { token: admin.token });
  console.log(`INFO    el admin lee vet_time_off (${admTO.json.length} filas): dato del vet, aceptable para moderación`);
  for (const lim of [-5, 0, 1000000]) {
    const m = await rpc('my_visits', { p_limit: lim }, b.token);
    check(m.status === 200 && m.json.length <= 200 && m.json.every((x) => x.viewer === 'owner'), `my_visits(p_limit=${lim}) acota a ≤ 200 y solo propias (${m.json.length})`);
  }
  check((await rpc('my_visits', { p_limit: 'x' }, b.token)).status === 400, 'my_visits con p_limit no numérico → 400');
  check((await rpc('my_visits', { p_owner: a.id }, b.token)).status === 404, 'my_visits no acepta p_owner');
  const colQ = await rest(`visits?select=quote,address_id,pet_id&id=eq.${p1}`, { token: V.token });
  check(colQ.status === 403, `el vet no lee quote/address_id/pet_id directo de visits (HTTP ${colQ.status})`);

  // ==== 4. Pagos y cancelación =====================================================
  for (const [lbl, id] of [['pending_vet', v1], ['rejected', p2], ['cancelled_owner', p3], ['expired', p5]]) {
    const r = await rpc('simulate_payment', { p_visit_id: id }, lbl === 'pending_vet' ? a.token : b.token);
    check(r.status === 400, `no se paga una visita ${lbl} (HTTP ${r.status})`);
  }
  const pay1 = await rpc('simulate_payment', { p_visit_id: p1 }, b.token);
  const pay2 = await rpc('simulate_payment', { p_visit_id: p1 }, b.token);
  check(pay1.status === 200 && pay2.status === 400, `visita completada: se paga una vez (${pay1.status}, ${pay2.status})`);
  // Configuración congelada: se publica una versión nueva más cara y con 24 h.
  const c0 = sql('select id from public.current_pricing_config()');
  const k1 = await newVisit(c);
  await tr(k1, 'accepted', V.token);
  await rest('pricing_config', { method: 'POST', token: admin.token, body: { commission_pct: 15, foundation_pct: 20, urgent_pct: 30, per_km: 500, free_km: 5,
    cancel_fee: 9000, cancel_free_hours: 24, max_distance_km: 30, created_by: admin.id, effective_from: new Date(Date.now() - 1000).toISOString() } });
  const c1 = sql('select id from public.current_pricing_config()');
  check(c1 !== c0, `nueva versión de pricing_config vigente (${c0} → ${c1})`);
  shift(k1, "now() + interval '3 hours'");
  check((await mv(k1, c.token)).cancel_fee_now === 0, 'a 3 h: con la regla congelada (2 h) cancelar es gratis, aunque la nueva diga 24 h');
  shift(k1, "now() + interval '90 minutes'");
  check((await mv(k1, c.token)).cancel_fee_now === 5000, 'a 1,5 h: cargo congelado de $5.000 (no los $9.000 nuevos)');
  const can = await tr(k1, 'cancelled_owner', c.token);
  const fee = (await rest(`payments?select=kind,status,service_price,platform_fee,foundation_share,vet_payout,total&visit_id=eq.${k1}`, { token: c.token })).json;
  check(can.json.cancel_fee === 5000 && fee.length === 1 && fee[0].kind === 'cancel_fee' && fee[0].platform_fee === 750 && fee[0].foundation_share === 150 && fee[0].vet_payout === 4250,
    `cargo de cancelación $5.000 → comisión ${fee[0]?.platform_fee}, fundación ${fee[0]?.foundation_share}, vet ${fee[0]?.vet_payout}`);
  // Visita nueva con la config nueva: usa 24 h y $9.000.
  const k2 = await newVisit(c);
  await tr(k2, 'accepted', V.token);
  shift(k2, "now() + interval '5 hours'");
  check((await mv(k2, c.token)).cancel_fee_now === 9000, 'una visita cotizada con la versión nueva usa sus $9.000 / 24 h (a 5 h ya cobra)');
  await rest('pricing_config', { method: 'POST', token: admin.token, body: { commission_pct: 15, foundation_pct: 20, urgent_pct: 30, per_km: 500, free_km: 5,
    cancel_fee: 5000, cancel_free_hours: 2, max_distance_km: 30, created_by: admin.id, effective_from: new Date(Date.now() - 1000).toISOString() } });
  // pending_vet: siempre gratis.
  const k3 = await newVisit(c); shift(k3, "now() + interval '20 minutes'");
  check((await tr(k3, 'cancelled_owner', c.token)).json?.cancel_fee === 0, 'cancelar una pending_vet, aun a minutos, es gratis');
  // Vet marca "en camino" y no llega: el dueño solo puede cancelar pagando.
  const k4 = await newVisit(c); await tr(k4, 'accepted', V.token); shift(k4, "now() + interval '110 minutes'");
  await tr(k4, 'en_route', V.token);
  sql(`update public.visits set scheduled_at = now() - interval '5 hours', slot = tstzrange(now() - interval '5 hours', now() - interval '210 minutes') where id = '${k4}'; select private.expire_visits();`);
  const k4s = (await mv(k4, c.token)).status;
  known(k4s !== 'en_route', 'QA-F6-03', `una visita "en camino" 5 h después de su hora se cierra sola (estado: ${k4s})`);
  const k4c = await tr(k4, 'cancelled_owner', c.token);
  known(k4c.json?.cancel_fee === 0, 'QA-F6-03', `si el vet marcó "en camino" y no llegó, cancelar no le cobra al dueño (cargo $${k4c.json?.cancel_fee})`);
  // Completar antes de la hora.
  const k5 = await newVisit(a); await tr(k5, 'accepted', V.token); shift(k5, "now() + interval '115 minutes'");
  const early = [];
  for (const s of ['en_route', 'arrived', 'in_progress', 'completed']) early.push((await tr(k5, s, V.token)).status);
  known(early[3] >= 400, 'QA-F6-04', `el vet no puede dar por completada una visita casi 2 h antes de su hora (${early.join(',')})`);
  // El vet ve solo sus pagos.
  const pv = (await rest('payments?select=vet_id,owner_id,extra_donation', { token: V.token })).json;
  const pw = (await rest('payments?select=vet_id', { token: W.token })).json;
  check(pv.length >= 2 && pv.every((p) => p.vet_id === V.id) && pw.every((p) => p.vet_id === W.id), `el vet ve solo sus pagos (V ${pv.length}, W ${pw.length})`);
  check((await rest('payments?select=id', { token: fund.token })).json.length === 0, 'la fundación no ve pagos');

  // ==== 5. Cron ====================================================================
  const j = sql("select count(*) filter (where status = 'succeeded') || '/' || count(*) from cron.job_run_details d join cron.job j using (jobid) where j.jobname = 'expire-visits'");
  check(Number(j.split('/')[0]) >= 1, `expire-visits corre en pg_cron (${j} ejecuciones exitosas/total)`);
  const ng = await newVisit(b); await tr(ng, 'accepted', V.token);
  sql(`update public.visits set scheduled_at = now() - interval '61 minutes', slot = tstzrange(now() - interval '61 minutes', now() + interval '29 minutes') where id = '${ng}'; select private.expire_visits();`);
  const ngs = await mv(ng, b.token);
  check(ngs.status === 'cancelled_vet' && ngs.cancel_fee === 0, `confirmada que nunca empieza → cancelled_vet sin cargo (${ngs.status})`);
  const ngEv = sql(`select actor_id is null from public.visit_events where visit_id = '${ng}' order by id desc limit 1`);
  check(ngEv === 't', 'el cierre automático queda en el historial sin actor');
  // Purga de cotizaciones.
  const qOld = (await quote(a, V)).json.quote_id;
  const qRecentExp = (await quote(a, V)).json.quote_id;
  const qLive = (await quote(a, V)).json.quote_id;
  const qUsedOld = (await quote(a, V)).json;
  const bu = await book(a, qUsedOld, V, nextV());
  await tr(bu.json.id, 'cancelled_owner', a.token);
  sql(`set session_replication_role = replica;
    update public.quotes set expires_at = now() - interval '2 days' where id in ('${qOld}', '${qUsedOld.quote_id}');
    update public.quotes set expires_at = now() - interval '2 hours' where id = '${qRecentExp}';`);
  sql('select private.purge_stale_quotes()');
  const left = sql(`select string_agg(id::text, ',') from public.quotes where id in ('${qOld}', '${qRecentExp}', '${qLive}', '${qUsedOld.quote_id}')`);
  check(!left.includes(qOld) && left.includes(qRecentExp) && left.includes(qLive) && left.includes(qUsedOld.quote_id),
    'la purga borra solo las vencidas hace más de 1 día y nunca usadas');
  const vq = sql(`select quote_id is not null from public.visits where id = '${bu.json.id}'`);
  check(vq === 't', 'la visita conserva su cotización usada');
} finally {
  for (const id of created) await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', ...srv });
}

console.log(fails ? `\nQA fase 6: ${fails} FALLAS, ${defects} defectos conocidos` :
  defects ? `\nQA fase 6: sin fallas; ${defects} defectos conocidos` : '\nQA fase 6: TODO OK');
process.exit(fails ? 1 : defects ? 2 : 0);
