# SessionStart: imprime la nota MEMORIA-PROYECTO del notebook de memoria.
# Su salida estándar se inyecta como contexto de la sesión. Nunca imprime credenciales.
$ErrorActionPreference = 'Continue'
$NB = 'f18b8953-2f68-4a1b-a4d9-d220afbbfa87'
$TITULO_NOTA = 'MEMORIA-PROYECTO'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$stateDir = Join-Path $root '.claude\state'

function Invoke-Nlm([string[]]$NlmArgs) {
    $out = & notebooklm @NlmArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $txt = ($out -join "`n")
    $i = $txt.IndexOf('{')
    if ($i -lt 0) { return $null }
    try { return ($txt.Substring($i) | ConvertFrom-Json) } catch { return $null }
}

# 1) Registrar el inicio de la sesión (lo usa bitacora.ps1 en SessionEnd).
$sessionId = 'manual'
try {
    if ([Console]::IsInputRedirected) {
        $raw = [Console]::In.ReadToEnd()
        if ($raw) { $j = $raw | ConvertFrom-Json; if ($j.session_id) { $sessionId = $j.session_id } }
    }
} catch { }
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$startFile = Join-Path $stateDir "$sessionId.start"
# Solo la primera vez: SessionStart se repite en resume/clear/compact con el mismo id.
if (-not (Test-Path $startFile)) {
    [IO.File]::WriteAllText($startFile, (Get-Date).ToString('o'), $utf8)
    # Foto de los cambios sin commit al inicio, para que la bitácora solo cuente lo nuevo.
    Push-Location $root
    $foto = @(& git status --porcelain -uall 2>$null | Where-Object { $_ -notmatch '\.claude/state/' })
    Pop-Location
    [IO.File]::WriteAllLines((Join-Path $stateDir "$sessionId.status"), [string[]]$foto, $utf8)
}

# 2) Verificar autenticación real.
$auth = Invoke-Nlm @('auth', 'check', '--test', '--json')
if (-not $auth -or $auth.status -ne 'ok' -or -not $auth.checks.token_fetch) {
    Write-Output '[memoria] AVISO: la sesión de NotebookLM no es válida. Ejecuta "notebooklm login" y reinicia la sesión.'
    exit 0
}

# 3) Buscar y leer la nota.
$lista = Invoke-Nlm @('note', 'list', '-n', $NB, '--json')
$notaInfo = $null
if ($lista) { $notaInfo = $lista.notes | Where-Object { $_.title -eq $TITULO_NOTA } | Select-Object -First 1 }
if (-not $notaInfo) {
    Write-Output "[memoria] AVISO: no se encontró la nota $TITULO_NOTA en el notebook $NB."
    exit 0
}
$det = Invoke-Nlm @('note', 'get', $notaInfo.id, '-n', $NB, '--json')
if (-not $det) {
    Write-Output "[memoria] AVISO: no se pudo leer la nota $TITULO_NOTA."
    exit 0
}

Write-Output "=== Memoria del proyecto (NotebookLM $NB, nota $TITULO_NOTA) ==="
Write-Output $det.content
exit 0
