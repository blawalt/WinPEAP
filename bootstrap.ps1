[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $AppId,
    [Parameter(Mandatory)] [string] $AppSecret,
    [Parameter(Mandatory)] [string] $GroupTag,
    [string] $Ref = 'prod'
)

$base = "https://raw.githubusercontent.com/<ORG>/<REPO>/$Ref"

# 1) Autopilot hardware-hash import
$upload = "$env:TEMP\UploadToAutopilot.ps1"
Invoke-WebRequest -UseBasicParsing "$base/UploadToAutopilot.ps1" -OutFile $upload
& $upload -TenantId $TenantId -AppId $AppId -AppSecret $AppSecret -GroupTag $GroupTag

# 2) OSDCloud V2 workflow
& (Import-Module OSDCloud -PassThru -Force) {
    Initialize-OSDCloudDeploy -WorkflowName 'default'
    $global:OSDCloudDeploy.Force     = $true
    $global:OSDCloudDeploy.TimeStart = Get-Date
    Invoke-OSDCloudWorkflowTask
}

# 3) Write SetupComplete onto the applied OS
$TargetDrive = 'C:'
if (-not (Test-Path "$TargetDrive\Windows\System32\ntoskrnl.exe")) {
    $TargetDrive = ((Get-Volume | ? { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows\System32\ntoskrnl.exe") } | Select-Object -First 1).DriveLetter) + ':'
}
$scripts = "$TargetDrive\Windows\Setup\Scripts"
New-Item $scripts -ItemType Directory -Force | Out-Null

@'
@echo off
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SetupComplete.ps1" >> "%WINDIR%\Temp\SetupComplete.log" 2>&1
exit /b 0
'@ | Set-Content "$scripts\SetupComplete.cmd" -Encoding Ascii -Force

@'
$ErrorActionPreference = 'SilentlyContinue'
Write-Output "[$(Get-Date -f o)] SetupComplete start"

# --- OEM firmware-key activation (Pro-from-Dell) ---
$key = (Get-CimInstance -ClassName SoftwareLicensingService).OA3xOriginalProductKey
if ($key) {
    $sls = Get-CimInstance -ClassName SoftwareLicensingService
    Invoke-CimMethod -InputObject $sls -MethodName InstallProductKey  -Arguments @{ProductKey = $key} | Out-Null
    Start-Sleep 5
    Invoke-CimMethod -InputObject $sls -MethodName RefreshLicenseStatus | Out-Null
    Write-Output "OEM key installed"
}

# --- remove staged unattend ---
Remove-Item C:\Windows\Panther\unattend.xml          -Force -EA 0
Remove-Item C:\Windows\Panther\unattend\unattend.xml -Force -EA 0

Write-Output "[$(Get-Date -f o)] SetupComplete done"
'@ | Set-Content "$scripts\SetupComplete.ps1" -Encoding UTF8 -Force
