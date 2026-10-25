# Compatibility

What runs where, and what each `not-supported` actually means.

## Operating systems

| OS family | Detected as | Engine | Notes |
|---|---|---|---|
| Debian, Ubuntu, Mint, Pop, Kali | `linux` | `bin/sysopt` | systemd assumed only for the power-daemon guard; without systemd the guard is inert and nothing else changes |
| Fedora, RHEL, CentOS, Rocky, Alma | `linux` | `bin/sysopt` | `firefox_policy` writes `/etc/firefox/policies/policies.json`, which Fedora's Firefox reads |
| Arch, Manjaro, Endeavour | `linux` | `bin/sysopt` | `policies.json` path is `/etc/firefox/policies/`, created if absent |
| openSUSE, SLES | `linux` | `bin/sysopt` | uses `/etc/sysctl.d/`; `sysctl --system` picks the drop-in up |
| Alpine, postmarketOS | `linux` | `bin/sysopt` | tested with `busybox sh`; `sysctl -p <file>` fallback when `--system` is absent |
| ChromeOS (Crostini, Debian container) | `chromebook` | `bin/sysopt` | `hosts` edits inside the container affect the container, not Chrome itself; `swappiness` is refused |
| macOS 12+ | `darwin` | `bin/sysopt` | `firefox_policy` not supported — Firefox on macOS reads policy from a JSON file, but the path is version-dependent and the failure mode is silent; `report_power` reports `pmset` ownership |
| FreeBSD 13+, OpenBSD 7+, NetBSD 9+, DragonFly | `bsd` | `bin/sysopt` | `/etc/hosts` and Firefox profiles are the same layout; no sysctl action |
| Windows 10 1809+, 11, Server 2019+ | `windows` | `bin/sysopt.ps1` | PowerShell 5.1 or 7; see below |
| Termux (Android) | `termux` | `bin/sysopt` | `report_power` only; `/etc` is not writable and there is no sysctl |
| Solaris / illumos, Haiku | `solaris` / `haiku` | `bin/sysopt` | detection only; every action reports `not-supported` |
| WSL2 | `linux` | `bin/sysopt` | the Linux side of WSL, which is a real Linux; the Windows side needs the PowerShell port |

## Architectures

Reported, never assumed:

`x86_64` · `x86_32` (i686, i386) · `aarch64` · `arm32` (armv6l, armv7l, armv8l in
32-bit mode) · `ppc64` · `ppc64le` · `s390x` · `riscv64` · `loongarch64` ·
`mips64` (both endiannesses) · `mips32`

Nothing in the code branches on word size, endianness or page size. The arch
string appears in `detect` and `version` output so that a bug report contains
it; it never changes behaviour. `uname -m` is the only source, with the raw
string kept next to the normalised one.

## Action × platform

| Action | linux | chromebook | darwin | bsd | termux | windows |
|---|---|---|---|---|---|---|
| `hosts_block` | ✅ | ✅ | ✅ | ✅ | — | ✅ |
| `firefox_userjs` | ✅ | ✅ | ✅ | ✅ | — | ✅ |
| `firefox_policy` | ✅ | ✅ | — | — | — | — |
| `swappiness` | ✅ | — | — | — | — | — |
| `report_power` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

### Why each `—` is a `—`

- **`hosts_block` on Termux** — Android's resolver does not read `/etc/hosts`,
  and the filesystem is read-only without root. Blocking there is a fiction.
- **`firefox_userjs` on Termux** — no Firefox profile layout; Fenix stores
  prefs in a compiled `omni.ja`/datastore, not a `user.js`.
- **`firefox_policy` outside Linux/ChromeOS** — see the macOS row above; on the
  BSDs the policy file location is build-dependent and Mozilla's documented
  mechanism is `policies.json` under the install directory, which differs per
  package. Guessing produces a file nobody reads.
- **`firefox_policy` on Windows** — Firefox reads enterprise policy from
  `HKLM\SOFTWARE\Policies\Mozilla\Firefox`. Writing that by script is possible
  but the supported path is the Mozilla ADMX templates via Group Policy, and a
  half-merged registry tree is a support nightmare. Refused, with the reason.
- **`swappiness` outside Linux** — macOS has no `vm.swappiness`; the BSDs call it
  `vm.swap_enabled`-adjacent knobs with different semantics; ChromeOS runs its
  own kernel policy from the host. Writing a drop-in that nothing reads is worse
  than saying no.

## Windows specifics

- **PowerShell 5.1 and 7 both supported.** No `??`, no ternary, no `-Parallel`.
- **The hosts action needs elevation.** Without it, the action reports the
  requirement and returns 1 rather than writing a partial file.
- **Firefox policies** are read from `%APPDATA%\Mozilla\Firefox\Profiles\*`.
  A profile is recognised by `prefs.js` or `times.json`.
- **State** lives in `%LOCALAPPDATA%\sysopt` (`$env:SYSOPT_STATE` overrides).
- **No registry writes.** The Windows port manages two files, both with markers
  and backups. Windows' own settings are left where Microsoft put them.

## Testing without touching the machine

Both engines have the same seam, and it is the only reason the suites can run in
CI:

| Engine | Seam | Paths affected |
|---|---|---|
| `bin/sysopt` | `--root DIR` | every absolute path (`/etc/hosts`, `/etc/sysctl.d/…`) |
| `bin/sysopt.ps1` | `$env:SYSOPT_ROOT` | the hosts file and the Firefox profile root |

With the seam set, elevation is not required, the power-daemon guard still
runs, and nothing outside the staged directory can be read or written. On
Windows, an unstaged run needs an elevated shell for the hosts action.

## Minimum versions

| Requirement | Why |
|---|---|
| `sh` with a `local` builtin (dash, ash, bash, ksh, mksh, zsh, macOS sh) | scoping; probed at load, and sysopt exits 3 with a clear message if absent |
| `awk`, `sed`, `grep`, `mktemp`, `cmp`, `cp`, `mv`, `chmod`, `sort`, `tr`, `head`, `cut` | POSIX userland, present on every target |
| `jq` | only for `firefox_policy`; the action refuses rather than half-merging JSON |
| `systemctl` | only for the power-daemon guard; absence makes the guard inert, not fatal |
| `curl` / `wget` | **never used.** Nothing in sysopt downloads anything at runtime |

## What "tested" means here

- Linux: CI runs the full suite under `dash`, `bash` and `busybox sh`, on
  x86_64 and aarch64.
- macOS: CI runs the full suite with `/bin/sh` (bash 3.2 in POSIX mode).
- Windows: CI parses `bin/sysopt.ps1` with the PowerShell parser and runs the
  read-only commands (`detect`, `list`, `plan`, `status`, `doctor`).
- Everything else in the table above is **implemented and reasoned, not
  continuously tested**. If you run it on a BSD or a RISC-V box, an issue with
  `sysopt detect` output is a genuinely useful contribution.
