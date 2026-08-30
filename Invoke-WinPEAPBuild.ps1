#requires -Version 7.0
<#
    Invoke-WinPEAPBuild - build the WinPEAP boot media.
    Dot-source in an elevated PowerShell 7 session.

    Initialize-WinPEAP.ps1 wires the build profile's WinPEMediaScript to winpeap-media.ps1,
    which stages OSDRepo\winpe-startup-files into the media DURING the build - so
    Build-OSDeployBoot produces a correct ISO in one pass. This wrapper just runs the build,
    verifies the staging happened, and optionally writes a USB.

    Flow:
        1. Build-OSDeployBoot          (GUI profile picker - select '<BuildName>')
        2. verify bootmedia\WinPEStartup\Files\config.json landed
        3. -Media USB / Both -> Update-OSDeployBootUSB (GUI folder picker - select the build folder)

    Usage:
        . C:\ProgramData\OSDeployCore\OSDRepo\Invoke-WinPEAPBuild.ps1
        Invoke-WinPEAPBuild -BuildName AP -Media ISO

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

    if (-not (Test-Path (Join-Path $OSDeployRoot 'winpe-startup-files'))) {
        throw "OSDRepo\winpe-startup-files not found - run Initialize-WinPEAP.ps1 first"
    }
    if (-not (Test-Path (Join-Path $OSDeployRoot "build-profiles\amd64\$BuildName.json"))) {
        throw "Build profile build-profiles\amd64\$BuildName.json not found - run Initialize-WinPEAP.ps1 first"
    }

    Write-Host "Build-OSDeployBoot -Name $BuildName ...  (select '$BuildName' at the profile picker)" -ForegroundColor Cyan
    Build-OSDeployBoot -Name $BuildName @BuildArgs

    $build = Get-ChildItem $BootRoot -Directory -ErrorAction Stop |
             Where-Object Name -like "*$BuildName*" |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $build) { throw "No build folder matching '*$BuildName*' under $BootRoot" }

    $staged = Join-Path $build.FullName 'bootmedia\WinPEStartup\Files\config.json'
    if (-not (Test-Path $staged)) {
        throw "winpeap-media.ps1 did not stage the startup files ($staged missing). Check the build log / that the build profile's WinPEMediaScript points at $OSDeployRoot\winpeap-media.ps1"
    }
    Write-Host "Startup files staged into $($build.Name)" -ForegroundColor Green

    if ($Media -in 'USB','Both') {
        $usb = @{}
        if ($BootLabel) { $usb.BootLabel = $BootLabel }
        if ($DataLabel) { $usb.DataLabel = $DataLabel }
        Write-Host "Update-OSDeployBootUSB ...  (select '$($build.Name)' at the folder picker)" -ForegroundColor Yellow
        Update-OSDeployBootUSB @usb
    }

    Write-Host "Done: $($build.FullName)" -ForegroundColor Cyan
    Write-Host "  ISO: $(Join-Path $build.FullName 'bootmedia.iso')  (already includes the staged files)" -ForegroundColor Cyan
}
