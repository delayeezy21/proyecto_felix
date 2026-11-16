# Felix

Marketplace de veterinarios a domicilio (Flutter + Supabase). Proyecto de portafolio con pagos simulados.

- Requisitos: [SPEC.md](SPEC.md)
- Arquitectura y plan por fases: [docs/arquitectura.md](docs/arquitectura.md)

## Requisitos de desarrollo

- Flutter 3.47.x (Android, Web, Windows; iOS requiere un Mac)
- Windows: **Modo de desarrollador** activado (`start ms-settings:developers`) para compilar plugins
- Docker Desktop (para Supabase local y los tests pgTAP)
- Supabase CLI 3.2.0: `npx --yes supabase@3.2.0 <comando>`

## Puesta en marcha

```bash
cp env.example .env            # completa los valores; .env no se versiona
npx --yes supabase@3.2.0 start # levanta Supabase local (Docker)
flutter run -d windows --dart-define-from-file=.env   # o -d chrome / -d <android>
```

## Pruebas

```bash
flutter analyze
flutter test
npx --yes supabase@3.2.0 test db   # pgTAP (requiere Docker)
```

## Probar en iPhone (sin Mac)

La app nativa de iOS necesita un Mac para compilarse. Mientras tanto se prueba la
**versión web en Safari**, en la misma red Wi-Fi que el PC:

```powershell
powershell -ExecutionPolicy Bypass -File tool\firewall_lan.ps1   # una vez (pide admin)
powershell -ExecutionPolicy Bypass -File tool\iphone_web.ps1     # compila y sirve
# al terminar:
powershell -ExecutionPolicy Bypass -File tool\firewall_lan.ps1 -Cerrar
```
