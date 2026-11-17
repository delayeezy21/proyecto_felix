// Purga los documentos de verificación de vets cuyo plazo venció
// (7 días tras aprobarse, 30 tras un rechazo). Ver SPEC HU1.4 y la
// migración vet_onboarding.
//
// Borrar filas de storage.objects por SQL NO elimina el archivo: por eso la
// purga usa la API de Storage. Solo la invoca pg_cron con la clave de servicio.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4';

const BATCH = 100;

// deno-lint-ignore no-explicit-any
async function purgeOrphans(db: any): Promise<number> {
  const { data } = await db.rpc('purge_orphan_candidates', { p_limit: BATCH });
  const names = (data ?? []).map((o: { name: string }) => o.name);
  if (names.length === 0) return 0;
  const { error } = await db.storage.from('vet-documents').remove(names);
  return error ? 0 : names.length;
}

Deno.serve(async (req) => {
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const auth = req.headers.get('Authorization') ?? '';
  if (!serviceKey || auth !== `Bearer ${serviceKey}`) {
    return new Response(JSON.stringify({ error: 'forbidden' }), { status: 403 });
  }

  const db = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey, {
    auth: { persistSession: false },
  });

  // Documentos vencidos de solicitudes que NO están en revisión (QA-06).
  const { data: due, error } = await db.rpc('purge_candidates', { p_limit: BATCH });
  if (error) {
    return new Response(JSON.stringify({ error: 'query_failed' }), { status: 500 });
  }
  if (!due || due.length === 0) {
    return Response.json({ purged: 0, orphans: await purgeOrphans(db) });
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

  // Huérfanos: archivos subidos cuyo registro falló (más de 24 h).
  const orphans = await purgeOrphans(db);

  // Sin datos personales en la respuesta ni en logs: solo cantidades.
  return Response.json({ purged: due.length, orphans });
});
