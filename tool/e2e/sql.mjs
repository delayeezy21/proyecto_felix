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
