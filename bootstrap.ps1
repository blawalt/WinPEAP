<#
    bootstrap.ps1 - WinPEAP runtime orchestrator (OSDCloud V2).

    Called by the WinPEStartup profile (directly, or via Startup.ps1). Reads X:\config.json
    for tenant / app / auth settings, prompts the operator for a Group Tag, then:
      1. runs the Autopilot 4k hash upload
      2. runs the OSDCloud V2 workflow (image download + apply)
      3. writes SetupComplete on the applied OS (OEM firmware-key activation + unattend cleanup)
      4. cleans up the workflow's duplicate PSReadLine
      5. copies logs to any media with an \OSDCloudLogs folder

    Fetched from GitHub at runtime by the profile; a baked copy on X:\ is the offline fallback.
#>
[CmdletBinding()]
param(
    [string] $Ref = 'prod'
)

$ErrorActionPreference = 'Stop'
$repo   = 'blawalt/WinPEAP'
$base   = "https://raw.githubusercontent.com/$repo/$Ref"
$logDir = 'X:\Windows\Temp'
Start-Transcript (Join-Path $logDir 'bootstrap.log') -Append -Force | Out-Null

$SetupCompleteCmd = @'
@echo off
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SetupComplete.ps1" >> "%WINDIR%\Temp\SetupComplete.log" 2>&1
exit /b 0
'@

$SetupCompletePs1 = @'
$ErrorActionPreference = 'SilentlyContinue'
"[$(Get-Date -Format o)] SetupComplete start"

# OEM firmware-key activation (works when the deployed edition matches the firmware key, e.g. Pro)
$key = (Get-CimInstance -ClassName SoftwareLicensingService).OA3xOriginalProductKey
if ($key) {
    $sls = Get-CimInstance -ClassName SoftwareLicensingService
    Invoke-CimMethod -InputObject $sls -MethodName InstallProductKey  -Arguments @{ProductKey = $key} | Out-Null
    Start-Sleep 5
    Invoke-CimMethod -InputObject $sls -MethodName RefreshLicenseStatus | Out-Null
    "OA3 firmware key installed"
}

# Remove the staged unattend
Remove-Item C:\Windows\Panther\unattend.xml, C:\Windows\Panther\unattend\unattend.xml -Force -ErrorAction SilentlyContinue

"[$(Get-Date -Format o)] SetupComplete done"
'@

function Get-RepoScript {
    param([string]$Name)
    $dest = Join-Path $env:TEMP $Name
    for ($i = 1; $i -le 5; $i++) {
        try { Invoke-WebRequest -UseBasicParsing "$base/$Name" -OutFile $dest; return $dest }
        catch { Write-Warning "fetch $Name attempt $i failed: $_"; Start-Sleep 10 }
    }
    $baked = Join-Path 'X:\' $Name
    if (Test-Path $baked) { Write-Warning "GitHub unreachable - using baked X:\$Name"; return $baked }
    throw "Cannot obtain $Name from GitHub ($Ref) or X:\"
}

function Get-GroupTag {
    param([string]$Default = '')
    while ($true) {
        Write-Host ''
        Write-Host '  Autopilot Group Tag:' -ForegroundColor Cyan
        Write-Host '    1) 1:1 Assigned   (no group tag)'
        Write-Host '    2) Shared         (group tag: Shared)'
        Write-Host '    3) Manual entry'
        switch (Read-Host '  Choice [1-3]') {
            '1' { return '' }
            '2' { return 'Shared' }
            '3' {
                $m = Read-Host '  Enter group tag'
                if (-not [string]::IsNullOrWhiteSpace($m)) { return $m.Trim() }
                Write-Host '  Group tag cannot be blank for manual entry.' -ForegroundColor Yellow
            }
            default { Write-Host '  Enter 1, 2, or 3.' -ForegroundColor Yellow }
        }
    }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = 'Tls12'

    # ---- config ----
    if (-not (Test-Path 'X:\config.json')) { throw 'X:\config.json is missing from the boot media.' }
    $cfg = Get-Content 'X:\config.json' -Raw | ConvertFrom-Json
    $authMode = if ($cfg.AuthMode) { $cfg.AuthMode } else { 'ClientSecret' }

    # ---- group tag ----
    try   { $groupTag = Get-GroupTag }
    catch { $groupTag = ''; Write-Warning 'No console for prompt - defaulting to 1:1 Assigned (no group tag).' }
    Write-Host "  Using group tag: '$groupTag'" -ForegroundColor Green

    # ---- 1) Autopilot 4k hash upload ----
    $up = Get-RepoScript '4kAutopilotHashUpload.ps1'
    $apParams = @{
        TenantId          = $cfg.TenantId
        AppId             = $cfg.AppId
        AuthMode          = $authMode
        UploadToAutopilot = $true
        ToolRoot          = 'X:\'
    }
    if ($cfg.AppSecret) { $apParams.AppSecret = $cfg.AppSecret }
    if ($groupTag)      { $apParams.GroupTag  = $groupTag }
    & $up @apParams

    # ---- 2) OSDCloud V2 workflow ----
    & (Import-Module OSDCloud -PassThru -Force) {
        Initialize-OSDCloudDeploy -WorkflowName 'default'
        $global:OSDCloudDeploy.Force     = $true
        $global:OSDCloudDeploy.TimeStart = Get-Date
        Invoke-OSDCloudWorkflowTask
    }

    # ---- 3) find the applied OS drive ----
    $t = 'C:'
    if (-not (Test-Path "$t\Windows\System32\ntoskrnl.exe")) {
        $t = ((Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows\System32\ntoskrnl.exe") } |
                Select-Object -First 1).DriveLetter) + ':'
    }
    Write-Host "Applied OS drive: $t"

    # ---- 4) undo the workflow's PSReadLine side-by-side install ----
    $psrl = "$t\Program Files\WindowsPowerShell\Modules\PSReadLine"
    Get-ChildItem $psrl -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -ne '2.0.0' | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # ---- 5) write SetupComplete ----
    $s = "$t\Windows\Setup\Scripts"
    New-Item $s -ItemType Directory -Force | Out-Null
    Set-Content "$s\SetupComplete.cmd" -Value $SetupCompleteCmd -Encoding Ascii -Force
    Set-Content "$s\SetupComplete.ps1" -Value $SetupCompletePs1 -Encoding UTF8 -Force
}
finally {
    Stop-Transcript | Out-Null
    $vol = Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\OSDCloudLogs") } | Select-Object -First 1
    if ($vol) { Copy-Item (Join-Path $logDir '*.log') "$($vol.DriveLetter):\OSDCloudLogs\" -Force -ErrorAction SilentlyContinue }
}
