// E2E de la fase 10 (suscripciones simuladas) contra Supabase local: Auth +
// REST, con el mismo contrato JSON que usa la app (SubscriptionRepository y
// Quote.fromJson).
// Uso: node tool/e2e/suscripciones_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
// Crea usuarios ficticios @test.local y los borra al final.
const st = JSON.parse(process.argv[2]);
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
  const owner = await newUser('dueno-f10');
  const vet = await newUser('vet-f10');
  const admin = await newUser('admin-f10');
  await call('/rest/v1/user_roles', { method: 'POST', key: SRV, token: SRV, body: { user_id: admin.id, role: 'admin' } });

  const sanMiguel = (await call('/rest/v1/communes?select=id&name=eq.San%20Miguel', { token: owner.token })).json[0].id;
  check((await register(owner, 'owner', 'Dueña Ficticia F10', sanMiguel)).status === 200, 'el dueño completa su registro');
  check((await register(vet, 'vet', 'Vet Ficticio F10')).status === 200, 'el vet completa su registro');

  const gato = (await call('/rest/v1/species?select=id&slug=eq.gato', { token: owner.token })).json[0].id;
  const general = (await call('/rest/v1/specialties?select=id&slug=eq.general', { token: owner.token })).json[0].id;
  const prevencion = (await call('/rest/v1/specialties?select=id&slug=eq.prevencion', { token: owner.token })).json[0]?.id;
  const mkPet = async (name) => (await call('/rest/v1/pets?select=id', { method: 'POST', token: owner.token,
    prefer: 'return=representation', body: { owner_id: owner.id, name, species_id: gato } })).json[0].id;
  const p1 = await mkPet('Minina');
  const p2 = await mkPet('Pelusa');
  const addr = (await call('/rest/v1/addresses?select=id', { method: 'POST', token: owner.token, prefer: 'return=representation',
    body: { owner_id: owner.id, label: 'Casa', street_text: 'Calle Ficticia 100', commune_id: sanMiguel, lat: -33.4970, lng: -70.6510 } })).json[0].id;
  const quote = (specialty, mode = 'scheduled') => rpc('quote_visit',
    { p_pet_id: p1, p_address_id: addr, p_specialty_id: specialty, p_mode: mode }, owner.token);

  // --- Catálogo (SELECT de la app) -------------------------------------------------------
  const plans = await call('/rest/v1/subscription_plans?select=id,slug,name,discount_pct,preventive_per_year,waive_urgent,max_pets,price_monthly&active=eq.true&order=sort,id', { token: owner.token });
  const bySlug = Object.fromEntries((plans.json ?? []).map((p) => [p.slug, p]));
  check(plans.status === 200 && bySlug.basico?.price_monthly === 4990 && bySlug.plus?.waive_urgent === true
    && bySlug.familia?.max_pets === 4, `el dueño lee los 3 planes (${plans.json?.length})`);

  const none = await rpc('my_subscription', {}, owner.token);
  check(none.status === 200 && none.json === null, 'sin plan, my_subscription es null');
  const before = (await quote(general)).json;
  check(before.plan === null && before.plan_subsidy === 0 && before.discount === 0,
    'sin plan la cotización no trae plan ni subsidio');

  // --- Contratar Básico -------------------------------------------------------------------
  const vetSub = await rpc('subscribe', { p_plan_id: bySlug.basico.id, p_pet_ids: [p1] }, vet.token);
  check(vetSub.status === 403 || vetSub.json?.code === '42501', `un vet no contrata planes (HTTP ${vetSub.status})`);
  const tooMany = await rpc('subscribe', { p_plan_id: bySlug.basico.id, p_pet_ids: [p1, p2] }, owner.token);
  check(tooMany.status === 400 && tooMany.json?.code === '22023', 'Básico rechaza 2 mascotas (22023)');

  const sub = await rpc('subscribe', { p_plan_id: bySlug.basico.id, p_pet_ids: [p1] }, owner.token);
  const s = sub.json;
  check(sub.status === 200 && s.status === 'active' && s.plan?.slug === 'basico' && s.renews === true
    && s.benefits_active === true && s.preventive_remaining === 1 && s.pets?.[0]?.pet_id === p1
    && typeof s.current_period_end === 'string', 'contrata Básico: la vista trae lo que lee la app');
  const again = await rpc('subscribe', { p_plan_id: bySlug.plus.id, p_pet_ids: [p1] }, owner.token);
  check(again.status === 400 && /activa/i.test(again.json?.message ?? ''), 'con un plan activo no contrata otro');

  // --- Beneficios en la cotización --------------------------------------------------------
  const q = (await quote(general)).json;
  check(q.plan?.name === 'Básico' && q.is_preventive === false && q.discount === Math.round(q.base_price * 0.10)
    && q.plan_subsidy === q.discount && q.service_price === q.base_price - q.discount,
    `descuento 10 %: base ${q.base_price} − ${q.discount} = ${q.service_price}`);
  check(q.vet_payout + q.platform_fee === q.service_price + q.plan_subsidy,
    'el vet y la comisión se calculan sobre el precio de lista');
  if (prevencion) {
    const pv = (await quote(prevencion)).json;
    check(pv.is_preventive === true && pv.discount === pv.base_price && pv.service_price === 0,
      `preventiva incluida: base ${pv.base_price} → $0 (sin vet aún, sin distancia)`);
  } else {
    check(false, 'existe la especialidad prevencion');
  }
  const urg = (await quote(general, 'urgent')).json;
  check(urg.plan?.name === 'Básico' && urg.urgent_surcharge > 0, 'Básico no omite el recargo de urgencia');

  // --- Mascotas, cancelar y volver a contratar -------------------------------------------
  const sp = await rpc('set_subscription_pets', { p_pet_ids: [p2] }, owner.token);
  check(sp.status === 200 && sp.json.pets?.length === 1 && sp.json.pets[0].pet_id === p2, 'cambia la mascota del plan');
  const q2 = (await quote(general)).json;
  check(q2.plan === null, 'la mascota que salió del plan ya no tiene descuento');

  const c = await rpc('cancel_subscription', {}, owner.token);
  check(c.status === 200 && c.json.status === 'cancelled' && c.json.renews === false && c.json.benefits_active === true,
    'cancelar: no se renueva y mantiene beneficios');
  const c2 = await rpc('cancel_subscription', {}, owner.token);
  check(c2.status === 400, 'no se cancela dos veces');

  const fam = await rpc('subscribe', { p_plan_id: bySlug.familia.id, p_pet_ids: [p1, p2] }, owner.token);
  check(fam.status === 200 && fam.json.plan?.slug === 'familia' && fam.json.pets?.length === 2,
    'con el plan cancelado contrata Familia con 2 mascotas');
  const u2 = (await quote(general, 'urgent')).json;
  check(u2.plan?.name === 'Familia' && u2.urgent_surcharge === 0 && u2.plan_subsidy > u2.discount,
    'Familia omite el recargo de urgencia (lo cubre Felix)');

  // --- Privacidad --------------------------------------------------------------------------
  const admSubs = await call('/rest/v1/subscriptions?select=id', { token: admin.token });
  check(admSubs.status !== 200 || admSubs.json.length === 0, 'el admin no lee suscripciones');
  const admPets = await call('/rest/v1/subscription_pets?select=pet_id', { token: admin.token });
  check(admPets.status !== 200 || admPets.json.length === 0, 'el admin no lee las mascotas del plan');
  const admMine = await rpc('my_subscription', {}, admin.token);
  check(admMine.json === null, 'my_subscription es null para otros roles');
  const pays = await call(`/rest/v1/payments?select=kind,total&kind=eq.subscription`, { token: owner.token });
  check(pays.status === 200 && pays.json.length === 2 && pays.json.some((p) => p.total === 4990)
    && pays.json.some((p) => p.total === 14990), `se registraron los 2 cobros simulados (${pays.json?.length})`);
} finally {
  for (const id of created) {
    await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
  }
}

console.log(fails === 0 ? '\nE2E fase 10: TODO OK' : `\nE2E fase 10: ${fails} fallas`);
process.exit(fails ? 1 : 0);
