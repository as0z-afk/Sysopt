# Design

sysopt is small on purpose. The interesting part is not the list of tweaks — it
is the set of rules that decides which tweaks are allowed to exist, and what has
to be true before one may run.

Every rule below is enforced in code. If a rule and an optimisation disagree, the
rule wins, and the action is either narrowed or dropped.

## 1. Plan is the default

`sysopt` with no subcommand, `sysopt plan`, and `sysopt apply --dry-run` all
render the exact bytes that would be written and write none of them. `--apply` is
the only switch that turns intent into a write, and the interactive path shows
the plan and asks first (`--yes` skips the question, never the plan).

Implementation: every action receives `plan|apply|verify|revert` as its phase and
must handle `plan` without touching the filesystem. `apply_file` refuses to run
when `DRY_RUN=1`, so an action that forgets cannot leak.

## 2. Backup, journal, manifest

A write is four steps, in this order:

```
journal begin <id>        # intent recorded
cp <new> <dest>.sysopt.new
mv <dest>.sysopt.new <dest>   # atomic on the same filesystem
journal done <id>
manifest_set <id> file <dest> <backup> <root?> <note>
```

The backup is taken *before* `journal begin` and only on the first write to a
given id, so repeated runs never overwrite the original. `doctor` compares the
journal against the manifest: a `begin` without a `done` is an interrupted
write, named explicitly, with the revert command that fixes it.

State lives in `${SYSOPT_STATE:-~/.config/sysopt}`:

```
manifest.tsv     id, kind, path, backup, root, note   (TSV, one row per item)
journal.log      timestamp, begin|done|abort, id
backups/<ts>/    <id>__<flattened path>
```

All three are plain text on purpose. `cat` and `diff` are the audit tools.

## 3. Add-only merges

Two actions touch files that other software also owns: the Firefox policy and
each profile's `user.js`.

- The `user.js` block is written between marker lines. A pref the user has set
  *outside* the block is detected and skipped; the value is never duplicated and
  never overridden. The plan says `keeping your own value for: <key>`.
- `policies.json` is merged with `jq`, key by key, and only adds keys that are
  absent. An existing key is never relaxed, never overwritten, never reordered.
  If `jq` is missing, the action refuses — a hand-rolled JSON edit is how you
  corrupt a policy file.

There is no `--force` for either of these. There will not be one.

## 4. Never fight a daemon

`tlp`, `power-profiles-daemon`, `thermald` and their vendor equivalents own the
power knobs. Writing `vm.swappiness` behind `tlp`'s back produces a value that
looks right for a minute and is gone after the next `tlp start` — an
optimisation that silently reverts itself is worse than no optimisation.

So `svc_active` is checked first, and an active owner means *skip*, with the
reason printed. `--force-cpu` exists for the person who knows their machine and
wants the write anyway; it is explicit, documented, and never implied by another
flag. `svc_active` asks `systemctl is-active` rather than reading
`list-unit-files`, because a generated or aliased unit can be running while
`list-unit-files` says nothing.

## 5. `not-supported` beats invention

`ACTION_DB` pins each action to the platforms where it is real:

```
hosts_block     linux,chromebook,darwin,bsd
firefox_userjs  linux,chromebook,darwin,bsd
firefox_policy  linux,chromebook
swappiness      linux
report_power    linux,chromebook,darwin,bsd,termux
```

On anything else the answer is `SKIP … not supported on <os>`, and `sysopt list`
prints the platforms where it *does* exist. No fallback that "probably works",
no `/proc` path assumed on a BSD, no sysctl name guessed on Solaris.

## 6. Revert is byte-exact

`revert` has two branches and no third:

- a backup exists → copy it back over the file;
- no backup (sysopt created the file) → delete the file, if and only if removing
  our block leaves nothing but whitespace. Content that was there before is
  never destroyed to make a revert look tidy.

`revert --all` reads the manifest, maps each manifest id back to its action
(`hosts` → `hosts_block`, `userjs-*` → `firefox_userjs`,
`firefox-policy` → `firefox_policy`), and reverts each in turn. The test suite
asserts byte equality of the whole tree, not "looks reverted".

## 7. Testable without root

Every absolute path goes through `syspath`, which prefixes `$SYSOPT_ROOT` when it
is set. Every state path goes through `$SYSOPT_STATE`. That is the entire test
seam: `tests/run_tests.sh` builds a fake root in `mktemp -d`, applies to it,
tampers with it, reverts it, and asserts on the result — 105 assertions, no
privileges, no network, nothing left behind.

A test that needs root is a test that will not run in CI, which is a test that
will not run.

## What is not here, and why

- **No file deletion, no cache clearing, no "debloat".** A tool that cannot put
  a file back has no business removing it.
- **No DNS, proxy or hosts *redirection* beyond a fixed blocklist.** Pointing
  traffic at a server is a trust decision, not a tuning decision.
- **No security relaxation.** Not the sandbox, not certificate checks, not
  Defender, not SIP, not SELinux/AppArmor.
- **No benchmark theatre.** sysopt does not print "37 % faster". It prints what
  it changed, and `report_power` prints what it did not touch.

## How an action gets added

1. It must be reversible by copying back one file, or by deleting one file
   sysopt created. If it is neither, it is not an action.
2. It must be `plan`-safe, `verify`-able with a PASS/FAIL that means something,
   and `revert`-able to original bytes.
3. It must be added to `ACTION_DB` with its exact platform list — no wildcards.
4. It must survive the tamper test: change the thing it manages, and `verify`
   must notice.
5. It must pass `shellcheck -s sh -S warning` and the whole suite.

Anything that cannot meet all five stays a comment in an issue.
