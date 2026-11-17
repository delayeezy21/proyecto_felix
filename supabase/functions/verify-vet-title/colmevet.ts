// Proveedor COLMEVET (buscador público de colegiados). APAGADO por defecto:
// activarlo es decisión del usuario (docs/verificacion-automatica.md §5).
//
// * Busca por NOMBRE (no pedimos RUT). La colegiatura es voluntaria: "sin
//   coincidencias" es neutro y nunca sube el riesgo.
// * La respuesta trae datos de terceros (homónimos): se procesan en memoria y
//   se descartan; solo se guarda la cantidad de coincidencias.
// * Sin saltar protecciones: si el sitio responde con algo distinto de 200 o
//   aparece un captcha, el resultado es 'error'.
import type {
  ProviderDeps,
  TitleVerificationInput,
  TitleVerificationProvider,
  TitleVerificationResult,
} from './providers.ts';
import { errorResult, nameTokens } from './providers.ts';

export const DEFAULT_COLMEVET_SEARCH_URL =
  'https://intranet.colegioveterinario.cl/publico/colegiados';
const MAX_BYTES = 1024 * 1024;

const ENTITIES: Record<string, string> = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
  aacute: 'á', eacute: 'é', iacute: 'í', oacute: 'ó', uacute: 'ú', ntilde: 'ñ',
  Aacute: 'Á', Eacute: 'É', Iacute: 'Í', Oacute: 'Ó', Uacute: 'Ú', Ntilde: 'Ñ', uuml: 'ü',
};

function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e: string) => {
    if (e[0] === '#') {
      const code = e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : m;
    }
    return ENTITIES[e] ?? m;
  });
}

/** Nombres de las tarjetas del listado (`<h6 class="text-primary">`). */
export function parseCardNames(html: string): string[] {
  const out: string[] = [];
  const re = /<h6\b[^>]*class="[^"]*\btext-primary\b[^"]*"[^>]*>([\s\S]*?)<\/h6>/gi;
  for (const m of html.matchAll(re)) {
    const text = decodeEntities(m[1].replace(/<[^>]*>/g, ' ')).trim();
    if (text) out.push(text);
  }
  return out;
}

/** Cantidad de tarjetas cuyo nombre contiene todas las palabras buscadas. */
export function countMatches(cardNames: string[], query: string[]): number {
  return cardNames.filter((n) => {
    const tokens = new Set(nameTokens(n));
    return query.every((q) => tokens.has(q));
  }).length;
}

export function looksLikeCaptcha(html: string): boolean {
  return /captcha|cf-challenge|turnstile/i.test(html);
}

async function readCapped(res: Response, max: number): Promise<string> {
  if (!res.body) return '';
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel();
      break;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(chunks.reduce((n, c) => n + c.byteLength, 0));
  let off = 0;
  for (const c of chunks) {
    all.set(c, off);
    off += c.byteLength;
  }
  return new TextDecoder('utf-8').decode(all);
}

export class ColmevetProvider implements TitleVerificationProvider {
  readonly source = 'colmevet' as const;
  readonly authoritative = false;
  static readonly version = 'colmevet-1';
  readonly searchUrl: string;
  readonly timeoutMs: number;

  constructor(searchUrl: string = DEFAULT_COLMEVET_SEARCH_URL, timeoutMs = 8000) {
    this.searchUrl = searchUrl;
    this.timeoutMs = timeoutMs;
  }

  async verify(input: TitleVerificationInput, deps: ProviderDeps): Promise<TitleVerificationResult> {
    const v = ColmevetProvider.version;
    const query = nameTokens(input.displayName);
    if (query.length < 2) {
      // "Dra. Vera" no alcanza para buscar sin homónimos masivos.
      return {
        source: this.source, outcome: 'skipped', risk: null, suggestedChecks: [],
        evidence: { reason: 'name_too_short' }, providerVersion: v,
      };
    }
    const url = new URL(this.searchUrl);
    url.searchParams.set('type', 'name');
    url.searchParams.set('q', query.join(' '));

    let res: Response;
    try {
      res = await deps.fetch(url.toString(), {
        method: 'GET',
        headers: {
          Accept: 'text/html',
          'User-Agent': 'FelixVerificador/1.0 (verificacion asistida de titulo)',
        },
        redirect: 'follow',
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (e) {
      const name = (e as { name?: string })?.name;
      return errorResult(this.source, v, name === 'TimeoutError' || name === 'AbortError' ? 'timeout' : 'exception');
    }
    if (res.status !== 200) {
      await res.body?.cancel();
      return errorResult(this.source, v, 'http', { http_status: res.status });
    }
    const html = await readCapped(res, MAX_BYTES);
    if (looksLikeCaptcha(html)) {
      return errorResult(this.source, v, 'http', { http_status: res.status, captcha: true });
    }
    const matches = countMatches(parseCardNames(html), query);
    return {
      source: this.source,
      outcome: matches === 0 ? 'no_match' : matches === 1 ? 'match' : 'ambiguous',
      risk: null,
      suggestedChecks: matches === 1 ? ['colmevet'] : [],
      evidence: { matches: Math.min(matches, 99), http_status: res.status },
      providerVersion: v,
    };
  }
}
