[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $AppId,
    [Parameter(Mandatory)] [string] $AppSecret,
    [Parameter(Mandatory)] [string] $GroupTag,
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

# OEM firmware-key activation (Pro-from-Dell)
$key = (Get-CimInstance -ClassName SoftwareLicensingService).OA3xOriginalProductKey
if ($key) {
    $sls = Get-CimInstance -ClassName SoftwareLicensingService
    Invoke-CimMethod -InputObject $sls -MethodName InstallProductKey  -Arguments @{ProductKey = $key} | Out-Null
    Start-Sleep 5
    Invoke-CimMethod -InputObject $sls -MethodName RefreshLicenseStatus | Out-Null
    "OA3 firmware key installed"
}

# Remove staged unattend
Remove-Item C:\Windows\Panther\unattend.xml, C:\Windows\Panther\unattend\unattend.xml -Force -ErrorAction SilentlyContinue

"[$(Get-Date -Format o)] SetupComplete done"
'@

function Get-RepoScript {
    param([string]$Name)
    $dest = Join-Path $env:TEMP $Name
    for ($i = 1; $i -le 5; $i++) {
        try { Invoke-WebRequest -UseBasicParsing "$base/$Name" -OutFile $dest; return $dest }
        catch { Start-Sleep 10 }
    }
    $baked = Join-Path 'X:\' $Name
    if (Test-Path $baked) { Write-Warning "GitHub unreachable - using baked X:\$Name"; return $baked }
    throw "Cannot obtain $Name from GitHub ($Ref) or X:\"
}

try {
    [Net.ServicePointManager]::SecurityProtocol = 'Tls12'

    # ---- 1) Autopilot 4k hash upload ----
    $up = Get-RepoScript '4kAutopilotHashUpload.ps1'
    & $up -TenantId $TenantId -AppId $AppId -AppSecret $AppSecret -GroupTag $GroupTag -UploadToAutopilot -ToolRoot 'X:\'

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

    # ---- 4) undo the workflow's PSReadLine side-by-side mess ----
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
