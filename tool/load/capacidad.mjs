// Prueba de capacidad para ~5.000 usuarios registrados (docs/qa/capacidad-5000.md).
//
// SOLO contra un stack local AISLADO (otro project_id y puertos) cargado con
// tool/load/seed_carga.sql. Nunca contra la nube ni contra el stack compartido.
//
// Modelo: 5.000 registrados → ~500 activos al día → picos de 50–100 sesiones
// concurrentes. Cada usuario virtual (VU) inicia sesión, recorre los flujos de
// la app con un tiempo de "pensar" entre pantallas y cada tanto vuelve a
// iniciar sesión con otro usuario. Las fases corren EN SECUENCIA.
//
// Uso:
//   LOAD_ALLOW_URL=http://127.0.0.1:<puerto> node tool/load/capacidad.mjs "$(npx --yes supabase@3.2.0 status --workdir <dir> -o json | sed -n '/^{/,$p')"
// Variables opcionales:
//   LOAD_PHASES=10,25,50,100   VUs por fase
//   LOAD_PHASE_SECONDS=60      duración de cada fase
//   LOAD_THINK_MS=1000         pausa media entre pantallas (±50 %)
//   LOAD_OUT=archivo.json      guarda los resultados
// Código de salida: 0 si no hubo errores ni fugas de RLS; 1 si los hubo.

import { writeFileSync } from 'node:fs';

const status = JSON.parse(process.argv[2] ?? '{}');
const API = status.API_URL;
const KEY = status.PUBLISHABLE_KEY ?? status.ANON_KEY;
if (!API || !KEY) {
  console.error('Falta el JSON de `supabase status -o json` (API_URL y PUBLISHABLE_KEY).');
  process.exit(2);
}
const host = new URL(API).hostname;
if (!['127.0.0.1', 'localhost'].includes(host)) {
  console.error(`Rechazado: ${API} no es local. Esta prueba es solo para un stack aislado.`);
  process.exit(2);
}
// QA-28: hay que nombrar explícitamente el stack de carga.
const ALLOW = process.env.LOAD_ALLOW_URL ?? '';
const norm = (u) => u.replace(/\/+$/, '').replace('localhost', '127.0.0.1');
if (!ALLOW) {
  console.error('Falta LOAD_ALLOW_URL=<API_URL del stack de carga> (ej.: http://127.0.0.1:55641).');
  process.exit(2);
}
if (norm(ALLOW) !== norm(API)) {
  console.error(`Rechazado: API_URL (${API}) no coincide con LOAD_ALLOW_URL (${ALLOW}).`);
  process.exit(2);
}
if (/^543\d\d$/.test(new URL(API).port)) {
  console.error('Rechazado: los puertos 543xx son del stack compartido. Usa un stack aislado.');
  process.exit(2);
}

const PHASES = (process.env.LOAD_PHASES ?? '10,25,50,100').split(',').map(Number);
const PHASE_MS = Number(process.env.LOAD_PHASE_SECONDS ?? 60) * 1000;
const THINK_MS = Number(process.env.LOAD_THINK_MS ?? 1000);
const PASSWORD = 'Carga-Felix-2026!';
const OWNERS = 4699;
const VETS = 300;
const ITER_PER_SESSION = 8;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rnd = (n) => Math.floor(Math.random() * n);
const think = () => sleep(THINK_MS * (0.5 + Math.random()));
const pad = (n) => String(n).padStart(4, '0');

// ---------------------------------------------------------------- métricas
let metrics = new Map();
let rlsLeaks = 0;
function record(label, ms, ok, statusCode) {
  let m = metrics.get(label);
  if (!m) metrics.set(label, (m = { lat: [], errors: 0, codes: {} }));
  m.lat.push(ms);
  if (!ok) {
    m.errors++;
    m.codes[statusCode] = (m.codes[statusCode] ?? 0) + 1;
  }
}
const pct = (sorted, p) =>
  sorted.length ? sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)] : 0;

async function call(label, path, { method = 'GET', token, body, prefer } = {}) {
  const headers = { apikey: KEY, 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (prefer) headers.Prefer = prefer;
  const t0 = performance.now();
  let res;
  try {
    res = await fetch(API + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await res.text();
    const ms = performance.now() - t0;
    record(label, ms, res.ok, res.status);
    return { status: res.status, ok: res.ok, data: text ? JSON.parse(text) : null };
  } catch (e) {
    record(label, performance.now() - t0, false, e.cause?.code ?? 'network');
    return { status: 0, ok: false, data: null };
  }
}

// ---------------------------------------------------------------- sesión
async function login(email) {
  const r = await call('auth: login (password)', '/auth/v1/token?grant_type=password', {
    method: 'POST',
    body: { email, password: PASSWORD },
  });
  if (!r.ok) return null;
  return { token: r.data.access_token, refresh: r.data.refresh_token, uid: r.data.user.id };
}

async function refresh(s) {
  const r = await call('auth: refresh token', '/auth/v1/token?grant_type=refresh_token', {
    method: 'POST',
    body: { refresh_token: s.refresh },
  });
  if (r.ok) {
    s.token = r.data.access_token;
    s.refresh = r.data.refresh_token;
  }
}

// ---------------------------------------------------------------- flujos
// Inicio de la app (splash): rol y perfil propio, filtrando por auth.uid().
async function home(s, role) {
  await call('perfil: user_roles propio', `/rest/v1/user_roles?select=role&user_id=eq.${s.uid}`, { token: s.token });
  if (role === 'owner') {
    await call('perfil: owner_profiles propio', `/rest/v1/owner_profiles?select=display_name&user_id=eq.${s.uid}`, { token: s.token });
  } else {
    await call('perfil: vet_profiles propio', `/rest/v1/vet_profiles?select=display_name,status&user_id=eq.${s.uid}`, { token: s.token });
  }
  await call('legal: current_legal_version', '/rest/v1/rpc/current_legal_version', {
    method: 'POST', token: s.token, body: { p_kind: 'terms' },
  });
}

async function catalogs(s) {
  await call('catálogo: regions', '/rest/v1/regions?select=id,name&order=sort', { token: s.token });
  await call('catálogo: communes por región', `/rest/v1/communes?select=id,region_id,name&region_id=eq.${1 + rnd(16)}&order=name`, { token: s.token });
  await call('catálogo: species', '/rest/v1/species?select=id,slug,name,active&order=sort,name', { token: s.token });
  await call('catálogo: specialties', '/rest/v1/specialties?select=id,slug,name,active&order=sort,name', { token: s.token });
  await call('catálogo: emergency_clinics', '/rest/v1/emergency_clinics?select=id,name,commune_id,address,phone,active,communes(name)&order=name', { token: s.token });
}

// El dueño NO debe ver perfiles de vets (RLS). Se mide el costo y se verifica
// que siga en 0 filas a esta escala.
async function ownerVetList(s) {
  const r = await call('vets aprobados (dueño, RLS = 0 filas)', '/rest/v1/vet_profiles?select=user_id,display_name&status=eq.approved&limit=50', { token: s.token });
  if (r.ok && Array.isArray(r.data) && r.data.length > 0) rlsLeaks++;
}

async function vetSelf(s) {
  await call('vet: perfil profesional', `/rest/v1/vet_profiles?select=*&user_id=eq.${s.uid}`, { token: s.token });
  await call('vet: especies propias', `/rest/v1/vet_species?select=species_id&vet_id=eq.${s.uid}`, { token: s.token });
  await call('vet: especialidades propias', `/rest/v1/vet_specialties?select=specialty_id&vet_id=eq.${s.uid}`, { token: s.token });
  await call('vet: horario', `/rest/v1/vet_availability?select=id,weekday,start_min,end_min&vet_id=eq.${s.uid}&order=weekday,start_min`, { token: s.token });
  await call('vet: documentos', `/rest/v1/vet_documents?select=id,kind,mime,size_bytes,uploaded_at,review_status,purged_at&vet_id=eq.${s.uid}&order=uploaded_at.desc`, { token: s.token });
}

const vetIds = [];
async function adminViews(s) {
  const pending = await call('admin: solicitudes pendientes', '/rest/v1/vet_profiles?select=user_id,display_name,university,submitted_at&status=eq.pending&submitted_at=not.is.null&order=submitted_at', { token: s.token });
  const approved = await call('admin: vets aprobados', '/rest/v1/vet_profiles?select=user_id,display_name,university,reviewed_at&status=eq.approved&order=display_name&limit=50', { token: s.token });
  for (const r of [pending, approved]) {
    if (r.ok && vetIds.length < 400) for (const v of r.data) vetIds.push(v.user_id);
  }
  const id = vetIds[rnd(vetIds.length)];
  if (id) {
    await call('admin: detalle vet (perfil)', `/rest/v1/vet_profiles?select=*&user_id=eq.${id}`, { token: s.token });
    await call('admin: detalle vet (especies)', `/rest/v1/vet_species?select=species(name)&vet_id=eq.${id}`, { token: s.token });
    await call('admin: detalle vet (especialidades)', `/rest/v1/vet_specialties?select=specialties(name)&vet_id=eq.${id}`, { token: s.token });
    await call('admin: detalle vet (documentos)', `/rest/v1/vet_documents?select=id,kind,mime,size_bytes,uploaded_at,review_status,purged_at&vet_id=eq.${id}&order=uploaded_at.desc`, { token: s.token });
    await call('admin: detalle vet (verificaciones)', `/rest/v1/vet_title_verifications?select=source,outcome,risk,suggested_checks,created_at&vet_id=eq.${id}&order=created_at.desc&limit=5`, { token: s.token });
  }
  await call('admin: tarifas', '/rest/v1/tariffs?select=id,base_price,active,specialties(name),species(name)&order=specialty_id', { token: s.token });
  await call('admin: pricing_config vigente', '/rest/v1/pricing_config?select=*&order=effective_from.desc&limit=1', { token: s.token });
  await call('admin: bitácora (50 últimos)', '/rest/v1/admin_audit_log?select=id,actor_id,table_name,action,at&order=at.desc&limit=50', { token: s.token });
}

// ---------------------------------------------------------------- VU
function pickUser(vuIndex) {
  // ~3 % de los VUs son el admin (1–3 sesiones), ~10 % vets y el resto dueños.
  if (vuIndex % 33 === 0) return { role: 'admin', email: 'carga-admin@carga.felix.test' };
  if (vuIndex % 10 === 1) return { role: 'vet', email: `carga-vet-${pad(1 + rnd(VETS))}@carga.felix.test` };
  return { role: 'owner', email: `carga-owner-${pad(301 + rnd(OWNERS))}@carga.felix.test` };
}

async function vu(index, deadline) {
  await sleep(rnd(5000)); // rampa de 5 s
  while (Date.now() < deadline) {
    const { role, email } = pickUser(index);
    const s = await login(email);
    if (!s) {
      await think();
      continue;
    }
    await home(s, role);
    for (let i = 0; i < ITER_PER_SESSION && Date.now() < deadline; i++) {
      await think();
      if (role === 'admin') await adminViews(s);
      else if (role === 'vet') await (i % 2 ? vetSelf(s) : catalogs(s));
      else await (i % 3 === 0 ? catalogs(s) : i % 3 === 1 ? ownerVetList(s) : home(s, role));
      if (i === ITER_PER_SESSION / 2) await refresh(s);
    }
  }
}

// ---------------------------------------------------------------- main
function summarize(phaseVus, elapsedMs) {
  const rows = [];
  let total = 0;
  let errors = 0;
  const all = [];
  for (const [label, m] of [...metrics.entries()].sort()) {
    const sorted = m.lat.slice().sort((a, b) => a - b);
    all.push(...sorted);
    total += sorted.length;
    errors += m.errors;
    rows.push({
      label,
      n: sorted.length,
      p50: +pct(sorted, 50).toFixed(1),
      p95: +pct(sorted, 95).toFixed(1),
      p99: +pct(sorted, 99).toFixed(1),
      max: +(sorted.at(-1) ?? 0).toFixed(1),
      errors: m.errors,
      codes: m.codes,
    });
  }
  all.sort((a, b) => a - b);
  return {
    vus: phaseVus,
    seconds: +(elapsedMs / 1000).toFixed(1),
    requests: total,
    rps: +(total / (elapsedMs / 1000)).toFixed(1),
    p50: +pct(all, 50).toFixed(1),
    p95: +pct(all, 95).toFixed(1),
    p99: +pct(all, 99).toFixed(1),
    errors,
    errorRate: total ? +((100 * errors) / total).toFixed(2) : 0,
    rlsLeaks,
    endpoints: rows,
  };
}

// Pre-chequeo: solo el stack con seed_carga.sql tiene el admin @carga.felix.test.
{
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: 'carga-admin@carga.felix.test', password: PASSWORD }),
  }).catch(() => null);
  if (!r || !r.ok) {
    console.error('Rechazado: este stack no tiene los usuarios de tool/load/seed_carga.sql. No es el stack de carga.');
    process.exit(2);
  }
}

const results = [];
for (const n of PHASES) {
  metrics = new Map();
  rlsLeaks = 0;
  const t0 = Date.now();
  const deadline = t0 + PHASE_MS;
  console.log(`\n=== Fase: ${n} VUs × ${PHASE_MS / 1000} s ===`);
  await Promise.all(Array.from({ length: n }, (_, i) => vu(i, deadline)));
  const r = summarize(n, Date.now() - t0);
  results.push(r);
  console.log(`requests=${r.requests} rps=${r.rps} p50=${r.p50}ms p95=${r.p95}ms p99=${r.p99}ms errores=${r.errors} (${r.errorRate} %) fugasRLS=${r.rlsLeaks}`);
  console.table(r.endpoints.map(({ codes, ...e }) => ({ ...e, codes: JSON.stringify(codes) })));
  await sleep(10000); // enfriamiento entre fases
}

if (process.env.LOAD_OUT) writeFileSync(process.env.LOAD_OUT, JSON.stringify(results, null, 2));
const bad = results.some((r) => r.errors > 0 || r.rlsLeaks > 0);
console.log(bad ? '\nHUBO ERRORES O FUGAS DE RLS' : '\nTODO OK');
process.exit(bad ? 1 : 0);
