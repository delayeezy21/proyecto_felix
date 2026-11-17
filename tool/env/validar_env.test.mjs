// Pruebas de tool/env/validar_env.mjs (QA d142432, docs/qa/QA-d142432.md).
//
//   node --test tool/env/validar_env.test.mjs
//
// Todas las claves son FICTICIAS. Los casos marcados "QA-21"/"QA-22" documentan
// bypasses encontrados en la QA (corregidos en validar_env.mjs).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), 'validar_env.mjs');
const dir = mkdtempSync(join(tmpdir(), 'validar-env-'));
process.on('exit', () => rmSync(dir, { recursive: true, force: true }));

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = (role) => `${b64({ alg: 'HS256' })}.${b64({ role, iss: 'supabase' })}.firma`;
const PUB = 'sb_publishable_FAKEfakeFAKE1234';
// Concatenada para que el job "Sin secretos en el repo" de ci.yml no la confunda con una real.
const SECRET = 'sb_' + 'secret_FAKEfakeFAKE1234';

let n = 0;
function run(lines) {
  const f = join(dir, `e${n++}.env`);
  writeFileSync(f, lines.join('\n') + '\n');
  return spawnSync(process.execPath, [SCRIPT, f], { encoding: 'utf8' });
}
const beta = (url, key = PUB, extra = []) => run(['APP_ENV=beta', `SUPABASE_URL=${url}`, `SUPABASE_PUBLISHABLE_KEY=${key}`, ...extra]);

test('acepta un entorno beta válido', () => assert.equal(beta('https://abcdefghijklmnopqrst.supabase.co').status, 0));
test('acepta la anon JWT legada', () => assert.equal(beta('https://x.supabase.co', jwt('anon')).status, 0));
test('acepta local con http://127.0.0.1', () =>
  assert.equal(run(['APP_ENV=local', 'SUPABASE_URL=http://127.0.0.1:54321', `SUPABASE_PUBLISHABLE_KEY=${PUB}`]).status, 0));

test('rechaza sb_secret_ como publishable key', () => assert.equal(beta('https://x.supabase.co', SECRET).status, 1));
test('rechaza sb_secret_ también en local', () =>
  assert.equal(run(['APP_ENV=local', 'SUPABASE_URL=http://127.0.0.1:54321', `SUPABASE_PUBLISHABLE_KEY=${SECRET}`]).status, 1));
test('rechaza sb_secret_ en cualquier variable', () =>
  assert.equal(beta('https://x.supabase.co', PUB, [`MAPS_API_KEY=${SECRET}`]).status, 1));
test('rechaza una JWT service_role', () => assert.equal(beta('https://x.supabase.co', jwt('service_role')).status, 1));
test('rechaza variables de servidor', () =>
  assert.equal(beta('https://x.supabase.co', PUB, ['SUPABASE_SERVICE_KEY=x']).status, 1));
test('nunca imprime el valor de la clave secreta', () => {
  const r = beta('https://x.supabase.co', SECRET);
  assert.ok(!(r.stdout + r.stderr).includes(SECRET));
});
test('rechaza http en beta', () => assert.equal(beta('http://x.supabase.co').status, 1));

for (const h of ['localhost', '127.0.0.1', '10.0.0.5', '172.20.0.1', '192.168.1.10']) {
  test(`rechaza host local/privado ${h}`, () => assert.equal(beta(`https://${h}:54321`).status, 1));
}

// QA-21: hosts locales que hoy pasan la validación.
for (const h of ['0.0.0.0', '[::1]', '127.0.0.2', 'localhost.', 'host.docker.internal', '169.254.1.1', 'mipc.local']) {
  test(`QA-21: rechaza host local ${h}`, () => assert.equal(beta(`https://${h}:54321`).status, 1));
}

// QA-22: valores entre comillas simples esquivan la detección de claves secretas.
test("QA-22: rechaza sb_secret_ entre comillas simples", () =>
  assert.equal(beta('https://x.supabase.co', PUB, [`MAPS_API_KEY='${SECRET}'`]).status, 1));
test("QA-22: rechaza JWT service_role entre comillas simples", () =>
  assert.equal(beta('https://x.supabase.co', PUB, [`MAPS_API_KEY='${jwt('service_role')}'`]).status, 1));

// Casos adicionales (corrección de QA-21/QA-22).
for (const h of ['127.255.0.9', '[::]', '[fe80::1]', '[fd00::5]', '[::ffff:127.0.0.1]', 'api.localhost',
                 'db.internal', 'supabase.lan', '100.64.0.1', 'intranet', '2130706433']) {
  test(`rechaza host local ${h}`, () => assert.equal(beta(`https://${h}:54321`).status, 1));
}
test('acepta un dominio propio público', () => assert.equal(beta('https://api.felix.cl').status, 0));
test('rechaza sb_secret_ en medio de un valor', () =>
  assert.equal(beta('https://x.supabase.co', PUB, [`MAPS_API_KEY=abc,${SECRET}`]).status, 1));
test('rechaza JWT service_role en medio de un valor', () =>
  assert.equal(beta('https://x.supabase.co', PUB, [`MAPS_API_KEY=x ${jwt('service_role')} y`]).status, 1));
test('rechaza sb_secret_ con export y comillas dobles', () =>
  assert.equal(beta('https://x.supabase.co', PUB, [`export MAPS_API_KEY="${SECRET}"`]).status, 1));

// ---- Recertificación 9138c22 (docs/qa/QA-9138c22.md) ----
// Marcados `todo`: se reportan como pendientes sin romper el job de CI.

// QA-30: el flujo del runbook (copiar env.example a .env.beta y completar) se
// rechaza por el COMENTARIO "Nunca sb_secret_..." de la plantilla: el escaneo del
// texto crudo incluye las líneas de comentario.
test('QA-30: acepta un .env.beta creado desde env.example', { todo: 'QA-30' }, () => {
  const plantilla = readFileSync(join(dirname(SCRIPT), '..', '..', 'env.example'), 'utf8')
    .replace(/^APP_ENV=.*$/m, 'APP_ENV=beta')
    .replace(/^SUPABASE_URL=.*$/m, 'SUPABASE_URL=https://abcdefghijklmnopqrst.supabase.co')
    .replace(/^SUPABASE_PUBLISHABLE_KEY=.*$/m, `SUPABASE_PUBLISHABLE_KEY=${PUB}`);
  assert.equal(run(plantilla.split(/\r?\n/)).status, 0);
});

// QA-31: hosts locales residuales (IPv4 embebida en IPv6 no "mapped" y nombres
// DNS que resuelven a loopback). Solución de fondo: allowlist de hosts.
for (const h of ['[::127.0.0.1]', '[64:ff9b::7f00:1]', '127.0.0.1.nip.io', 'localtest.me']) {
  test(`QA-31: rechaza host local ${h}`, { todo: 'QA-31' }, () => assert.equal(beta(`https://${h}:54321`).status, 1));
}
