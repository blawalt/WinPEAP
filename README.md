# WinPEAP

# Guide: POC for Transitioning to Entra Joined Devices using OSDCloud

## 1. Introduction

This document outlines the Proof of Concept (POC) process for transitioning devices from their current Hybrid Azure AD Joined state (without Intune management) to a fully cloud-managed state using Microsoft Entra Join (formerly Azure AD Join) and Intune.

The chosen method utilizes OSDCloud, a PowerShell module, to create a customized Windows Preinstallation Environment (WinPE) delivered via an ISO file. This approach automates the Windows installation and, crucially, incorporates a script to register the device with Windows Autopilot during the WinPE phase, ensuring a smooth onboarding experience into Intune.

**❗️ Important Warning: Virtual Machine (VM) Considerations ❗️**

When testing this deployment process using Virtual Machines, be aware of Windows Autopilot profile limitations:

* **Self-Deploying Mode:** Autopilot profiles set to Self-Deploying mode (and Pre-Provisioning/White Glove) require hardware TPM 2.0 attestation to authenticate the device during enrollment. Most standard VM configurations either lack a virtual TPM (vTPM) or cannot perform the required level of attestation. Attempting to use a Self-Deploying profile on a typical VM will likely result in enrollment failure during the Autopilot process.

**Recommendation for VMs:** To successfully test Autopilot enrollment on VMs using this OSDCloud method, ensure the target VM object (registered via the hardware hash upload) is assigned an Autopilot profile configured for **User-Driven mode** in Microsoft Intune. User-Driven mode relies on user credentials for authentication and does not require TPM attestation, making it compatible with most VM environments.

## 2. Goal

To demonstrate a reliable and automated method for deploying Windows 11 (or 10) that results in a device being Entra Joined and automatically enrolled into Intune via Windows Autopilot, requiring minimal interaction after initial boot.

## 3. Core Technology: OSDCloud

OSDCloud simplifies and automates the Windows deployment process. It will be leveraged to:

* Download the required Windows OS files.
* Create a customized WinPE environment.
* Inject custom scripts and tools into WinPE for Autopilot registration.
* Package the entire deployment into a bootable ISO file.

## 4. Prerequisites

Before starting, ensure the following are installed and configured on the administrative machine:

* **PowerShell:** Running as Administrator.
* **OSDCloud Module:** Install or update the OSDCloud PowerShell module.
    ```powershell
    Install-Module OSDCloud -Force
    ```
* **Windows Assessment and Deployment Kit (ADK) and WinPE Add-on:** Install the Windows 10 or Windows 11 ADK and the corresponding Windows PE add-on. These provide essential deployment tools, including WinPE itself and the `oa3tool.exe` needed later.
    * Download link: [Windows ADK Downloads (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
    * Ensure installation of both the **ADK** and the **WinPE Add-on** components.

## 5. Step-by-Step Process

Execute the following steps in an elevated PowerShell window:

### Step 5.1: Create an OSDCloud Template

A template defines default settings for deployments (like language and locale). This serves as a baseline for workspaces.

```powershell
# Creates a template with US English language and locale settings
New-OSDCloudTemplate -SetAllIntl en-us -SetInputLocale en-us
```

### Step 5.2: Create an OSDCloud Workspace

A workspace is a dedicated directory where OSDCloud stores downloaded content, customizations, and temporary files for a specific deployment configuration.

```powershell
# Creates a workspace directory. Replace the path with the desired location.
# OSDCloud will create the directory structure if it doesn't exist.
New-OSDCloudWorkspace -WorkspacePath "C:\OSDCloud\EntraJoinPOC"
```

You can verify or change the active workspace later using `Get-OSDCloudWorkspace` and `Set-OSDCloudWorkspace -WorkspacePath "C:\path\to\workspace"`.

### Step 5.3: Add Customizations for Autopilot Hash Upload

This step involves adding the Autopilot registration script and necessary tools to the WinPE environment.

1.  **Navigate to the Startnet Scripts Folder:** Go to the Startnet scripts directory within the created workspace. Using the example above, this would be: `C:\OSDCloud\EntraJoinPOC\Config\Scripts\Startnet\`
2.  **Copy Required Files:** Place the following files into this `Startnet` directory:
    * `4kAutopilotHashUpload.ps1`: The custom PowerShell script responsible for capturing and uploading the hash (you MUST update $groupTag to your respective GroupTag at Intune.
    * `oa3tool.exe`: Copy this executable from the ADK installation path. Typically found at: `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Licensing\OA30\oa3tool.exe`
    * `PCPKsp.dll`: Copy this DLL file from a Windows machine w/ a similar build. Found at: `C:\Windows\System32\PCPKsp.dll`
    * `oa3.cfg` & `input.xml`

**Explanation:**

* Capturing the hardware hash for Autopilot registration typically needs access to the device's TPM. Accessing the TPM directly from WinPE can be problematic.
* The `oa3tool.exe` (along with its dependency `PCPKsp.dll` and configuration files) provides a reliable way to extract the necessary hardware information within the WinPE environment. This specific technique for using `oa3tool.exe` within WinPE for Autopilot hash capture was adapted from information shared on [Can you create a Autopilot Hash from WinPE? Yes! (Mike's MDM Blog)](https://mikemdm.de/2023/01/29/can-you-create-a-autopilot-hash-from-winpe-yes/)
* The `4kAutopilotHashUpload.ps1` script leverages `oa3tool.exe` to get the hash and then uses Microsoft Graph API calls to upload it directly to the Autopilot device list in Entra/Intune.
* Performing this upload during WinPE, before the main Windows OS setup begins, is crucial for ensuring the device is known to Autopilot by the time Windows checks for an Autopilot profile during OOBE.

### Step 5.4: Edit the WinPE Image

This command modifies the base WinPE image (`boot.wim`), injecting the files added in Step 5.3 and configuring the OSDCloud deployment process.

**Important Warning:** The `Edit-OSDCloudWinPE` command applies the parameters specified each time it is run. If you run the command once with certain flags (e.g., `-StartOSDCloud`) and then run it again later with different flags (e.g., only `-Wallpaper`), the settings from the first run (like `-StartOSDCloud` or previously set `-CloudDriver`) will be overwritten or reset to defaults unless they are explicitly included again in the second command. It is best practice to include all desired `Edit-OSDCloudWinPE` customization flags in a single execution.

```powershell
# Define path to wallpaper (optional) - replace with your actual path
$WallpaperPath = "C:\path\to\your\background.jpg"

# Ensure you are in the correct workspace context first (use Set-OSDCloudWorkspace if needed)
# This command customizes the WinPE image in the current workspace
Edit-OSDCloudWinPE -StartOSDCloud "-OSVersion 'Windows 11' -OSBuild 23H2 -OSEdition Education -OSLanguage en-us -OSLicense Volume -ZTI -Restart" `
                   -CloudDriver Dell `
                   -Wallpaper $WallpaperPath `
                   -Verbose
```

* `-StartOSDCloud "..."`: Defines the parameters passed to the OSDCloud engine when it runs within WinPE.
    * `-OSVersion`, `-OSBuild`, `-OSEdition`, `-OSLanguage`, `-OSLicense`: Specify the target Windows operating system details. Adjust as needed.
    * `-ZTI`: Enables Zero Touch Installation for automated deployment within WinPE.
    * `-Restart`: Automatically restarts the computer after the OSDCloud process completes.
* `-CloudDriver Dell`: Instructs OSDCloud to download the latest WinPE driver pack specifically for Dell hardware directly from Dell's sources and inject them into the WinPE image. This significantly improves hardware compatibility (especially network and storage controllers) during the WinPE phase for Dell devices. Other vendors like `'HP'` or `'Lenovo'` can also be specified.
* `-Wallpaper $path` (Optional): Sets a custom background image for the WinPE environment itself. Replace `$path` with the full path to a `.jpg` or `.bmp` image file. This is purely cosmetic for the deployment phase. If not needed, omit this parameter.
* `-Verbose`: Provides detailed output during command execution.

### Step 5.5: Create the Bootable ISO File

This final OSDCloud command packages the customized WinPE environment into a bootable `.ISO` file.

```powershell
# Ensure you are still in the correct workspace context
# Create the ISO file using the contents of the current workspace
New-OSDCloudISO -Verbose
```

## 6. Deployment

1.  **Transfer ISO:** Copy the generated ISO file (found in the workspace's working directory) to bootable media (USB drive, VM mount, etc.) or use `New-OSDCloudUSB`.
2.  **Network Connection:** Ensure the target device has a **WIRED** network connection with internet access before booting from the ISO. Wireless connections are generally unreliable during WinPE for Autopilot registration.
3.  **Boot Device:** Boot the target device from the created ISO media.
4.  **Automated Process:** Due to the `-ZTI` flag:
    * The device boots into WinPE (potentially displaying the custom wallpaper).
    * Necessary drivers (like Dell WinPE drivers) load.
    * The `4kAutopilotHashUpload.ps1` script runs automatically.
    * OSDCloud automates partitioning, image application, and configuration.
    * The device restarts upon completion.
5.  **Outcome:** After restart, the device boots into OOBE. Windows should detect the assigned Autopilot profile (due to the successful hash upload - remember the VM considerations mentioned earlier if testing virtually), guide the user through Entra Join (for User-Driven profiles) or proceed automatically (for Self-Deploying on compatible physical hardware), and enroll the device into Intune.

## 7. Conclusion

This OSDCloud process provides a robust method for achieving a zero-touch (for Self-Deploying) or minimal-touch (for User-Driven) deployment experience that transitions devices directly into an Entra Joined and Intune-managed state. By injecting the Autopilot registration script and appropriate WinPE drivers, it overcomes common timing and hardware compatibility issues, ensuring devices are correctly onboarded from the start.
