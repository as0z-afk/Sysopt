# Security

## What sysopt does with your machine

sysopt edits files you already own or administer, and it keeps a copy of what
was there. That is the entire capability. There is no daemon, no network
listener, no background process, and no scheduled task.

Concretely, at rest:

- it **reads** `/etc/hosts`, Firefox profile directories, `/proc/sys/vm/*`,
  `/sys/devices/system/cpu/*`, `systemctl is-active` output, and `pmset` on macOS;
- it **writes** only: the hosts file, a `user.js` per Firefox profile,
  `/etc/firefox/policies/policies.json`, `/etc/sysctl.d/90-sysopt.conf`, and its
  own state directory;
- it **never** executes a download, never pipes a URL to a shell, and contains no
  `curl`, `wget`, `iex` or `Invoke-Expression` call;
- it **never** writes to the Windows registry, and the PowerShell port has no
  `Set-ItemProperty`, `New-ItemProperty` or `reg add` in it.

You can verify the download claim in one line:

```sh
grep -rnE 'curl|wget|iex|Invoke-Expression|DownloadString' bin lib install.sh
```

There is no output. If there ever is, that is the security bug.

## Reporting a vulnerability

Open a private security advisory on the repository (**Security → Advisories →
Report a vulnerability**), or email the maintainer listed in the repo metadata.
Please do not open a public issue for anything that could be used to attack a
user before a fix exists.

Include:

- the platform and `sysopt detect` output,
- the exact command you ran,
- the contents of `${SYSOPT_STATE:-~/.config/sysopt}/journal.log` if a write is
  involved,
- what you expected to happen, and what happened.

A useful report for this project usually looks like: *"a run with `--apply`
wrote X without a backup"*, *"`revert` did not restore the original bytes"*, or
*"this path is reachable from a value I control"*.

Out of scope, and closed without discussion:

- **"It doesn't disable Defender / SIP / SELinux / the browser sandbox."** That
  is a design rule, not a defect. See [docs/DESIGN.md](docs/DESIGN.md).
- **"It can't activate Windows."** Not in scope. See
  [docs/WINUTIL.md](docs/WINUTIL.md#activation-is-not-a-tuning-step).
- **"The hosts block is easy to bypass."** Yes — it is a DNS name block, not a
  firewall. DNS-over-HTTPS, a VPN and a hard-coded IP all go around it, and the
  README says so.
- **Prompts to add a remote install path.** Every change to how code arrives on
  a machine is a design discussion, and `curl | sh` is refused on principle.

## Threat model

**In scope:** a mistake in this repository damaging *your* machine — a write
without a backup, a merge that overwrites your policy, a revert that does not
restore, a crashed run that leaves a file half-written, a busybox/BSD portability
assumption that quietly does the wrong thing.

The mitigations are structural, not promises: plan-by-default, a backup before
the first write to each id, a write-ahead journal, atomic `cp`+`mv` replacement,
byte-exact restore, and a test suite that asserts on file contents rather than on
exit codes.

**Out of scope:** a hostile local administrator, a compromised kernel, firmware
attacks, supply-chain attacks on your OS packages. sysopt runs with your
privileges and trusts your userland — if `cp` lies, so does sysopt.

**One genuine trust boundary** remains: `firefox_policy` shells out to `jq`. If
`jq` on your system is malicious, the JSON it emits is whatever it wants. sysopt
refuses to merge without `jq` rather than half-writing, and the resulting file is
diffed before the write, which is the most a shell tool can honestly offer.

## Supported versions

Fixes land on `main`. There are no maintained release branches; the whole tool is
two files, so the fix is always in the next commit.
