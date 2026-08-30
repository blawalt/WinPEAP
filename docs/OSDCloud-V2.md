> For the legacy `OSD` module see [OSDCloud-V1.md](OSDCloud-V1.md).

# WinPE Autopilot Provisioning — OSDCloud V2

OSDCloud V2 replaces V1's variable-driven wrapper with a **task-sequence workflow engine** and
**JSON startup profiles** (`WinPEStartup`). Some V1 conveniences — the `SetupComplete` builder,
OEM key activation, Autopilot registration — are **not yet ported**, so this kit fills those gaps.

---

## Architecture

```
BOOT MEDIA  (held by a small number of technicians)
  WinPEStartup\Profiles\Autopilot.json     one-line launcher
  WinPEStartup\Files\   -> copied to X:\ at boot
    config.json          Repo / Ref / TenantId / AppId / AuthMode [/ AppSecret]   <- media only, never in git
    oa3tool.exe, PCPKsp.dll, oa3.cfg, input.xml   OA3Tool 4k-hash deps (must be baked)
    bootstrap.ps1, 4kAutopilotHashUpload.ps1, Startup.ps1   baked fallback copies

GITHUB  <Repo> @ <Ref>  (no secrets)  — fetched at runtime; Repo + Ref come from config.json
    bootstrap.ps1              hash upload -> OSDCloud workflow -> SetupComplete
    4kAutopilotHashUpload.ps1  4k hash + Graph upload (client-secret or device-code auth)
```

`Repo` and `Ref` live in `config.json` (on the media, never in git), so a fork points its own
media at its own repo/branch without touching a line of script. Pin `Ref` to something **you**
control — `main`, your own `stable`, a version tag. The media only re-flashes when `config.json`,
the profile, or the OA3 binaries change; script logic ships through GitHub.

---

## Boot flow

```
WinPE starts -> Recast initializes network -> profile runs InvokeMainCommand
  -> (Startup.ps1 or the profile) fetches bootstrap.ps1 from <Repo>@<Ref>   (baked fallback if offline)
  -> bootstrap.ps1:
       reads X:\config.json  (Repo, Ref, TenantId, AppId, AuthMode)
       prompts:  Group Tag  (plain prompt, or a numbered menu if config.json has GroupTagMenu)
       1) 4kAutopilotHashUpload.ps1  -> OA3Tool hash -> Graph import
          (DeviceCode: operator signs in at microsoft.com/devicelogin here)
       2) OSDCloud V2 workflow       -> download + apply Windows image
       3) writes C:\Windows\Setup\Scripts\SetupComplete.{cmd,ps1}
       4) removes the workflow's duplicate PSReadLine (keeps inbox 2.0.0)
       5) copies X:\Windows\Temp\*.log to any media \OSDCloudLogs folder
  -> reboot
Windows setup -> specialize -> SetupComplete.cmd runs (OEM activation, unattend cleanup) -> OOBE / Autopilot
```

`SetupComplete.cmd` is native Windows: if the file exists it runs once, as SYSTEM, at the end
of setup — **before** the Autopilot ESP. Right place for machine prep; not for app installs
(that's Intune's job).

---

## Prerequisites

### Build box

Everything here runs on the build box in an **elevated PowerShell 7 session** (`pwsh`, 7.6+ —
the OSDeploy V2 tooling is a `pwsh` workflow; Windows PowerShell 5.1 is not supported for the
build side).

```powershell
Install-Module -Name OSDCloud                     # OSDCloud V2 deployment engine (baked into the boot image)
Install-Module -Name OSDeploy -AllowPrerelease    # Build-OSDeployBoot etc. (gallery has prerelease only)
Install-Module -Name OSD                          # Build-OSDeployBoot bakes this into the boot image

Install-OSDeploySoftware -Name 'adk-25h2' -Force  # Windows ADK + WinPE add-on (adjust the ADK name to taste)
Update-OSDeployCoreDrivers                        # WinPE network / storage / wifi drivers -> winpe-drivers\amd64\*

Build-OSDeployBoot                                # run once, press Cancel at the profile picker to seed
                                                  # build-profiles\amd64\OSDeploy.json (the stock profile)
```

`Initialize-WinPEAP.ps1` **seeds its build profile (`AP.json`) from that stock `OSDeploy.json`**
and only overrides `WinPEStartupProfile` — so `Languages`, `SetTimeZone`, `WinPEMediaScript`,
the driver paths from `Update-OSDeployCoreDrivers`, etc. all carry over. Without a stock profile
to seed from, `Build-OSDeployBoot` fails on an empty `SetTimeZone`.

**About `Invoke-OSDeployHydration`:** it does all of the above **plus** downloading a Windows
Enterprise ESD and importing it as a full Windows OS + WinRE source — but it is *interactive*
(prompts for selections), which breaks a zero-touch setup. This solution doesn't need the OS
import (OSDCloud downloads the Windows image at deploy time), so the steps above are enough.
Run hydration instead only if you specifically want WinRE-based boot media or a guided setup.

This repo does **not** re-implement build-box prep — it layers the Autopilot pieces on top
using the documented `build-profiles` / `winpe-profiles` / `WinPEStartup\Files` surface.

### Tenant

- An **Entra app registration** — see the auth table below

### Authentication modes

| | `ClientSecret` | `DeviceCode` |
|---|---|---|
| Client type | Confidential | Public — *Authentication → Allow public client flows = Yes* |
| Graph permission | `DeviceManagementServiceConfig.ReadWrite.All` — **Application** | same scope — **Delegated** |
| Admin consent | Required | Required |
| Secret on media | Yes (in `config.json`) | **None** — `config.json` holds only Tenant ID + App ID |
| Who needs rights | The app | The signing-in tech — an **Intune RBAC role with the "Enrollment programs" permission** (a scoped custom role is fine; *not* the Intune Administrator directory role) |
| Unattended | Yes | No — interactive sign-in each deployment |

One app registration can carry both permission types if you want a single App ID.

**Why "Allow public client flows"?** Azure treats an app registration as a *confidential*
client by default — it must present a secret or certificate. The device-code grant is a
*public* client flow (it runs where no secret can be protected), so you have to opt the app
in. Without it, the token request fails with `AADSTS7000218` ("request body must contain
client_assertion or client_secret").

**Why not Intune Administrator?** The `importedWindowsAutopilotDeviceIdentities` POST is gated
by the Intune RBAC **Enrollment programs** permission (Create + Read), not by a directory role.
A tech who already enrolls devices generally has an equivalent role, or you grant a narrow
custom Intune role scoped to just that.

Test the app registration from your desk before building:

```powershell
# ClientSecret
$b = @{client_id=$AppId;scope='https://graph.microsoft.com/.default';client_secret=$AppSecret;grant_type='client_credentials'}
$t = (Invoke-RestMethod "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $b).access_token
Invoke-RestMethod 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities' -Headers @{Authorization="Bearer $t"}
```

Empty result = good. 401/403 = fix permissions first.

---

## Part A — repo (one time)

1. Fork the repo (or use it directly). Ensure `Initialize-WinPEAP.ps1`, `Invoke-WinPEAPBuild.ps1`,
   `bootstrap.ps1`, `4kAutopilotHashUpload.ps1`, `Startup.ps1`, `oa3tool.exe`, `oa3.cfg`,
   `input.xml` are on the branch you'll pin (`main`, or your own `stable` / a tag).
2. Verify `https://raw.githubusercontent.com/<you>/WinPEAP/<ref>/Initialize-WinPEAP.ps1` loads (not 404).

`config.json` on the media stores `Repo` + `Ref`, so your booted media pulls from **your** fork
at **your** pinned ref — nothing in the scripts is hardcoded to upstream.

## Part B — initialize the WinPEAP layer

Do the build-box prep first if you haven't (see Prerequisites — modules, ADK, drivers). Then:

```powershell
iwr https://raw.githubusercontent.com/blawalt/WinPEAP/main/Initialize-WinPEAP.ps1 -OutFile Initialize-WinPEAP.ps1

# device code (no secret on media) - prompts for Tenant ID + App ID
.\Initialize-WinPEAP.ps1 -AuthMode DeviceCode -BuildName AP

# or client secret
.\Initialize-WinPEAP.ps1 -AuthMode ClientSecret -TenantId <guid> -AppId <guid> -AppSecret <value> -BuildName AP

# fork: point the media at your repo + pinned ref
.\Initialize-WinPEAP.ps1 -Repo <you>/WinPEAP -Ref stable -AuthMode DeviceCode -BuildName AP
```

`Initialize-WinPEAP.ps1` options:

| Param | Default | Notes |
|---|---|---|
| `-ProfileStyle` | `Fetch` | `Fetch` = profile fetches bootstrap directly. `Loader` = profile calls `X:\Startup.ps1` (use if your build's JSON parser rejects a URL). `Baked` = no runtime fetch (air-gapped). |
| `-AuthMode` | `DeviceCode` | `DeviceCode` or `ClientSecret` |
| `-Repo` | `blawalt/WinPEAP` | repo the media pulls from at runtime (set to your fork); written to `config.json` |
| `-Ref` | `main` | branch/tag the media pulls from at runtime; written to `config.json` |
| `-SeedProfile` | `OSDeploy.json` | build profile to copy as the base for `AP.json` (name in `build-profiles\amd64\` or a full path) |
| `-TimeZone` | *(inherit seed's)* | override `SetTimeZone`, e.g. `'Eastern Standard Time'` |
| `-NoWallpaper` | off | clear `WinPECustomWallpaper` (drop the Recast branding) |

Drivers are **not** an option here — `Update-OSDeployCoreDrivers` (a prereq) populates them and
the stock profile references them; `Initialize-WinPEAP.ps1` inherits that.

### Editing `config.json` directly

`Initialize-WinPEAP.ps1` **merges** — it updates the keys it owns (`Repo`, `Ref`, `TenantId`,
`AppId`, `AuthMode`, `AppSecret`) and leaves anything else you added alone. So put org-specific,
rarely-changing settings straight in `OSDRepo\winpe-startup-files\config.json` and re-run
`Initialize-WinPEAP.ps1` freely. The main one is the Group Tag menu:

```json
"GroupTagMenu": [
  { "label": "1:1 Assigned", "tag": "" },
  { "label": "Shared",       "tag": "Shared" }
]
```

Omit it entirely for a plain `Group Tag (blank = none)` prompt (the community default). A
"Manual entry" option is always appended.

## Part C — build the media

```powershell
. C:\ProgramData\OSDeployCore\OSDRepo\Invoke-WinPEAPBuild.ps1
Invoke-WinPEAPBuild -BuildName AP -Media ISO      # ISO | USB | Both
```

`Initialize-WinPEAP.ps1` set the build profile's `WinPEMediaScript` to `winpeap-media.ps1`,
which runs the stock EN-US language filter **and** copies `winpe-startup-files\` into
`WinPEStartup\Files\` *during* the build — so `Build-OSDeployBoot` produces a correct ISO in
one pass. The wrapper just:

1. `Build-OSDeployBoot` — **select `AP`** at the profile picker (or `-BuildArgs @{ Auto = $true }`
   if `Get-Help Build-OSDeployBoot -Full` shows a non-interactive flag)
2. verifies `bootmedia\WinPEStartup\Files\config.json` landed
3. `-Media USB` / `Both` → `Update-OSDeployBootUSB` (folder picker — **select the build folder**,
   e.g. `26100.1-amd64-AP`; this cmdlet has no path parameter)

For `-Media ISO` there's just the one profile-pick; `bootmedia.iso` already has everything.
**Always build through the wrapper** — a plain `Build-OSDeployBoot` from a profile without the
`winpeap-media.ps1` hook leaves the startup files out.

## Part D — test

### VM first (Gen2, Secure Boot, vTPM, External vSwitch)

Watch the WinPE console: `config.json` found → Group Tag prompt → bootstrap downloaded (not
"using baked") → `Hardware Hash successfully retrieved` → `Device added successfully with ID` →
device shows in **Intune → Devices → Enrollment → Devices** (delete the test entry after) →
workflow applies image → reboot → OOBE.

After OOBE: `Get-ChildItem 'C:\Program Files\WindowsPowerShell\Modules\PSReadLine'` → only `2.0.0`.

VMs can't verify WinPE drivers or OEM activation — that's the hardware pass.

### Real Dell

At the WinPE prompt: `Get-NetAdapter | ? Status -eq 'Up'` and `ipconfig` — confirm an IP. After OOBE:

- `cscript //nologo C:\Windows\System32\slmgr.vbs /dlv` → activated via firmware key
- `C:\Windows\Temp\SetupComplete.log` → contains `OA3 firmware key installed`
- `C:\Windows\Panther\unattend.xml` → gone

## Part E — production

Pick a release model that suits you:

- **Simple:** pin `-Ref main` and just be careful what you push.
- **Safer:** keep a long-lived branch (e.g. `stable`) or cut tags; pin `-Ref stable`. Develop on
  `main`, merge to `stable` only after a green test run so a mid-day push can't reach a tech.

Green run → merge to your pinned ref → re-run `Initialize-WinPEAP.ps1` (writes the new `config.json`
+ profile) → `Invoke-WinPEAPBuild` → re-flash the techs' sticks **once**. Thereafter script logic
ships through GitHub; re-flash only when `config.json`, the profile, or the OA3 binaries change.

---

## Appendix — V2 quirks this kit handles

| Symptom | Cause | Handled by |
|---|---|---|
| PSReadLine loads twice / "Cannot load PSReadline module" | The `default` workflow's **"Update PowerShell Modules -Offline"** task `Save-Module`s every inbox module, dropping PSReadLine 2.4.x beside inbox 2.0.0 | `bootstrap.ps1` step 4 deletes any PSReadLine folder ≠ `2.0.0`. Cleaner long-term fix: `"skip": true` on that task in a custom workflow. |
| Start Menu / console reads "Windows PowerShell 5.1" | Microsoft cosmetic rename in recent 24H2/25H2 LCUs. Not OSDCloud. | Nothing needed — differs only by patch level. |
| OEM / firmware key not activated (V1 did this via `Set-WindowsOEMActivation`) | V2 has no OEM activation step | `bootstrap.ps1` writes `SetupComplete.ps1` calling `InstallProductKey` with `OA3xOriginalProductKey`. Requires deploying the edition the firmware key licenses (Pro). |
| Profile fails to load: *"Invalid array passed in, ',' expected"* | Inline PowerShell with escaped quotes / a URL in the profile JSON breaks the parser | Keep `InvokeMainCommand` a single simple line. `-ProfileStyle Loader` moves all logic into `Startup.ps1`. |
| `Add-WindowsCapability` RSAT → `0x800f0950` on non-domain devices | Device is managed (Autopatch/WUfB) with no policy allowing FoD from Windows Update | Intune Settings Catalog: **"Specify settings for optional component installation and component repair"** → Enabled + "Download… directly from Windows Update instead of WSUS". Assign to the Autopilot group. |

## File reference

| File | Where it runs | Notes |
|---|---|---|
| `Initialize-WinPEAP.ps1` | build box — **elevated pwsh 7** | writes config, profile, `winpeap-media.ps1`, and the seeded build profile |
| `Invoke-WinPEAPBuild.ps1` | build box — **elevated pwsh 7** | runs `Build-OSDeployBoot`, verifies staging, optional USB |
| `winpeap-media.ps1` | build box (during build) | generated; EN-US filter + stages `winpe-startup-files\` into the media |
| `config.json` | media → `X:\` | Repo/Ref/tenant/auth; from `config.sample.json`; **git-ignored** |
| `Startup.ps1` | WinPE — **Windows PowerShell 5.1** | thin loader (only used with `-ProfileStyle Loader`) |
| `bootstrap.ps1` | WinPE — **Windows PowerShell 5.1** | orchestrator — the file you iterate on |
| `4kAutopilotHashUpload.ps1` | WinPE — **Windows PowerShell 5.1** | reusable hash + upload primitive (V1 + V2) |
| `oa3tool.exe` / `oa3.cfg` / `input.xml` | WinPE (`X:\`) | OA3Tool + config |

> WinPE ships Windows PowerShell 5.1, so `bootstrap.ps1` / `Startup.ps1` /
> `4kAutopilotHashUpload.ps1` are kept 5.1-compatible. Only the build-box scripts require 7.
