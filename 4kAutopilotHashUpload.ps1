<#
.SYNOPSIS
    Collects Windows Autopilot hardware hash from WinPE and uploads to Microsoft Intune
.DESCRIPTION
    This script gathers the Windows Autopilot hardware hash using OA3Tool while in WinPE,
    including TPM information by registering the PCPKsp.dll, and then uploads the device
    to Windows Autopilot via Microsoft Graph API
.PARAMETER GroupTag
    Optional. Specifies the Autopilot group tag to assign to the device.
.PARAMETER TenantId
    Required for upload. Specifies the Azure AD tenant ID for authentication.
.PARAMETER AppId
    Required for upload. Specifies the app registration ID for authentication.
.PARAMETER AppSecret
    Required for upload. Specifies the app registration secret for authentication.
.PARAMETER UploadToAutopilot
    Optional. Indicates whether to upload the device to Autopilot. Default is $false.
.NOTES
    File Name: 4kAutopilotHashUpload.ps1
    Author: Based on Mike Mdm's approach (https://mikemdm.de/2023/01/29/can-you-create-a-autopilot-hash-from-winpe-yes/)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)] [String] $GroupTag = "<YOUR-AP-GROUP-TAG>",
    [Parameter(Mandatory=$false)] [String] $TenantId = "<TENANT-ID>",
    [Parameter(Mandatory=$false)] [String] $AppId = "<APP/CLIENT-ID>",
    [Parameter(Mandatory=$false)] [String] $AppSecret = "<APP/CLIENT-SECRET",
    [Parameter(Mandatory=$false)] [Switch] $UploadToAutopilot = $true
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
        # Define auth body
        $body = @{
            grant_type    = "client_credentials"
            client_id     = $AppId
            client_secret = $AppSecret
            scope         = "https://graph.microsoft.com/.default"
        }

        # Get OAuth token
        $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body
        
        # Return the token
        return $response.access_token
    }
    catch {
        Write-Host "Error getting auth token: $_" -ForegroundColor Red
        if ($_.Exception.Response) {
            $errorResponse = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorResponse)
            $reader.BaseStream.Position = 0
            $reader.DiscardBufferedData()
            $responseBody = $reader.ReadToEnd()
            Write-Host $responseBody -ForegroundColor Red
        }
        throw
    }
}

function Add-AutopilotImportedDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [String] $SerialNumber,
        [Parameter(Mandatory=$true)] [String] $HardwareHash,
        [Parameter(Mandatory=$false)] [String] $GroupTag = "",
        [Parameter(Mandatory=$true)] [String] $AuthToken
    )

    try {
        # Create the device object
        $deviceObject = @{
            serialNumber = $SerialNumber
            hardwareIdentifier = $HardwareHash
        }

        # Add GroupTag if specified
        if (-not [string]::IsNullOrEmpty($GroupTag)) {
            $deviceObject.groupTag = $GroupTag
        }

        # Convert to JSON
        $deviceJson = $deviceObject | ConvertTo-Json

        # Set up API request
        $headers = @{
            "Authorization" = "Bearer $AuthToken"
            "Content-Type" = "application/json"
        }

        # Upload to Autopilot using the importedWindowsAutopilotDeviceIdentities endpoint
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
            $responseBody = $reader.ReadToEnd()
            Write-Host $responseBody -ForegroundColor Red
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
        # Set up API request
        $headers = @{
            "Authorization" = "Bearer $AuthToken"
            "Content-Type" = "application/json"
        }

        # Get device status from Autopilot
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
            $responseBody = $reader.ReadToEnd()
            Write-Host $responseBody -ForegroundColor Red
        }
        throw
    }
}

# Check if we're in WinPE and have the required PCPKsp.dll file
If ((Test-Path X:\Windows\System32\wpeutil.exe) -and (Test-Path $PSScriptRoot\PCPKsp.dll))
{
    Write-Host "Running in WinPE, installing PCPKsp.dll for TPM support..." -ForegroundColor Yellow
    Copy-Item "$PSScriptRoot\PCPKsp.dll" "X:\Windows\System32\PCPKsp.dll"
    # Register PCPKsp
    rundll32 X:\Windows\System32\PCPKsp.dll,DllInstall
}

# Change Current Directory so OA3Tool finds the files written in the Config File 
Push-Location $PSScriptRoot

# Delete old Files if exits
if (Test-Path $PSScriptRoot\OA3.xml) 
{
    Remove-Item $PSScriptRoot\OA3.xml -Force
}

# Get SN from WMI
$serial = (Get-WmiObject -Class Win32_BIOS).SerialNumber
Write-Host "Device Serial Number: $serial" -ForegroundColor Cyan

# Run OA3Tool
Write-Host "Running OA3Tool to gather hardware hash..." -ForegroundColor Green
&$PSScriptRoot\oa3tool.exe /Report /ConfigFile=$PSScriptRoot\OA3.cfg /NoKeyCheck

# Check if Hash was found
If (Test-Path $PSScriptRoot\OA3.xml) 
{
    # Read Hash from generated XML File
    [xml]$xmlhash = Get-Content -Path "$PSScriptRoot\OA3.xml"
    $hash = $xmlhash.Key.HardwareHash
    Write-Host "Hardware Hash successfully retrieved" -ForegroundColor Green
    
    # Delete XML File
    Remove-Item $PSScriptRoot\OA3.xml -Force
    
    # Output the hash information to screen
    Write-Host "Serial Number: $serial" -ForegroundColor Cyan
    Write-Host "Group Tag: $GroupTag" -ForegroundColor Cyan
    Write-Host "Hardware Hash length: $(($hash).Length) characters" -ForegroundColor Cyan
    
    # Create temporary CSV file in case it's needed
    $TempCSVPath = "X:\Windows\Temp\AutopilotHash.csv"
    
    # Create the CSV object
    $computers = @()
    $product = ""
    
    if ($GroupTag -ne "")
    {
        # Create a pipeline object with Group Tag
        $c = New-Object psobject -Property @{
            "Device Serial Number" = $serial
            "Windows Product ID" = $product
            "Hardware Hash" = $hash
            "Group Tag" = $GroupTag
        }
        
        # Save to temp CSV
        $computers += $c
        $computers | Select "Device Serial Number", "Windows Product ID", "Hardware Hash", "Group Tag" | 
            ConvertTo-CSV -NoTypeInformation | % {$_ -replace '"',''} | Out-File $TempCSVPath
    }
    else
    {
        # Create a pipeline object without Group Tag
        $c = New-Object psobject -Property @{
            "Device Serial Number" = $serial
            "Windows Product ID" = $product
            "Hardware Hash" = $hash
        }
        
        # Save to temp CSV
        $computers += $c
        $computers | Select "Device Serial Number", "Windows Product ID", "Hardware Hash" | 
            ConvertTo-CSV -NoTypeInformation | % {$_ -replace '"',''} | Out-File $TempCSVPath
    }
    
    Write-Host "CSV file created at: $TempCSVPath" -ForegroundColor Green
    
    # Upload to Autopilot if requested
    if ($UploadToAutopilot)
    {
        if ([string]::IsNullOrEmpty($TenantId) -or [string]::IsNullOrEmpty($AppId) -or [string]::IsNullOrEmpty($AppSecret))
        {
            Write-Host "Error: TenantId, AppId, and AppSecret parameters are required for Autopilot upload" -ForegroundColor Red
        }
        else
        {
            try {
                # Get auth token
                Write-Host "Getting authorization token..." -ForegroundColor Yellow
                $authToken = Get-AuthToken -TenantId $TenantId -AppId $AppId -AppSecret $AppSecret
                
                # Upload device to Autopilot
                Write-Host "Adding device to Autopilot..." -ForegroundColor Yellow
                $importedDevice = Add-AutopilotImportedDevice -SerialNumber $serial -HardwareHash $hash -GroupTag $GroupTag -AuthToken $authToken
                
                if ($importedDevice) {
                    Write-Host "Device added successfully with ID: $($importedDevice.id)" -ForegroundColor Green
                    
                    # Wait for processing to complete
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
                        Write-Host "Import did not complete within the expected time." -ForegroundColor Yellow
                    }
                }
            }
            catch {
                Write-Host "An error occurred during the Autopilot upload process: $_" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "Skipping Autopilot upload. Use -UploadToAutopilot switch with required parameters to upload." -ForegroundColor Yellow
    }
}
else
{
    Write-Host "No Hardware Hash found" -ForegroundColor Red
    Pop-Location
    exit 1
}

# Return to original directory
Pop-Location