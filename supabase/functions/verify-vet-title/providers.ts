// Contrato de los proveedores de verificación del título (verificación asistida).
// Ver docs/verificacion-automatica.md. Sin APIs de Deno: este módulo y sus
// implementaciones también se prueban con `node --test` (sin red).

export type Source = 'rules' | 'colmevet' | 'fake';
export type Outcome = 'match' | 'no_match' | 'ambiguous' | 'error' | 'skipped';
export type Risk = 'low' | 'medium' | 'high';
/** Chequeos de la lista del admin que un proveedor puede sugerir. */
export type SuggestedCheck = 'university' | 'colmevet';

/** Datos mínimos de la solicitud (nunca RUT ni documentos). */
export interface TitleVerificationInput {
  displayName: string;
  university: string | null;
  graduationYear: number | null;
  foreignDegree: boolean;
  hasVerificationCode: boolean;
}

/** Evidencia mínima: contadores, banderas y códigos; nunca nombres de terceros. */
export type Evidence = Record<string, string | number | boolean>;

export interface TitleVerificationResult {
  source: Source;
  outcome: Outcome;
  risk: Risk | null;
  suggestedChecks: SuggestedCheck[];
  evidence: Evidence;
  providerVersion: string;
}

export interface ProviderDeps {
  fetch: typeof fetch;
  now: () => Date;
}

export interface TitleVerificationProvider {
  readonly source: Source;
  /**
   * Si es true, el resultado proviene de una fuente oficial concluyente y
   * podría habilitar auto-aprobación. Ningún proveedor actual lo es.
   */
  readonly authoritative: boolean;
  verify(input: TitleVerificationInput, deps: ProviderDeps): Promise<TitleVerificationResult>;
}

/** Minúsculas, sin tildes ni signos, espacios colapsados. */
export function normalize(text: string): string {
  return text
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9ñ\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

const HONORIFICS = new Set(['dr', 'dra', 'doctor', 'doctora', 'mv', 'mvz', 'med', 'vet', 'sr', 'sra']);

/** Palabras del nombre sin tratamientos ("Dra.", "MV"). */
export function nameTokens(name: string): string[] {
  return normalize(name)
    .split(' ')
    .filter((t) => t.length > 0 && !HONORIFICS.has(t));
}

/** Resultado de error genérico (no expone mensajes internos). */
export function errorResult(
  source: Source,
  providerVersion: string,
  reason: 'timeout' | 'exception' | 'http' | 'rate_limited',
  extra: Evidence = {},
): TitleVerificationResult {
  return {
    source,
    outcome: reason === 'rate_limited' ? 'skipped' : 'error',
    risk: null,
    suggestedChecks: [],
    evidence: { reason, ...extra },
    providerVersion,
  };
}
