# Despliegue de la Beta en la nube (runbook)

> Formato TDAH: un paso por bloque, una acción por línea y un **Listo cuando** para saber que terminaste.
> Los comandos usan la CLI fijada vía `npx --yes supabase@3.2.0` (no hay que instalarla).
> En los ejemplos, `SB` significa `npx --yes supabase@3.2.0`.

## En 30 segundos

- **Backend:** Supabase Cloud **Pro** (US$25 al mes, incluye US$10 de cómputo), región **São Paulo (sa-east-1)** y cómputo **Micro**. El plan Free no sirve: se pausa tras 7 días sin uso y no tiene respaldos.
- **Web:** **Cloudflare Pages** (gratis, ancho de banda ilimitado, cabeceras propias y fallback SPA).
- **Correo de Auth:** SMTP propio (**Resend** o **Amazon SES**). El SMTP por defecto de Supabase permite solo 2 correos por hora.
- **Capacidad:** la prueba de 5.000 usuarios no tuvo errores. El cuello de botella es la CPU del login (bcrypt), no la base de datos. Detalle en [`docs/qa/capacidad-5000.md`](qa/capacidad-5000.md).
- **Despliegue:** tres workflows manuales: `db-migrate.yml`, `web-deploy.yml` y `db-backup.yml` (este último queda inactivo hasta que lo enciendas).

## Orden y tiempo estimado

| # | Paso | Tiempo | Quién |
|---|---|---|---|
| 0 | Cuentas y pagos | 30 min | Tú |
| 1 | Crear el proyecto Supabase | 10 min | Tú |
| 2 | `login` y `link` | 5 min | Tú (terminal) |
| 3 | Migraciones (`db push`, sin seed) | 5 min | Tú o el workflow |
| 4 | Edge Functions y sus secretos | 5 min | Tú o el workflow |
| 5 | pg_cron y Vault | 5 min | Tú (SQL Editor) |
| 6 | Storage | 2 min | Revisar |
| 7 | Auth: URLs, correo, SMTP, límites y plantillas | 30 min | Tú (dashboard) |
| 8 | Web en Cloudflare Pages | 20 min | Tú, luego el workflow |
| 9 | Primer admin | 5 min | Tú (SQL Editor) |
| 10 | Prueba de humo en la nube | 15 min | Tú |
| 11 | Respaldos | 20 min | Tú |
| 12 | Checklist de seguridad | 30 min | Tú y Claude |
| 13 | Rollback | Leer antes | — |
| 14 | Invitar testers | — | Tú |

---

## Paso 0 · Cuentas y pagos (en este orden)

- [ ] **Dominio** `.cl` en NIC Chile (unos $9.990 al año). Hace falta para el SMTP (SPF y DKIM) y para una URL propia. Ejemplo: `felix.cl`.
- [ ] **Supabase:** crea la organización, pásala a **Pro** y registra la tarjeta.
- [ ] **Resend** (gratis: 3.000 correos al mes y 100 al día) o **Amazon SES**. Ver el paso 7.3 para elegir.
- [ ] **Cloudflare** (gratis). Si quieres, mueve aquí el DNS del dominio.
- [ ] **GitHub:** ya existe. Crea los Environments `beta`, `production` y `backup` (paso 8.3).
- [ ] **Gestor de contraseñas** (Bitwarden o 1Password) para la contraseña de la base, los tokens y la clave privada de los respaldos.
- [ ] *Más adelante:* Apple Developer (US$99 al año) y Google Play Console (US$25, pago único).

**Listo cuando:** puedes entrar a Supabase (Pro), Cloudflare y Resend/SES.

---

## Paso 1 · Crear el proyecto Supabase

1. Dashboard → **New project**.
2. Nombre: `felix-beta`. Región: **South America (São Paulo) — sa-east-1**.
3. **Database password:** genera una de 32 o más caracteres y guárdala en el gestor como `SUPABASE_DB_PASSWORD (beta)`.
4. **Compute:** **Micro** (cubierto por el crédito del plan Pro).
5. Espera a que diga *Healthy*.
6. Anota el **Project ref** (Settings → General): 20 letras minúsculas.
7. Settings → **API Keys**: copia la **Publishable key** (`sb_publishable_...`). Esa clave va en la app.
   - **No** copies la Secret key a ningún archivo de la app.
   - Deja **activas** las claves JWT legadas (`anon` y `service_role`). La purga de documentos las usa (paso 5).

**Listo cuando:** tienes el ref, la publishable key y la contraseña guardados en el gestor.

---

## Paso 2 · `login` y `link`

```powershell
npx --yes supabase@3.2.0 login                       # abre el navegador y crea el access token
npx --yes supabase@3.2.0 link --project-ref <REF>    # pide la contraseña de la base
```

- `link` usa el **pooler IPv4** por defecto. La conexión directa `db.<ref>.supabase.co` es solo IPv6.
- Crea además un **access token con alcance (scoped PAT)** para GitHub Actions, **uno por proyecto**:
  - Account → Access Tokens → *Generate new token*. Los tokens del dashboard ya nacen con alcance y empiezan con `sbp_fc`.
  - **Nunca** uses un token "Legacy": tiene los mismos privilegios que tu usuario sobre **todos** tus proyectos.
  - Nombre: `gha-felix-beta`. **Proyecto:** solo `felix-beta`. **Vencimiento:** 90 días (anótalo en el calendario para rotarlo).
  - Permisos mínimos, según la CLI 3.2.0 y la [guía de personal access tokens](https://supabase.com/docs/guides/platform/personal-access-tokens):

    | Para | Permiso |
    |---|---|
    | Todos los comandos | Projects (Read) y Branching production (Read) (`projects_read`, `branching_production_read`) |
    | `link` | Project admin (Read) (`project_admin_read`), Project Settings (Read), API Keys (Read), API Key Secrets (Read) |
    | `migration list` / `db push --remote` | Database (Read-write), Database Pooling Config (Read), Migrations (Read-write) |
    | `db advisors --remote` | Advisors (Read) |
    | `functions deploy` | Edge Functions (Read-write) |
    | `secrets set` (manual, no lo usa el workflow) | Edge Function Secrets (Read-write) |

  - Si el formulario cambia de nombres, elige los equivalentes y **solo para ese proyecto**. Si un paso falla por permisos, el error de la CLI dice cuál falta: agrégalo y nada más.
  - Repite para producción: `gha-felix-prod`, limitado al proyecto `felix-prod`.
  - Guárdalos en el gestor.
- **Si tu cuenta no ofreciera tokens con alcance:** crea **una organización de Supabase por ambiente** (`felix-beta-org` y `felix-prod-org`), cada una con su propio usuario de servicio (un correo distinto) y su token. Así el token de beta no puede tocar producción.

**Listo cuando:** `SB migration list --remote` muestra las migraciones locales y la columna remota vacía.

---

## Paso 3 · Migraciones (sin `seed.sql`)

> **Ojo con la CLI v3:** `db push` apunta a la base **local** por defecto. Para la nube hay que pasar **`--remote`**.
> **Nunca** uses `--include-seed`: `seed.sql` solo tiene datos demo, como las clínicas ficticias.
> **Nunca** uses `supabase config push`: subiría la configuración local (`site_url = localhost`, 2 correos por hora, etc.).

**Opción A, desde tu PC:**

```powershell
npx --yes supabase@3.2.0 test db                     # contra tu stack local (pgTAP en verde)
npx --yes supabase@3.2.0 db push --remote --dry-run  # revisa la lista
npx --yes supabase@3.2.0 db push --remote
npx --yes supabase@3.2.0 db advisors --remote --level warn
```

**Opción B, con el workflow (recomendada desde la segunda vez):**
GitHub → Actions → **Migrar base de datos (nube)** → Run workflow:
- `environment`: `beta`;
- `confirm`: `MIGRAR beta`.

El workflow corre pgTAP, advisors y E2E en un Supabase efímero. Recién entonces hace `db push --remote`.

Qué crean las migraciones (no hay que hacerlo a mano):
- tablas con RLS forzada, grants mínimos, catálogos (346 comunas, especies, especialidades, tarifas y `pricing_config`);
- **versiones legales vigentes** (`20261117150000_legal_versions_reference.sql`). Antes estaban solo en el seed y sin ellas nadie podía registrarse;
- el bucket privado `vet-documents` y sus políticas;
- las extensiones `postgis`, `btree_gist`, `pg_cron` y `pg_net`, y el job `purge-vet-documents`.

**Listo cuando:** `SB migration list --remote` muestra todas las migraciones aplicadas y el advisor no reporta nada de nivel `WARN` o `ERROR`.

---

## Paso 4 · Edge Functions y sus secretos

```powershell
npx --yes supabase@3.2.0 secrets set TITLE_VERIFICATION_PROVIDER=off
npx --yes supabase@3.2.0 functions deploy --use-api   # purge-vet-documents y verify-vet-title
npx --yes supabase@3.2.0 secrets list
```

- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` y `SUPABASE_ANON_KEY` las inyecta Supabase solo. No las definas.
- `TITLE_VERIFICATION_PROVIDER=off`: la verificación asistida queda apagada. **Nunca** uses `colmevet` sin revisar antes `docs/verificacion-automatica.md`.
- Ambas funciones quedan con `verify_jwt` activo (el valor por defecto).
- En el workflow: marca `deploy_functions: true` al migrar.

**Listo cuando:** Dashboard → Edge Functions muestra las 2 funciones como *Active*.

---

## Paso 5 · pg_cron y Vault (purga de documentos)

La migración ya programó `purge-vet-documents` cada hora. El job **no hace nada** hasta que existan 2 secretos en Vault.

Dashboard → **SQL Editor** (pega los valores ahí, **nunca** en un archivo del repo):

```sql
select vault.create_secret('https://<REF>.supabase.co', 'project_url');
-- La clave service_role JWT LEGADA (eyJ...): Settings → API Keys → Legacy API keys.
-- La función compara exactamente contra SUPABASE_SERVICE_ROLE_KEY; una sb_secret_ no sirve.
select vault.create_secret('<SERVICE_ROLE_JWT_LEGADA>', 'service_role_key');
```

Verifica:

```sql
select jobname, schedule, active from cron.job;                       -- purge-vet-documents | 0 * * * * | t
-- Después de la siguiente hora en punto:
select status, start_time from cron.job_run_details order by start_time desc limit 3;
select status_code, created from net._http_response order by created desc limit 3;  -- 200
```

> Si algún día desactivas las claves legadas, la purga empieza a responder 403. Antes hay que adaptar `purge-vet-documents` a las claves nuevas.

**Listo cuando:** `net._http_response` muestra `200`.

---

## Paso 6 · Storage

- Dashboard → Storage: existe `vet-documents`, **privado**, con 5 MB por archivo y solo PDF, JPEG o PNG.
- Las políticas vienen en la migración: cada vet sube solo a su carpeta y el admin lee con URL firmada de 60 s.
- Settings → Storage → *Upload file size limit*: deja 50 MB (el bucket ya limita a 5 MB).

**Listo cuando:** ves el bucket privado. No hay que crear nada.

---

## Paso 7 · Auth

### 7.1 URLs (Authentication → URL Configuration)
- **Site URL:** `https://<proyecto>.pages.dev` (o `https://beta.felix.cl` si conectas un dominio).
- **Redirect URLs:**
  - `https://<proyecto>.pages.dev/**`
  - `https://beta.felix.cl/**` (si usas dominio propio)
  - `cl.proyectofelix://login-callback` (Android e iOS)
- No agregues `http://localhost...` al proyecto de la nube.

> La app usa PKCE: después de confirmar el correo vuelve a `https://<origen>/?code=...`. Por eso el hosting debe servir la app **en la raíz** del dominio (`--base-href /`). Ver el paso 8.1.

### 7.2 Correo y contraseñas (Authentication → Providers → Email y Sign In / Providers)
- [ ] **Confirm email:** ON (obligatorio).
- [ ] **Secure email change:** ON.
- [ ] **Minimum password length:** 8, con minúsculas, mayúsculas y dígitos (igual que en local).
- [ ] **Leaked password protection** (HaveIBeenPwned): ON (es del plan Pro).
- [ ] **Allow anonymous sign-ins:** OFF. **Manual linking:** OFF.
- [ ] JWT expiry: 3600 s (por defecto).

### 7.3 SMTP propio (Authentication → Emails → SMTP Settings)

| Opción | Costo | Cuándo |
|---|---|---|
| **Resend Free** | $0 (3.000 al mes, **100 al día**) | Beta cerrada (menos de unos 80 registros al día) |
| **Resend Pro** | US$20 al mes (50.000 al mes) | Si se abren los 5.000 usuarios en pocas semanas |
| **Amazon SES** | ~US$0,10 por 1.000 | Lo más barato a escala. Hay que pedir salir del *sandbox* (1–2 días) |

Con 5.000 registros, cada uno con su correo de confirmación, Resend Free (100 al día) se agota si se registran más de unas 80 personas al día. Para la apertura usa **SES** o **Resend Pro**.

Configuración de Resend:
1. Resend → Domains → agrega `felix.cl` y crea en tu DNS los registros **SPF, DKIM y MX** que te indique.
2. Resend → API Keys → crea una con permiso *Sending access*, limitada a ese dominio.
3. En Supabase: host `smtp.resend.com`, puerto `465`, usuario `resend`, contraseña = la API key, remitente `no-responder@felix.cl`, nombre `Felix`.

**DMARC:** agrega `_dmarc.felix.cl TXT "v=DMARC1; p=none; rua=mailto:<tu correo>"`. Sin DMARC, Gmail manda los correos a spam.

### 7.4 Rate limits (Authentication → Rate Limits)

| Límite | Por defecto | Recomendado beta | Por qué |
|---|---|---|---|
| Emails enviados por hora (todo el proyecto) | 30 con SMTP propio | **100** (Resend Free) / **300** (SES o Resend Pro) | Que no pase el tope diario del proveedor |
| Registros e inicios de sesión (por IP, cada 5 min) | 30 | **100** | Las redes móviles chilenas usan CGNAT: muchas personas comparten IP |
| Token refresh y login (`/token`, por IP, cada 5 min) | 150 | **300** | Mismo motivo |
| Verificaciones OTP (por IP, cada 5 min) | 30 | 60 | Confirmaciones de correo desde la misma red |

> **`email_sent` es global** (todo el proyecto: confirmaciones, recuperaciones y cambios de correo). En `supabase/config.toml` vale `2`, el valor de desarrollo (con Mailpit no se aplica). En la nube con SMTP propio **súbelo en el dashboard** a 100 por hora (Resend Free, 100 al día → ~1 tanda por hora) o 300 (SES / Resend Pro). Con 2, el tercer correo de la hora deja a todos los usuarios sin confirmación ni recuperación. No lo cambies con `config push` (ver Paso 3).

Más adelante: captcha (Cloudflare Turnstile) en el registro. **Hoy no lo actives:** la app todavía no envía `captchaToken` y el registro dejaría de funcionar.

**Paso opcional · captcha en "Olvidé mi contraseña" (QA-F5-03).** GoTrue responde `429 over_email_send_rate_limit` solo a cuentas existentes que repiten el pedido, y tarda más con ellas. La app ya lo neutraliza (trata el 429 como éxito y responde en al menos 800 ms), pero un script contra la API aún podría enumerar correos. La mitigación completa es captcha: Supabase Auth admite **hCaptcha** y **Cloudflare Turnstile** (Authentication → Attack Protection). Requiere que la app envíe `captchaToken` en `resetPasswordForEmail`, `signUp` y `signInWithPassword`; actívalo solo cuando ese cambio esté publicado.

### 7.5 Plantillas en español (Authentication → Emails → Templates)
Copia cada HTML de `supabase/templates/` en su plantilla (son las mismas que usa el stack local):

| Plantilla | Asunto | Archivo |
|---|---|---|
| Confirm signup | Felix: confirma tu correo | `confirmation.html` |
| Invite user | Felix: te invitamos a la beta | `invite.html` |
| Magic link | Felix: tu enlace de acceso | `magic_link.html` |
| Change email address | Felix: confirma tu nuevo correo | `email_change.html` |
| Reset password | Felix: restablece tu contraseña | `recovery.html` |

### 7.6 Google OAuth (opcional)
1. Google Cloud Console → APIs & Services → Credentials → **OAuth client ID** de tipo *Web application*.
2. Authorized redirect URI: `https://<REF>.supabase.co/auth/v1/callback`.
3. Supabase → Authentication → Providers → **Google**: pega el Client ID y el Secret.
4. En el Environment de GitHub: `GOOGLE_AUTH_ENABLED=true` (variable). Si no, el botón queda oculto.

**Listo cuando:** te registras con un correo tuyo, el correo llega en español desde `no-responder@felix.cl` y el enlace te devuelve a la app con la sesión iniciada.

---

## Paso 8 · Web en Cloudflare Pages

### 8.1 Por qué Cloudflare Pages

| | GitHub Pages | **Cloudflare Pages** | Firebase Hosting (Spark) |
|---|---|---|---|
| Costo | Gratis | Gratis | Gratis |
| Ancho de banda | ~100 GB al mes (límite blando) | **Ilimitado** | **360 MB al día** (~10 GB al mes) |
| Ruta | `usuario.github.io/Proyecto_Felix/` (subcarpeta) salvo con dominio propio | Raíz: `felix-beta.pages.dev` | Raíz: `felix.web.app` |
| Cabeceras (`Cache-Control`, seguridad) | **No** se pueden configurar | Sí (`_headers`) | Sí (`firebase.json`) |
| Fallback SPA | Truco con `404.html` (responde con estado 404) | **Automático** (sin `404.html` en la raíz) | `rewrites` |
| Uso comercial | Desaconsejado por sus términos | Permitido | Permitido |
| Rollback | Re-ejecutar el deploy | **1 clic** | 1 clic |

**Elegido: Cloudflare Pages.**
- Es gratis sin tope de tráfico.
- Permite cabeceras propias.
- Sirve la app en la **raíz**. La redirección de Auth (`Uri.base.origin`) vuelve al origen *sin* la subcarpeta: en GitHub Pages la confirmación de correo caería en `usuario.github.io/` y fallaría.

Firebase queda como alternativa si se quiere todo en Google (ya se usa FCM), pero su ancho de banda gratis se agota con unos pocos miles de usuarios.

### 8.2 Crear el proyecto de Pages (una vez)

```powershell
npx --yes wrangler@3 login
npx --yes wrangler@3 pages project create felix-beta --production-branch main
```

- Cloudflare → My Profile → **API Tokens** → *Create Custom Token*, con permiso **Account → Cloudflare Pages → Edit** (solo esa cuenta). Guárdalo en el gestor.
- Anota el **Account ID** (aparece en el panel derecho del dashboard).
- Opcional: Pages → felix-beta → Custom domains → `beta.felix.cl`.

### 8.3 GitHub Environments (Settings → Environments)

En los **tres** Environments (`beta`, `production` y `backup`):
- **Deployment branches and tags → Selected branches → `master`.** Así un workflow modificado en otra rama no puede leer estos secretos.
- **Required reviewers:** tú.

**`beta`**
- Variables: `SUPABASE_URL=https://<REF>.supabase.co`, `SUPABASE_PROJECT_REF=<REF>`, `CLOUDFLARE_PAGES_PROJECT=felix-beta`, `MAP_PROVIDER=osm` y, opcional, `GOOGLE_AUTH_ENABLED=false`.
- Secretos:
  - `SUPABASE_PUBLISHABLE_KEY`;
  - `SUPABASE_ACCESS_TOKEN`: el token con alcance **solo** al proyecto de beta (paso 2);
  - `SUPABASE_DB_PASSWORD`;
  - `CLOUDFLARE_API_TOKEN` y `CLOUDFLARE_ACCOUNT_ID`;
  - opcional, `MAPS_API_KEY_WEB`.

**`production`**
- Lo mismo, con los valores y el token **del proyecto de producción**.

**`backup`**
- Ver el paso 11.

Por qué así (QA-23):
- Cada token de Supabase llega a **un solo** proyecto, así que un run de `beta` no puede tocar producción.
- La restricción de rama impide que una rama con un workflow alterado lea los secretos.
- El token de Cloudflare Pages tiene alcance de cuenta (Cloudflare no lo limita a un proyecto de Pages); lo protegen la restricción de rama y el revisor.
- Si quieres aislarlo del todo, usa una cuenta de Cloudflare distinta para producción.

### 8.4 Desplegar

GitHub → Actions → **Deploy Web (Cloudflare Pages)** → Run workflow:
- `environment`: `beta`;
- `confirm`: `DESPLEGAR beta` (o `DESPLEGAR production`). Si no coincide con el ambiente, el run **falla en rojo**.

El workflow:
1. corre `flutter analyze` y `flutter test`;
2. arma el archivo de entorno desde los secretos y lo valida con `tool/env/validar_env.mjs` (rechaza `sb_secret_`, JWT `service_role`, `http://` y hosts locales);
3. compila con `--base-href /`;
4. revisa que el build no tenga claves secretas ni la URL local `:54321`, y que no exista `404.html`;
5. sube `build/web` a Pages.

Cabeceras (`web/_headers`, que Flutter copia a `build/web`):
- Flutter Web **no pone hash** en `main.dart.js`, `flutter_bootstrap.js` ni `assets/`. Por eso todo va con `Cache-Control: no-cache`: el navegador revalida con ETag y recibe 304 si no cambió. Así un deploy nuevo nunca convive con un JS viejo.
- `canvaskit/`, `icons/` y `favicon.png`: 1 día.
- Seguridad: `nosniff`, `X-Frame-Options: DENY`, HSTS, `Referrer-Policy` y `Permissions-Policy` (geolocalización y cámara solo del propio sitio).
- **Content-Security-Policy**, por ahora en modo **`Content-Security-Policy-Report-Only`**: el navegador solo avisa en la consola y no bloquea nada. Qué permite:

  | Directiva | Permite | Para qué |
  |---|---|---|
  | `script-src` | `'self'`, `'wasm-unsafe-eval'`, `https://www.gstatic.com` y `https://maps.googleapis.com` | Flutter y CanvasKit/Skwasm (WASM desde gstatic) y el JS de Google Maps en Web |
  | `connect-src` | `https://*.supabase.co`, `wss://*.supabase.co`, `https://nominatim.openstreetmap.org`, tiles de OSM, Stadia y MapTiler, `https://*.googleapis.com`, `https://www.gstatic.com` y `https://fonts.gstatic.com` | API, Auth, Storage, Realtime, geocoding, tiles (Flutter los descarga con `fetch`) y la descarga de CanvasKit y fuentes |
  | `img-src` | `'self'`, `data:`, `blob:`, `https://*.supabase.co`, tiles de OSM, Stadia y MapTiler, y `*.googleapis.com`/`*.gstatic.com`/`*.google.com` | Documentos firmados, tiles y mapas |
  | `style-src` | `'self'`, `'unsafe-inline'` y `https://fonts.googleapis.com` | Flutter inyecta estilos en línea |
  | `font-src` | `'self'`, `data:` y `https://fonts.gstatic.com` | Fuentes de respaldo de Flutter |
  | `worker-src` | `'self'` y `blob:` | Service worker y workers de Skwasm |
  | `frame-ancestors` | `'none'` | Igual que `X-Frame-Options: DENY` |
  | `frame-src` | `https://www.google.com` | Iframes internos de Google Maps |
  | `object-src`, `base-uri`, `form-action` | `'none'`, `'self'` y `'self'` | Endurecimiento estándar |

  **Cómo pasarla a obligatoria:**
  1. Despliega en beta, abre la app en Chrome con DevTools → Console y recorre todos los flujos (login, registro, subir documento, mapas, admin).
  2. Si aparece `[Report Only] Refused to ...`, agrega ese origen a la directiva que corresponda en `web/_headers`.
  3. Cuando una sesión completa no muestre avisos, cambia el nombre de la cabecera de `Content-Security-Policy-Report-Only:` a `Content-Security-Policy:` y vuelve a desplegar.
  4. Con un dominio propio de Supabase (`api.felix.cl`), reemplaza `*.supabase.co` por ese dominio.
- Rutas: la app usa la estrategia de URL con `#` de go_router. Aunque se cambiara a rutas limpias, Pages ya sirve `index.html` para cualquier ruta (fallback SPA).

**Listo cuando:** `https://felix-beta.pages.dev` carga, te registras y recargar en cualquier pantalla no da 404.

---

## Paso 9 · Primer admin (por SQL)

1. Dashboard → Authentication → Users → **Add user** → *Create new user*: tu correo y una contraseña fuerte, con **Auto Confirm User** activado.
2. SQL Editor:

```sql
-- El admin nunca se autoasigna: solo por SQL (rol postgres, que salta la RLS).
insert into public.user_roles (user_id, role)
select id, 'admin' from auth.users where email = '<TU_CORREO>';

insert into public.terms_acceptances (user_id, version)
select id, public.current_legal_version('terms') from auth.users where email = '<TU_CORREO>';
insert into public.privacy_notice_views (user_id, version)
select id, public.current_legal_version('privacy') from auth.users where email = '<TU_CORREO>';
```

3. Activa **MFA** en tu cuenta de Supabase (Account → Security) y en GitHub.

**Listo cuando:** inicias sesión en la web y ves el panel de admin.

---

## Paso 10 · Prueba de humo en la nube (manual, con datos ficticios)

- [ ] Registro de un dueño con un correo tuyo (`+alias`). Llega el correo, lo confirmas y completas el perfil.
- [ ] Registro de un vet: subes un PDF de prueba (ficticio) y envías la solicitud.
- [ ] El admin ve la solicitud, abre el documento (URL firmada) y la aprueba.
- [ ] El dueño **no** ve datos del vet ni de otros dueños.
- [ ] Recargar en `/#/admin` mantiene la sesión.
- [ ] `SB db advisors --remote` sigue limpio.

---

## Paso 11 · Respaldos

| Capa | Qué | Costo | Cuándo |
|---|---|---|---|
| 1 | **Respaldo diario de Supabase Pro** (7 días) | Incluido | Desde el día 1 |
| 2 | **`pg_dump` semanal cifrado** (`db-backup.yml`) | $0 (Actions es gratis en repos públicos) | Desde el día 1 |
| 3 | **PITR** (7 días) | ~US$100 al mes y necesita cómputo Small o mayor | Cuando haya visitas y fichas reales (fase 6+) |

Activar la capa 2:
1. Instala `age` en tu PC: `winget install FiloSottile.age`.
2. `age-keygen -o felix-backup.key`. La línea `# public key: age1...` es la clave **pública**.
3. Guarda `felix-backup.key` **fuera del PC**: en el gestor de contraseñas y en un pendrive. **Si la pierdes, los respaldos no se pueden abrir.**
4. Dashboard → Connect → **Session pooler** (IPv4, puerto 5432): copia la cadena con la contraseña.
5. GitHub → Environment **`backup`**:
   - **Required reviewers:** tú;
   - **Deployment branches:** `master`;
   - secretos `SUPABASE_BACKUP_DB_URL` (esa cadena) y `BACKUP_AGE_RECIPIENT` (`age1...`).

   Con el revisor activado, el cron de cada domingo queda **esperando tu aprobación**: GitHub te avisa por correo y lo apruebas en Actions con un clic. Si no lo apruebas en 30 días, se cancela. Es el precio de que nadie pueda sacar la cadena de conexión (que trae la contraseña de `postgres`) sin pasar por ti.
6. GitHub → Settings → Variables (repo) → `BACKUP_ENABLED=true`.
7. Actions → **Respaldo semanal** → Run workflow una vez para probar.

Por qué está cifrado: el repo es **público** y cualquier persona con cuenta de GitHub puede bajar los artefactos. El runner solo tiene la clave pública, así que no puede descifrar. Los artefactos duran 90 días (unos 13 respaldos).

> GitHub desactiva los `schedule` tras 60 días sin actividad en el repo: revisa cada mes que el último respaldo exista.

**Simulacro de restauración (cada 3 meses), en un stack local AISLADO:**

```powershell
age -d -i felix-backup.key felix-backup-AAAAMMDD.tar.gz.age > respaldo.tar.gz
tar -xzf respaldo.tar.gz          # roles.sql, schema.sql, data.sql
# Stack aislado vacío (otro project_id y puertos 553xx, sin migraciones):
psql "<DB_URL_AISLADO>" -f roles.sql
psql "<DB_URL_AISLADO>" -f schema.sql
psql "<DB_URL_AISLADO>" -c "SET session_replication_role = replica" -f data.sql
```

Borra los `.sql` en texto plano al terminar.

---

## Paso 12 · Checklist de seguridad antes de abrir

- [ ] `SB db advisors --remote --level info`: sin hallazgos (o con su justificación anotada).
- [ ] `/security-review` de Claude Code sobre la rama a desplegar.
- [ ] `SB test db` en verde, incluida la **matriz pgTAP de la ficha** cuando exista (fase 6).
- [ ] CI en verde (`ci.yml`, incluido el job "Sin secretos en el repo").
- [ ] La Secret key y la `service_role` **no** están en ningún `.env` de la app ni en el build (lo revisa `web-deploy.yml`).
- [ ] Vault con `project_url` y `service_role_key`, y la purga responde 200 (paso 5).
- [ ] Confirmación de correo ON, SMTP propio, rate limits ajustados y plantillas en español.
- [ ] `TITLE_VERIFICATION_PROVIDER=off`.
- [ ] MFA en Supabase, Cloudflare, GitHub y el proveedor SMTP.
- [ ] Respaldos: hay al menos un artefacto `felix-backup-*` y se probó una restauración.
- [ ] **Legal:** la beta con personas reales trata datos personales (correo y teléfono). Antes de invitar: política de privacidad y términos publicados, y DPA con Supabase, Cloudflare y Resend/SES (Ley 21.719, vigente desde el 01-12-2026). Pide a los testers usar datos **ficticios** de mascotas.
- [ ] **Falta en la app:** "Olvidé mi contraseña" (no existe; la plantilla `recovery.html` ya está lista). Sin esto, quien olvide su clave depende del admin. Conviene tenerlo antes de abrir a 5.000 personas.

---

## Paso 13 · Rollback

**Web (instantáneo):** Cloudflare → Pages → felix-beta → Deployments → el anterior → **Rollback to this deployment**.

**Edge Functions:**

```powershell
git checkout <commit_bueno> -- supabase/functions
npx --yes supabase@3.2.0 functions deploy --use-api
git checkout HEAD -- supabase/functions
```

**Base de datos (las migraciones solo avanzan):**
1. **Antes de cada migración a producción:** corre el workflow **Respaldo semanal** a mano (`workflow_dispatch`).
2. Si una migración rompe algo **sin dañar datos**: escribe una migración nueva que lo revierta y pásala por el workflow. **Nunca** edites una migración ya aplicada.
3. Si **se dañaron datos**:
   - Dashboard → Database → Backups → restaurar el respaldo diario (pierdes lo posterior y hay minutos sin servicio);
   - con PITR, restaurar al minuto previo;
   - en último caso, el `pg_dump` semanal.
4. Para frenar el daño mientras decides: Authentication → Sign In / Providers → **Allow new users to sign up: OFF**.

---

## Paso 14 · Invitar testers

### Web (ahora)
- **Beta abierta por enlace (recomendado):** comparte `https://felix-beta.pages.dev`. Cada tester se registra y confirma su correo.
- **Invitación por correo:** Authentication → Users → **Invite user** (usa la plantilla `invite.html`). Ojo: el invitado entra sin contraseña y la app aún no tiene "crear/olvidé mi contraseña". Hasta que exista, usa la beta por enlace.
- Mensaje sugerido: qué probar, que usen **solo datos ficticios** de mascotas y un formulario para reportar fallas.
- Para frenar los registros: **Allow new users to sign up: OFF**.

### iOS · TestFlight (más adelante)
1. Apple Developer Program (US$99 al año). App Store Connect → crea la app con el bundle id `cl.proyectofelix.proyectoFelix` (Android: `cl.proyectofelix.proyecto_felix`).
2. `flutter build ipa --release --dart-define-from-file=.env.beta`. Sube el build con Transporter o Xcode. Necesita una Mac o un runner `macos` de Actions (10 veces más caro en minutos).
3. **Testers internos** (hasta 100, miembros del equipo): sin revisión de Apple.
4. **Testers externos** (hasta 10.000, por correo o **enlace público**): el primer build pasa por *Beta App Review* (~1 día).
5. Agrega en Supabase el redirect `cl.proyectofelix://login-callback` (ya está en la lista del paso 7.1).

### Android · Prueba cerrada de Google Play (más adelante)
1. Play Console (US$25, pago único). Si la cuenta es **personal**, Google exige **una prueba cerrada con al menos 12 testers durante 14 días seguidos** antes de pedir el acceso a producción.
2. `flutter build appbundle --release --dart-define-from-file=.env.beta`, con la firma en `key.properties` (ya está en `.gitignore`).
3. Testing → **Closed testing** → crea una pista y una lista de correos (Google Group o lista) con **12 o más** testers que **acepten la invitación** y mantengan la app instalada los 14 días.
4. Play App Signing: activado. Guarda la *upload key* en el gestor.
5. Completa la ficha: política de privacidad (URL pública), *Data safety* y clasificación de contenido.

---

## Entornos de la app (`--dart-define-from-file`)

| Ambiente | Archivo (no se versiona) | Comando |
|---|---|---|
| Local | `.env` | `flutter run -d chrome --dart-define-from-file=.env` |
| Beta | `.env.beta` | `node tool/env/validar_env.mjs .env.beta` (exige `*.supabase.co`; con dominio propio, antepone `FELIX_ALLOWED_API_HOSTS=api.tudominio.cl` y crea la variable del mismo nombre en el Environment de GitHub) y luego `flutter build web --release --base-href / --dart-define-from-file=.env.beta` |
| Producción | `.env.prod` | Igual, con `.env.prod` y `APP_ENV=production` |

- La plantilla es `env.example`. `.env` y `.env.*` están en `.gitignore`.
- La app lee **solo** `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `MAP_PROVIDER`, `MAPS_API_KEY` y `GOOGLE_AUTH_ENABLED` (`lib/core/config/env.dart`). No hay URLs de Supabase escritas en el código. La única URL local es la de Mailpit, en un aviso que solo aparece con backend local.
- En CI el archivo se genera desde los secretos del Environment y se borra después del build.

## Resumen: secretos y variables

| Nombre | Dónde | Tipo | Origen |
|---|---|---|---|
| `SUPABASE_URL` | Environment beta/production | Variable | Settings → API |
| `SUPABASE_PROJECT_REF` | Environment beta/production | Variable | Settings → General |
| `SUPABASE_PUBLISHABLE_KEY` | Environment beta/production | Secreto (es pública, pero así no queda en los logs) | Settings → API Keys |
| `SUPABASE_ACCESS_TOKEN` | Environment beta/production | Secreto | Token con alcance a ese proyecto (paso 2) |
| `SUPABASE_DB_PASSWORD` | Environment beta/production | Secreto | Paso 1 |
| `CLOUDFLARE_API_TOKEN` | Environment beta/production | Secreto | Paso 8.2 |
| `CLOUDFLARE_ACCOUNT_ID` | Environment beta/production | Secreto | Paso 8.2 |
| `CLOUDFLARE_PAGES_PROJECT` | Environment beta/production | Variable | `felix-beta` / `felix` |
| `MAP_PROVIDER`, `GOOGLE_AUTH_ENABLED` | Environment beta/production | Variable (opcional) | — |
| `MAPS_API_KEY_WEB` | Environment beta/production | Secreto (opcional) | Google Cloud, restringida al dominio |
| `SUPABASE_BACKUP_DB_URL` | Environment backup | Secreto | Connect → Session pooler |
| `BACKUP_AGE_RECIPIENT` | Environment backup | Secreto | `age-keygen` (clave pública) |
| `BACKUP_ENABLED` | Repo | Variable | `true` |
| `TITLE_VERIFICATION_PROVIDER` | Supabase secrets | Secreto de función | `off` |
| `project_url`, `service_role_key` | Supabase Vault | Secreto de BD | Paso 5 |
| Contraseña SMTP (API key de Resend o SES) | Supabase Auth → SMTP | — | Paso 7.3 |
