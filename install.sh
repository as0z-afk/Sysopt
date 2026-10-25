#!/bin/sh
# =============================================================================
#  sysopt installer — local files only. Nothing is downloaded, nothing is
#  fetched from the network, no pipe-to-shell. You clone the repo, you run this.
#
#    sh install.sh                 install for the current user
#    sh install.sh --prefix DIR    install under DIR (default ~/.local)
#    sh install.sh --uninstall     remove it again
#    sh install.sh --dry-run       show what would happen
# =============================================================================
set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 1
PREFIX="${PREFIX:-$HOME/.local}"
DRY=0
UNINSTALL=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)    PREFIX="${2:-}"; [ -n "$PREFIX" ] || { echo "install: --prefix needs a value" >&2; exit 2; }; shift ;;
    --prefix=*)  PREFIX="${1#--prefix=}" ;;
    --uninstall) UNINSTALL=1 ;;
    --dry-run)   DRY=1 ;;
    -h|--help)   sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "install: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

SHARE="$PREFIX/share/sysopt"
BINDIR="$PREFIX/bin"
LINK="$BINDIR/sysopt"

say() { printf '%s\n' "$*"; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }
act() { if [ "$DRY" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else eval "$*"; fi; }

if [ "$UNINSTALL" = 1 ]; then
  say "removing sysopt from $PREFIX"
  [ -L "$LINK" ] && act "rm -f -- '$LINK'"
  act "rm -rf -- '$SHARE'"
  say "done. your state dir (~/.config/sysopt or \$SYSOPT_STATE) is kept;"
  say "run 'sysopt revert --all --apply' first if anything is still applied."
  exit 0
fi

[ -r "$HERE/bin/sysopt" ] || die "bin/sysopt not found next to this script"
[ -r "$HERE/lib/sysopt.sh" ] || die "lib/sysopt.sh not found next to this script"

# the core must at least parse before we install it
sh -n "$HERE/lib/sysopt.sh" || die "lib/sysopt.sh does not parse; refusing to install"
sh -n "$HERE/bin/sysopt" || die "bin/sysopt does not parse; refusing to install"

say "installing sysopt"
say "  from   $HERE"
say "  share  $SHARE"
say "  bin    $LINK"

act "mkdir -p -- '$SHARE/lib' '$SHARE/bin' '$SHARE/contrib/catalog' '$BINDIR'"
act "cp -- '$HERE/lib/sysopt.sh' '$SHARE/lib/sysopt.sh'"
act "cp -- '$HERE/bin/sysopt' '$SHARE/bin/sysopt'"
act "chmod 0755 '$SHARE/bin/sysopt' '$SHARE/lib/sysopt.sh'"
# the catalog ships with the tool: it decides what is offered, and what was retired
if [ -f "$HERE/contrib/catalog/actions.tsv" ]; then
  act "cp -- '$HERE/contrib/catalog/actions.tsv' '$SHARE/contrib/catalog/actions.tsv'"
fi

if [ "$DRY" != 1 ]; then
  # a relative symlink keeps the install relocatable
  if [ -L "$LINK" ] || [ -e "$LINK" ]; then rm -f -- "$LINK"; fi
  ln -s ../share/sysopt/bin/sysopt "$LINK" 2>/dev/null \
    || cp -- "$SHARE/bin/sysopt" "$LINK"
  chmod 0755 "$LINK" 2>/dev/null || true
fi

say ""
say "installed. check it:"
say "  $LINK detect"
case ":$PATH:" in
  *":$BINDIR:"*) : ;;
  *) say ""
     say "note: $BINDIR is not on your PATH. add it with:"
     say "  export PATH=\"$BINDIR:\$PATH\"" ;;
esac
say ""
say "the first real step is always the read-only one:"
say "  sysopt plan"
