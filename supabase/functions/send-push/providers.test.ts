// Unit tests de send-push (sin red: fetch simulado, claves generadas en el
// momento). Ejecutar: node --test supabase/functions/send-push/providers.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { FcmPushProvider } from './fcm.ts';
import type { PushDeps, PushJob } from './providers.ts';
import { buildData, FakePushProvider, readConfig } from './providers.ts';

const VISIT = '6f1c2d3e-4a5b-4c6d-8e7f-001122334455';
const job = (over: Partial<PushJob> = {}): PushJob => ({
  id: 1, token: 'tok-ficticio-0001', platform: 'android', visit_id: VISIT, event: 'offer_new', ...over,
});

test('readConfig: por defecto off; fake y fcm explícitos', () => {
  assert.equal(readConfig(() => undefined).mode, 'off');
  assert.equal(readConfig((k) => (k === 'PUSH_PROVIDER' ? ' FAKE ' : undefined)).mode, 'fake');
  assert.equal(readConfig((k) => (k === 'PUSH_PROVIDER' ? 'fcm' : undefined)).mode, 'fcm');
  assert.equal(readConfig((k) => (k === 'PUSH_PROVIDER' ? 'otro' : undefined)).mode, 'off');
});

test('el payload lleva solo visit_id y el evento', () => {
  const d = buildData({ ...job(), ...{ pet_name: 'Rayo', address: 'Calle 1' } } as PushJob);
  assert.deepEqual(Object.keys(d).sort(), ['event', 'visit_id']);
  assert.throws(() => buildData(job({ visit_id: 'no-uuid' })));
  assert.throws(() => buildData(job({ event: 'Rayo está grave' })));
});

test('fake: no usa la red y registra lo enviado sin tokens', async () => {
  const p = new FakePushProvider();
  const deps: PushDeps = { fetch: () => Promise.reject(new Error('sin red')), now: () => new Date() };
  const r = await p.send([job(), job({ id: 2, event: 'visit_accepted' })], deps);
  assert.equal(r.sent, 2);
  assert.deepEqual(p.delivered.map((x) => x.data.event), ['offer_new', 'visit_accepted']);
  assert.ok(!JSON.stringify(p.delivered).includes('tok-ficticio'));
});

async function fakeServiceAccount() {
  const kp = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true, ['sign', 'verify']);
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', kp.privateKey));
  const b64 = btoa(String.fromCharCode(...der));
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g)!.join('\n')}\n-----END PRIVATE KEY-----\n`;
  return JSON.stringify({ project_id: 'felix-ficticio', client_email: 'push@ficticio.test', private_key: pem });
}

test('fcm: OAuth + mensaje v1 solo con data; borra tokens no registrados', async () => {
  const calls: { url: string; body: string }[] = [];
  const deps: PushDeps = {
    now: () => new Date('2026-11-24T12:00:00Z'),
    fetch: ((url: string, init: RequestInit) => {
      calls.push({ url, body: String(init.body) });
      if (url.includes('oauth2')) return Promise.resolve(Response.json({ access_token: 'at-ficticio' }));
      const msg = JSON.parse(String(init.body));
      if (msg.message.token === 'tok-muerto-00001') {
        return Promise.resolve(new Response('{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}', { status: 404 }));
      }
      return Promise.resolve(Response.json({ name: 'projects/x/messages/1' }));
    }) as unknown as typeof fetch,
  };
  const p = new FcmPushProvider(await fakeServiceAccount());
  const r = await p.send([job(), job({ id: 2, token: 'tok-muerto-00001', platform: 'web' })], deps);
  assert.equal(r.sent, 1);
  assert.equal(r.failed, 1);
  assert.deepEqual(r.invalidTokens, ['tok-muerto-00001']);
  assert.ok(calls[0].url.startsWith('https://oauth2.googleapis.com/token'));
  assert.match(calls[0].body, /grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer/);
  assert.equal(calls[1].url, 'https://fcm.googleapis.com/v1/projects/felix-ficticio/messages:send');
  const sent = JSON.parse(calls[1].body).message;
  assert.deepEqual(Object.keys(sent).sort(), ['android', 'apns', 'data', 'token']);
  assert.deepEqual(sent.data, { visit_id: VISIT, event: 'offer_new' });
});

test('fcm: sin cuenta de servicio válida no se construye', () => {
  assert.throws(() => new FcmPushProvider('{}'));
});
