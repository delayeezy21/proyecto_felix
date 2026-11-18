// SQL directo (como postgres) contra la BD de un stack local, vía `docker exec`
// + psql. Lo usan los E2E de visitas para simular el paso del tiempo (mover
// la hora de una visita o vencer su plazo), algo que la API no permite.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';

const WIN_DOCKER = 'C:\\Program Files\\Docker\\Docker\\resources\\bin\\docker.exe';

export function sqlRunner(status) {
  const docker = process.env.DOCKER_BIN || (existsSync(WIN_DOCKER) ? WIN_DOCKER : 'docker');
  const port = new URL(status.DB_URL).port;
  const name = execFileSync(docker, ['ps', '--filter', `publish=${port}`, '--format', '{{.Names}}'])
    .toString().trim().split(/\r?\n/)[0];
  if (!name) throw new Error(`No hay un contenedor de BD publicado en el puerto ${port}`);
  return (query) => execFileSync(docker,
    ['exec', '-i', name, 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-tA', '-c', query])
    .toString().trim();
}

// El horario de una visita (scheduled_at, slot, confirm_deadline, started_at)
// solo se mueve desde una sesión directa de postgres con esta marca: la API
// (PostgREST conecta como authenticator) nunca puede hacerlo.
export const timeTravel = (sql, query) => sql(`set felix.time_travel = 'on'; ${query}`);

/// Mueve la hora de una visita (slot de 90 min).
export const shiftVisit = (sql, visitId, expr) => timeTravel(sql,
  `update public.visits set scheduled_at = ${expr},
   slot = tstzrange(${expr}, ${expr} + interval '90 minutes') where id = '${visitId}'`);

/// Simula que la atención empezó hace 15 min (duración mínima de 10 min).
export const backdateStart = (sql, visitId) => timeTravel(sql,
  `update public.visits set started_at = now() - interval '15 minutes' where id = '${visitId}'`);
