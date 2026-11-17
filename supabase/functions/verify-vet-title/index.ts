// Verificación asistida del título de un vet (docs/verificacion-automatica.md).
//
// POST { vet_id?: uuid } con el JWT del usuario:
//   * admin → verifica cualquier solicitud en revisión (run_trigger 'admin').
//   * vet   → solo la propia, recién enviada (run_trigger 'submit').
// Corre las reglas internas y, según TITLE_VERIFICATION_PROVIDER
// (off | fake | colmevet; por defecto off), un proveedor externo. Guarda el
// resultado en vet_title_verifications. Nunca aprueba: el admin decide.
// Sin datos personales en la respuesta ni en los logs.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4';
import type { TitleVerificationResult } from './providers.ts';
import { readConfig, runVerification } from './run.ts';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  });
  const { data: auth } = await db.auth.getUser(jwt);
  const uid = auth?.user?.id;
  if (!uid) return json({ error: 'unauthorized' }, 401);

  let body: { vet_id?: unknown } = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }

  const { data: roleRow } = await db.from('user_roles').select('role').eq('user_id', uid).maybeSingle();
  const role = roleRow?.role as string | undefined;
  let vetId: string;
  let trigger: 'admin' | 'submit';
  if (role === 'admin') {
    if (typeof body.vet_id !== 'string' || !UUID.test(body.vet_id)) return json({ error: 'invalid_vet_id' }, 400);
    vetId = body.vet_id;
    trigger = 'admin';
  } else if (role === 'vet') {
    if (body.vet_id !== undefined && body.vet_id !== uid) return json({ error: 'forbidden' }, 403);
    vetId = uid;
    trigger = 'submit';
  } else {
    return json({ error: 'forbidden' }, 403);
  }

  const { data: p } = await db
    .from('vet_profiles')
    .select('display_name, status, submitted_at, university, graduation_year, foreign_degree, title_verification_code')
    .eq('user_id', vetId)
    .maybeSingle();
  if (!p || p.status !== 'pending' || !p.submitted_at) return json({ error: 'not_in_review' }, 409);

  const { data: quota, error: quotaError } = await db.rpc('title_verification_quota', { p_vet_id: vetId }).single();
  if (quotaError || !quota) return json({ error: 'quota_failed' }, 500);
  if (!quota.vet_ok) return json({ error: 'rate_limited' }, 429);

  const cfg = readConfig((k) => Deno.env.get(k));
  const results: TitleVerificationResult[] = await runVerification(
    {
      displayName: p.display_name ?? '',
      university: p.university ?? null,
      graduationYear: p.graduation_year ?? null,
      foreignDegree: p.foreign_degree === true,
      hasVerificationCode: !!p.title_verification_code,
    },
    cfg,
    { fetch, now: () => new Date() },
    cfg.mode !== 'colmevet' || quota.colmevet_ok === true,
  );

  const { error: insertError } = await db.from('vet_title_verifications').insert(
    results.map((r) => ({
      vet_id: vetId,
      source: r.source,
      outcome: r.outcome,
      risk: r.risk,
      suggested_checks: r.suggestedChecks,
      evidence: r.evidence,
      run_trigger: trigger,
      requested_by: uid,
      provider_version: r.providerVersion,
    })),
  );
  if (insertError) return json({ error: 'insert_failed' }, 500);

  return json({
    results: results.map((r) => ({
      source: r.source,
      outcome: r.outcome,
      risk: r.risk,
      suggested_checks: r.suggestedChecks,
    })),
  });
});
