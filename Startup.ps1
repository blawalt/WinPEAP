<#
    Startup.ps1 - optional thin WinPE launcher.

    Baked into WinPEStartup\Files (lands at X:\Startup.ps1). Its only job is to fetch the
    current bootstrap.ps1 from GitHub and run it, falling back to the baked copy if offline.
    Set $Ref once; this file otherwise never changes.

    Use this when your WinPEStartup profile JSON parser rejects a URL on the InvokeMainCommand
    line (some builds do). Otherwise the profile can fetch bootstrap.ps1 directly and this
    file is unnecessary - see hydrate.ps1 -ProfileStyle.
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'

$Ref = 'prod'
$bs  = 'X:\Windows\Temp\bootstrap.ps1'
$url = "https://raw.githubusercontent.com/blawalt/WinPEAP/$Ref/bootstrap.ps1"
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

& $bs -Ref $Ref

wpeutil reboot
