#requires -Version 7.0
<#
    Invoke-WinPEAPBuild - build + stage + package in one call.
    Dot-source in an elevated PowerShell 7 session.

    Build-OSDeployBoot builds boot.wim AND the ISO in one pass - but it does that BEFORE
    this wrapper can stage WinPEStartup\Files, so the media has to be re-packed afterward.

    Flow:
        1. Build-OSDeployBoot          (GUI profile picker - select '<BuildName>')
        2. robocopy OSDRepo\winpe-startup-files -> boot\<...>\bootmedia\WinPEStartup\Files
        3. Update-OSDeployBootISO / -USB   (GUI folder picker - select the build folder,
           e.g. '26100.1-amd64-AP' - these cmdlets take no path parameter)

    Usage:
        . C:\ProgramData\OSDeployCore\OSDRepo\Invoke-WinPEAPBuild.ps1
        Invoke-WinPEAPBuild -BuildName AP -Media USB

    If Get-Help Build-OSDeployBoot -Full shows a non-interactive flag, pass it via
    -BuildArgs, e.g.  Invoke-WinPEAPBuild -BuildArgs @{ Auto = $true }
#>
function Invoke-WinPEAPBuild {
    [CmdletBinding()]
    param(
        [string] $BuildName    = 'AP',
        [string] $OSDeployRoot = 'C:\ProgramData\OSDeployCore\OSDRepo',
        [string] $BootRoot     = 'C:\ProgramData\OSDeployCore\boot',
        [ValidateSet('ISO','USB','Both','None')] [string] $Media = 'ISO',
        [hashtable] $BuildArgs = @{},   # extra args for Build-OSDeployBoot (e.g. @{ Auto = $true })
        [string]    $BootLabel,         # Update-OSDeployBootUSB -BootLabel
        [string]    $DataLabel          # Update-OSDeployBootUSB -DataLabel
    )
    $ErrorActionPreference = 'Stop'

    $src = Join-Path $OSDeployRoot 'winpe-startup-files'
    if (-not (Test-Path $src)) { throw "Startup-files source not found: $src  (run Initialize-WinPEAP.ps1 first)" }
    if (-not (Test-Path (Join-Path $OSDeployRoot "build-profiles\amd64\$BuildName.json"))) {
        throw "Build profile build-profiles\amd64\$BuildName.json not found (run Initialize-WinPEAP.ps1 first)"
    }

    Write-Host "Build-OSDeployBoot -Name $BuildName ..." -ForegroundColor Cyan
    Build-OSDeployBoot -Name $BuildName @BuildArgs

    $build = Get-ChildItem $BootRoot -Directory -ErrorAction Stop |
             Where-Object Name -like "*$BuildName*" |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $build) { throw "No build folder matching '*$BuildName*' under $BootRoot" }

    $dst = Join-Path $build.FullName 'bootmedia\WinPEStartup\Files'
    New-Item $dst -ItemType Directory -Force | Out-Null
    robocopy $src $dst /E /PURGE /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit code $LASTEXITCODE) copying '$src' -> '$dst'" }
    Write-Host "Staged startup files -> $($build.Name)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Build-OSDeployBoot made the ISO BEFORE the startup files were staged, so it must" -ForegroundColor Yellow
    Write-Host "be re-packed. Update-OSDeployBootISO/USB are GUI-only - SELECT '$($build.Name)'" -ForegroundColor Yellow
    Write-Host "in the folder picker." -ForegroundColor Yellow
    Write-Host ""

    $usb = @{}
    if ($BootLabel) { $usb.BootLabel = $BootLabel }
    if ($DataLabel) { $usb.DataLabel = $DataLabel }

    switch ($Media) {
        'ISO'  { Update-OSDeployBootISO }
        'USB'  { Update-OSDeployBootUSB @usb }
        'Both' { Update-OSDeployBootISO; Update-OSDeployBootUSB @usb }
    }

    Write-Host "Done: $($build.FullName)" -ForegroundColor Cyan
    if ($Media -in 'ISO','Both') { Write-Host "  ISO: $(Join-Path $build.FullName 'bootmedia.iso')" }
}
