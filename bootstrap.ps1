[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][string]$AppSecret,
    [Parameter(Mandatory)][string]$GroupTag,
    [string]$Ref = 'prod'
)
$ErrorActionPreference = 'Stop'
Start-Transcript "X:\Windows\Temp\bootstrap.log" -Append -Force | Out-Null
$base = "https://raw.githubusercontent.com/blawalt/WinPEAP/$Ref"
try {
    # 1) Autopilot 4k hash upload
    $up = "$env:TEMP\4kAutopilotHashUpload.ps1"
    Invoke-WebRequest -UseBasicParsing "$base/4kAutopilotHashUpload.ps1" -OutFile $up
    & $up -TenantId $TenantId -AppId $AppId -AppSecret $AppSecret -GroupTag $GroupTag

    # 2) OSDCloud V2 workflow
    & (Import-Module OSDCloud -PassThru -Force) {
        Initialize-OSDCloudDeploy -WorkflowName 'default'
        $global:OSDCloudDeploy.Force     = $true
        $global:OSDCloudDeploy.TimeStart = Get-Date
        Invoke-OSDCloudWorkflowTask
    }

    # 3) SetupComplete on the applied OS
    $t = 'C:'
    if (-not (Test-Path "$t\Windows\System32\ntoskrnl.exe")) {
        $t = ((Get-Volume | ?{$_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows\System32\ntoskrnl.exe")}|select -First 1).DriveLetter)+':'
    }
    $s = "$t\Windows\Setup\Scripts"; New-Item $s -ItemType Directory -Force | Out-Null
    @'
@echo off
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SetupComplete.ps1" >> "%WINDIR%\Temp\SetupComplete.log" 2>&1
exit /b 0
'@ | Set-Content "$s\SetupComplete.cmd" -Encoding Ascii -Force
    @'
$ErrorActionPreference='SilentlyContinue'
"[$(Get-Date -f o)] start" | Write-Output
$k=(Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKey
if($k){$sls=Get-CimInstance SoftwareLicensingService
 Invoke-CimMethod -InputObject $sls -MethodName InstallProductKey -Arguments @{ProductKey=$k}|Out-Null
 Start-Sleep 5
 Invoke-CimMethod -InputObject $sls -MethodName RefreshLicenseStatus|Out-Null
 "OA3 key installed"|Write-Output}
Remove-Item C:\Windows\Panther\unattend.xml,C:\Windows\Panther\unattend\unattend.xml -Force -EA 0
"[$(Get-Date -f o)] done"|Write-Output
'@ | Set-Content "$s\SetupComplete.ps1" -Encoding UTF8 -Force

    # copy logs to media if present
    $log = Get-Volume | ?{$_.DriveLetter -and (Test-Path "$($_.DriveLetter):\OSDCloudLogs")} | select -First 1
    if ($log) { Copy-Item X:\Windows\Temp\*.log "$($log.DriveLetter):\OSDCloudLogs\" -Force -EA 0 }
}
finally { Stop-Transcript | Out-Null }
