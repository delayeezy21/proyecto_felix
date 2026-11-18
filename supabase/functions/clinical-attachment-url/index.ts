// URL firmada corta para un adjunto de la ficha clínica (fase 7).
//
// POST { attachment_id: uuid } con el JWT del usuario.
//   1. Con el JWT del usuario llama a la RPC authorize_attachment, que exige
//      acceso vigente (dueño de la mascota, o vet con autorización vigente) y
//      registra la descarga del vet en record_access_log.
//   2. Con la clave de servicio firma la ruta por 60 s (nadie de la API tiene
//      SELECT sobre el bucket `clinical-attachments`).
// Devuelve la ruta firmada relativa (`/storage/v1/object/sign/...`): el cliente
// la completa con su URL de Supabase. Sin datos personales en la respuesta ni
// en los logs; un adjunto ajeno o inexistente responde igual (404).
import { createClient } from 'npm:@supabase/supabase-js@2.49.4';

export const SIGNED_URL_TTL_SECONDS = 60;
const BUCKET = 'clinical-attachments';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const authorization = req.headers.get('Authorization') ?? '';
  if (!/^Bearer\s+\S+$/i.test(authorization)) return json({ error: 'unauthorized' }, 401);

  let body: { attachment_id?: unknown } = {};
  try {
    body = await req.json();
  } catch {
    body = {};
  }
  const id = body.attachment_id;
  if (typeof id !== 'string' || !UUID.test(id)) return json({ error: 'invalid_attachment_id' }, 400);

  const url = Deno.env.get('SUPABASE_URL')!;
  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data: path, error } = await asUser.rpc('authorize_attachment', { p_attachment_id: id });
  if (error || typeof path !== 'string') return json({ error: 'not_found' }, 404);

  const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false },
  });
  const { data, error: signError } = await service.storage
    .from(BUCKET)
    .createSignedUrl(path, SIGNED_URL_TTL_SECONDS);
  if (signError || !data?.signedUrl) return json({ error: 'sign_failed' }, 500);

  const signed = new URL(data.signedUrl);
  return json({
    signed_path: signed.pathname + signed.search,
    expires_in: SIGNED_URL_TTL_SECONDS,
  });
});
