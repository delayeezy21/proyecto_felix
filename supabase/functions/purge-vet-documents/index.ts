// Purga los documentos de verificación de vets cuyo plazo venció
// (7 días tras aprobarse, 30 tras un rechazo). Ver SPEC HU1.4 y la
// migración vet_onboarding.
//
// Borrar filas de storage.objects por SQL NO elimina el archivo: por eso la
// purga usa la API de Storage. Solo la invoca pg_cron con la clave de servicio.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4';

const BATCH = 100;

Deno.serve(async (req) => {
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const auth = req.headers.get('Authorization') ?? '';
  if (!serviceKey || auth !== `Bearer ${serviceKey}`) {
    return new Response(JSON.stringify({ error: 'forbidden' }), { status: 403 });
  }

  const db = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey, {
    auth: { persistSession: false },
  });

  const { data: due, error } = await db
    .from('vet_documents')
    .select('id, storage_path')
    .is('purged_at', null)
    .not('storage_path', 'is', null)
    .lte('purge_after', new Date().toISOString())
    .limit(BATCH);
  if (error) {
    return new Response(JSON.stringify({ error: 'query_failed' }), { status: 500 });
  }
  if (!due || due.length === 0) {
    return Response.json({ purged: 0 });
  }

  const paths = due.map((d) => d.storage_path as string);
  const { error: removeError } = await db.storage.from('vet-documents').remove(paths);
  if (removeError) {
    return new Response(JSON.stringify({ error: 'storage_remove_failed' }), { status: 500 });
  }

  const { error: updateError } = await db
    .from('vet_documents')
    .update({ storage_path: null, purged_at: new Date().toISOString() })
    .in('id', due.map((d) => d.id));
  if (updateError) {
    return new Response(JSON.stringify({ error: 'update_failed' }), { status: 500 });
  }

  // Sin datos personales en la respuesta ni en logs: solo la cantidad.
  return Response.json({ purged: due.length });
});
