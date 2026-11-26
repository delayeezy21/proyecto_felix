// QA exploratorio de la fase 9 (calificaciones y cancelaciones, SPEC F7,
// HU7.1–HU7.4) contra Supabase local: Auth + REST, y SQL directo (docker exec)
// solo para simular el paso del tiempo y correr el job de borrado.
//
// Uso: node tool/e2e/calificaciones_exploratorio_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
//
// Convención: OK / FALLA (código 1) / DEFECTO <id> (código 2, documentado en
// docs/qa/; pasa a OK solo cuando se corrige). Solo crea usuarios
// *@test.local y los borra al final.
import { backdateStart, shiftVisit, sqlRunner, timeTravel } from './sql.mjs';

const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(API)) throw new Error('Solo stacks locales');
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
  return { status: r.status, json, text };
}
const rest = (p, o) => call(`/rest/v1/${p}`, o);
const rpc = (name, body, token) => call(`/rest/v1/rpc/${name}`, { method: 'POST', token, body });
const srv = { key: SRV, token: SRV };

const stamp = Date.now();
const created = [];
async function newUser(tag) {
  const email = `qa-f9-${tag}-${stamp}@test.local`;
  const c = await call('/auth/v1/admin/users', { method: 'POST', ...srv, body: { email, password: 'Felix2026', email_confirm: true } });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status}`);
  created.push(c.json.id);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password: 'Felix2026' } });
  return { token: s.json.access_token, id: c.json.id, tag, email };
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
const shift = (id, expr) => shiftVisit(sql, id, expr);
// completed_at / closed_at no se mueven con felix.time_travel: como en el pgTAP
// 200, se usa session_replication_role = replica (sin triggers) solo en QA.
const backdate = (where, interval) => sql(`begin; set local session_replication_role = replica;
  update public.visits set completed_at = case when completed_at is not null then now() - interval '${interval}' end,
  closed_at = now() - interval '${interval}' where ${where}; commit;`);
const keys = (o) => Object.keys(o ?? {}).sort().join(',');

try {
  const general = (await rest('specialties?select=id&slug=eq.general', srv)).json[0].id;
  const perro = (await rest('species?select=id&slug=eq.perro', srv)).json[0].id;
  const users = await Promise.all(['a', 'b', 'c', 'd', 'e', 'x', 'v', 'w', 'pend', 'admin'].map(newUser));
  const [a, b, c, d, e, x, V, W, pend, admin] = users;
  await rest('user_roles', { method: 'POST', ...srv, body: { user_id: admin.id, role: 'admin' } });
  const nunoa = await cAt(-33.4569, -70.5974, a.token);
  for (const o of [a, b, c, d, e, x]) await register(o, 'owner', nunoa, '+56 9 2222 3333');
  for (const v of [V, W, pend]) await register(v, 'vet');
  for (const v of [V, W]) await rest(`vet_profiles?user_id=eq.${v.id}`, { method: 'PATCH', ...srv, body: { status: 'approved' } });
  for (const v of [V, W, pend]) {
    await rest('vet_species', { method: 'POST', ...srv, body: { vet_id: v.id, species_id: perro } });
    await rest('vet_specialties', { method: 'POST', ...srv, body: { vet_id: v.id, specialty_id: general } });
    await rest('vet_availability', { method: 'POST', ...srv, body: [1, 2, 3, 4, 5, 6, 7].map((n) => ({ vet_id: v.id, weekday: n, start_min: 0, end_min: 1440 })) });
    await rest('vet_bases', { method: 'POST', token: v.token, body: { vet_id: v.id, commune_id: await cAt(-33.42, -70.58, v.token), lat: -33.42, lng: -70.58 } });
  }
  const pets = {}; const addrs = {};
  for (const o of [a, b, c, d, e, x]) {
    pets[o.tag] = (await rest('pets?select=id', { method: 'POST', token: o.token, prefer: 'return=representation', body: { owner_id: o.id, name: `QA ${o.tag}`, species_id: perro } })).json[0].id;
    addrs[o.tag] = (await rest('addresses?select=id', { method: 'POST', token: o.token, prefer: 'return=representation',
      body: { owner_id: o.id, label: 'Casa', street_text: `Calle QA ${o.tag} 100`, commune_id: nunoa, lat: -33.4569, lng: -70.5974 } })).json[0].id;
  }
  const tr = (id, to, tok, reason = null) => rpc('transition_visit', { p_visit_id: id, p_to_status: to, p_reason: reason }, tok);
  const slotsOf = async (o, vet, date) => ((await rpc('available_vets', { p_pet_id: pets[o.tag], p_address_id: addrs[o.tag],
    p_specialty_id: general, p_date: date }, o.token)).json ?? []).find((y) => y.vet_id === vet.id)?.slots ?? [];
  const days = [1, 2, 3, 4, 5, 6].map((n) => chile(new Date(Date.now() + n * 24 * 3600 * 1000)));
  const pool = { [V.id]: [], [W.id]: [] };
  for (const dd of days) { pool[V.id].push(...await slotsOf(a, V, dd)); pool[W.id].push(...await slotsOf(a, W, dd)); }
  check(pool[V.id].length >= 40 && pool[W.id].length >= 40, `V y W ofrecen horarios (${pool[V.id].length}/${pool[W.id].length})`);
  const idx = { [V.id]: 0, [W.id]: 0 };
  const newVisit = async (o, vet) => {
    const q = (await rpc('quote_visit', { p_pet_id: pets[o.tag], p_address_id: addrs[o.tag], p_specialty_id: general,
      p_mode: 'scheduled', p_vet_id: vet.id }, o.token)).json;
    const when = pool[vet.id][idx[vet.id]]; idx[vet.id] += 3;
    const r = await rpc('book_visit', { p_quote_id: q.quote_id, p_vet_id: vet.id, p_pet_id: pets[o.tag],
      p_address_id: addrs[o.tag], p_scheduled_at: when }, o.token);
    if (r.status !== 200) throw new Error(`book ${o.tag}: ${r.status} ${JSON.stringify(r.json)}`);
    return r.json.id;
  };
  const complete = async (o, vet) => {
    const id = await newVisit(o, vet);
    await tr(id, 'accepted', vet.token);
    shift(id, "now() + interval '30 minutes'");
    for (const s of ['en_route', 'arrived', 'in_progress']) await tr(id, s, vet.token);
    backdateStart(sql, id);
    const r = await tr(id, 'completed', vet.token);
    if (r.json?.status !== 'completed') throw new Error(`completar: ${r.status} ${JSON.stringify(r.json)}`);
    return id;
  };
  const rate = (id, stars, tok, comment) => rpc('rate_visit', { p_visit_id: id, p_stars: stars, p_comment: comment }, tok);
  const status = (id, tok) => rpc('visit_rating_status', { p_visit_id: id }, tok);
  const summary = async (vet, tok = x.token) => (await rpc('vet_rating_summary', { p_vet_id: vet.id }, tok)).json;

  // ==== HU7.1: solo participantes, visita completada, una vez ======================
  const vA = await newVisit(a, V);
  await tr(vA, 'accepted', V.token);
  const early = await rate(vA, 5, a.token);
  check(early.status === 400, `no se califica una visita aceptada (HTTP ${early.status})`);
  shift(vA, "now() + interval '30 minutes'");
  for (const s of ['en_route', 'arrived', 'in_progress']) await tr(vA, s, V.token);
  check((await rate(vA, 5, a.token)).status === 400, 'ni una en curso');
  backdateStart(sql, vA); await tr(vA, 'completed', V.token);
  const outsiders = { otroDueño: b.token, otroVet: W.token, admin: admin.token, vetPendiente: pend.token };
  const outRes = {};
  for (const [k, t] of Object.entries(outsiders)) outRes[k] = (await rate(vA, 5, t)).status;
  check(Object.values(outRes).every((s) => s === 403), `terceros no califican: ${JSON.stringify(outRes)}`);
  check((await rate(vA, 5, undefined)).status === 401, 'anónimo no califica (401)');
  const statOut = {};
  for (const [k, t] of Object.entries(outsiders)) statOut[k] = (await status(vA, t)).status;
  check(Object.values(statOut).every((s) => s === 403), `terceros no leen el estado de la calificación: ${JSON.stringify(statOut)}`);
  check((await rate('00000000-0000-0000-0000-000000000000', 5, a.token)).status === 403, 'visita inexistente: 403 (no se distingue de ajena)');
  const bad = [];
  for (const s of [0, 6, -1, null]) bad.push((await rate(vA, s, a.token)).status);
  check(bad.every((s) => s === 400), `estrellas fuera de 1–5 → 400 (${bad})`);
  check((await rate(vA, 3, a.token, 'x'.repeat(501))).status === 400, 'comentario de 501 caracteres → 400');
  check((await rest(`ratings?visit_id=eq.${vA}`, srv)).json.length === 0, 'los rechazos no dejaron filas');
  const r1 = await rate(vA, 5, a.token, '  ' + 'ñ'.repeat(500) + '  ');
  check(r1.status === 200 && r1.json.mine?.stars === 5 && r1.json.mine.comment.length === 500 && r1.json.can_rate === false,
    `el dueño califica con 500 caracteres (recortados los espacios) (HTTP ${r1.status})`);
  const dup = await rate(vA, 4, a.token);
  check(dup.status === 409, `segunda calificación del mismo participante → 409 (HTTP ${dup.status})`);
  const blank = await rate(vA, 4, V.token, '   ');
  // (blank se usa también en HU7.2: el vet califica con comentario vacío → null)

  // ==== HU7.2: ciega hasta que ambos califican ======================================
  const vB = await complete(b, V);
  await rate(vB, 2, b.token, 'Llegó tarde');
  const sV = (await status(vB, V.token)).json;
  check(sV.theirs === null && sV.can_rate === true && sV.my_role === 'vet', 'el vet no ve la calificación del dueño antes de calificar');
  const sumBefore = await summary(V);
  const recvBefore = (await rpc('my_ratings_received', {}, V.token)).json;
  check(!recvBefore.some((y) => y.comment === 'Llegó tarde'), 'ni aparece en my_ratings_received');
  const rv = await rate(vB, 4, V.token, 'Dueño amable');
  check(rv.json.theirs?.stars === 2 && rv.json.theirs.comment === 'Llegó tarde', 'al calificar el segundo, ambos se publican (vet ve la del dueño)');
  const sB = (await status(vB, b.token)).json;
  check(sB.theirs?.stars === 4 && sB.theirs.comment === 'Dueño amable', 'y el dueño ve la del vet');
  check(blank.status === 200 && blank.json.mine?.comment === null && blank.json.theirs?.stars === 5,
    'en vA el vet calificó con comentario en blanco (queda null) y ve la del dueño');
  check(keys(sB.theirs) === 'comment,comment_hidden,published_at,stars', `theirs no expone quién calificó (${keys(sB.theirs)})`);

  // Carrera: dueño y vet califican a la vez (3 visitas).
  const race = [];
  for (const o of [c, e, c]) race.push(await complete(o, V));
  const raceOwners = [c, e, c];
  await Promise.all(race.flatMap((id, i) => [rate(id, 5, raceOwners[i].token), rate(id, 3, V.token)]));
  const unpub = sql(`select count(*) from public.ratings where visit_id in ('${race.join("','")}') and published_at is null`);
  const nr = sql(`select count(*) from public.ratings where visit_id in ('${race.join("','")}')`);
  check(nr === '6' && unpub === '0', `carrera: 6 calificaciones y todas publicadas (sin publicar: ${unpub})`);

  // Promedio: solo dueño→vet publicadas, con ≥ 3.
  const sum = await summary(V);
  // V recibió 5 (a), 2 (b), 5, 5, 5 (carrera) = 22/5 = 4.4
  check(sumBefore?.rating_avg === null && Number(sum?.rating_avg) === 4.4 && sum.rating_count === 5,
    `promedio público de V = 4,4 con 5 (antes: ${JSON.stringify(sumBefore)}; ahora: ${JSON.stringify(sum)})`);
  check(keys(sum) === 'rating_avg,rating_count,vet_id', `vet_rating_summary solo trae el agregado (${keys(sum)})`);
  const recv = (await rpc('my_ratings_received', {}, V.token)).json;
  check(recv.length === 5 && recv.every((y) => keys(y) === 'comment,comment_hidden,published_on,rater_role,stars'),
    `my_ratings_received: 5 filas sin rater_id (${recv.length}; ${keys(recv[0])})`);
  check(!JSON.stringify(recv).includes(a.id) && !JSON.stringify(recv).includes(b.id), 'sin UUID de los dueños');
  const mySum = (await rpc('my_rating_summary', {}, b.token)).json;
  check(mySum.rating_count === 1 && mySum.rating_avg === null && mySum.cancel_count_30d === null,
    `resumen del dueño b: 1 recibida, sin promedio (< 3) y sin contador de cancelaciones (${JSON.stringify(mySum)})`);
  check((await summary(pend)) === null && (await rpc('vet_rating_summary', { p_vet_id: V.id }, undefined)).status === 401,
    'vet no aprobado → null; anónimo → 401');
  const direct = await Promise.all([rest('ratings?select=*', { token: V.token }), rest('ratings?select=*', { token: admin.token }),
    rest('vet_cancel_alerts?select=*', { token: admin.token }), rest('vet_cancel_alerts?select=*', { token: W.token })]);
  check(direct.every((y) => y.status === 401 || y.status === 403), `sin acceso directo a las tablas (${direct.map((y) => y.status)})`);

  // Plazo de 7 días (168 h).
  const vD = await complete(d, V);
  await rate(vD, 1, d.token, 'Mala atención');
  backdate(`id = '${vD}'`, '167 hours 59 minutes');
  const near = (await status(vD, V.token)).json;
  check(near.can_rate === true && near.theirs === null, 'a las 167 h 59 min el vet aún puede calificar y sigue ciega');
  backdate(`id = '${vD}'`, '168 hours 1 minute');
  const late = await rate(vD, 5, V.token);
  check(late.status === 400 && /venci/.test(late.json?.message ?? ''), `vencidas las 168 h → 400 (HTTP ${late.status})`);
  const after = (await status(vD, V.token)).json;
  check(after.can_rate === false && after.theirs?.stars === 1, 'vencido el plazo, la calificación del dueño se publica sola');
  check(Number((await summary(V)).rating_avg) === 3.83 && (await summary(V)).rating_count === 6, 'y entra al promedio (23/6 = 3,83)');

  // ==== Moderación =================================================================
  const list = await rpc('admin_list_ratings', {}, admin.token);
  const target = list.json.find((y) => y.visit_id === vB && y.rater_role === 'owner');
  check(list.status === 200 && target && list.json.some((y) => y.published === false || y.published === true), 'el admin lista las calificaciones');
  const nonAdmin = await Promise.all([rpc('admin_list_ratings', {}, V.token), rpc('admin_set_rating_hidden', { p_rating_id: target.id }, b.token),
    rpc('admin_list_cancel_alerts', {}, V.token), rpc('admin_review_cancel_alert', { p_alert_id: target.id }, W.token)]);
  check(nonAdmin.every((y) => y.status === 403), `RPC del admin rechazan a otros (${nonAdmin.map((y) => y.status)})`);
  const hide = await rpc('admin_set_rating_hidden', { p_rating_id: target.id }, admin.token);
  check(hide.status === 200 && hide.json.hidden === true, 'el admin oculta el comentario');
  const hv = (await status(vB, V.token)).json.theirs;
  check(hv.comment === null && hv.comment_hidden === true && hv.stars === 2, 'el vet ya no ve el comentario; las estrellas siguen');
  const hr = (await rpc('my_ratings_received', {}, V.token)).json.find((y) => y.stars === 2 && y.comment_hidden);
  check(hr?.comment === null && hr?.comment_hidden === true, 'tampoco en my_ratings_received');
  const audit = sql(`select count(*) || ':' || bool_and(actor_id = '${admin.id}') from public.admin_audit_log
    where table_name = 'ratings' and row_pk = '${target.id}' and action = 'UPDATE'`);
  check(audit === '1:true', `ocultar queda en admin_audit_log con el admin como actor (${audit})`);

  // ==== HU7.3: cargos por estado y hora ==============================================
  const k1 = await newVisit(a, V); await tr(k1, 'accepted', V.token);
  shift(k1, "now() + interval '3 hours'");
  const free = await tr(k1, 'cancelled_owner', a.token);
  const k2 = await newVisit(a, V); await tr(k2, 'accepted', V.token);
  shift(k2, "now() + interval '90 minutes'");
  const fee = await tr(k2, 'cancelled_owner', a.token);
  const k3 = await newVisit(a, V);
  const pendFree = await tr(k3, 'cancelled_owner', a.token);
  const k4 = await newVisit(a, V); await tr(k4, 'accepted', V.token);
  shift(k4, "now() + interval '30 minutes'");
  const vetCancel = await tr(k4, 'cancelled_vet', V.token, 'Imprevisto');
  check(free.json?.cancel_fee === 0 && fee.json?.cancel_fee === 5000 && pendFree.json?.cancel_fee === 0 && vetCancel.json?.cancel_fee === 0,
    `cargos: >2 h=${free.json?.cancel_fee}, <2 h=${fee.json?.cancel_fee}, pendiente=${pendFree.json?.cancel_fee}, vet=${vetCancel.json?.cancel_fee}`);
  const pays = sql(`select string_agg(visit_id || '=' || kind || ':' || status || ':' || total, ',') from public.payments where visit_id in ('${k1}','${k2}','${k3}','${k4}')`);
  check(pays === `${k2}=cancel_fee:simulated_paid:5000`, `solo la tardía genera pago cancel_fee simulado (${pays})`);
  check((await rest(`payments?select=kind,total&visit_id=eq.${k2}`, { token: a.token })).json?.[0]?.total === 5000, 'el dueño ve su pago cancel_fee');
  check((await rate(k2, 3, a.token)).status === 400, 'una visita cancelada no se califica');

  // ==== HU7.4: alerta de cancelaciones del vet =====================================
  const openAlert = () => sql(`select coalesce(string_agg(cancel_count::text, ','), '') from public.vet_cancel_alerts where vet_id = '${W.id}' and reviewed_at is null`);
  const vetCancelW = async (o) => { const id = await newVisit(o, W); await tr(id, 'accepted', W.token); return tr(id, 'cancelled_vet', W.token, 'Imprevisto'); };
  await vetCancelW(a); await vetCancelW(b);
  check(openAlert() === '', 'con 2 cancelaciones no hay alerta');
  await vetCancelW(c);
  check(openAlert() === '3', `la 3.ª cancelación abre la alerta (${openAlert()})`);
  await vetCancelW(e);
  check(openAlert() === '4', 'la 4.ª actualiza la misma alerta (una abierta por vet)');
  const wSum = (await rpc('my_rating_summary', {}, W.token)).json;
  check(wSum.cancel_count_30d === 4, `el vet ve su contador (${wSum.cancel_count_30d}) pero no la alerta`);
  const al = await rpc('admin_list_cancel_alerts', {}, admin.token);
  const myAl = al.json.find((y) => y.vet_id === W.id);
  check(al.status === 200 && myAl?.cancel_count === 4 && myAl.cancel_count_30d === 4 && myAl.vet_name === 'QA w',
    `el admin lista la alerta (${JSON.stringify(myAl)})`);
  const rev = await rpc('admin_review_cancel_alert', { p_alert_id: myAl.id }, admin.token);
  check(rev.status === 200 && rev.json.reviewed_at, 'el admin la marca revisada');
  const def = (await rpc('admin_list_cancel_alerts', {}, admin.token)).json;
  const inc = (await rpc('admin_list_cancel_alerts', { p_include_reviewed: true }, admin.token)).json;
  check(!def.some((y) => y.id === myAl.id) && inc.some((y) => y.id === myAl.id && y.reviewed_at), 'revisada sale de la lista por defecto y queda en el historial');
  check(sql(`select count(*) from public.admin_audit_log where table_name = 'vet_cancel_alerts' and row_pk = '${myAl.id}' and actor_id = '${admin.id}'`) === '1',
    'la revisión queda auditada');
  const wex = (await rpc('export_my_data', {}, W.token)).json;
  check(wex.cancel_alerts?.length === 1 && keys(wex.cancel_alerts[0]) === 'cancel_count,created_at,first_cancel_at,last_cancel_at,reviewed_at',
    `export del vet trae su alerta sin quién la revisó (${keys(wex.cancel_alerts?.[0])})`);
  // Ventana de 720 h: se envejecen las 4 y se cuentan de nuevo.
  backdate(`vet_id = '${W.id}' and status = 'cancelled_vet'`, '721 hours');
  check((await rpc('my_rating_summary', {}, W.token)).json.cancel_count_30d === 0, 'a las 721 h ya no cuentan');
  await vetCancelW(a); await vetCancelW(b);
  check(openAlert() === '', 'tras la revisión y fuera de ventana, 2 nuevas no abren alerta');
  // Cierre del sistema: aceptada sin "en camino" 1 h después.
  const sys = await newVisit(c, W); await tr(sys, 'accepted', W.token);
  shift(sys, "now() - interval '70 minutes'");
  sql('select private.expire_visits()');
  const sysRow = sql(`select status || ':' || closed_by_system from public.visits where id = '${sys}'`);
  check(sysRow === 'cancelled_vet:true' && openAlert() === '3', `el cierre del sistema cuenta y abre una alerta nueva (${sysRow}; ${openAlert()})`);

  // ==== Exportación ==================================================================
  const aex = await rpc('export_my_data', {}, a.token);
  check(aex.json.ratings_given?.length === 1 && aex.json.ratings_received?.length === 1
    && aex.json.ratings_received[0].from_role === 'vet' && !aex.text.includes(V.id),
    `export del dueño: ratings_given 1, ratings_received 1, sin el UUID del vet`);
  const vex = await rpc('export_my_data', {}, V.token);
  check(vex.json.ratings_given?.length === 5 && vex.json.ratings_received?.length === 6
    && ![a, b, c, d, e].some((o) => vex.text.includes(o.id)), 'export del vet: 5 dadas, 6 recibidas, sin UUID de dueños');
  check(vex.json.ratings_received.find((y) => y.visit_id === vB)?.comment === null, 'el comentario oculto sale null en el export');

  // ==== Cuentas bloqueadas ===========================================================
  const vE = await complete(e, V);
  const reqE = await rpc('request_account_deletion', {}, e.token);
  check(reqE.json?.status === 'blocked', 'e pide el borrado (bloqueada)');
  const own = await rate(vE, 5, e.token);
  check(own.status === 403 && own.json?.hint === 'account_blocked', `propia bloqueada → 403 account_blocked (${own.status} ${own.json?.hint})`);
  const cp = await rate(vE, 5, V.token);
  check(cp.status === 400 && cp.json?.hint === 'counterpart_blocked', `contraparte bloqueada → 400 counterpart_blocked (${cp.status} ${cp.json?.hint})`);
  check((await status(vE, V.token)).json.can_rate === false, 'can_rate = false con la contraparte bloqueada');
  const sumBlocked = await summary(V);
  check(sumBlocked.rating_count === 5, `las calificaciones de e (bloqueada) salen del promedio (${sumBlocked.rating_count})`);
  check(!(await rpc('my_ratings_received', {}, V.token)).json.some((y) => y.visit_id === race[1]), 'y de my_ratings_received');
  check(!(await rpc('admin_list_ratings', {}, admin.token)).json.some((y) => y.visit_id === race[1]), 'y de admin_list_ratings');
  const eex = await rpc('export_my_data', {}, e.token);
  check(eex.status === 200 && eex.json.ratings_given?.length === 1, 'la cuenta bloqueada exporta sus calificaciones');
  // Regla de CLAUDE.md: todo acceso de terceros a datos de un titular bloqueado excluye private.is_blocked.
  const vexB = (await rpc('export_my_data', {}, V.token)).json;
  known(!vexB.ratings_received.some((y) => y.visit_id === race[1]), 'QA-F9-01',
    `el export del vet no entrega la calificación (y el comentario) de la cuenta bloqueada e (recibidas: ${vexB.ratings_received.length})`);
  // Vet bloqueado: la alerta sale del panel y no se revisa.
  const wAlert = sql(`select id from public.vet_cancel_alerts where vet_id = '${W.id}' and reviewed_at is null`);
  const reqW = await rpc('request_account_deletion', {}, W.token);
  check(reqW.json?.status === 'blocked', 'W pide el borrado');
  check(!(await rpc('admin_list_cancel_alerts', { p_include_reviewed: true }, admin.token)).json.some((y) => y.vet_id === W.id), 'el panel no muestra alertas del vet bloqueado');
  check((await rpc('admin_review_cancel_alert', { p_alert_id: wAlert }, admin.token)).status >= 400, 'ni deja revisarlas');
  check((await summary(W)) === null, 'vet_rating_summary del vet bloqueado → null');

  // ==== Borrado (erase_subject) ========================================================
  sql(`update public.deletion_requests set execute_after = now() - interval '1 minute' where user_id in ('${e.id}', '${W.id}') and status = 'blocked'`);
  let run = sql('select private.run_account_deletions()');
  if (/executing/.test(run)) { await call('/functions/v1/purge-privacy-storage', { method: 'POST', ...srv, body: {} }); run = sql('select private.run_account_deletions()'); }
  const stE = sql(`select string_agg(status, ',' order by id) from public.deletion_requests where id in ('${reqE.json.request_id}', '${reqW.json.request_id}')`);
  check(!/executing|blocked/.test(stE), `el borrado de e y W no queda en executing (${stE}; ${run})`);
  const left = sql(`select (select count(*) from public.ratings where rater_id in ('${e.id}','${W.id}') or ratee_id in ('${e.id}','${W.id}'))
    || ':' || (select count(*) from public.vet_cancel_alerts where vet_id = '${W.id}')`);
  check(left === '0:0', `sin calificaciones ni alertas residuales (${left})`);
  const tgt = sql(`select string_agg(target || '=' || affected, ',' order by target) from public.deletion_targets t
    join public.deletion_requests r on r.id = t.request_id where r.id in ('${reqE.json.request_id}','${reqW.json.request_id}') and target in ('ratings (hechas y recibidas)', 'vet_cancel_alerts')`);
  check(/ratings \(hechas y recibidas\)=2/.test(tgt) && /vet_cancel_alerts=2/.test(tgt), `deletion_targets registra los pasos (${tgt})`);
  check(Number((await summary(V)).rating_avg) === 3.6 && (await summary(V)).rating_count === 5, 'el promedio de V queda sin e (18/5 = 3,6)');
} finally {
  for (const id of created) await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', ...srv });
}

console.log(fails ? `\nQA fase 9: ${fails} FALLAS, ${defects} defectos conocidos` :
  defects ? `\nQA fase 9: sin fallas; ${defects} defectos conocidos` : '\nQA fase 9: TODO OK');
process.exit(fails ? 1 : defects ? 2 : 0);
