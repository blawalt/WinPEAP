<#
    Startup.ps1 - optional thin WinPE launcher.

    Baked into WinPEStartup\Files (lands at X:\Startup.ps1). Reads Repo + Ref from
    X:\config.json, fetches the current bootstrap.ps1 and runs it, falling back to the
    baked copy if GitHub is unreachable. This file otherwise never changes.

    Used only with  Initialize-WinPEAP.ps1 -ProfileStyle Loader  (when a build's
    WinPEStartup JSON parser rejects a URL on the InvokeMainCommand line).
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'

if (-not (Test-Path 'X:\config.json')) { Write-Warning 'X:\config.json is missing from the boot media.'; Start-Sleep 120; exit 1 }
$cfg  = Get-Content 'X:\config.json' -Raw | ConvertFrom-Json
$repo = if ($cfg.Repo) { $cfg.Repo } else { 'blawalt/WinPEAP' }
$ref  = if ($cfg.Ref)  { $cfg.Ref }  else { 'main' }

$bs  = 'X:\Windows\Temp\bootstrap.ps1'
$url = "https://raw.githubusercontent.com/$repo/$ref/bootstrap.ps1"
$ok  = $false

for ($i = 1; $i -le 5 -and -not $ok; $i++) {
    try { Invoke-WebRequest -UseBasicParsing $url -OutFile $bs; $ok = $true }
    catch { Write-Warning "fetch $i failed: $_"; Start-Sleep 10 }
}
if (-not $ok -and (Test-Path 'X:\bootstrap.ps1')) {
    Copy-Item 'X:\bootstrap.ps1' $bs -Force; $ok = $true
    Write-Warning 'GitHub unreachable - using baked X:\bootstrap.ps1'
}
if (-not $ok) { Write-Warning 'No bootstrap.ps1 available.'; Start-Sleep 120; exit 1 }

& $bs

wpeutil reboot
