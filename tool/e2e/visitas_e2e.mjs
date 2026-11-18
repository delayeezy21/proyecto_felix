// E2E de la fase 6 (visitas agendadas) contra Supabase local: Auth + REST,
// y SQL directo (docker exec) solo para simular el paso del tiempo.
// Uso: node tool/e2e/visitas_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
// Crea usuarios ficticios y los borra al final.
import { sqlRunner } from './sql.mjs';

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

// Hora de Chile para "mañana".
const tomorrow = new Date(Date.now() + 24 * 3600 * 1000)
  .toLocaleDateString('en-CA', { timeZone: 'America/Santiago' });
const shift = (visitId, expr) => sql(`update public.visits set scheduled_at = ${expr},
  slot = tstzrange(${expr}, ${expr} + interval '90 minutes') where id = '${visitId}'`);

try {
  const ownerA = await newUser('dueno-a-f6');
  const ownerB = await newUser('dueno-b-f6');
  const vet = await newUser('vet-f6');
  const vetCat = await newUser('vet-gatos-f6');
  const admin = await newUser('admin-f6');
  await svc('/rest/v1/user_roles', { user_id: admin.id, role: 'admin' });

  const nunoa = (await call('/rest/v1/communes?select=id&name=eq.%C3%91u%C3%B1oa', { token: ownerA.token })).json[0].id;
  check((await register(ownerA, 'owner', 'Ana Ficticia', nunoa, '+56 9 1111 1111')).status === 200, 'el dueño A completa su registro');
  check((await register(ownerB, 'owner', 'Beto Ficticio', nunoa)).status === 200, 'el dueño B completa su registro');
  check((await register(vet, 'vet', 'Dra. Agenda')).status === 200, 'el vet completa su registro');
  check((await register(vetCat, 'vet', 'Dr. Gatuno')).status === 200, 'el vet de gatos completa su registro');

  const sp = async (slug) => (await call(`/rest/v1/species?select=id&slug=eq.${slug}`, { token: ownerA.token })).json[0].id;
  const perro = await sp('perro');
  const gato = await sp('gato');
  const general = (await call('/rest/v1/specialties?select=id&slug=eq.general', { token: ownerA.token })).json[0].id;

  // Vets aprobados (lo haría el admin), disponibles todo el día, todos los días.
  for (const [u, species] of [[vet, perro], [vetCat, gato]]) {
    await svc(`/rest/v1/vet_profiles?user_id=eq.${u.id}`, { status: 'approved' }, 'PATCH');
    await svc('/rest/v1/vet_species', { vet_id: u.id, species_id: species });
    await svc('/rest/v1/vet_specialties', { vet_id: u.id, specialty_id: general });
    await svc('/rest/v1/vet_availability', [1, 2, 3, 4, 5, 6, 7].map((d) => ({ vet_id: u.id, weekday: d, start_min: 0, end_min: 1440 })));
  }
  const baseCommune = (await rpc('communes_at_point', { p_lat: -33.3849, p_lng: -70.5974 }, vet.token)).json[0].commune_id;
  for (const u of [vet, vetCat]) {
    const b = await call('/rest/v1/vet_bases', { method: 'POST', token: u.token,
      body: { vet_id: u.id, commune_id: baseCommune, lat: -33.3849, lng: -70.5974 } });
    check(b.status === 201, `el vet define su punto de partida (HTTP ${b.status})`);
  }

  const pet = (await call('/rest/v1/pets?select=id', { method: 'POST', token: ownerA.token, prefer: 'return=representation',
    body: { owner_id: ownerA.id, name: 'Firulais', species_id: perro } })).json[0].id;
  const mkAddr = async (label, lat, lng) => (await call('/rest/v1/addresses?select=id', { method: 'POST', token: ownerA.token,
    prefer: 'return=representation', body: { owner_id: ownerA.id, label, street_text: `Av. Ficticia ${label}`,
      details: 'Depto 4', commune_id: nunoa, lat, lng } })).json[0].id;
  const addr = await mkAddr('Casa', -33.4569, -70.5974);
  const addr2 = await mkAddr('Trabajo', -33.4560, -70.5980);

  // --- Disponibilidad ---------------------------------------------------------------
  const av = await rpc('available_vets', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_date: tomorrow }, ownerA.token);
  const mine = (av.json ?? []).find((v) => v.vet_id === vet.id);
  check(av.status === 200 && mine && !(av.json ?? []).some((v) => v.vet_id === vetCat.id),
    'available_vets muestra el vet compatible y no al de otra especie');
  check(mine && Object.keys(mine).sort().join(',') === 'bio,display_name,distance_km,slots,vet_id',
    'del vet solo llegan datos públicos');
  check(mine && Number.isInteger(mine.distance_km) && mine.distance_km >= 6 && mine.distance_km <= 10,
    `distancia redondeada al km desde el origen aproximado (${mine?.distance_km} km)`);
  const slots = mine?.slots ?? [];
  check(slots.length >= 30, `ofrece horarios mañana (${slots.length})`);
  const at = (i) => slots[i];
  const avVet = await rpc('available_vets', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_date: tomorrow }, vet.token);
  check(avVet.status === 403, `un vet no busca veterinarios (HTTP ${avVet.status})`);

  const quote = async (vetId = vet.id, token = ownerA.token) => (await rpc('quote_visit', {
    p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_mode: 'scheduled', p_vet_id: vetId }, token)).json;
  const book = (q, when, extra = {}, token = ownerA.token) => rpc('book_visit', {
    p_quote_id: q.quote_id, p_vet_id: vet.id, p_pet_id: pet, p_address_id: addr, p_scheduled_at: when, ...extra }, token);
  const mv = async (id, token) => ((await rpc('my_visits', {}, token)).json ?? []).find((v) => v.id === id);
  const tr = (id, to, token, reason = null) => rpc('transition_visit', { p_visit_id: id, p_to_status: to, p_reason: reason }, token);

  // --- Reserva -----------------------------------------------------------------------
  const q1 = await quote();
  const mismatch = await book(q1, at(0), { p_address_id: addr2 });
  check(mismatch.status === 400 && /no coincide/.test(mismatch.json.message), 'O-1: no se reserva con otra dirección que la cotizada');
  const otherVet = await book(q1, at(0), { p_vet_id: vetCat.id });
  check(otherVet.status === 400, 'O-1: no se reserva con otro vet que el cotizado');
  const noVet = await book(await quote(null), at(0));
  check(noVet.status === 400 && /con veterinario/.test(noVet.json.message), 'una cotización agendada sin vet no se reserva');
  const r1 = await book(q1, at(0), { p_notes: 'Control anual' });
  const v1 = r1.json?.id;
  check(r1.status === 200 && r1.json.status === 'pending_vet', 'el dueño reserva: queda esperando al vet');
  check(r1.json?.quote?.quote_id === q1.quote_id && r1.json?.quote?.total === q1.total, 'el precio queda congelado en la visita');
  check((await book(q1, at(6))).status === 400, 'una cotización no se reserva dos veces');

  // Solapes.
  const overlap = await book(await quote(), at(1));
  check(overlap.status === 400 && /no está disponible/.test(overlap.json.message), 'no se reserva un horario que se solapa (traslado incluido)');
  const [ra, rb] = await Promise.all([book(await quote(), at(12)), book(await quote(), at(12))]);
  check([ra.status, rb.status].sort().join(',') === '200,400', `reservas simultáneas del mismo horario: gana una (${ra.status}, ${rb.status})`);
  const vRace = (ra.status === 200 ? ra : rb).json.id;
  const av2 = await rpc('available_vets', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_date: tomorrow }, ownerA.token);
  const slots2 = av2.json.find((v) => v.vet_id === vet.id)?.slots ?? [];
  check(!slots2.includes(at(0)) && !slots2.includes(at(12)), 'los horarios reservados dejan de ofrecerse');

  // --- Accesos indebidos --------------------------------------------------------------
  check(((await rpc('my_visits', {}, ownerB.token)).json ?? []).length === 0, 'el dueño B no ve visitas de A');
  const bCancel = await tr(v1, 'cancelled_owner', ownerB.token);
  check(bCancel.status === 400 && bCancel.json.message === 'La visita no existe', 'el dueño B no cancela una visita de A');
  check((await tr(v1, 'accepted', vetCat.token)).status === 400, 'otro vet no confirma una visita ajena');
  check((await tr(v1, 'accepted', ownerA.token)).status === 403, 'el dueño no confirma su propia visita');
  check((await rpc('my_visits', {})).status === 401, 'un anónimo no lee visitas');
  const patch = await call(`/rest/v1/visits?id=eq.${v1}`, { method: 'PATCH', token: ownerA.token, body: { status: 'completed' } });
  check(patch.status >= 400, `nadie cambia el estado con un update directo (HTTP ${patch.status})`);
  const ins = await call('/rest/v1/visits', { method: 'POST', token: ownerA.token, body: { mode: 'scheduled', status: 'completed' } });
  check(ins.status >= 400, `nadie inserta visitas a mano (HTTP ${ins.status})`);
  const quoteCol = await call(`/rest/v1/visits?select=quote&id=eq.${v1}`, { token: vet.token });
  check(quoteCol.status >= 400, `el precio (y la donación) no se lee directo de visits (HTTP ${quoteCol.status})`);
  check(((await call('/rest/v1/addresses?select=id', { token: vet.token })).json ?? []).length === 0, 'el vet no lee direcciones');
  const prePay = await rpc('simulate_payment', { p_visit_id: v1 }, ownerA.token);
  check(prePay.status === 400 && /completada/.test(prePay.json.message), 'no se paga antes de completar');
  const payQuote = await rpc('simulate_payment', { p_visit_id: q1.quote_id }, ownerA.token);
  check(payQuote.status === 400, 'ya no se paga una cotización suelta');

  // --- Vet: dirección aproximada → exacta solo asignado y activo -----------------------
  let vv = await mv(v1, vet.token);
  check(vv && vv.exact === null && vv.commune_name === 'Ñuñoa' && typeof vv.distance_km === 'number',
    'con la solicitud pendiente el vet ve solo comuna y distancia');
  check(vv && !('quote' in vv) && !('address_text' in vv), 'el vet no ve el precio completo ni la dirección');
  const bad = await tr(v1, 'en_route', vet.token);
  check(bad.status === 400 && /pending_vet → en_route/.test(bad.json.message), 'transición inválida con error explícito');
  check((await tr(v1, 'accepted', vet.token)).json?.status === 'accepted', 'el vet confirma');
  vv = await mv(v1, vet.token);
  check(vv?.exact?.street_text === 'Av. Ficticia Casa' && vv?.exact?.owner_phone === '+56 9 1111 1111',
    'confirmada, el vet asignado ve la dirección exacta y el teléfono');
  check(((await mv(v1, vetCat.token)) ?? null) === null, 'otro vet no ve la visita');
  const early = await tr(v1, 'en_route', vet.token);
  check(early.status === 400 && /2 horas antes/.test(early.json.message), 'no puede salir con un día de anticipación');
  check((await tr(v1, 'completed', vet.token)).status === 400, 'no se salta estados (accepted → completed)');

  // Paso del tiempo: la visita empieza en 1 h.
  shift(v1, "date_trunc('minute', now()) + interval '1 hour'");
  for (const s of ['en_route', 'arrived', 'in_progress', 'completed']) {
    const r = await tr(v1, s, vet.token);
    check(r.json?.status === s, `el vet avanza a ${s}`);
  }
  vv = await mv(v1, vet.token);
  check(vv && vv.exact === null, 'cerrada la visita, el vet vuelve a ver solo lo aproximado');
  check((await tr(v1, 'in_progress', vet.token)).status === 400, 'una visita completada no se reabre');

  // --- Pago solo al completar -----------------------------------------------------------
  check((await rpc('simulate_payment', { p_visit_id: v1 }, ownerB.token)).status === 400, 'el dueño B no paga la visita de A');
  check((await rpc('simulate_payment', { p_visit_id: v1 }, vet.token)).status === 403, 'el vet no paga');
  const fail = await rpc('simulate_payment', { p_visit_id: v1, p_simulate_failure: true }, ownerA.token);
  check(fail.json?.status === 'simulated_failed', 'se simula un pago rechazado');
  const pay = await rpc('simulate_payment', { p_visit_id: v1 }, ownerA.token);
  check(pay.status === 200 && pay.json.status === 'simulated_paid' && pay.json.total === q1.total,
    `pago simulado por el precio congelado ($${pay.json?.total})`);
  check((await rpc('simulate_payment', { p_visit_id: v1 }, ownerA.token)).status === 400, 'una visita no se paga dos veces');
  check((await mv(v1, ownerA.token))?.paid === true, 'el dueño ve la visita pagada');
  const vetPays = await call(`/rest/v1/payments?select=kind,status,vet_payout&visit_id=eq.${v1}`, { token: vet.token });
  check(vetPays.json.length === 2 && vetPays.json.some((p) => p.status === 'simulated_paid'), 'el vet ve los pagos de su visita');
  check(((await call('/rest/v1/payments?select=id', { token: vetCat.token })).json ?? []).length === 0, 'otro vet no ve esos pagos');

  // --- Cancelaciones ------------------------------------------------------------------
  const v3 = (await book(await quote(), at(18))).json.id;
  await tr(v3, 'accepted', vet.token);
  check((await mv(v3, ownerA.token))?.cancel_fee_now === 0, 'más de 2 h antes, cancelar es gratis');
  check((await tr(v3, 'cancelled_owner', ownerA.token)).json?.cancel_fee === 0, 'cancelación anticipada sin cargo');

  const v4 = (await book(await quote(), at(24))).json.id;
  await tr(v4, 'accepted', vet.token);
  shift(v4, "date_trunc('minute', now()) + interval '90 minutes'");
  check((await mv(v4, ownerA.token))?.cancel_fee_now === 5000, 'dentro de las 2 h se anuncia el cargo de $5.000');
  const late = await tr(v4, 'cancelled_owner', ownerA.token, 'Me surgió un viaje');
  check(late.json?.cancel_fee === 5000, 'cancelar dentro de las 2 h cobra $5.000');
  const fee = await call(`/rest/v1/payments?select=kind,status,service_price,platform_fee,vet_payout&visit_id=eq.${v4}`, { token: ownerA.token });
  check(fee.json.length === 1 && fee.json[0].kind === 'cancel_fee' && fee.json[0].status === 'simulated_paid'
    && fee.json[0].service_price === 5000 && fee.json[0].vet_payout === 4250, 'el cargo queda como pago simulado con su reparto');

  // Rechazo del vet y cancelación del vet.
  check((await tr(vRace, 'rejected', vet.token, 'Sin cupo')).json?.status === 'rejected', 'el vet rechaza una solicitud');

  // --- Expiración (pg_cron) --------------------------------------------------------------
  check(sql("select schedule from cron.job where jobname = 'expire-visits'") === '* * * * *', 'pg_cron programa la expiración cada minuto');
  const v5 = (await book(await quote(), at(30))).json.id;
  sql(`update public.visits set confirm_deadline = now() - interval '1 minute' where id = '${v5}'`);
  const lateAccept = await tr(v5, 'accepted', vet.token);
  check(lateAccept.status === 400 && /plazo/.test(lateAccept.json.message), 'el vet no confirma fuera de plazo');
  sql('select private.expire_visits()');
  check((await mv(v5, ownerA.token))?.status === 'expired', 'la solicitud no confirmada a tiempo expira');
  const v6 = (await book(await quote(), at(36))).json.id;
  await tr(v6, 'accepted', vet.token);
  shift(v6, "date_trunc('minute', now()) - interval '2 hours'");
  sql('select private.expire_visits()');
  const v6o = await mv(v6, ownerA.token);
  check(v6o?.status === 'cancelled_vet' && v6o?.cancel_fee === 0, 'la confirmada que nunca empezó se cierra sin cargo para el dueño');

  // --- Admin: solo agregados -----------------------------------------------------------
  const sum = await rpc('admin_visit_summary', {}, admin.token);
  check(sum.status === 200 && sum.json.some((r) => r.status === 'completed' && r.total >= 1), 'el admin ve el resumen agregado');
  check(((await rpc('my_visits', {}, admin.token)).json ?? []).length === 0, 'el admin no obtiene el detalle de visitas');
  check(((await call('/rest/v1/visits?select=id', { token: admin.token })).json ?? []).length === 0, 'el admin no lee filas de visitas');
  check(((await rpc('admin_visit_summary', {}, ownerA.token)).json ?? []).length === 0, 'un dueño no ve el resumen');

  // --- Días libres ------------------------------------------------------------------------
  const off = await rpc('add_time_off', { p_from: tomorrow, p_to: tomorrow }, vet.token);
  check(off.status === 200, 'el vet registra un día libre');
  const av3 = await rpc('available_vets', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_date: tomorrow }, ownerA.token);
  check(!av3.json.some((v) => v.vet_id === vet.id), 'en su día libre el vet no aparece');
  check((await rpc('add_time_off', { p_from: tomorrow, p_to: tomorrow }, ownerA.token)).status >= 400, 'un dueño no registra días libres');
} finally {
  for (const id of created) {
    await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
  }
}

console.log(fails === 0 ? '\nE2E fase 6: TODO OK' : `\nE2E fase 6: ${fails} fallas`);
process.exit(fails ? 1 : 0);
