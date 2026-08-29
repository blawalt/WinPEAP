#requires -RunAsAdministrator
<#
.SYNOPSIS
    Layers the WinPEAP Autopilot solution onto an existing OSDeployCore build box.

.DESCRIPTION
    Prerequisite: the build box is already prepared with Segura's Invoke-OSDeployHydration
    (installs the ADK, imports a Windows OS + WinRE, pulls WinPE drivers, proves a stock
    Build-OSDeployBoot works). This script only adds the WinPEAP-specific pieces on top,
    using the documented customization surface (build-profiles / winpe-profiles / WinPEStartup\Files):

        OSDRepo\winpe-startup-files\        config.json + OA3 tooling + baked script fallbacks
        OSDRepo\winpe-profiles\<name>.json  the WinPEStartup profile
        OSDRepo\build-profiles\amd64\<name>.json   (WinPEStartupProfile [+ WinPEDriver])
        OSDRepo\Invoke-WinPEAPBuild.ps1     build + stage + package wrapper

    Then:  Invoke-WinPEAPBuild -BuildName <name> -Media USB

.EXAMPLE
    iwr https://raw.githubusercontent.com/blawalt/WinPEAP/prod/Initialize-WinPEAP.ps1 -OutFile Initialize-WinPEAP.ps1
    .\Initialize-WinPEAP.ps1 -AuthMode DeviceCode

.EXAMPLE
    .\Initialize-WinPEAP.ps1 -AuthMode ClientSecret -TenantId <guid> -AppId <guid> -AppSecret <value> -BuildName AP
#>
[CmdletBinding()]
param(
    [string]   $Repo         = 'blawalt/WinPEAP',
    [string]   $Ref          = 'prod',
    [string]   $OSDeployRoot  = 'C:\ProgramData\OSDeployCore\OSDRepo',
    [string]   $ProfileName   = 'Autopilot',
    [string]   $BuildName     = 'AP',
    [ValidateSet('Fetch','Loader','Baked')]    [string]   $ProfileStyle = 'Fetch',
    [ValidateSet('ClientSecret','DeviceCode')] [string]   $AuthMode     = 'DeviceCode',
    [string[]] $WinPEDriver    = @('Dell','USB'),
    [switch]   $Drivers,          # off by default - Invoke-OSDeployHydration already pulled WinPE drivers
    [string]   $TenantId,
    [string]   $AppId,
    [string]   $AppSecret
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
$raw = "https://raw.githubusercontent.com/$Repo/$Ref"
function Say($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Fetch($name,$dest){ Invoke-WebRequest -UseBasicParsing "$raw/$name" -OutFile $dest }

Say "`n=== Initialize-WinPEAP  ($Repo@$Ref) ===`n" Cyan

# ---------- 1. preflight ----------
if (-not (Get-Command Build-OSDeployBoot -ErrorAction SilentlyContinue)) {
    throw "Build-OSDeployBoot not found. Prepare this build box first with Segura's Invoke-OSDeployHydration (https://www.osdeploy.com/osdeploy-guide/osdeploy-hydration)."
}
$bootRoot = Join-Path (Split-Path $OSDeployRoot -Parent) 'boot'
if (-not (Test-Path $bootRoot)) {
    Say "WARN: $bootRoot does not exist yet - run Invoke-OSDeployHydration if a stock build has never succeeded." Yellow
}
$pcp = 'C:\Windows\System32\PCPKsp.dll'
if (-not (Test-Path $pcp)) { throw "PCPKsp.dll not found in System32 on this build box." }
$adkOa3 = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Licensing\OA30\oa3tool.exe" -ErrorAction SilentlyContinue
if ($Drivers -and -not (Get-Command Save-WinPECloudDriver -ErrorAction SilentlyContinue)) {
    if ((Read-Host '-Drivers requested but the OSD module is missing. Install now? [Y/n]') -ne 'n') { Install-Module OSD -Force -Scope AllUsers }
    else { throw "OSD module required for -Drivers." }
}
Say "preflight OK" Green

# ---------- 2. inputs ----------
if (-not $TenantId) { $TenantId = Read-Host 'Entra Tenant ID (guid)' }
if (-not $AppId)    { $AppId    = Read-Host 'App (client) ID (guid)' }
if ($AuthMode -eq 'ClientSecret' -and -not $AppSecret) {
    $AppSecret = Read-Host 'App client secret VALUE'
}

# ---------- 3. folders ----------
$profDir  = Join-Path $OSDeployRoot 'winpe-profiles'
$filesDir = Join-Path $OSDeployRoot 'winpe-startup-files'
$drvDir   = Join-Path $OSDeployRoot 'winpe-drivers'
$bpDir    = Join-Path $OSDeployRoot 'build-profiles\amd64'
$profDir,$filesDir,$bpDir | ForEach-Object { New-Item $_ -ItemType Directory -Force | Out-Null }
if ($Drivers) { New-Item $drvDir -ItemType Directory -Force | Out-Null }

# ---------- 4. config.json ----------
$cfg = [ordered]@{ TenantId = $TenantId; AppId = $AppId; AuthMode = $AuthMode }
if ($AuthMode -eq 'ClientSecret') { $cfg.AppSecret = $AppSecret }
$cfg | ConvertTo-Json | Set-Content (Join-Path $filesDir 'config.json') -Encoding UTF8
Say "config.json written ($AuthMode$(if($AuthMode -eq 'DeviceCode'){' - no secret on media'}))" Green

# ---------- 5. OA3 tooling ----------
if ($adkOa3) { Copy-Item $adkOa3.FullName (Join-Path $filesDir 'oa3tool.exe') -Force; Say "oa3tool.exe from ADK" Green }
else         { Fetch 'oa3tool.exe' (Join-Path $filesDir 'oa3tool.exe');            Say "oa3tool.exe from repo (ADK copy not found)" Yellow }
Copy-Item $pcp (Join-Path $filesDir 'PCPKsp.dll') -Force
Fetch 'oa3.cfg'   (Join-Path $filesDir 'oa3.cfg')
Fetch 'input.xml' (Join-Path $filesDir 'input.xml')

# ---------- 6. scripts (baked fallback / primary in Baked+Loader) ----------
foreach ($s in 'bootstrap.ps1','4kAutopilotHashUpload.ps1','Startup.ps1') {
    try { Fetch $s (Join-Path $filesDir $s); Say "staged $s" Green }
    catch { Say "WARN could not download $s" Yellow }
}

# ---------- 7. startup profile ----------
switch ($ProfileStyle) {
    'Fetch'  { $cmd = "iwr -UseBasicParsing $raw/bootstrap.ps1 -OutFile X:\bootstrap-new.ps1 -EA SilentlyContinue; if (Test-Path X:\bootstrap-new.ps1) { & X:\bootstrap-new.ps1 -Ref $Ref } else { & X:\bootstrap.ps1 -Ref $Ref }; wpeutil reboot" }
    'Loader' { $cmd = "& X:\Startup.ps1" }
    'Baked'  { $cmd = "& X:\bootstrap.ps1 -Ref $Ref; wpeutil reboot" }
}
[ordered]@{ InvokeMainCommand = @($cmd); InvokeMainCommandNoExit = $true } |
    ConvertTo-Json | Set-Content (Join-Path $profDir "$ProfileName.json") -Encoding UTF8
Say "winpe-profiles\$ProfileName.json  (style=$ProfileStyle)" Green

# ---------- 8. build profile ----------
$bp = Join-Path $bpDir "$BuildName.json"
$o  = if (Test-Path $bp) { Get-Content $bp -Raw | ConvertFrom-Json } else { [pscustomobject]@{ Architecture = 'amd64' } }
$o | Add-Member NoteProperty WinPEStartupProfile (Join-Path $profDir "$ProfileName.json") -Force
if ($Drivers) { $o | Add-Member NoteProperty WinPEDriver $drvDir -Force }
$o | ConvertTo-Json -Depth 5 | Set-Content $bp -Encoding UTF8
Say "build-profiles\amd64\$BuildName.json upserted" Green

# ---------- 9. optional extra drivers ----------
if ($Drivers) {
    Say "Save-WinPECloudDriver -CloudDriver $($WinPEDriver -join ',') ..." Cyan
    Save-WinPECloudDriver -CloudDriver $WinPEDriver -Path $drvDir
}

# ---------- 10. build wrapper ----------
try { Fetch 'Invoke-WinPEAPBuild.ps1' (Join-Path $OSDeployRoot 'Invoke-WinPEAPBuild.ps1') } catch {}

# ---------- 11. summary ----------
Say "`n=== Done ===" Cyan
Say "App registration checklist ($AuthMode):" Cyan
if ($AuthMode -eq 'ClientSecret') {
    Say "  - Graph API permission: DeviceManagementServiceConfig.ReadWrite.All  (Application) + admin consent"
    Say "  - client secret (its value is now in config.json on the media)"
} else {
    Say "  - Authentication > Allow public client flows = Yes"
    Say "  - Graph API permission: DeviceManagementServiceConfig.ReadWrite.All  (Delegated) + admin consent"
    Say "  - the tech who signs in at microsoft.com/devicelogin needs the Intune Administrator role"
}
Say "`nNext:" Cyan
Say "  . $OSDeployRoot\Invoke-WinPEAPBuild.ps1"
Say "  Invoke-WinPEAPBuild -BuildName $BuildName -Media USB"
Say ""
