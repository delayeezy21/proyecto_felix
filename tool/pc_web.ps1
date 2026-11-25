<#
.SYNOPSIS
  Ejecuta Felix en Chrome del PC (http://localhost:3000) contra Supabase local,
  con el login de Google habilitado si así está en supabase/config.toml.

.DESCRIPTION
  No necesita el archivo .env de la app: lee la clave publicable desde
  `supabase status`. Google solo funciona en el PC (localhost); Google no
  acepta direcciones de red local como las del iPhone.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tool\pc_web.ps1
#>
param(
  [int]$Port = 3000,
  # Centro inicial de los mapas (beta local: San Miguel, Santiago).
  [string]$MapCenter = '-33.4970,-70.6510'
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$env:Path += ';C:\Program Files\Docker\Docker\resources\bin'

$raw = (& npx --yes supabase@3.2.0 status -o json 2>$null) -join "`n"
$i = $raw.IndexOf('{')
if ($i -lt 0) { throw 'Supabase local no está corriendo. Ejecuta: npx --yes supabase@3.2.0 start' }
$status = $raw.Substring($i) | ConvertFrom-Json

# Google habilitado = bloque [auth.external.google] con enabled = true.
$toml = Get-Content supabase\config.toml -Raw
$google = $toml -match '(?ms)^\[auth\.external\.google\]\s*\r?\nenabled\s*=\s*true'
Write-Host "Login con Google: $(if ($google) { 'habilitado' } else { 'deshabilitado' })" -ForegroundColor Cyan
Write-Host "Abriendo Chrome en http://localhost:$Port ..." -ForegroundColor Cyan

& flutter run -d chrome --web-port $Port `
  '--dart-define=SUPABASE_URL=http://127.0.0.1:54321' `
  "--dart-define=SUPABASE_PUBLISHABLE_KEY=$($status.PUBLISHABLE_KEY)" `
  '--dart-define=MAP_PROVIDER=osm' `
  "--dart-define=MAP_DEFAULT_CENTER=$MapCenter" `
  "--dart-define=GOOGLE_AUTH_ENABLED=$($google.ToString().ToLower())"
