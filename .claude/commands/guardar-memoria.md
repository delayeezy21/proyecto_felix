---
description: Actualiza la nota MEMORIA-PROYECTO en NotebookLM y sube SPEC.md / docs/arquitectura.md si cambiaron
---

Notebook de memoria: `f18b8953-2f68-4a1b-a4d9-d220afbbfa87` (en adelante NB).
Usa siempre `-n NB` y `--json`. Revisa `notebooklm <cmd> --help` si dudas de un flag.
Responde en español. Nunca escribas secretos, tokens ni datos personales reales en el notebook.

## 1. Actualizar MEMORIA-PROYECTO
1. `notebooklm auth check --test --json`: exige `status == "ok"` y `checks.token_fetch == true`. Si no, pide al usuario que ejecute `notebooklm login` y detente.
2. `notebooklm note list -n NB --json` → toma el `id` de la nota con título exacto `MEMORIA-PROYECTO`.
3. `notebooklm note get <id> -n NB --json` → lee `content`.
4. Reúne lo nuevo de esta sesión: decisiones tomadas, cambios de estado, pendientes nuevos o cerrados, riesgos (usa la conversación y `git log --oneline -20`).
5. Reescribe la nota:
   - Mantén las secciones: Objetivo, Decisiones, Estado actual, Pendientes, Riesgos.
   - Corta y sin duplicar: fusiona lo repetido, elimina pendientes cerrados, reemplaza el estado viejo (no lo acumules).
   - Decisiones con fecha `AAAA-MM-DD`.
   - **Máximo 60 líneas.** Si se pasa, resume las decisiones antiguas.
6. Escribe el contenido en un archivo temporal del scratchpad y guarda con:
   `notebooklm note save <id> -n NB --content "$(cat <archivo>)" --json`
7. Verifica con `note get` que el contenido quedó actualizado.

## 2. Subir documentos como fuentes (solo si cambiaron)
Para cada archivo existente entre `SPEC.md` y `docs/arquitectura.md`:
1. Calcula su hash: `git hash-object <archivo>`.
2. Compáralo con el guardado en `.claude/state/fuentes.json` (`{"SPEC.md": "<hash>", ...}`; si no existe, considera que cambió).
3. Si cambió:
   a. `notebooklm source list -n NB --json` → guarda los `id` de las fuentes cuyo título sea exactamente el nombre del archivo (`SPEC.md` o `arquitectura.md`).
   b. `notebooklm source add <archivo> --type file --title <nombre> -n NB --json` → guarda el `.source.id` nuevo.
   c. `notebooklm source wait <id_nuevo> -n NB --timeout 600` → exige salida 0 y estado `ready`.
   d. Solo después, borra las versiones anteriores: `notebooklm source delete <id_viejo> -n NB --yes --json` por cada id del paso (a).
   e. Actualiza el hash en `.claude/state/fuentes.json`.
4. Si no cambió, no hagas nada con ese archivo.

## 3. Resumen
Muestra al usuario en una tabla corta: nota actualizada (líneas antes y después), fuentes subidas o reemplazadas y fuentes sin cambios.
