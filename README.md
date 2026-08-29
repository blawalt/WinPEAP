# WinPEAP — WinPE Autopilot Provisioning

Register a device with **Windows Autopilot during the WinPE phase** — 4k hardware hash via
`OA3Tool`, uploaded through Microsoft Graph — then deploy Windows with OSDCloud so the
device lands Entra‑joined and Intune‑enrolled with minimal touch.

![AP-Provisioning](https://github.com/user-attachments/assets/96b44640-1d2a-431b-8c74-8ba2c71a191f)

## Which guide?

| You are using… | Guide |
|---|---|
| **OSDCloud V2** — the `OSDCloud` module / OSDeployCore, workflow engine, `WinPEStartup` profiles | **[docs/OSDCloud-V2.md](docs/OSDCloud-V2.md)** ← current, a thin Autopilot layer for OSDCloud V2 |
| **OSDCloud V1** — the `OSD` module, `Edit-OSDCloudWinPE`, `-StartOSDCloud` / `-ZTI` | [docs/OSDCloud-V1.md](docs/OSDCloud-V1.md) — still supported |

Both use the same `4kAutopilotHashUpload.ps1`.

## Quick start (V2)

**Prereq:** on the build box, in an **elevated PowerShell 7** session (7.6+ — the OSDeploy V2
tooling is a `pwsh` workflow), install the modules, the ADK, and WinPE drivers:

```powershell
Install-Module -Name OSDCloud                     # OSDCloud V2 engine
Install-Module -Name OSDeploy -AllowPrerelease    # Build-OSDeployBoot etc. (prerelease only on the gallery)
Install-Module -Name OSD                          # baked into the boot image by Build-OSDeployBoot

Install-OSDeploySoftware -Name 'adk-25h2' -Force  # Windows ADK + WinPE add-on
Update-OSDeployCoreDrivers                        # WinPE drivers
Build-OSDeployBoot                                # run once, Cancel the picker to seed the stock build profile
```

(`Invoke-OSDeployHydration` does all this plus a full Windows OS import, but it's interactive —
see [docs/OSDCloud-V2.md](docs/OSDCloud-V2.md) for why the steps above are enough and stay zero-touch.)

Then add the WinPEAP Autopilot layer and build:

```powershell
iwr https://raw.githubusercontent.com/blawalt/WinPEAP/main/Initialize-WinPEAP.ps1 -OutFile Initialize-WinPEAP.ps1
.\Initialize-WinPEAP.ps1 -AuthMode DeviceCode      # prompts for Tenant ID + App ID, no secret on media

. C:\ProgramData\OSDeployCore\OSDRepo\Invoke-WinPEAPBuild.ps1
Invoke-WinPEAPBuild -BuildName AP -Media USB
```

### Fork &amp; pin your own ref

The booted media pulls `bootstrap.ps1` / `4kAutopilotHashUpload.ps1` from GitHub at runtime.
**Which repo and which branch/tag** are stored in `config.json` on the media (never in git),
written by `Initialize-WinPEAP.ps1`:

```powershell
# fork the repo, then:
iwr https://raw.githubusercontent.com/<you>/WinPEAP/main/Initialize-WinPEAP.ps1 -OutFile Initialize-WinPEAP.ps1
.\Initialize-WinPEAP.ps1 -Repo <you>/WinPEAP -Ref stable -AuthMode DeviceCode
```

Pin `-Ref` to a branch or tag **you** control (`main`, your own `stable`, a version tag) so a
mid-day upstream push can't reach a tech mid-deployment. Changing the ref later = re-run
`Initialize-WinPEAP.ps1 -Ref <new>` and rebuild the media.

See [docs/OSDCloud-V2.md](docs/OSDCloud-V2.md) for the full walkthrough, the app‑registration
checklist, and the VM → hardware test plan.

## Repo contents

| File | Used by | Purpose |
|---|---|---|
| `Initialize-WinPEAP.ps1` | V2 | Layers the Autopilot bits (config, profile, startup files, build profile) onto a prepared OSDeployCore box |
| `Invoke-WinPEAPBuild.ps1` | V2 | Wrapper: `Build-OSDeployBoot` → stage startup files → package ISO/USB |
| `bootstrap.ps1` | V2 | Runtime orchestrator: hash upload → OSDCloud workflow → write `SetupComplete` |
| `Startup.ps1` | V2 | Optional thin WinPE launcher (fetches `bootstrap.ps1`) |
| `4kAutopilotHashUpload.ps1` | V1 + V2 | Generate 4k hash in WinPE, upload to Autopilot (client‑secret **or** device‑code auth) |
| `oa3tool.exe`, `oa3.cfg`, `input.xml` | V1 + V2 | OA3Tool + config for hash generation |
| `config.sample.json` | V2 | Template for the media‑side `config.json` (never commit a real one) |

## Authentication modes

| | `ClientSecret` | `DeviceCode` |
|---|---|---|
| Client type | Confidential | Public (Allow public client flows = Yes) |
| Graph permission | `DeviceManagementServiceConfig.ReadWrite.All` — **Application** | same scope — **Delegated** |
| Secret on media | Yes | **None** |
| Who needs rights | The app | The signing‑in tech — Intune RBAC "Enrollment programs" permission (not Intune Administrator) |
| Unattended | Yes | No — interactive sign‑in each run |

## ⚠️ VM testing

Self‑Deploying / Pre‑Provisioning Autopilot profiles require hardware TPM 2.0 attestation and
will fail on most VMs. To test on a VM, assign the imported device a **User‑Driven** profile.
Physical hardware works with any profile.

---

4k‑hash‑in‑WinPE technique adapted from
[Mike's MDM blog](https://mikemdm.de/2023/01/29/can-you-create-a-autopilot-hash-from-winpe-yes/).
