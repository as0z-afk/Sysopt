# The Windows side: a config you can read, not a pipe you cannot

sysopt's Windows engine is `bin/sysopt.ps1`. It does the same four things the
POSIX core does — plan, apply, verify, revert — with the same seven rules, and
it does them natively. No WSL, no MSYS, no bash shim.

This page covers the part sysopt deliberately does *not* automate: the wider
"Windows tweaks" ecosystem, and specifically
[WinUtil](https://github.com/ChrisTitusTech/winutil).

---

## Why there is no `irm https://… | iex` in this repo

A pipe from the internet into `iex` executes whatever the server sends at that
moment. You cannot diff it, you cannot pin it, and next month the same command
runs different code. That is not a property a "fail-safe" tool can have, so
sysopt has no such install path — not in the README, not in CI, not behind a
flag.

Neither is activation. `massgrave.dev` / `get.activated.win` and everything
like them work by defeating Windows' licence check. sysopt will not call them,
bundle them, or wrap them. See [activation](#activation-is-not-a-tuning-step)
below for the paths that are legitimate.

What you get instead is a **file**. You can open it, diff it against the last
version, and import it yourself:

```
contrib/winutil/sysopt-config.json
```

---

## What is in the config

The file is a WinUtil **export-format** configuration: the same shape WinUtil
itself produces from *Settings cog → Export*. Four selections, all reversible:

| Key | What it does | How to undo |
|---|---|---|
| `WPFTweaksRestorePoint` | Creates a System Restore point before anything else in the run — a rollback you can actually use | Delete the point in *System Restore* if you do not want it |
| `WPFTweaksTelemetry` | Sets `AllowTelemetry=0` under `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection` | Set the value back to `1`, or delete the policy key |
| `WPFTweaksConsumerFeatures` | Stops Windows from silently installing promoted Store apps | Re-enable the *CloudContent* policy values, or reinstall the app from the Store |
| `WPFTweaksDeliveryOptimization` | Limits update delivery to your own network instead of the internet at large | Reset the *Delivery Optimization* settings in Windows Update |

`Install` and `Features` are empty **on purpose**. sysopt does not install
software, and it does not turn Windows features on or off — both are decisions
with consequences a tuning tool should not take on your behalf.

Deliberately **not** included, though they exist upstream:

- anything that removes AppX packages or user data (`WPFTweaksDebloat`,
  `WPFTweaksDeleteTempFiles`, disk-cleanup tweaks) — sysopt does not delete
  things it cannot restore;
- the bulk services tweak (`WPFTweaksServices`) — it disables services by the
  dozen, and the failure mode shows up weeks later as something that quietly
  stopped working;
- every DNS / proxy / firewall reconfiguration — sysopt does not point your
  traffic at a server you did not choose;
- anything that turns off a security feature (Defender, SmartScreen, UAC,
  Memory Integrity).

## How to use it

1. **Read the four IDs above.** They are the whole change.
2. Start WinUtil the way *you* normally do, from *its* instructions, and let it
   run. (sysopt does not tell you to pipe a URL into `iex`; if you are fine with
   it, that is your call to make, not a command this repo hands you.)
3. Open the gear icon → **Import**, pick
   `contrib/winutil/sysopt-config.json`.
4. Look at what got checked in the UI. If a checkbox you did not expect is
   ticked, uncheck it. That is the review step, and it is the point.
5. Press **Run Tweaks**.
6. **Export your own config afterwards** (gear → Export) and keep it. That file
   is the record of what your machine actually received, in your WinUtil
   version's own vocabulary.

> Versions differ. If your WinUtil rejects the file, export a config from your
> own copy first and compare the shape with this one — the section names
> (`Install`, `Tweaks`, `Features`) and the `WPFTweaks…` ID spelling are what
> matter. Never hand-edit a config to make an error message go away; rebuild it
> from your export.

## The six tweaks sysopt applies itself

`bin/sysopt.ps1` implements these natively — data, not a downloaded script. Each
captures the previous value before writing, so `revert` puts back exactly what
was there, including deleting a value that did not exist.

| id | key | what it changes |
|---|---|---|
| `wu_telemetry` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection` → `AllowTelemetry = 0` | no optional diagnostic data |
| `wu_consumer` | `HKLM\…\CloudContent` → `DisableWindowsConsumerFeatures = 1` | no silently installed promoted apps |
| `wu_delivery_lan` | `HKLM\…\DeliveryOptimization` → `DODownloadMode = 1` | updates delivered inside your network only |
| `wu_bing_search` | `HKCU\…\CurrentVersion\Search` → `BingSearchEnabled = 0` | no web results in Start search |
| `wu_tips` | `HKCU\…\ContentDeliveryManager` → `SoftLandingEnabled = 0` | no tips and suggestion popups |
| `wu_sync_ads` | `HKCU\…\Explorer\Advanced` → `ShowSyncProviderNotifications = 0` | no Microsoft 365 ads in File Explorer |

```powershell
.\bin\sysopt.ps1 plan                              # what would change
.\bin\sysopt.ps1 apply -Only wu_telemetry -Apply    # one of them
.\bin\sysopt.ps1 verify
.\bin\sysopt.ps1 revert -All -Apply                # back exactly as before
```

Every HKLM one needs an elevated shell and says so instead of half-failing.
None of them touches a service, an installed app, a firewall rule, Defender,
UAC or Windows Update itself.

## What sysopt does on its own, on Windows

```powershell
.\bin\sysopt.ps1 detect      # what this box is, what is supported here
.\bin\sysopt.ps1 plan        # the hosts block and the Firefox user.js block
.\bin\sysopt.ps1 apply -Apply
.\bin\sysopt.ps1 verify
.\bin\sysopt.ps1 revert -All -Apply
```

Those are the two actions with a reliable, byte-level undo: the hosts file and
the Firefox profile `user.js`. Both keep their managed block inside markers, so
removing the block is a complete revert — and the backup file under
`%LOCALAPPDATA%\sysopt\backups\` is the authoritative copy.

`firefox_policy` reports `not-supported` on Windows. Firefox reads enterprise
policy from the registry there (`HKLM\SOFTWARE\Policies\Mozilla\Firefox`), not
from a JSON file, and the supported way to write that is the Mozilla ADMX
templates in Group Policy — not a script inventing registry values.

---

## Activation is not a tuning step

sysopt does not activate Windows, and neither should a tool that promises a
clean revert: licence state is not something you can back up and put back.

Legitimate paths, by edition:

- **You bought a licence** — activate under *Settings → System → Activation*;
  if it fails, `slmgr /dlv` shows the error code Microsoft's support will ask for.
- **Your machine came with Windows** — the key is embedded in firmware; the
  digital licence follows the hardware and activates on reinstall of the same
  edition.
- **You are a student, a charity, or a small business** — Microsoft's own
  programmes (Azure for Students, Microsoft 365 Education, non-profit grants)
  issue real keys.
- **You want to run Windows without activating** — that is allowed by the
  licence terms, with cosmetic limits. Nothing breaks; nothing needs patching.
- **You do not want to pay at all** — use Linux. sysopt runs there too, and
  there is nothing to activate.

What sysopt will not do is pretend that defeating the check is a system
optimisation. It is not; it is a different thing entirely, and it is out of
scope for this repository.

---

## If you want the rest of WinUtil's tweaks

Use WinUtil. It is a good tool, actively maintained, and its tweaks are
documented in its own repo. sysopt's contribution is the shape of the decision:
read the config, import it yourself, keep the export, know the undo before you
press the button.

That habit is portable. It is the same one `sysopt plan` asks of you on Linux.
