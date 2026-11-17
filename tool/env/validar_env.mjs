// Valida un archivo de entorno de la app ANTES de compilar (local, beta o producción).
//
//   node tool/env/validar_env.mjs .env.beta
//
// Reglas (docs/despliegue-beta.md, "Entornos de la app"):
// * SUPABASE_URL y SUPABASE_PUBLISHABLE_KEY son obligatorias.
// * Nunca una clave secreta: ni `sb_secret_...` ni un JWT con rol service_role.
// * Si APP_ENV es beta o production: URL https y no local ni de red privada.
// Nunca imprime valores, solo nombres de variables.
import { readFileSync } from 'node:fs';

const file = process.argv[2];
if (!file) {
  console.error('Uso: node tool/env/validar_env.mjs <archivo>');
  process.exit(2);
}

const env = {};
for (const raw of readFileSync(file, 'utf8').split(/\r?\n/)) {
  const line = raw.trim();
  if (!line || line.startsWith('#')) continue;
  const i = line.indexOf('=');
  if (i < 0) continue;
  const k = line.slice(0, i).trim().replace(/^export\s+/, '');
  // Quita comillas dobles o simples (QA-22).
  env[k] = line.slice(i + 1).trim().replace(/^(["'])(.*)\1$/, '$2');
}

// Texto crudo de todo el archivo: los secretos se buscan también ahí, por si
// el parser no entendiera alguna línea (comillas raras, espacios, etc.).
const rawText = readFileSync(file, 'utf8');

const errors = [];
const appEnv = (env.APP_ENV || 'local').toLowerCase();
if (!['local', 'beta', 'production'].includes(appEnv)) {
  errors.push(`APP_ENV debe ser local, beta o production (es "${appEnv}")`);
}

const jwtRole = (v) => {
  const parts = v.split('.');
  if (parts.length !== 3) return null;
  try {
    return JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8')).role ?? null;
  } catch {
    return null;
  }
};

// Algún JWT con rol service_role en cualquier posición del texto.
const hasServiceRoleJwt = (text) =>
  (text.match(/[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/g) ?? []).some(
    (t) => jwtRole(t) === 'service_role',
  );
const hasSecret = (text) => /sb_secret_/.test(text) || hasServiceRoleJwt(text);

for (const [k, v] of Object.entries(env)) {
  if (hasSecret(v)) {
    errors.push(`${k} contiene una clave SECRETA de Supabase: nunca va en el cliente`);
  }
  if (/SERVICE|SECRET|DB_PASSWORD|ACCESS_TOKEN/i.test(k)) {
    errors.push(`${k}: las variables de servidor no van en el archivo de la app`);
  }
}
if (!errors.some((e) => e.includes('SECRETA')) && hasSecret(rawText)) {
  errors.push('El archivo contiene una clave SECRETA de Supabase: nunca va en el cliente');
}

const key = env.SUPABASE_PUBLISHABLE_KEY ?? '';
if (!key) errors.push('Falta SUPABASE_PUBLISHABLE_KEY');
else if (!/^sb_publishable_/.test(key) && jwtRole(key) !== 'anon') {
  errors.push('SUPABASE_PUBLISHABLE_KEY debe ser sb_publishable_... (o la anon JWT legada)');
}

let url;
try {
  url = new URL(env.SUPABASE_URL ?? '');
} catch {
  errors.push('SUPABASE_URL falta o no es una URL válida');
}
if (url && appEnv !== 'local') {
  if (url.protocol !== 'https:') errors.push(`SUPABASE_URL debe ser https en ${appEnv}`);
  if (isLocalOrPrivateHost(url.hostname)) {
    errors.push(`SUPABASE_URL apunta a un host local o privado en ${appEnv}`);
  }
}

if (env.MAP_PROVIDER && !['google', 'osm'].includes(env.MAP_PROVIDER.toLowerCase())) {
  errors.push('MAP_PROVIDER debe ser google u osm');
}

// Host local, de loopback, de enlace local o de red privada (QA-21).
// `URL` ya normaliza las IPv4 raras (2130706433, 0x7f.1, 127.1) a decimal con puntos.
function isLocalOrPrivateHost(hostname) {
  const h = hostname.toLowerCase().replace(/^\[|\]$/g, '').replace(/\.+$/, '');
  if (h === '' || h === 'localhost' || h === 'host.docker.internal') return true;
  if (/\.(localhost|local|internal|lan|home\.arpa)$/.test(h)) return true;
  if (!h.includes('.') && !h.includes(':')) return true; // nombre sin dominio (intranet)

  const v4 = h.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (v4) return isPrivateV4(v4.slice(1).map(Number));

  if (h.includes(':')) {
    // IPv4 embebida (::ffff:127.0.0.1 o ::ffff:7f00:1).
    const dotted = h.match(/(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
    if (dotted) return isPrivateV4(dotted.slice(1).map(Number));
    const mapped = h.match(/^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/);
    if (mapped) {
      const [a, b] = [parseInt(mapped[1], 16), parseInt(mapped[2], 16)];
      return isPrivateV4([a >> 8, a & 255, b >> 8, b & 255]);
    }
    if (h === '::' || h === '::1') return true; // no especificada / loopback
    const first = parseInt(h.split(':')[0] || '0', 16);
    if ((first & 0xfe00) === 0xfc00) return true; // fc00::/7 (ULA)
    if ((first & 0xffc0) === 0xfe80) return true; // fe80::/10 (enlace local)
    return false;
  }
  return false;
}

function isPrivateV4([a, b]) {
  return (
    a === 0 || // 0.0.0.0/8
    a === 10 ||
    a === 127 || // loopback completo
    (a === 169 && b === 254) || // enlace local
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 100 && b >= 64 && b <= 127) // CGNAT
  );
}

if (errors.length) {
  console.error(`Archivo de entorno inválido (${appEnv}):`);
  for (const e of errors) console.error(`  - ${e}`);
  process.exit(1);
}
console.log(`OK: entorno ${appEnv} válido (${Object.keys(env).join(', ')})`);
