## What this changes

<!-- one paragraph; say which action or which invariant is touched -->

## Which invariant does it touch?

- [ ] none — docs, CI, tests only
- [ ] plan-by-default (nothing written without consent)
- [ ] backup / journal / manifest
- [ ] add-only merging
- [ ] power-daemon guard
- [ ] revert (byte-exact restore)
- [ ] platform declarations in `ACTION_DB`

## Checks

- [ ] `sh tests/run_tests.sh` passes
- [ ] `pwsh -File tests/run_tests.ps1` passes
- [ ] `shellcheck -s sh -S warning bin/sysopt lib/sysopt.sh tests/run_tests.sh install.sh` is clean
- [ ] if this adds an action: it is reversible by restoring one file, it has a
      tamper test, and `README.md` + `docs/COMPATIBILITY.md` are updated
- [ ] no runtime download was added (`curl`, `wget`, `iex`, `Invoke-Expression`)

## Anything a user should know before merging

<!-- failure modes, migration notes, "do not do this on $platform" -->
