#!/bin/sh
#
# QuasarDNS installer for Asuswrt-Merlin
#
#   From a clone / zip :  sh install.sh
#   One-liner          :  curl -fsL https://raw.githubusercontent.com/imanubdesigner/QuasarDNS/master/install.sh | sh
#

REPO_RAW="https://raw.githubusercontent.com/imanubdesigner/QuasarDNS/master"
JFFS_DIR="${QUASARDNS_JFFS:-/jffs}"
DEST="$JFFS_DIR/scripts/quasardns"
TMP="/tmp/quasardns.install.$$"

abort() { echo "[X] $*" >&2; rm -f "$TMP" "$DEST.new"; exit 1; }

echo "=== QuasarDNS installer ==="
mkdir -p "$JFFS_DIR/scripts" || abort "cannot create $JFFS_DIR/scripts"

# use the copy next to this installer if there is one, otherwise download it
if [ -f ./quasardns.sh ]; then
	SRC=./quasardns.sh
	echo "Using local ./quasardns.sh"
else
	# no "command -v curl": on some BusyBox ash builds (Merlin 386.x) it fails to find external commands
	echo "Downloading quasardns.sh..."
	curl -fsL --retry 3 --connect-timeout 10 --max-time 60 "$REPO_RAW/quasardns.sh" -o "$TMP" \
		|| abort "download failed (is curl available and the router online?)"
	SRC="$TMP"
fi

# sanity checks before replacing anything
sh -n "$SRC" 2>/dev/null || abort "$SRC is not a valid shell script"
grep -q '^readonly SCRIPT_NAME="quasardns"$' "$SRC" || abort "$SRC does not look like QuasarDNS"

if ! cp "$SRC" "$DEST.new"; then abort "cannot write $DEST"; fi
chmod 0755 "$DEST.new"
mv -f "$DEST.new" "$DEST" || abort "cannot write $DEST"
rm -f "$TMP"
echo "Installed to $DEST"

# dependencies (bind-dig), hooks, migration from v1.x
sh "$DEST" install || abort "setup failed"

# optional: schedule the automatic check (only when a terminal is available)
ans=n
if [ -r /dev/tty ]; then
	printf '\nEnable automatic checks (every 3 days at 04:00, applies only when clearly faster)? [y/N] '
	{ read -r ans < /dev/tty; } 2>/dev/null || ans=n
fi
case "$ans" in
	y|Y) sh "$DEST" --enable ;;
	*)   echo "Automatic mode is off. Turn it on any time from the menu or with: quasardns --enable" ;;
esac

echo ""
echo "Running a dry-run (no changes)..."
sh "$DEST" --dry-run

echo ""
echo "Done. Open the menu with:  sh $DEST"
echo "Apply the best DNS with:   sh $DEST --apply"
