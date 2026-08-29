<#
.SYNOPSIS
    Collects the Windows Autopilot 4k hardware hash from WinPE and uploads it to Intune.
.DESCRIPTION
    Gathers the hardware hash using OA3Tool while in WinPE (including TPM info by registering
    PCPKsp.dll), then uploads the device to Windows Autopilot via Microsoft Graph.
    Supports two auth modes:
      ClientSecret - app-only (client credentials). Requires -AppSecret.
      DeviceCode   - delegated. The operator signs in at microsoft.com/devicelogin. No secret.
.PARAMETER GroupTag
    Autopilot group tag. Optional; blank = no group tag.
.PARAMETER TenantId
    Entra tenant ID. Required for upload.
.PARAMETER AppId
    App registration (client) ID. Required for upload.
.PARAMETER AppSecret
    App registration client secret. Required only when -AuthMode is ClientSecret.
.PARAMETER AuthMode
    ClientSecret (default) or DeviceCode.
.PARAMETER UploadToAutopilot
    Upload the device to Autopilot. Default $true. Pass $false for hash-only (writes the CSV).
.PARAMETER ToolRoot
    Folder holding oa3tool.exe / oa3.cfg / input.xml / PCPKsp.dll. Defaults to X:\ (the
    WinPEStartup\Files content, copied to the WinPE root at boot). Leave as-is even when this
    script is fetched from elsewhere - the OA3 binaries still live on X:\.
.NOTES
    File Name: 4kAutopilotHashUpload.ps1
    Author: Based on Mike Mdm's approach (https://mikemdm.de/2023/01/29/can-you-create-a-autopilot-hash-from-winpe-yes/)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)] [String] $GroupTag = "",
    [Parameter(Mandatory=$false)] [String] $TenantId,
    [Parameter(Mandatory=$false)] [String] $AppId,
    [Parameter(Mandatory=$false)] [String] $AppSecret,
    [Parameter(Mandatory=$false)] [ValidateSet('ClientSecret','DeviceCode')] [String] $AuthMode = 'ClientSecret',
    [Parameter(Mandatory=$false)] [bool]   $UploadToAutopilot = $true,
    [Parameter(Mandatory=$false)] [String] $ToolRoot = 'X:\'
)

# Functions for Autopilot API operations
function Get-AuthToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]  [String] $TenantId,
        [Parameter(Mandatory=$true)]  [String] $AppId,
        [Parameter(Mandatory=$false)] [String] $AppSecret,
        [Parameter(Mandatory=$false)] [ValidateSet('ClientSecret','DeviceCode')] [String] $AuthMode = 'ClientSecret'
    )

    if ($AuthMode -eq 'ClientSecret') {
        if ([string]::IsNullOrEmpty($AppSecret)) { throw "AppSecret is required when AuthMode is ClientSecret." }
        try {
            $body = @{
                grant_type    = "client_credentials"
                client_id     = $AppId
                client_secret = $AppSecret
                scope         = "https://graph.microsoft.com/.default"
            }
            $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body
            return $response.access_token
        }
        catch {
            Write-Host "Error getting auth token: $_" -ForegroundColor Red
            if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
            throw
        }
    }

    # ---- DeviceCode ----
    try {
        $dc = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
            -Body @{ client_id = $AppId; scope = "https://graph.microsoft.com/.default" }
    }
    catch {
        Write-Host "Error starting device code flow: $_" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
        throw
    }

    Write-Host ""
    Write-Host "  ==========================================================" -ForegroundColor Yellow
    Write-Host "   $($dc.message)"                                            -ForegroundColor Yellow
    Write-Host "  ==========================================================" -ForegroundColor Yellow
    Write-Host ""

    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    $interval = [int]$dc.interval
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $tok = Invoke-RestMethod -Method Post `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -Body @{
                    grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                    client_id   = $AppId
                    device_code = $dc.device_code
                }
            return $tok.access_token
        }
        catch {
            $err = ($_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue).error
            if ($err -eq 'authorization_pending') { continue }
            if ($err -eq 'slow_down')             { $interval += 5; continue }
            Write-Host "Device code auth failed: $err" -ForegroundColor Red
            throw "Device code auth failed: $err"
        }
    }
    throw "Device code sign-in timed out."
}

function Add-AutopilotImportedDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]  [String] $SerialNumber,
        [Parameter(Mandatory=$true)]  [String] $HardwareHash,
        [Parameter(Mandatory=$false)] [String] $GroupTag = "",
        [Parameter(Mandatory=$true)]  [String] $AuthToken
    )

    try {
        $deviceObject = @{
            serialNumber       = $SerialNumber
            hardwareIdentifier = $HardwareHash
        }
        if (-not [string]::IsNullOrEmpty($GroupTag)) { $deviceObject.groupTag = $GroupTag }
        $deviceJson = $deviceObject | ConvertTo-Json

        $headers = @{
            "Authorization" = "Bearer $AuthToken"
            "Content-Type"  = "application/json"
        }

        Write-Host "Uploading device to Autopilot..." -ForegroundColor Yellow
        $response = Invoke-RestMethod -Method Post `
            -Uri "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities" `
            -Headers $headers `
            -Body $deviceJson
        return $response
    }
    catch {
        Write-Host "Error adding device to Autopilot: $_" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
        throw
    }
}

function Get-AutopilotImportedDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [String] $Id,
        [Parameter(Mandatory=$true)] [String] $AuthToken
    )

    try {
        $headers = @{
            "Authorization" = "Bearer $AuthToken"
            "Content-Type"  = "application/json"
        }
        $response = Invoke-RestMethod -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$Id" `
            -Headers $headers
        return $response
    }
    catch {
        Write-Host "Error getting device status: $_" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
        throw
    }
}

function Get-AutopilotDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [String] $Serial,
        [Parameter(Mandatory = $true)] [String] $AuthToken
    )

    try {
        $headers = @{
            "Authorization" = "Bearer $AuthToken"
            "Content-Type"  = "application/json"
        }
        $response = Invoke-RestMethod -Method Get `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,%27$Serial%27)" `
            -Headers $headers
        return ($response.value | Where-Object { $_.serialNumber -eq $Serial })
    }
    catch {
        Write-Host "Error getting device status: $_" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
        throw
    }
}

# ---- resolve tool paths (baked on X:\ even when this script runs from $env:TEMP) ----
$PCPKsp  = Join-Path $ToolRoot 'PCPKsp.dll'
$OA3Tool = Join-Path $ToolRoot 'oa3tool.exe'
$OA3Cfg  = Join-Path $ToolRoot 'oa3.cfg'
$OA3Xml  = Join-Path $ToolRoot 'OA3.xml'
$OA3Bin  = Join-Path $ToolRoot 'OA3.bin'

# Register PCPKsp.dll for TPM support if we're in WinPE
if ((Test-Path X:\Windows\System32\wpeutil.exe) -and (Test-Path $PCPKsp)) {
    Write-Host "Running in WinPE, installing PCPKsp.dll for TPM support..." -ForegroundColor Yellow
    Copy-Item $PCPKsp "X:\Windows\System32\PCPKsp.dll" -Force
    rundll32 X:\Windows\System32\PCPKsp.dll,DllInstall
}

# OA3Tool resolves the relative paths in oa3.cfg against its working directory
Push-Location $ToolRoot

Remove-Item $OA3Xml, $OA3Bin -Force -ErrorAction SilentlyContinue

$serial = (Get-WmiObject -Class Win32_BIOS).SerialNumber
Write-Host "Device Serial Number: $serial" -ForegroundColor Cyan

Write-Host "Running OA3Tool to gather hardware hash..." -ForegroundColor Green
& $OA3Tool /Report /ConfigFile=$OA3Cfg /NoKeyCheck

if (Test-Path $OA3Xml) {
    [xml]$xmlhash = Get-Content -Path $OA3Xml
    $hash = $xmlhash.Key.HardwareHash
    Write-Host "Hardware Hash successfully retrieved" -ForegroundColor Green
    Remove-Item $OA3Xml, $OA3Bin -Force -ErrorAction SilentlyContinue

    Write-Host "Serial Number: $serial" -ForegroundColor Cyan
    Write-Host "Group Tag: $GroupTag" -ForegroundColor Cyan
    Write-Host "Hardware Hash length: $(($hash).Length) characters" -ForegroundColor Cyan

    # Write a CSV copy in case it is needed for a manual import
    $TempCSVPath = "X:\Windows\Temp\AutopilotHash.csv"
    $c = [ordered]@{
        "Device Serial Number" = $serial
        "Windows Product ID"   = ""
        "Hardware Hash"        = $hash
    }
    if ($GroupTag -ne "") { $c["Group Tag"] = $GroupTag }
    [pscustomobject]$c | ConvertTo-Csv -NoTypeInformation | ForEach-Object { $_ -replace '"','' } | Out-File $TempCSVPath
    Write-Host "CSV file created at: $TempCSVPath" -ForegroundColor Green

    if ($UploadToAutopilot) {
        if ([string]::IsNullOrEmpty($TenantId) -or [string]::IsNullOrEmpty($AppId)) {
            Write-Host "Error: TenantId and AppId are required for Autopilot upload" -ForegroundColor Red
        }
        elseif ($AuthMode -eq 'ClientSecret' -and [string]::IsNullOrEmpty($AppSecret)) {
            Write-Host "Error: AppSecret is required when AuthMode is ClientSecret" -ForegroundColor Red
        }
        else {
            try {
                Write-Host "Getting authorization token ($AuthMode)..." -ForegroundColor Yellow
                $authToken = Get-AuthToken -TenantId $TenantId -AppId $AppId -AppSecret $AppSecret -AuthMode $AuthMode

                Write-Host "Adding device to Autopilot..." -ForegroundColor Yellow
                $importedDevice = Add-AutopilotImportedDevice -SerialNumber $serial -HardwareHash $hash -GroupTag $GroupTag -AuthToken $authToken

                $device = Get-AutopilotDevice -Serial $serial -AuthToken $authToken
                if ($device) {
                    Write-Host "Device already exists in Autopilot with SerialNumber: $serial" -ForegroundColor Green
                }
                elseif ($importedDevice) {
                    Write-Host "Device added successfully with ID: $($importedDevice.id)" -ForegroundColor Green
                    Write-Host "Waiting for import to complete..." -ForegroundColor Yellow
                    $processingComplete = $false
                    $maxRetries = 20
                    $retryCount = 0
                    while (-not $processingComplete -and $retryCount -lt $maxRetries) {
                        Start-Sleep -Seconds 15
                        $device = Get-AutopilotImportedDevice -Id $importedDevice.id -AuthToken $authToken
                        if ($device.state.deviceImportStatus -eq "complete") {
                            $processingComplete = $true
                            Write-Host "Import completed successfully!" -ForegroundColor Green
                            Write-Host "Device Registration ID: $($device.state.deviceRegistrationId)" -ForegroundColor Cyan
                        }
                        elseif ($device.state.deviceImportStatus -eq "error") {
                            Write-Host "Import failed with error: $($device.state.deviceErrorCode) - $($device.state.deviceErrorName)" -ForegroundColor Red
                            break
                        }
                        else {
                            Write-Host "Import status: $($device.state.deviceImportStatus). Waiting..." -ForegroundColor Yellow
                            $retryCount++
                        }
                    }
                    if (-not $processingComplete) {
                        Write-Host "Import did not complete within the expected time (device is still imported)." -ForegroundColor Yellow
                    }
                }
            }
            catch {
                Write-Host "An error occurred during the Autopilot upload process: $_" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "Skipping Autopilot upload (-UploadToAutopilot `$false)." -ForegroundColor Yellow
    }
}
else {
    Write-Host "No Hardware Hash found" -ForegroundColor Red
    Pop-Location
    exit 1
}

Pop-Location
