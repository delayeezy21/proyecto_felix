// Unit tests de los adaptadores (sin red: fetch simulado, HTML sintético con
// nombres ficticios). Ejecutar: node --test supabase/functions/verify-vet-title/
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ColmevetProvider, countMatches, parseCardNames } from './colmevet.ts';
import { FakeProvider } from './fake.ts';
import type { ProviderDeps, TitleVerificationInput } from './providers.ts';
import { nameTokens, normalize } from './providers.ts';
import { isKnownVetSchool, RulesProvider } from './rules.ts';
import { readConfig, runProvider, runVerification } from './run.ts';

const base: TitleVerificationInput = {
  displayName: 'Dra. Ana Prueba Ficticia',
  university: 'Universidad de Chile',
  graduationYear: 2015,
  foreignDegree: false,
  hasVerificationCode: true,
};
const noNet: ProviderDeps = {
  fetch: () => Promise.reject(new Error('sin red en tests')),
  now: () => new Date('2026-11-17T12:00:00Z'),
};

// HTML sintético con la misma estructura de tarjetas del listado público.
const card = (name: string) => `
  <div class="card text-center align-items-center">
    <div class="card-body"><h6 class="text-primary">${name}</h6><span>Institución (Ciudad - Región)</span></div>
    <div class="pb-3"><a target="_blank" class="btn btn-warning btn-sm" href="/publico/colegiados/1">Ver Perfil</a></div>
  </div>`;
const page = (...names: string[]) => `<html><body><h4>Colegiados</h4>${names.map(card).join('')}</body></html>`;

function htmlFetch(html: string, status = 200, seen: string[] = []): ProviderDeps {
  return {
    now: noNet.now,
    fetch: ((url: string) => {
      seen.push(url);
      return Promise.resolve(new Response(html, { status }));
    }) as unknown as typeof fetch,
  };
}

test('normaliza tildes, signos y tratamientos', () => {
  assert.equal(normalize('  Ñuñoa, Pérez-Soto '), 'nunoa perez soto');
  assert.deepEqual(nameTokens('Dra. Ana Pérez'), ['ana', 'perez']);
});

test('reglas: universidad conocida, con código → riesgo bajo y sugiere universidad', async () => {
  const r = await new RulesProvider().verify(base, noNet);
  assert.equal(r.outcome, 'match');
  assert.equal(r.risk, 'low');
  assert.deepEqual(r.suggestedChecks, ['university']);
  assert.equal(r.evidence.university_known, true);
});

test('reglas: universidad desconocida o sin código → riesgo medio, sin sugerencia', async () => {
  const r = await new RulesProvider().verify({ ...base, university: 'Instituto Inventado' }, noNet);
  assert.equal(r.outcome, 'no_match');
  assert.equal(r.risk, 'medium');
  assert.deepEqual(r.suggestedChecks, []);
  const s = await new RulesProvider().verify({ ...base, hasVerificationCode: false }, noNet);
  assert.equal(s.risk, 'medium');
});

test('reglas: título extranjero o año imposible → riesgo alto', async () => {
  const f = await new RulesProvider().verify({ ...base, foreignDegree: true }, noNet);
  assert.equal(f.risk, 'high');
  assert.deepEqual(f.suggestedChecks, [], 'el extranjero se revisa a mano');
  const y = await new RulesProvider().verify({ ...base, graduationYear: 2030 }, noNet);
  assert.equal(y.risk, 'high');
});

test('reglas: la universidad se compara normalizada (tildes y mayúsculas)', () => {
  assert.ok(isKnownVetSchool('UNIVERSIDAD DE CONCEPCIÓN'));
  assert.ok(!isKnownVetSchool('Universidad de Chile Falsa'));
  assert.ok(!isKnownVetSchool(null));
});

test('colmevet: extrae nombres de tarjetas y decodifica entidades', () => {
  assert.deepEqual(parseCardNames(page('Ana Prueba Ficticia', 'Jos&eacute; Ejemplo')), [
    'Ana Prueba Ficticia',
    'José Ejemplo',
  ]);
  assert.equal(countMatches(['Ana María Prueba Ficticia', 'Otra Persona'], ['ana', 'prueba', 'ficticia']), 1);
});

test('colmevet: una coincidencia → match y sugiere el chequeo opcional; busca por nombre', async () => {
  const seen: string[] = [];
  const p = new ColmevetProvider('https://colmevet.example/publico/colegiados');
  const r = await p.verify(base, htmlFetch(page('Ana Prueba Ficticia', 'Otra Persona'), 200, seen));
  assert.equal(r.outcome, 'match');
  assert.deepEqual(r.suggestedChecks, ['colmevet']);
  assert.equal(r.risk, null, 'COLMEVET no evalúa riesgo');
  assert.deepEqual(r.evidence, { matches: 1, http_status: 200 });
  const url = new URL(seen[0]);
  assert.equal(url.searchParams.get('type'), 'name');
  assert.equal(url.searchParams.get('q'), 'ana prueba ficticia');
  assert.ok(!seen[0].toLowerCase().includes('rut'), 'nunca busca por RUT');
});

test('colmevet: la evidencia no guarda nombres de terceros', async () => {
  const r = await new ColmevetProvider().verify(base, htmlFetch(page('Ana Prueba Ficticia', 'Ana Prueba Ficticia')));
  assert.equal(r.outcome, 'ambiguous');
  assert.deepEqual(r.suggestedChecks, []);
  assert.ok(!JSON.stringify(r).toLowerCase().includes('ficticia'));
});

test('colmevet: sin coincidencias → no_match neutro', async () => {
  const r = await new ColmevetProvider().verify(base, htmlFetch(page('Otra Persona')));
  assert.equal(r.outcome, 'no_match');
  assert.equal(r.risk, null);
});

test('colmevet: HTTP distinto de 200, captcha o error de red → error', async () => {
  const p = new ColmevetProvider();
  assert.equal((await p.verify(base, htmlFetch('x', 503))).outcome, 'error');
  const c = await p.verify(base, htmlFetch('<div class="g-recaptcha"></div>'));
  assert.equal(c.outcome, 'error');
  assert.equal(c.evidence.captcha, true);
  assert.equal((await p.verify(base, noNet)).outcome, 'error');
});

test('colmevet: nombre de una sola palabra → skipped (evita homónimos masivos)', async () => {
  const r = await new ColmevetProvider().verify({ ...base, displayName: 'Dra. Vera' }, noNet);
  assert.equal(r.outcome, 'skipped');
});

test('falso: determinista según el nombre', async () => {
  const f = new FakeProvider(10);
  assert.equal((await f.verify({ ...base, displayName: 'Dr. Colegiado Prueba' }, noNet)).outcome, 'match');
  assert.equal((await f.verify({ ...base, displayName: 'Dr. Homonimo Prueba' }, noNet)).outcome, 'ambiguous');
  assert.equal((await f.verify(base, noNet)).outcome, 'no_match');
  await assert.rejects(f.verify({ ...base, displayName: 'Dr. Falla' }, noNet));
});

test('runProvider: excepción o timeout → error, nunca lanza', async () => {
  const f = new FakeProvider(500);
  const e = await runProvider(f, { ...base, displayName: 'Falla' }, noNet, 1000);
  assert.equal(e.outcome, 'error');
  assert.equal(e.evidence.reason, 'exception');
  const t = await runProvider(f, { ...base, displayName: 'Lento' }, noNet, 20);
  assert.equal(t.outcome, 'error');
  assert.equal(t.evidence.reason, 'timeout');
});

test('config: por defecto apagado; valores inválidos vuelven al defecto', () => {
  assert.equal(readConfig(() => undefined).mode, 'off');
  assert.equal(readConfig((k) => (k === 'TITLE_VERIFICATION_PROVIDER' ? 'FAKE' : undefined)).mode, 'fake');
  assert.equal(readConfig((k) => (k === 'TITLE_VERIFICATION_PROVIDER' ? 'scraper' : undefined)).mode, 'off');
  assert.equal(readConfig((k) => (k === 'TITLE_VERIFICATION_TIMEOUT_MS' ? '999999' : undefined)).timeoutMs, 8000);
});

test('runVerification: apagado → solo reglas; sin cuota externa → skipped', async () => {
  const off = await runVerification(base, readConfig(() => undefined), noNet, true);
  assert.deepEqual(off.map((r) => r.source), ['rules']);
  const cfg = readConfig((k) => (k === 'TITLE_VERIFICATION_PROVIDER' ? 'colmevet' : undefined));
  const limited = await runVerification(base, cfg, noNet, false);
  assert.deepEqual(limited.map((r) => [r.source, r.outcome]), [['rules', 'match'], ['colmevet', 'skipped']]);
});
