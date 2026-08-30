#requires -Version 7.0
<#
    Invoke-WinPEAPBuild - build + stage + package in one call.
    Dot-source in an elevated PowerShell 7 session.

    Build-OSDeployBoot regenerates the boot\<name>\bootmedia tree on every run, so the
    WinPEStartup\Files content has to be re-staged from a canonical source afterwards.
    Initialize-WinPEAP.ps1 creates that source at OSDRepo\winpe-startup-files; this wrapper copies it
    into the freshly built media and then packages the ISO/USB.

    Usage:
        . C:\ProgramData\OSDeployCore\OSDRepo\Invoke-WinPEAPBuild.ps1
        Invoke-WinPEAPBuild -BuildName AP -Media USB

    Build-OSDeployBoot shows a GUI profile picker unless you give it a non-interactive
    argument (check: Get-Help Build-OSDeployBoot -Full). Pass whatever that turns out to be
    via -BuildArgs, e.g.  Invoke-WinPEAPBuild -BuildArgs @{ Auto = $true }
    Otherwise just select the '<BuildName>' profile when the picker appears.
#>
function Invoke-WinPEAPBuild {
    [CmdletBinding()]
    param(
        [string] $BuildName    = 'AP',
        [string] $OSDeployRoot = 'C:\ProgramData\OSDeployCore\OSDRepo',
        [string] $BootRoot     = 'C:\ProgramData\OSDeployCore\boot',
        [ValidateSet('ISO','USB','Both','None')] [string] $Media = 'ISO',
        [hashtable] $BuildArgs  = @{},   # extra args for Build-OSDeployBoot (e.g. @{ Auto = $true })
        [hashtable] $UpdateArgs = @{}    # extra args for Update-OSDeployBootISO/USB (e.g. a path/name param)
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
    Write-Host "Re-packing media (Build-OSDeployBoot made the ISO BEFORE the files were staged)..." -ForegroundColor Yellow
    Write-Host "  If a folder picker appears, select: $($build.Name)" -ForegroundColor Yellow

    switch ($Media) {
        'ISO'  { Update-OSDeployBootISO @UpdateArgs }
        'USB'  { Update-OSDeployBootUSB @UpdateArgs }
        'Both' { Update-OSDeployBootISO @UpdateArgs; Update-OSDeployBootUSB @UpdateArgs }
    }

    Write-Host "Done: $($build.FullName)" -ForegroundColor Cyan
    if ($Media -in 'ISO','Both') { Write-Host "  ISO: $(Join-Path $build.FullName 'bootmedia.iso')" }
}
