<#
.SYNOPSIS
    Collects Windows Autopilot 4k hardware hash from WinPE and uploads to Intune.
.PARAMETER GroupTag      Autopilot group tag. Optional.
.PARAMETER TenantId      Entra tenant ID.      Required for upload.
.PARAMETER AppId         App registration ID.  Required for upload.
.PARAMETER AppSecret     App registration secret. Required for upload.
.PARAMETER UploadToAutopilot  Upload the device. Default $true.
.PARAMETER ToolRoot      Folder holding oa3tool.exe / OA3.cfg / input.xml / PCPKsp.dll.
                         Defaults to X:\ (baked from WinPEStartup\Files). Leave as-is even
                         when this script itself is fetched from GitHub to $env:TEMP.
.NOTES
    Based on Mike Mdm: https://mikemdm.de/2023/01/29/can-you-create-a-autopilot-hash-from-winpe-yes/
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)] [String] $GroupTag = "",
    [Parameter(Mandatory=$false)] [String] $TenantId,
    [Parameter(Mandatory=$false)] [String] $AppId,
    [Parameter(Mandatory=$false)] [String] $AppSecret,
    [Parameter(Mandatory=$false)] [Switch] $UploadToAutopilot = $true,
    [Parameter(Mandatory=$false)] [String] $ToolRoot = 'X:\'
)

# Functions for Autopilot API operations
function Get-AuthToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [String] $TenantId,
        [Parameter(Mandatory=$true)] [String] $AppId,
        [Parameter(Mandatory=$true)] [String] $AppSecret
    )

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
        if ($_.Exception.Response) {
            $errorResponse = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorResponse)
            $reader.BaseStream.Position = 0
            $reader.DiscardBufferedData()
            Write-Host ($reader.ReadToEnd()) -ForegroundColor Red
        }
        throw
    }
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
        if ($_.Exception.Response) {
            $errorResponse = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorResponse)
            $reader.BaseStream.Position = 0
            $reader.DiscardBufferedData()
            Write-Host ($reader.ReadToEnd()) -ForegroundColor Red
        }
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
        if ($_.Exception.Response) {
            $errorResponse = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorResponse)
            $reader.BaseStream.Position = 0
            $reader.DiscardBufferedData()
            Write-Host ($reader.ReadToEnd()) -ForegroundColor Red
        }
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
            -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,%27$serial%27)" `
            -Headers $headers
        return ($response.value | Where-Object { $_.serialNumber -eq $serial })
    }
    catch {
        Write-Host "Error getting device status: $_" -ForegroundColor Red
        if ($_.Exception.Response) {
            $errorResponse = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorResponse)
            $reader.BaseStream.Position = 0
            $reader.DiscardBufferedData()
            Write-Host ($reader.ReadToEnd()) -ForegroundColor Red
        }
        throw
    }
}

# ---- resolve tool paths (baked on X:\ even when this script runs from $env:TEMP) ----
$PCPKsp  = Join-Path $ToolRoot 'PCPKsp.dll'
$OA3Tool = Join-Path $ToolRoot 'oa3tool.exe'
$OA3Cfg  = Join-Path $ToolRoot 'OA3.cfg'
$OA3Xml  = Join-Path $ToolRoot 'OA3.xml'

# Check if we're in WinPE and have PCPKsp.dll
if ((Test-Path X:\Windows\System32\wpeutil.exe) -and (Test-Path $PCPKsp)) {
    Write-Host "Running in WinPE, installing PCPKsp.dll for TPM support..." -ForegroundColor Yellow
    Copy-Item $PCPKsp "X:\Windows\System32\PCPKsp.dll" -Force
    rundll32 X:\Windows\System32\PCPKsp.dll,DllInstall
}

# OA3Tool resolves relative paths from its working directory
Push-Location $ToolRoot

if (Test-Path $OA3Xml) { Remove-Item $OA3Xml -Force }

$serial = (Get-WmiObject -Class Win32_BIOS).SerialNumber
Write-Host "Device Serial Number: $serial" -ForegroundColor Cyan

Write-Host "Running OA3Tool to gather hardware hash..." -ForegroundColor Green
& $OA3Tool /Report /ConfigFile=$OA3Cfg /NoKeyCheck

if (Test-Path $OA3Xml) {
    [xml]$xmlhash = Get-Content -Path $OA3Xml
    $hash = $xmlhash.Key.HardwareHash
    Write-Host "Hardware Hash successfully retrieved" -ForegroundColor Green
    Remove-Item $OA3Xml -Force

    Write-Host "Serial Number: $serial" -ForegroundColor Cyan
    Write-Host "Group Tag: $GroupTag" -ForegroundColor Cyan
    Write-Host "Hardware Hash length: $(($hash).Length) characters" -ForegroundColor Cyan

    $TempCSVPath = "X:\Windows\Temp\AutopilotHash.csv"
    $computers = @()
    $product = ""

    if ($GroupTag -ne "") {
        $c = New-Object psobject -Property @{
            "Device Serial Number" = $serial
            "Windows Product ID"   = $product
            "Hardware Hash"        = $hash
            "Group Tag"            = $GroupTag
        }
        $computers += $c
        $computers | Select "Device Serial Number", "Windows Product ID", "Hardware Hash", "Group Tag" |
            ConvertTo-CSV -NoTypeInformation | % { $_ -replace '"','' } | Out-File $TempCSVPath
    }
    else {
        $c = New-Object psobject -Property @{
            "Device Serial Number" = $serial
            "Windows Product ID"   = $product
            "Hardware Hash"        = $hash
        }
        $computers += $c
        $computers | Select "Device Serial Number", "Windows Product ID", "Hardware Hash" |
            ConvertTo-CSV -NoTypeInformation | % { $_ -replace '"','' } | Out-File $TempCSVPath
    }
    Write-Host "CSV file created at: $TempCSVPath" -ForegroundColor Green

    if ($UploadToAutopilot) {
        if ([string]::IsNullOrEmpty($TenantId) -or [string]::IsNullOrEmpty($AppId) -or [string]::IsNullOrEmpty($AppSecret)) {
            Write-Host "Error: TenantId, AppId, and AppSecret are required for Autopilot upload" -ForegroundColor Red
        }
        else {
            try {
                Write-Host "Getting authorization token..." -ForegroundColor Yellow
                $authToken = Get-AuthToken -TenantId $TenantId -AppId $AppId -AppSecret $AppSecret

                Write-Host "Adding device to Autopilot..." -ForegroundColor Yellow
                $importedDevice = Add-AutopilotImportedDevice -SerialNumber $serial -HardwareHash $hash -GroupTag $GroupTag -AuthToken $authToken

                $device = Get-AutopilotDevice -Serial $serial -AuthToken $authToken
                if ($device) {
                    Write-Host "Device already exists in Autopilot with SerialNumber: $serial" -ForegroundColor Green
                }
                else {
                    if ($importedDevice) {
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
                                Write-Host "Import failed: $($device.state.deviceErrorCode) - $($device.state.deviceErrorName)" -ForegroundColor Red
                                break
                            }
                            else {
                                Write-Host "Import status: $($device.state.deviceImportStatus). Waiting..." -ForegroundColor Yellow
                                $retryCount++
                            }
                        }
                        if (-not $processingComplete) {
                            Write-Host "Import did not complete within the expected time." -ForegroundColor Yellow
                        }
                    }
                }
            }
            catch {
                Write-Host "An error occurred during the Autopilot upload process: $_" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "Skipping Autopilot upload." -ForegroundColor Yellow
    }
}
else {
    Write-Host "No Hardware Hash found" -ForegroundColor Red
    Pop-Location
    exit 1
}

Pop-Location
