# Prueba de capacidad: 5.000 usuarios (Beta)

Fecha: 17-11-2026 · Commit base: `75796f6` + migración `20261117150000_legal_versions_reference.sql`

## Veredicto

**La Beta soporta 5.000 usuarios registrados en Supabase Pro con cómputo Micro.**
- 0 errores en 38.402 peticiones.
- 0 fugas de RLS.
- p95 de 31 ms hasta 50 usuarios simultáneos.

La base de datos **no** es el cuello de botella: todas las consultas tardan menos de 1 ms. Lo caro es el **login** (bcrypt en GoTrue) y la CPU de PostgREST. **No falta ningún índice** a esta escala.

## Cómo se midió

- **Stack local aislado:**
  - `project_id = felix-load` y puertos 55340–55349, para no tocar el stack compartido (54321) ni el de la fase 4 (55321/55322);
  - servicios activos: db, auth, rest, kong y storage (sin studio, realtime, mailpit, edge-runtime, imgproxy, vector, logflare, pg-meta ni supavisor);
  - límites de Auth del stack de prueba subidos a 100.000 para medir la capacidad y no el rate limit.
- **Datos** (`tool/load/seed_carga.sql`, todos ficticios con `@carga.felix.test`):
  - 1 admin;
  - 300 vets: 200 aprobados, 60 en revisión, 20 rechazados y 20 en borrador, con especies, especialidades, horarios, documentos (solo metadatos) y verificaciones;
  - 4.699 dueños con comuna;
  - términos y aviso de privacidad para todos, 1.500 consentimientos y 3.000 entradas de bitácora.
- **Script** `tool/load/capacidad.mjs` (Node 24 con `fetch`; k6 no está instalado):
  - cada usuario virtual (VU) inicia sesión, carga el inicio y navega con una pausa de 0,5 a 1,5 s entre pantallas;
  - refresca el token a mitad de la sesión y vuelve a iniciar sesión cada 8 pantallas;
  - mezcla: ~3 % admin, ~10 % vets y el resto dueños.
- **Flujos medidos:**
  - login por contraseña y refresh;
  - rol y perfil propio (filtrando por `auth.uid()`);
  - `current_legal_version`;
  - catálogos: regiones, comunas por región, especies, especialidades y clínicas 24 h con su comuna;
  - datos propios del vet;
  - vistas del admin: solicitudes pendientes, vets aprobados, detalle del vet, tarifas, `pricing_config` y bitácora;
  - "vets aprobados" pedidos por un **dueño**: la RLS debe devolver 0 filas, y el script cuenta una fuga si devuelve alguna.
- **Fases en secuencia:** 10, 25, 50 y 100 VUs, 60 s cada una, con 10 s de pausa entre fases.
- **Hardware:** el mismo PC (16 GB, con el stack compartido y el de la fase 4 encendidos) corre el cliente de carga y todos los contenedores.

**Equivalencia:** un VU de esta prueba hace una petición cada ~0,3 s. Un usuario real cambia de pantalla cada 5–10 s. Por eso **50 VUs ≈ 500–1.000 usuarios reales simultáneos**, de 5 a 10 veces el pico esperado de 50–100.

## Resultados

| VUs | Peticiones | req/s | p50 | p95 | p99 | Errores | Fugas RLS |
|---|---|---|---|---|---|---|---|
| 10 | 2.556 | 41,7 | 3,9 ms | 24,4 ms | 76 ms | 0 | 0 |
| 25 | 5.783 | 94,7 | 3,9 ms | 28,7 ms | 88 ms | 0 | 0 |
| 50 | 11.509 | 187,6 | 4,1 ms | 31,3 ms | 89 ms | 0 | 0 |
| 100 | 18.554 | 301,7 | 13,7 ms | 244,5 ms | 1.078 ms | 0 | 0 |

Por flujo (p50 / p95, en ms):

| Flujo | 10 VUs | 50 VUs | 100 VUs |
|---|---|---|---|
| Login (contraseña) | 73 / 122 | 82 / 117 | 136 / **2.739** |
| Refresh token | 16 / 32 | 17 / 32 | 34 / 814 |
| `user_roles` propio (1.ª lectura tras el login) | 21 / 29 | 23 / 41 | 44 / 694 |
| Catálogos (peor de los 5) | 4 / 7 | 4 / 9 | 10 / 221 |
| Dueño pide vets aprobados (RLS, 0 filas) | 4 / 7 | 4 / 11 | 13 / 357 |
| Admin: solicitudes pendientes | 5 / 24 | 5 / 24 | 19 / 179 |

A 100 VUs el throughput deja de crecer linealmente: 302 req/s, cuando lo lineal serían ~375. Con `docker stats` en el pico:
- PostgREST: **98 %** de CPU;
- GoTrue: **78 %** (bcrypt);
- Kong: 28 %;
- Postgres: 39 % y 211 MB.

La saturación viene de la CPU compartida del PC, que también corre el generador de carga, no de Postgres.

## Consultas más caras (`pg_stat_statements`, las 4 fases)

| Consulta | Llamadas | Media | Máx. | Comentario |
|---|---|---|---|---|
| `vet_profiles` aprobados pedidos por un dueño (RLS → 0 filas) | 2.931 | 0,54 ms | 59 ms | Seq scan de 300 filas filtrando por la política. Ver EXPLAIN |
| `set_config(...)` de PostgREST por petición | 36.029 | 0,03 ms | 16 ms | Costo fijo por petición |
| `current_legal_version` (RPC) | 3.211 | 0,33 ms | 22 ms | Índice `(kind, effective_from desc)` |
| `INSERT refresh_tokens` (GoTrue) | 2.373 | 0,36 ms | 346 ms | Escritura de Auth en cada login o refresh |
| `emergency_clinics` + `communes(name)` | 3.478 | 0,22 ms | 28 ms | Hash join con 346 comunas |
| Admin: solicitudes pendientes | 372 | 0,84 ms | 12 ms | Index scan `vet_profiles_status_idx` |

EXPLAIN (ANALYZE, BUFFERS) como `authenticated` con los claims reales:
- **Dueño → vets aprobados:**
  - `Seq Scan on vet_profiles`, con filtro `(user_id = auth.uid() OR is_admin()) AND status = 'approved'`;
  - 300 filas descartadas, 39 buffers, **1,75 ms** (incluye 0,48 ms de `is_admin()` como InitPlan, que se evalúa una sola vez gracias a `(select ...)`).
- **Admin → pendientes:** `Index Scan using vet_profiles_status_idx`, 60 filas, **0,58 ms**.
- **Bitácora (50 últimos):** `Index Scan using admin_audit_log_at_idx`, **0,25 ms**.
- **Clínicas 24 h:** hash join, **1,5 ms**.

## Índices

- **Claves foráneas sin índice:** ninguna. Se revisaron todas las FK de `public` contra la primera columna de un índice.
- **Seq scans altos:** solo en tablas de catálogo diminutas (`communes` 346, `species` 9, `specialties` 12, `regions` 16, `emergency_clinics` 4). Ahí el seq scan es lo óptimo.
- **`supabase db advisors`** (seguridad y rendimiento): **sin hallazgos**.
- **Conclusión:** no se agrega ninguna migración de índices. Agregar índices sin una consulta que los use solo encarece las escrituras.
- **A futuro** (no es de esta fase): cuando exista la búsqueda de vets para dueños (fase 5/8), irá por una RPC o vista con PostGIS y necesitará un índice **GiST** sobre la ubicación del vet, más uno parcial `where status = 'approved'`. Hay que medirlo con este mismo script cuando exista.

## Tamaño de cómputo recomendado

| Cómputo | RAM | Conexiones BD | Clientes del pooler | Costo con Pro | Veredicto |
|---|---|---|---|---|---|
| **Micro** | 1 GB | 60 | 200 | US$0 extra (crédito de US$10) | **Recomendado para la Beta de 5.000** |
| Small | 2 GB | 90 | 400 | +US$5 | Cuando lleguen las urgencias (fase 8: pg_cron cada 10 s, PostGIS y Realtime) o si la CPU pasa del 70 % sostenido |
| Medium | 4 GB | 120 | 600 | +US$50 | No hace falta para 5.000; el informe de costos lo ubica en ~50.000 usuarios |

Por qué Micro alcanza:
- **Carga esperada:**
  - 500 activos al día, con un pico de 50–100 simultáneos que cambian de pantalla cada 5–10 s, son **10–20 req/s**;
  - la prueba sostuvo **188 req/s con p95 de 31 ms**, unas 10 veces más, en una CPU compartida con todo lo demás.
- **Base de datos:**
  - toda la base de prueba (5.000 usuarios) cabe en `shared_buffers` (128 MB);
  - Postgres no pasó de 211 MB.
- **Login:**
  - cada login cuesta ~70 ms de CPU (bcrypt costo 10), así que 2 núcleos compartidos aguantan ~20 logins por segundo;
  - el pico realista de 5.000 usuarios es de 1–2 por segundo.
- **Qué vigilar** (Dashboard → Reports → Database):
  - CPU sobre 70 % por más de 15 min;
  - RAM con swap;
  - conexiones sobre 45 de 60.
  - Si se cumple alguna, sube a Small: se hace en caliente, con unos 2 minutos sin servicio.

## Pooler

- La app **no** abre conexiones directas a Postgres. Todo pasa por la Data API (PostgREST, con su propio pool), Auth y Storage. **El pooler no es necesario para la app.**
- **Session pooler (puerto 5432, IPv4):** úsalo para la CLI y GitHub Actions (`link`, `db push`, `db dump`). La conexión directa `db.<ref>.supabase.co` es **solo IPv6** y los runners de GitHub no tienen IPv6. No hace falta comprar el add-on de IPv4.
- **Transaction pooler (puerto 6543):** solo si una Edge Function futura usa un driver de Postgres en vez de `supabase-js`. Hoy ninguna lo hace.
- El *dedicated pooler* (PgBouncer) no hace falta.

## Límites de Auth para 5.000 usuarios (nube, valores por defecto)

| Límite | Por defecto | Riesgo a esta escala | Acción |
|---|---|---|---|
| Correos con el SMTP de Supabase | **2 por hora** (todo el proyecto) | Bloquea cualquier registro real | **SMTP propio obligatorio** (paso 7.3 del runbook) |
| Correos con SMTP propio | Configurable (30 por hora al empezar) | 5.000 confirmaciones repartidas en semanas: OK. En un lanzamiento masivo, no | Subir a 100–300 por hora y que el proveedor lo soporte. **Resend Free tiene tope de 100 al día**: usar SES o Resend Pro para la apertura |
| Registros e inicios de sesión | 30 cada 5 min **por IP** | Las redes móviles chilenas (CGNAT) y las oficinas comparten IP | Subir a 100 |
| `/token` (login y refresh) | 150 cada 5 min por IP | El refresh es ~1 por hora por usuario: OK, salvo un CGNAT grande | Subir a 300 |
| Verificaciones OTP | 30 cada 5 min por IP | Bajo | 60 |
| Envío de OTP o confirmación | 1 por minuto por usuario | Ninguno | — |
| MAU incluidos en Pro | 100.000 | 5.000 es el 5 % | — |

## Límites de Realtime (Pro)

| Límite | Pro | Uso esperado con 5.000 usuarios |
|---|---|---|
| Conexiones simultáneas | 500 | Hoy la app no usa Realtime. Desde la fase 8, una conexión por app abierta: pico de ~100–200 |
| Mensajes por segundo | 500 | Ubicación cada 5 s por visita "en camino": 20 visitas a la vez ≈ 4 por segundo |
| Joins de canal por segundo | 500 | Bajo |
| Mensajes al mes | 5 M incluidos | ~500 por visita × 1.000 visitas ≈ 0,5 M |

Riesgo señalado por el PM: suscribirse por Realtime a la **presencia de todos los vets** multiplica las conexiones y los mensajes. Hay que diseñarlo con canales por zona y medirlo en la fase 8.

## Cómo repetir la prueba

```bash
# 1. Copia supabase/ a un directorio aparte y edita su config.toml:
#    project_id = "felix-load", puertos 5534x, inspector_port = 8094,
#    [auth.rate_limit] sign_in_sign_ups y token_refresh = 100000.
npx --yes supabase@3.2.0 start --workdir <dir> \
  -x studio,imgproxy,vector,logflare,realtime,mailpit,postgres-meta,supavisor,edge-runtime
npx --yes supabase@3.2.0 test db --workdir <dir>
docker exec -i supabase_db_felix-load psql -U supabase_admin -d postgres < tool/load/seed_carga.sql
docker exec supabase_db_felix-load psql -U supabase_admin -d postgres \
  -c "create extension if not exists pg_stat_statements with schema extensions"
node tool/load/capacidad.mjs "$(npx --yes supabase@3.2.0 status --workdir <dir> -o json | sed -n '/^{/,$p')"
npx --yes supabase@3.2.0 stop --workdir <dir> --no-backup
```

El script se niega a correr contra hosts que no sean locales y contra el puerto 54321 (el stack compartido).

## Hallazgos colaterales (corregidos o documentados)

1. **Las versiones legales solo estaban en `seed.sql`.** En la nube nadie podría registrarse: `complete_registration` exige la versión vigente. Se corrigió con la migración idempotente `20261117150000_legal_versions_reference.sql`. pgTAP 156/156 y advisors limpios.
2. **La CLI 3.2.0 apunta a la base local por defecto**: `db push`, `db dump` y `migration list` necesitan `--remote`. Los workflows y el runbook ya lo usan.
3. **`supabase config push` no se debe usar**: subiría `site_url = localhost` y los límites locales a la nube.
4. **La purga de documentos necesita la `service_role` JWT legada** en Vault. Si se desactivan las claves legadas, responde 403.
5. **La app no tiene "Olvidé mi contraseña".** Conviene tenerlo antes de abrir a 5.000 personas.
6. **GitHub Pages rompería la confirmación de correo**: la app vuelve a `Uri.base.origin`, sin la subcarpeta del repo. Por eso se eligió Cloudflare Pages, que sirve en la raíz.
