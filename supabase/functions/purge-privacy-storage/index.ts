// Borra con la API de Storage los objetos que pide la fase 11 (privacidad):
// los encolados por el job de borrado de cuentas y los adjuntos de la ficha
// subidos sin registrar hace más de 24 h (M2). Ver la migración privacy_rights.
//
// Borrar filas de storage.objects por SQL NO elimina el archivo: por eso se usa
// la API. El job de BD (pg_cron) confirma después contra storage.objects y
// recién entonces borra el usuario de Auth. Solo la invoca pg_cron con la
// clave de servicio.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4';
import { groupByBucket, summarize, type Candidate } from './plan.ts';

const BATCH = 200;

Deno.serve(async (req) => {
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const auth = req.headers.get('Authorization') ?? '';
  if (!serviceKey || auth !== `Bearer ${serviceKey}`) {
    return new Response(JSON.stringify({ error: 'forbidden' }), { status: 403 });
  }

  const db = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey, {
    auth: { persistSession: false },
  });

  const { data, error } = await db.rpc('privacy_storage_candidates', { p_limit: BATCH });
  if (error) {
    return new Response(JSON.stringify({ error: 'query_failed' }), { status: 500 });
  }
  const rows = (data ?? []) as Candidate[];
  let removed = 0;
  let failed = 0;
  for (const [bucket, names] of groupByBucket(rows)) {
    const { error: removeError } = await db.storage.from(bucket).remove(names);
    if (removeError) failed += names.length;
    else removed += names.length;
  }

  // Sin datos personales en la respuesta ni en logs: solo cantidades.
  return Response.json({ candidates: summarize(rows), removed, failed },
    { status: failed ? 500 : 200 });
});
