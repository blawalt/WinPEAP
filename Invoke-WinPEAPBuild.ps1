<#
    Invoke-WinPEAPBuild - build + stage + package in one call.

    Build-OSDeployBoot regenerates the boot\<name>\bootmedia tree on every run, so the
    WinPEStartup\Files content has to be re-staged from a canonical source afterwards.
    Initialize-WinPEAP.ps1 creates that source at OSDRepo\winpe-startup-files; this wrapper copies it
    into the freshly built media and then packages the ISO/USB.

    Usage:
        . C:\ProgramData\OSDeployCore\OSDRepo\Invoke-WinPEAPBuild.ps1
        Invoke-WinPEAPBuild -BuildName AP -Media USB
#>
function Invoke-WinPEAPBuild {
    [CmdletBinding()]
    param(
        [string] $BuildName    = 'AP',
        [string] $OSDeployRoot = 'C:\ProgramData\OSDeployCore\OSDRepo',
        [string] $BootRoot     = 'C:\ProgramData\OSDeployCore\boot',
        [ValidateSet('ISO','USB','Both','None')] [string] $Media = 'ISO'
    )
    $ErrorActionPreference = 'Stop'

    $src = Join-Path $OSDeployRoot 'winpe-startup-files'
    if (-not (Test-Path $src)) { throw "Startup-files source not found: $src  (run Initialize-WinPEAP.ps1 first)" }

    Write-Host "Build-OSDeployBoot -Name $BuildName ..." -ForegroundColor Cyan
    Build-OSDeployBoot -Name $BuildName

    $build = Get-ChildItem $BootRoot -Directory -ErrorAction Stop |
             Where-Object Name -like "*$BuildName*" |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $build) { throw "No build folder matching '*$BuildName*' under $BootRoot" }

    $dst = Join-Path $build.FullName 'bootmedia\WinPEStartup\Files'
    New-Item $dst -ItemType Directory -Force | Out-Null
    robocopy $src $dst /E /PURGE /NFL /NDL /NJH /NJS | Out-Null
    Write-Host "Staged startup files -> $($build.Name)" -ForegroundColor Green

    switch ($Media) {
        'ISO'  { Update-OSDeployBootISO -Name $build.Name }
        'USB'  { Update-OSDeployBootUSB -Name $build.Name }
        'Both' { Update-OSDeployBootISO -Name $build.Name; Update-OSDeployBootUSB -Name $build.Name }
    }

    Write-Host "Done: $($build.FullName)" -ForegroundColor Cyan
    if ($Media -in 'ISO','Both') { Write-Host "  ISO: $(Join-Path $build.FullName 'bootmedia.iso')" }
}
