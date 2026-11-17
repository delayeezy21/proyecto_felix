# Verificación automática del título de veterinarios

Fecha del análisis: 2026-11-17. Complementa `docs/arquitectura.md` §8.1 (verificación manual) y SPEC HU1.3–HU1.4.

**Conclusión:** COLMEVET no puede reemplazar la verificación del título. Sirve como **evidencia positiva opcional** (el chequeo opcional del admin). En Chile no hay una fuente oficial consultable por máquina que confirme un título sin pedir el RUT, así que se implementa una **verificación asistida**: la automatización precompleta parte del checklist y marca el riesgo, y el admin decide. No hay auto‑aprobación.

---

## 1. El buscador de COLMEVET

URL: `https://intranet.colegioveterinario.cl/publico/colegiados`. Solo inspeccioné la estructura: una petición a la página del listado y otra a `robots.txt`. **No hice búsquedas de personas ni abrí perfiles individuales.** Borré la copia local del HTML porque trae datos de terceros.

| Aspecto | Observación |
|---|---|
| Tecnología | App Rails en Heroku (`Server: Heroku`, cookie `_colmevet_new_session`, meta `csrf-token`). Pública, sin login. |
| Formulario | `GET /colegiados` con `type` (`<select>`: **Nombre**, **RCMV**, **RUT**) y `q` (texto, ej. "Juan Pérez"). |
| Listado | Tarjetas paginadas de 25 (unas 278 páginas, ~6.900 colegiados). Cada tarjeta trae una foto, el nombre (`<h6 class="text-primary">`), una línea de texto con forma `… (… - …)` y un botón "Ver Perfil" → `/publico/colegiados/{id}`. |
| Vigencia | El listado **no muestra ningún campo de vigencia ni de estado**. No verifiqué si el perfil individual la muestra: el entorno bloqueó, con razón, abrir el perfil de una persona real. |
| Captcha / límites | El HTML no tiene captcha (reCAPTCHA, hCaptcha ni Turnstile). No hay cabeceras de límite de tasa. El token CSRF no aplica a GET. |
| `robots.txt` | Es el de Rails por defecto: solo un comentario, sin `Disallow`. No lo prohíbe, pero **`robots.txt` no es una autorización**. |
| Términos de uso | La página no enlaza términos ni política de privacidad, y no encontré términos publicados para el buscador. |
| Hallazgo de privacidad | Los nombres de archivo de las fotos del listado público parecen contener RUT y nombres completos. Es una exposición del sitio de COLMEVET. **No lo usamos ni lo guardamos.** Avisarle a COLMEVET es decisión del usuario. |

## 2. Evaluación legal y de privacidad

1. **La colegiatura es voluntaria.** En Chile la afiliación a los colegios profesionales es voluntaria ([BCN, informe comparado de colegios profesionales](https://www.colegiomedico.cl/wp-content/uploads/2021/12/BCN_Informe-comparado_colegios-profesionales-2014_v3_compressed.pdf)). No aparecer en COLMEVET **no indica** falta de título. El resultado "no aparece" se trata como neutro: nunca sube el riesgo ni sugiere rechazar.
2. **Qué prueba COLMEVET.** Prueba que la persona está colegiada, lo que en su momento exigió un título. No prueba que el título esté vigente hoy ni que la cuenta pertenezca a esa persona: puede haber homónimos o suplantación. La identidad la sigue confirmando el admin con la cédula.
3. **Uso automatizado de un sitio de terceros.** No vamos a saltar ninguna barrera técnica: la Ley 21.459 de delitos informáticos sanciona el acceso indebido y la superación de barreras. Aun así, sin términos publicados ni un permiso explícito, consultar el sitio de forma automática y recurrente es un **riesgo reputacional y contractual**. **Recomendación:** pedir autorización o un convenio (API o archivo periódico) a COLMEVET antes de activar el proveedor real en producción.
4. **Ley 21.719 (vigente desde el 1-12-2026).**
   - Consultar COLMEVET con el nombre del vet le comunica ese nombre a un tercero. Hay que informarlo en la política de privacidad, con la finalidad "verificar habilitación profesional" y como base el contrato, a petición del propio vet.
   - La respuesta incluye datos de **otras personas** (homónimos). Se procesan solo en memoria y se descartan. Se guarda solo el resultado: coincide, no coincide, ambiguo o error, y la cantidad de coincidencias.
   - El resultado es una **decisión asistida, no automatizada**: siempre decide un admin humano (§8, "Decisiones automatizadas"). El vet puede ver sus resultados (derecho de acceso).
5. **RUT.** La búsqueda por RUT de COLMEVET (o los validadores de universidades y el Registro Civil) daría una coincidencia exacta, pero obliga a pedir y tratar el RUT del vet. Eso **choca con la decisión actual** (sin RUT, §8 Minimización). → **Decisión del usuario** (§5).

## 3. Otras opciones de validación automática en Chile

| Opción | ¿Existe? | ¿Automatizable? | Notas |
|---|---|---|---|
| **Registro Civil – "Certificado de profesionales"** | Sí. Las instituciones de educación superior informan cada mes los títulos otorgados ([ChileAtiende 13700](https://www.chileatiende.gob.cl/fichas/13700-certificado-de-profesionales)). Se obtiene en línea con ClaveÚnica y lleva Firma Electrónica Avanzada. | **No.** No hay API pública. El verificador web (`registrocivil.cl/OficinaInternet/verificacion/…`) pide **folio + código verificador**, carga por AJAX y el sitio tiene un WAF que rechazó peticiones automatizadas ("Request Rejected"). | **Es la mejor evidencia oficial para revisión manual**: el admin la valida en segundos con el folio y el código. El certificado muestra el RUN, pero no lo guardamos, igual que con la cédula. El costo no está confirmado. |
| Validadores de universidades | Sí, cada uno por separado. Ejemplo: U. de Chile, `validador.uchile.cl`, con código + RUT o pasaporte; diplomas electrónicos con QR desde octubre de 2023 ([uchile.cl/u225010](https://uchile.cl/u225010), [diplomas](https://uchile.cl/presentacion/prorrectoria/oficina-de-titulos-y-grados/diplomas)). | No de forma general: no hay una API común y piden el RUT. | Hay **QR falsos** que llevan a validadores falsos ([Fast Check / Derechos Digitales](https://www.derechosdigitales.org/wp-content/uploads/2025/08/¿Ingeniero-en-minutos__-asi-opera-la-maquinaria-que-vende-certificados-falsos-del-Duoc-UC-por-redes-sociales-—-Fast-Check-🔍.pdf)): hay que validar siempre en el dominio oficial. Mejora futura: comprobar que el enlace o QR del certificado apunte a un dominio oficial conocido. |
| Mineduc / SIES | SIES publica estadísticas, sin consulta individual. `registroprofesionales.mineduc.cl` es el registro de profesionales de **educación especial**, no de veterinarios. El portal de certificados de Mineduc es para instituciones **cerradas** ([ChileAtiende 4620](https://www.chileatiende.gob.cl/fichas/4620-certificados-de-titulo-y-notas-de-estudios-cursados-en-instituciones-de-educacion-superior-cerradas)). | No | No sirve para este caso. |
| Mineduc – portal de certificados (`https://certificados.mineduc.cl/mvc/home/index`, consultado el 17-11-2026, sin enviar formularios) | Sí, pero solo para registros **escolares**: licencias de Educación Media, certificados anuales de estudios, títulos Técnico Profesionales de nivel **medio**, validaciones y equivalencias, y certificados de alumno prioritario. No incluye títulos de educación superior. | **No.** Pide RUN + fecha de nacimiento + número de serie de la cédula + **reCAPTCHA**. No tiene validación para terceros por folio o código, ni API, ni términos publicados (`robots.txt` → 404). | **Descartado**: no certifica el título de Médico Veterinario. Usarlo exigiría pedirle al vet su RUN, su fecha de nacimiento y la serie de su cédula (más datos de los que hoy guardamos, contra la minimización de la Ley 21.719) y resolver un reCAPTCHA, algo que no se debe intentar. |
| Superintendencia de Salud (Registro de Prestadores Individuales) | Sí, pero solo para profesiones de salud humana | — | No incluye a los veterinarios (§8.1). |
| SAG | Tiene registros de veterinarios acreditados para programas específicos | No verificado | Cubre solo un subconjunto. No lo uso porque no confirmé su alcance ni si es consultable. |
| Proveedores comerciales (ej. [Verifik](https://docs.verifik.co/background-check/chile-certificate-verify/)) | Verifican certificados del Registro Civil por folio + código | Sí, pagando | Lo documentado es el **certificado de antecedentes**: no confirmé el de profesionales. Implica una transferencia internacional y un DPA. Queda como opción futura. |
| Convenio con COLMEVET | Habría que negociarlo | Sí | Es la vía limpia para automatizar el chequeo opcional. |
| ClaveÚnica como identidad | Existe | — | Según entiendo, solo la pueden integrar organismos públicos (a confirmar). |

## 4. Diseño recomendado: verificación asistida

- **Reglas internas** (sin terceros, siempre activas):
  - La universidad está en la lista inicial de escuelas de Medicina Veterinaria reconocidas → **sugiere** el chequeo "universidad reconocida".
  - Título extranjero o año fuera de rango → riesgo **alto**. Universidad fuera de la lista o sin código de verificación → riesgo **medio**.
  - La lista es inicial y **debe validarla el usuario contra CNA/Mineduc**. Una universidad fuera de la lista no es un rechazo, solo que el admin la revise.
- **Proveedor COLMEVET** (apagado por defecto):
  - Busca por nombre. Una coincidencia exacta y única → **sugiere** el chequeo opcional COLMEVET. "Sin coincidencias" y "ambiguo" son neutros.
  - Nunca marca "el nombre coincide con la cédula" ni "verifiqué el certificado con la universidad": esos dos los hace siempre el admin.
- **Sin auto‑aprobación:** ninguna fuente disponible es oficial, consultable por máquina y concluyente. El diseño deja preparado el punto de extensión: un proveedor futuro con convenio (Registro Civil, universidad o COLMEVET) podría marcar `authoritative`, y entonces se evaluaría la auto‑aprobación.
- **Robustez:**
  - Todo corre en la Edge Function `verify-vet-title`, nunca en el cliente, con un timeout de 8 s y un tope de 1 MB por respuesta.
  - Límite de tasa: 3 ejecuciones por vet cada 10 min y 20 consultas a COLMEVET por minuto en todo el sistema.
  - Si falla o está apagada, la revisión manual funciona igual que hoy.
- **Recomendación adicional** (manual, alto valor y bajo costo): pedir el "Certificado de profesionales" del Registro Civil como documento preferente y que el admin lo valide con folio + código. Agregarlo es decisión del usuario.

## 5. Decisiones del usuario

1. **Activar el proveedor COLMEVET en producción** (`TITLE_VERIFICATION_PROVIDER=colmevet`). Se recomienda pedir autorización o un convenio a COLMEVET y actualizar la política de privacidad antes.
2. **¿Pedir RUT?** Permitiría coincidencias exactas (COLMEVET por RUT, validadores de universidades), pero revierte la decisión de minimización. Además, ninguna fuente revisada lo aprovecharía de forma automática y legítima: el portal de certificados Mineduc no cubre títulos universitarios y tiene reCAPTCHA, y el Registro Civil no tiene API y bloquea los clientes automáticos. La recomendación es **no pedirlo** mientras no haya una fuente oficial con convenio que lo justifique.
3. **Certificado del Registro Civil** como documento preferente u obligatorio.
4. **Validar la lista de universidades** de `supabase/functions/verify-vet-title/rules.ts`.
5. **Avisar a COLMEVET** de la posible exposición de RUT en los nombres de archivo de las fotos.

## 6. Implementación (resumen)

- Migración `title_verifications`:
  - Tabla `public.vet_title_verifications`, de solo inserción, con RLS forzada. El vet lee las suyas y el admin todas. Solo `service_role` inserta y nadie borra.
  - Evidencia mínima: `matches` y estado HTTP, sin nombres ni RUT.
  - Cuota `title_verification_quota` (solo `service_role`).
- Edge Function `verify-vet-title`:
  - Interfaz `TitleVerificationProvider` (`providers.ts`), con las implementaciones `RulesProvider`, `ColmevetProvider` y `FakeProvider`.
  - Configuración por `TITLE_VERIFICATION_PROVIDER` = `off` (por defecto) | `fake` | `colmevet`.
  - Autorización: el admin puede verificar cualquier solicitud en revisión y el vet solo la suya.
- App:
  - Al enviar la solicitud se dispara la verificación en segundo plano; si falla, se ignora.
  - La revisión del admin muestra los resultados (fuente, fecha, resultado y riesgo), precompleta los chequeos sugeridos (el admin puede desmarcarlos), deja una línea de resumen en las notas y tiene el botón "Ejecutar verificación".
- Pruebas:
  - pgTAP `060_title_verifications.test.sql`.
  - Unitarias de los adaptadores con `node --test`, con HTML sintético y sin red.
  - Widget tests de la revisión.
  - E2E por API (`tool/e2e/verificacion_e2e.mjs`) con el proveedor falso.
