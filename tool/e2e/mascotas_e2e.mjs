// E2E de la fase 4 (mascotas y direcciones) contra Supabase local: Auth + REST.
// Uso: node tool/e2e/mascotas_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
// Crea usuarios ficticios y los borra al final (las mascotas y direcciones se
// van en cascada con el perfil).
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
  terms: (await call('/rest/v1/rpc/current_legal_version', { method: 'POST', body: { p_kind: 'terms' } })).json,
  privacy: (await call('/rest/v1/rpc/current_legal_version', { method: 'POST', body: { p_kind: 'privacy' } })).json,
};
async function register(u, role, name, communeId = null) {
  return call('/rest/v1/rpc/complete_registration', { method: 'POST', token: u.token, body: {
    p_role: role, p_display_name: name, p_phone: null,
    p_terms_version: legal.terms, p_privacy_version: legal.privacy, p_commune_id: communeId } });
}

try {
  const ownerA = await newUser('dueno-a-f4');
  const ownerB = await newUser('dueno-b-f4');
  const vet = await newUser('vet-f4');
  const admin = await newUser('admin-f4');
  await call('/rest/v1/user_roles', { method: 'POST', key: SRV, token: SRV, body: { user_id: admin.id, role: 'admin' } });

  const nunoa = (await call('/rest/v1/communes?select=id&name=eq.%C3%91u%C3%B1oa', { token: ownerA.token })).json[0].id;
  check((await register(ownerA, 'owner', 'Ana Ficticia', nunoa)).status === 200, 'el dueño A completa su registro');
  check((await register(ownerB, 'owner', 'Beto Ficticio', nunoa)).status === 200, 'el dueño B completa su registro');
  check((await register(vet, 'vet', 'Dra. Ficticia')).status === 200, 'el vet completa su registro');

  const perro = (await call('/rest/v1/species?select=id&slug=eq.perro', { token: ownerA.token })).json[0].id;
  const gato = (await call('/rest/v1/species?select=id&slug=eq.gato', { token: ownerA.token })).json[0].id;
  const breeds = (await call(`/rest/v1/breeds?select=id,name&species_id=eq.${perro}&active=is.true`, { token: ownerA.token })).json;
  const beagle = breeds.find((b) => b.name === 'Beagle').id;
  check(breeds.length > 0, `las razas se filtran por especie (${breeds.length} de perro)`);

  // --- Dueño A: crea, lee, edita y desactiva -----------------------------------
  const pet = await call('/rest/v1/pets?select=id,name,active', { method: 'POST', token: ownerA.token, prefer: 'return=representation',
    body: { owner_id: ownerA.id, name: 'Firulais', species_id: perro, breed_id: beagle, sex: 'male',
            birth_date_approx: '2020-03-01', sterilized: true, microchip: '152000000000001' } });
  check(pet.status === 201 && pet.json[0].name === 'Firulais', 'el dueño A registra una mascota');
  const petId = pet.json[0]?.id;

  const addr = await call('/rest/v1/addresses?select=id', { method: 'POST', token: ownerA.token, prefer: 'return=representation',
    body: { owner_id: ownerA.id, label: 'Casa', street_text: 'Av. Ficticia 123', commune_id: nunoa, lat: -33.4569, lng: -70.5974 } });
  check(addr.status === 201, 'el dueño A guarda una dirección con coordenadas');
  const addrId = addr.json[0]?.id;

  const listA = await call('/rest/v1/pets?select=id,name,microchip,species(name),breeds(name)', { token: ownerA.token });
  check(listA.json.length === 1 && listA.json[0].species.name === 'Perro' && listA.json[0].breeds.name === 'Beagle',
    'el dueño A lista su mascota con especie y raza en una sola consulta');
  const addrA = await call('/rest/v1/addresses?select=id,street_text,lat,lng,communes(name)', { token: ownerA.token });
  check(addrA.json.length === 1 && addrA.json[0].communes.name === 'Ñuñoa' && addrA.json[0].lat === -33.4569,
    'el dueño A ve su dirección exacta y su comuna');

  const edit = await call(`/rest/v1/pets?id=eq.${petId}`, { method: 'PATCH', token: ownerA.token, prefer: 'return=representation',
    body: { name: 'Firu', sterilized: false } });
  check(edit.status === 200 && edit.json[0]?.name === 'Firu', 'el dueño A edita su mascota');

  const forgeOwner = await call(`/rest/v1/pets?id=eq.${petId}`, { method: 'PATCH', token: ownerA.token, body: { owner_id: ownerB.id } });
  check(forgeOwner.status === 403, `no puede reasignar la mascota a otro dueño (HTTP ${forgeOwner.status})`);
  const forgeCol = await call('/rest/v1/pets', { method: 'POST', token: ownerA.token,
    body: { owner_id: ownerA.id, name: 'X', species_id: gato, created_at: '2000-01-01T00:00:00Z' } });
  check(forgeCol.status === 403, `no puede fijar columnas de sistema (HTTP ${forgeCol.status})`);
  const forgeLoc = await call(`/rest/v1/addresses?id=eq.${addrId}`, { method: 'PATCH', token: ownerA.token,
    body: { location: 'SRID=4326;POINT(-70 -30)' } });
  check(forgeLoc.status >= 400, `location es derivada: no se escribe directo (HTTP ${forgeLoc.status})`);

  const badBreed = await call('/rest/v1/pets', { method: 'POST', token: ownerA.token,
    body: { owner_id: ownerA.id, name: 'X', species_id: gato, breed_id: beagle } });
  check(badBreed.status === 400 && /raza/i.test(badBreed.json.message), 'rechaza una raza de otra especie (HU1.2)');
  const badSpecies = await call('/rest/v1/pets', { method: 'POST', token: ownerA.token,
    body: { owner_id: ownerA.id, name: 'X', species_id: 999999 } });
  check(badSpecies.status === 400, 'rechaza una especie inexistente (HU1.2)');
  const badChip = await call('/rest/v1/pets', { method: 'POST', token: ownerA.token,
    body: { owner_id: ownerA.id, name: 'X', species_id: gato, microchip: '123' } });
  check(badChip.status === 400, 'rechaza un microchip inválido');
  const foreignPoint = await call('/rest/v1/addresses', { method: 'POST', token: ownerA.token,
    body: { owner_id: ownerA.id, label: 'Madrid', street_text: 'Gran Vía 1', commune_id: nunoa, lat: 40.42, lng: -3.70 } });
  check(foreignPoint.status === 400, 'rechaza coordenadas fuera de Chile');

  const del = await call(`/rest/v1/pets?id=eq.${petId}`, { method: 'DELETE', token: ownerA.token });
  check(del.status === 403, `el dueño no borra mascotas: se desactivan (HTTP ${del.status})`);
  const deact = await call(`/rest/v1/addresses?id=eq.${addrId}`, { method: 'PATCH', token: ownerA.token, prefer: 'return=representation',
    body: { active: false } });
  check(deact.status === 200 && deact.json[0]?.active === false, 'el dueño desactiva una dirección');
  await call(`/rest/v1/addresses?id=eq.${addrId}`, { method: 'PATCH', token: ownerA.token, body: { active: true } });

  // --- Otro dueño ----------------------------------------------------------------
  const listB = await call('/rest/v1/pets?select=id', { token: ownerB.token });
  const addrB = await call('/rest/v1/addresses?select=id', { token: ownerB.token });
  check(listB.json.length === 0 && addrB.json.length === 0, 'el dueño B no ve mascotas ni direcciones de A');
  const byIdB = await call(`/rest/v1/addresses?select=street_text,lat&id=eq.${addrId}`, { token: ownerB.token });
  check(byIdB.json.length === 0, 'el dueño B no lee la dirección de A aunque conozca su id');
  const patchB = await call(`/rest/v1/pets?id=eq.${petId}`, { method: 'PATCH', token: ownerB.token, prefer: 'return=representation',
    body: { name: 'Hackeado' } });
  check(patchB.status === 200 && patchB.json.length === 0, 'el dueño B no modifica la mascota de A (0 filas)');
  const patchAddrB = await call(`/rest/v1/addresses?id=eq.${addrId}`, { method: 'PATCH', token: ownerB.token, prefer: 'return=representation',
    body: { street_text: 'Hackeada 1' } });
  check(patchAddrB.json.length === 0, 'el dueño B no modifica la dirección de A (0 filas)');
  const intrude = await call('/rest/v1/pets', { method: 'POST', token: ownerB.token,
    body: { owner_id: ownerA.id, name: 'Intrusa', species_id: gato } });
  check(intrude.status === 403, 'el dueño B no crea mascotas a nombre de A');

  // --- Vet ---------------------------------------------------------------------------
  const vetPets = await call('/rest/v1/pets?select=id', { token: vet.token });
  const vetAddr = await call('/rest/v1/addresses?select=id', { token: vet.token });
  check(vetPets.json.length === 0 && vetAddr.json.length === 0, 'un vet no ve mascotas ni direcciones');
  const vetIns = await call('/rest/v1/pets', { method: 'POST', token: vet.token, body: { owner_id: vet.id, name: 'X', species_id: gato } });
  check(vetIns.status === 403, 'un vet no registra mascotas');
  const vetPatch = await call(`/rest/v1/addresses?id=eq.${addrId}`, { method: 'PATCH', token: vet.token, prefer: 'return=representation',
    body: { label: 'Vet' } });
  check(vetPatch.json.length === 0, 'un vet no modifica direcciones');

  // --- Admin (minimización: no ve mascotas ni direcciones) ---------------------------
  const admPets = await call('/rest/v1/pets?select=id,microchip', { token: admin.token });
  const admAddr = await call('/rest/v1/addresses?select=id', { token: admin.token });
  check(admPets.json.length === 0 && admAddr.json.length === 0, 'el admin no ve mascotas, microchips ni direcciones');
  const admPatch = await call(`/rest/v1/pets?id=eq.${petId}`, { method: 'PATCH', token: admin.token, prefer: 'return=representation',
    body: { name: 'Admin' } });
  check(admPatch.json.length === 0, 'el admin no modifica mascotas');

  // --- Anónimo ---------------------------------------------------------------------------
  const anonPets = await call('/rest/v1/pets?select=id');
  const anonAddr = await call('/rest/v1/addresses?select=id');
  check(anonPets.status >= 400 && anonAddr.status >= 400,
    `un anónimo no lee mascotas ni direcciones (HTTP ${anonPets.status}/${anonAddr.status})`);
  const anonIns = await call('/rest/v1/pets', { method: 'POST', body: { owner_id: ownerA.id, name: 'X', species_id: gato } });
  check(anonIns.status >= 400, 'un anónimo no crea mascotas');

  // --- Helper de la fase 6: no expuesto ----------------------------------------------------
  const approx = await call('/rest/v1/rpc/address_approx', { method: 'POST', token: vet.token, body: { p_address: addrId } });
  check(approx.status >= 400, `el helper de ubicación aproximada no está en la API (HTTP ${approx.status})`);

  // --- Estado final: nada cambió --------------------------------------------------------------
  const final = await call(`/rest/v1/pets?select=name&id=eq.${petId}`, { token: ownerA.token });
  const finalAddr = await call(`/rest/v1/addresses?select=street_text,label&id=eq.${addrId}`, { token: ownerA.token });
  check(final.json[0]?.name === 'Firu' && finalAddr.json[0]?.street_text === 'Av. Ficticia 123' && finalAddr.json[0]?.label === 'Casa',
    'los datos de A siguen intactos tras los intentos ajenos');
} finally {
  for (const id of created) {
    await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
  }
}

console.log(fails === 0 ? '\nE2E fase 4: TODO OK' : `\nE2E fase 4: ${fails} fallas`);
process.exit(fails ? 1 : 0);
