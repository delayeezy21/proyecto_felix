// Proveedor FCM (HTTP v1). La cuenta de servicio llega por el secreto
// FCM_SERVICE_ACCOUNT (JSON con project_id, client_email y private_key);
// nunca va en el código. Nunca se llama en tests ni en CI: los unit tests
// usan un fetch simulado.
import type { PushDeps, PushJob, PushProvider, PushResult } from './providers.ts';
import { buildData } from './providers.ts';

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const DEFAULT_TOKEN_URI = 'https://oauth2.googleapis.com/token';

const b64url = (bytes: Uint8Array) => {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};
const b64urlText = (t: string) => b64url(new TextEncoder().encode(t));

function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** JWT firmado (RS256) para pedir un access token de OAuth 2.0. */
export async function signAssertion(sa: ServiceAccount, now: Date): Promise<string> {
  const iat = Math.floor(now.getTime() / 1000);
  const header = b64urlText(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64urlText(JSON.stringify({
    iss: sa.client_email,
    scope: SCOPE,
    aud: sa.token_uri ?? DEFAULT_TOKEN_URI,
    iat,
    exp: iat + 3600,
  }));
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(sa.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${header}.${claims}`)),
  );
  return `${header}.${claims}.${b64url(sig)}`;
}

export class FcmPushProvider implements PushProvider {
  readonly mode = 'fcm' as const;
  private readonly sa: ServiceAccount;

  constructor(serviceAccountJson: string) {
    const sa = JSON.parse(serviceAccountJson) as ServiceAccount;
    if (!sa?.project_id || !sa?.client_email || !sa?.private_key) {
      throw new Error('invalid_fcm_service_account');
    }
    this.sa = sa;
  }

  private async accessToken(deps: PushDeps): Promise<string> {
    const assertion = await signAssertion(this.sa, deps.now());
    const r = await deps.fetch(this.sa.token_uri ?? DEFAULT_TOKEN_URI, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion,
      }).toString(),
    });
    if (!r.ok) throw new Error('fcm_auth_failed');
    const j = await r.json() as { access_token?: string };
    if (!j.access_token) throw new Error('fcm_auth_failed');
    return j.access_token;
  }

  /** Mensaje FCM v1: solo `data` (visit_id + event); la app arma el texto. */
  static message(job: PushJob) {
    return {
      message: {
        token: job.token,
        data: buildData(job),
        android: { priority: 'high' },
        apns: { headers: { 'apns-priority': '10' } },
      },
    };
  }

  async send(jobs: PushJob[], deps: PushDeps): Promise<PushResult> {
    const res: PushResult = { sent: 0, failed: 0, invalidTokens: [] };
    if (jobs.length === 0) return res;
    const token = await this.accessToken(deps);
    const url = `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(this.sa.project_id)}/messages:send`;
    for (const job of jobs) {
      try {
        const r = await deps.fetch(url, {
          method: 'POST',
          headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
          body: JSON.stringify(FcmPushProvider.message(job)),
        });
        if (r.ok) {
          res.sent++;
          continue;
        }
        res.failed++;
        // 404 UNREGISTERED / 400 INVALID_ARGUMENT del token: se borra.
        const text = await r.text();
        if (r.status === 404 || /UNREGISTERED|registration-token-not-registered/.test(text)) {
          res.invalidTokens.push(job.token);
        }
      } catch {
        res.failed++;
      }
    }
    return res;
  }
}
