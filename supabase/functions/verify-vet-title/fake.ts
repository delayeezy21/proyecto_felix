// Proveedor falso y determinista para tests y E2E (nunca llama a la red).
// Decide según palabras del nombre visible (solo datos ficticios):
//   "Colegiado" → match · "Homonimo" → ambiguous · "Falla" → lanza error
//   "Lento" → excede el timeout · cualquier otro → no_match.
import type {
  ProviderDeps,
  TitleVerificationInput,
  TitleVerificationProvider,
  TitleVerificationResult,
} from './providers.ts';
import { normalize } from './providers.ts';

export class FakeProvider implements TitleVerificationProvider {
  readonly source = 'fake' as const;
  readonly authoritative = false;
  static readonly version = 'fake-1';
  readonly slowMs: number;

  constructor(slowMs = 60_000) {
    this.slowMs = slowMs;
  }

  async verify(input: TitleVerificationInput, _deps: ProviderDeps): Promise<TitleVerificationResult> {
    const n = normalize(input.displayName);
    if (n.includes('falla')) throw new Error('fallo simulado');
    if (n.includes('lento')) await new Promise((r) => setTimeout(r, this.slowMs));
    const outcome = n.includes('colegiado') ? 'match' : n.includes('homonimo') ? 'ambiguous' : 'no_match';
    return {
      source: this.source,
      outcome,
      risk: null,
      suggestedChecks: outcome === 'match' ? ['colmevet'] : [],
      evidence: { matches: outcome === 'match' ? 1 : outcome === 'ambiguous' ? 2 : 0 },
      providerVersion: FakeProvider.version,
    };
  }
}
