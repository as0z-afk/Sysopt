# Contributing

The most valuable contribution to this project is **an action that is smaller
than the one you wanted to add**. Second most valuable: a platform report.

## Before anything else

```sh
sh tests/run_tests.sh
shellcheck -s sh -S warning bin/sysopt lib/sysopt.sh tests/run_tests.sh install.sh
sh -n lib/sysopt.sh
```

All three must be clean before a pull request, and CI runs exactly these
commands (`shellcheck` is skipped gracefully where it is not installed).

## The five rules an action must satisfy

An action is a change sysopt is allowed to make. Adding one is a design review,
not a code review. It must:

1. **Be reversible by copying back one file, or by deleting one file sysopt
   created.** Nothing else qualifies. If your idea needs a package install, a
   reboot, or a "mostly reversible" caveat, it is not an action.
2. **Handle `plan` without touching the filesystem.** `apply_file` enforces
   this, but your action must also skip creating directories, temp files in
   place, or empty files.
3. **Verify with a meaningful PASS/FAIL.** `verify` must actually detect
   tampering: if someone edits the thing your action manages, the check must
   fail. "File exists" is not a verification.
4. **Declare its exact platforms in `ACTION_DB`.** No wildcards, no "probably
   works". A missing platform is a `not-supported`, which is a valid and
   honest answer.
5. **Survive the test suite**, including a tamper test and a byte-exact
   revert test, on both `dash` and `bash`.

## Adding an action, step by step

```sh
# 1. register it (platform list is exact)
#    in lib/sysopt.sh: ACTION_DB
myaction|linux,darwin|1|low|One sentence a user can understand

# 2. implement the four phases
action_myaction() {
  local _phase=''
  _phase="$1"
  case "$_phase" in
    plan|apply) ... ;;
    verify)     printf 'PASS\tmy action\tshort reason\n' ;;
    revert)     ... ;;
  esac
  return 0
}

# 3. write the tests: new_env; apply; tamper; verify must FAIL; revert; cmp
#    tests/run_tests.sh, one `section` per concern

# 4. document it in three places
#    README.md (the table), docs/COMPATIBILITY.md (the matrix), CHANGELOG.md
```

Use `apply_file` for every write. Do not call `cp`/`mv` on a system path
directly — you will skip the backup, the journal, and the manifest, which is the
one unrecoverable mistake in this codebase.

## Portability rules

- `#!/bin/sh`, POSIX only, plus `local` (probed at load; see `docs/DESIGN.md`).
- No bashisms: no `[[ ]]`, no arrays, no `${var//x/y}`, no `declare`, no `$'…'`.
- No GNU-only flags: `sed -i` needs a backup-suffix argument form on BSD, so
  avoid it; `readlink -f` is not on macOS, so the launcher walks symlinks
  itself; `grep -c` exits 1 on zero matches, so use the `count()` helper.
- Quote every variable. `set -u` is on; an unset variable must be a bug you
  found while testing, not a surprise for a user.
- Never assume a path exists because it exists on Linux. Route every absolute
  path through `syspath`, or check it first.

## Reporting a platform

If you ran sysopt on a BSD, a RISC-V board, or a Chromebook, paste the output of:

```sh
sysopt detect
sysopt plan
```

That is enough to file a support claim in `docs/COMPATIBILITY.md`, and it is a
genuinely welcome pull request.

## What gets rejected

- Anything that disables a security feature, a sandbox, a certificate check, or
  a firewall.
- Anything that deletes a file sysopt cannot restore.
- Anything that changes DNS, a proxy, or a trust anchor.
- Anything that races `tlp` / `power-profiles-daemon` without the existing
  `--force-cpu` path.
- Anything that downloads code at runtime. Including "just for the installer".
- Telemetry, analytics, or a phone-home of any kind.

## Commit style

One logical change per commit. The subject line says what changed and why, in
under 72 characters:

```
hosts: create the name list before building the block
```

Reference the issue if there is one. If the change touches an invariant, say
which one in the body — future-you will be reading it.

## Licence

Contributions are MIT, same as the project. By opening a pull request you agree
to that.
