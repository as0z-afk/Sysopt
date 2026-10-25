#!/bin/sh
# shellcheck disable=SC3043  # `local` is deliberate; availability is probed at load
# =============================================================================
#  sysopt — portable, reversible system tuning for any OS
#
#  One POSIX-sh core that runs unchanged on Linux, macOS, the BSDs and a
#  Chromebook (Crostini). Windows uses bin/sysopt.ps1, which implements the same
#  command surface and the same safety contract.
#
#  DESIGN RULES (enforced in code, not just documented):
#    1. Nothing is written unless --apply is given. Default is plan.
#    2. Every write is preceded by a backup and a manifest entry.
#    3. Every write is journalled before it happens, so an interrupted run is
#       detectable and recoverable (see `doctor`).
#    4. Merges are add-only: an existing key is never overwritten or weakened.
#    5. Anything a power daemon (tlp / power-profiles-daemon) owns is skipped,
#       never raced. Override only with an explicit --force-cpu.
#    6. No action is invented on a platform that lacks it: the answer is
#       `not-supported`, with the reason printed.
#    7. `revert` restores the original bytes or deletes what we created.
#
#  There are no dependencies beyond POSIX sh and a POSIX userland. `jq` is used
#  when present for JSON merges; when absent we refuse to touch an existing JSON
#  file rather than risk corrupting it.
# =============================================================================

SYSOPT_NAME="sysopt"
SYSOPT_VERSION="1.1.0"
SYSOPT_SCHEMA="1"

# exit codes — part of the public contract, used by bin/sysopt and the Windows port
# shellcheck disable=SC2034
EX_OK=0
# shellcheck disable=SC2034
EX_FAIL=1
EX_USAGE=2
# shellcheck disable=SC2034
EX_UNSUP=3
# shellcheck disable=SC2034
EX_CANCELLED=130

# `local` is not in POSIX, but every shell we support has it (dash, ash/busybox,
# bash, ksh, mksh, zsh, macOS sh). Scoping matters here: without it, helper
# variables such as _id would leak between functions and silently corrupt an
# argument. So refuse to run on a shell that lacks it, with a message, instead
# of half-working.
_sysopt_have_local() { local _p_=1; }
if ! _sysopt_have_local 2>/dev/null; then
  printf '[x] this shell has no \`local\` builtin.\n' >&2
  printf '    run with: sh, dash, bash, ksh, mksh or zsh\n' >&2
  exit 3
fi
unset -f _sysopt_have_local 2>/dev/null || :

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$(printf '\033[31m'); C_G=$(printf '\033[32m'); C_Y=$(printf '\033[33m')
  C_D=$(printf '\033[2m');  C_B=$(printf '\033[1m');  C_0=$(printf '\033[0m')
else
  C_R=; C_G=; C_Y=; C_D=; C_B=; C_0=
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
dim()  { printf '%s%s%s\n' "$C_D" "$*" "$C_0"; }
hdr()  { [ "${QUIET:-0}" = 1 ] && return 0; printf '\n%s%s== %s ==%s\n' "$C_B" "$C_B" "$*" "$C_0"; }
kv()   { printf '  %-26s %s\n' "$1" "$2"; }

have() { command -v -- "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# run context
# ---------------------------------------------------------------------------
# SYSOPT_ROOT stages every absolute path under a prefix. Tests and CI use it so
# nothing real is touched; production leaves it empty.
syspath() { printf '%s%s' "${SYSOPT_ROOT:-}" "$1"; }

state_dir() {
  if [ -n "${SYSOPT_STATE:-}" ]; then printf '%s\n' "$SYSOPT_STATE"; return 0; fi
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/sysopt"
}

STATE_DIR="$(state_dir)"
CONFIG_DIR="${SYSOPT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/sysopt}"
MANIFEST="$STATE_DIR/manifest.tsv"
JOURNAL="$STATE_DIR/journal.log"
BACKUP_DIR="$STATE_DIR/backups"
EXTRA_BLOCK="$CONFIG_DIR/extra-block.txt"
ALLOW_FILE="$CONFIG_DIR/allow.txt"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

is_root() { [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; }

reset_state_paths() {
  STATE_DIR="$(state_dir)"
  CONFIG_DIR="${SYSOPT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/sysopt}"
  MANIFEST="$STATE_DIR/manifest.tsv"
  JOURNAL="$STATE_DIR/journal.log"
  BACKUP_DIR="$STATE_DIR/backups"
  EXTRA_BLOCK="$CONFIG_DIR/extra-block.txt"
  ALLOW_FILE="$CONFIG_DIR/allow.txt"
}

# ---------------------------------------------------------------------------
# detection
# ---------------------------------------------------------------------------
detect_os() {
  local _dos_id=''
  SYSOPT_OS="${SYSOPT_OS_FORCE:-}"
  SYSOPT_OS_NAME=""
  SYSOPT_OS_VERSION=""
  SYSOPT_OS_FAMILY=""
  SYSOPT_CONTAINER=""
  [ -n "$SYSOPT_OS" ] && { SYSOPT_OS_NAME="forced"; SYSOPT_OS_FAMILY="$SYSOPT_OS"; return 0; }

  _u="$(uname -s 2>/dev/null || echo unknown)"
  case "$_u" in
    Linux)
      SYSOPT_OS="linux"
      if [ -r /etc/os-release ]; then
        SYSOPT_OS_NAME="$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -1)"
        _dos_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | head -1)"
        SYSOPT_OS_VERSION="$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -1)"
      fi
      # Chromebook: Crostini container, or ChromeOS itself
      if [ -d /opt/google/cros-containers ] || [ -n "${CROS_USER_ID_HASH:-}" ]; then
        SYSOPT_OS="chromebook"; SYSOPT_CONTAINER="crostini"
      fi
      # Termux on Android
      [ -n "${TERMUX_VERSION:-}" ] && SYSOPT_OS="termux"
      # generic container detection (Docker/Podman/systemd-nspawn)
      [ -f /.dockerenv ] && SYSOPT_CONTAINER="${SYSOPT_CONTAINER:-docker}"
      [ -f /run/.containerenv ] && SYSOPT_CONTAINER="${SYSOPT_CONTAINER:-podman}"
      ;;
    Darwin)  SYSOPT_OS="darwin"
             SYSOPT_OS_NAME="macOS"
             SYSOPT_OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo '')" ;;
    FreeBSD|OpenBSD|NetBSD|DragonFly|MidnightBSD)
             SYSOPT_OS="bsd"; SYSOPT_OS_NAME="$_u"
             SYSOPT_OS_VERSION="$(uname -r 2>/dev/null || echo '')" ;;
    SunOS)   SYSOPT_OS="solaris"; SYSOPT_OS_NAME="SunOS" ;;
    Haiku)   SYSOPT_OS="haiku";   SYSOPT_OS_NAME="Haiku" ;;
    MINGW*|MSYS*|CYGWIN*) SYSOPT_OS="windows-posix"; SYSOPT_OS_NAME="$_u (use PowerShell core)" ;;
    *)       SYSOPT_OS="unknown"; SYSOPT_OS_NAME="$_u" ;;
  esac
  # shellcheck disable=SC2034  # part of the public detect output
  SYSOPT_OS_FAMILY="$SYSOPT_OS"
  case "$SYSOPT_OS" in
    linux|chromebook|termux|bsd|darwin|solaris) : ;;
  esac
  [ -n "${SYSOPT_OS_NAME:-}" ] || SYSOPT_OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
  return 0
}

detect_arch() {
  local _a=''
  _a="${SYSOPT_ARCH_FORCE:-}"
  if [ -z "$_a" ]; then
    if have uname; then _a="$(uname -m 2>/dev/null)"; else _a="unknown"; fi
  fi
  case "$_a" in
    x86_64|amd64|x64)          SYSOPT_ARCH="x86_64" ;;
    i386|i486|i586|i686|x86)   SYSOPT_ARCH="x86_32" ;;
    aarch64|arm64)             SYSOPT_ARCH="aarch64" ;;
    armv8l|armv7l|armv7|armv6l|armv6|armv5l|arm) SYSOPT_ARCH="arm32" ;;
    ppc64le)                   SYSOPT_ARCH="ppc64le" ;;
    ppc64)                     SYSOPT_ARCH="ppc64" ;;
    s390x)                     SYSOPT_ARCH="s390x" ;;
    riscv64)                   SYSOPT_ARCH="riscv64" ;;
    loongarch64)               SYSOPT_ARCH="loongarch64" ;;
    mips64)                    SYSOPT_ARCH="mips64" ;;
    mips)                      SYSOPT_ARCH="mips32" ;;
    *)                         SYSOPT_ARCH="unknown:$_a" ;;
  esac
  SYSOPT_ARCH_RAW="$_a"
}

detect_cpu() {
  local _tmp=''
  SYSOPT_CPU_MODEL="unknown"
  SYSOPT_CPU_CORES=""
  if [ -r /proc/cpuinfo ] && grep -qi 'model name\|Hardware\|cpu model' /proc/cpuinfo 2>/dev/null; then
    SYSOPT_CPU_MODEL="$(sed -n 's/^model name[[:space:]]*: //p;s/^Hardware[[:space:]]*: //p;s/^cpu model[[:space:]]*: //p' /proc/cpuinfo | head -1)"
  elif have sysctl; then
    SYSOPT_CPU_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null \
      || sysctl -n hw.model 2>/dev/null || echo unknown)"
  fi
  [ -n "$SYSOPT_CPU_MODEL" ] || SYSOPT_CPU_MODEL="unknown"
  if have getconf; then
    SYSOPT_CPU_CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '')"
  fi
  if [ -z "$SYSOPT_CPU_CORES" ] && have sysctl; then
    SYSOPT_CPU_CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo '')"
  fi
}

detect_mem() {
  local _b='' _s=''
  SYSOPT_RAM_MB=""; SYSOPT_SWAP_MB=""
  if [ -r /proc/meminfo ]; then
    SYSOPT_RAM_MB="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
    SYSOPT_SWAP_MB="$(awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
  elif have sysctl; then
    _b="$(sysctl -n hw.memsize 2>/dev/null || echo '')"
    [ -n "$_b" ] && SYSOPT_RAM_MB="$(( _b / 1048576 ))"
    _s="$(sysctl -n vm.swapusage 2>/dev/null || echo '')"
    [ -n "$_s" ] && SYSOPT_SWAP_MB="$(printf '%s' "$_s" | sed -n 's/.*total = \([0-9.]*\)M.*/\1/p' | cut -d. -f1)"
  fi
}

# ---------------------------------------------------------------------------
# manifest: one tab-separated record per managed item
#   id <TAB> kind <TAB> path <TAB> backup <TAB> root <TAB> note
# ---------------------------------------------------------------------------
manifest_set() {
  local _id='' _kind='' _path='' _bkp='' _root='' _note='' _tmp=''
  _id="$1"; _kind="$2"; _path="$3"; _bkp="$4"; _root="$5"; _note="${6:-}"
  mkdir -p -- "$STATE_DIR" || return 1
  [ -f "$MANIFEST" ] || : >"$MANIFEST"
  _tmp="$(mktemp "${TMPDIR:-/tmp}/sysopt.XXXXXX")" || return 1
  awk -F'\t' -v i="$_id" '$1!=i' "$MANIFEST" >"$_tmp" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_id" "$_kind" "$_path" "$_bkp" "$_root" "$_note" >>"$_tmp"
  mv -f -- "$_tmp" "$MANIFEST"
}

manifest_get() {
  [ -f "$MANIFEST" ] || return 1
  awk -F'\t' -v i="$1" '$1==i{print; exit}' "$MANIFEST"
}

manifest_has() { [ -n "$(manifest_get "$1" 2>/dev/null)" ]; }
manifest_note() { manifest_get "$1" 2>/dev/null | awk -F'\t' '{print $6}'; }

manifest_del() {
  local _tmp
  [ -f "$MANIFEST" ] || return 0
  _tmp="$(mktemp "${TMPDIR:-/tmp}/sysopt.XXXXXX")" || return 1
  awk -F'\t' -v i="$1" '$1!=i' "$MANIFEST" >"$_tmp"
  mv -f -- "$_tmp" "$MANIFEST"
}

backup_path() { # backup_path <id> <file>
  local _ts='' _safe=''
  _ts="$(date -u +%Y%m%d-%H%M%S)"
  _safe="$(printf '%s' "$2" | sed 's#[/\\:]#_#g')"
  mkdir -p -- "$BACKUP_DIR/$_ts" || return 1
  cp -p -- "$2" "$BACKUP_DIR/$_ts/$1__$_safe" 2>/dev/null \
    || cp -- "$2" "$BACKUP_DIR/$_ts/$1__$_safe" || return 1
  printf '%s\n' "$BACKUP_DIR/$_ts/$1__$_safe"
}

backup_for() {
  manifest_get "$1" 2>/dev/null | awk -F'\t' '{print $4}'
}

# ---------------------------------------------------------------------------
# journal: write-ahead so an interrupted run is visible
# ---------------------------------------------------------------------------
journal() { mkdir -p -- "$STATE_DIR" 2>/dev/null; printf '%s\t%s\t%s\n' "$(now)" "$1" "$2" >>"$JOURNAL" 2>/dev/null || true; }

# count <pattern> <file> -> a number, always a single line.
# grep -c prints "0" AND exits 1 when nothing matches, so `grep -c ... || echo 0`
# yields "0\n0"; this helper exists so that mistake cannot come back.
count() {
  local _n_=''
  _n_=$(grep -c -- "$1" "$2" 2>/dev/null | head -n 1)
  printf '%s' "${_n_:-0}"
}

journal_pending() {
  [ -f "$JOURNAL" ] || return 0
  awk -F'\t' '
    $2=="begin" { open[$3]=1 }
    $2=="done"  { delete open[$3] }
    END { for (k in open) print k }' "$JOURNAL"
}

# ---------------------------------------------------------------------------
# atomic file write, with dry-run and backup baked in
#   apply_file <id> <dest> <new-content-file> <mode>
# ---------------------------------------------------------------------------
apply_file() {
  local _id='' _dest='' _src='' _mode='' _bkp='' _note=''
  _id="$1"; _dest="$2"; _src="$3"; _mode="${4:-0644}"
  if [ "${DRY_RUN:-1}" = 1 ]; then
    dim "  [dry-run] would write $_dest"
    return 0
  fi
  if [ -f "$_dest" ] && cmp -s -- "$_dest" "$_src"; then
    ok "$_dest already current"
    return 0
  fi
  mkdir -p -- "$(dirname -- "$_dest")" 2>/dev/null || true
  # _bkp records where the original lives. "-" means "there was no file".
  # _note records that we created it, so a later revert knows it may delete it.
  _bkp="-"
  _note=""
  if [ -f "$_dest" ]; then
    if ! manifest_has "$_id"; then
      _bkp="$(backup_path "$_id" "$_dest")" || { err "cannot back up $_dest; refusing to write"; return 1; }
      [ -n "$_bkp" ] && [ -f "$_bkp" ] || { err "backup of $_dest vanished; refusing to write"; return 1; }
    else
      _bkp="$(backup_for "$_id")"
      _note="$(manifest_note "$_id")"
      case "$_bkp" in
        ""|-)
          if [ "$_note" != "created" ]; then
            err "no usable backup on record for $_dest"
            dim "  sysopt will not overwrite a file it cannot put back."
            dim "  run '$SYSOPT_NAME doctor'; if this row is stale, remove it with"
            dim "  '$SYSOPT_NAME revert --id $_id --apply' after checking the file yourself."
            return 1
          fi
          ;;
        *)
          [ -f "$_bkp" ] || { err "recorded backup $_bkp is missing; refusing to write $_dest"; return 1; }
          ;;
      esac
    fi
  else
    _note="created"
  fi
  journal begin "$_id"
  if cp -- "$_src" "$_dest.sysopt.new" && chmod "$_mode" "$_dest.sysopt.new" 2>/dev/null; then
    mv -f -- "$_dest.sysopt.new" "$_dest" || { err "cannot replace $_dest"; journal abort "$_id"; return 1; }
  else
    err "cannot stage $_dest"
    rm -f -- "$_dest.sysopt.new" 2>/dev/null
    journal abort "$_id"
    return 1
  fi
  journal "done" "$_id"
  manifest_set "$_id" "file" "$_dest" "$_bkp" "$([ -n "${SYSOPT_ROOT:-}" ] && echo 0 || { is_root && echo 1 || echo 0; })" "$_note"
  ok "$_dest written"
  return 0
}

# ---------------------------------------------------------------------------
# capability registry
#   id | platforms | needs-root | risk | one-line summary
# ---------------------------------------------------------------------------
ACTION_DB='
hosts_block|linux,chromebook,darwin,bsd|1|low|Block a fixed ad/tracker hostname list in the system hosts file
firefox_userjs|linux,chromebook,darwin,bsd|0|low|Managed prefs block inside each Firefox profile user.js
firefox_policy|linux,chromebook|1|medium|System Firefox policy (add-only merge; never relaxes an existing key)
swappiness|linux|1|medium|vm.swappiness, skipped automatically while tlp or ppd owns power
report_power|linux,chromebook,darwin,bsd,termux|0|none|Report governor/EPP/power-daemon state; changes nothing
'

action_ids() { printf '%s\n' "$ACTION_DB" | awk -F'|' 'NF>=5{print $1}'; }

# The catalog is data, shipped in the repository, that decides which actions are
# offered. It can add an action and it can retire one — but it can never carry
# code. An action that is withdrawn still runs its own revert for as long as this
# machine has something applied, because losing the way back would be worse than
# the feature being gone.
CATALOG="${SYSOPT_CATALOG:-}"

catalog_get() {
  [ -n "${CATALOG:-}" ] && [ -f "$CATALOG" ] || return 1
  awk -F'\t' -v i="$1" '$1==i{print; exit}' "$CATALOG"
}
catalog_state() { catalog_get "$1" 2>/dev/null | cut -f2; }
catalog_field() { catalog_get "$1" 2>/dev/null | cut -f"$2"; }

action_in_manifest() { # action_in_manifest <action id>
  [ -f "$MANIFEST" ] || return 1
  case "$1" in
    hosts_block)    manifest_has hosts ;;
    firefox_policy) manifest_has firefox-policy ;;
    firefox_userjs) grep -q '^userjs-' "$MANIFEST" 2>/dev/null ;;
    *)              manifest_has "$1" ;;
  esac
}

action_enabled() { # action_enabled <id> -> 0 offered, 1 withheld
  local _cstate=''
  _cstate="$(catalog_state "$1")"
  [ -z "$_cstate" ] && return 0            # no catalog: take the code at its word
  [ "$_cstate" = "retired" ] || return 0
  action_in_manifest "$1"                  # retired, but still ours to undo
}
action_meta() { printf '%s\n' "$ACTION_DB" | awk -F'|' -v i="$1" '$1==i{print; exit}'; }

action_supported() { # action_supported <id> -> 0 yes, 1 no
  _m="$(action_meta "$1")"
  [ -n "$_m" ] || return 1
  _plats="$(printf '%s' "$_m" | cut -d'|' -f2)"
  case ",$_plats," in *",$SYSOPT_OS,"*) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------

# --- hostname list -----------------------------------------------------------
hosts_names() {
  cat <<'NAMES'
doubleclick.net
googlesyndication.com
googleadservices.com
google-analytics.com
amazon-adsystem.com
adsrvr.org
criteo.com
adnxs.com
rubiconproject.com
pubmedreader.net
taboola.com
outbrain.com
scorecardresearch.com
quantserve.com
moatads.com
graph.facebook.com
pixel.facebook.com
analytics.twitter.com
static.ads-twitter.com
bat.bing.com
NAMES
}

hosts_file() {
  case "$SYSOPT_OS" in
    darwin|bsd) syspath /etc/hosts ;;
    *)          syspath /etc/hosts ;;
  esac
}

BEGIN_MARK='# BEGIN sysopt managed block'
END_MARK='# END sysopt managed block'

action_hosts_block() {
  local _phase
  _phase="$1"
  _hf="$(hosts_file)"
  case "$_phase" in
    plan|apply)
      _tmpd="$(mktemp -d "${TMPDIR:-/tmp}/sysopt.h.XXXXXX")" || return 1
      _base="$_tmpd/base"
      hosts_names >"$_tmpd/names"
      if [ -f "$_hf" ]; then
        awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
          index($0,b)==1 { skip=1; next }
          index($0,e)==1 { skip=0; next }
          skip!=1 { print }' "$_hf" >"$_base"
      else
        : >"$_base"
      fi
      # strip trailing blank lines, then append our block
      awk 'BEGIN{n=0} {line[NR]=$0} END{last=NR; while(last>0 && line[last]=="") last--; for(i=1;i<=last;i++) print line[i]}' "$_base" >"$_tmpd/trim"
      {
        cat "$_tmpd/trim"
        [ -s "$_tmpd/trim" ] && printf '\n'
        printf '%s\n' "$BEGIN_MARK"
        printf '# generated by %s %s — remove this whole block to revert\n' "$SYSOPT_NAME" "$SYSOPT_VERSION"
        printf '# exact hostnames only; A and AAAA records for every name\n'
        # optional user list: one hostname per line, '#' comments, added on top
        if [ -f "$EXTRA_BLOCK" ]; then
          sed 's/#.*//' "$EXTRA_BLOCK" | tr -d ' \t\r' | grep -v '^$' >>"$_tmpd/names" || true
        fi
        # allow list: an exact hostname here is never blocked
        if [ -f "$ALLOW_FILE" ]; then
          sed 's/#.*//' "$ALLOW_FILE" | tr -d ' \t\r' | grep -v '^$' >"$_tmpd/allow" || :
          if [ -s "$_tmpd/allow" ]; then
            grep -vxF -f "$_tmpd/allow" "$_tmpd/names" >"$_tmpd/names2" 2>/dev/null || :
            [ -s "$_tmpd/names2" ] && mv -f "$_tmpd/names2" "$_tmpd/names"
          fi
        fi
        sort -u "$_tmpd/names" -o "$_tmpd/names" 2>/dev/null || true
        _n=0
        while IFS= read -r _name; do
          [ -n "$_name" ] || continue
          case "$_name" in http*|*/*|*' '*) continue ;; esac
          printf '0.0.0.0 %s\n' "$_name"
          printf ':: %s\n' "$_name"
          _n=$(( _n + 1 ))
        done <"$_tmpd/names"
        printf '%s\n' "$END_MARK"
      } >"$_tmpd/new"
      hdr "hosts block: $_hf"
      dim "  names $_n, records $(( _n * 2 ))"
      [ -f "$EXTRA_BLOCK" ] && dim "  extra names from $EXTRA_BLOCK are included"
      [ -f "$ALLOW_FILE" ]  && dim "  names in $ALLOW_FILE are never blocked"
      if [ -f "$_hf" ]; then
        diff -u --label "$_hf (current)" --label "$_hf (proposed)" "$_hf" "$_tmpd/new" 2>/dev/null | head -40 || true
      else
        dim "  (file does not exist yet — it will be created)"
      fi
      if [ "$_phase" = "apply" ]; then
        if [ "${DRY_RUN:-1}" = 1 ]; then dim "  [dry-run] not written"; rm -rf "$_tmpd"; return 0; fi
        if ! is_root && [ -z "${SYSOPT_ROOT:-}" ]; then err "hosts file needs root"; rm -rf "$_tmpd"; return 1; fi
        apply_file hosts "$_hf" "$_tmpd/new" 0644 || { rm -rf "$_tmpd"; return 1; }
      fi
      rm -rf "$_tmpd"
      ;;
    verify)
      if [ ! -f "$_hf" ]; then
        # no file and nothing of ours applied here: nothing to verify, no failure
        if manifest_has hosts; then
          printf 'FAIL\thosts block\t%s does not exist\n' "$_hf"
        else
          printf 'SKIP\thosts block\tno hosts file and nothing applied here\n'
        fi
        return 0
      fi
      _b="$(count "$BEGIN_MARK" "$_hf")"
      _e="$(count "$END_MARK" "$_hf")"
      if [ "$_b" != 1 ] || [ "$_e" != 1 ]; then
        printf 'FAIL\thosts block\t%d begin / %d end markers (want exactly 1 of each)\n' "$_b" "$_e"; return 1
      fi
      _missing="$(hosts_names | while IFS= read -r n; do
        [ -n "$n" ] || continue
        grep -qx "0.0.0.0 $n" "$_hf" 2>/dev/null || printf '%s ' "$n"
        grep -qx ":: $n" "$_hf" 2>/dev/null || printf '%s (AAAA) ' "$n"
      done)"
      if [ -n "$_missing" ]; then printf 'FAIL\thosts block\tmissing: %s\n' "$_missing"; return 1; fi
      printf 'PASS\thosts block\t1 block, every name has A and AAAA\n'
      ;;
    revert)
      [ -f "$_hf" ] || { ok "no hosts file, nothing to revert"; return 0; }
      _bkp="$(backup_for hosts)"
      if [ -n "$_bkp" ] && [ -f "$_bkp" ]; then
        if [ "${DRY_RUN:-1}" = 1 ]; then dim "  [dry-run] would restore $_hf from $_bkp"; return 0; fi
        cp -- "$_bkp" "$_hf.sysopt.revert" && mv -f -- "$_hf.sysopt.revert" "$_hf" \
          && ok "$_hf restored from backup" && manifest_del hosts && return 0
        err "could not restore $_hf"; return 1
      fi
      _tmpd="$(mktemp -d "${TMPDIR:-/tmp}/sysopt.h.XXXXXX")"
      awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        index($0,b)==1 { skip=1; next }
        index($0,e)==1 { skip=0; next }
        skip!=1 { print }' "$_hf" >"$_tmpd/out"
      if [ "${DRY_RUN:-1}" = 1 ]; then dim "  [dry-run] would remove the managed block"; rm -rf "$_tmpd"; return 0; fi
      if ! is_root && [ -z "${SYSOPT_ROOT:-}" ]; then err "hosts file needs root"; rm -rf "$_tmpd"; return 1; fi
      cp -- "$_tmpd/out" "$_hf.sysopt.new" && mv -f -- "$_hf.sysopt.new" "$_hf" \
        && ok "managed block removed from $_hf" && manifest_del hosts
      rm -rf "$_tmpd"
      ;;
  esac
  return 0
}

# --- firefox user.js ---------------------------------------------------------
USERJS_BEGIN='// BEGIN sysopt managed prefs'
USERJS_END='// END sysopt managed prefs'

firefox_profiles() {
  if [ "$SYSOPT_OS" = "darwin" ]; then
    _roots="$HOME/Library/Application Support/Firefox/Profiles"
  else
    _roots="$HOME/.mozilla/firefox"
  fi
  [ -d "$_roots" ] || return 0
  for _d in "$_roots"/*/; do
    [ -d "$_d" ] || continue
    if [ -f "$_d/prefs.js" ] || [ -f "$_d/user.js" ] || [ -f "$_d/times.json" ]; then
      printf '%s\n' "${_d%/}"
    fi
  done
}

PREF_LINES='browser.sessionstore.interval|600000
browser.tabs.unloadOnLowMemory|true
browser.tabs.min_inactive_duration_before_unload|900000
dom.ipc.processCount|4
media.hardware-video-decoding.enabled|true
toolkit.telemetry.enabled|false
datareporting.healthreport.uploadEnabled|false
network.dns.disablePrefetch|true
network.prefetch-next|false
browser.newtab.preload|false
extensions.pocket.enabled|false'

action_firefox_userjs() {
  local _phase
  _phase="$1"
  _profiles="$(firefox_profiles)"
  if [ -z "$_profiles" ]; then
    if [ "$_phase" = "verify" ]; then printf 'SKIP\tfirefox user.js\tno Firefox profile found\n'; fi
    [ "$_phase" = "plan" ] || [ "$_phase" = "apply" ] && dim "  no Firefox profile found — skipped"
    return 0
  fi
  case "$_phase" in
    plan|apply)
      _tmpd="$(mktemp -d "${TMPDIR:-/tmp}/sysopt.f.XXXXXX")" || return 1
      for _p in $_profiles; do
        _src="$_p/user.js"
        # plan runs against a stand-in when the profile has no user.js yet, so
        # that a dry run leaves the profile untouched
        _read="$_src"
        if [ ! -f "$_src" ]; then : >"$_tmpd/empty"; _read="$_tmpd/empty"; fi
        awk -v b="$USERJS_BEGIN" -v e="$USERJS_END" '
          index($0,b)==1 { s=1; next } index($0,e)==1 { s=0; next } s!=1 { print }' "$_read" >"$_tmpd/outside"
        # a pref the user already set outside our block wins — never override
        _dup=""
        while IFS='|' read -r _k _v; do
          [ -n "$_k" ] || continue
          if grep -q "user_pref(\"$_k\"" "$_tmpd/outside" 2>/dev/null; then
            _dup="$_dup $_k"
          fi
        done <<EOF
$PREF_LINES
EOF
        {
          awk 'BEGIN{n=0} {line[NR]=$0} END{last=NR; while(last>0 && line[last]=="") last--; for(i=1;i<=last;i++) print line[i]}' "$_tmpd/outside"
          printf '%s\n' "$USERJS_BEGIN"
          printf '// generated by %s %s — delete this whole block to revert\n' "$SYSOPT_NAME" "$SYSOPT_VERSION"
          while IFS='|' read -r _k _v; do
            [ -n "$_k" ] || continue
            case " $_dup " in *" $_k "*) continue ;; esac
            printf 'user_pref("%s", %s);\n' "$_k" "$_v"
          done <<EOF
$PREF_LINES
EOF
          printf '%s\n' "$USERJS_END"
        } >"$_tmpd/new"
        hdr "firefox profile: $_p"
        [ -n "$_dup" ] && dim "  keeping your own value for:$_dup"
        if [ -f "$_src" ]; then
          diff -u --label "$_src (current)" --label "$_src (proposed)" "$_src" "$_tmpd/new" 2>/dev/null | head -30 || true
        else
          dim "  [new file] $_src does not exist yet; it will be created"
        fi
        if [ "$_phase" = "apply" ]; then
          case "$_p" in "$STATE_DIR"/*) continue ;; esac
          apply_file "userjs-$(basename -- "$_p")" "$_src" "$_tmpd/new" 0644 || true
        fi
      done
      rm -rf "$_tmpd"
      ;;
    verify)
      for _p in $_profiles; do
        _src="$_p/user.js"
        if [ ! -f "$_src" ]; then
          if manifest_has "userjs-$(basename -- "$_p")"; then
            printf 'FAIL\tfirefox user.js\t%s missing\n' "$_src"
          else
            printf 'SKIP\tfirefox user.js\t%s has no user.js and nothing applied\n' "$(basename -- "$_p")"
          fi
          continue
        fi
        _b="$(count "$USERJS_BEGIN" "$_src")"
        if [ "$_b" = 1 ]; then printf 'PASS\tfirefox user.js\t%s\n' "$(basename -- "$_p")"
        else printf 'FAIL\tfirefox user.js\t%s has %s block(s)\n' "$(basename -- "$_p")" "$_b"; fi
      done
      ;;
    revert)
      for _p in $_profiles; do
        _src="$_p/user.js"
        [ -f "$_src" ] || continue
        _bkp="$(backup_for "userjs-$(basename -- "$_p")")"
        if [ -n "$_bkp" ] && [ -f "$_bkp" ]; then
          [ "${DRY_RUN:-1}" = 1 ] && { dim "  [dry-run] would restore $_src"; continue; }
          cp -- "$_bkp" "$_src.sysopt.revert" && mv -f -- "$_src.sysopt.revert" "$_src" \
            && ok "$_src restored" && manifest_del "userjs-$(basename -- "$_p")"
        else
          _tmpf="$(mktemp "${TMPDIR:-/tmp}/sysopt.XXXXXX")"
          awk -v b="$USERJS_BEGIN" -v e="$USERJS_END" '
            index($0,b)==1 { s=1; next } index($0,e)==1 { s=0; next } s!=1 { print }' "$_src" >"$_tmpf"
          # nothing but blank lines left, and the manifest says we created it:
          # the contract is to remove what we created and keep what we found.
          # Without that record, the block is stripped and the file stays.
          _left="$(count '[^[:space:]]' "$_tmpf")"
          if [ "$_left" = 0 ] && [ "$(manifest_note "userjs-$(basename -- "$_p")")" = "created" ]; then
            if [ "${DRY_RUN:-1}" = 1 ]; then
              dim "  [dry-run] would delete $_src (sysopt created it)"; rm -f "$_tmpf"; continue
            fi
            rm -f -- "$_src" && ok "$_src removed (sysopt created it)" \
              && manifest_del "userjs-$(basename -- "$_p")"
            rm -f "$_tmpf"
            continue
          fi
          [ "${DRY_RUN:-1}" = 1 ] && { dim "  [dry-run] would strip the block from $_src"; rm -f "$_tmpf"; continue; }
          cp -- "$_tmpf" "$_src.sysopt.revert" && mv -f -- "$_src.sysopt.revert" "$_src" \
            && ok "managed block removed from $_src" && manifest_del "userjs-$(basename -- "$_p")"
          rm -f "$_tmpf"
        fi
      done
      ;;
  esac
  return 0
}

# --- firefox policy ----------------------------------------------------------
policy_file() {
  case "$SYSOPT_OS" in
    linux|chromebook) syspath /etc/firefox/policies/policies.json ;;
    *) printf '' ;;
  esac
}

action_firefox_policy() {
  local _phase
  _phase="$1"
  _pf="$(policy_file)"
  if [ -z "$_pf" ]; then
    [ "$_phase" = "verify" ] && printf 'SKIP\tfirefox policy\tnot supported on %s\n' "$SYSOPT_OS"
    [ "$_phase" != "verify" ] && dim "  firefox policy: not supported on $SYSOPT_OS (no system policy path)"
    return 0
  fi
  _desired='{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DontCheckDefaultBrowser": true,
    "OfferToSaveLogins": false,
    "NetworkPrediction": false,
    "UserMessaging": {
      "WhatsNew": false,
      "ExtensionRecommendations": false,
      "FeatureRecommendations": false,
      "UrlbarInterventions": false,
      "SkipOnboarding": true,
      "MoreFromMozilla": false
    }
  }
}'
  case "$_phase" in
    plan|apply)
      # only the writing phases need a scratch dir; verify and revert used to
      # create one and return without removing it
      _tmpd="$(mktemp -d "${TMPDIR:-/tmp}/sysopt.p.XXXXXX")" || return 1
      printf '%s\n' "$_desired" >"$_tmpd/want.json"
      if [ -f "$_pf" ]; then
        if ! have jq; then
          warn "jq is not installed — refusing to merge into an existing policy file"
          dim "  install jq, or move the file aside and let sysopt create a fresh one"
          rm -rf "$_tmpd"; return 1
        fi
        if ! jq -e . "$_pf" >/dev/null 2>&1; then
          err "$_pf is not valid JSON — not touching it"; rm -rf "$_tmpd"; return 1
        fi
        # add-only: never overwrite a key that already exists
        jq -s '.[0] as $cur | .[1] as $want
               | $cur * {policies: (($want.policies) + ($cur.policies // {}))}' \
          "$_pf" "$_tmpd/want.json" >"$_tmpd/new.json" 2>/dev/null \
          || { err "merge failed"; rm -rf "$_tmpd"; return 1; }
        if [ "$(jq -S . "$_tmpd/new.json")" = "$(jq -S . "$_pf")" ]; then
          ok "policy already contains everything we add — nothing to do"
          rm -rf "$_tmpd"; return 0
        fi
      else
        cp -- "$_tmpd/want.json" "$_tmpd/new.json"
      fi
      hdr "firefox policy: $_pf"
      if [ -f "$_pf" ]; then
        diff -u --label "$_pf (current)" --label "$_pf (proposed)" "$_pf" "$_tmpd/new.json" 2>/dev/null | head -40 || true
      else
        dim "  (file does not exist yet — it will be created)"
      fi
      if [ "$_phase" = "apply" ]; then
        [ "${DRY_RUN:-1}" = 1 ] && { dim "  [dry-run] not written"; rm -rf "$_tmpd"; return 0; }
        if ! is_root && [ -z "${SYSOPT_ROOT:-}" ]; then err "policy file needs root"; rm -rf "$_tmpd"; return 1; fi
        apply_file firefox-policy "$_pf" "$_tmpd/new.json" 0644 || { rm -rf "$_tmpd"; return 1; }
      fi
      rm -rf "$_tmpd"
      ;;
    verify)
      if [ ! -f "$_pf" ]; then printf 'SKIP\tfirefox policy\tnone present\n'; return 0; fi
      if ! have jq; then printf 'SKIP\tfirefox policy\tjq unavailable, cannot parse\n'; return 0; fi
      if ! jq -e . "$_pf" >/dev/null 2>&1; then printf 'FAIL\tfirefox policy\tinvalid JSON\n'; return 1; fi
      _ok="$(jq -r '.policies.DisableTelemetry == true' "$_pf" 2>/dev/null)"
      if [ "$_ok" = "true" ]; then printf 'PASS\tfirefox policy\tvalid JSON with managed keys\n'
      else printf 'FAIL\tfirefox policy\tmanaged keys absent\n'; fi
      ;;
    revert)
      _bkp="$(backup_for firefox-policy)"
      if [ -n "$_bkp" ] && [ -f "$_bkp" ]; then
        [ "${DRY_RUN:-1}" = 1 ] && { dim "  [dry-run] would restore $_pf"; return 0; }
        cp -- "$_bkp" "$_pf.sysopt.revert" && mv -f -- "$_pf.sysopt.revert" "$_pf" \
          && ok "$_pf restored from backup" && manifest_del firefox-policy
      else
        # no backup: we may delete only if we recorded that we created it
        if [ "$(manifest_note firefox-policy)" = "created" ]; then
          if [ -f "$_pf" ]; then
            [ "${DRY_RUN:-1}" = 1 ] && { dim "  [dry-run] would delete $_pf (created by sysopt)"; return 0; }
            rm -f -- "$_pf" && ok "$_pf removed (sysopt created it)"
          fi
          manifest_del firefox-policy
        else
          warn "no backup on record for $_pf — leaving it untouched"
          dim "  check it yourself, then remove the block by hand if you want it gone"
          return 1
        fi
      fi
      ;;
  esac
  return 0
}

# --- swappiness --------------------------------------------------------------
svc_active() { # svc_active <unit>
  have systemctl || return 1
  systemctl is-active --quiet "$1" 2>/dev/null
}

action_swappiness() {
  local _phase
  _phase="$1"
  _pf_path="$(syspath /proc/sys/vm/swappiness)"
  _dropin="$(syspath /etc/sysctl.d/90-sysopt.conf)"
  case "$_phase" in
    plan|apply)
      if svc_active tlp || svc_active power-profiles-daemon; then
        dim "  swappiness: skipped — tlp/power-profiles-daemon manages kernel VM settings"
        if [ "${FORCE_CPU:-0}" != 1 ]; then return 0; fi
        dim "  --force-cpu given: writing anyway"
      fi
      [ -r "$_pf_path" ] || { dim "  swappiness: not readable on this system, skipped"; return 0; }
      _cur="$(cat "$_pf_path" 2>/dev/null || echo '')"
      dim "  current vm.swappiness = ${_cur:-unknown}, proposed = 10"
      _tmpf="$(mktemp "${TMPDIR:-/tmp}/sysopt.XXXXXX")"
      printf '# managed by %s %s\n# revert: %s revert --id swappiness\nvm.swappiness=10\n' \
        "$SYSOPT_NAME" "$SYSOPT_VERSION" "$SYSOPT_NAME" >"$_tmpf"
      hdr "sysctl drop-in: $_dropin"
      apply_file swappiness "$_dropin" "$_tmpf" 0644 || { rm -f "$_tmpf"; return 1; }
      if [ "$_phase" = "apply" ] && [ "${DRY_RUN:-1}" != 1 ] && [ -z "${SYSOPT_ROOT:-}" ]; then
        if have sysctl; then sysctl -p "$_dropin" >/dev/null 2>&1 && ok "swappiness applied" || warn "sysctl -p failed"; fi
      fi
      rm -f "$_tmpf"
      ;;
    verify)
      [ -r "$_pf_path" ] || { printf 'SKIP\tswappiness\tnot readable\n'; return 0; }
      _cur="$(cat "$_pf_path" 2>/dev/null)"
      if svc_active tlp || svc_active power-profiles-daemon; then
        printf 'SKIP\tswappiness\towned by a power daemon\n'
      elif [ "$_cur" = "10" ]; then printf 'PASS\tswappiness\tvm.swappiness=10\n'
      else printf 'WARN\tswappiness\tvm.swappiness=%s (want 10)\n' "$_cur"; fi
      ;;
    revert)
      _bkp="$(backup_for swappiness)"
      [ "${DRY_RUN:-1}" = 1 ] && { dim "  [dry-run] would remove $_dropin"; return 0; }
      [ -f "$_dropin" ] && rm -f -- "$_dropin" && ok "$_dropin removed"
      if [ -n "$_bkp" ] && [ -f "$_bkp" ]; then
        cp -- "$_bkp" "$_dropin" && ok "$_dropin restored from backup"
      fi
      manifest_del swappiness
      ;;
  esac
  return 0
}

# --- power report (never changes anything) -----------------------------------
action_report_power() {
  local _phase
  _phase="$1"
  _gov=""; _epp=""; _owner="none"
  if [ -r "$(syspath /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" ]; then
    _gov="$(cat "$(syspath /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" 2>/dev/null)"
    _epp="$(cat "$(syspath /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference)" 2>/dev/null)"
  elif have sysctl; then
    _gov="$(sysctl -n dev.cpu.0.freq_levels 2>/dev/null | head -1)"; _epp="n/a"
  fi
  svc_active tlp && _owner="tlp"
  svc_active power-profiles-daemon && _owner="${_owner:+$_owner,}power-profiles-daemon"
  [ "$_owner" = "none" ] && have pmset && _owner="pmset(macos)"
  if [ "$_phase" = "verify" ]; then
    printf 'PASS\tpower state\tgovernor=%s epp=%s owner=%s\n' "${_gov:-unknown}" "${_epp:-n/a}" "$_owner"
    return 0
  fi
  hdr "power state (read-only)"
  kv "governor" "${_gov:-unknown}"
  kv "EPP" "${_epp:-n/a}"
  kv "managed by" "$_owner"
  dim "  sysopt never writes governor or EPP; change them in the daemon that owns them"
  return 0
}

# ---------------------------------------------------------------------------
# command dispatch
# ---------------------------------------------------------------------------
run_phase() { # run_phase <phase> [ids...]
  local _phase='' _ids='' _rc=0 _id=''
  _phase="$1"; shift
  _ids="$*"
  [ -n "$_ids" ] || _ids="$(action_ids)"
  _rc=0
  for _id in $_ids; do
    if ! action_enabled "$_id"; then
      dim "  $_id: withdrawn by the catalog (nothing to do)"
      continue
    fi
    if ! action_supported "$_id"; then
      if [ "$_phase" = "verify" ]; then printf 'SKIP\t%s\tnot supported on %s\n' "$_id" "$SYSOPT_OS"
      else dim "  $_id: not supported on $SYSOPT_OS"; fi
      continue
    fi
    "action_$_id" "$_phase" || _rc=1
  done
  return $_rc
}

cmd_detect() {
  detect_os; detect_arch; detect_cpu; detect_mem
  hdr "$SYSOPT_NAME $SYSOPT_VERSION — system"
  kv "os"            "$SYSOPT_OS ($SYSOPT_OS_NAME)"
  kv "os version"    "${SYSOPT_OS_VERSION:-unknown}"
  kv "container/vm"  "${SYSOPT_CONTAINER:-no}"
  kv "architecture"  "$SYSOPT_ARCH (uname: ${SYSOPT_ARCH_RAW:-unknown})"
  kv "cpu"           "${SYSOPT_CPU_MODEL:-unknown}"
  kv "cores (online)" "${SYSOPT_CPU_CORES:-unknown}"
  kv "ram total"     "${SYSOPT_RAM_MB:-unknown} MB"
  kv "swap total"    "${SYSOPT_SWAP_MB:-unknown} MB"
  kv "root"          "$(is_root && echo yes || echo no)"
  kv "staged root"   "${SYSOPT_ROOT:-none (live system)}"
  hdr "capabilities on this platform"
  action_ids | while IFS= read -r _id; do
    _m="$(action_meta "$_id")"
    _needs="$(printf '%s' "$_m" | cut -d'|' -f3)"
    _risk="$(printf '%s' "$_m" | cut -d'|' -f4)"
    _sum="$(printf '%s' "$_m" | cut -d'|' -f5)"
    if action_supported "$_id"; then _st="available"; else _st="not-supported"; fi
    printf '  %-18s %-14s %-12s %s\n' "$_id" "$_st" "risk:$_risk" "$_sum"
  done
  return 0
}

cmd_list() {
  hdr "actions on $SYSOPT_OS / $SYSOPT_ARCH"
  action_ids | while IFS= read -r _id; do
    action_enabled "$_id" || continue
    _m="$(action_meta "$_id")"
    if action_supported "$_id"; then _st="available"; else _st="not-supported"; fi
    printf '  %-18s %-14s %s\n' "$_id" "$_st" "$(printf '%s' "$_m" | cut -d'|' -f5)"
    if [ "$_st" = "not-supported" ]; then
      printf '  %-18s %-14s supported on: %s\n' '' '' "$(printf '%s' "$_m" | cut -d'|' -f2 | tr ',' ' ')"
    fi
  done
  printf '\n  nothing above is written without --apply.\n'
  return 0
}

cmd_status() {
  detect_os; detect_arch
  hdr "$SYSOPT_NAME $SYSOPT_VERSION — status"
  kv "os"        "$SYSOPT_OS"
  kv "arch"      "$SYSOPT_ARCH"
  kv "state dir" "$STATE_DIR"
  kv "config dir" "$CONFIG_DIR"
  kv "manifest"  "$([ -f "$MANIFEST" ] && wc -l <"$MANIFEST" | tr -d ' ' || echo 0) item(s)"
  if [ -f "$MANIFEST" ]; then
    hdr "managed items"
    awk -F'\t' '{printf "  %-24s %-10s %s\n", $1, $2, $3}' "$MANIFEST"
  fi
  _pend="$(journal_pending)"
  if [ -n "$_pend" ]; then
    hdr "interrupted operations"
    printf '%s\n' "$_pend" | while IFS= read -r _p; do [ -n "$_p" ] && printf '  %s (started, never confirmed)\n' "$_p"; done
    dim "  run: $SYSOPT_NAME doctor"
  fi
  return 0
}

cmd_catalog() {
  local _id='' _st='' _since='' _until='' _note='' _live=''
  hdr "catalog"
  if [ -z "${CATALOG:-}" ] || [ ! -f "$CATALOG" ]; then
    dim "  no catalog in this tree; every action the code knows is offered"
    action_ids | while IFS= read -r _id; do printf '  %-18s %s\n' "$_id" "available"; done
    return 0
  fi
  printf '  %-18s %-10s %-8s %s\n' ACTIONS STATUS SINCE NOTE
  action_ids | while IFS= read -r _id; do
    _st="$(catalog_state "$_id")"; [ -n "$_st" ] || _st="not-listed"
    _since="$(catalog_field "$_id" 3)"
    _note="$(catalog_field "$_id" 5)"
    if action_in_manifest "$_id"; then _live=" (applied here)"; else _live=""; fi
    printf '  %-18s %-10s %-8s %s%s\n' "$_id" "$_st" "${_since:--}" "$_note" "$_live"
  done
  printf '\n  the catalog decides what is offered; it never contains code.\n'
  printf '  a retired action still reverts anything this machine already has.\n'
  return 0
}

cmd_plan()     { run_phase plan "$@" ; }
cmd_apply()    { run_phase apply "$@" ; }
# render verify rows (TSV: STATUS<TAB>WHAT<TAB>DETAIL) the same way everywhere
print_rows() {
  local _l=''
  while IFS= read -r _l; do
    case "$_l" in
      PASS*) printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$(printf '%s' "$_l" | cut -f2- | tr '\t' ' ')" ;;
      FAIL*) printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$(printf '%s' "$_l" | cut -f2- | tr '\t' ' ')" ;;
      WARN*) printf '  %sWARN%s %s\n' "$C_Y" "$C_0" "$(printf '%s' "$_l" | cut -f2- | tr '\t' ' ')" ;;
      SKIP*) printf '  %sSKIP%s %s\n' "$C_D" "$C_0" "$(printf '%s' "$_l" | cut -f2- | tr '\t' ' ')" ;;
      '')    : ;;
      *)     printf '  %s\n' "$_l" ;;
    esac
  done
}

# --- update ---------------------------------------------------------------
# Deliberately offline. You obtain the new tree however you like (git pull, a
# tarball, a USB stick); this command is the part that decides whether it is
# safe to install: it stages it, proves it parses, runs its own test suite
# against a throwaway root, shows what the catalog adds or retires, and only
# then swaps files — keeping the previous version for one-command rollback.
#
# There is no URL here and there never will be: a download path with no pinned
# hash is how a "fail-safe" tool stops being one.
update_catalog_diff() { # update_catalog_diff <old> <new>
  local _old='' _new=''
  _old="${1:-}"; _new="${2:-}"
  if [ -f "$_new" ]; then
    if [ -f "$_old" ]; then
      while IFS="$(printf '\t')" read -r _id _st _rest; do
        [ -n "$_id" ] || continue
        if ! awk -F'\t' -v i="$_id" '$1==i{f=1} END{exit !f}' "$_old"; then
          printf '  + new action   %s (%s)\n' "$_id" "${_st:-stable}"
        fi
      done <"$_new"
      while IFS="$(printf '\t')" read -r _id _st _rest; do
        [ -n "$_id" ] || continue
        if awk -F'\t' -v i="$_id" '$1==i{f=1} END{exit !f}' "$_new"; then :; else
          printf '  - withdrawn    %s\n' "$_id"
        fi
      done <"$_old"
    else
      dim "  (no catalog installed yet; the candidate brings one)"
    fi
  fi
}

cmd_update() {
  local _from='' _apply=0 _notest=0 _fulltest=0 _rollback=0 _home='' _work='' _prev='' _ts=''
  local _old_ver='' _new_ver='' _rc=0
  # the launcher has already parsed these; the library API keeps the flags too
  _from="${SYSOPT_UPD_FROM:-}"
  [ "${SYSOPT_UPD_NOTEST:-0}" = 1 ] && _notest=1
  [ "${SYSOPT_UPD_FULLTEST:-0}" = 1 ] && _fulltest=1
  [ "${SYSOPT_UPD_ROLLBACK:-0}" = 1 ] && _rollback=1
  [ "${DRY_RUN:-1}" = 1 ] || _apply=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from)      _from="${2:-}"; shift ;;
      --from=*)    _from="${1#--from=}" ;;
      --apply)     _apply=1 ;;
      --no-test)   _notest=1 ;;
      --full-test) _fulltest=1 ;;
      --rollback)  _rollback=1 ;;
      *)           err "update: unknown option: $1"; return $EX_USAGE ;;
    esac
    shift
  done

  _home="${SYSOPT_HOME:-}"
  if [ -z "$_home" ]; then
    err "SYSOPT_HOME is not set — run this through bin/sysopt, not the library"
    return $EX_USAGE
  fi

  if [ "$_rollback" = 1 ]; then
    _prev="$STATE_DIR/update/prev/latest"
    if [ ! -d "$_prev" ]; then err "nothing to roll back to"; return $EX_FAIL; fi
    hdr "rollback"
    dim "  from $_prev"
    if [ "${DRY_RUN:-1}" = 1 ]; then
      dim "  [dry-run] would restore bin/ and lib/; re-run with --apply"
      return 0
    fi
    cp -- "$_prev/bin/sysopt" "$_home/bin/.sysopt.upd" && mv -f -- "$_home/bin/.sysopt.upd" "$_home/bin/sysopt" \
      || { err "rollback of bin/sysopt failed"; return $EX_FAIL; }
    cp -- "$_prev/lib/sysopt.sh" "$_home/lib/.sysopt.upd" && mv -f -- "$_home/lib/.sysopt.upd" "$_home/lib/sysopt.sh" \
      || { err "rollback of lib/sysopt.sh failed"; return $EX_FAIL; }
    chmod 0755 "$_home/bin/sysopt" "$_home/lib/sysopt.sh" 2>/dev/null || true
    ok "rolled back to $("$_home/bin/sysopt" version 2>/dev/null | head -1)"
    return 0
  fi

  if [ -z "$_from" ]; then
    err "usage: $SYSOPT_NAME update --from <directory> [--apply] [--no-test|--full-test]"
    dim "  get a newer tree yourself (git pull, tarball, USB), then point this at it"
    return $EX_USAGE
  fi
  [ -d "$_from" ] || { err "not a directory: $_from"; return $EX_USAGE; }

  local _f=''
  for _f in bin/sysopt lib/sysopt.sh; do
    [ -f "$_from/$_f" ] || { err "$_from is not a sysopt tree (missing $_f)"; return $EX_USAGE; }
  done

  _work="$(mktemp -d "${TMPDIR:-/tmp}/sysopt.update.XXXXXX")" || return $EX_FAIL
  mkdir -p "$_work/bin" "$_work/lib"
  cp -R -- "$_from/bin/." "$_work/bin/" 2>/dev/null || cp -- "$_from/bin/sysopt" "$_work/bin/sysopt"
  cp -R -- "$_from/lib/." "$_work/lib/" 2>/dev/null || cp -- "$_from/lib/sysopt.sh" "$_work/lib/sysopt.sh"
  if [ -f "$_from/contrib/catalog/actions.tsv" ]; then
    mkdir -p "$_work/contrib/catalog"
    cp -- "$_from/contrib/catalog/actions.tsv" "$_work/contrib/catalog/actions.tsv"
  fi
  [ -d "$_from/tests" ] && cp -R -- "$_from/tests" "$_work/tests"

  hdr "update candidate: $_from"

  # 1. it has to parse before it is allowed anywhere near the install
  if ! sh -n "$_work/lib/sysopt.sh" 2>"$_work/syntax.log"; then
    err "the candidate library does not parse"; sed -n '1,10p' "$_work/syntax.log"
    rm -rf "$_work"; return $EX_FAIL
  fi
  if ! sh -n "$_work/bin/sysopt" 2>>"$_work/syntax.log"; then
    err "the candidate launcher does not parse"; sed -n '1,10p' "$_work/syntax.log"
    rm -rf "$_work"; return $EX_FAIL
  fi
  ok "candidate parses"

  _old_ver="$(sed -n 's/^SYSOPT_VERSION="\(.*\)"/\1/p' "$_home/lib/sysopt.sh" 2>/dev/null | head -1)"
  _new_ver="$(sed -n 's/^SYSOPT_VERSION="\(.*\)"/\1/p' "$_work/lib/sysopt.sh" 2>/dev/null | head -1)"
  dim "  installed $_old_ver  ->  candidate $_new_ver"

  hdr "catalog changes"
  update_catalog_diff "$_home/contrib/catalog/actions.tsv" "$_work/contrib/catalog/actions.tsv"

  # 2. the candidate must actually run. A parse check proves it is sh; this
  #    proves it works: plan and verify against a throwaway root, where every
  #    absolute path is staged and nothing real can be touched.
  hdr "candidate smoke test"
  _root="$(mktemp -d "${TMPDIR:-/tmp}/sysopt.root.XXXXXX")" || { rm -rf "$_work"; return $EX_FAIL; }
  mkdir -p "$_root/etc"
  if ( cd "$_work" && sh bin/sysopt --root "$_root" --state "$_work/.state" plan >"$_work/plan.log" 2>&1 ); then
    ok "candidate plans cleanly against a staged root"
  else
    err "the candidate cannot even produce a plan — refusing to install it"
    tail -n 10 "$_work/plan.log" 2>/dev/null | sed 's/^/    /'
    rm -rf "$_work" "$_root"; return $EX_FAIL
  fi
  if ( cd "$_work" && sh bin/sysopt --root "$_root" --state "$_work/.state" verify >"$_work/verify.log" 2>&1 ); then
    ok "candidate verifies cleanly"
  else
    err "the candidate fails its own verification — refusing to install it"
    tail -n 10 "$_work/verify.log" 2>/dev/null | sed 's/^/    /'
    rm -rf "$_work" "$_root"; return $EX_FAIL
  fi
  rm -rf "$_root"

  # 3. the full suite on request, never by default: it is slow, and running a
  #    test suite that can invoke `update` from inside `update` needs the guard
  if [ "$_fulltest" = 1 ]; then
    if [ -d "$_work/tests" ]; then
      hdr "candidate full test suite"
      if ( cd "$_work" && SYSOPT_UNDER_UPDATE=1 sh tests/run_tests.sh >"$_work/test.log" 2>&1 ); then
        ok "candidate passes its own suite"
      else
        err "the candidate fails its own suite — refusing to install it"
        tail -n 12 "$_work/test.log" 2>/dev/null | sed 's/^/    /'
        rm -rf "$_work"; return $EX_FAIL
      fi
    else
      warn "--full-test requested but the candidate has no tests/ directory"
    fi
  fi

  if [ "$_apply" != 1 ]; then
    say ""
    say "  dry-run: nothing installed. re-run with --apply to install $_new_ver"
    rm -rf "$_work"; return 0
  fi

  # 3. keep the old tree, swap atomically, prove the new one runs
  _ts="$(date -u +%Y%m%d-%H%M%S)"
  _prev="$STATE_DIR/update/prev/$_ts"
  mkdir -p "$_prev" || { err "cannot create $_prev"; rm -rf "$_work"; return $EX_FAIL; }
  cp -R -- "$_home/bin" "$_prev/bin" && cp -R -- "$_home/lib" "$_prev/lib" \
    || { err "cannot back up the installed tree; refusing to update"; rm -rf "$_work"; return $EX_FAIL; }
  if [ -d "$_home/contrib/catalog" ]; then cp -R -- "$_home/contrib/catalog" "$_prev/catalog" 2>/dev/null || :; fi

  cp -- "$_work/bin/sysopt" "$_home/bin/.sysopt.upd" && mv -f -- "$_home/bin/.sysopt.upd" "$_home/bin/sysopt" \
    || { err "cannot replace bin/sysopt"; rm -rf "$_work"; return $EX_FAIL; }
  cp -- "$_work/lib/sysopt.sh" "$_home/lib/.sysopt.upd" && mv -f -- "$_home/lib/.sysopt.upd" "$_home/lib/sysopt.sh" \
    || { err "cannot replace lib/sysopt.sh"; rm -rf "$_work"; return $EX_FAIL; }
  chmod 0755 "$_home/bin/sysopt" "$_home/lib/sysopt.sh" 2>/dev/null || true
  if [ -f "$_work/contrib/catalog/actions.tsv" ]; then
    mkdir -p "$_home/contrib/catalog" 2>/dev/null || true
    cp -- "$_work/contrib/catalog/actions.tsv" "$_home/contrib/catalog/actions.tsv" 2>/dev/null || :
  fi
  ln -sfn "$_prev" "$STATE_DIR/update/prev/latest" 2>/dev/null || true

  if ! "$_home/bin/sysopt" version >/dev/null 2>&1; then
    err "the new version does not start — rolling back automatically"
    cp -- "$_prev/bin/sysopt" "$_home/bin/sysopt"
    cp -- "$_prev/lib/sysopt.sh" "$_home/lib/sysopt.sh"
    chmod 0755 "$_home/bin/sysopt" "$_home/lib/sysopt.sh" 2>/dev/null || true
    rm -rf "$_work"; return $EX_FAIL
  fi

  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_old_ver" "$_new_ver" >>"$STATE_DIR/update.log"
  rm -rf "$_work"
  ok "updated $_old_ver -> $_new_ver"
  say "  previous version kept at $_prev"
  say "  undo with: $SYSOPT_NAME update --rollback --apply"
  return 0
}

cmd_verify() {
  detect_os; detect_arch
  hdr "verification"
  _out="$(run_phase verify "$@" 2>&1)"
  printf '%s\n' "$_out" | print_rows
  _fails="$(printf '%s\n' "$_out" | grep -c '^FAIL' | head -n 1)"
  if [ "$_fails" = 0 ]; then ok "no failures"; return 0; fi
  err "$_fails check(s) failed"; return 1
}

cmd_revert() {
  local _id='' _ids='' _i=''
  _id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) _id="${2:-}"; shift ;;
      --all) _id="ALL" ;;
      *) : ;;
    esac
    shift
  done
  detect_os
  if [ -z "$_id" ]; then err "usage: $SYSOPT_NAME revert --id <id> | --all"; return $EX_USAGE; fi
  if [ "$_id" = "ALL" ]; then
    _ids="$(awk -F'\t' '{print $1}' "$MANIFEST" 2>/dev/null | sed 's/^hosts$/hosts_block/; s/^userjs-.*/firefox_userjs/; s/^firefox-policy$/firefox_policy/' | sort -u)"
    [ -n "$_ids" ] || { ok "nothing managed"; return 0; }
  else
    _ids="$(printf '%s' "$_id" | tr '-' '_')"
  fi
  for _i in $_ids; do
    if ! printf '%s\n' "$(action_ids)" | grep -qx "$_i"; then
      err "unknown action: $_i"; return $EX_USAGE
    fi
    "action_$_i" revert || return 1
  done
  # a revert is a write like any other: it needs --apply and is a plan otherwise
  if [ "${DRY_RUN:-1}" = 1 ]; then
    dim "  [dry-run] nothing was reverted — re-run with --apply to actually revert: $_ids"
  else
    ok "reverted: $_ids"
  fi
  return 0
}

cmd_doctor() {
  local _warn=0 _pend='' _missing=0
  detect_os; detect_arch
  hdr "doctor — read-only"
  _warn=0
  _pend="$(journal_pending)"
  if [ -n "$_pend" ]; then
    warn "interrupted operation(s): $(printf '%s' "$_pend" | tr '\n' ' ')"
    dim "  a write started but was never confirmed; check the file, then re-run apply"
    _warn=$(( _warn + 1 ))
  else
    ok "journal clean (no interrupted writes)"
  fi
  if [ -f "$MANIFEST" ]; then
    _missing=0
    while IFS='	' read -r _id _kind _path _bkp _root _note; do
      [ -n "$_path" ] || continue
      [ -e "$_path" ] || { warn "manifest lists $_id but $_path is gone"; _missing=$(( _missing + 1 )); }
    done <"$MANIFEST"
    [ "$_missing" = 0 ] && ok "every managed path is present"
    _warn=$(( _warn + _missing ))
  else
    ok "nothing applied yet"
  fi
  if have jq; then ok "jq present (JSON merges possible)"; else warn "jq absent — existing JSON policy files will not be merged"; _warn=$(( _warn + 1 )); fi
  svc_active tlp && dim "  tlp is active: governor, EPP and vm.dirty_* are left to it"
  svc_active power-profiles-daemon && dim "  power-profiles-daemon is active: governor/EPP left to it"
  if [ "$_warn" = 0 ]; then hdr "result"; ok "no known-harmful state"; return 0; fi
  hdr "result"; warn "$_warn item(s) need attention"; return 0
}

cmd_version() {
  say "$SYSOPT_NAME $SYSOPT_VERSION (schema $SYSOPT_SCHEMA)"
  kv "platform" "$SYSOPT_OS/$SYSOPT_ARCH"
  if [ -n "${SYSOPT_SELF:-}" ] && [ -r "$SYSOPT_SELF" ]; then
    if have sha256sum; then kv "sha256" "$(sha256sum -- "$SYSOPT_SELF" | cut -d' ' -f1)"
    elif have shasum; then kv "sha256" "$(shasum -a 256 "$SYSOPT_SELF" | cut -d' ' -f1)"; fi
  fi
  return 0
}

usage() {
  cat <<EOF
$SYSOPT_NAME $SYSOPT_VERSION — portable, reversible system tuning

usage: $SYSOPT_NAME <command> [options]

commands
  detect                 describe this system and what is supported here
  list                   list available actions
  plan                   show every change that would be made (default, writes nothing)
  apply                  plan, ask once, apply, then verify — the whole workflow
  verify                 check the current state and print PASS/FAIL per item
  status                 what is applied, where, with which backups
  doctor                 read-only diagnosis, including interrupted writes
  revert --id <id>       undo one item      (needs --apply; a plan otherwise)
  revert --all           undo everything sysopt manages
  catalog                what is offered here, and what the catalog retired
  update --from <dir>    stage a newer tree, test it, then install it
  update --rollback      put the previous version back
  version                version, platform, checksum of this file

options
  --apply                write without asking; same consent as typing "y"
                         (without it, apply asks first, and revert only plans)
  --dry-run              explicit no-op; same as the default, never writes
  --only <id[,id]>       restrict to these actions
  --force-cpu            write CPU/VM knobs even if tlp/ppd is active (explicit override)
  --yes                  do not ask for confirmation
  --state <dir>          override the state directory
  --root <dir>           stage every absolute path under <dir> (testing/CI)
  --quiet                less output
  -h, --help             this text

exit codes
  0 ok   1 failure   2 usage   3 unsupported platform   130 cancelled

safety
  * nothing is written without --apply, --yes, or a typed "y" at the prompt
  * every write is backed up, journalled and listed in a manifest
  * merges are add-only; existing keys are never overwritten or weakened
  * knobs owned by tlp / power-profiles-daemon are skipped, never raced
  * revert restores the original bytes, byte for byte
EOF
}
