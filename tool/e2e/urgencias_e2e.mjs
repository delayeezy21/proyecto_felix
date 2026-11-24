// E2E de la fase 8 (urgencias) contra Supabase local: Auth + REST + Edge
// Function send-push (PUSH_PROVIDER = "fake"), y SQL directo (docker exec)
// solo para simular el paso del tiempo y forzar una pasada del despacho.
// Uso: node tool/e2e/urgencias_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
// Crea usuarios ficticios y los borra al final.
import { backdateStart, sqlRunner, timeTravel } from './sql.mjs';

const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;
const sql = sqlRunner(st);

let fails = 0;
const check = (cond, msg) => { console.log(`${cond ? 'OK  ' : 'FALLA'} ${msg}`); if (!cond) fails++; };

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
const register = (u, role, name, communeId = null, phone = null) => rpc('complete_registration', {
  p_role: role, p_display_name: name, p_phone: phone,
  p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: communeId }, u.token);

// Dirección del dueño en Ñuñoa; vets a ~1 y ~2 km al norte.
const HOME = { lat: -33.4569, lng: -70.5974 };

try {
  const owner = await newUser('dueno-f8');
  const ownerFar = await newUser('dueno-lejos-f8');
  const vetA = await newUser('vet-a-f8');
  const vetB = await newUser('vet-b-f8');

  const nunoa = (await call('/rest/v1/communes?select=id&name=eq.%C3%91u%C3%B1oa', { token: owner.token })).json[0].id;
  const puntaArenas = (await call('/rest/v1/communes?select=id&name=eq.Punta%20Arenas', { token: owner.token })).json[0].id;
  check((await register(owner, 'owner', 'Ana Urgente', nunoa, '+56 9 3333 3333')).status === 200, 'el dueño completa su registro');
  check((await register(ownerFar, 'owner', 'Beto Austral', puntaArenas)).status === 200, 'el dueño lejano completa su registro');
  check((await register(vetA, 'vet', 'Dra. Rápida')).status === 200, 'el vet A completa su registro');
  check((await register(vetB, 'vet', 'Dr. Veloz')).status === 200, 'el vet B completa su registro');

  const perro = (await call('/rest/v1/species?select=id&slug=eq.perro', { token: owner.token })).json[0].id;
  const general = (await call('/rest/v1/specialties?select=id&slug=eq.general', { token: owner.token })).json[0].id;
  for (const u of [vetA, vetB]) {
    await svc(`/rest/v1/vet_profiles?user_id=eq.${u.id}`, { status: 'approved' }, 'PATCH');
    await svc('/rest/v1/vet_species', { vet_id: u.id, species_id: perro });
    await svc('/rest/v1/vet_specialties', { vet_id: u.id, specialty_id: general });
  }

  const mkPet = async (u) => (await call('/rest/v1/pets?select=id', { method: 'POST', token: u.token, prefer: 'return=representation',
    body: { owner_id: u.id, name: 'Rayo', species_id: perro } })).json[0].id;
  const mkAddr = async (u, commune, lat, lng) => (await call('/rest/v1/addresses?select=id', { method: 'POST', token: u.token,
    prefer: 'return=representation', body: { owner_id: u.id, label: 'Casa', street_text: 'Pasaje Ficticio 456',
      details: 'Casa 2', commune_id: commune, lat, lng } })).json[0].id;
  const pet = await mkPet(owner);
  const addr = await mkAddr(owner, nunoa, HOME.lat, HOME.lng);
  const petFar = await mkPet(ownerFar);
  const addrFar = await mkAddr(ownerFar, puntaArenas, -53.1638, -70.9171);

  // --- Presencia -----------------------------------------------------------------
  check((await rpc('set_vet_presence', { p_online: true, p_lat: HOME.lat, p_lng: HOME.lng }, owner.token)).status === 403,
    'un dueño no informa presencia');
  check((await rpc('set_vet_presence', { p_online: true, p_lat: HOME.lat + 0.009, p_lng: HOME.lng }, vetA.token)).status === 200,
    'el vet A se conecta');
  check((await rpc('set_vet_presence', { p_online: true, p_lat: HOME.lat + 0.018, p_lng: HOME.lng }, vetB.token)).status === 200,
    'el vet B se conecta');
  const presA = await call('/rest/v1/vet_presence?select=vet_id,online', { token: vetA.token });
  check(presA.status === 200 && presA.json.length === 1 && presA.json[0].vet_id === vetA.id, 'el vet ve solo su presencia');
  check((await call('/rest/v1/vet_presence?select=location', { token: vetA.token })).status >= 400,
    'la ubicación no se lee por la API');
  check(((await call('/rest/v1/vet_presence?select=vet_id', { token: owner.token })).json ?? []).length === 0,
    'el dueño no ve presencias');
  check((await call('/rest/v1/vet_presence', { method: 'POST', token: vetA.token,
    body: { vet_id: vetA.id, online: true } })).status >= 400, 'la presencia no se escribe directo');

  // --- Push: dispositivos ------------------------------------------------------------
  for (const [u, t, p] of [[owner, 'tok-e2e-owner-' + stamp, 'android'], [vetA, 'tok-e2e-vet-a-' + stamp, 'web'],
    [vetB, 'tok-e2e-vet-b-' + stamp, 'android']]) {
    check((await rpc('register_push_device', { p_token: t, p_platform: p }, u.token)).status === 200, 'se registra un dispositivo');
  }
  check((await rpc('register_push_device', { p_token: 'corto', p_platform: 'android' }, owner.token)).status === 400,
    'token inválido: rechazado');

  // --- Solicitud y ofertas ---------------------------------------------------------------
  const req = await rpc('request_urgent_visit', { p_pet_id: pet, p_address_id: addr, p_notes: 'Vomita desde anoche' }, owner.token);
  const v1 = req.json?.id;
  check(req.status === 200 && req.json.status === 'searching' && req.json.mode === 'urgent', 'el dueño pide una urgencia: buscando vet');
  check(req.json?.quote?.urgent_surcharge === 8097 && req.json?.quote?.max_total === 26990 + 8097 + 7500,
    `precio del servidor con recargo y tope (${req.json?.quote?.urgent_surcharge}, máx ${req.json?.quote?.max_total})`);
  const st1 = (await rpc('urgent_search_status', { p_visit_id: v1 }, owner.token)).json;
  check(st1?.pending_offers === 2 && st1?.radius_km === 5, `primera tanda a ≤ 5 km con los 2 vets (${JSON.stringify(st1)})`);

  const offA = (await rpc('my_offers', {}, vetA.token)).json ?? [];
  const offB = (await rpc('my_offers', {}, vetB.token)).json ?? [];
  check(offA.length === 1 && offB.length === 1 && offA[0].visit_id === v1, 'cada vet recibe su oferta');
  check(offA[0] && Object.keys(offA[0]).sort().join(',') ===
    'batch,commune_name,created_at,distance_km,expires_at,offer_id,service_price,specialty_name,species_name,vet_payout,visit_id',
    'la oferta no trae dirección, coordenadas, mascota ni nota');
  check(offA[0]?.distance_km === 1 && offB[0]?.distance_km === 2 && offA[0]?.commune_name === 'Ñuñoa',
    `distancia a 0,5 km y comuna (${offA[0]?.distance_km}, ${offB[0]?.distance_km})`);
  check(!JSON.stringify(offA).includes('Pasaje') && !JSON.stringify(offA).includes('Vomita'), 'sin calle ni nota en la oferta');
  check(((await call(`/rest/v1/visits?select=id&id=eq.${v1}`, { token: vetA.token })).json ?? []).length === 0,
    'el vet con oferta no lee la visita');
  check(((await call('/rest/v1/visit_offers?select=id', { token: owner.token })).json ?? []).length === 0,
    'el dueño no lee ofertas');
  check((await call('/rest/v1/visit_offers?select=distance_m', { token: vetA.token })).status >= 400,
    'la distancia exacta de la oferta no se lee');

  // --- Carrera: ambos aceptan a la vez ----------------------------------------------------
  const [ra, rb] = await Promise.all([
    rpc('accept_offer', { p_offer_id: offA[0].offer_id }, vetA.token),
    rpc('accept_offer', { p_offer_id: offB[0].offer_id }, vetB.token),
  ]);
  check([ra.status, rb.status].sort().join(',') === '200,400', `dos aceptan a la vez: gana uno (${ra.status}, ${rb.status})`);
  const [win, loser, lost] = ra.status === 200 ? [vetA, vetB, rb] : [vetB, vetA, ra];
  check(lost.json?.hint === 'offer_taken' && /ya fue tomada/.test(lost.json?.message ?? ''),
    `el otro recibe "ya tomada" (${lost.json?.message})`);
  const winView = (ra.status === 200 ? ra : rb).json;
  check(winView?.status === 'accepted' && winView?.exact?.street_text === 'Pasaje Ficticio 456' && winView?.exact?.owner_phone,
    'el vet asignado ve la dirección exacta y el teléfono');
  check(((await rpc('my_offers', {}, loser.token)).json ?? []).length === 0, 'al perdedor ya no le queda la oferta');
  const ownerView = ((await rpc('my_visits', {}, owner.token)).json ?? []).find((v) => v.id === v1);
  check(ownerView?.status === 'accepted' && ownerView?.vet_name && Number.isInteger(ownerView?.quote?.distance_km),
    `el dueño ve el vet asignado y el precio final (${ownerView?.quote?.total})`);

  // --- Push (proveedor fake) ----------------------------------------------------------------
  const push = await call('/functions/v1/send-push', { method: 'POST', key: SRV, token: SRV, body: {} });
  const delivered = push.json?.delivered ?? [];
  const events = delivered.filter((d) => d.data.visit_id === v1).map((d) => d.data.event);
  check(push.status === 200 && push.json.provider === 'fake', `send-push responde con el proveedor fake (HTTP ${push.status})`);
  check(events.includes('offer_new') && events.includes('visit_accepted') && events.includes('offer_taken'),
    `push de oferta, aceptación y "tomada" (${[...new Set(events)].join(', ')})`);
  check(delivered.every((d) => Object.keys(d.data).sort().join(',') === 'event,visit_id'), 'el payload lleva solo visit_id y evento');
  check(!JSON.stringify(push.json).includes('tok-e2e'), 'la respuesta no expone tokens');
  check((await call('/functions/v1/send-push', { method: 'POST', token: owner.token, body: {} })).status === 403,
    'un usuario no invoca send-push');

  // --- En camino, llegó, en curso, completada y pago -----------------------------------------
  const tr = (to, token) => rpc('transition_visit', { p_visit_id: v1, p_to_status: to }, token);
  check((await tr('en_route', loser.token)).status === 400, 'el perdedor no puede mover la visita');
  check((await tr('en_route', win.token)).status === 200, 'el vet sale: en camino');
  check((await tr('arrived', win.token)).status === 200, 'llegó');
  check((await tr('in_progress', win.token)).status === 200, 'en curso');
  backdateStart(sql, v1);
  check((await tr('completed', win.token)).status === 200, 'completada');
  const pay = await rpc('simulate_payment', { p_visit_id: v1 }, owner.token);
  check(pay.status === 200 && pay.json.status === 'simulated_paid' && pay.json.total === ownerView?.quote?.total,
    `pago simulado por el precio final (${pay.json?.total})`);

  // --- Sin vet: radio agotado (Punta Arenas) ------------------------------------------------
  const far = await rpc('request_urgent_visit', { p_pet_id: petFar, p_address_id: addrFar }, ownerFar.token);
  check(far.status === 200 && far.json.status === 'no_vet_found', `sin vets a 20 km: no_vet_found de inmediato (${far.json?.status})`);
  const farPays = await call(`/rest/v1/payments?select=id&visit_id=eq.${far.json?.id}`, { token: ownerFar.token });
  check((farPays.json ?? []).length === 0, 'no_vet_found no genera cobro');
  check(((await call('/rest/v1/emergency_clinics?select=id&limit=1', { token: ownerFar.token })).status === 200),
    'el dueño puede consultar clínicas 24 h');

  // --- Sin vet: 10 min ---------------------------------------------------------------------------
  const r2 = await rpc('request_urgent_visit', { p_pet_id: pet, p_address_id: addr }, owner.token);
  const v2 = r2.json?.id;
  check(r2.status === 200 && r2.json.status === 'searching', 'otra urgencia: buscando vet');
  timeTravel(sql, `update public.visits set confirm_deadline = now() - interval '1 second' where id = '${v2}'`);
  sql('select private.dispatch_urgent_visits()');
  const v2View = ((await rpc('my_visits', {}, owner.token)).json ?? []).find((v) => v.id === v2);
  check(v2View?.status === 'no_vet_found' && v2View?.closed_by_system === true && v2View?.cancel_fee === 0,
    'a los 10 min: no_vet_found, cerrada por el sistema y sin cargo');
  check(((await rpc('my_offers', {}, vetA.token)).json ?? []).length === 0
     && ((await rpc('my_offers', {}, vetB.token)).json ?? []).length === 0, 'las ofertas pendientes se cierran');

  // Desconexión: sin ubicación guardada.
  check((await rpc('set_vet_presence', { p_online: false }, vetA.token)).status === 200, 'el vet se desconecta');
  check(sql(`select location is null from public.vet_presence where vet_id = '${vetA.id}'`) === 't',
    'al desconectarse no queda la última posición');
} finally {
  for (const id of created) {
    await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
  }
}

console.log(fails === 0 ? '\nE2E fase 8: TODO OK' : `\nE2E fase 8: ${fails} fallas`);
process.exit(fails ? 1 : 0);
