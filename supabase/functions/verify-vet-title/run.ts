// Orquestación pura (sin Deno ni Supabase): elige proveedores según la
// configuración y los ejecuta con timeout. Un proveedor que falla nunca
// rompe la verificación: queda registrado como 'error'.
import { ColmevetProvider, DEFAULT_COLMEVET_SEARCH_URL } from './colmevet.ts';
import { FakeProvider } from './fake.ts';
import type {
  ProviderDeps,
  TitleVerificationInput,
  TitleVerificationProvider,
  TitleVerificationResult,
} from './providers.ts';
import { errorResult } from './providers.ts';
import { RulesProvider } from './rules.ts';

export type ProviderMode = 'off' | 'fake' | 'colmevet';

export interface VerificationConfig {
  mode: ProviderMode;
  colmevetSearchUrl: string;
  timeoutMs: number;
}

/** Lee la configuración desde variables de entorno (por defecto: apagado). */
export function readConfig(env: (k: string) => string | undefined): VerificationConfig {
  const raw = (env('TITLE_VERIFICATION_PROVIDER') ?? 'off').trim().toLowerCase();
  const mode: ProviderMode = raw === 'fake' || raw === 'colmevet' ? raw : 'off';
  const timeout = Number(env('TITLE_VERIFICATION_TIMEOUT_MS') ?? '8000');
  return {
    mode,
    colmevetSearchUrl: env('COLMEVET_SEARCH_URL') || DEFAULT_COLMEVET_SEARCH_URL,
    timeoutMs: Number.isFinite(timeout) && timeout >= 100 && timeout <= 15000 ? timeout : 8000,
  };
}

/** Proveedor externo configurado (o null si está apagado). */
export function externalProvider(cfg: VerificationConfig): TitleVerificationProvider | null {
  switch (cfg.mode) {
    case 'fake':
      return new FakeProvider();
    case 'colmevet':
      return new ColmevetProvider(cfg.colmevetSearchUrl, cfg.timeoutMs);
    default:
      return null;
  }
}

function providerVersion(p: TitleVerificationProvider): string {
  return (p.constructor as unknown as { version?: string }).version ?? `${p.source}-?`;
}

/** Ejecuta un proveedor con timeout; nunca lanza. */
export async function runProvider(
  p: TitleVerificationProvider,
  input: TitleVerificationInput,
  deps: ProviderDeps,
  timeoutMs: number,
): Promise<TitleVerificationResult> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<TitleVerificationResult>((resolve) => {
    timer = setTimeout(() => resolve(errorResult(p.source, providerVersion(p), 'timeout')), timeoutMs);
  });
  try {
    return await Promise.race([
      p.verify(input, deps).catch(() => errorResult(p.source, providerVersion(p), 'exception')),
      timeout,
    ]);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Corre las reglas internas y, si está configurado y hay cuota, el proveedor
 * externo. Sin cuota externa el resultado es 'skipped' (rate_limited).
 */
export async function runVerification(
  input: TitleVerificationInput,
  cfg: VerificationConfig,
  deps: ProviderDeps,
  externalQuotaOk: boolean,
): Promise<TitleVerificationResult[]> {
  const results = [await runProvider(new RulesProvider(), input, deps, cfg.timeoutMs)];
  const ext = externalProvider(cfg);
  if (ext) {
    results.push(
      externalQuotaOk
        ? await runProvider(ext, input, deps, cfg.timeoutMs)
        : errorResult(ext.source, providerVersion(ext), 'rate_limited'),
    );
  }
  return results;
}

export type BlockedCheck = (ids: string[]) => PromiseLike<{ data: unknown; error: unknown }>;

/**
 * QA-F11-04: ¿se puede tratar a estos titulares? Una cuenta con solicitud de
 * eliminación (bloqueada) no se trata y, ante cualquier duda (error o
 * respuesta inesperada), se falla cerrado.
 */
export async function subjectGate(
  check: BlockedCheck,
  ids: string[],
): Promise<'ok' | 'blocked' | 'error'> {
  try {
    const { data, error } = await check([...new Set(ids)]);
    if (error || typeof data !== 'boolean') return 'error';
    return data ? 'blocked' : 'ok';
  } catch {
    return 'error';
  }
}
