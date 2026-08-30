> For the legacy `OSD` module (V1) see [OSDCloud-V1.md](OSDCloud-V1.md).

# WinPE Autopilot Provisioning — OSDCloud V2

Register a device with **Windows Autopilot while it's still in WinPE** — generate the 4k
hardware hash with `OA3Tool`, upload it through Microsoft Graph — then let OSDCloud V2 deploy
Windows. The device reaches OOBE already known to Autopilot, so it goes straight into
Entra join + Intune enrollment with minimal touch.

OSDCloud V2 (the `OSDCloud` module + OSDeploy's `Build-OSDeployBoot`) replaced V1's script
wrapper with a workflow engine and JSON `WinPEStartup` profiles. V1 conveniences the Autopilot
flow needs — a `SetupComplete` builder, OEM key activation — aren't in V2, so this kit adds them.

---

## How it works

```
BUILD BOX  (elevated PowerShell 7)
  Initialize-WinPEAP.ps1  writes ->  C:\ProgramData\OSDeployCore\OSDRepo\
       winpe-startup-files\   config.json, oa3tool.exe, PCPKsp.dll, oa3.cfg, input.xml,
                              bootstrap.ps1, 4kAutopilotHashUpload.ps1, Startup.ps1
       winpe-profiles\Autopilot.json     the WinPEStartup profile (one-line launcher)
       winpeap-media.ps1                 stages winpe-startup-files INTO the media during the build
       build-profiles\amd64\AP.json      seeded from the stock profile; WinPEStartupProfile +
                                         WinPEMediaScript overridden
  Invoke-WinPEAPBuild  ->  Build-OSDeployBoot  ->  bootmedia.iso  (files already inside)

BOOT MEDIA  (a small number of technicians hold it)
  X:\config.json          Repo / Ref / TenantId / AppId / AuthMode [/ AppSecret] [/ GroupTagMenu]
  X:\oa3tool.exe, PCPKsp.dll, oa3.cfg, input.xml   OA3Tool 4k-hash deps  (must be on the media)
  X:\bootstrap.ps1, 4kAutopilotHashUpload.ps1, Startup.ps1   offline fallback copies

GITHUB  <Repo> @ <Ref>   (public repo or your fork; no secrets)
  bootstrap.ps1              orchestrator - fetched at boot
  4kAutopilotHashUpload.ps1  hash + Graph upload - fetched by bootstrap
```

**What lives where, and why:**

| | Where | Changing it means |
|---|---|---|
| Script logic (`bootstrap.ps1`, `4kAutopilotHashUpload.ps1`) | **GitHub**, pinned to a ref | `git push` — no media rebuild |
| Tenant / app / auth / menu (`config.json`) | **media only** (never in git) | edit `config.json` + rebuild media |
| OA3 binaries, offline fallbacks | **media only** (baked) | rebuild media |
| The WinPEStartup profile | **media only** (`Initialize-WinPEAP.ps1` regenerates it) | re-run `Initialize-WinPEAP.ps1` + rebuild |

## Boot flow

```
WinPE boots -> network comes up -> the WinPEStartup profile runs its one line
  -> fetches bootstrap.ps1 from <Repo>@<Ref>  (falls back to the baked X:\bootstrap.ps1)
  -> bootstrap.ps1:
       reads X:\config.json
       prompts for a Group Tag  (plain prompt, or a menu if config.json has GroupTagMenu)
       1) 4kAutopilotHashUpload.ps1:  register PCPKsp.dll -> OA3Tool -> 4k hash -> Graph import
          (DeviceCode: the operator signs in at microsoft.com/devicelogin here)
       2) OSDCloud V2 workflow:  download + apply the Windows image
       3) writes C:\Windows\Setup\Scripts\SetupComplete.{cmd,ps1}
       4) removes the workflow's duplicate PSReadLine (keeps inbox 2.0.0)
       5) copies X:\Windows\Temp\*.log to any media \OSDCloudLogs folder
  -> reboot
Windows setup -> specialize -> SetupComplete.cmd runs (OEM activation, unattend cleanup) -> OOBE / Autopilot
```

`SetupComplete.cmd` is native Windows — if the file exists it runs once, as SYSTEM, at the end
of setup, **before** the Autopilot ESP. It's the right place for machine prep (OEM key, cleanup);
app installs stay Intune's job.

---

## Prerequisites — build box

Everything runs on the build box in an **elevated PowerShell 7** session (`pwsh`, 7.6+). Windows
PowerShell 5.1 is not supported for the build side.

### 1. Modules — do these in one session, then open a *fresh* `pwsh`

```powershell
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted    # once - stops the "Untrusted repository" prompt

Install-Module OSDCloud, OSD -Force -SkipPublisherCheck -Scope AllUsers
Install-Module OSDeploy -AllowPrerelease -Force -Scope AllUsers
```

Then **close the session and start a new `pwsh`.** `Install-Module` doesn't refresh the running
session's module cache, so `Build-OSDeployBoot` in the same session can fail its "OSDCloud module
… or newer is required" check even though the files are on disk. A fresh session reads from disk
and is correct. (In-session alternative: `Import-Module OSDCloud, OSDeploy, OSD -Force`.)

> The **OSDeploy module is a time-limited preview** — it warns on load (e.g. *"expires 2026-08-31"*)
> and stops working after that date. Run `Update-Module OSDeploy -AllowPrerelease -Force` before
> each build session.

### 2. ADK, drivers, and a stock build profile (fresh session)

```powershell
Install-OSDeploySoftware -Name 'adk-25h2' -Force   # Windows ADK + WinPE add-on
Update-OSDeployCoreDrivers                          # WinPE NIC / storage / wifi -> winpe-drivers\amd64\*
Build-OSDeployBoot                                  # run once, press Cancel at the profile picker
```

That last `Build-OSDeployBoot` + **Cancel** creates `build-profiles\amd64\OSDeploy.json` — the
stock profile with all the fields `Build-OSDeployBoot` requires (`Languages`, `SetTimeZone`,
`WinPEMediaScript`, and the driver paths from `Update-OSDeployCoreDrivers`). `Initialize-WinPEAP.ps1`
**copies** it as the base for `AP.json` and only overrides two keys. Without a stock profile to
seed from, `Build-OSDeployBoot` later fails on an empty `SetTimeZone`.

> **On a VM build box:** `Install-OSDeploySoftware -Name 'adk-25h2'` currently pulls a `hyperv`
> prerequisite; `Test-IsVM` then marks the ADK `NotSupported` and skips it. The ADK doesn't need
> the Hyper-V *feature* and `Build-OSDeployBoot` auto-detects any installed ADK, so either install
> the ADK another way or work around that check until it's fixed upstream.

> `Invoke-OSDeployHydration` does modules + ADK + drivers + a full Windows OS/WinRE import in one
> command — but it's **interactive** (prompts for selections), which breaks a zero-touch setup.
> This kit doesn't need the OS import (OSDCloud downloads the image at deploy time), so the steps
> above are enough. Use hydration only if you want WinRE-based boot media or a guided setup.

---

## Prerequisites — Entra app registration

| | `ClientSecret` | `DeviceCode` (default) |
|---|---|---|
| Client type | Confidential | **Public** — *Authentication → Allow public client flows = Yes* |
| Graph permission | `DeviceManagementServiceConfig.ReadWrite.All` — **Application** | same scope — **Delegated** |
| Admin consent | Required | Required |
| Secret on media | Yes, in `config.json` | **None** — `config.json` has only Tenant ID + App ID |
| Who needs rights | the app | the tech who signs in |
| Unattended | Yes | No — interactive sign-in per deployment |

One app registration can hold both permission types if you want a single App ID.

**Why "Allow public client flows"?** Azure treats an app as a *confidential* client by default
(must present a secret). Device code is a *public* client flow — it runs where no secret can be
protected — so you opt the app in. Without it the token request fails with `AADSTS7000218`.

**Why not Intune Administrator?** The `importedWindowsAutopilotDeviceIdentities` call is gated by
the Intune RBAC **Enrollment programs** permission (Create + Read), not a directory role. A tech
who already enrolls devices generally has an equivalent role; otherwise grant a narrow custom
Intune role scoped to just that.

**Test it from your desk before building** (ClientSecret shown):

```powershell
$b = @{client_id=$AppId;scope='https://graph.microsoft.com/.default';client_secret=$AppSecret;grant_type='client_credentials'}
$t = (Invoke-RestMethod "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $b).access_token
Invoke-RestMethod 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities' -Headers @{Authorization="Bearer $t"}
```

Empty result = good. 401/403 = fix permissions first.

---

## Runbook — build box to media

### 1. Repo (one time)

Use `blawalt/WinPEAP` directly, or fork it. The scripts have no upstream hard-coding — the media's
`config.json` carries `Repo` + `Ref`, so your booted media pulls from *your* repo at *your* pinned
branch/tag.

Verify your ref serves the file (not a 404):
`https://raw.githubusercontent.com/<repo>/<ref>/Initialize-WinPEAP.ps1`

### 2. Initialize (fresh elevated `pwsh`, after the prereqs)

```powershell
iwr https://raw.githubusercontent.com/blawalt/WinPEAP/main/Initialize-WinPEAP.ps1 -OutFile Initialize-WinPEAP.ps1
.\Initialize-WinPEAP.ps1 -AuthMode DeviceCode
#   prompts: Tenant ID, App ID   ->   writes winpe-startup-files\config.json + the profile + AP.json
```

| Param | Default | |
|---|---|---|
| `-AuthMode` | `DeviceCode` | `DeviceCode` or `ClientSecret` (adds `-TenantId -AppId -AppSecret`) |
| `-Repo` | `blawalt/WinPEAP` | set to your fork; written to `config.json` |
| `-Ref` | `main` | branch/tag the media pulls from at runtime; written to `config.json` |
| `-BuildName` | `AP` | build-profile name / media suffix |
| `-ProfileStyle` | `Fetch` | `Fetch` = profile fetches bootstrap directly. `Loader` = profile calls `X:\Startup.ps1` (use if a build's JSON parser rejects a URL). `Baked` = no runtime fetch (air-gapped). |
| `-SeedProfile` | `OSDeploy.json` | build profile to copy as the base for `AP.json` |
| `-TimeZone` | *(inherit seed's)* | override `SetTimeZone`, e.g. `'Eastern Standard Time'` |
| `-NoWallpaper` | off | clear `WinPECustomWallpaper` |

### 3. Optional — hand-edit `config.json`

`Initialize-WinPEAP.ps1` **merges** `config.json`: it updates the keys it owns
(`Repo`, `Ref`, `TenantId`, `AppId`, `AuthMode`, `AppSecret`) and leaves anything else you added
in place. So put org-specific settings straight into
`C:\ProgramData\OSDeployCore\OSDRepo\winpe-startup-files\config.json` and re-run freely.

The one most people want is the Group Tag menu:

```json
"GroupTagMenu": [
  { "label": "1:1 Assigned", "tag": "" },
  { "label": "Shared",       "tag": "Shared" }
]
```

Omit it entirely for a plain `Group Tag (blank = none)` prompt (the default). A "Manual entry"
option is always appended.

### 4. Build

```powershell
. C:\ProgramData\OSDeployCore\OSDRepo\Invoke-WinPEAPBuild.ps1
Invoke-WinPEAPBuild -BuildName AP -Media ISO        # ISO | USB | Both
```

- `Build-OSDeployBoot` pops a **profile picker** — select **`AP`**. (If `Get-Help Build-OSDeployBoot -Full`
  shows a non-interactive flag, pass it: `Invoke-WinPEAPBuild -BuildArgs @{ Auto = $true }`.)
- `winpeap-media.ps1` (wired to `WinPEMediaScript`) runs the EN-US filter and copies
  `winpe-startup-files\` into the media **during** the build, so the ISO is correct in one pass.
- `-Media USB` / `Both` also runs `Update-OSDeployBootUSB` — a **folder picker**; select the build
  folder (e.g. `26100.1-amd64-AP`).

Output: `C:\ProgramData\OSDeployCore\boot\26100.1-amd64-AP\bootmedia.iso` — write it to USB with
Rufus (GPT/UEFI) or Ventoy.

### 5. Verify the stick

Mount it and confirm `\WinPEStartup\Files\config.json` and `Startup.ps1` are present with the
right values.

---

## Fork & pin — release model

`prod` is nothing special — just a branch you pin your org's media to. Pick a model:

- **Simple:** pin `-Ref main`, be careful what you push.
- **Safer:** keep a `stable` branch or cut tags; develop on `main`, merge to `stable` only after a
  green test so a mid-day push can't reach a tech mid-deployment.

Moving your media to a new ref = re-run `Initialize-WinPEAP.ps1 -Ref <new>` (rewrites `config.json`
and the profile, keeps your `GroupTagMenu`) + rebuild. After that, script changes ship through
`git push` to that ref — no rebuild — until `config.json`, the profile, or the OA3 binaries change.

On a **brand-new build box**, re-add any hand-edited `config.json` keys (`GroupTagMenu`, …) — they
live only on the media and in your build box, never in git. Keep the snippet in an internal note.

---

## Test plan

### VM first — Hyper-V Gen2, Secure Boot on, **vTPM on**, External vSwitch, empty disk

Boot the ISO. Watch the WinPE console for, in order:

- `Source: <repo> @ <ref>` and the Group Tag prompt
- `bootstrap.ps1` fetched from GitHub (not `using baked X:\bootstrap.ps1`)
- `Hardware Hash successfully retrieved`
- DeviceCode: the `microsoft.com/devicelogin` code — sign in on another device
- `Device added successfully with ID …` → `Import completed successfully!`
- the device appears in **Intune → Devices → Enrollment → Devices** (delete the test entry after)
- the OSDCloud workflow downloads + applies the image, then reboots

Assign the imported VM a **User-Driven** Autopilot profile — VMs can't attest for Self-Deploying /
Pre-Provisioning. After OOBE:

- `Get-ChildItem 'C:\Program Files\WindowsPowerShell\Modules\PSReadLine'` → only `2.0.0`
- `C:\Windows\Panther\unattend.xml` → gone
- `C:\Windows\Temp\SetupComplete.log` → has the start/done timestamps (no OA3 key line on a VM)

### Then a real device (Dell)

Same, plus:

- at the WinPE prompt: `Get-NetAdapter | ? Status -eq 'Up'` and `ipconfig` → confirm an IP (drivers)
- after OOBE: `cscript //nologo C:\Windows\System32\slmgr.vbs /dlv` → activated via the firmware key
- `C:\Windows\Temp\SetupComplete.log` → contains `OA3 firmware key installed`
- Autopilot ESP completes to the desktop

---

## Gotchas

| Symptom | Cause / fix |
|---|---|
| `Build-OSDeployBoot`: *"OSDCloud module … or newer is required"* right after installing it | `Install-Module` didn't refresh the session's module cache. Open a **fresh `pwsh`** (or `Import-Module OSDCloud -Force`). Do all installs in one session, all build steps in another. |
| OSDeploy warns it *"expires"* / stops working | The preview module is time-limited. `Update-Module OSDeploy -AllowPrerelease -Force`. |
| `Install-OSDeploySoftware -Name 'adk-25h2'` → ADK `NotSupported` on a VM | Spurious `hyperv` prerequisite + `Test-IsVM`. The ADK doesn't need the Hyper-V feature. Install the ADK another way; report upstream. |
| *"Untrusted repository"* prompt on every `Install-Module` | `Set-PSRepository -Name PSGallery -InstallationPolicy Trusted` once. |
| `Initialize-WinPEAP.ps1`: *"No stock build profile … to seed from"* | Run `Build-OSDeployBoot` once and press **Cancel** at the picker to create `OSDeploy.json`. |
| `Build-OSDeployBoot`: *"No WinRE source … Defaulting to Windows ADK WinPE"* | Expected — you skipped the OS import. Fine for wired deployments. Import WinRE (`Import-OSDeployCoreOS`) only if you need better Wi-Fi/driver coverage in WinPE. |
| GUI pickers during the build | `Build-OSDeployBoot` (select `AP`) and `Update-OSDeployBootUSB` (select the build folder) have no path parameter. `-Media ISO` needs only the one profile-pick. |
| `Import status: unknown. Waiting…` then `Import completed successfully!` | Normal — the import queues before it flips to complete. |
| Profile fails to load: *"Invalid array passed in, ',' expected"* | Inline PowerShell with escaped quotes / a URL broke the profile-JSON parser. Use `-ProfileStyle Loader` (all logic moves to `Startup.ps1`). |
| PSReadLine loads twice / *"Cannot load PSReadline module"* | The `default` workflow's *"Update PowerShell Modules -Offline"* task drops a newer PSReadLine beside inbox 2.0.0. `bootstrap.ps1` step 4 deletes the extra. |
| Start Menu / console says *"Windows PowerShell 5.1"* | Microsoft cosmetic rename in recent 24H2/25H2 LCUs. Not OSDCloud. |
| `Add-WindowsCapability` RSAT → `0x800f0950` on non-domain devices | Managed device with no policy allowing FoD from Windows Update. Intune Settings Catalog: *"Specify settings for optional component installation and component repair"* → Enabled + "Download… directly from Windows Update instead of WSUS". |

---

## File reference

| File | Where it runs | Notes |
|---|---|---|
| `Initialize-WinPEAP.ps1` | build box — **elevated pwsh 7** | writes `config.json`, the profile, `winpeap-media.ps1`, the seeded build profile |
| `Invoke-WinPEAPBuild.ps1` | build box — **elevated pwsh 7** | runs `Build-OSDeployBoot`, verifies staging, optional USB |
| `winpeap-media.ps1` | build box, during the build | generated; EN-US language filter + stages `winpe-startup-files\` into the media |
| `config.json` | media → `X:\` | Repo / Ref / tenant / auth / GroupTagMenu; from `config.sample.json`; **git-ignored** |
| `Startup.ps1` | WinPE — **Windows PowerShell 5.1** | thin loader; only used with `-ProfileStyle Loader` |
| `bootstrap.ps1` | WinPE — **Windows PowerShell 5.1** | orchestrator — the file you iterate on |
| `4kAutopilotHashUpload.ps1` | WinPE — **Windows PowerShell 5.1** | reusable hash + Graph upload (V1 + V2); `-AuthMode ClientSecret\|DeviceCode` |
| `oa3tool.exe` / `oa3.cfg` / `input.xml` | WinPE (`X:\`) | OA3Tool + config for the 4k hash |

WinPE ships Windows PowerShell 5.1, so `bootstrap.ps1` / `Startup.ps1` / `4kAutopilotHashUpload.ps1`
are kept 5.1-compatible. Only the build-box scripts require PowerShell 7.

---

4k-hash-in-WinPE technique adapted from
[Mike's MDM blog](https://mikemdm.de/2023/01/29/can-you-create-a-autopilot-hash-from-winpe-yes/).
