<#
.SYNOPSIS
  Abre (o cierra) en el firewall de Windows los puertos para probar Felix
  desde el celular, SOLO para equipos de la misma red local.

.EXAMPLE
  # Abrir (pide permisos de administrador):
  powershell -ExecutionPolicy Bypass -File tool\firewall_lan.ps1
  # Cerrar cuando termines:
  powershell -ExecutionPolicy Bypass -File tool\firewall_lan.ps1 -Cerrar
#>
param([switch]$Cerrar, [int[]]$Puertos = @(8080, 54321))
$nombre = 'Felix - pruebas en red local'

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
  $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
  if ($Cerrar) { $argsList += '-Cerrar' }
  Start-Process powershell -Verb RunAs -ArgumentList $argsList -Wait
  exit
}

Get-NetFirewallRule -DisplayName $nombre -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($Cerrar) {
  Write-Host 'Regla eliminada. Puertos cerrados.'
} else {
  New-NetFirewallRule -DisplayName $nombre -Direction Inbound -Protocol TCP `
    -LocalPort $Puertos -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null
  Write-Host "Puertos $($Puertos -join ', ') abiertos solo para la red local."
}
Start-Sleep -Seconds 2
