// E2E de la purga de documentos de vets (QA-06, versión d0c586c) contra
// Supabase local: Storage real + Edge Function purge-vet-documents.
// Para simular el paso del tiempo retrocede fechas con psql dentro del
// contenedor de la BD (solo filas creadas por este script).
//
// Uso: node tool/e2e/purga_e2e.mjs "$(npx --yes supabase@3.2.0 status -o json | sed -n '/^{/,$p')"
// Requiere `docker` en el PATH (contenedor supabase_db_*).
//
// OJO: invoca la purga real; borra también cualquier documento vencido o
// huérfano (> 24 h) que ya exista en la base local. Revisa antes con:
//   select * from private.vet_documents_due(1000); select * from private.vet_orphan_objects(1000);
import { execFileSync } from 'node:child_process';

const st = JSON.parse(process.argv[2]);
const API = st.API_URL;
const PUB = st.PUBLISHABLE_KEY;
const SRV = st.SERVICE_ROLE_KEY;

let fails = 0;
const check = (cond, msg) => { console.log(`${cond ? 'OK   ' : 'FALLA'} ${msg}`); if (!cond) fails++; };

// El contenedor se elige por el puerto de DB_URL: puede haber otros stacks de
// Supabase levantados en la misma máquina.
const dbPort = new URL(st.DB_URL).port || '54322';
const container = execFileSync('docker', ['ps', '--filter', `publish=${dbPort}`, '--format', '{{.Names}}'])
  .toString().split(/\r?\n/).find((n) => n.startsWith('supabase_db_'));
if (!container) throw new Error(`No encontré el contenedor supabase_db_* del puerto ${dbPort}`);
const sql = (q) => execFileSync('docker', ['exec', '-i', container, 'psql', '-U', 'postgres', '-tA', '-v', 'ON_ERROR_STOP=1'],
  { input: q }).toString().trim();

async function call(path, { method = 'GET', token, key = PUB, body, raw, type } = {}) {
  const headers = { apikey: key };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (raw) headers['Content-Type'] = type; else if (body !== undefined) headers['Content-Type'] = 'application/json';
  const r = await fetch(API + path, { method, headers, body: raw ?? (body !== undefined ? JSON.stringify(body) : undefined) });
  const text = await r.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, json };
}
const rest = (p, o) => call(`/rest/v1/${p}`, o);
const rpc = (fn, token, body = {}) => rest(`rpc/${fn}`, { method: 'POST', token, body });

const stamp = Date.now();
const created = [];
async function newUser(tag) {
  const email = `qa-purga-${tag}-${stamp}@test.local`;
  const c = await call('/auth/v1/admin/users', { method: 'POST', key: SRV, token: SRV,
    body: { email, password: 'Felix2026', email_confirm: true } });
  created.push(c.json.id);
  const s = await call('/auth/v1/token?grant_type=password', { method: 'POST', body: { email, password: 'Felix2026' } });
  return { token: s.json.access_token, id: c.json.id };
}
const legal = {
  terms: (await rpc('current_legal_version', undefined, { p_kind: 'terms' })).json,
  privacy: (await rpc('current_legal_version', undefined, { p_kind: 'privacy' })).json,
};
const pdf = new TextEncoder().encode('%PDF-1.4 purga');
const up = (u, path) => call(`/storage/v1/object/vet-documents/${path}`, { method: 'POST', token: u.token, raw: pdf, type: 'application/pdf' });
const exists = async (path) => (await call(`/storage/v1/object/authenticated/vet-documents/${path}`, { key: SRV, token: SRV })).status === 200;

async function vetWithDocs(tag, { submit = false } = {}) {
  const u = await newUser(tag);
  await rpc('complete_registration', u.token, { p_role: 'vet', p_display_name: `QA ${tag}`, p_phone: null,
    p_terms_version: legal.terms, p_privacy_version: legal.privacy });
  const t = `${u.id}/titulo-${stamp}.pdf`;
  const c = `${u.id}/cedula-${stamp}.pdf`;
  for (const [kind, p] of [['degree_certificate', t], ['id_card_front', c]]) {
    await up(u, p);
    await rest('vet_documents', { method: 'POST', token: u.token,
      body: { vet_id: u.id, kind, storage_path: p, mime: 'application/pdf', size_bytes: pdf.length } });
  }
  if (submit) {
    const perro = (await rest('species?select=id&slug=eq.perro', { token: u.token })).json[0].id;
    const general = (await rest('specialties?select=id&slug=eq.general', { token: u.token })).json[0].id;
    await rest('vet_species', { method: 'POST', token: u.token, body: { vet_id: u.id, species_id: perro } });
    await rest('vet_specialties', { method: 'POST', token: u.token, body: { vet_id: u.id, specialty_id: general } });
    await rest(`vet_profiles?user_id=eq.${u.id}`, { method: 'PATCH', token: u.token, body: {
      university: 'Universidad QA', graduation_year: 2015, declaration_accepted_at: new Date().toISOString() } });
    const s = await rpc('submit_vet_application', u.token);
    if (s.status !== 200) throw new Error(`envío ${tag}: ${JSON.stringify(s.json)}`);
  }
  return { ...u, t, c };
}

try {
  const draft = await vetWithDocs('borrador');
  const dDoc = (await rest(`vet_documents?select=purge_after&vet_id=eq.${draft.id}`, { token: draft.token })).json;
  check(dDoc.length === 2 && dDoc.every((d) => Math.abs(new Date(d.purge_after) - Date.now() - 90 * 864e5) < 36e5),
    'un documento en borrador nace con purga a 90 días');

  const review = await vetWithDocs('revision', { submit: true });
  const approvedVet = await vetWithDocs('aprobado', { submit: true });
  const admin = await newUser('admin');
  await rest('user_roles', { method: 'POST', key: SRV, token: SRV, body: { user_id: admin.id, role: 'admin' } });
  const appr = await rpc('review_vet_application', admin.token, { p_vet_id: approvedVet.id, p_approve: true });
  check(appr.status === 200, 'el admin aprueba al vet (los documentos pasan a purga a 7 días)');
  const expiredDraft = await vetWithDocs('borrador-vencido');

  // Huérfanos: uno viejo (> 24 h) y uno reciente.
  const oldOrphan = `${draft.id}/huerfano-viejo-${stamp}.pdf`;
  const newOrphan = `${draft.id}/huerfano-nuevo-${stamp}.pdf`;
  check((await up(draft, oldOrphan)).status === 200 && (await up(draft, newOrphan)).status === 200,
    'se suben dos archivos sin registrarlos (simula un INSERT fallido)');

  // Paso del tiempo (solo filas de este script).
  const moved = sql(`update public.vet_documents set purge_after = now() - interval '1 hour'
         where vet_id in ('${review.id}', '${approvedVet.id}', '${expiredDraft.id}');
       update storage.objects set created_at = now() - interval '25 hours'
         where bucket_id = 'vet-documents' and name = '${oldOrphan}';`);
  check(moved.includes('UPDATE 6') && moved.includes('UPDATE 1'), `se simula el paso del tiempo (${moved.replace(/s+/g, ' ')})`);

  const due = sql(`select string_agg(storage_path, ',') from private.vet_documents_due(1000)`);
  check(!due.includes(review.id), 'la purga omite los documentos de una solicitud en revisión');
  check(due.includes(approvedVet.id) && due.includes(expiredDraft.id), 'la purga incluye los vencidos que no están en revisión');
  const orphans = sql(`select coalesce(string_agg(name, ','), '') from private.vet_orphan_objects(1000)`);
  check(orphans.includes(oldOrphan) && !orphans.includes(newOrphan) && !orphans.includes(draft.t),
    'huérfanos: solo los de más de 24 h y sin fila en vet_documents');

  const purgeAuthOnly = await rpc('purge_candidates', draft.token, { p_limit: 10 });
  check(purgeAuthOnly.status >= 400, `un usuario no ejecuta purge_candidates (HTTP ${purgeAuthOnly.status})`);
  const orphAuthOnly = await rpc('purge_orphan_candidates', draft.token, { p_limit: 10 });
  check(orphAuthOnly.status >= 400, `un usuario no ejecuta purge_orphan_candidates (HTTP ${orphAuthOnly.status})`);

  const fn = await call('/functions/v1/purge-vet-documents', { method: 'POST', key: SRV, token: SRV, body: {} });
  check(fn.status === 200 && fn.json.orphans !== undefined,
    `la Edge Function desplegada es la nueva (responde ${JSON.stringify(fn.json)})`);

  check(!(await exists(oldOrphan)), 'el huérfano viejo se borró de Storage');
  check(await exists(newOrphan), 'el huérfano reciente sigue (aún puede registrarse)');
  check(await exists(draft.t), 'el documento del borrador vigente sigue');
  check(await exists(review.t) && await exists(review.c), 'los documentos en revisión siguen aunque estén vencidos');
  check(!(await exists(approvedVet.t)) && !(await exists(expiredDraft.t)), 'los vencidos fuera de revisión se borraron');
  const meta = (await rest(`vet_documents?select=storage_path,purged_at&vet_id=eq.${approvedVet.id}`, { key: SRV, token: SRV })).json;
  check(meta.length === 2 && meta.every((d) => d.storage_path === null && d.purged_at), 'quedan solo los metadatos de los purgados');

  // Un borrador cuyos documentos expiraron debe volver a subirlos para enviar.
  await rest(`vet_profiles?user_id=eq.${expiredDraft.id}`, { method: 'PATCH', token: expiredDraft.token, body: {
    university: 'Universidad QA', graduation_year: 2015, declaration_accepted_at: new Date().toISOString() } });
  const st2 = await rpc('submit_vet_application', expiredDraft.token);
  check(st2.status === 400 && /certificado/i.test(st2.json.message ?? ''),
    `un borrador con documentos purgados no se envía (${st2.json.message ?? st2.status})`);
} finally {
  for (const id of created) {
    const objs = await call('/storage/v1/object/list/vet-documents', { method: 'POST', key: SRV, token: SRV, body: { prefix: id } });
    const names = Array.isArray(objs.json) ? objs.json.map((o) => `${id}/${o.name}`) : [];
    if (names.length) await call('/storage/v1/object/vet-documents', { method: 'DELETE', key: SRV, token: SRV, body: { prefixes: names } });
  }
  for (const id of [...created].reverse()) await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE', key: SRV, token: SRV });
}

console.log(fails ? `\nPurga: ${fails} FALLA(s)` : '\nPurga: TODO OK');
process.exit(fails ? 1 : 0);
