#requires -Version 7.0
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Layers the WinPEAP Autopilot solution onto a prepared OSDeployCore build box.
    Run in an elevated PowerShell 7 session - the OSDeploy V2 build tooling requires pwsh.

.DESCRIPTION
    Prerequisites (see docs/OSDCloud-V2.md): OSDCloud + OSDeploy + OSD modules installed, the
    Windows ADK installed, Update-OSDeployCoreDrivers run, and at least one stock build profile
    seeded (run Build-OSDeployBoot once and Cancel the profile picker to create 'OSDeploy.json').

    This script only adds the WinPEAP-specific pieces, using the documented customization surface:

        OSDRepo\winpe-startup-files\        config.json + OA3 tooling + baked script fallbacks
        OSDRepo\winpe-profiles\<name>.json  the WinPEStartup profile
        OSDRepo\build-profiles\amd64\<name>.json   seeded from the stock profile, WinPEStartupProfile overridden
        OSDRepo\Invoke-WinPEAPBuild.ps1     build + stage + package wrapper

    Then:  Invoke-WinPEAPBuild -BuildName <name> -Media USB

.EXAMPLE
    iwr https://raw.githubusercontent.com/blawalt/WinPEAP/main/Initialize-WinPEAP.ps1 -OutFile Initialize-WinPEAP.ps1
    .\Initialize-WinPEAP.ps1 -AuthMode DeviceCode

.EXAMPLE
    .\Initialize-WinPEAP.ps1 -AuthMode ClientSecret -TenantId <guid> -AppId <guid> -AppSecret <value> -BuildName AP
#>
[CmdletBinding()]
param(
    [string] $Repo         = 'blawalt/WinPEAP',   # your fork, if you forked
    [string] $Ref          = 'main',              # the branch/tag you pin your media to
    [string] $OSDeployRoot  = 'C:\ProgramData\OSDeployCore\OSDRepo',
    [string] $ProfileName   = 'Autopilot',
    [string] $BuildName     = 'AP',
    [ValidateSet('Fetch','Loader','Baked')]    [string] $ProfileStyle = 'Fetch',
    [ValidateSet('ClientSecret','DeviceCode')] [string] $AuthMode     = 'DeviceCode',
    [string] $SeedProfile,                        # build profile to seed AP.json from (default: OSDeploy.json)
    [string] $TimeZone,                           # override SetTimeZone in the build profile (else inherit the seed's)
    [switch] $NoWallpaper,                        # clear WinPECustomWallpaper in the build profile
    [string] $TenantId,
    [string] $AppId,
    [string] $AppSecret
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
$raw = "https://raw.githubusercontent.com/$Repo/$Ref"
function Say($m,$c='Gray'){ Write-Host $m -ForegroundColor $c }
function Fetch($name,$dest){ Invoke-WebRequest -UseBasicParsing "$raw/$name" -OutFile $dest }

Say "`n=== Initialize-WinPEAP  ($Repo@$Ref) ===`n" Cyan

# ---------- 1. preflight ----------
if (-not (Get-Command Build-OSDeployBoot -ErrorAction SilentlyContinue)) {
    throw "Build-OSDeployBoot not found. Install the OSDeploy module (Install-Module OSDeploy -AllowPrerelease)."
}
$pcp = 'C:\Windows\System32\PCPKsp.dll'
if (-not (Test-Path $pcp)) { throw "PCPKsp.dll not found in System32 on this build box." }
$adkOa3 = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Licensing\OA30\oa3tool.exe" -ErrorAction SilentlyContinue

$bpDir = Join-Path $OSDeployRoot 'build-profiles\amd64'
$seed  = if ($SeedProfile) {
    if (Test-Path $SeedProfile) { Get-Item $SeedProfile } else { Get-Item (Join-Path $bpDir $SeedProfile) }
} elseif (Test-Path (Join-Path $bpDir "$BuildName.json")) {
    Get-Item (Join-Path $bpDir "$BuildName.json")           # already have our own - reuse it as the base
} elseif (Test-Path (Join-Path $bpDir 'OSDeploy.json')) {
    Get-Item (Join-Path $bpDir 'OSDeploy.json')
} else {
    Get-ChildItem $bpDir -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $seed) {
    throw "No build profile found in $bpDir to seed from. Run 'Build-OSDeployBoot' once and press Cancel at the profile picker to create a stock profile, then re-run this."
}
Say "preflight OK  (seed profile: $($seed.Name))" Green

# ---------- 2. inputs ----------
if (-not $TenantId) { $TenantId = Read-Host 'Entra Tenant ID (guid)' }
if (-not $AppId)    { $AppId    = Read-Host 'App (client) ID (guid)' }
if ($AuthMode -eq 'ClientSecret' -and -not $AppSecret) {
    $AppSecret = Read-Host 'App client secret VALUE'
}

# ---------- 3. folders ----------
$profDir  = Join-Path $OSDeployRoot 'winpe-profiles'
$filesDir = Join-Path $OSDeployRoot 'winpe-startup-files'
$profDir,$filesDir,$bpDir | ForEach-Object { New-Item $_ -ItemType Directory -Force | Out-Null }

# ---------- 4. config.json ----------
$cfg = [ordered]@{ Repo = $Repo; Ref = $Ref; TenantId = $TenantId; AppId = $AppId; AuthMode = $AuthMode }
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
    catch { Say "WARN could not download $s (does $Repo@$Ref have it?)" Yellow }
}

# ---------- 7. startup profile ----------
switch ($ProfileStyle) {
    'Fetch'  { $cmd = "iwr -UseBasicParsing $raw/bootstrap.ps1 -OutFile X:\bootstrap-new.ps1 -EA SilentlyContinue; if (Test-Path X:\bootstrap-new.ps1) { & X:\bootstrap-new.ps1 } else { & X:\bootstrap.ps1 }; wpeutil reboot" }
    'Loader' { $cmd = "& X:\Startup.ps1" }
    'Baked'  { $cmd = "& X:\bootstrap.ps1; wpeutil reboot" }
}
[ordered]@{ InvokeMainCommand = @($cmd); InvokeMainCommandNoExit = $true } |
    ConvertTo-Json | Set-Content (Join-Path $profDir "$ProfileName.json") -Encoding UTF8
Say "winpe-profiles\$ProfileName.json  (style=$ProfileStyle)" Green

# ---------- 8. build profile (seed from stock so all required fields carry over) ----------
$o = Get-Content $seed.FullName -Raw | ConvertFrom-Json
$o | Add-Member NoteProperty WinPEStartupProfile (Join-Path $profDir "$ProfileName.json") -Force
if ($TimeZone)     { $o | Add-Member NoteProperty SetTimeZone $TimeZone -Force }
if ($NoWallpaper)  { $o | Add-Member NoteProperty WinPECustomWallpaper $null -Force }
$o | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $bpDir "$BuildName.json") -Encoding UTF8
Say "build-profiles\amd64\$BuildName.json  (seeded from $($seed.Name); WinPEStartupProfile -> $ProfileName.json)" Green

# ---------- 9. build wrapper ----------
try { Fetch 'Invoke-WinPEAPBuild.ps1' (Join-Path $OSDeployRoot 'Invoke-WinPEAPBuild.ps1') } catch {}

# ---------- 10. summary ----------
Say "`n=== Done ===" Cyan
Say "Wrote:" Cyan
Say "  $filesDir\   (config.json, oa3tool.exe, PCPKsp.dll, oa3.cfg, input.xml, *.ps1)"
Say "  $profDir\$ProfileName.json"
Say "  $bpDir\$BuildName.json"
Say "  $OSDeployRoot\Invoke-WinPEAPBuild.ps1"
Say ""
Say "Runtime source pinned to:  $Repo @ $Ref   (change with -Repo / -Ref, then rebuild)" Cyan
Say ""
Say "App registration checklist ($AuthMode):" Cyan
if ($AuthMode -eq 'ClientSecret') {
    Say "  - Graph API permission: DeviceManagementServiceConfig.ReadWrite.All  (Application) + admin consent"
    Say "  - client secret (its value is now in config.json on the media)"
} else {
    Say "  - Authentication > Allow public client flows = Yes  (device code is a public-client flow)"
    Say "  - Graph API permission: DeviceManagementServiceConfig.ReadWrite.All  (Delegated) + admin consent"
    Say "  - the tech who signs in needs an Intune RBAC role with the 'Enrollment programs' permission"
    Say "    (a scoped custom role is fine - not the Intune Administrator directory role)"
}
Say "`nNext:" Cyan
Say "  . $OSDeployRoot\Invoke-WinPEAPBuild.ps1"
Say "  Invoke-WinPEAPBuild -BuildName $BuildName -Media USB     # pick '$BuildName' at the profile picker"
Say ""
