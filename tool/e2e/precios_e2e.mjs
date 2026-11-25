// E2E de la fase 5 (precios, pagos simulados y fundaciones) contra Supabase
// local: Auth + REST.
// Uso: node tool/e2e/precios_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
// Crea usuarios y fundaciones ficticias. Al final borra los usuarios (los
// pagos quedan anonimizados y los aportes se conservan, como en producción).
import { backdateStart, shiftVisit, sqlRunner } from './sql.mjs';

const st = JSON.parse(process.argv[2]);
const sql = sqlRunner(st);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;

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

const stamp = Date.now();
const created = [];
async function newUser(tag) {
  const email = `${tag}-${stamp}@test.local`;
  const c = await call('/auth/v1/admin/users', { method: 'POST', key: SRV, token: SRV,
    body: { email, password: 'Felix2026', email_confirm: true } });
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

try {
  const ownerA = await newUser('dueno-a-f5');
  const ownerB = await newUser('dueno-b-f5');
  const vet = await newUser('vet-f5');
  const admin = await newUser('admin-f5');
  const fundX = await newUser('fund-x-f5');
  const fundY = await newUser('fund-y-f5');
  for (const [u, role] of [[admin, 'admin'], [fundX, 'foundation'], [fundY, 'foundation']]) {
    await call('/rest/v1/user_roles', { method: 'POST', key: SRV, token: SRV, body: { user_id: u.id, role } });
  }

  const nunoa = (await call('/rest/v1/communes?select=id&name=eq.%C3%91u%C3%B1oa', { token: ownerA.token })).json[0].id;
  check((await register(ownerA, 'owner', 'Ana Ficticia', nunoa)).status === 200, 'el dueño A completa su registro');
  check((await register(ownerB, 'owner', 'Beto Ficticio', nunoa)).status === 200, 'el dueño B completa su registro');
  check((await register(vet, 'vet', 'Dra. Ficticia')).status === 200, 'el vet completa su registro');

  const perro = (await call('/rest/v1/species?select=id&slug=eq.perro', { token: ownerA.token })).json[0].id;
  const general = (await call('/rest/v1/specialties?select=id&slug=eq.general', { token: ownerA.token })).json[0].id;

  // Vet aprobado (lo haría el admin) con especie, especialidad y punto de partida.
  await call(`/rest/v1/vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', key: SRV, token: SRV, body: { status: 'approved' } });
  await call('/rest/v1/vet_species', { method: 'POST', key: SRV, token: SRV, body: { vet_id: vet.id, species_id: perro } });
  await call('/rest/v1/vet_specialties', { method: 'POST', key: SRV, token: SRV, body: { vet_id: vet.id, specialty_id: general } });
  const badBase = await call('/rest/v1/vet_bases', { method: 'POST', token: vet.token,
    body: { vet_id: vet.id, commune_id: nunoa, lat: -33.3849, lng: -70.5974 } });
  check(badBase.status === 400, `la base del vet debe coincidir con su comuna (HTTP ${badBase.status})`);
  const baseCommune = (await rpc('communes_at_point', { p_lat: -33.3849, p_lng: -70.5974 }, vet.token)).json[0].commune_id;
  const base = await call('/rest/v1/vet_bases', { method: 'POST', token: vet.token,
    body: { vet_id: vet.id, commune_id: baseCommune, lat: -33.3849, lng: -70.5974 } });
  check(base.status === 201, `el vet define su punto de partida (HTTP ${base.status})`);
  const fuzzPatch = await call(`/rest/v1/vet_bases?vet_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, body: { fuzz_dlat: 0 } });
  check(fuzzPatch.status >= 400, `el vet no anula su desplazamiento aleatorio (HTTP ${fuzzPatch.status})`);
  // Fase 6: disponible todo el día para reservar y completar una visita.
  await call('/rest/v1/vet_availability', { method: 'POST', key: SRV, token: SRV,
    body: [1, 2, 3, 4, 5, 6, 7].map((d) => ({ vet_id: vet.id, weekday: d, start_min: 0, end_min: 1440 })) });
  // Para montos deterministas, el E2E (service role) anula el desplazamiento.
  await call(`/rest/v1/vet_bases?vet_id=eq.${vet.id}`, { method: 'PATCH', key: SRV, token: SRV, body: { fuzz_dlat: 0, fuzz_dlng: 0 } });

  // Parte de la configuración por defecto (el E2E se puede repetir: cada
  // corrida publica versiones nuevas y la última es la vigente).
  const base0 = await call('/rest/v1/pricing_config', { method: 'POST', token: admin.token, body: {
    commission_pct: 15, foundation_pct: 20, urgent_pct: 30, per_km: 500, free_km: 5, cancel_fee: 5000,
    created_by: admin.id, effective_from: new Date(Date.now() - 1000).toISOString() } });
  check(base0.status === 201, 'parámetros por defecto vigentes (15 / 20 / 30 / $500 / 5 km)');

  // --- Admin: fundaciones ------------------------------------------------------------
  const mkF = async (name) => (await call('/rest/v1/foundations?select=id', { method: 'POST', token: admin.token,
    prefer: 'return=representation', body: { name, description: 'Ficticia (E2E)' } })).json[0]?.id;
  const fX = await mkF(`E2E Fundación X ${stamp}`);
  const fY = await mkF(`E2E Fundación Y ${stamp}`);
  check(fX && fY, 'el admin crea fundaciones');
  check((await rpc('set_default_foundation', { p_foundation_id: fX }, admin.token)).status < 300,
    'el admin define la fundación por defecto');
  const ownerCreatesF = await call('/rest/v1/foundations', { method: 'POST', token: ownerA.token, body: { name: `Pirata ${stamp}` } });
  check(ownerCreatesF.status === 403, `un dueño no crea fundaciones (HTTP ${ownerCreatesF.status})`);
  const ownerDefault = await rpc('set_default_foundation', { p_foundation_id: fY }, ownerA.token);
  check(ownerDefault.status >= 400, `un dueño no cambia la fundación por defecto (HTTP ${ownerDefault.status})`);
  for (const [u, f] of [[fundX, fX], [fundY, fY]]) {
    const m = await call('/rest/v1/foundation_members', { method: 'POST', token: admin.token, body: { user_id: u.id, foundation_id: f } });
    check(m.status === 201, `el admin agrega un miembro de fundación (HTTP ${m.status})`);
  }

  // --- Dueño A: mascota, dirección y cotización -----------------------------------------
  const pet = (await call('/rest/v1/pets?select=id', { method: 'POST', token: ownerA.token, prefer: 'return=representation',
    body: { owner_id: ownerA.id, name: 'Firulais', species_id: perro } })).json[0].id;
  const addr = (await call('/rest/v1/addresses?select=id', { method: 'POST', token: ownerA.token, prefer: 'return=representation',
    body: { owner_id: ownerA.id, label: 'Casa', street_text: 'Av. Ficticia 123', commune_id: nunoa, lat: -33.4569, lng: -70.5974 } })).json[0].id;

  const q = await rpc('quote_visit', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general,
    p_mode: 'scheduled', p_vet_id: vet.id, p_extra_donation: 1000 }, ownerA.token);
  const qj = q.json;
  check(q.status === 200 && qj.base_price === 26990 && qj.billable_km === 3 && qj.distance_surcharge === 1500
    && qj.service_price === 28490 && qj.platform_fee === 4274 && qj.foundation_share === 855
    && qj.vet_payout === 24216 && qj.extra_donation === 1000 && qj.total === 29490,
    `cotización correcta: consulta general 26.990 + 3 km (PostGIS) → total ${qj.total}`);
  check(qj.foundation_id === fX, 'sin elección, la cotización va a la fundación por defecto');
  check(qj.distance_km === 8, `el cliente ve la distancia redondeada al km (${qj.distance_km})`);

  const urg = (await rpc('quote_visit', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_mode: 'urgent' }, ownerA.token)).json;
  check(urg.urgent_surcharge === 8097 && urg.distance_km === null && urg.total === 35087,
    'urgencia: recargo 30 % y distancia pendiente sin vet');

  // --- El cliente no puede manipular el precio --------------------------------------------
  const extraArg = await rpc('quote_visit', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general,
    p_mode: 'scheduled', p_total: 1 }, ownerA.token);
  check(extraArg.status >= 400, `quote_visit rechaza montos enviados por el cliente (HTTP ${extraArg.status})`);
  const insQuote = await call('/rest/v1/quotes', { method: 'POST', token: ownerA.token, body: {
    owner_id: ownerA.id, species_id: perro, specialty_id: general, commune_id: nunoa, mode: 'scheduled',
    pricing_config_id: 1, foundation_id: fX, base_price: 1, urgent_surcharge: 0, billable_km: 0,
    distance_surcharge: 0, discount: 0, service_price: 1, platform_fee: 0, foundation_share: 0,
    vet_payout: 1, extra_donation: 0, total: 1, expires_at: '2099-01-01T00:00:00Z' } });
  check(insQuote.status === 403, `no se inserta una cotización a mano (HTTP ${insQuote.status})`);
  const patchQuote = await call(`/rest/v1/quotes?id=eq.${qj.quote_id}`, { method: 'PATCH', token: ownerA.token, body: { total: 1 } });
  check(patchQuote.status === 403, `no se modifica el total de una cotización (HTTP ${patchQuote.status})`);
  const insPay = await call('/rest/v1/payments', { method: 'POST', token: ownerA.token, body: {
    owner_id: ownerA.id, foundation_id: fX, kind: 'visit', status: 'simulated_paid', service_price: 1,
    platform_fee: 0, foundation_share: 0, vet_payout: 1, extra_donation: 0, total: 1 } });
  check(insPay.status === 403, `no se inserta un pago a mano (HTTP ${insPay.status})`);
  const internal = await rpc('price_breakdown', { p_base: 1 }, ownerA.token);
  check(internal.status >= 400, `el cálculo interno no está en la API (HTTP ${internal.status})`);
  const anonQuote = await rpc('quote_visit', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_mode: 'scheduled' });
  check(anonQuote.status >= 400, `un anónimo no cotiza (HTTP ${anonQuote.status})`);
  const vetQuote = await rpc('quote_visit', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_mode: 'scheduled' }, vet.token);
  check(vetQuote.status >= 400, `un vet no cotiza (HTTP ${vetQuote.status})`);
  const bQuote = await rpc('quote_visit', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_mode: 'scheduled' }, ownerB.token);
  check(bQuote.status === 400, 'el dueño B no cotiza con la mascota de A');

  // --- Precio congelado: el admin cambia la configuración -------------------------------------
  const cfg = await call('/rest/v1/pricing_config', { method: 'POST', token: admin.token, body: {
    commission_pct: 20, foundation_pct: 50, urgent_pct: 40, per_km: 800, free_km: 2, cancel_fee: 6000, created_by: admin.id } });
  check(cfg.status === 201, 'el admin publica una nueva versión de parámetros');

  // --- Pago simulado (fase 6: solo de una visita completada) --------------------------------
  const payQuote = await rpc('simulate_payment', { p_visit_id: qj.quote_id }, ownerA.token);
  check(payQuote.status === 400, 'ya no se paga una cotización suelta (solo visitas completadas)');
  const tomorrow = new Date(Date.now() + 24 * 3600 * 1000).toLocaleDateString('en-CA', { timeZone: 'America/Santiago' });
  const slot = (await rpc('available_vets', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_date: tomorrow },
    ownerA.token)).json.find((v) => v.vet_id === vet.id)?.slots?.[0];
  const booked = await rpc('book_visit', { p_quote_id: qj.quote_id, p_vet_id: vet.id, p_pet_id: pet,
    p_address_id: addr, p_scheduled_at: slot }, ownerA.token);
  const visitId = booked.json?.id;
  check(booked.status === 200 && booked.json.quote.total === 29490, 'la visita reservada congela el precio de la cotización');
  const early = await rpc('simulate_payment', { p_visit_id: visitId }, ownerA.token);
  check(early.status === 400, 'no se paga antes de completar la visita');
  const tr = (to) => rpc('transition_visit', { p_visit_id: visitId, p_to_status: to }, vet.token);
  await tr('accepted');
  // Paso del tiempo (SQL directo, solo stacks locales): empieza en 20 min.
  shiftVisit(sql, visitId, "date_trunc('minute', now()) + interval '20 minutes'");
  for (const s of ['en_route', 'arrived', 'in_progress']) await tr(s);
  backdateStart(sql, visitId);
  await tr('completed');
  const fakeAmount = await rpc('simulate_payment', { p_visit_id: visitId, p_total: 1 }, ownerA.token);
  check(fakeAmount.status >= 400, 'simulate_payment no acepta montos');
  const failed = await rpc('simulate_payment', { p_visit_id: visitId, p_simulate_failure: true }, ownerA.token);
  check(failed.json.status === 'simulated_failed', 'se puede simular un pago rechazado');
  const bPays = await rpc('simulate_payment', { p_visit_id: visitId }, ownerB.token);
  check(bPays.status === 400, 'el dueño B no paga una visita de A');
  const pay = await rpc('simulate_payment', { p_visit_id: visitId }, ownerA.token);
  check(pay.status === 200 && pay.json.status === 'simulated_paid' && pay.json.platform_fee === 4274 && pay.json.total === 29490,
    'el pago simulado usa el precio congelado aunque cambió la configuración');
  const again = await rpc('simulate_payment', { p_visit_id: visitId }, ownerA.token);
  check(again.status === 400, 'una visita no se paga dos veces');
  const myPays = await call('/rest/v1/payments?select=id,status,total,provider', { token: ownerA.token });
  check(myPays.json.length === 2 && myPays.json.every((p) => p.provider === 'simulated'),
    'el dueño A ve sus pagos, todos simulados');
  // QA-F11-05 (HU8.6): sin filas de payments; sus liquidaciones por my_payouts.
  const vetPays = await call('/rest/v1/payments?select=id', { token: vet.token });
  const vetPayouts = await rpc('my_payouts', {}, vet.token);
  check(vetPays.json.length === 0 && vetPayouts.json?.length === 2,
    'el vet no lee payments y ve solo las liquidaciones de su visita (my_payouts)');

  // --- Otros roles no ven pagos ajenos ---------------------------------------------------------
  for (const [who, u] of [['el dueño B', ownerB], ['la fundación X', fundX]]) {
    const p = await call('/rest/v1/payments?select=id', { token: u.token });
    const qq = await call('/rest/v1/quotes?select=id', { token: u.token });
    check(p.status === 200 && p.json.length === 0 && qq.json.length === 0, `${who} no ve pagos ni cotizaciones ajenas`);
  }
  const anonPay = await call('/rest/v1/payments?select=id');
  check(anonPay.status >= 400, `un anónimo no lee pagos (HTTP ${anonPay.status})`);

  // --- Fundación: solo agregados ---------------------------------------------------------------
  const rowsX = await call('/rest/v1/foundation_contributions?select=*', { token: fundX.token });
  check(rowsX.status === 200 && rowsX.json.length === 0, 'la fundación no ve filas de aportes');
  const ownersX = await call('/rest/v1/owner_profiles?select=display_name', { token: fundX.token });
  check(ownersX.json.length === 0, 'la fundación no ve datos de dueños');
  const sumX = await rpc('foundation_summary', {}, fundX.token);
  const m = sumX.json[0] ?? {};
  check(sumX.status === 200 && sumX.json.length === 1 && m.commission_total === 855 && m.donation_total === 1000 && m.total === 1855,
    `la fundación X ve su total del mes: comisión 855 + donación 1.000 (${JSON.stringify(sumX.json)})`);
  check(Object.keys(m).sort().join(',') === 'commission_total,donation_total,month,total',
    'el resumen solo trae mes y montos (sin dueños ni pagos)');
  const sumY = await rpc('foundation_summary', {}, fundY.token);
  check(sumY.status === 200 && sumY.json.length === 0, 'la fundación Y no ve los aportes de X');
  const sumOwner = await rpc('foundation_summary', {}, ownerA.token);
  check(sumOwner.json.length === 0, 'un dueño no obtiene resúmenes de fundaciones');

  // --- Dueño elige su fundación ------------------------------------------------------------------
  const choose = await call(`/rest/v1/owner_profiles?user_id=eq.${ownerA.id}`, { method: 'PATCH', token: ownerA.token,
    prefer: 'return=representation', body: { foundation_id: fY } });
  check(choose.status === 200 && choose.json[0]?.foundation_id === fY, 'el dueño A elige la fundación Y en su perfil');
  const qY = (await rpc('quote_visit', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_mode: 'scheduled' }, ownerA.token)).json;
  check(qY.foundation_id === fY && qY.platform_fee === 5398,
    `la nueva cotización va a Y y usa la versión vigente (26.990 × 20 % = ${qY.platform_fee})`);

  // --- Admin ---------------------------------------------------------------------------------------
  const admPays = await call('/rest/v1/payments?select=id', { token: admin.token });
  const admContrib = await call(`/rest/v1/foundation_contributions?select=kind,amount&foundation_id=eq.${fX}`, { token: admin.token });
  check(admPays.json.length >= 2 && admContrib.json.length === 2, 'el admin audita pagos y aportes');
} finally {
  for (const id of created) {
    await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
  }
}

console.log(fails === 0 ? '\nE2E fase 5: TODO OK' : `\nE2E fase 5: ${fails} fallas`);
process.exit(fails ? 1 : 0);
