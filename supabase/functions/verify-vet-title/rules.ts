// Reglas internas: no consultan a terceros. Siempre se ejecutan.
import type {
  ProviderDeps,
  Risk,
  TitleVerificationInput,
  TitleVerificationProvider,
  TitleVerificationResult,
} from './providers.ts';
import { normalize } from './providers.ts';

/**
 * Lista INICIAL de universidades chilenas con Medicina Veterinaria (nombres
 * normalizados). Debe validarla el usuario contra CNA/Mineduc
 * (docs/verificacion-automatica.md §5). Estar fuera de la lista NO es un
 * rechazo: solo deja la universidad para revisión manual.
 */
export const KNOWN_VET_SCHOOLS: readonly string[] = [
  'universidad de chile',
  'universidad austral de chile',
  'universidad de concepcion',
  'universidad mayor',
  'universidad santo tomas',
  'universidad andres bello',
  'universidad san sebastian',
  'universidad de las americas',
  'universidad catolica de temuco',
  'universidad de vina del mar',
];

/** ¿La universidad declarada está en la lista? Coincidencia exacta normalizada. */
export function isKnownVetSchool(university: string | null): boolean {
  if (!university) return false;
  const u = normalize(university);
  return KNOWN_VET_SCHOOLS.includes(u);
}

export class RulesProvider implements TitleVerificationProvider {
  readonly source = 'rules' as const;
  readonly authoritative = false;
  static readonly version = 'rules-1';

  verify(input: TitleVerificationInput, deps: ProviderDeps): Promise<TitleVerificationResult> {
    const year = input.graduationYear;
    const currentYear = deps.now().getUTCFullYear();
    const yearOk = year !== null && year >= 1950 && year <= currentYear;
    const known = isKnownVetSchool(input.university);

    let risk: Risk = 'low';
    if (!known || !input.hasVerificationCode) risk = 'medium';
    if (input.foreignDegree || !yearOk) risk = 'high';

    return Promise.resolve({
      source: this.source,
      outcome: known ? 'match' : 'no_match',
      risk,
      // Un título extranjero debe revisarse a mano (revalidación).
      suggestedChecks: known && !input.foreignDegree ? ['university'] : [],
      evidence: {
        university_known: known,
        year_plausible: yearOk,
        code_present: input.hasVerificationCode,
        foreign_degree: input.foreignDegree,
      },
      providerVersion: RulesProvider.version,
    });
  }
}
