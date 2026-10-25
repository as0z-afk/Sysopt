#!/bin/sh
# =============================================================================
#  Portable test suite. Runs on any POSIX sh with a POSIX userland; no root,
#  no network, nothing outside a temporary directory.
#
#    sh tests/run_tests.sh           # quiet, exit 0 on success
#    sh tests/run_tests.sh -v        # show every assertion
# =============================================================================
set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
SYSOPT="$ROOT/bin/sysopt"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

PASS=0; FAIL=0; FAILED=""

_t=""
t() { _t="$*"; [ "$VERBOSE" = 1 ] && printf '  ... %s\n' "$_t"; return 0; }
ok() { PASS=$((PASS + 1)); [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$_t"; return 0; }
no() { FAIL=$((FAIL + 1)); FAILED="$FAILED
  FAIL: $_t${1:+  ($1)}"; printf '  FAIL %s%s\n' "$_t" "${1:+  ($1)}"; return 0; }

assert_eq()   { [ "$1" = "$2" ] && ok || no "want [$2] got [$1]"; }
assert_has()  { printf '%s' "$1" | grep -qF -- "$2" && ok || no "missing [$2]"; }
assert_not()  { printf '%s' "$1" | grep -qF -- "$2" && no "should not contain [$2]" || ok; }
assert_file() { [ -f "$1" ] && ok || no "no such file $1"; }
assert_nofile(){ [ -e "$1" ] && no "should not exist: $1" || ok; }

WORK_ALL=''
new_env() { # new_env -> sets WORK; every tree this run made is removed at exit
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/sysopt-test.XXXXXX") || exit 1
  WORK_ALL="$WORK_ALL $WORK"
  # shellcheck disable=SC2086
  trap 'rm -rf $WORK_ALL' EXIT INT TERM
  mkdir -p "$WORK/root/etc" "$WORK/root/home/tester/.mozilla/firefox/p1.default"
  : >"$WORK/root/home/tester/.mozilla/firefox/p1.default/prefs.js"
  printf '127.0.0.1\tlocalhost\n127.0.1.1\tbox\n\n# user comment\n10.0.0.5\tnas.lan\n' >"$WORK/root/etc/hosts"
  export SYSOPT_STATE="$WORK/state"
  export HOME="$WORK/root/home/tester"
}

run() { # run <args...>
  "$SYSOPT" --root "$WORK/root" --state "$SYSOPT_STATE" "$@" 2>&1
}

section() { printf '\n%s\n' "$*"; }

# --------------------------------------------------------------------------
section '1. detection and architecture mapping'
new_env
out=$(run detect)
assert_has "$out" 'architecture'
assert_has "$out" 'capabilities on this platform'
for pair in 'x86_64:x86_64' 'i686:x86_32' 'aarch64:aarch64' 'armv7l:arm32' 'riscv64:riscv64' 's390x:s390x'; do
  raw=${pair%%:*}; want=${pair##*:}
  got=$(SYSOPT_ARCH_FORCE="$raw" sh -c ". '$ROOT/lib/sysopt.sh'; detect_arch; printf '%s' \"\$SYSOPT_ARCH\"")
  t "arch map $raw -> $want"; assert_eq "$got" "$want"
done

section '2. unsupported platform degrades honestly'
t 'freebsd: firefox_policy not supported'
out=$(SYSOPT_OS_FORCE=bsd run detect)
assert_has "$out" 'not-supported'
t 'freebsd still supports hosts_block'
printf '%s' "$out" | grep 'hosts_block' | grep -q 'available' && ok || no 'hosts_block should be available on bsd'

section '3. plan writes nothing'
new_env
before=$(cat "$WORK/root/etc/hosts")
out=$(run plan); rc=$?
t 'plan exits 0'; assert_eq "$rc" "0"
t 'plan mentions hosts block'; assert_has "$out" 'hosts block'
t 'plan produced no state dir'
assert_nofile "$SYSOPT_STATE/manifest.tsv"
t 'plan did not modify hosts'; assert_eq "$(cat "$WORK/root/etc/hosts")" "$before"

section '4. apply is backed up, journalled and reversible'
new_env
orig=$(cat "$WORK/root/etc/hosts")
out=$(run apply --apply --yes); rc=$?
t 'apply exits 0'; assert_eq "$rc" "0"
t 'hosts has one begin marker'; assert_eq "$(grep -c 'BEGIN sysopt managed block' "$WORK/root/etc/hosts")" "1"
t 'hosts has one end marker';   assert_eq "$(grep -c 'END sysopt managed block' "$WORK/root/etc/hosts")"   "1"
t 'doubleclick has A record';   assert_has "$(cat "$WORK/root/etc/hosts")" '0.0.0.0 doubleclick.net'
t 'doubleclick has AAAA record';assert_has "$(cat "$WORK/root/etc/hosts")" ':: doubleclick.net'
t 'user line preserved';        assert_has "$(cat "$WORK/root/etc/hosts")" '10.0.0.5'
t 'manifest exists';            assert_file "$SYSOPT_STATE/manifest.tsv"
t 'backup recorded';            assert_file "$(awk -F'\t' '$1=="hosts"{print $4}' "$SYSOPT_STATE/manifest.tsv")"
t 'journal has begin and done'; assert_eq "$(grep -c 'hosts' "$SYSOPT_STATE/journal.log" 2>/dev/null | head -1)" "2"

section '5. idempotent: a second apply changes nothing'
sum1=$(cksum <"$WORK/root/etc/hosts")
out=$(run apply --apply --yes)
sum2=$(cksum <"$WORK/root/etc/hosts")
t 'hosts unchanged'; assert_eq "$sum2" "$sum1"
t 'reports already current'; assert_has "$out" 'already current'

section '6. verify passes, then fails when tampered'
out=$(run verify)
t 'no FAIL rows'; assert_not "$out" 'FAIL'
proc="$WORK/root/etc/hosts"
grep -v '0.0.0.0 criteo.com' "$proc" >"$proc.t"; mv "$proc.t" "$proc"
out=$(run verify)
t 'detects a removed name'; assert_has "$out" 'FAIL'

section '7. revert restores the original bytes'
new_env
orig=$(cat "$WORK/root/etc/hosts")
run apply --apply --yes >/dev/null
run revert --id hosts_block --apply >/dev/null
t 'hosts byte-identical to before'
assert_eq "$(cat "$WORK/root/etc/hosts")" "$orig"
t 'no managed markers left'; assert_not "$(cat "$WORK/root/etc/hosts")" 'sysopt managed block'

section '8. user prefs outside our block always win'
new_env
p="$HOME/.mozilla/firefox/p1.default/user.js"
printf 'user_pref("dom.ipc.processCount", 8);\n' >"$p"
out=$(run apply --apply --yes --only firefox_userjs)
t 'apply mentioned keeping the user value'; assert_has "$out" 'keeping your own value'
t 'user value untouched'
assert_eq "$(grep -c 'ipc.processCount", 8' "$p")" "1"
t 'no duplicate of that pref in our block'
assert_eq "$(grep -c 'ipc.processCount' "$p")" "1"
t 'other prefs were added'
assert_has "$(cat "$p")" 'browser.sessionstore.interval'

section '9. firefox policy merge is add-only'
new_env
mkdir -p "$WORK/root/etc/firefox/policies"
printf '{"policies":{"EnableTrackingProtection":{"Value":true,"Locked":true,"Category":"strict"}}}\n' \
  >"$WORK/root/etc/firefox/policies/policies.json"
out=$(run apply --apply --yes --only firefox_policy)
pol="$WORK/root/etc/firefox/policies/policies.json"
t 'policy still locks tracking'
assert_eq "$(grep -o '"Locked": *true' "$pol" | head -1 | tr -d ' ')" '"Locked":true'
t 'policy still strict'
assert_has "$(cat "$pol")" '"strict"'
t 'managed key added'
assert_has "$(cat "$pol")" '"DisableTelemetry"'
t 'policy is valid JSON'
if command -v jq >/dev/null 2>&1; then
  jq -e . "$pol" >/dev/null 2>&1 && ok || no 'json invalid'
else
  ok
fi

section '10. dry-run never writes, even with --apply'
new_env
out=$(run apply --dry-run)
t 'no manifest after dry-run'; assert_nofile "$SYSOPT_STATE/manifest.tsv"
t 'no markers in hosts'; assert_not "$(cat "$WORK/root/etc/hosts")" 'sysopt managed block'

section '11. doctor and status are safe on an empty system'
new_env
out=$(run doctor); rc=$?
t 'doctor exits 0'; assert_eq "$rc" "0"
assert_has "$out" 'nothing applied yet'
out=$(run status); rc=$?
t 'status exits 0'; assert_eq "$rc" "0"
assert_has "$out" 'state dir'

section '12. an interrupted run is detected and reported, not ignored'
new_env
mkdir -p "$SYSOPT_STATE"
printf '%s\tbegin\thosts\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$SYSOPT_STATE/journal.log"
out=$(run doctor); rc=$?
t 'doctor still exits 0 (it reports, it does not fail)'; assert_eq "$rc" "0"
t 'doctor names the interrupted action'; assert_has "$out" 'interrupted'

section '13. revert --all returns the machine to its original bytes'
new_env
orig_h=$(cat "$WORK/root/etc/hosts")
run apply --apply --yes >/dev/null
t 'a user.js was created'
[ -f "$HOME/.mozilla/firefox/p1.default/user.js" ] && ok || no
out=$(run revert --all --apply); rc=$?
t 'revert --all exits 0'; assert_eq "$rc" "0"
t 'hosts identical'; assert_eq "$(cat "$WORK/root/etc/hosts")" "$orig_h"
t 'user.js removed (we created it; the user had none)'
assert_nofile "$HOME/.mozilla/firefox/p1.default/user.js"
t 'manifest is empty'
assert_eq "$(grep -c . "$SYSOPT_STATE/manifest.tsv" 2>/dev/null | head -1)" "0"

section '14. --only touches exactly one action'
new_env
run apply --apply --yes --only hosts_block >/dev/null
t 'hosts was written'
assert_has "$(cat "$WORK/root/etc/hosts")" 'sysopt managed block'
t 'user.js untouched'
assert_nofile "$HOME/.mozilla/firefox/p1.default/user.js"

section '15. a bogus --only is refused'
new_env
out=$(run apply --apply --yes --only not_an_action); rc=$?
t 'exit code is 2 (usage)'; assert_eq "$rc" "2"
t 'no state written'; assert_nofile "$SYSOPT_STATE/manifest.tsv"

section '16. a running power daemon is never fought'
new_env
mkdir -p "$WORK/bin" "$WORK/root/proc/sys/vm"
echo 60 >"$WORK/root/proc/sys/vm/swappiness"
cat >"$WORK/bin/systemctl" <<'STUB'
#!/bin/sh
# test stub: tlp is active, nothing else is
[ "$1" = "is-active" ] || exit 1
shift
[ "${1:-}" = "--quiet" ] && shift
[ "${1:-}" = "tlp" ] && exit 0
exit 3
STUB
chmod +x "$WORK/bin/systemctl"
out=$(PATH="$WORK/bin:$PATH" run apply --apply --yes --only swappiness); rc=$?
t 'apply still exits 0 (it skips, it does not fail)'; assert_eq "$rc" "0"
t 'says it skipped because of the daemon'; assert_has "$out" 'skipped'
t 'the drop-in was NOT written'
assert_nofile "$WORK/root/etc/sysctl.d/90-sysopt.conf"

section '17. --force-cpu is the explicit, documented override'
out=$(PATH="$WORK/bin:$PATH" run apply --apply --yes --force-cpu --only swappiness); rc=$?
t 'override writes the drop-in'
assert_file "$WORK/root/etc/sysctl.d/90-sysopt.conf"
t 'override is announced'; assert_has "$out" 'force-cpu'

section '18. list marks what this platform cannot do'
out=$(SYSOPT_OS_FORCE=bsd run list)
t 'bsd: swappiness is not-supported'
printf '%s' "$out" | grep 'swappiness' | grep -q 'not-supported' && ok || no
t 'bsd: hosts_block is available'
printf '%s' "$out" | grep 'hosts_block' | grep -q 'available' && ok || no
t 'list names the platforms for a missing action'; assert_has "$out" 'supported on: linux'

section '19. files that already existed survive two applies and a full revert'
new_env
pfile="$HOME/.mozilla/firefox/p1.default/user.js"
printf 'user_pref("general.useragent.override", "mine");\n' >"$pfile"
mkdir -p "$WORK/root/etc/firefox/policies"
pol="$WORK/root/etc/firefox/policies/policies.json"
printf '{"policies":{"EnableTrackingProtection":{"Value":true,"Locked":true,"Category":"strict"}}}\n' >"$pol"
tree() { find "$WORK/root" -type f | sort | while IFS= read -r _f; do
           printf '%s %s\n' "$(cksum <"$_f")" "${_f#"$WORK/root"}"; done; }
tree >"$WORK/tree.before"
run apply --apply --yes >/dev/null 2>&1
run apply --apply --yes >/dev/null 2>&1
t 'every managed row has a real backup'
_missing=$(awk -F'\t' '$4=="" || $4=="-"{print $1}' "$SYSOPT_STATE/manifest.tsv" 2>/dev/null)
assert_eq "$_missing" ""
t 'the recorded backups still exist'
_ok=1
for _b in $(awk -F'\t' '{print $4}' "$SYSOPT_STATE/manifest.tsv"); do
  [ -f "$_b" ] || _ok=0
done
t 'backup files present'; assert_eq "$_ok" "1"
run revert --all --apply >/dev/null 2>&1
tree >"$WORK/tree.after"
t 'the whole tree is byte-identical to before sysopt ran'
if diff -u "$WORK/tree.before" "$WORK/tree.after" >"$WORK/tree.diff" 2>&1; then ok; else no "$(head -4 "$WORK/tree.diff" | tr '\n' ' ')"; fi
t 'the policy file still exists'; assert_file "$pol"
t 'the user.js still exists';       assert_file "$pfile"
t 'no leftover .sysopt files'
assert_eq "$(find "$WORK/root" -name '*.sysopt*' | head -1)" ""

section '20. a stale manifest cannot make revert delete a file you own'
new_env
mkdir -p "$WORK/root/etc/firefox/policies"
pol="$WORK/root/etc/firefox/policies/policies.json"
printf '{"policies":{"Homepage":{"URL":"https://example.org"}}}\n' >"$pol"
mkdir -p "$SYSOPT_STATE"
printf 'firefox-policy\tfile\t%s\t-\t0\t\n' "$pol" >"$SYSOPT_STATE/manifest.tsv"
out=$(run revert --id firefox_policy --apply); rc=$?
t 'revert refuses (non-zero)'; assert_eq "$rc" "1"
t 'the file is still there'; assert_file "$pol"
t 'it says why'; assert_has "$out" 'leaving it untouched'

section '21. apply asks, and a refusal writes nothing'
new_env
out=$(run apply </dev/null); rc=$?
t 'no answer -> cancelled (130)'; assert_eq "$rc" "130"
t 'nothing was written'; assert_not "$(cat "$WORK/root/etc/hosts")" 'sysopt managed block'
t 'no manifest'; assert_nofile "$SYSOPT_STATE/manifest.tsv"
t 'the plan was shown first'; assert_has "$out" 'Apply these changes?'
out=$(printf 'n\n' | run apply); rc=$?
t 'answering n cancels'; assert_eq "$rc" "130"
out=$(printf 'y\n' | run apply); rc=$?
t 'answering y applies'; assert_eq "$rc" "0"
t 'the block is there'
assert_has "$(cat "$WORK/root/etc/hosts")" 'sysopt managed block'

section '22. --dry-run always wins over any consent flag'
new_env
out=$(run apply --yes --dry-run); rc=$?
t 'exits 0'; assert_eq "$rc" "0"
t 'nothing written'; assert_nofile "$SYSOPT_STATE/manifest.tsv"
t 'says so'; assert_has "$out" 'nothing will be written'

section '23. the catalog decides what is offered, and never hides an undo'
new_env
out=$(run catalog); rc=$?
t 'catalog exits 0'; assert_eq "$rc" "0"
t 'lists a known action'; assert_has "$out" 'hosts_block'
t 'says the catalog carries no code'; assert_has "$out" 'never contains code'

# retire firefox_userjs in a private catalog and check both halves of the rule
cat >"$WORK/catalog.tsv" <<'CAT'
hosts_block	stable	1.0.0		A marked block in the system hosts file
firefox_userjs	retired	1.0.0	1.1.0	Withdrawn in this example
swappiness	stable	1.0.0		vm.swappiness drop-in
CAT
export SYSOPT_CATALOG="$WORK/catalog.tsv"
out=$(run list)
t 'a retired action disappears from list'
assert_not "$out" 'firefox_userjs'
out=$(run catalog)
t 'catalog marks it retired'; assert_has "$out" 'retired'
t 'plan no longer touches it'; assert_not "$(run plan)" 'firefox profile'

# ...but once it is applied on this machine, the way back must survive
unset SYSOPT_CATALOG
run apply --apply --yes --only firefox_userjs >/dev/null
export SYSOPT_CATALOG="$WORK/catalog.tsv"
out=$(run doctor); rc=$?
t 'doctor still exits 0'; assert_eq "$rc" "0"
out=$(run catalog)
t 'catalog shows the retired action is applied here'; assert_has "$out" '(applied here)'
out=$(run revert --id firefox_userjs --apply)
t 'revert still works for a retired action'; assert_has "$out" 'reverted'
unset SYSOPT_CATALOG

section '24. update refuses what it cannot prove'
new_env
out=$(run update); rc=$?
t 'no --from is a usage error'; assert_eq "$rc" "2"
out=$(run update --from "$WORK/not-a-tree"); rc=$?
t 'a directory that is not a sysopt tree is refused'; assert_eq "$rc" "2"
mkdir -p "$WORK/not-a-tree/bin" "$WORK/not-a-tree/lib"
printf '#!/bin/sh\necho broken\n' >"$WORK/not-a-tree/bin/sysopt"
# a file that genuinely cannot parse: unterminated if
printf '#!/bin/sh\nif [ 1 = 1 ]; then\n  echo unterminated\n' >"$WORK/not-a-tree/lib/sysopt.sh"
out=$(run update --from "$WORK/not-a-tree"); rc=$?
t 'a candidate that does not parse is refused'; assert_eq "$rc" "1"
t 'and it says why'; assert_has "$out" 'does not parse'
t 'nothing was installed'
assert_has "$(cat "$ROOT/lib/sysopt.sh")" 'SYSOPT_VERSION'

section '25. update stages, tests, swaps, and rolls back'
if [ "${SYSOPT_UNDER_UPDATE:-0}" = 1 ]; then
  # this suite is being run by `sysopt update` as a candidate self-test;
  # running update again here would recurse until the disk fills
  t 'nested update skipped inside a candidate self-test'; ok
else
new_env
CAND="$WORK/candidate"
mkdir -p "$CAND"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/tests" "$ROOT/contrib" "$CAND/" 2>/dev/null
sed -e 's/^SYSOPT_VERSION="[^"]*"/SYSOPT_VERSION="9.9.9"/' "$CAND/lib/sysopt.sh" >"$CAND/lib/x" && mv "$CAND/lib/x" "$CAND/lib/sysopt.sh"
out=$(run update --from "$CAND"); rc=$?
t 'a dry run exits 0'; assert_eq "$rc" "0"
t 'and installs nothing'; assert_not "$(cat "$ROOT/lib/sysopt.sh")" '9.9.9'
t 'it smoke-tested the candidate'; assert_has "$out" 'plans cleanly against a staged root'
fi


new_env
CAND="$WORK/candidate"
mkdir -p "$CAND"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/tests" "$ROOT/contrib" "$CAND/" 2>/dev/null
sed -i.bak 's/^SYSOPT_VERSION="1.0.0"/SYSOPT_VERSION="9.9.9"/' "$CAND/lib/sysopt.sh"
rm -f "$CAND/lib/sysopt.sh.bak"
out=$(run update --from "$CAND"); rc=$?
t 'a dry run exits 0'; assert_eq "$rc" "0"
t 'and installs nothing'; assert_not "$(cat "$ROOT/lib/sysopt.sh")" '9.9.9'
t 'it smoke-tested the candidate'; assert_has "$out" 'plans cleanly against a staged root'

section '26. the launcher and library parse with every available shell'
for sh in sh dash bash busybox; do
  command -v "$sh" >/dev/null 2>&1 || continue
  if [ "$sh" = busybox ]; then
    busybox sh -n "$SYSOPT" >/dev/null 2>&1 && ok || no "$sh syntax"
  else
    "$sh" -n "$SYSOPT" >/dev/null 2>&1 && "$sh" -n "$ROOT/lib/sysopt.sh" >/dev/null 2>&1 && ok || no "$sh syntax"
  fi
done

# --------------------------------------------------------------------------
rm -rf $WORK_ALL
printf '\n------------------------------------------------\n'
printf '  passed %d   failed %d\n' "$PASS" "$FAIL"
if [ "$FAIL" != 0 ]; then printf '%s\n' "$FAILED"; exit 1; fi
printf '  all good\n'
exit 0
