#!/bin/sh
#
# QuasarDNS installer for Asuswrt-Merlin
#
#   From a clone / zip :  sh install.sh
#   Over SSH           :  curl -fsL -o /tmp/install.sh \
#                          https://raw.githubusercontent.com/imanubdesigner/QuasarDNS/master/install.sh \
#                        && sh /tmp/install.sh
#
# Download it to a file rather than piping it into `sh`: with `curl ... | sh`
# the shell's stdin is the pipe, so the question below cannot be answered and
# the automatic mode is left off without explanation.
#
# Run it from an interactive SSH session (ssh -t) to be asked about the
# automatic mode. Without a terminal nothing is asked and nothing is changed:
# the installer only says what it would have done.

REPO_RAW="https://raw.githubusercontent.com/imanubdesigner/QuasarDNS/master"
JFFS_DIR="${QUASARDNS_JFFS:-/jffs}"
DEST="$JFFS_DIR/scripts/quasardns"
TMP="/tmp/quasardns.install.$$"

abort() { echo "[X] $*" >&2; rm -f "$TMP" "$DEST.new"; exit 1; }

# A prompt is only useful when there is a terminal to read the answer from:
# `ssh 'cmd'` without -t leaves stdin without a TTY, so read would hit EOF and
# silently take the default. Detect that and say so instead of pretending to
# ask. Only fd 0 is tested: ask() runs inside a command substitution, so its
# stdout is a pipe and `[ -t 1 ]` would always fail.
have_tty() { [ -t 0 ]; }

ask() { # ask <question> -> echoes y or n on stdout
	have_tty || return 1
	# the prompt goes to stderr: stdout is the pipe of the command substitution
	# this runs in, so printing there would prepend the question to the answer
	printf '%s [y/N] ' "$1" >&2
	read -r _ans
	case "$_ans" in y|Y) echo y ;; *) echo n ;; esac
}

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

# checks, hooks, migration from v1.x
sh "$DEST" install || abort "setup failed"

# Measurement dependency. Optional: without it QuasarDNS falls back to BusyBox
# nslookup, which works but times whole processes with a 10 ms clock and adds
# its own queries to the resolver under test, so the ranking is unreliable.
DRILL=/opt/bin/drill
TIMEOUT_BIN=/opt/bin/timeout
if [ -x "$DRILL" ] && [ -x "$TIMEOUT_BIN" ]; then
	MEASURE_OK=1
	echo "Measurement: drill ($DRILL) + timeout — 1 ms resolution."
else
	MEASURE_OK=0
	echo ""
	echo "[!] Measurement dependencies missing: drill and/or coreutils-timeout."
	echo "    QuasarDNS will still work, falling back to BusyBox nslookup, but that"
	echo "    times whole processes with a 10 ms clock and issues extra queries to the"
	echo "    resolver under test — enough to make the ranking unreliable."
	echo "    Recommended:  opkg update && opkg install drill coreutils-timeout"
	if [ -x /opt/bin/opkg ]; then
		if ask "Install them now with opkg?" >/dev/null; then
			if opkg update >/dev/null 2>&1 && opkg install drill coreutils-timeout >/dev/null 2>&1; then
				MEASURE_OK=1
				echo "[OK] Installed: measurement now uses drill."
			else
				echo "[X] opkg failed — continuing on the nslookup fallback."
			fi
		else
			echo "    Skipped. You can install them later with the command above."
		fi
	else
		echo "    Entware (opkg) not found, so they cannot be installed automatically."
	fi
fi

# optional: schedule the automatic check
if grep -qs '^AUTO=enabled' "$JFFS_DIR/addons/quasardns.d/config"; then
	echo ""
	echo "Automatic mode is already enabled: leaving it as it is."
elif _a=$(ask "Enable automatic checks (every 3 days at 04:00, applies only when clearly faster)?"); then
	echo ""
	case "$_a" in
		y) echo "Enabling automatic checks..."; sh "$DEST" --enable ;;
		*) echo "Automatic mode is off. Turn it on any time with: sh $DEST --enable" ;;
	esac
else
	echo ""
	echo "Automatic mode is OFF (no terminal attached, so nothing was asked)."
	echo "  turn it on with:   sh $DEST --enable"
	echo "  look around first: sh $DEST          # interactive menu"
fi

echo ""
if [ "$MEASURE_OK" = "1" ]; then
	echo "Running a dry-run (no changes, about a minute with drill)..."
else
	echo "Running a dry-run (no changes, about two minutes on the nslookup fallback)..."
fi
sh "$DEST" --dry-run

cat <<EOF

=== installed ===
  menu        sh $DEST
  try it      sh $DEST --dry-run     # benchmark, changes nothing
  apply best  sh $DEST --apply
  undo        sh $DEST --rollback
  remove      sh $DEST uninstall
EOF
