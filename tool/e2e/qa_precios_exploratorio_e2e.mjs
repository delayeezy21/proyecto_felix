// QA exploratorio de la fase 5 (precios, pagos simulados y fundaciones)
// contra Supabase local: Auth + REST. Complementa precios_e2e.mjs con
// manipulación de parámetros, concurrencia, topes, privacidad de fundaciones
// y de la ubicación del vet.
//
// Uso: node tool/e2e/qa_precios_exploratorio_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
//
// Convención: OK / FALLA (código 1) / DEFECTO <id> (código 2, defecto conocido
// documentado en docs/qa/; pasa a OK solo cuando se corrige).
// Solo crea usuarios *@test.local y fundaciones "QA ..." ficticias. Publica una
// versión de pricing_config con los valores por defecto: correrlo DESPUÉS de
// `supabase test db`.
import { backdateStart, shiftVisit, sqlRunner } from './sql.mjs';

const st = JSON.parse(process.argv[2]);
const sql = sqlRunner(st);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;

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
  const email = `qa-f5-${tag}-${stamp}@test.local`;
  const c = await call('/auth/v1/admin/users', { method: 'POST', ...srv, body: { email, password: 'Felix2026', email_confirm: true } });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status}`);
  created.push(c.json.id);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password: 'Felix2026' } });
  return { token: s.json.access_token, id: c.json.id };
}
const legal = {
  terms: (await rpc('current_legal_version', { p_kind: 'terms' })).json,
  privacy: (await rpc('current_legal_version', { p_kind: 'privacy' })).json,
};
const register = (u, role, commune = null) => rpc('complete_registration', {
  p_role: role, p_display_name: `QA ${role}`, p_phone: null,
  p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: commune }, u.token);
const communeId = async (n) => (await rest(`communes?select=id&name=eq.${encodeURIComponent(n)}`, srv)).json[0].id;
const clp = (x) => Math.floor(x + 0.5);

// Distancia geodésica aproximada (haversine, m) para la trilateración.
const R = 6371008.8;
const rad = (d) => d * Math.PI / 180;
function hav(a, b) {
  const dLat = rad(b[0] - a[0]); const dLng = rad(b[1] - a[1]);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a[0])) * Math.cos(rad(b[0])) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

try {
  const nunoa = await communeId('Ñuñoa');
  const providencia = await communeId('Providencia');
  const lasCondes = await communeId('Las Condes');
  const puntaArenas = await communeId('Punta Arenas');
  const perro = (await rest('species?select=id&slug=eq.perro', srv)).json[0].id;
  const gato = (await rest('species?select=id&slug=eq.gato', srv)).json[0].id;
  const general = (await rest('specialties?select=id&slug=eq.general', srv)).json[0].id;
  const otherSpec = (await rest(`specialties?select=id&slug=neq.general&active=is.true&limit=1`, srv)).json[0].id;

  const [a, b, c, vet, vetPend, vetNoSpec, vetFar, admin, fx, fy] = await Promise.all(
    ['a', 'b', 'c', 'vet', 'vetpend', 'vetnospec', 'vetfar', 'admin', 'fx', 'fy'].map(newUser));
  for (const [u, role] of [[admin, 'admin'], [fx, 'foundation'], [fy, 'foundation']]) {
    await rest('user_roles', { method: 'POST', ...srv, body: { user_id: u.id, role } });
  }
  for (const o of [a, b, c]) check((await register(o, 'owner', nunoa)).status === 200, 'dueño registrado');
  for (const v of [vet, vetPend, vetNoSpec, vetFar]) await register(v, 'vet');
  for (const v of [vet, vetNoSpec, vetFar]) {
    await rest(`vet_profiles?user_id=eq.${v.id}`, { method: 'PATCH', ...srv, body: { status: 'approved' } });
  }
  for (const v of [vet, vetPend, vetNoSpec, vetFar]) {
    await rest('vet_species', { method: 'POST', ...srv, body: { vet_id: v.id, species_id: perro } });
  }
  for (const v of [vet, vetPend, vetFar]) {
    await rest('vet_specialties', { method: 'POST', ...srv, body: { vet_id: v.id, specialty_id: general } });
  }
  // Base "secreta" del vet: solo él debería conocerla.
  const SECRET = [-33.41234, -70.56789];
  const vb = await rest('vet_bases', { method: 'POST', token: vet.token, body: { vet_id: vet.id, commune_id: lasCondes, lat: SECRET[0], lng: SECRET[1] } });
  check(vb.status === 201, `el vet guarda su punto de partida (HTTP ${vb.status})`);

  await rest('pricing_config', { method: 'POST', token: admin.token, body: {
    commission_pct: 15, foundation_pct: 20, urgent_pct: 30, per_km: 500, free_km: 5, cancel_fee: 5000,
    created_by: admin.id, effective_from: new Date(Date.now() - 1000).toISOString() } });

  const mkF = async (name) => (await rest('foundations?select=id', { method: 'POST', token: admin.token,
    prefer: 'return=representation', body: { name, description: 'Ficticia (QA)' } })).json[0]?.id;
  const fX = await mkF(`QA Fundación X ${stamp}`);
  const fY = await mkF(`QA Fundación Y ${stamp}`);
  const fZ = await mkF(`QA Fundación Z inactiva ${stamp}`);
  await rest(`foundations?id=eq.${fZ}`, { method: 'PATCH', token: admin.token, body: { active: false } });
  await rest('foundation_members', { method: 'POST', token: admin.token, body: { user_id: fx.id, foundation_id: fX } });
  await rest('foundation_members', { method: 'POST', token: admin.token, body: { user_id: fy.id, foundation_id: fY } });

  const mkPet = async (o, species = perro) => (await rest('pets?select=id', { method: 'POST', token: o.token,
    prefer: 'return=representation', body: { owner_id: o.id, name: 'QA', species_id: species } })).json[0].id;
  const mkAddr = async (o, lat, lng, commune) => {
    commune ??= (await rpc('communes_at_point', { p_lat: lat, p_lng: lng }, o.token)).json[0].commune_id;
    const r = await rest('addresses?select=id', { method: 'POST', token: o.token, prefer: 'return=representation',
      body: { owner_id: o.id, label: 'QA', street_text: 'Calle QA 1', commune_id: commune, lat, lng } });
    return r.json[0]?.id;
  };
  const petA = await mkPet(a);
  const catA = await mkPet(a, gato);
  const addrA = await mkAddr(a, -33.4569, -70.5974);
  const petB = await mkPet(b);
  const addrB = await mkAddr(b, -33.4569, -70.5974);
  const q = (o, extra = {}) => rpc('quote_visit', { p_pet_id: petA, p_address_id: addrA, p_specialty_id: general,
    p_mode: 'scheduled', p_vet_id: vet.id, ...extra }, o.token);

  // ---- 1. Manipulación de parámetros ----------------------------------------------------
  const ok = await q(a);
  check(ok.status === 200 && ok.json.base_price === 26990, `cotización base OK (${ok.status}, base ${ok.json.base_price})`);
  const bad = async (msg, extra, o = a) => { const r = await q(o, extra); check(r.status >= 400 && r.status < 500, `${msg} (HTTP ${r.status})`); };
  await bad('parámetro extra p_total rechazado', { p_total: 1 });
  await bad('mascota de otro dueño', { p_pet_id: petB });
  await bad('dirección de otro dueño', { p_address_id: addrB });
  await bad('vet pendiente', { p_vet_id: vetPend.id });
  await bad('vet aprobado sin la especialidad', { p_vet_id: vetNoSpec.id });
  await bad('vet incompatible con la especie (gato)', { p_pet_id: catA });
  await bad('vet inexistente', { p_vet_id: '00000000-0000-4000-8000-000000000000' });
  await bad('donación negativa', { p_extra_donation: -1 });
  await bad('donación sobre $1.000.000', { p_extra_donation: 1000001 });
  await bad('donación decimal', { p_extra_donation: 1.5 });
  await bad('donación entera enorme (overflow int4)', { p_extra_donation: 99999999999 });
  await bad('modo desconocido', { p_mode: 'URGENT' });
  await bad('fundación inactiva', { p_foundation_id: fZ });
  await bad('fundación inexistente', { p_foundation_id: '00000000-0000-4000-8000-000000000000' });
  const maxDon = await q(a, { p_extra_donation: 1000000 });
  check(maxDon.status === 200 && maxDon.json.total === maxDon.json.service_price + 1000000, 'donación tope $1.000.000 aceptada y sumada al total');
  const vetQ = await q(vet);
  check(vetQ.status >= 400, `un vet no cotiza (HTTP ${vetQ.status})`);
  const adminQ = await q(admin);
  check(adminQ.status >= 400, `el admin no cotiza (HTTP ${adminQ.status})`);
  const inactive = await mkAddr(a, -33.4569, -70.5974);
  await rest(`addresses?id=eq.${inactive}`, { method: 'PATCH', token: a.token, body: { active: false } });
  await bad('dirección desactivada', { p_address_id: inactive });

  // ---- 2. Cuadratura y redondeo (JS independiente) ----------------------------------------
  const sums = (s) => s.service_price === s.base_price - s.discount + s.urgent_surcharge + s.distance_surcharge
    && s.platform_fee + s.vet_payout === s.service_price && s.total === s.service_price + s.extra_donation
    && s.platform_fee === clp(s.service_price * 0.15) && s.foundation_share === clp(s.platform_fee * 0.20);
  const urg = await q(a, { p_mode: 'urgent', p_vet_id: null, p_extra_donation: 333 });
  check(urg.status === 200 && sums(urg.json) && urg.json.urgent_surcharge === clp(26990 * 0.3),
    `urgente sin vet: ${urg.json.service_price} = base + ${urg.json.urgent_surcharge}; comisión ${urg.json.platform_fee}, fundación ${urg.json.foundation_share}`);
  // Desde la corrección de QA-F5-01 la distancia se mide desde un origen
  // aproximado (base ± 1–2 km): los km facturables pueden diferir hasta en 2.
  check(sums(ok.json) && ok.json.distance_surcharge === ok.json.billable_km * 500
    && Math.abs(ok.json.billable_km - Math.max(0, Math.ceil(hav([-33.4569, -70.5974], SECRET) / 1000 - 5))) <= 2,
    `agendada con vet: km facturables ${ok.json.billable_km}, cuadra al peso`);
  const launch = (await q(a, { p_vet_id: null })).json;
  check(launch.service_price === 26990 && launch.platform_fee === 4049 && launch.foundation_share === 810 && launch.vet_payout === 22941,
    `precio de lanzamiento $26.990 → comisión ${launch.platform_fee}, fundación ${launch.foundation_share}, vet ${launch.vet_payout}`);

  // ---- 3. Privacidad de la base del vet ------------------------------------------------------
  for (const [who, u] of [['dueño', a], ['otro vet', vetFar], ['admin', admin], ['fundación', fx]]) {
    const r = await rest('vet_bases?select=lat,lng', { token: u.token });
    check(r.status === 200 && r.json.length === 0, `${who} no lee vet_bases`);
  }
  check(!('distance_m' in ok.json) && Number.isInteger(ok.json.distance_km)
    && Math.abs(ok.json.distance_km * 1000 - hav([-33.4569, -70.5974], SECRET)) <= 2500,
    `la respuesta de quote_visit solo trae distance_km redondeada (${ok.json.distance_km})`);
  const raw = await rest(`quotes?select=distance_m&id=eq.${ok.json.quote_id}`, { token: a.token });
  known(!(raw.json[0]?.distance_m > 0), 'QA-F5-01', `el dueño NO lee la distancia exacta en metros desde /quotes (obtiene ${raw.json[0]?.distance_m} m)`);
  const rawAdm = await rest(`quotes?select=distance_m&id=eq.${ok.json.quote_id}`, { token: admin.token });
  const rawStar = await rest(`quotes?select=*&id=eq.${ok.json.quote_id}`, { token: a.token });
  check(raw.status >= 400 && rawAdm.status >= 400 && rawStar.status >= 400,
    `distance_m no es legible ni por el dueño, ni por el admin, ni con select=* (HTTP ${raw.status}/${rawAdm.status}/${rawStar.status})`);
  // Trilateración con 3 direcciones propias, usando lo único que el dueño
  // recibe: distance_km (al km, desde el origen aproximado del vet).
  const pts = [[-33.4569, -70.5974], [-33.3800, -70.5000], [-33.4300, -70.5000]];
  const ds = [];
  for (const p of pts) {
    const id = p === pts[0] ? addrA : await mkAddr(a, p[0], p[1]);
    const qq = await q(a, { p_address_id: id });
    ds.push(qq.json.distance_km * 1000);
  }
  let best = null;
  if (ds.every((d) => d > 0)) {
    // Búsqueda en grilla fina alrededor del primer punto (radio 20 km).
    for (let dLat = -0.2; dLat <= 0.2; dLat += 0.0005) {
      for (let dLng = -0.2; dLng <= 0.2; dLng += 0.0005) {
        const cand = [-33.4569 + dLat, -70.5974 + dLng];
        const err = pts.reduce((s, p, i) => s + (hav(p, cand) - ds[i]) ** 2, 0);
        if (!best || err < best.err) best = { err, cand };
      }
    }
  }
  const leak = best ? hav(best.cand, SECRET) : Infinity;
  // Lo trilaterable es el origen aproximado (1–2 km de la base real): el
  // error mínimo garantizado es 1 km menos el error de redondeo del ajuste.
  // QA 26ac1c3: el ajuste con distancias al km tiene ruido propio, así que un
  // umbral sobre ese resultado es aleatorio. Se informa y se verifica la
  // garantía fuerte: aun conociendo EXACTAMENTE el origen aproximado (el mejor
  // atacante posible, simulado con la clave de servicio), la base real queda a
  // 1–2 km.
  console.log(`INFO    trilateración con distance_km: ${Math.round(leak)} m de la base real`);
  const origin = async (id) => {
    const r = (await rest(`vet_bases?select=lat,lng,fuzz_dlat,fuzz_dlng&vet_id=eq.${id}`, srv)).json[0];
    return { base: [r.lat, r.lng], orig: [r.lat + r.fuzz_dlat, r.lng + r.fuzz_dlng], fuzz: [r.fuzz_dlat, r.fuzz_dlng] };
  };
  const o1 = await origin(vet.id);
  const gap = hav(o1.orig, SECRET);
  check(gap >= 990 && gap <= 2010, `el origen exacto de cotización queda a ${Math.round(gap)} m de la base real (anillo 1–2 km)`);
  // Sin re-sorteo: el vet no borra ni recrea su base, ni toca el desplazamiento.
  const vDel = await rest(`vet_bases?vet_id=eq.${vet.id}`, { method: 'DELETE', token: vet.token });
  check(vDel.status === 403, `el vet no borra su base para sortear otro desplazamiento (HTTP ${vDel.status})`);
  const vFuzz = await rest(`vet_bases?vet_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, body: { fuzz_dlng: 0 } });
  check(vFuzz.status === 403, `el vet no modifica fuzz_dlng (HTTP ${vFuzz.status})`);
  const vOrig = await rest(`vet_bases?vet_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, body: { quote_origin: 'SRID=4326;POINT(-70.6 -33.4)' } });
  check(vOrig.status >= 400, `el vet no escribe quote_origin (HTTP ${vOrig.status})`);
  const vMove = await rest(`vet_bases?vet_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, body: { lat: SECRET[0] + 0.001 } });
  const o2 = await origin(vet.id);
  check(vMove.status < 300 && o2.fuzz[0] === o1.fuzz[0] && o2.fuzz[1] === o1.fuzz[1], 'mover la base no re-sortea el desplazamiento (no se puede promediar)');
  await rest(`vet_bases?vet_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, body: { lat: SECRET[0] } });
  const ownView = await rest('vet_bases?select=quote_origin,fuzz_dlat', { token: vet.token });
  check(ownView.json.length === 1, 'el propio vet ve su desplazamiento (dato suyo; nadie más lo ve)');

  // Base del vet sin validación geográfica (fuera de Chile / comuna incoherente).
  const mendoza = await rest('vet_bases', { method: 'POST', token: vetFar.token, body: { vet_id: vetFar.id, commune_id: nunoa, lat: -32.889, lng: -68.845 } });
  known(mendoza.status === 400, 'QA-F5-02', `vet_bases rechaza Mendoza con comuna Ñuñoa (HTTP ${mendoza.status})`);
  if (mendoza.status === 201) await rest(`vet_bases?vet_id=eq.${vetFar.id}`, { method: 'PATCH', token: vetFar.token, body: { commune_id: puntaArenas, lat: -53.1638, lng: -70.9171 } });
  else await rest('vet_bases', { method: 'POST', token: vetFar.token, body: { vet_id: vetFar.id, commune_id: puntaArenas, lat: -53.1638, lng: -70.9171 } });
  const far = await q(a, { p_vet_id: vetFar.id });
  known(far.status === 400 || far.json.distance_surcharge <= 50000, 'QA-F5-02',
    `una base a ~2.200 km no infla el recargo (HTTP ${far.status}, recargo $${far.json.distance_surcharge}, total $${far.json.total})`);
  const otherVetBase = await rest('vet_bases', { method: 'POST', token: vetFar.token, body: { vet_id: vet.id, commune_id: nunoa, lat: -33.4, lng: -70.6 } });
  check(otherVetBase.status === 403 || otherVetBase.status === 409, `un vet no crea la base de otro (HTTP ${otherVetBase.status})`);
  const ownerBase = await rest('vet_bases', { method: 'POST', token: a.token, body: { vet_id: a.id, commune_id: nunoa, lat: -33.4, lng: -70.6 } });
  check(ownerBase.status >= 400, `un dueño no crea vet_bases (HTTP ${ownerBase.status})`);

  // ---- 4. Pagos: escritura directa y RPC --------------------------------------------------
  // Desde la fase 6 se paga una VISITA completada (simulate_payment(p_visit_id)),
  // no una cotización suelta. La hora de la visita se adelanta por SQL (QA).
  await rest('vet_availability', { method: 'POST', ...srv, body: [1, 2, 3, 4, 5, 6, 7].map((d) => ({ vet_id: vet.id, weekday: d, start_min: 0, end_min: 1440 })) });
  const tomorrow = new Date(Date.now() + 24 * 3600 * 1000).toLocaleDateString('en-CA', { timeZone: 'America/Santiago' });
  const slots = ((await rpc('available_vets', { p_pet_id: petA, p_address_id: addrA, p_specialty_id: general, p_date: tomorrow }, a.token)).json ?? [])
    .find((v) => v.vet_id === vet.id)?.slots ?? [];
  check(slots.length >= 10, `el vet ofrece horarios mañana (${slots.length})`);
  let slotIdx = 0;
  const tr = (id, to, tok) => rpc('transition_visit', { p_visit_id: id, p_to_status: to }, tok);
  async function doneVisit(extra = {}) {
    const qq = (await q(a, extra)).json;
    const bk = await rpc('book_visit', { p_quote_id: qq.quote_id, p_vet_id: vet.id, p_pet_id: petA, p_address_id: addrA,
      p_scheduled_at: slots[slotIdx], p_notes: null }, a.token);
    slotIdx += 4;
    const id = bk.json.id;
    await tr(id, 'accepted', vet.token);
    // Fase 6 (QA-F6): el horario solo se mueve con felix.time_travel y
    // "completada" exige 10 min de atención.
    shiftVisit(sql, id, "now() + interval '30 minutes'");
    for (const s of ['en_route', 'arrived', 'in_progress']) await tr(id, s, vet.token);
    backdateStart(sql, id);
    await tr(id, 'completed', vet.token);
    return { id, quote: qq, booked: bk.status };
  }
  const v1 = await doneVisit({ p_extra_donation: 500 });
  const st1 = (await rest(`visits?select=status&id=eq.${v1.id}`, { token: a.token })).json[0]?.status;
  check(v1.booked === 200 && st1 === 'completed', `visita reservada y completada (book ${v1.booked}, estado ${st1})`);
  const writes = [
    ['INSERT payments', rest('payments', { method: 'POST', token: a.token, body: { owner_id: a.id, visit_id: v1.id, foundation_id: fX, kind: 'visit', service_price: 1, platform_fee: 0, foundation_share: 0, vet_payout: 1, extra_donation: 0, total: 1 } })],
    ['INSERT payment_events', rest('payment_events', { method: 'POST', token: a.token, body: { payment_id: '00000000-0000-4000-8000-000000000000', to_status: 'simulated_paid' } })],
    ['INSERT foundation_contributions (admin)', rest('foundation_contributions', { method: 'POST', token: admin.token, body: { payment_id: '00000000-0000-4000-8000-000000000000', foundation_id: fX, kind: 'donation', amount: 1 } })],
    ['PATCH quotes.consumed_at', rest(`quotes?id=eq.${v1.quote.quote_id}`, { method: 'PATCH', token: a.token, body: { consumed_at: null } })],
    ['PATCH quotes.total (admin)', rest(`quotes?id=eq.${v1.quote.quote_id}`, { method: 'PATCH', token: admin.token, body: { total: 1 } })],
    ['DELETE quotes', rest(`quotes?id=eq.${v1.quote.quote_id}`, { method: 'DELETE', token: a.token })],
  ];
  for (const [msg, p] of writes) { const r = await p; check(r.status === 403, `${msg} rechazado (HTTP ${r.status})`); }
  const oldContract = await rpc('simulate_payment', { p_quote_id: v1.quote.quote_id }, a.token);
  check(oldContract.status === 404, `ya no se paga una cotización suelta (contrato de la fase 5 retirado, HTTP ${oldContract.status})`);

  // Máximo 5 fallos; los fallos no marcan la visita como pagada.
  const fails5 = [];
  for (let i = 0; i < 6; i++) fails5.push((await rpc('simulate_payment', { p_visit_id: v1.id, p_simulate_failure: true }, a.token)).status);
  check(fails5.slice(0, 5).every((s) => s === 200) && fails5[5] === 400, `5 fallos aceptados y el 6.º rechazado (${fails5.join(',')})`);
  const paidFlag = ((await rpc('my_visits', {}, a.token)).json ?? []).find((v) => v.id === v1.id)?.paid;
  check(paidFlag === false, 'los fallos no dejan la visita pagada');

  // Doble pago concurrente sobre otra visita (la v1 agotó sus 5 intentos).
  const v1b = await doneVisit({ p_extra_donation: 500 });
  const race = await Promise.all(Array.from({ length: 10 }, () => rpc('simulate_payment', { p_visit_id: v1b.id }, a.token)));
  const paid = race.filter((r) => r.status === 200 && r.json.status === 'simulated_paid').length;
  const paidRows = (await rest(`payments?select=id,status&visit_id=eq.${v1b.id}&status=eq.simulated_paid`, { token: a.token })).json.length;
  const contrib = (await rest(`foundation_contributions?select=kind,amount&payment_id=in.(${race.filter((r) => r.status === 200).map((r) => r.json.payment_id).join(',') || '00000000-0000-4000-8000-000000000000'})`, { token: admin.token })).json;
  check(paid === 1 && paidRows === 1, `10 pagos paralelos: ${paid} pagado(s), ${paidRows} fila(s) simulated_paid`);
  check(contrib.length === 2 && contrib.some((x) => x.kind === 'donation' && x.amount === 500),
    `aportes generados una sola vez (${contrib.map((x) => `${x.kind}:${x.amount}`).join(', ')})`);
  const paidPay = race.find((r) => r.status === 200)?.json ?? {};
  check(paidPay.total === v1b.quote.total && paidPay.vet_payout === v1b.quote.vet_payout, 'el pago usa el precio congelado de la cotización');
  const afterPaidFail = await rpc('simulate_payment', { p_visit_id: v1b.id, p_simulate_failure: true }, a.token);
  check(afterPaidFail.status === 400, `fallo simulado sobre una visita pagada se rechaza (HTTP ${afterPaidFail.status})`);
  // Carrera fallo + pago.
  const v2 = await doneVisit();
  const mix = await Promise.all([true, false, true, false, true].map((f) => rpc('simulate_payment', { p_visit_id: v2.id, p_simulate_failure: f }, a.token)));
  const mixPaid = (await rest(`payments?select=status&visit_id=eq.${v2.id}`, { token: a.token })).json;
  check(mixPaid.filter((p) => p.status === 'simulated_paid').length === 1, `carrera fallo/pago: 1 pagado de ${mixPaid.length} intentos (${mix.map((r) => r.status).join(',')})`);
  // Ajena y por otros roles.
  const v3 = await doneVisit();
  check((await rpc('simulate_payment', { p_visit_id: v3.id }, b.token)).status === 400, 'B no paga una visita de A');
  check((await rpc('simulate_payment', { p_visit_id: v3.id }, vet.token)).status >= 400, 'un vet no paga');
  check((await rpc('simulate_payment', { p_visit_id: v3.id }, admin.token)).status >= 400, 'el admin no paga por el dueño');
  check((await rpc('simulate_payment', { p_visit_id: v3.id, p_total: 1 }, a.token)).status >= 400, 'simulate_payment no acepta montos');
  const pe = await rest(`payment_events?select=id`, { token: a.token });
  check(pe.json.length === 0, 'el dueño no lee payment_events');

  // ---- 5. Tope de 60 cotizaciones por hora (concurrente) ----------------------------------
  const petC = await mkPet(c);
  const addrC = await mkAddr(c, -33.4569, -70.5974);
  const burst = await Promise.all(Array.from({ length: 70 }, () => rpc('quote_visit', { p_pet_id: petC, p_address_id: addrC,
    p_specialty_id: general, p_mode: 'scheduled' }, c.token)));
  const okQ = burst.filter((r) => r.status === 200).length;
  const nC = (await rest('quotes?select=id', { token: c.token })).json.length;
  check(okQ === 60 && nC === 60, `70 cotizaciones paralelas: ${okQ} aceptadas, ${nC} guardadas (tope 60/h)`);

  // ---- 6. Fundaciones -------------------------------------------------------------------------
  const vX = await doneVisit({ p_foundation_id: fX, p_extra_donation: 700 });
  const qX = vX.quote;
  const payX = await rpc('simulate_payment', { p_visit_id: vX.id }, a.token);
  const sumX = await rpc('foundation_summary', {}, fx.token);
  const sumY = await rpc('foundation_summary', {}, fy.token);
  const mX = sumX.json[0] ?? {};
  check(payX.status === 200 && sumX.json.length === 1 && mX.commission_total === qX.foundation_share && mX.donation_total === 700
    && mX.total === qX.foundation_share + 700 && Object.keys(mX).sort().join(',') === 'commission_total,donation_total,month,total',
    `X ve solo su agregado mensual (comisión ${mX.commission_total}, donación ${mX.donation_total})`);
  check(sumY.status === 200 && sumY.json.length === 0, `Y no ve aportes de X (Y: ${sumY.json.length} meses)`);  for (const t of ['payments', 'quotes', 'foundation_contributions', 'payment_events', 'owner_profiles', 'pets', 'addresses', 'vet_bases']) {
    const r = await rest(`${t}?select=*&limit=5`, { token: fx.token });
    check(r.status >= 400 || (Array.isArray(r.json) && r.json.length === 0), `fundación X no lee ${t} (HTTP ${r.status}, ${Array.isArray(r.json) ? r.json.length : '-'} filas)`);
  }
  const membersX = await rest('foundation_members?select=user_id', { token: fx.token });
  check(membersX.json.length === 1 && membersX.json[0].user_id === fx.id, 'el miembro solo ve su propia membresía');
  const fxEdit = await rest(`foundations?id=eq.${fX}`, { method: 'PATCH', token: fx.token, prefer: 'return=representation', body: { name: 'Hack' } });
  check(fxEdit.status === 403 || (Array.isArray(fxEdit.json) && fxEdit.json.length === 0), `el miembro no edita su fundación (HTTP ${fxEdit.status})`);
  const fxAdd = await rest('foundation_members', { method: 'POST', token: fx.token, body: { user_id: fy.id, foundation_id: fX } });
  check(fxAdd.status === 403, `el miembro no agrega miembros (HTTP ${fxAdd.status})`);
  const fxDefault = await rpc('set_default_foundation', { p_foundation_id: fX }, fx.token);
  check(fxDefault.status >= 400, `el miembro no cambia la fundación por defecto (HTTP ${fxDefault.status})`);
  const seesZ = await rest(`foundations?select=id&id=eq.${fZ}`, { token: a.token });
  check(seesZ.json.length === 0, 'el dueño no ve fundaciones inactivas');
  const chooseZ = await rest(`owner_profiles?user_id=eq.${a.id}`, { method: 'PATCH', token: a.token, body: { foundation_id: fZ } });
  check(chooseZ.status === 400, `el dueño no elige una fundación inactiva (HTTP ${chooseZ.status})`);
  const chooseY = await rest(`owner_profiles?user_id=eq.${a.id}`, { method: 'PATCH', token: a.token, prefer: 'return=representation', body: { foundation_id: fY } });
  check(chooseY.status === 200, 'el dueño elige una fundación activa');
  const chooseOther = await rest(`owner_profiles?user_id=eq.${b.id}`, { method: 'PATCH', token: a.token, prefer: 'return=representation', body: { foundation_id: fY } });
  check(Array.isArray(chooseOther.json) && chooseOther.json.length === 0, 'A no cambia la fundación de B');
  await rest(`foundations?id=eq.${fY}`, { method: 'PATCH', token: admin.token, body: { active: false } });
  const fallback = (await q(a, { p_vet_id: null })).json;
  const def = (await rest('foundations?select=id&is_default=is.true', srv)).json[0].id;
  check(fallback.foundation_id === def, 'si la fundación elegida se desactiva, la cotización va a la por defecto');
  const deactDefault = await rest(`foundations?id=eq.${def}`, { method: 'PATCH', token: admin.token, body: { active: false } });
  check(deactDefault.status === 400, `no se desactiva la fundación por defecto (HTTP ${deactDefault.status})`);
  const sumYInactive = await rpc('foundation_summary', {}, fy.token);
  check(sumYInactive.status === 200, 'el miembro de una fundación desactivada aún consulta su resumen (sus aportes históricos)');
  const anonSum = await rpc('foundation_summary', {});
  check(anonSum.status === 401, `foundation_summary sin sesión rechazado (HTTP ${anonSum.status})`);
  const ownerSum = await rpc('foundation_summary', { p_months: 60 }, a.token);
  check(ownerSum.status === 200 && ownerSum.json.length === 0, 'un dueño no obtiene resúmenes');
} finally {
  for (const id of created) await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', ...srv });
}

console.log(fails ? `\nQA fase 5: ${fails} FALLAS, ${defects} defectos conocidos` :
  defects ? `\nQA fase 5: sin fallas; ${defects} defectos conocidos` : '\nQA fase 5: TODO OK');
process.exit(fails ? 1 : defects ? 2 : 0);
