// E2E de la fase 11 (derechos de privacidad) contra Supabase local: Auth +
// REST + Storage + Edge Function `purge-privacy-storage`, y SQL directo
// (docker exec) solo para simular el paso del tiempo y correr los jobs de
// pg_cron (el job de borrado necesita una sesión de postgres).
// Uso: node tool/e2e/privacidad_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
// Crea usuarios ficticios y borra lo que queda al final.
import { backdateStart, shiftVisit, sqlRunner } from './sql.mjs';

const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;
const sql = sqlRunner(st);
const BUCKET = 'clinical-attachments';

let fails = 0;
const check = (cond, msg) => { console.log(`${cond ? 'OK  ' : 'FALLA'} ${msg}`); if (!cond) fails++; };

async function call(path, { method = 'GET', token, key = PUB, body, prefer, raw, type } = {}) {
  const headers = { apikey: key };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (prefer) headers.Prefer = prefer;
  if (raw !== undefined) headers['Content-Type'] = type ?? 'application/octet-stream';
  else if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(API + path, {
    method, headers, body: raw !== undefined ? raw : body !== undefined ? JSON.stringify(body) : undefined });
  const buf = Buffer.from(await r.arrayBuffer());
  let json; try { json = JSON.parse(buf.toString()); } catch { json = buf.toString(); }
  return { status: r.status, json, buf, text: buf.toString() };
}
const rpc = (name, body, token) => call(`/rest/v1/rpc/${name}`, { method: 'POST', token, body });
const svc = (path, body, method = 'POST') => call(path, { method, key: SRV, token: SRV, body });
const PDF = Buffer.from('%PDF-1.4\n% receta ficticia de prueba\n%%EOF\n');

const stamp = Date.now();
const created = [];
const login = (email) => call('/auth/v1/token?grant_type=password', {
  method: 'POST', body: { email, password: 'Felix2026' } });
async function newUser(tag) {
  const email = `${tag}-${stamp}@test.local`;
  const c = await svc('/auth/v1/admin/users', { email, password: 'Felix2026', email_confirm: true });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status}`);
  created.push(c.json.id);
  const s = await login(email);
  return { token: s.json.access_token, refresh: s.json.refresh_token, id: s.json.user.id, email };
}

const legal = {
  terms: (await rpc('current_legal_version', { p_kind: 'terms' })).json,
  privacy: (await rpc('current_legal_version', { p_kind: 'privacy' })).json,
};
const register = (u, role, name, communeId = null, phone = null) => rpc('complete_registration', {
  p_role: role, p_display_name: name, p_phone: phone,
  p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: communeId }, u.token);

const tomorrow = new Date(Date.now() + 24 * 3600 * 1000)
  .toLocaleDateString('en-CA', { timeZone: 'America/Santiago' });
let vet;
let pet;

try {
  const owner = await newUser('dueno-f11');
  vet = await newUser('vet-f11');
  const nunoa = (await call('/rest/v1/communes?select=id&name=eq.%C3%91u%C3%B1oa', { token: owner.token })).json[0].id;
  check((await register(owner, 'owner', 'Olga Borrable', nunoa, '+56 9 4444 5555')).status === 200,
    'el dueño completa su registro');
  check((await register(vet, 'vet', 'Dra. Retiene')).status === 200, 'el vet completa su registro');

  const perro = (await call('/rest/v1/species?select=id&slug=eq.perro', { token: owner.token })).json[0].id;
  const general = (await call('/rest/v1/specialties?select=id&slug=eq.general', { token: owner.token })).json[0].id;
  await svc(`/rest/v1/vet_profiles?user_id=eq.${vet.id}`, { status: 'approved' }, 'PATCH');
  await svc('/rest/v1/vet_species', { vet_id: vet.id, species_id: perro });
  await svc('/rest/v1/vet_specialties', { vet_id: vet.id, specialty_id: general });
  await svc('/rest/v1/vet_availability', [1, 2, 3, 4, 5, 6, 7].map((d) => ({ vet_id: vet.id, weekday: d, start_min: 0, end_min: 1440 })));
  const baseCommune = (await rpc('communes_at_point', { p_lat: -33.3849, p_lng: -70.5974 }, vet.token)).json[0].commune_id;
  await call('/rest/v1/vet_bases', { method: 'POST', token: vet.token,
    body: { vet_id: vet.id, commune_id: baseCommune, lat: -33.3849, lng: -70.5974 } });

  pet = (await call('/rest/v1/pets?select=id', { method: 'POST', token: owner.token, prefer: 'return=representation',
    body: { owner_id: owner.id, name: 'Canelita', species_id: perro, microchip: '941000099998888' } })).json[0].id;
  const addr = (await call('/rest/v1/addresses?select=id', { method: 'POST', token: owner.token,
    prefer: 'return=representation', body: { owner_id: owner.id, label: 'Casa', street_text: 'Pasaje Borrado 99',
      commune_id: nunoa, lat: -33.4569, lng: -70.5974 } })).json[0].id;

  // --- Visita completada y pagada, con ficha y adjunto --------------------------------
  const av = await rpc('available_vets', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general, p_date: tomorrow }, owner.token);
  const slot = av.json.find((v) => v.vet_id === vet.id).slots[0];
  const q = (await rpc('quote_visit', { p_pet_id: pet, p_address_id: addr, p_specialty_id: general,
    p_mode: 'scheduled', p_vet_id: vet.id, p_extra_donation: 1000 }, owner.token)).json;
  const visit = (await rpc('book_visit', { p_quote_id: q.quote_id, p_vet_id: vet.id, p_pet_id: pet,
    p_address_id: addr, p_scheduled_at: slot }, owner.token)).json.id;
  const tr = (to) => rpc('transition_visit', { p_visit_id: visit, p_to_status: to }, vet.token);
  check((await tr('accepted')).status === 200, 'el vet confirma la visita');
  shiftVisit(sql, visit, "date_trunc('minute', now()) + interval '20 minutes'");
  for (const s of ['en_route', 'arrived', 'in_progress']) await tr(s);
  const dx = await rpc('add_clinical_entry', { p_pet_id: pet, p_kind: 'diagnosis', p_title: 'Otitis de Canelita',
    p_body: 'Dueña Olga Borrable (+56 9 4444 5555, ' + owner.email + '), Pasaje Borrado 99. Revisar en 10 días.',
    p_visit_id: visit, p_specialty_id: general }, vet.token);
  check(dx.status === 200, 'el vet registra un diagnóstico con datos del dueño en el texto');
  const path = `pets/${pet}/${dx.json}/receta.pdf`;
  const up = await call(`/storage/v1/object/${BUCKET}/${path}`, { method: 'POST', token: vet.token, raw: PDF, type: 'application/pdf' });
  const att = await call('/rest/v1/entry_attachments', { method: 'POST', token: vet.token,
    body: { entry_id: dx.json, storage_path: path, file_name: 'receta.pdf', mime: 'application/pdf', size_bytes: PDF.length } });
  check(up.status === 200 && att.status === 201, 'el vet sube y registra un adjunto en Storage');
  check((await rpc('add_clinical_entry', { p_pet_id: pet, p_kind: 'note', p_title: 'Nota de Olga' }, owner.token)).status === 200,
    'el dueño agrega una nota');
  backdateStart(sql, visit);
  check((await tr('completed')).status === 200, 'el vet completa la visita');
  const pay = await rpc('simulate_payment', { p_visit_id: visit }, owner.token);
  check(pay.status === 200 && pay.json.status === 'simulated_paid', 'el dueño paga (simulado)');

  // --- Consentimientos y política -----------------------------------------------------
  const c1 = await rpc('set_consent', { p_purpose: 'marketing', p_granted: true }, owner.token);
  const c2 = await rpc('set_consent', { p_purpose: 'marketing', p_granted: false }, owner.token);
  check(c1.json.purposes?.[0]?.granted === true && c2.json.purposes?.[0]?.granted === false
    && c2.json.history?.[0]?.revoked_at, 'el dueño otorga y retira el consentimiento (queda la fecha)');
  const ps = await rpc('my_privacy_status', {}, owner.token);
  check(ps.status === 200 && ps.json.must_review === false && ps.json.privacy_version === legal.privacy,
    'el estado de la política informa la versión vigente');

  // --- Exportación --------------------------------------------------------------------
  const ex = await rpc('export_my_data', {}, owner.token);
  let parsed;
  try { parsed = JSON.parse(ex.text); } catch { parsed = null; }
  check(ex.status === 200 && parsed?.format === 'felix-export', 'la exportación es un JSON válido');
  check(parsed?.pets?.length === 1 && parsed.pets[0].microchip === '941000099998888'
    && parsed.addresses?.length === 1 && parsed.visits?.length === 1 && parsed.payments?.length >= 1
    && parsed.clinical_entries?.length === 2 && parsed.clinical_entries.some((e) => e.attachments?.length === 1)
    && parsed.consents?.length === 1 && parsed.terms_acceptances?.length === 1
    && parsed.privacy_notice_views?.length === 1 && parsed.account?.email === owner.email,
    'la exportación trae perfil, mascota, dirección, ficha con adjunto, visita, pago, consentimiento y avisos');
  const vex = await rpc('export_my_data', {}, vet.token);
  check(vex.status === 200 && !vex.text.includes('4444 5555') && !vex.text.includes('Canelita')
    && !vex.text.includes('Pasaje Borrado') && !vex.text.includes(owner.id),
    'la exportación del vet no trae datos del dueño');

  // --- Solicitud de borrado: bloqueo y sesiones -----------------------------------------
  const req = await rpc('request_account_deletion', {}, owner.token);
  check(req.status === 200 && req.json.status === 'blocked' && req.json.cancellable === true,
    'acuse inmediato: cuenta bloqueada y cancelable');
  const refresh = await call('/auth/v1/token?grant_type=refresh_token', { method: 'POST', body: { refresh_token: owner.refresh } });
  check(refresh.status >= 400, `el refresh token quedó revocado (HTTP ${refresh.status})`);
  const blocked = await call('/rest/v1/pets?select=id', { token: owner.token });
  check(blocked.status === 403 && blocked.json?.hint === 'account_blocked',
    `con el JWT vigente la REST responde 403 account_blocked (HTTP ${blocked.status})`);
  const blockedRpc = await rpc('my_visits', {}, owner.token);
  check(blockedRpc.status === 403, 'y las RPC también');
  check((await rpc('my_deletion_request', {}, owner.token)).json?.status === 'blocked',
    'la cuenta bloqueada sí ve su solicitud');
  const relog = await login(owner.email);
  const relogPets = await call('/rest/v1/pets?select=id', { token: relog.json.access_token });
  check(relog.status === 200 && relogPets.status === 403,
    'durante la gracia puede entrar solo para cancelar o exportar: los datos siguen bloqueados');
  const blockedUp = await call(`/storage/v1/object/${BUCKET}/pets/${pet}/${dx.json}/otro.pdf`, {
    method: 'POST', token: relog.json.access_token, raw: PDF, type: 'application/pdf' });
  check(blockedUp.status >= 400, 'Storage también rechaza a la cuenta bloqueada');
  const vetRead = await rpc('get_pet_record', { p_pet_id: pet }, vet.token);
  const attId = parsed?.clinical_entries?.find((e) => e.attachments?.length)?.attachments[0].id;
  const vetSign = await call('/functions/v1/clinical-attachment-url', { method: 'POST', token: vet.token,
    body: { attachment_id: attId } });
  check(vetRead.status === 403 && vetSign.status >= 400,
    'sin tratamiento: el vet ya no lee la ficha ni firma el adjunto del dueño bloqueado');

  // --- Vence la gracia y corre el job ---------------------------------------------------
  sql(`update public.deletion_requests set execute_after = now() - interval '1 minute' where id = '${req.json.request_id}'`);
  const run1 = sql('select private.run_account_deletions()');
  check(run1.includes('"executing": 1'), `el job ejecuta y espera a Storage (${run1})`);
  const banned = await login(owner.email);
  check(banned.status >= 400, `vencida la gracia, el login se rechaza (HTTP ${banned.status})`);
  check(sql(`select count(*) from public.pets where id = '${pet}'`) === '0', 'la mascota ya no existe');
  const fn = await call('/functions/v1/purge-privacy-storage', { method: 'POST', key: SRV, token: SRV, body: {} });
  check(fn.status === 200 && fn.json.removed >= 1, `la Edge Function borra los objetos con la API de Storage (${JSON.stringify(fn.json)})`);
  check((await call('/functions/v1/purge-privacy-storage', { method: 'POST', token: vet.token, body: {} })).status === 403,
    'la Edge Function es solo para el rol de servicio');
  const run2 = sql('select private.run_account_deletions()');
  check(run2.includes('"done": 1'), `con Storage confirmado, el job termina (${run2})`);
  const obj = await call(`/storage/v1/object/${BUCKET}/${path}`, { key: SRV, token: SRV });
  check(obj.status >= 400, `el objeto de Storage ya no existe (HTTP ${obj.status})`);
  check(sql(`select count(*) from auth.users where id = '${owner.id}'`) === '0', 'el usuario de Auth se borró');
  check(sql(`select count(*) from private.privacy_residue(array['${owner.id}', '${pet}']::uuid[])`) === '0',
    'el escaneo final por user_id y pet_id sale limpio');
  check(sql(`select affected from public.deletion_targets where request_id = '${req.json.request_id}' and target = 'verification_scan'`) === '0',
    'y queda registrado en deletion_targets');
  check(sql(`select (owner_id is null)::text || ':' || total from public.payments where visit_id = '${visit}' and kind = 'visit'`)
    === `true:${pay.json.total}`, 'el pago queda anonimizado con su monto');
  check(sql('select private.run_account_deletions()').trim() === '{}', 'correr el job de nuevo no hace nada');

  // --- El vet autor pide su entrada retenida ------------------------------------------
  const ret = await rpc('list_my_retained_entries', {}, vet.token);
  check(ret.status === 200 && ret.json.some((e) => e.id === dx.json), 'el vet autor ve su entrada retenida');
  const noReason = await rpc('request_retained_entry', { p_entry_id: dx.json, p_reason: 'x' }, vet.token);
  check(noReason.status === 400, 'la consulta exige un motivo');
  const got = await rpc('request_retained_entry', { p_entry_id: dx.json, p_reason: 'Reclamo del tutor por el tratamiento' }, vet.token);
  check(got.status === 200 && got.json.title === 'Otitis de [redactado]'
    && !/Olga|Borrable|4444|Pasaje|@test\.local/.test(got.json.body ?? '')
    && (got.json.body ?? '').includes('Revisar en 10 días.'),
    'la entrada retenida llega desvinculada y con la PII redactada');
} finally {
  // Limpieza: lo retenido del vet y los usuarios que queden.
  if (vet) {
    try {
      sql(`set felix.record_maintenance = 'on';
           delete from public.clinical_entries where author_id = '${vet.id}' and pet_id is null;`);
    } catch (e) { console.log(`limpieza de la ficha: ${e.message}`); }
  }
  for (const id of created) {
    await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
  }
}

console.log(fails === 0 ? '\nE2E fase 11: TODO OK' : `\nE2E fase 11: ${fails} fallas`);
process.exit(fails ? 1 : 0);
