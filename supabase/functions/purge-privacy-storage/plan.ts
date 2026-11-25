// Lógica pura de purge-privacy-storage (sin red), para probarla con node --test.

export type Candidate = { bucket_id: string; name: string; reason: string };

// Solo estos buckets privados se purgan por esta vía.
export const ALLOWED_BUCKETS = ['clinical-attachments', 'vet-documents'];

/// Agrupa los candidatos por bucket (sin duplicados), descartando buckets
/// desconocidos y nombres vacíos o con "..".
export function groupByBucket(rows: Candidate[]): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const r of rows ?? []) {
    if (!ALLOWED_BUCKETS.includes(r?.bucket_id)) continue;
    if (typeof r.name !== 'string' || r.name === '' || r.name.includes('..')) continue;
    const list = out.get(r.bucket_id) ?? [];
    if (!list.includes(r.name)) list.push(r.name);
    out.set(r.bucket_id, list);
  }
  return out;
}

/// Resumen sin datos personales: solo cantidades por motivo.
export function summarize(rows: Candidate[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const r of rows ?? []) out[r.reason] = (out[r.reason] ?? 0) + 1;
  return out;
}
