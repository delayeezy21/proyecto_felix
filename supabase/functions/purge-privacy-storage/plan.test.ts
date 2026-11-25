// Unit tests de purge-privacy-storage (sin red).
// Ejecutar: node --test supabase/functions/purge-privacy-storage/plan.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { groupByBucket, summarize } from './plan.ts';

test('agrupa por bucket sin duplicados', () => {
  const g = groupByBucket([
    { bucket_id: 'clinical-attachments', name: 'pets/a/e/x.pdf', reason: 'erasure' },
    { bucket_id: 'clinical-attachments', name: 'pets/a/e/x.pdf', reason: 'erasure' },
    { bucket_id: 'vet-documents', name: 'v1/degree.pdf', reason: 'erasure' },
    { bucket_id: 'clinical-attachments', name: 'pets/b/e/y.png', reason: 'orphan' },
  ]);
  assert.deepEqual(g.get('clinical-attachments'), ['pets/a/e/x.pdf', 'pets/b/e/y.png']);
  assert.deepEqual(g.get('vet-documents'), ['v1/degree.pdf']);
});

test('descarta buckets desconocidos, nombres vacíos y rutas con ..', () => {
  const g = groupByBucket([
    { bucket_id: 'avatars', name: 'a.png', reason: 'erasure' },
    { bucket_id: 'clinical-attachments', name: '', reason: 'orphan' },
    { bucket_id: 'clinical-attachments', name: 'pets/../x', reason: 'orphan' },
  ]);
  assert.equal(g.size, 0);
  assert.equal(groupByBucket(null as never).size, 0);
});

test('el resumen solo cuenta por motivo', () => {
  assert.deepEqual(summarize([
    { bucket_id: 'clinical-attachments', name: 'p/1', reason: 'erasure' },
    { bucket_id: 'clinical-attachments', name: 'p/2', reason: 'orphan' },
    { bucket_id: 'vet-documents', name: 'v/3', reason: 'erasure' },
  ]), { erasure: 2, orphan: 1 });
});
