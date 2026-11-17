// QA exploratorio (fases 0–3) contra Supabase local: Auth + Mailpit + REST +
// Storage + Edge Function. Complementa auth_e2e.mjs y vet_e2e.mjs con casos
// negativos, de borde y de concurrencia simple.
//
// Uso: node tool/e2e/qa_exploratorio_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
//
// Convención:
//   OK      el comportamiento esperado se cumple.
//   FALLA   regresión de algo que debería funcionar (sale con código 1).
//   DEFECTO defecto conocido y documentado en docs/qa/ (sale con código 2 si no
//           hay FALLAs). Cuando se corrija, la línea pasa a OK sola.
//
// Solo crea usuarios *@test.local y borra (con la clave de servicio) lo que crea.
const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;
const MAIL = st.MAILPIT_URL ?? 'http://127.0.0.1:54324';

let fails = 0;
let defects = 0;
const check = (cond, msg) => {
  console.log(`${cond ? 'OK     ' : 'FALLA  '} ${msg}`);
  if (!cond) fails++;
};
// cond = comportamiento esperado. Si no se cumple, es un defecto conocido.
const known = (cond, id, msg) => {
  console.log(`${cond ? 'OK     ' : `DEFECTO ${id}`} ${msg}`);
  if (!cond) defects++;
};

async function call(path, { method = 'GET', token, key = PUB, body, prefer, raw, type, headers: extra } = {}) {
  const headers = { apikey: key, ...extra };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (prefer) headers.Prefer = prefer;
  if (raw) headers['Content-Type'] = type;
  else if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(API + path, { method, headers, body: raw ?? (body !== undefined ? JSON.stringify(body) : undefined) });
  const text = await r.text();
  let json;
  try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, json };
}
const rest = (path, opts) => call(`/rest/v1/${path}`, opts);
const rpc = (fn, token, body = {}) => rest(`rpc/${fn}`, { method: 'POST', token, body });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const stamp = Date.now();
const created = []; // ids de auth.users creados por este script
const createdSpecies = [];

async function newUser(tag, { confirmed = true } = {}) {
  const email = `qa-${tag}-${stamp}@test.local`;
  const c = await call('/auth/v1/admin/users', { method: 'POST', key: SRV, token: SRV,
    body: { email, password: 'Felix2026', email_confirm: confirmed } });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status} ${JSON.stringify(c.json)}`);
  created.push(c.json.id);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password: 'Felix2026' } });
  return { email, token: s.json.access_token, refresh: s.json.refresh_token, id: c.json.id };
}

const legal = {
  terms: (await rpc('current_legal_version', undefined, { p_kind: 'terms' })).json,
  privacy: (await rpc('current_legal_version', undefined, { p_kind: 'privacy' })).json,
};
const santiago = (await rest('communes?select=id&name=eq.Santiago', { key: SRV, token: SRV })).json[0].id;
const register = (u, role, extra = {}) => rpc('complete_registration', u.token, {
  p_role: role, p_display_name: extra.name ?? `QA ${role}`, p_phone: extra.phone ?? null,
  p_terms_version: legal.terms, p_privacy_version: legal.privacy,
  p_commune_id: role === 'owner' ? (extra.commune ?? santiago) : null,
});

async function mails(email) {
  const r = await fetch(`${MAIL}/api/v1/search?query=${encodeURIComponent(`to:"${email}"`)}`);
  if (!r.ok) return null;
  return (await r.json()).messages ?? [];
}

try {
  // =========================================================================
  console.log('\n== 1. Registro con email, confirmación, reenvío, login/logout ==');
  const signEmail = `qa-signup-${stamp}@test.local`;
  const su = await call('/auth/v1/signup', { method: 'POST',
    body: { email: signEmail, password: 'Felix2026' } });
  check(su.status === 200 && !su.json.access_token, 'el registro no entrega sesión antes de confirmar');
  if (su.json.id ?? su.json.user?.id) created.push(su.json.id ?? su.json.user.id);
  await sleep(800);
  const m1 = await mails(signEmail);
  check(m1 !== null && m1.length === 1, `Mailpit recibe el correo de confirmación (${m1?.length})`);

  await sleep(1200); // max_frequency = 1s
  const rs = await call('/auth/v1/resend', { method: 'POST', body: { type: 'signup', email: signEmail } });
  check(rs.status === 200, `el reenvío de confirmación responde 200 (HTTP ${rs.status})`);
  await sleep(800);
  const m2 = await mails(signEmail);
  check(m2 !== null && m2.length === 2, `llega un segundo correo tras el reenvío (${m2?.length})`);

  const noConf = await call('/auth/v1/token?grant_type=password', { method: 'POST',
    body: { email: signEmail, password: 'Felix2026' } });
  check(noConf.status === 400 && noConf.json.error_code === 'email_not_confirmed',
    'sin confirmar: error_code email_not_confirmed (la app lo traduce)');

  for (const [pw, why] of [['felix2026', 'sin mayúscula'], ['FELIX2026', 'sin minúscula'],
    ['FelixFelix', 'sin número'], ['Fe1ix', 'menos de 8']]) {
    const w = await call('/auth/v1/signup', { method: 'POST',
      body: { email: `qa-weak-${why.replace(/\W/g, '')}-${stamp}@test.local`, password: pw } });
    check(w.status === 422 && w.json.error_code === 'weak_password', `Auth rechaza contraseña ${why}`);
  }

  // Retorno tras confirmar: en Web la app pide volver a Uri.base.origin.
  const lanEmail = `qa-lan-${stamp}@test.local`;
  const lan = await call(`/auth/v1/signup?redirect_to=${encodeURIComponent('http://192.168.1.50:8080')}`, {
    method: 'POST', body: { email: lanEmail, password: 'Felix2026' } });
  if (lan.json.id) created.push(lan.json.id);
  await sleep(800);
  const lanMail = (await mails(lanEmail))?.[0];
  let lanRedirectOk = false;
  if (lanMail) {
    const full = await (await fetch(`${MAIL}/api/v1/message/${lanMail.ID}`)).json();
    lanRedirectOk = decodeURIComponent(full.Text ?? full.HTML ?? '').includes('192.168.1.50');
  }
  known(lanRedirectOk, 'QA-07',
    'confirmar desde la red local (iPhone) vuelve a http://<IP>:8080 y no a site_url');

  const owner = await newUser('owner');
  const bad = await call('/auth/v1/token?grant_type=password', { method: 'POST',
    body: { email: owner.email, password: 'Incorrecta1' } });
  check(bad.status === 400 && bad.json.error_code === 'invalid_credentials', 'clave incorrecta: invalid_credentials');

  const sessUser = await newUser('logout');
  const lo = await call('/auth/v1/logout', { method: 'POST', token: sessUser.token });
  check(lo.status === 204, `logout responde 204 (HTTP ${lo.status})`);
  const refr = await call('/auth/v1/token?grant_type=refresh_token', { method: 'POST',
    body: { refresh_token: sessUser.refresh } });
  check(refr.status >= 400, 'tras logout el refresh token ya no sirve');

  // =========================================================================
  console.log('\n== 2. Onboarding (dueño y vet) ==');
  const badPhone = await register(owner, 'owner', { phone: 'abc' });
  check(badPhone.status === 400 && badPhone.json.code === '23514', 'teléfono inválido: CHECK 23514');
  const badCommune = await register(owner, 'owner', { commune: 999999 });
  check(badCommune.status >= 400, 'comuna inexistente: rechazada');
  const asAdmin = await rpc('complete_registration', owner.token, { p_role: 'admin', p_display_name: 'X Y',
    p_phone: null, p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: santiago });
  check(asAdmin.status === 400, 'complete_registration no acepta rol admin');
  const asFound = await rpc('complete_registration', owner.token, { p_role: 'foundation', p_display_name: 'X Y',
    p_phone: null, p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: santiago });
  check(asFound.status === 400, 'complete_registration no acepta rol foundation');
  const oldTerms = await rpc('complete_registration', owner.token, { p_role: 'owner', p_display_name: 'X Y',
    p_phone: null, p_terms_version: '2000-01-01', p_privacy_version: legal.privacy, p_commune_id: santiago });
  check(oldTerms.status === 400, 'versión de términos no vigente: rechazada');

  // Concurrencia: dos envíos simultáneos del formulario (doble toque).
  const [r1, r2] = await Promise.all([register(owner, 'owner', { phone: '+56 9 1234 5678' }),
    register(owner, 'owner', { phone: '+56 9 1234 5678' })]);
  const codes = [r1.status, r2.status].sort();
  check(codes[0] === 200 && codes[1] === 409, `doble envío simultáneo: uno gana y el otro 409 (${codes})`);
  const terms = await rest(`terms_acceptances?select=version&user_id=eq.${owner.id}`, { token: owner.token });
  check(terms.json.length === 1, 'queda exactamente una aceptación de términos');

  // Consentimiento opcional.
  const cIns = await rest('consents', { method: 'POST', token: owner.token, prefer: 'return=representation',
    body: { user_id: owner.id, purpose: 'marketing', version: legal.privacy } });
  check(cIns.status === 201, 'el dueño otorga el consentimiento opcional');
  const cOther = await rest('consents', { method: 'POST', token: owner.token,
    body: { user_id: sessUser.id, purpose: 'marketing', version: legal.privacy } });
  check(cOther.status === 403, 'no puede otorgar consentimientos a nombre de otro');
  const cId = cIns.json[0].id;
  const rev1 = await rest(`consents?id=eq.${cId}`, { method: 'PATCH', token: owner.token,
    prefer: 'return=representation', body: { revoked_at: new Date().toISOString() } });
  check(rev1.status === 200 && rev1.json.length === 1, 'el dueño retira su consentimiento');
  const rev2 = await rest(`consents?id=eq.${cId}`, { method: 'PATCH', token: owner.token,
    prefer: 'return=representation', body: { revoked_at: '2099-01-01T00:00:00Z' } });
  known(!(rev2.status === 200 && rev2.json.length === 1), 'QA-05',
    'un retiro ya registrado no se puede reescribir (fecha de revocación inmutable)');
  const regrant = await rest('consents', { method: 'POST', token: owner.token,
    body: { user_id: owner.id, purpose: 'marketing', version: legal.privacy } });
  check(regrant.status === 201, 'tras retirarlo, el dueño puede volver a otorgar el consentimiento');

  // Perfil: comuna obligatoria y aislamiento.
  const nullCommune = await rest(`owner_profiles?user_id=eq.${owner.id}`, { method: 'PATCH', token: owner.token,
    prefer: 'return=representation', body: { commune_id: null } });
  known(!(nullCommune.status === 200 && nullCommune.json.length === 1), 'QA-04',
    'el dueño no puede dejar su comuna en blanco por la API');

  // Registro saltándose complete_registration (sin términos ni comuna).
  const bypass = await newUser('bypass');
  const br = await rest('user_roles', { method: 'POST', token: bypass.token, body: { user_id: bypass.id, role: 'owner' } });
  const bp = await rest('owner_profiles', { method: 'POST', token: bypass.token,
    body: { user_id: bypass.id, display_name: 'Sin Términos' } });
  const bt = await rest(`terms_acceptances?select=id&user_id=eq.${bypass.id}`, { token: bypass.token });
  known(!(br.status === 201 && bp.status === 201 && bt.json.length === 0), 'QA-01',
    'no se puede quedar como dueño registrado sin aceptar términos ni elegir comuna');
  const bypassVet = await newUser('bypassvet');
  const bvr = await rest('user_roles', { method: 'POST', token: bypassVet.token, body: { user_id: bypassVet.id, role: 'vet' } });
  const bvp = await rest('vet_profiles', { method: 'POST', token: bypassVet.token,
    body: { user_id: bypassVet.id, display_name: 'Vet Sin Términos' } });
  known(!(bvr.status === 201 && bvp.status === 201), 'QA-01',
    'no se puede quedar como vet registrado sin aceptar términos');
  const roleAgain = await rest(`user_roles?user_id=eq.${bypass.id}`, { method: 'PATCH', token: bypass.token,
    body: { role: 'admin' } });
  check(roleAgain.status === 401 || roleAgain.status === 403, 'nadie cambia su rol a admin por PATCH');

  const owner2 = await newUser('owner2');
  await register(owner2, 'owner');
  const peek = await rest(`owner_profiles?select=user_id,phone&user_id=eq.${owner.id}`, { token: owner2.token });
  check(peek.status === 200 && peek.json.length === 0, 'un dueño no ve el perfil (ni el teléfono) de otro');
  const tamper = await rest(`owner_profiles?user_id=eq.${owner.id}`, { method: 'PATCH', token: owner2.token,
    prefer: 'return=representation', body: { display_name: 'Hackeado' } });
  check(tamper.status === 200 && tamper.json.length === 0, 'un dueño no edita el perfil de otro (0 filas)');

  // =========================================================================
  console.log('\n== 3. Anónimo sin acceso ==');
  const tables = ['user_roles', 'owner_profiles', 'vet_profiles', 'terms_acceptances', 'privacy_notice_views',
    'consents', 'admin_audit_log', 'regions', 'communes', 'species', 'breeds', 'specialties',
    'species_specialties', 'tariffs', 'pricing_config', 'emergency_clinics', 'vet_species',
    'vet_specialties', 'vet_availability', 'vet_documents'];
  const leaks = [];
  for (const t of tables) {
    const r = await rest(`${t}?select=*&limit=1`);
    if (!(r.status === 401 || r.status === 403 || (r.status === 200 && r.json.length === 0))) leaks.push(`${t}:${r.status}`);
  }
  check(leaks.length === 0, `anónimo no lee ninguna de las ${tables.length} tablas (${leaks.join(', ') || 'sin fugas'})`);
  const anonRpc = [];
  for (const fn of ['complete_registration', 'submit_vet_application', 'review_vet_application',
    'base_tariff', 'current_pricing_config']) {
    const r = await rpc(fn, undefined, {});
    if (r.status < 400) anonRpc.push(`${fn}:${r.status}`);
  }
  check(anonRpc.length === 0, `anónimo no ejecuta RPC protegidas (${anonRpc.join(', ') || 'ninguna'})`);
  const anonList = await call('/storage/v1/object/list/vet-documents', { method: 'POST', body: { prefix: '' },
    headers: { 'Content-Type': 'application/json' } });
  check(anonList.status >= 400 || (Array.isArray(anonList.json) && anonList.json.length === 0),
    'anónimo no lista el bucket vet-documents');

  // =========================================================================
  console.log('\n== 4. Admin y catálogos ==');
  const admin = await newUser('admin');
  await rest('user_roles', { method: 'POST', key: SRV, token: SRV, body: { user_id: admin.id, role: 'admin' } });
  const grantOther = await rest('user_roles', { method: 'POST', token: admin.token, body: { user_id: owner2.id, role: 'admin' } });
  check(grantOther.status >= 400, 'ni el admin asigna roles por la API (admin solo por SQL)');
  const auditWrite = await rest('admin_audit_log', { method: 'POST', token: admin.token,
    body: { table_name: 'x', row_pk: '1', action: 'INSERT' } });
  check(auditWrite.status === 401 || auditWrite.status === 403, 'el admin no escribe el log de auditoría a mano');
  const auditDel = await rest('admin_audit_log?id=gt.0', { method: 'DELETE', token: admin.token });
  check(auditDel.status === 401 || auditDel.status === 403, 'el admin no borra el log de auditoría');

  const letters = String(stamp).slice(-7).replace(/\d/g, (d) => 'abcdefghij'[d]);
  const sp = await rest('species', { method: 'POST', token: admin.token, prefer: 'return=representation',
    body: { slug: `qa_especie_${letters}`, name: `QA Especie ${letters}` } });
  check(sp.status === 201, `el admin crea una especie de prueba (HTTP ${sp.status})`);
  const spId = sp.json[0]?.id;
  if (spId) createdSpecies.push(spId);
  const deact = await rest(`species?id=eq.${spId}`, { method: 'PATCH', token: admin.token,
    prefer: 'return=representation', body: { active: false } });
  check(deact.status === 200 && deact.json[0]?.active === false, 'el admin desactiva la especie');
  const seen = await rest(`species?select=id&id=eq.${spId}`, { token: owner.token });
  check(seen.json.length === 0, 'el dueño ya no ve la especie inactiva');
  const del = await rest(`species?id=eq.${spId}`, { method: 'DELETE', token: admin.token });
  check(del.status === 401 || del.status === 403, 'ni el admin borra catálogos (solo desactiva)');
  const slugChange = await rest(`species?id=eq.${spId}`, { method: 'PATCH', token: admin.token, body: { slug: 'otro' } });
  check(slugChange.status === 401 || slugChange.status === 403, 'el slug es inmutable');
  const audit = await rest(`admin_audit_log?select=action,actor_id,new_data&table_name=eq.species&row_pk=eq.${spId}&order=id`, { token: admin.token });
  check(audit.json.length === 2 && audit.json.every((a) => a.actor_id === admin.id),
    `alta y desactivación quedan en la auditoría con el actor (${audit.json.length})`);

  const pcUpd = await rest('pricing_config?id=gt.0', { method: 'PATCH', token: admin.token, body: { commission_pct: 99 } });
  check(pcUpd.status === 401 || pcUpd.status === 403, 'pricing_config no se modifica (solo INSERT de versiones)');
  const pcFake = await rest('pricing_config', { method: 'POST', token: admin.token, body: {
    commission_pct: 15, foundation_pct: 20, urgent_pct: 30, per_km: 500, free_km: 5, cancel_fee: 5000,
    effective_from: '2999-01-01', created_by: owner.id } });
  check(pcFake.status === 403, 'el admin no firma una versión de precios a nombre de otro');
  const tarNeg = await rest('tariffs?id=gt.0&limit=1', { method: 'PATCH', token: admin.token, body: { base_price: 0 } });
  check(tarNeg.status === 400, 'tarifa en $0: rechazada (CHECK)');

  // =========================================================================
  console.log('\n== 5. Verificación de vets ==');
  const vet = await newUser('vet');
  const vetB = await newUser('vetb');
  check((await register(vet, 'vet')).status === 200, 'el vet completa el registro');
  await register(vetB, 'vet');
  const vstat = await rest(`vet_profiles?select=status&user_id=eq.${vet.id}`, { token: vet.token });
  check(vstat.json[0]?.status === 'pending', 'el vet nace pendiente');
  const ownerSeesVet = await rest(`vet_profiles?select=user_id&user_id=eq.${vet.id}`, { token: owner.token });
  check(ownerSeesVet.json.length === 0, 'un dueño no ve vets pendientes');

  const pdf = new TextEncoder().encode('%PDF-1.4 qa');
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
  const up = (u, path, bytes, type, extra) => call(`/storage/v1/object/vet-documents/${path}`,
    { method: 'POST', token: u.token, raw: bytes, type, headers: extra });
  const regDoc = (u, kind, path, mime, over = {}) => rest('vet_documents', { method: 'POST', token: u.token,
    prefer: 'return=representation', body: { vet_id: u.id, kind, storage_path: path, mime, size_bytes: 10, ...over } });

  const tPath = `${vet.id}/titulo-${stamp}.pdf`;
  const cPath = `${vet.id}/cedula-${stamp}.png`;
  check((await up(vet, tPath, pdf, 'application/pdf')).status === 200, 'el vet sube su título');
  check((await up(vet, cPath, png, 'image/png')).status === 200, 'el vet sube su cédula (PNG)');
  const mimeLie = await up(vet, `${vet.id}/falso-${stamp}.pdf`, new TextEncoder().encode('<html>'), 'text/html');
  check(mimeLie.status >= 400, 'Storage rechaza text/html aunque el nombre termine en .pdf');
  const ow = await up(vet, tPath, pdf, 'application/pdf', { 'x-upsert': 'true' });
  check(ow.status >= 400, `el vet no sobrescribe un archivo ya subido (HTTP ${ow.status})`);
  const rm = await call('/storage/v1/object/vet-documents', { method: 'DELETE', token: vet.token,
    body: { prefixes: [tPath] } });
  const stillThere = await call(`/storage/v1/object/authenticated/vet-documents/${tPath}`, { token: vet.token });
  check(stillThere.status === 200, `el vet no borra archivos del bucket (DELETE ${rm.status})`);

  const forged = await regDoc(vet, 'degree_certificate', tPath, 'application/pdf', { review_status: 'accepted' });
  check(forged.status === 403, 'el vet no registra un documento como ya aceptado');
  const forged2 = await regDoc(vet, 'degree_certificate', tPath, 'application/pdf', { purge_after: '2999-01-01' });
  check(forged2.status === 403, 'el vet no fija su propia fecha de purga');
  const ghost = await regDoc(vet, 'degree_certificate', `${vet.id}/no-existe.pdf`, 'application/pdf');
  check(ghost.status === 403, 'no se registra un documento que no está en Storage');
  const foreign = await regDoc(vetB, 'degree_certificate', tPath, 'application/pdf');
  check(foreign.status >= 400, 'otro vet no registra como suyo un archivo ajeno');
  check((await regDoc(vet, 'degree_certificate', tPath, 'application/pdf')).status === 201, 'el vet registra su título');
  check((await regDoc(vet, 'id_card_front', cPath, 'image/png')).status === 201, 'el vet registra su cédula');
  const dupDoc = await regDoc(vet, 'degree_certificate', tPath, 'application/pdf');
  known(dupDoc.status >= 400, 'QA-09', 'el mismo archivo no se registra dos veces');

  // Disponibilidad.
  const av = (u, weekday, s, e) => rest('vet_availability', { method: 'POST', token: u.token,
    prefer: 'return=representation', body: { vet_id: u.id, weekday, start_min: s, end_min: e } });
  const b1 = await av(vet, 1, 540, 780);
  check(b1.status === 201, 'bloque lunes 09:00–13:00');
  check((await av(vet, 1, 780, 900)).status === 201, 'bloque contiguo 13:00–15:00 se permite');
  const ov = await av(vet, 1, 600, 660);
  check(ov.status >= 400 && ov.json.code === '23P01', `bloque solapado: 23P01 (HTTP ${ov.status} ${ov.json.code})`);
  check((await av(vet, 1, 600, 600)).status === 400, 'bloque vacío (inicio = fin): rechazado');
  check((await av(vet, 8, 600, 660)).status === 400, 'día 8: rechazado');
  check((await av(vet, 7, 1380, 1440)).status === 201, 'bloque hasta las 24:00 se permite');
  check((await av(vet, 2, 540, 600)).status === 201 && (await av(vetB, 1, 540, 780)).status === 201,
    'el mismo horario en otro día u otro vet no choca');
  const peekAv = await rest(`vet_availability?select=id&vet_id=eq.${vet.id}`, { token: vetB.token });
  check(peekAv.json.length === 0, 'otro vet no ve la disponibilidad ajena');
  const delAv = await rest(`vet_availability?id=eq.${b1.json[0].id}`, { method: 'DELETE', token: vetB.token,
    prefer: 'return=representation' });
  check(delAv.json.length === 0, 'otro vet no borra bloques ajenos');
  const avForOther = await av({ ...vetB, id: vet.id }, 3, 600, 660);
  check(avForOther.status === 403, 'nadie crea bloques a nombre de otro vet');
  const ownerAv = await av(owner, 1, 600, 660);
  check(ownerAv.status >= 400, 'un dueño no crea disponibilidad');

  // Especies / especialidades.
  const perro = (await rest('species?select=id&slug=eq.perro', { token: vet.token })).json[0].id;
  const general = (await rest('specialties?select=id&slug=eq.general', { token: vet.token })).json[0].id;
  check((await rest('vet_species', { method: 'POST', token: vet.token, body: { vet_id: vet.id, species_id: perro } })).status === 201,
    'el vet elige Perro');
  check((await rest('vet_specialties', { method: 'POST', token: vet.token, body: { vet_id: vet.id, specialty_id: general } })).status === 201,
    'el vet elige Medicina general');
  const inactive = await rest('vet_species', { method: 'POST', token: vet.token, body: { vet_id: vet.id, species_id: spId } });
  check(inactive.status === 403, 'no se elige una especie inactiva');

  // Envío.
  const early = await rpc('submit_vet_application', vet.token);
  check(early.status === 400 && /universidad/i.test(early.json.message), `envío incompleto: "${early.json.message}"`);
  await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token,
    body: { university: 'Universidad de Prueba', graduation_year: 2015 } });
  const noDecl = await rpc('submit_vet_application', vet.token);
  check(noDecl.status === 400 && /declaración/i.test(noDecl.json.message), `sin declaración: "${noDecl.json.message}"`);
  await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token,
    body: { declaration_accepted_at: new Date().toISOString() } });
  const [s1, s2] = await Promise.all([rpc('submit_vet_application', vet.token), rpc('submit_vet_application', vet.token)]);
  check([s1.status, s2.status].sort().join() === '200,400', `doble envío simultáneo: uno gana (${s1.status},${s2.status})`);

  // En revisión: ¿se puede alterar lo enviado?
  const lockU = await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, body: { university: 'Otra' } });
  check(lockU.status === 403, 'en revisión: la universidad queda bloqueada');
  const decl = await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token,
    prefer: 'return=representation', body: { declaration_accepted_at: null } });
  known(!(decl.status === 200 && decl.json[0]?.declaration_accepted_at === null), 'QA-02',
    'en revisión: el vet no puede retirar la declaración jurada');
  // Si el defecto reaparece, restaurar para que el resto del flujo sea realista
  // (con QA-02 corregido este PATCH responde 403 y no cambia nada).
  await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token,
    body: { declaration_accepted_at: new Date().toISOString() } });
  const sub = await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token,
    prefer: 'return=representation', body: { submitted_at: '2000-01-01T00:00:00Z' } });
  known(!(sub.status === 200 && sub.json.length === 1), 'QA-02',
    'en revisión: el vet no reescribe la fecha de envío (orden de la cola)');
  const delSp = await rest(`vet_species?vet_id=eq.${vet.id}`, { method: 'DELETE', token: vet.token, prefer: 'return=representation' });
  known(!(delSp.status === 200 && delSp.json.length > 0), 'QA-12',
    'en revisión: el vet no puede quitar todas sus especies');
  if (delSp.json.length > 0) {
    await rest('vet_species', { method: 'POST', token: vet.token, body: { vet_id: vet.id, species_id: perro } });
  }
  const addSpec = await rest('vet_specialties', { method: 'POST', token: vet.token,
    body: { vet_id: vet.id, specialty_id: (await rest('specialties?select=id&slug=eq.urgencias', { token: vet.token })).json[0].id } });
  known(addSpec.status >= 400, 'QA-12', 'en revisión: el vet no agrega especialidades');
  const extraPath = `${vet.id}/extra-${stamp}.pdf`;
  const extraUp = await up(vet, extraPath, pdf, 'application/pdf');
  known(extraUp.status >= 400, 'QA-03', 'en revisión: no se suben documentos nuevos (Storage)');
  const extraReg = await regDoc(vet, 'other', extraPath, 'application/pdf');
  known(extraReg.status >= 400, 'QA-03', 'en revisión: no se registran documentos nuevos');
  const selfApprove = await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, body: { status: 'approved' } });
  check(selfApprove.status === 403, 'el vet no se autoaprueba');
  const selfVerify = await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token,
    body: { identity_verified_at: new Date().toISOString(), verified_by: vet.id } });
  check(selfVerify.status === 403, 'el vet no marca su identidad como verificada');
  const docSelf = await rest(`vet_documents?vet_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token,
    prefer: 'return=representation', body: { review_status: 'accepted' } });
  check(docSelf.json.length === 0, 'el vet no acepta sus propios documentos');

  // Revisión del admin.
  const queue = await rest('vet_profiles?select=user_id&status=eq.pending&submitted_at=not.is.null', { token: admin.token });
  check(queue.json.some((r) => r.user_id === vet.id), 'la solicitud aparece en la cola del admin');
  const notSubmitted = await rpc('review_vet_application', admin.token, { p_vet_id: vetB.id, p_approve: true });
  check(notSubmitted.status === 400, 'no se aprueba un vet que no envió su solicitud');
  const blank = await rpc('review_vet_application', admin.token, { p_vet_id: vet.id, p_approve: false, p_reason: '   ' });
  check(blank.status === 400 && /motivo/.test(blank.json.message), 'rechazar con motivo en blanco: error en español');
  const ownerReview = await rpc('review_vet_application', owner.token, { p_vet_id: vet.id, p_approve: true });
  check(ownerReview.status === 403, 'un dueño no revisa solicitudes');
  const vetBReview = await rpc('review_vet_application', vetB.token, { p_vet_id: vet.id, p_approve: true });
  check(vetBReview.status === 403, 'otro vet no revisa solicitudes');
  const longNotes = await rpc('review_vet_application', admin.token, { p_vet_id: vet.id, p_approve: false,
    p_reason: 'Falta folio', p_notes: 'x'.repeat(1001) });
  check(longNotes.status === 400, 'notas de revisión > 1000 caracteres: rechazadas por la BD (la UI limita a 500 desde d0c586c)');

  const rej = await rpc('review_vet_application', admin.token, { p_vet_id: vet.id, p_approve: false,
    p_reason: 'El nombre no coincide con la cédula' });
  check(rej.status === 200 && rej.json === 'rejected', 'el admin rechaza con motivo');
  const afterRej = (await rest(`vet_profiles?select=status,rejection_reason,submitted_at&user_id=eq.${vet.id}`, { token: vet.token })).json[0];
  check(afterRej.status === 'rejected' && afterRej.rejection_reason && afterRej.submitted_at === null,
    'el vet ve el motivo y puede corregir');
  const docsRej = (await rest(`vet_documents?select=purge_after,review_status&vet_id=eq.${vet.id}`, { token: vet.token })).json;
  const in30 = docsRej.every((d) => d.review_status === 'rejected' &&
    Math.abs(new Date(d.purge_after) - Date.now() - 30 * 864e5) < 36e5);
  check(in30, 'tras rechazar, los documentos se purgan a los 30 días');
  const rejToApproved = await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, body: { status: 'approved' } });
  check(rejToApproved.status === 403, 'un vet rechazado no se pasa a aprobado');
  const reRej = await rpc('review_vet_application', admin.token, { p_vet_id: vet.id, p_approve: true });
  check(reRej.status === 400, 'no se aprueba una solicitud rechazada sin reenvío');

  // Corrige y reenvía con documento nuevo.
  const t2 = `${vet.id}/titulo2-${stamp}.pdf`;
  check((await up(vet, t2, pdf, 'application/pdf')).status === 200, 'el vet rechazado sube un título nuevo');
  check((await regDoc(vet, 'degree_certificate', t2, 'application/pdf')).status === 201, 'y lo registra');
  const resub = await rpc('submit_vet_application', vet.token);
  check(resub.status === 200, 'el vet reenvía la solicitud');
  const st2 = (await rest(`vet_profiles?select=status&user_id=eq.${vet.id}`, { token: vet.token })).json[0].status;
  check(st2 === 'pending', 'vuelve a quedar pendiente (en revisión)');

  const [a1, a2] = await Promise.all([
    rpc('review_vet_application', admin.token, { p_vet_id: vet.id, p_approve: true, p_notes: '[x] nombre' }),
    rpc('review_vet_application', admin.token, { p_vet_id: vet.id, p_approve: false, p_reason: 'Carrera' }),
  ]);
  check([a1.status, a2.status].sort().join() === '200,400', `aprobar y rechazar a la vez: solo una decisión gana (${a1.status},${a2.status})`);
  const final = (await rest(`vet_profiles?select=status,verified_by,identity_verified_at&user_id=eq.${vet.id}`, { token: vet.token })).json[0];
  const approved = final.status === 'approved';
  if (!approved) {
    // Ganó el rechazo: reenviar y aprobar para seguir con el flujo.
    await rpc('submit_vet_application', vet.token);
    await rpc('review_vet_application', admin.token, { p_vet_id: vet.id, p_approve: true });
  }
  const fin = (await rest(`vet_profiles?select=status,verified_by,identity_verified_at&user_id=eq.${vet.id}`, { token: vet.token })).json[0];
  check(fin.status === 'approved' && fin.verified_by === admin.id && fin.identity_verified_at, 'el vet queda aprobado con quién y cuándo');
  const auditVet = await rest(`admin_audit_log?select=new_data&table_name=eq.vet_profiles&row_pk=eq.${vet.id}`, { token: admin.token });
  check(auditVet.json.length >= 2, `cada decisión del admin queda en la auditoría (${auditVet.json.length})`);
  const purgeDates = (await rest(`vet_documents?select=purge_after,purged_at&vet_id=eq.${vet.id}&purged_at=is.null`, { token: vet.token })).json;
  check(purgeDates.length > 0 && purgeDates.every((d) => new Date(d.purge_after) - Date.now() < 7 * 864e5 + 36e5),
    'al aprobar, todos los documentos vigentes se purgan a los 7 días');

  // Aprobado: ¿se puede alterar la evidencia?
  const apprUp = await up(vet, `${vet.id}/post-${stamp}.pdf`, pdf, 'application/pdf');
  check(apprUp.status >= 400, 'un vet aprobado no sube más documentos');
  const apprName = await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, body: { display_name: 'Otro Nombre' } });
  check(apprName.status === 403, 'un vet aprobado no cambia su nombre verificado');
  const apprBio = await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token,
    prefer: 'return=representation', body: { bio: 'Bio nueva' } });
  check(apprBio.status === 200 && apprBio.json.length === 1, 'un vet aprobado sí edita su presentación');
  const apprDecl = await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token,
    prefer: 'return=representation', body: { declaration_accepted_at: null } });
  known(!(apprDecl.status === 200 && apprDecl.json[0]?.declaration_accepted_at === null), 'QA-02',
    'un vet aprobado no puede borrar su declaración jurada');
  const backPending = await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, body: { status: 'pending' } });
  check(backPending.status === 403, 'un vet aprobado no vuelve solo a pendiente');
  const unsubmit = await rest(`vet_profiles?user_id=eq.${vet.id}`, { method: 'PATCH', token: vet.token, body: { submitted_at: null } });
  check(unsubmit.status === 403, 'un vet aprobado no retira su envío');

  // Purga: solo con la clave de servicio.
  const fnAnon = await call('/functions/v1/purge-vet-documents', { method: 'POST', body: {} });
  check(fnAnon.status === 401 || fnAnon.status === 403, `la purga rechaza la clave publicable (HTTP ${fnAnon.status})`);
  const fnUser = await call('/functions/v1/purge-vet-documents', { method: 'POST', token: vet.token, body: {} });
  check(fnUser.status === 401 || fnUser.status === 403, 'la purga rechaza el JWT de un usuario');
  const fnAdmin = await call('/functions/v1/purge-vet-documents', { method: 'POST', token: admin.token, body: {} });
  check(fnAdmin.status === 401 || fnAdmin.status === 403, 'la purga rechaza el JWT del admin');

  // Retención: documentos de una solicitud nunca enviada no tienen fecha de purga.
  const abandoned = await newUser('vetabandona');
  await register(abandoned, 'vet');
  const abPath = `${abandoned.id}/titulo-${stamp}.pdf`;
  await up(abandoned, abPath, pdf, 'application/pdf');
  await regDoc(abandoned, 'degree_certificate', abPath, 'application/pdf');
  const abDoc = (await rest(`vet_documents?select=purge_after&vet_id=eq.${abandoned.id}`, { token: abandoned.token })).json[0];
  known(abDoc?.purge_after != null, 'QA-06',
    'un documento de una solicitud nunca enviada tiene plazo de retención (purge_after)');
  // Nota QA-06 (revisión de código): si uploadDocument sube a Storage y falla
  // el INSERT en vet_documents, el archivo queda sin fila y la purga (que parte
  // de vet_documents) nunca lo borra.
} finally {
  // Limpieza: solo lo creado por este script.
  for (const id of created) {
    const objs = await call('/storage/v1/object/list/vet-documents', { method: 'POST', key: SRV, token: SRV,
      body: { prefix: id } });
    const names = Array.isArray(objs.json) ? objs.json.map((o) => `${id}/${o.name}`) : [];
    if (names.length) {
      await call('/storage/v1/object/vet-documents', { method: 'DELETE', key: SRV, token: SRV, body: { prefixes: names } });
    }
  }
  for (const id of createdSpecies) {
    await rest(`vet_species?species_id=eq.${id}`, { method: 'DELETE', key: SRV, token: SRV });
    await rest(`species?id=eq.${id}`, { method: 'DELETE', key: SRV, token: SRV });
  }
  // En orden inverso: los vets antes que el admin que los verificó. Si se borra
  // primero al admin, el ON DELETE SET NULL de verified_by choca con
  // private.guard_vet_profile (defecto QA-10) y el usuario queda sin borrar.
  const leftovers = [];
  for (const id of [...created].reverse()) {
    const d = await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
    if (d.status >= 300) leftovers.push(id);
  }
  if (leftovers.length) console.log(`AVISO   no se pudieron borrar ${leftovers.length} usuario(s) de prueba`);
}

console.log(`\nQA exploratorio: ${fails} FALLA(s), ${defects} DEFECTO(s) conocido(s).`);
process.exit(fails ? 1 : defects ? 2 : 0);
