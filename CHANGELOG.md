# Changelog

Everything notable in this project. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow semver.

## [1.1.0] — 2026-10-25

### Added

- **Catalog** (`contrib/catalog/actions.tsv` + `sysopt catalog`). Data, not code:
  it decides which actions are offered and which are retired. A retired action
  still reverts anything this machine already has — the manifest, not the
  catalog, owns the way back.
- **Offline updater** (`sysopt update --from DIR`). Stages a candidate tree,
  proves it parses, runs it against a throwaway `--root`, prints the catalog
  diff (`+ new action` / `- withdrawn`), swaps atomically, keeps the previous
  tree, and rolls back automatically if the new version does not start.
  `sysopt update --rollback --apply` undoes a swap. No URL, no `curl`, no pipe.
- **Windows tweak pack** — six registry values as data (`wu_telemetry`,
  `wu_consumer`, `wu_delivery_lan`, `wu_bing_search`, `wu_tips`, `wu_sync_ads`),
  each one captured before it is written and restored *exactly* on revert
  (including "it did not exist before", which deletes it again). CI proves the
  round-trip on a disposable Windows runner and compares the registry before
  and after.
- `assets/banner.svg` for the repository header.

### Fixed

- `firefox_policy` and `firefox_userjs` verify created a scratch directory and
  returned without removing it — 30 leaked temp trees per test run.
- `verify` reported `FAIL` for an action that had never been applied on a
  staging root with no file present; it is now `SKIP … nothing applied here`.
- The test harness now removes every temp tree it creates, including on failure.

## [1.0.0] — 2026-10-25

First release. The scope is deliberately small: five actions, two engines, one
safety contract.

### Added

- **Portable POSIX-sh engine** (`lib/sysopt.sh` + `bin/sysopt`) with the
  commands `detect`, `list`, `plan`, `apply`, `verify`, `status`, `doctor`,
  `revert`, `version`.
- **Native PowerShell port** (`bin/sysopt.ps1`) for Windows PowerShell 5.1 and
  PowerShell 7, with the same command surface, the same exit codes and the same
  safety rules. No WSL, no MSYS, no bash shim.
- **Actions**
  - `hosts_block` — a marked block in the system hosts file, A and AAAA records
    for every name, plus optional `extra-block.txt` / `allow.txt` lists in the
    state directory.
  - `firefox_userjs` — a marked prefs block in every Firefox profile; prefs the
    user set outside the block are kept, never overridden.
  - `firefox_policy` — add-only merge into `policies.json`, refused without
    `jq` rather than half-written.
  - `swappiness` — one `/etc/sysctl.d` drop-in, skipped automatically while
    `tlp` or `power-profiles-daemon` is active.
  - `report_power` — read-only governor / EPP / power-owner report.
- **Safety machinery** — backup before the first write to each id, write-ahead
  journal, TSV manifest, atomic `cp` + `mv` replacement, `doctor` for
  interrupted runs, byte-exact `revert`.
- **Platform support** — Linux, ChromeOS/Crostini, macOS, the BSDs, Termux and
  Windows; x86_64, x86_32, aarch64, arm32, ppc64, ppc64le, s390x, riscv64,
  loongarch64, mips64, mips32.
- **`contrib/winutil/sysopt-config.json`** — a reviewable WinUtil config the
  user imports themselves, documented line by line in `docs/WINUTIL.md`.
  There is no `irm … | iex` anywhere in this project, and activation is out of
  scope.
- **`install.sh`** — local, offline installer with `--prefix`, `--dry-run` and
  `--uninstall`.
- **Test suites** — 105 assertions for the shell engine (`tests/run_tests.sh`)
  and 31 for the PowerShell port (`tests/run_tests.ps1`), no root, no network,
  every absolute path staged under a throwaway root. Covers plan-safety,
  idempotency, tamper detection, add-only merging, byte-exact revert,
  backup-once, the power-daemon guard and its explicit override, refusal to
  delete a file the manifest cannot prove sysopt created, and
  `not-supported` behaviour.
- **CI** — Ubuntu (dash, bash, busybox) and macOS (`/bin/sh`), `shellcheck`
  warnings-as-errors, a grep gate that fails the build if a runtime download
  path ever appears, and a Windows job that parses the PowerShell port and runs
  every read-only command.
- Docs: `DESIGN.md` (the invariants, and why each exists), `COMPATIBILITY.md`
  (matrix plus the reason for every gap), `WINUTIL.md`, `SECURITY.md`,
  `CONTRIBUTING.md`.

### Notes

- `revert` is a write like any other: it needs `--apply`, and without it prints
  what it would restore.
- `--force-cpu` is the only way past the power-daemon guard, and it never
  applies implicitly.
- An unknown `--only` id is a usage error (exit 2), not a silent no-op.
