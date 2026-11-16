# SessionEnd: crea en el notebook una nota "Bitácora AAAA-MM-DD HH:MM" con los
# commits y archivos cambiados durante la sesión. Sin IA: solo git + notebooklm.
#
# Uso:
#   (hook)  bitacora.ps1            -> arma la nota y la sube en un proceso aparte
#                                      (SessionEnd tiene poco tiempo antes del cierre)
#   (manual) bitacora.ps1 -Sync     -> sube la nota y espera el resultado
#   (interno) bitacora.ps1 -Job <ruta.json>
param(
    [switch]$Sync,
    [string]$Job
)
$ErrorActionPreference = 'Continue'
$NB = 'f18b8953-2f68-4a1b-a4d9-d220afbbfa87'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$stateDir = Join-Path $root '.claude\state'
$logFile = Join-Path $stateDir 'bitacora.log'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

function Send-Nota([string]$Title, [string]$Content) {
    $out = $Content | & notebooklm note create --content - -t $Title -n $NB --json 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    $linea = "{0} {1} '{2}'" -f (Get-Date -Format 's'), ($(if ($ok) { 'OK' } else { 'ERROR' })), $Title
    Add-Content -Path $logFile -Value $linea -Encoding UTF8
    if (-not $ok) {
        Add-Content -Path $logFile -Value '  Fallo al crear la nota. Si es autenticación: notebooklm login' -Encoding UTF8
    }
    return @{ ok = $ok; out = ($out -join "`n") }
}

# --- Modo interno: subir un trabajo preparado ---
if ($Job) {
    try {
        $j = [IO.File]::ReadAllText($Job, $utf8) | ConvertFrom-Json
        Send-Nota $j.title $j.content | Out-Null
    } finally { Remove-Item -Force $Job -ErrorAction SilentlyContinue }
    exit 0
}

# --- Determinar el inicio de la sesión ---
$sessionId = 'manual'
try {
    if ([Console]::IsInputRedirected) {
        $raw = [Console]::In.ReadToEnd()
        if ($raw) { $j = $raw | ConvertFrom-Json; if ($j.session_id) { $sessionId = $j.session_id } }
    }
} catch { }
$startFile = Join-Path $stateDir "$sessionId.start"
if (Test-Path $startFile) {
    $inicio = [datetime]::Parse(([IO.File]::ReadAllText($startFile, $utf8)).Trim())
} else {
    $inicio = (Get-Date).Date   # sin registro: desde las 00:00 de hoy
}
$since = $inicio.ToString('yyyy-MM-ddTHH:mm:ss')

# --- Recolectar cambios con git ---
Push-Location $root
$tieneCommits = $false
& git rev-parse --verify HEAD 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { $tieneCommits = $true }
$commits = @(); $archivosCommit = @()
if ($tieneCommits) {
    $commits = @(& git log --since=$since --format='%h %ad %s' --date=format:'%H:%M' 2>$null)
    $archivosCommit = @(& git log --since=$since --name-only --format='' 2>$null | Where-Object { $_ } | Sort-Object -Unique)
}
$sinCommit = @(& git status --porcelain -uall 2>$null | Where-Object { $_ -notmatch '\.claude/state/' })
Pop-Location

$ahora = Get-Date
$titulo = 'Bitácora ' + $ahora.ToString('yyyy-MM-dd HH:mm')

if ($commits.Count -eq 0 -and $sinCommit.Count -eq 0) {
    Write-Output "[bitacora] Sin commits ni cambios desde $since; no se crea nota."
    Remove-Item -Force $startFile -ErrorAction SilentlyContinue
    exit 0
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# $titulo")
[void]$sb.AppendLine("Sesión desde $($inicio.ToString('yyyy-MM-dd HH:mm')) hasta $($ahora.ToString('HH:mm')).")
[void]$sb.AppendLine('')
[void]$sb.AppendLine("## Commits ($($commits.Count))")
if ($commits.Count) { $commits | ForEach-Object { [void]$sb.AppendLine("- $_") } } else { [void]$sb.AppendLine('- (ninguno)') }
[void]$sb.AppendLine('')
[void]$sb.AppendLine("## Archivos en commits ($($archivosCommit.Count))")
if ($archivosCommit.Count) { $archivosCommit | ForEach-Object { [void]$sb.AppendLine("- $_") } } else { [void]$sb.AppendLine('- (ninguno)') }
[void]$sb.AppendLine('')
[void]$sb.AppendLine("## Cambios sin commit ($($sinCommit.Count))")
if ($sinCommit.Count) { $sinCommit | ForEach-Object { [void]$sb.AppendLine("- $($_.Trim())") } } else { [void]$sb.AppendLine('- (ninguno)') }
$contenido = $sb.ToString()

Remove-Item -Force $startFile -ErrorAction SilentlyContinue

if ($Sync) {
    $r = Send-Nota $titulo $contenido
    Write-Output $contenido
    Write-Output $r.out
    exit 0
}

# Modo hook: delegar la subida a un proceso independiente y salir rápido.
$jobFile = Join-Path $stateDir ("bitacora-{0}.json" -f [guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllText($jobFile, (@{ title = $titulo; content = $contenido } | ConvertTo-Json -Compress), $utf8)
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Job', "`"$jobFile`""
) | Out-Null
Write-Output "[bitacora] Subiendo '$titulo' en segundo plano (ver .claude/state/bitacora.log)."
exit 0
