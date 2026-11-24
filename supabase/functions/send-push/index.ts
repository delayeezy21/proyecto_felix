// Envío de push (fase 8). Ver docs/arquitectura.md §6.
//
// POST {} con la clave de servicio (solo pg_cron vía pg_net, job 'send-push',
// o un E2E local). Toma un lote de private.push_outbox con claim_push_batch
// y lo envía según PUSH_PROVIDER (off | fake | fcm; por defecto off).
// * off  → no toma el lote (la cola se purga a las 24 h).
// * fake → no usa la red; responde los eventos enviados (para E2E).
// * fcm  → FCM HTTP v1 con FCM_SERVICE_ACCOUNT (secreto). Nunca en tests/CI.
// El payload lleva SOLO visit_id + evento. Sin tokens ni datos en los logs
// ni en la respuesta.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4';
import { FcmPushProvider } from './fcm.ts';
import type { PushJob, PushProvider } from './providers.ts';
import { buildData, FakePushProvider, readConfig } from './providers.ts';

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const auth = req.headers.get('Authorization') ?? '';
  if (!serviceKey || auth !== `Bearer ${serviceKey}`) return json({ error: 'forbidden' }, 403);

  const cfg = readConfig((k) => Deno.env.get(k));
  if (cfg.mode === 'off') return json({ provider: 'off', sent: 0 });

  let provider: PushProvider;
  try {
    provider = cfg.mode === 'fcm' ? new FcmPushProvider(cfg.fcmServiceAccount ?? '') : new FakePushProvider();
  } catch {
    return json({ error: 'provider_not_configured' }, 500);
  }

  const db = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey, { auth: { persistSession: false } });
  const { data, error } = await db.rpc('claim_push_batch', { p_limit: 100 });
  if (error) return json({ error: 'claim_failed' }, 500);
  const jobs = ((data ?? []) as PushJob[]).filter((j) => {
    try {
      buildData(j);
      return true;
    } catch {
      return false;
    }
  });

  const result = await provider.send(jobs, { fetch, now: () => new Date() });
  if (result.invalidTokens.length > 0) {
    await db.rpc('drop_push_tokens', { p_tokens: result.invalidTokens });
  }

  return json({
    provider: provider.mode,
    sent: result.sent,
    failed: result.failed,
    // Solo en fake (E2E): lo que habría viajado, sin tokens.
    ...(provider instanceof FakePushProvider ? { delivered: provider.delivered } : {}),
  });
});
