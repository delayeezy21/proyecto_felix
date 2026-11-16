<#
.SYNOPSIS
  Sirve la app web de Felix en la red local para probarla desde un iPhone (Safari).

.DESCRIPTION
  1. Detecta la IP de este PC en la red local.
  2. Lee la clave publicable de Supabase local (`supabase status`).
  3. Compila la app web apuntando a http://<IP>:54321.
  4. Crea (si no existe) un usuario de prueba ya confirmado.
  5. Sirve build/web en http://<IP>:<Port>.

  Requisitos: Docker Desktop corriendo y `npx --yes supabase@3.2.0 start` hecho.
  Solo para desarrollo local: usa las claves de demostración de Supabase local.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tool\iphone_web.ps1
#>
param(
  [int]$Port = 8080,
  [string]$Ip = '',
  [string]$DemoEmail = 'demo@felix.local',
  [string]$DemoPassword = 'Felix2026'
)
# Continue: en PowerShell 5.1, la salida stderr de comandos nativos (npx, flutter)
# se convierte en excepción con 'Stop'. Los errores se validan a mano con throw.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$env:Path += ';C:\Program Files\Docker\Docker\resources\bin'

function Paso($n, $texto) { Write-Host "`n[$n/5] $texto" -ForegroundColor Cyan }

Paso 1 'Buscando la IP de este PC en la red local...'
if (-not $Ip) {
  $Ip = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
      $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254*' -and
      $_.InterfaceAlias -notmatch 'vEthernet|WSL|Docker|Loopback|VirtualBox|VMware'
    } | Select-Object -First 1).IPAddress
}
if (-not $Ip) { throw 'No encontré la IP local. Pásala con -Ip 192.168.x.x' }
Write-Host "   IP: $Ip"

Paso 2 'Leyendo la configuración de Supabase local...'
$raw = (& npx --yes supabase@3.2.0 status -o json 2>$null) -join "`n"
$jsonStart = $raw.IndexOf('{')
if ($jsonStart -lt 0) { throw 'Supabase local no está corriendo. Ejecuta: npx --yes supabase@3.2.0 start' }
$status = $raw.Substring($jsonStart) | ConvertFrom-Json
if (-not $status.PUBLISHABLE_KEY) { throw 'Supabase local no está completo. Ejecuta: npx --yes supabase@3.2.0 start' }
$apiUrl = "http://${Ip}:54321"
Write-Host "   API: $apiUrl"

Paso 3 'Compilando la app web (tarda ~1-2 min)...'
& flutter build web --release `
  "--dart-define=SUPABASE_URL=$apiUrl" `
  "--dart-define=SUPABASE_PUBLISHABLE_KEY=$($status.PUBLISHABLE_KEY)" `
  '--dart-define=MAP_PROVIDER=osm'
if ($LASTEXITCODE -ne 0) { throw 'Falló la compilación web.' }

Paso 4 "Creando el usuario de prueba $DemoEmail (si no existe)..."
$headers = @{ apikey = $status.SERVICE_ROLE_KEY; Authorization = "Bearer $($status.SERVICE_ROLE_KEY)" }
$body = @{ email = $DemoEmail; password = $DemoPassword; email_confirm = $true } | ConvertTo-Json
try {
  Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:54321/auth/v1/admin/users" `
    -Headers $headers -ContentType 'application/json' -Body $body -ErrorAction Stop | Out-Null
  Write-Host '   Usuario creado.'
} catch {
  if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 422) {
    Write-Host '   Ya existía. OK.'
  } else { throw }
}

Paso 5 'Sirviendo la app. Deja esta ventana abierta mientras pruebas.'
Write-Host ''
Write-Host '   ==============================================' -ForegroundColor Green
Write-Host "   En el iPhone abre Safari y entra a:"           -ForegroundColor Green
Write-Host "   http://${Ip}:$Port"                             -ForegroundColor Yellow
Write-Host "   Usuario: $DemoEmail   Clave: $DemoPassword"     -ForegroundColor Green
Write-Host "   Correos de confirmación (en el PC): http://127.0.0.1:54324" -ForegroundColor Green
Write-Host '   Para detener: Ctrl + C'                         -ForegroundColor Green
Write-Host '   ==============================================' -ForegroundColor Green
& npx --yes http-server@14.1.1 build/web -p $Port -a 0.0.0.0 -c-1 --silent
