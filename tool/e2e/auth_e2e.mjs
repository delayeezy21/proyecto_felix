// E2E de autenticación y registro (fase 1) contra Supabase local: Auth + PostgREST.
// Uso: node tool/e2e/auth_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;

let fails = 0;
const check = (cond, msg) => { console.log(`${cond ? 'OK  ' : 'FALLA'} ${msg}`); if (!cond) fails++; };

async function call(path, { method = 'GET', token, key = PUB, body, prefer } = {}) {
  const headers = { apikey: key, 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (prefer) headers.Prefer = prefer;
  const r = await fetch(API + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await r.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, json };
}

const stamp = Date.now();
async function newUser(tag) {
  const email = `${tag}-${stamp}@test.local`;
  const password = 'Felix2026';
  const c = await call('/auth/v1/admin/users', { method: 'POST', key: SRV, token: SRV,
    body: { email, password, email_confirm: true } });
  if (c.status >= 300) throw new Error(`crear ${tag}: ${c.status} ${JSON.stringify(c.json)}`);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password } });
  if (!s.json.access_token) throw new Error(`login ${tag}: ${s.status} ${JSON.stringify(s.json)}`);
  return s.json.access_token;
}

// Login sin confirmar el correo debe fallar (confirmación obligatoria).
const unconfirmed = `noconf-${stamp}@test.local`;
await call('/auth/v1/signup', { method: 'POST', body: { email: unconfirmed, password: 'Felix2026' } });
const noLogin = await call('/auth/v1/token?grant_type=password', { method: 'POST',
  body: { email: unconfirmed, password: 'Felix2026' } });
check(noLogin.status === 400 && /confirm/i.test(JSON.stringify(noLogin.json)),
  'no se puede entrar sin confirmar el correo');

const weak = await call('/auth/v1/signup', { method: 'POST', body: { email: `weak-${stamp}@test.local`, password: 'abc' } });
check(weak.status >= 400, 'Auth rechaza contraseñas débiles');

const terms = await call('/rest/v1/rpc/current_legal_version', { method: 'POST', body: { p_kind: 'terms' } });
const privacy = await call('/rest/v1/rpc/current_legal_version', { method: 'POST', body: { p_kind: 'privacy' } });
check(terms.status === 200 && typeof terms.json === 'string', `anónimo lee la versión de términos (${terms.json})`);

const a = await newUser('dueno');
const regA = await call('/rest/v1/rpc/complete_registration', { method: 'POST', token: a, body: {
  p_role: 'owner', p_display_name: 'Ana', p_phone: '+56 9 1234 5678',
  p_terms_version: terms.json, p_privacy_version: privacy.json } });
check(regA.status === 200 && regA.json === 'owner', 'el dueño completa el registro vía API');

const rolesA = await call('/rest/v1/user_roles?select=role', { token: a });
check(rolesA.status === 200 && rolesA.json.length === 1 && rolesA.json[0].role === 'owner',
  'el dueño lee su rol por REST');

const b = await newUser('vet');
const regB = await call('/rest/v1/rpc/complete_registration', { method: 'POST', token: b, body: {
  p_role: 'vet', p_display_name: 'Dra. Vera', p_phone: null,
  p_terms_version: terms.json, p_privacy_version: privacy.json } });
check(regB.status === 200, 'el vet completa el registro vía API');

const ownersFromVet = await call('/rest/v1/owner_profiles?select=*', { token: b });
check(ownersFromVet.status === 200 && ownersFromVet.json.length === 0, 'el vet no ve perfiles de dueños');

const selfApprove = await call('/rest/v1/vet_profiles?user_id=not.is.null', { method: 'PATCH', token: b,
  body: { status: 'approved' }, prefer: 'return=representation' });
check(selfApprove.status === 401 || selfApprove.status === 403, `el vet no puede aprobarse (HTTP ${selfApprove.status} ${JSON.stringify(selfApprove.json).slice(0,90)})`);

const roleEsc = await call('/rest/v1/user_roles?user_id=not.is.null', { method: 'PATCH', token: a, body: { role: 'admin' } });
check(roleEsc.status === 401 || roleEsc.status === 403, `el dueño no puede volverse admin (HTTP ${roleEsc.status})`);

const adminReg = await call('/rest/v1/rpc/complete_registration', { method: 'POST', token: await newUser('x'), body: {
  p_role: 'admin', p_display_name: 'X', p_phone: null, p_terms_version: terms.json, p_privacy_version: privacy.json } });
check(adminReg.status >= 400, 'nadie puede autorregistrarse como admin');

const anonRoles = await call('/rest/v1/user_roles?select=*');
check(anonRoles.status === 401 || anonRoles.status === 403, `anónimo no lee roles (HTTP ${anonRoles.status})`);

const privateRpc = await call('/rest/v1/rpc/is_admin', { method: 'POST', token: a, body: {} });
check(privateRpc.status === 404, `los helpers de private no se exponen por la API (HTTP ${privateRpc.status})`);

console.log(fails === 0 ? '\nE2E fase 1: TODO OK' : `\nE2E fase 1: ${fails} fallas`);
process.exit(fails ? 1 : 0);
