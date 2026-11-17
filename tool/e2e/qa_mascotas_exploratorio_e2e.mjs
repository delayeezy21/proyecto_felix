// QA exploratorio de la fase 4 (mascotas y direcciones) contra Supabase local:
// Auth + REST. Complementa mascotas_e2e.mjs con casos de borde, mass
// assignment y concurrencia sobre los topes (20 mascotas / 10 direcciones).
//
// Uso: node tool/e2e/qa_mascotas_exploratorio_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
//
// Convención:
//   OK      el comportamiento esperado se cumple.
//   FALLA   regresión de algo que debería funcionar (sale con código 1).
//   DEFECTO defecto conocido y documentado en docs/qa/ (sale con código 2 si no
//           hay FALLAs). Cuando se corrija, la línea pasa a OK sola.
//
// Solo crea usuarios *@test.local y los borra al final (cascada a sus filas).
const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;

let fails = 0;
let defects = 0;
const check = (cond, msg) => {
  console.log(`${cond ? 'OK     ' : 'FALLA  '} ${msg}`);
  if (!cond) fails++;
};
const known = (cond, id, msg) => {
  console.log(`${cond ? 'OK     ' : `DEFECTO ${id}`} ${msg}`);
  if (!cond) defects++;
};

async function call(path, { method = 'GET', token, key = PUB, body, prefer, headers: extra } = {}) {
  const headers = { apikey: key, ...extra };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (prefer) headers.Prefer = prefer;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(API + path, { method, headers, body: body !== undefined ? JSON.stringify(body) : undefined });
  const text = await r.text();
  let json;
  try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, json };
}
const rest = (path, opts) => call(`/rest/v1/${path}`, opts);
const rpc = (fn, token, body = {}, extra = {}) => rest(`rpc/${fn}`, { method: 'POST', token, body, ...extra });

const stamp = Date.now();
const created = [];
async function newUser(tag) {
  const email = `qa-f4-${tag}-${stamp}@test.local`;
  const c = await call('/auth/v1/admin/users', { method: 'POST', key: SRV, token: SRV,
    body: { email, password: 'Felix2026', email_confirm: true } });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status}`);
  created.push(c.json.id);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password: 'Felix2026' } });
  return { token: s.json.access_token, id: c.json.id };
}
const legal = {
  terms: (await rpc('current_legal_version', undefined, { p_kind: 'terms' })).json,
  privacy: (await rpc('current_legal_version', undefined, { p_kind: 'privacy' })).json,
};
const communeId = async (name) => (await rest(`communes?select=id&name=eq.${encodeURIComponent(name)}`, { key: SRV, token: SRV })).json[0].id;
const register = (u, role, commune = null) => rpc('complete_registration', u.token, {
  p_role: role, p_display_name: `QA ${role}`, p_phone: null,
  p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: commune,
});

try {
  const nunoa = await communeId('Ñuñoa');
  const arica = await communeId('Arica');
  const perro = (await rest('species?select=id&slug=eq.perro', { key: SRV, token: SRV })).json[0].id;
  const gato = (await rest('species?select=id&slug=eq.gato', { key: SRV, token: SRV })).json[0].id;
  const beagle = (await rest(`breeds?select=id&species_id=eq.${perro}&name=eq.Beagle`, { key: SRV, token: SRV })).json[0].id;

  const a = await newUser('a');
  const b = await newUser('b');
  const vet = await newUser('vet');
  const admin = await newUser('admin');
  check((await register(a, 'owner', nunoa)).status === 200, 'dueño A registrado');
  check((await register(b, 'owner', nunoa)).status === 200, 'dueño B registrado');
  check((await register(vet, 'vet')).status === 200, 'vet registrado');
  await rest('user_roles', { method: 'POST', key: SRV, token: SRV, body: { user_id: admin.id, role: 'admin' } });

  const pet = (await rest('pets?select=id', { method: 'POST', token: a.token, prefer: 'return=representation',
    body: { owner_id: a.id, name: 'Base', species_id: perro, breed_id: beagle } })).json[0].id;
  const addr = (await rest('addresses?select=id', { method: 'POST', token: a.token, prefer: 'return=representation',
    body: { owner_id: a.id, label: 'Casa', street_text: 'Calle Ficticia 1', commune_id: nunoa, lat: -33.4569, lng: -70.5974 } })).json[0].id;

  // ---- Mass assignment --------------------------------------------------------
  const fixedId = '00000000-0000-4000-8000-000000000001';
  for (const [col, val] of [['id', fixedId], ['active', false], ['updated_at', '2000-01-01T00:00:00Z']]) {
    const r = await rest('pets', { method: 'POST', token: a.token, body: { owner_id: a.id, name: 'MA', species_id: gato, [col]: val } });
    check(r.status === 403, `INSERT pets con ${col} no permitido (HTTP ${r.status})`);
  }
  for (const [col, val] of [['id', fixedId], ['owner_id', b.id], ['created_at', '2000-01-01T00:00:00Z']]) {
    const r = await rest(`pets?id=eq.${pet}`, { method: 'PATCH', token: a.token, body: { [col]: val } });
    check(r.status === 403, `PATCH pets.${col} no permitido (HTTP ${r.status})`);
  }
  for (const [col, val] of [['id', fixedId], ['active', false], ['location', 'SRID=4326;POINT(-70 -33)']]) {
    const r = await rest('addresses', { method: 'POST', token: a.token,
      body: { owner_id: a.id, label: 'MA', street_text: 'Calle 2', commune_id: nunoa, lat: -33.45, lng: -70.6, [col]: val } });
    check(r.status >= 400, `INSERT addresses con ${col} no permitido (HTTP ${r.status})`);
  }
  const patchOwnerAddr = await rest(`addresses?id=eq.${addr}`, { method: 'PATCH', token: a.token, body: { owner_id: b.id } });
  check(patchOwnerAddr.status === 403, `PATCH addresses.owner_id no permitido (HTTP ${patchOwnerAddr.status})`);
  // El admin tampoco puede reasignar (ni siquiera ve la fila).
  const admOwner = await rest(`pets?id=eq.${pet}`, { method: 'PATCH', token: admin.token, prefer: 'return=representation', body: { owner_id: admin.id } });
  check(admOwner.status === 403 || (admOwner.status === 200 && admOwner.json.length === 0), `admin no reasigna owner_id (HTTP ${admOwner.status})`);
  // Upsert con id ajeno: no se puede fijar id, así que no pisa filas.
  const upsert = await rest('pets?on_conflict=id', { method: 'POST', token: b.token, prefer: 'resolution=merge-duplicates',
    body: { id: pet, owner_id: b.id, name: 'Upsert', species_id: gato } });
  check(upsert.status === 403, `upsert sobre la mascota de A rechazado (HTTP ${upsert.status})`);
  // DELETE por cualquiera
  for (const [who, tok] of [['A', a.token], ['B', b.token], ['admin', admin.token], ['vet', vet.token]]) {
    const d = await rest(`addresses?id=eq.${addr}`, { method: 'DELETE', token: tok });
    check(d.status === 403, `DELETE dirección por ${who} rechazado (HTTP ${d.status})`);
  }
  const anonDel = await rest(`pets?id=eq.${pet}`, { method: 'DELETE' });
  check(anonDel.status >= 400, `DELETE anónimo rechazado (HTTP ${anonDel.status})`);

  // ---- Fugas por filtros y embebidos ----------------------------------------------------
  const byOwner = await rest(`pets?select=id&owner_id=eq.${a.id}`, { token: b.token });
  check(byOwner.json.length === 0, 'B filtrando por owner_id de A no ve nada');
  const embedAdm = await rest(`owner_profiles?select=user_id,pets(id,microchip),addresses(street_text)&user_id=eq.${a.id}`, { token: admin.token });
  const row = Array.isArray(embedAdm.json) ? embedAdm.json[0] : null;
  check(embedAdm.status >= 400 || !row || ((row.pets ?? []).length === 0 && (row.addresses ?? []).length === 0),
    `admin no obtiene mascotas/direcciones embebidas en owner_profiles (HTTP ${embedAdm.status})`);
  const countB = await rest('pets?select=count', { token: b.token });
  check(countB.json?.[0]?.count === 0, 'B no infiere el número de mascotas ajenas con count');
  const headB = await call(`/rest/v1/addresses?select=id&id=eq.${addr}`, { method: 'HEAD', token: b.token, prefer: 'count=exact' });
  check(headB.status < 300, 'HEAD/count de B sobre la dirección de A no revela existencia');

  // ---- address_approx -----------------------------------------------------------------------
  for (const [who, tok] of [['vet', vet.token], ['admin', admin.token], ['dueño', a.token], ['anónimo', undefined]]) {
    const r = await rpc('address_approx', tok, { p_address: addr, p_from: 'SRID=4326;POINT(-70.6 -33.4)' },
      { headers: { 'Content-Profile': 'private' } });
    check(r.status >= 400, `address_approx vía schema private por ${who} rechazado (HTTP ${r.status})`);
  }

  // ---- Validaciones de datos ----------------------------------------------------------------
  const v = async (body) => rest('pets', { method: 'POST', token: a.token, body: { owner_id: a.id, species_id: gato, ...body } });
  check((await v({ name: '    ' })).status === 400, 'nombre solo con espacios rechazado');
  check((await v({ name: 'X'.repeat(41) })).status === 400, 'nombre de 41 caracteres rechazado');
  check((await v({ name: 'Fut', birth_date_approx: '2999-01-01' })).status === 400, 'fecha de nacimiento futura rechazada');
  check((await v({ name: 'Sex', sex: 'other' })).status === 400, 'sexo inválido rechazado');
  const chMut = await rest(`pets?id=eq.${pet}`, { method: 'PATCH', token: a.token, body: { species_id: gato } });
  check(chMut.status === 400, `cambiar la especie dejando una raza de perro se rechaza (HTTP ${chMut.status})`);

  const addrTry = (lat, lng, extra = {}) => rest('addresses', { method: 'POST', token: a.token, prefer: 'return=representation',
    body: { owner_id: a.id, label: 'T', street_text: 'Calle prueba', commune_id: nunoa, lat, lng, ...extra } });
  check((await addrTry(-12.05, -77.04)).status === 400, 'Lima (Perú) rechazada');
  check((await addrTry(-34.60, -58.38)).status === 400, 'Buenos Aires rechazada');
  check((await addrTry('NaN', -70.6)).status === 400, 'lat NaN rechazada');
  check((await addrTry('Infinity', -70.6)).status === 400, 'lat Infinity rechazada');
  const mendoza = await addrTry(-32.889, -68.845);
  known(mendoza.status === 400, 'QA-F4-01', `Mendoza (Argentina) rechazada como fuera de Chile (HTTP ${mendoza.status})`);
  const mismatch = await addrTry(-33.4569, -70.5974, { commune_id: arica });
  known(mismatch.status === 400, 'QA-F4-02', `coordenadas de Ñuñoa con comuna Arica rechazadas (HTTP ${mismatch.status})`);
  // Deja A con solo la dirección base activa.
  for (const r of [mendoza, mismatch]) if (r.status === 201) await rest(`addresses?id=eq.${r.json[0].id}`, { method: 'PATCH', token: a.token, body: { active: false } });

  // ---- Topes en concurrencia -----------------------------------------------------------------
  const c = await newUser('conc');
  await register(c, 'owner', nunoa);
  const par = await Promise.all(Array.from({ length: 30 }, (_, i) =>
    rest('pets', { method: 'POST', token: c.token, body: { owner_id: c.id, name: `P${i}`, species_id: gato } })));
  const okPets = par.filter((r) => r.status === 201).length;
  const activePets = (await rest('pets?select=id&active=is.true', { token: c.token })).json.length;
  check(okPets === 20 && activePets === 20, `30 altas paralelas de mascotas: ${okPets} aceptadas, ${activePets} activas (tope 20)`);
  const rej = par.find((r) => r.status !== 201);
  check(rej && rej.status === 400 && /20 mascotas/.test(rej.json.message), `el rechazo explica el tope (HTTP ${rej?.status}: ${rej?.json?.message})`);

  const parA = await Promise.all(Array.from({ length: 15 }, (_, i) =>
    rest('addresses', { method: 'POST', token: c.token,
      body: { owner_id: c.id, label: `D${i}`, street_text: `Calle ${i}`, commune_id: nunoa, lat: -33.45, lng: -70.6 } })));
  const okAddr = parA.filter((r) => r.status === 201).length;
  const activeAddr = (await rest('addresses?select=id&active=is.true', { token: c.token })).json.length;
  check(okAddr === 10 && activeAddr === 10, `15 altas paralelas de direcciones: ${okAddr} aceptadas, ${activeAddr} activas (tope 10)`);

  // Inserción masiva en una sola petición (arreglo JSON).
  const d = await newUser('bulk');
  await register(d, 'owner', nunoa);
  const bulk = await rest('pets', { method: 'POST', token: d.token,
    body: Array.from({ length: 25 }, (_, i) => ({ owner_id: d.id, name: `B${i}`, species_id: gato })) });
  const bulkActive = (await rest('pets?select=id&active=is.true', { token: d.token })).json.length;
  check(bulk.status === 400 && bulkActive === 0, `bulk de 25 mascotas en una petición rechazado completo (HTTP ${bulk.status}, activas ${bulkActive})`);
  const bulkA = await rest('addresses', { method: 'POST', token: d.token,
    body: Array.from({ length: 11 }, (_, i) => ({ owner_id: d.id, label: `D${i}`, street_text: `Calle ${i}`, commune_id: nunoa, lat: -33.45, lng: -70.6 })) });
  const bulkAActive = (await rest('addresses?select=id&active=is.true', { token: d.token })).json.length;
  check(bulkA.status === 400 && bulkAActive === 0, `bulk de 11 direcciones rechazado completo (HTTP ${bulkA.status}, activas ${bulkAActive})`);

  // Reactivar por encima del tope (desactivar 1, crear 1, reactivar la primera).
  const cPets = (await rest('pets?select=id&order=created_at', { token: c.token })).json;
  await rest(`pets?id=eq.${cPets[0].id}`, { method: 'PATCH', token: c.token, body: { active: false } });
  const refill = await rest('pets', { method: 'POST', token: c.token, body: { owner_id: c.id, name: 'Refill', species_id: gato } });
  check(refill.status === 201, 'tras desactivar una, se puede crear otra (vuelve a 20)');
  const react = await rest(`pets?id=eq.${cPets[0].id}`, { method: 'PATCH', token: c.token, body: { active: true } });
  check(react.status === 400, `reactivar la 21.ª mascota se rechaza (HTTP ${react.status})`);
  // Reactivaciones en paralelo de varias inactivas.
  const cP2 = (await rest('pets?select=id&active=is.true&order=created_at', { token: c.token })).json.slice(0, 3);
  for (const p of cP2) await rest(`pets?id=eq.${p.id}`, { method: 'PATCH', token: c.token, body: { active: false } });
  const reacts = await Promise.all([cPets[0], ...cP2].map((p) =>
    rest(`pets?id=eq.${p.id}`, { method: 'PATCH', token: c.token, body: { active: true } })));
  const after = (await rest('pets?select=id&active=is.true', { token: c.token })).json.length;
  check(after === 20, `4 reactivaciones paralelas con 3 cupos: ${reacts.filter((r) => r.status < 300).length} OK, activas ${after} (tope 20)`);
} finally {
  for (const id of created) await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
}

console.log(fails ? `\nQA fase 4: ${fails} FALLAS, ${defects} defectos conocidos` :
  defects ? `\nQA fase 4: sin fallas; ${defects} defectos conocidos` : '\nQA fase 4: TODO OK');
process.exit(fails ? 1 : defects ? 2 : 0);
