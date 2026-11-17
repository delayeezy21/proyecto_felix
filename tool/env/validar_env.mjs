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
  env[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^"(.*)"$/, '$1');
}

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

for (const [k, v] of Object.entries(env)) {
  if (/^sb_secret_/.test(v) || jwtRole(v) === 'service_role') {
    errors.push(`${k} contiene una clave SECRETA de Supabase: nunca va en el cliente`);
  }
  if (/SERVICE|SECRET|DB_PASSWORD|ACCESS_TOKEN/i.test(k)) {
    errors.push(`${k}: las variables de servidor no van en el archivo de la app`);
  }
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
  const h = url.hostname;
  const isPrivate =
    h === 'localhost' || h === '127.0.0.1' || h.startsWith('10.') || h.startsWith('192.168.') ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(h);
  if (url.protocol !== 'https:') errors.push(`SUPABASE_URL debe ser https en ${appEnv}`);
  if (isPrivate) errors.push(`SUPABASE_URL apunta a un host local o privado en ${appEnv}`);
}

if (env.MAP_PROVIDER && !['google', 'osm'].includes(env.MAP_PROVIDER.toLowerCase())) {
  errors.push('MAP_PROVIDER debe ser google u osm');
}

if (errors.length) {
  console.error(`Archivo de entorno inválido (${appEnv}):`);
  for (const e of errors) console.error(`  - ${e}`);
  process.exit(1);
}
console.log(`OK: entorno ${appEnv} válido (${Object.keys(env).join(', ')})`);
