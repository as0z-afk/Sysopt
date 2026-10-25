<div align="center">

<img src="assets/logo.svg" alt="sysopt" width="120" height="120">

# sysopt

**Portable, reversible system tuning that refuses to break your machine.**

One POSIX shell core. One native PowerShell port. Twelve platforms.
Nothing happens without a backup, a journal entry and a way back.

`plan` → `apply` → `verify` → `revert`

</div>

---

## The promise, in seven lines

1. **Nothing is written unless you pass `--apply`.** The default is a plan you can read.
2. **Every write is backed up** before it happens, and listed in a manifest.
3. **Every write is journalled before it happens**, so an interrupted run is *detected* (`doctor`), never silently half-done.
4. **Merges are add-only.** An existing setting you made is never overwritten or weakened.
5. **A running power daemon is never fought.** If `tlp` or `power-profiles-daemon` owns a knob, sysopt skips it — even if that means doing less.
6. **No action is invented.** On a platform that lacks a feature, the answer is `not-supported` with the reason, not a guess.
7. **`revert` restores the original bytes** — or deletes exactly what sysopt created, and nothing else.

If those rules ever conflict with an optimisation, the optimisation loses. That is the whole design.

---

## What it does

| Action | What it changes | Needs root | Risk |
|---|---|---|---|
| `hosts_block` | A managed block in the system hosts file: A **and** AAAA records for a fixed list of ad/tracker hostnames | yes | low |
| `firefox_userjs` | A managed block inside each Firefox profile's `user.js` (session restore interval, telemetry off, prefetch off, …) | no | low |
| `firefox_policy` | System Firefox `policies.json`, **add-only merge** — never relaxes an existing key | yes | medium |
| `swappiness` | `vm.swappiness=10` via one `/etc/sysctl.d` drop-in, skipped while a power daemon is active | yes | medium |
| `report_power` | Nothing. Prints governor / EPP / power-daemon ownership | no | none |
| `wu_*` (6 tweaks, Windows) | Registry values: telemetry policy, consumer features, delivery optimization, Bing in Start, tips, Explorer ads | HKLM ones yes | low |

There is deliberately **no** "speed up your PC" action. sysopt changes a small
number of things it can prove it can put back.

### Customising the blocklist

Two optional files in the state directory (`~/.config/sysopt/` by default):

- `extra-block.txt` — one bare hostname per line, added to the block;
- `allow.txt` — hostnames that are never blocked; the allow list wins over both
  the built-in list and the extra list.

`contrib/profiles/` has an example of each, with the reasoning commented in.

---

## What it refuses to do

- Disable a sandbox, a certificate check, or a firewall.
- Point a resolver or a proxy at a server you did not choose.
- Remove software, delete your files, or clear a cache it cannot restore.
- Override a pref you set yourself.
- Fight `tlp`, `power-profiles-daemon`, `thermald` or the vendor power tool for control of a knob.
- Bypass a licence, an activation check, or a paywall. Not a feature, not a flag, not a plugin.

---

## Install

Every platform: clone, then run the installer. No `curl … | sh`, no remote code, nothing downloaded behind your back.

```sh
git clone https://github.com/<you>/sysopt.git
cd sysopt
sh install.sh
```

That puts the tool in `~/.local/share/sysopt` and a launcher in `~/.local/bin/sysopt`. Use `--prefix DIR` for elsewhere, `--uninstall` to remove it, `--dry-run` to see the moves first. If you would rather not install anything, run `./bin/sysopt` straight out of the clone.

**Windows** — nothing to install; the port is a single PowerShell file:

```powershell
git clone https://github.com/<you>/sysopt.git
cd sysopt
.\bin\sysopt.ps1 detect
```

Windows PowerShell 5.1 and PowerShell 7 are both supported. The hosts action needs an elevated shell; everything else runs as you.

## Use

```sh
sysopt detect                 # what this machine is, and what it supports here
sysopt list                   # every action, marked available / not-supported
sysopt plan                   # what would change — writes nothing at all
sysopt apply                  # show the plan, ask, then apply, then verify
sysopt verify                 # PASS / FAIL / WARN / SKIP per item
sysopt status                 # what is applied, where the backups live
sysopt doctor                 # read-only: interrupted writes, orphaned backups
sysopt revert --id hosts_block --apply
sysopt revert --all --apply   # byte-identical to before sysopt ever ran
```

One command runs the entire workflow: `sysopt apply`. It plans, asks once, applies, verifies, and prints the exact revert line.

Useful flags: `--dry-run` (plan, even with `apply`), `--yes` (non-interactive), `--only id1,id2`, `--force-cpu` (override the power-daemon guard, explicitly), `--state DIR`, `--root DIR` (stage every absolute path under DIR — this is how the test suite stays off your real system).

Exit codes: `0` ok, `1` something failed, `2` usage error, `3` unsupported here, `130` cancelled.

### What it looks like

A real run, with the 40-line hosts diff and the `user.js` diff trimmed down to
their shape (`…` marks the cut):

```console
$ sudo sysopt apply
== plan ==
== hosts block: /etc/hosts ==
  names 20, records 40
--- /etc/hosts (current)
+++ /etc/hosts (proposed)
@@ -1,4 +1,47 @@
 127.0.0.1	localhost
+
+# BEGIN sysopt managed block
+# generated by sysopt 1.0.0 — remove this whole block to revert
+# exact hostnames only; A and AAAA records for every name
+0.0.0.0 adnxs.com
+:: adnxs.com
…
+# END sysopt managed block

Apply these changes? [y/N] y

== hosts block: /etc/hosts ==
[+] /etc/hosts written

== firefox profile: ~/.mozilla/firefox/abc.default ==
  [new file] ~/.mozilla/firefox/abc.default/user.js does not exist yet; it will be created
[+] ~/.mozilla/firefox/abc.default/user.js written

== firefox policy: /etc/firefox/policies/policies.json ==
  (file does not exist yet — it will be created)
[+] /etc/firefox/policies/policies.json written
  swappiness: skipped — tlp/power-profiles-daemon manages kernel VM settings

== power state (read-only) ==
  governor                   powersave
  EPP                        balance_power
  managed by                 tlp
  sysopt never writes governor or EPP; change them in the daemon that owns them

== verification ==
  PASS hosts block 1 block, every name has A and AAAA
  PASS firefox user.js abc.default
  PASS firefox policy valid JSON with managed keys
  SKIP swappiness owned by a power daemon
  PASS power state governor=powersave epp=balance_power owner=tlp

== next ==
  status : sysopt status
  revert : sysopt revert --all --apply
```

Note what is *not* in that output: no service restarted, no governor written, no
claim about speed. `tlp` owns the power knobs, so sysopt reported them and left
them alone.

---

## Platforms

| Platform | Engine | `hosts_block` | `firefox_userjs` | `firefox_policy` | `swappiness` | `report_power` |
|---|---|---|---|---|---|---|
| Linux (Debian, Ubuntu, Fedora, Arch, openSUSE, …) | `bin/sysopt` | ✅ | ✅ | ✅ | ✅ | ✅ |
| ChromeOS / Crostini | `bin/sysopt` | ✅ | ✅ | ✅ | — | ✅ |
| macOS | `bin/sysopt` | ✅ | ✅ | — | — | ✅ |
| FreeBSD, OpenBSD, NetBSD, DragonFly | `bin/sysopt` | ✅ | ✅ | — | — | ✅ |
| Termux (Android) | `bin/sysopt` | — | — | — | — | ✅ |
| Windows 10 / 11 / Server | `bin/sysopt.ps1` | ✅ | ✅ | — | — | ✅ |
| Solaris / illumos, Haiku | `bin/sysopt` | detect only | | | | |

Architectures: `x86_64`, `x86_32`/`i686`, `aarch64`, `arm32` (armv6/armv7), `ppc64`, `ppc64le`, `s390x`, `riscv64`, `loongarch64`, `mips64`, `mips32`. Nothing in the shell core assumes a word size, an endianness or a page size; the arch string is reported, not assumed.

A `—` is a real answer: `sysopt list` prints `not-supported` and the platforms where the action does exist. See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for the per-platform detail and the reasons.

---

## Windows, and the WinUtil question

Windows is a **native PowerShell port**, never a POSIX shim. It implements the same commands, the same exit codes and the same seven rules.

On the "one-click debloat" scripts that circulate for Windows: sysopt does not run them. `irm https://… | iex` executes whatever the server sends, today and on every future run — there is no pinned hash, no diff, no revert. If you want those tweaks, this repo ships a **reviewable config you import yourself**:

```
contrib/winutil/sysopt-config.json     ← every line readable before you run anything
docs/WINUTIL.md                        ← what each key does, and how to undo it
```

Import it through WinUtil's own UI, after reading it. It is a file in a repo, not a live pipe, and you can diff it.

Activation is out of scope. sysopt does not unlock, patch or "activate" anything; see [docs/WINUTIL.md](docs/WINUTIL.md#activation-is-not-a-tuning-step) for the legitimate paths per Windows edition.

---

## Staying current — catalog and update

Two pieces, both deliberately boring:

**The catalog** (`contrib/catalog/actions.tsv`) is data, shipped in the repo,
that says which actions exist and which have been retired. It can withhold a
feature; it can never carry code. Retiring an action does **not** strand a
machine that already applied it — `revert` keeps working for as long as the
manifest has a row, because losing the way back is worse than the feature being
gone.

```console
$ sysopt catalog
  ACTIONS            STATUS     SINCE    NOTE
  hosts_block        stable     1.0.0    A marked block in the system hosts file
  firefox_userjs     stable     1.0.0    A marked prefs block in every Firefox profile
  firefox_policy     stable     1.0.0    Add-only merge into the system policies.json
  swappiness         stable     1.0.0    vm.swappiness drop-in; skipped under tlp/ppd
  report_power       stable     1.0.0    Read-only governor / EPP / power-owner report
  wu_telemetry       beta       1.1.0    Windows policy: AllowTelemetry = 0
  …
```

**The updater** (`sysopt update`) is offline on purpose. You get a newer tree
however you like — `git pull`, a tarball, a USB stick — and point sysopt at it:

```console
$ sysopt update --from ../sysopt-main        # stage and inspect, install nothing
$ sysopt update --from ../sysopt-main --apply
```

What it does before it touches your install:

1. **parses** the candidate with `sh -n` (a file that is not sh never gets near you);
2. **runs** the candidate against a throwaway `--root`, so "it starts" is proven, not assumed;
3. **diffs the catalog** and prints every action added (`+ new action`) or withdrawn (`- withdrawn`);
4. **swaps atomically**, keeping the previous tree, and proves the new one starts — rolling back automatically if it does not;
5. **rolls back on demand**: `sysopt update --rollback --apply`.

Add `--full-test` to run the candidate's entire suite as well (slower; the suite
is guarded against re-entering `update`). There is no URL, no `curl`, no
`| sh`: a download path with no pinned hash is how a tool that promised to be
fail-safe stops being one.

---

## Getting your machine back

```sh
sysopt status                 # -> manifest: id, path, backup
sysopt doctor                 # clean, or a specific complaint
sysopt revert --all --apply   # every original byte restored
```

Backups live under `${SYSOPT_STATE:-~/.config/sysopt}/backups/<timestamp>/` and are never deleted by sysopt, so a revert can be repeated and audited. The manifest is a plain TSV; the journal is a plain log. You can read both with `cat`, and you should.

If a run is interrupted — power cut, closed terminal, `kill -9` — the journal still has a `begin` without a `done`. `sysopt doctor` says so by name, and `revert --id <that-id> --apply` puts the file back.

---

## Development

```sh
sh tests/run_tests.sh          # 105 assertions — POSIX engine
pwsh -File tests/run_tests.ps1  # 31 assertions — PowerShell engine
shellcheck -s sh bin/sysopt lib/sysopt.sh tests/run_tests.sh install.sh
sh -n lib/sysopt.sh
```

Both suites stage every absolute path under a throwaway root — `--root DIR` for
the shell engine, `$env:SYSOPT_ROOT` for the PowerShell one — so neither ever
touches your real `/etc`, `%APPDATA%` or state directory. That is also why they
run in CI on machines that are not yours: Linux (dash, bash, busybox), macOS
(`/bin/sh`), Windows PowerShell, and the PowerShell port staged on Linux. See
[.github/workflows/ci.yml](.github/workflows/ci.yml).

- [docs/DESIGN.md](docs/DESIGN.md) — the invariants, and why each one exists
- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) — platform matrix and reasons
- [docs/WINUTIL.md](docs/WINUTIL.md) — the Windows config, line by line
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to add an action without breaking the contract
- [SECURITY.md](SECURITY.md) — threat model, and what is explicitly not accepted

## Licence

MIT. See [LICENSE](LICENSE).
