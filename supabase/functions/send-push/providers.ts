// Contrato de los proveedores de push (fase 8). Sin APIs de Deno: este módulo
// y sus implementaciones también se prueban con `node --test` (sin red).
//
// Privacidad (SPEC HU2.3): el payload lleva SOLO `visit_id` y el tipo de
// evento. Nada de nombres, direcciones ni datos clínicos (FCM pasa por
// Google). La app trae el detalle por la API con la sesión del usuario.

export type PushMode = 'off' | 'fake' | 'fcm';
export type Platform = 'android' | 'ios' | 'web';

/** Fila que entrega `claim_push_batch` (el token nunca sale de la función). */
export interface PushJob {
  id: number;
  token: string;
  platform: Platform;
  visit_id: string;
  event: string;
}

/** Los únicos datos que viajan al proveedor. */
export interface PushData {
  visit_id: string;
  event: string;
}

export interface PushResult {
  sent: number;
  failed: number;
  /** Tokens que el proveedor declaró inválidos (se borran). */
  invalidTokens: string[];
}

export interface PushDeps {
  fetch: typeof fetch;
  now: () => Date;
}

export interface PushProvider {
  readonly mode: PushMode;
  send(jobs: PushJob[], deps: PushDeps): Promise<PushResult>;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EVENT = /^[a-z_]{3,40}$/;

/** Payload mínimo; rechaza cualquier valor fuera de forma. */
export function buildData(job: Pick<PushJob, 'visit_id' | 'event'>): PushData {
  if (!UUID.test(job.visit_id) || !EVENT.test(job.event)) {
    throw new Error('invalid_push_job');
  }
  return { visit_id: job.visit_id, event: job.event };
}

export interface PushConfig {
  mode: PushMode;
  /** JSON de la cuenta de servicio de FCM (solo en secretos, nunca en el código). */
  fcmServiceAccount: string | null;
}

/** Lee la configuración (por defecto: apagado). */
export function readConfig(env: (k: string) => string | undefined): PushConfig {
  const raw = (env('PUSH_PROVIDER') ?? 'off').trim().toLowerCase();
  const mode: PushMode = raw === 'fake' || raw === 'fcm' ? raw : 'off';
  return { mode, fcmServiceAccount: env('FCM_SERVICE_ACCOUNT') ?? null };
}

/** Proveedor falso: no usa la red; registra en memoria lo que "envió". */
export class FakePushProvider implements PushProvider {
  readonly mode = 'fake' as const;
  readonly delivered: { platform: Platform; data: PushData }[] = [];

  send(jobs: PushJob[]): Promise<PushResult> {
    for (const j of jobs) this.delivered.push({ platform: j.platform, data: buildData(j) });
    return Promise.resolve({ sent: jobs.length, failed: 0, invalidTokens: [] });
  }
}
