#!/bin/sh
#
# QuasarDNS - Find the fastest DNS for your Asuswrt-Merlin router
# https://github.com/imanubdesigner/QuasarDNS
#
# Add-on for Asuswrt-Merlin, amtm-ready. POSIX sh / BusyBox ash.
# Requires: dig  (Entware: opkg install bind-dig)
#
# License: MIT
#

readonly SCRIPT_NAME="quasardns"
readonly SCRIPT_VERSION="v2.0.0"
readonly SCRIPT_TITLE="QuasarDNS"
readonly SCRIPT_REPO="https://raw.githubusercontent.com/imanubdesigner/QuasarDNS/master"
readonly SCRIPT_URL="$SCRIPT_REPO/quasardns.sh"

# JFFS root can be overridden for testing (QUASARDNS_JFFS=/some/dir)
JFFS_DIR="${QUASARDNS_JFFS:-/jffs}"
readonly SCRIPT_PATH="$JFFS_DIR/scripts/$SCRIPT_NAME"
readonly RUN_CMD="sh $SCRIPT_PATH"
readonly ADDON_DIR="$JFFS_DIR/addons/$SCRIPT_NAME.d"
readonly CFG_FILE="$ADDON_DIR/config"
readonly STATE_FILE="$ADDON_DIR/previous_dns"
readonly LOG_FILE="$ADDON_DIR/$SCRIPT_NAME.log"
readonly HOOK_FILE="$JFFS_DIR/scripts/services-start"
readonly HOOK_MARK="# QuasarDNS"
readonly CRON_ID="QuasarDNS"
readonly LOCK_DIR="/tmp/$SCRIPT_NAME.lock"
readonly TIMEOUT_PENALTY=5000

# Firmware tools FIRST, Entware last. Under cron/services LD_LIBRARY_PATH points at the
# firmware libraries: Entware binaries (grep, date...) found first in PATH then fail with
# "relocation error" and the script silently breaks. Only dig is taken from /opt (see dig_run).
PATH="${QUASARDNS_SYSPATH:-/sbin:/bin:/usr/sbin:/usr/bin}:$PATH:/opt/sbin:/opt/bin"   # QUASARDNS_SYSPATH: testing only
export PATH

# Domains queried against every resolver (same idea as dnsspeedtest.online)
HOSTS="google.com youtube.com wikipedia.org"

# Name|profile|primary|secondary
#   plain    = no filtering (the fastest of these can be picked freely)
#   security = blocks malware / phishing by default
#   ads      = blocks ads and trackers by default
# In "auto" profile mode QuasarDNS only chooses among resolvers of the same
# profile as your current DNS, so it never silently removes (or adds) filtering.
SERVERS="Cloudflare|plain|1.1.1.1|1.0.0.1
Google|plain|8.8.8.8|8.8.4.4
NextDNS|plain|45.90.28.0|45.90.30.0
DNS4EU|plain|86.54.11.100|86.54.11.200
Quad9|security|9.9.9.9|149.112.112.112
OpenDNS|security|208.67.222.222|208.67.220.220
AdGuard|ads|94.140.14.14|94.140.15.15"

TMP_DIR="/tmp/$SCRIPT_NAME.$$"
HAVE_LOCK=0

###############################################################################
# Output helpers
###############################################################################

if [ -t 1 ]; then
	ESC=$(printf '\033')
	C_RED="${ESC}[1;31m"; C_GRN="${ESC}[1;32m"; C_YLW="${ESC}[1;33m"
	C_CYN="${ESC}[1;36m"; C_NC="${ESC}[0m"
else
	C_RED=""; C_GRN=""; C_YLW=""; C_CYN=""; C_NC=""
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_GRN" "$C_NC" "$*"; }
warn() { printf '%s[!]%s  %s\n' "$C_YLW" "$C_NC" "$*"; }
err()  { printf '%s[X]%s  %s\n' "$C_RED" "$C_NC" "$*" >&2; }

log_msg() {
	[ -d "$ADDON_DIR" ] || mkdir -p "$ADDON_DIR" 2>/dev/null
	_ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
	printf '%s %s\n' "${_ts:-????-??-?? ??:??:??}" "$*" >> "$LOG_FILE" 2>/dev/null
}

log_sys() {
	log_msg "$*"
	logger -t "$SCRIPT_TITLE" "$*" 2>/dev/null
}

rotate_log() {
	[ -f "$LOG_FILE" ] || return 0
	_sz=$(wc -c < "$LOG_FILE" 2>/dev/null)
	_sz=${_sz:-0}
	if [ "$_sz" -gt 51200 ]; then
		tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
	fi
}

###############################################################################
# Cleanup / locking
###############################################################################

# shellcheck disable=SC2329  # invoked through trap
cleanup() {
	rm -rf "$TMP_DIR" 2>/dev/null
	[ "$HAVE_LOCK" = "1" ] && rm -rf "$LOCK_DIR" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 141' PIPE

lock_acquire() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		echo $$ > "$LOCK_DIR/pid"; HAVE_LOCK=1; return 0
	fi
	_old=$(cat "$LOCK_DIR/pid" 2>/dev/null)
	if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
		return 1
	fi
	# stale lock from a crashed run
	rm -rf "$LOCK_DIR" 2>/dev/null
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		echo $$ > "$LOCK_DIR/pid"; HAVE_LOCK=1; return 0
	fi
	return 1
}

lock_release() {
	[ "$HAVE_LOCK" = "1" ] && rm -rf "$LOCK_DIR" 2>/dev/null
	HAVE_LOCK=0
}

###############################################################################
# Config (simple key=value file, parsed - never sourced)
###############################################################################

cfg_init() {
	mkdir -p "$ADDON_DIR"
	[ -f "$CFG_FILE" ] && return 0
	cat > "$CFG_FILE" <<'EOF'
PROFILE=auto
DNS2_MODE=auto
SAMPLES=5
MIN_GAIN_MS=5
MIN_GAIN_PCT=15
AUTO=disabled
SCHEDULE=0 4 */3 * *
AMTMUPDATE=enabled
EOF
}

cfg_get() { # key default
	_v=$(sed -n "s/^$1=//p" "$CFG_FILE" 2>/dev/null | head -n 1)
	if [ -n "$_v" ]; then printf '%s\n' "$_v"; else printf '%s\n' "$2"; fi
}

cfg_set() { # key value (values are validated by the callers)
	cfg_init
	if grep -q "^$1=" "$CFG_FILE" 2>/dev/null; then
		sed -i "s|^$1=.*|$1=$2|" "$CFG_FILE"
	else
		printf '%s=%s\n' "$1" "$2" >> "$CFG_FILE"
	fi
}

is_int() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	return 0
}

valid_cron() {
	printf '%s\n' "$1" | awk 'NF==5 && $0 ~ "^[0-9*/, -]+$" {ok=1} END{exit ok?0:1}'
}

###############################################################################
# Environment checks
###############################################################################

# Locate dig: known Entware/system paths first, then whatever the shell finds.
# Sets DIG (full path). Not relying on PATH alone: some BusyBox builds and
# cron environments do not resolve /opt/bin reliably.
find_dig() {
	DIG=""
	for _d in /opt/bin/dig /opt/sbin/dig /usr/bin/dig /usr/sbin/dig /bin/dig; do
		if [ -x "$_d" ]; then DIG="$_d"; break; fi
	done
	if [ -z "$DIG" ]; then
		# Walk PATH by hand. "command -v" is not used: on the ash of some BusyBox builds
		# (1.25.1 on Merlin 386.x) it fails to find external commands.
		_ifs=$IFS; IFS=:
		for _p in $PATH; do
			if [ -x "$_p/dig" ]; then DIG="$_p/dig"; break; fi
		done
		IFS=$_ifs
	fi
	[ -n "$DIG" ] || return 1
	# An Entware dig needs Entware's libraries. Under cron LD_LIBRARY_PATH holds the firmware's,
	# and dig then dies with "relocation error" / "Bus error".
	case "$DIG" in
		/opt/*) DIG_LD="/opt/lib:/opt/usr/lib" ;;
		*)      DIG_LD="$LD_LIBRARY_PATH" ;;
	esac
	return 0
}

dig_run() { LD_LIBRARY_PATH="$DIG_LD" "$DIG" "$@"; }

need_dig() {
	find_dig && return 0
	err "'dig' not found (looked in /opt/bin, /opt/sbin, /usr/bin, /usr/sbin, /bin and PATH)."
	err "Install it with:  opkg update && opkg install bind-dig"
	err "(Entware is required - install it from amtm with the 'ep' option)"
	return 1
}

is_running() { pidof "$1" >/dev/null 2>&1; }

# Sets PATH_BLOCK=1 when changing WAN DNS would have no (or unwanted) effect.
path_check() {
	PATH_BLOCK=0; PATH_MSG=""
	if [ "$(nvram get dnspriv_enable)" = "1" ]; then
		PATH_BLOCK=1; PATH_MSG="DNS-over-TLS is enabled (WAN DNS is not the main upstream)"
		warn "$PATH_MSG"
	fi
	for _p in unbound AdGuardHome dnscrypt-proxy dnscrypt-proxy2; do
		if is_running "$_p"; then
			PATH_BLOCK=1; PATH_MSG="$_p is running (it handles upstream resolution)"
			warn "$PATH_MSG"
		fi
	done
	if [ "$(nvram get dnsfilter_enable_x)" = "1" ]; then
		warn "DNS Director is enabled: clients with filter rules bypass the WAN DNS"
	fi
	_dw=$(nvram get wans_dualwan)
	case "$_dw" in
		""|*none*) ;;
		*) warn "Dual WAN is enabled ($_dw): only WAN 0 / global settings are managed" ;;
	esac
}

get_current_dns() {
	CUR_ENABLE=$(nvram get wan0_dnsenable_x)
	[ -z "$CUR_ENABLE" ] && CUR_ENABLE=$(nvram get wan_dnsenable_x)
	CUR1=$(nvram get wan0_dns1_x); CUR2=$(nvram get wan0_dns2_x)
	[ -z "$CUR1" ] && CUR1=$(nvram get wan_dns1_x)
	[ -z "$CUR2" ] && CUR2=$(nvram get wan_dns2_x)
	if [ "$CUR_ENABLE" = "1" ]; then
		# DNS handed out by the ISP: measure the first active one for reference
		CUR_TEST_IP=$(nvram get wan0_dns | awk '{print $1}')
		CUR_LABEL="ISP (automatic) ${CUR_TEST_IP}"
	else
		CUR_TEST_IP="$CUR1"
		CUR_LABEL="$CUR1 $CUR2"
	fi
}

# dnsmasq needs a moment after a restart: try a few times before giving up
local_resolves() {
	_n=0
	while [ "$_n" -lt 3 ]; do
		[ -n "$(dig_run -4 @127.0.0.1 google.com +time=3 +tries=1 +short 2>/dev/null)" ] && return 0
		_n=$((_n+1)); sleep 2
	done
	return 1
}

###############################################################################
# Benchmark
###############################################################################

# bench_ip <ip>  ->  sets BENCH_MS (score in ms), BENCH_OK and BENCH_TOT
# Score = mean of the samples after dropping the slowest 20 % (outliers such as
# a cold-cache miss). A mean is used instead of a median on purpose: on some
# routers dig reports times in 10 ms steps (19, 29, 39...), and a median would
# snap two equally fast resolvers to different steps.
bench_ip() {
	_ip="$1"; _tmp="$TMP_DIR/samples"; : > "$_tmp"
	_ok=0; _tot=0; _r=0
	while [ "$_r" -lt "$SAMPLES" ]; do
		for _h in $HOSTS; do
			_out=$(dig_run -4 "@$_ip" "$_h" +time=2 +tries=1 +stats 2>&1)
			_ms=$(printf '%s\n' "$_out" | awk '/Query time/ {print $4; exit}')
			if printf '%s\n' "$_out" | grep -q "status: NOERROR" && [ -n "$_ms" ]; then
				_ok=$((_ok+1))
			else
				_ms=$TIMEOUT_PENALTY
			fi
			echo "$_ms" >> "$_tmp"
			_tot=$((_tot+1))
		done
		_r=$((_r+1))
	done
	cat "$_tmp" >> "$TMP_DIR/all_samples"
	BENCH_MS=$(sort -n "$_tmp" | awk '{a[NR]=$1} END{if (!NR) {print 5000; exit} k=NR-int(NR/5); for (i=1;i<=k;i++) s+=a[i]; printf "%d\n", s/k+0.5}')
	BENCH_OK=$_ok; BENCH_TOT=$_tot
}

# Decide which group of resolvers may be chosen (PROFILE_USED / PROFILE_NOTE)
resolve_profile() {
	_p=$(cfg_get PROFILE auto)
	case "$_p" in
		plain|security|ads|all) PROFILE_USED="$_p"; PROFILE_NOTE="set in config"; return ;;
	esac
	_cat=""
	if [ "$CUR_ENABLE" != "1" ] && [ -n "$CUR1" ]; then
		_cat=$(printf '%s\n' "$SERVERS" | awk -F'|' -v ip="$CUR1" '$3==ip || $4==ip {print $2; exit}')
	fi
	if [ -n "$_cat" ]; then
		PROFILE_USED="$_cat"; PROFILE_NOTE="same type as your current DNS"
	else
		PROFILE_USED="plain"; PROFILE_NOTE="current DNS not recognized: unfiltered resolvers only"
	fi
}

# Tell the user when every successful query time falls on the same 10 ms step
coarse_timer_note() {
	[ -s "$TMP_DIR/all_samples" ] || return 0
	if awk '$1<5000 {n++; r=$1%10; if (n==1) f=r; else if (r!=f) d=1} END{exit (n>=10 && !d) ? 0 : 1}' "$TMP_DIR/all_samples"; then
		echo ""
		info "[i] dig reports times in 10 ms steps on this router: each score is an average over"
		info "    $((SAMPLES*3)) queries per resolver, so differences of a few ms are meaningful, single values are not."
	fi
}

run_benchmark() {
	RESULTS="$TMP_DIR/results"; POOL="$TMP_DIR/pool"; : > "$RESULTS"
	printf '%s\n' "$SERVERS" | while IFS='|' read -r _n _c _i1 _i2; do
		[ -z "$_n" ] && continue
		bench_ip "$_i1"
		echo "$BENCH_MS $_n $_i1 $_i2 $_c $BENCH_OK $BENCH_TOT" >> "$RESULTS"
		[ "$QUIET" = "1" ] || printf '%-15s %-15s %4d ms (%d/%d ok) [%s]\n' "$_n" "$_i1" "$BENCH_MS" "$BENCH_OK" "$BENCH_TOT" "$_c"
	done
	awk -v p="$PROFILE_USED" '($5==p || p=="all") && ($6*3 >= $7*2)' "$RESULTS" | sort -n > "$POOL"
}

###############################################################################
# Apply / rollback
###############################################################################

# The firmware keeps two lists: the configured one (wan0_dns1_x, wan0_dns2_x...)
# and the live one (wan0_dns / wan_dns) that feeds /tmp/resolv.dnsmasq. Changing
# only the first and restarting dnsmasq is NOT enough: the resolver keeps using
# the old servers (observed on Merlin 386.14_2). We also set the live list and
# run "service updateresolv", which rewrites the resolver files; that runs
# asynchronously, so wait_resolv waits until the files really list the servers.
SAVED_KEYS="wan_dnsenable_x wan0_dnsenable_x wan_dns1_x wan_dns2_x wan0_dns1_x wan0_dns2_x wan_dns wan0_dns"

save_state() {
	mkdir -p "$ADDON_DIR"
	{
		echo "TS=$(date +%s)"
		for _k in $SAVED_KEYS; do
			echo "$_k=$(nvram get "$_k")"
		done
	} > "$STATE_FILE"
}

# resolv_has <file> <ip>: exact match of an IP as a whole word (server=IP / nameserver IP)
resolv_has() {
	_re=$(printf '%s' "$2" | sed 's/\./\\./g')
	grep -qE "(^|[= ])${_re}\$" "$1" 2>/dev/null
}

# wait_resolv [ip...]: up to ~15 s until the resolver file lists all the given IPs
wait_resolv() {
	_t=0
	while [ "$_t" -lt 15 ]; do
		_f=/tmp/resolv.dnsmasq
		[ -f "$_f" ] || _f=/tmp/resolv.conf
		_all=0
		if [ -s "$_f" ]; then
			_all=1
			for _w in "$@"; do resolv_has "$_f" "$_w" || _all=0; done
		fi
		[ "$_all" = "1" ] && return 0
		sleep 1; _t=$((_t+1))
	done
	return 1
}

restore_state() {
	[ -f "$STATE_FILE" ] || return 1
	while IFS='=' read -r _k _v; do
		case " $SAVED_KEYS " in
			*" $_k "*) ;;
			*) continue ;;
		esac
		# only IPv4/IPv6 addresses separated by spaces (or empty) are accepted
		printf '%s\n' "$_v" | grep -qE '^[0-9a-fA-F:. ]*$' || continue
		nvram set "$_k=$_v"
	done < "$STATE_FILE"
	nvram commit
	service updateresolv >/dev/null 2>&1
	# shellcheck disable=SC2046  # word splitting of the IP list is intended
	wait_resolv $(nvram get wan0_dns)
	service restart_dnsmasq >/dev/null 2>&1
	return 0
}

apply_dns() { # dns1 dns2
	_div_before=$(diversion_probe)
	save_state
	for _k in wan_dnsenable_x wan0_dnsenable_x; do nvram set "$_k=0"; done
	nvram set "wan0_dns1_x=$1"; nvram set "wan0_dns2_x=$2"
	nvram set "wan_dns1_x=$1";  nvram set "wan_dns2_x=$2"
	nvram set "wan0_dns=$1 $2"; nvram set "wan_dns=$1 $2"
	nvram commit
	service updateresolv >/dev/null 2>&1
	if ! wait_resolv "$1" "$2"; then
		err "The new DNS did not reach the resolver files (/tmp/resolv.dnsmasq): rolling back"
		restore_state
		log_sys "apply $1 $2 FAILED (resolver files not updated) - rolled back to $CUR_LABEL"
		return 1
	fi
	service restart_dnsmasq >/dev/null 2>&1
	sleep 4
	if ! local_resolves; then
		err "The router stopped resolving after the change: rolling back"
		restore_state
		sleep 3
		log_sys "apply $1 $2 FAILED (no local resolution) - rolled back to $CUR_LABEL"
		return 1
	fi
	log_sys "applied $1 $2 (was $CUR_LABEL)"
	ok "New DNS: $(nvram get wan0_dns1_x) / $(nvram get wan0_dns2_x)  (active in /tmp/resolv.dnsmasq)"
	if [ "$_div_before" -gt 0 ]; then
		if [ "$(diversion_probe)" -gt 0 ]; then
			ok "Diversion is still blocking (doubleclick.net -> 0.0.0.0)"
		else
			warn "Diversion was blocking doubleclick.net before the change and is not now: check Diversion"
			log_msg "warning: Diversion blocking not detected after applying $1 $2"
		fi
	fi
	return 0
}

# Diversion blocks ads inside dnsmasq, independently of the upstream DNS. We only
# warn if blocking that worked before the change stops working after it.
# diversion_probe prints how many 0.0.0.0 answers a well-known ad domain gets
# (0 = not blocked, or Diversion not installed).
diversion_probe() {
	[ -d /opt/share/diversion ] || { echo 0; return 0; }
	nslookup doubleclick.net 127.0.0.1 2>&1 | grep -c "0\.0\.0\.0"
	return 0
}

###############################################################################
# Commands: test / apply / auto
###############################################################################

# cmd_run <test|apply|auto> [--force]
cmd_run() {
	MODE="$1"; FORCE="$2"; QUIET=0
	[ "$MODE" = "auto" ] && QUIET=1
	need_dig || return 1
	lock_acquire || { err "Another $SCRIPT_TITLE run is already in progress"; return 1; }
	mkdir -p "$TMP_DIR"; rotate_log

	SAMPLES=$(cfg_get SAMPLES 5); is_int "$SAMPLES" && [ "$SAMPLES" -ge 1 ] && [ "$SAMPLES" -le 5 ] || SAMPLES=5
	MIN_GAIN_MS=$(cfg_get MIN_GAIN_MS 5); is_int "$MIN_GAIN_MS" || MIN_GAIN_MS=5
	MIN_GAIN_PCT=$(cfg_get MIN_GAIN_PCT 15); is_int "$MIN_GAIN_PCT" || MIN_GAIN_PCT=15

	get_current_dns
	if [ "$QUIET" = "1" ]; then path_check >/dev/null 2>&1; else path_check; fi

	if [ "$MODE" = "auto" ]; then
		if [ "$CUR_ENABLE" = "1" ]; then
			log_msg "auto: DNS is provided by the ISP - skipped (run '$RUN_CMD --apply' once to set manual DNS)"
			return 0
		fi
		if [ "$PATH_BLOCK" = "1" ]; then
			log_msg "auto: skipped - $PATH_MSG"
			return 0
		fi
	fi
	if [ "$MODE" = "apply" ] && [ "$PATH_BLOCK" = "1" ] && [ "$FORCE" != "--force" ]; then
		err "Not applying: $PATH_MSG. Use '--apply --force' to override."
		return 1
	fi

	resolve_profile
	if [ "$QUIET" != "1" ]; then
		echo "=== $SCRIPT_TITLE SpeedTest ($(date)) ==="
		echo "Hosts: $HOSTS  |  samples: $SAMPLES  |  resolvers: $PROFILE_USED ($PROFILE_NOTE)"
		echo ""
	fi
	run_benchmark
	if [ "$QUIET" != "1" ]; then coarse_timer_note; fi

	BEST_LINE=$(head -n 1 "$POOL")
	if [ -z "$BEST_LINE" ]; then
		[ "$QUIET" = "1" ] && log_msg "auto: no valid DNS found (is the WAN up?)"
		err "No valid DNS found"
		return 1
	fi
	read -r BEST_MS BEST_NAME NEW1 BEST_IP2 _rest <<EOF
$BEST_LINE
EOF

	_mode=$(cfg_get DNS2_MODE auto)
	if [ "$_mode" = "auto" ]; then
		if [ "$PROFILE_USED" = "plain" ]; then _mode="next"; else _mode="same"; fi
	fi
	NEW2="$BEST_IP2"
	if [ "$_mode" = "next" ]; then
		_second=$(sed -n '2p' "$POOL" | awk '{print $3}')
		[ -n "$_second" ] && NEW2="$_second"
	fi

	if [ "$QUIET" != "1" ]; then
		echo ""
		echo "--- Ranking (fastest -> slowest) ---"
		awk '{print NR" "$1" ms "$2" "$3" ("$6"/"$7" ok)"}' "$POOL"
	fi

	# reference: how fast is what we use today?
	CUR_MS=""
	if [ -n "$CUR_TEST_IP" ]; then
		bench_ip "$CUR_TEST_IP"
		CUR_MS=$BENCH_MS
	fi

	if [ "$MODE" = "test" ]; then
		echo ""
		[ -n "$CUR_MS" ] && echo "Current: $CUR_LABEL -> ${CUR_MS} ms"
		echo "DRY-RUN current: $CUR_LABEL -> best: $NEW1 $NEW2 ($BEST_NAME ${BEST_MS}ms)"
		echo "Use --apply to apply or --auto for cron"
		return 0
	fi

	if [ "$NEW1" = "$CUR1" ] && [ "$NEW2" = "$CUR2" ] && [ "$CUR_ENABLE" != "1" ]; then
		[ "$QUIET" = "1" ] || ok "Already using the best DNS ($NEW1 $NEW2)"
		log_msg "$MODE: already optimal ($NEW1 $NEW2)"
		return 0
	fi

	if [ "$MODE" = "auto" ]; then
		[ -z "$CUR_MS" ] && CUR_MS=$TIMEOUT_PENALTY
		DIFF=$((CUR_MS-BEST_MS)); PCT=0
		[ "$CUR_MS" -gt 0 ] && PCT=$((DIFF*100/CUR_MS))
		if [ "$DIFF" -lt "$MIN_GAIN_MS" ] || [ "$PCT" -lt "$MIN_GAIN_PCT" ]; then
			log_msg "auto: no significant improvement (current ${CUR_MS}ms vs best ${BEST_MS}ms: ${DIFF}ms, ${PCT}%) - skipped"
			return 0
		fi
		log_msg "auto: current ${CUR_MS}ms vs best ${BEST_MS}ms (${DIFF}ms, ${PCT}%) - applying"
	else
		echo ""
		[ -n "$CUR_MS" ] && echo "Current $CUR_LABEL: ${CUR_MS} ms  vs  Best $NEW1 ($BEST_NAME): ${BEST_MS} ms"
		[ "$CUR_ENABLE" = "1" ] && warn "This replaces the ISP-provided DNS with manual servers (rollback: $RUN_CMD --rollback)"
	fi

	# make sure the chosen servers really answer before touching anything
	for _ip in "$NEW1" "$NEW2"; do
		if [ -z "$(dig_run -4 "@$_ip" google.com +time=2 +tries=2 +short 2>/dev/null)" ]; then
			err "$_ip does not resolve - aborting"
			log_msg "$MODE: $_ip does not resolve - aborted"
			return 1
		fi
	done

	[ "$QUIET" = "1" ] || echo "Applying $NEW1 $NEW2 (was $CUR_LABEL)..."
	apply_dns "$NEW1" "$NEW2"
}

cmd_rollback() {
	[ -f "$STATE_FILE" ] || { err "No saved DNS state - nothing to roll back"; return 1; }
	lock_acquire || { err "Another $SCRIPT_TITLE run is already in progress"; return 1; }
	get_current_dns
	restore_state || { err "Rollback failed"; return 1; }
	sleep 3
	log_sys "rollback: restored previous DNS settings (was $CUR_LABEL)"
	get_current_dns
	ok "Restored: $CUR_LABEL"
	return 0
}

cmd_status() {
	get_current_dns
	echo "$SCRIPT_TITLE $SCRIPT_VERSION"
	echo "Current DNS : $CUR_LABEL"
	echo "Auto mode   : $(cfg_get AUTO disabled) (schedule: $(cfg_get SCHEDULE '0 4 */3 * *'))"
	echo "Profile     : $(cfg_get PROFILE auto)   Secondary: $(cfg_get DNS2_MODE auto)   Samples: $(cfg_get SAMPLES 5)"
	echo "Thresholds  : >= $(cfg_get MIN_GAIN_MS 5) ms and >= $(cfg_get MIN_GAIN_PCT 15) %"
	echo "amtmupdate  : $(cfg_get AMTMUPDATE enabled)"
	if cru l 2>/dev/null | grep -q "#$CRON_ID#"; then echo "Cron job    : active"; else echo "Cron job    : not scheduled"; fi
	[ -f "$STATE_FILE" ] && echo "Rollback    : available"
	if [ -f "$LOG_FILE" ]; then echo ""; echo "Last log lines:"; tail -n 5 "$LOG_FILE"; fi
}

###############################################################################
# Scheduling / startup hook
###############################################################################

cron_add() {
	_s=$(cfg_get SCHEDULE "0 4 */3 * *")
	valid_cron "$_s" || _s="0 4 */3 * *"
	cru d "$CRON_ID" 2>/dev/null
	cru a "$CRON_ID" "$_s $SCRIPT_PATH --auto >/dev/null 2>&1"
}

cron_del() { cru d "$CRON_ID" 2>/dev/null; }

hook_add() {
	[ -f "$HOOK_FILE" ] || { mkdir -p "$(dirname "$HOOK_FILE")"; echo "#!/bin/sh" > "$HOOK_FILE"; }
	chmod 0755 "$HOOK_FILE"
	if ! grep -q "$HOOK_MARK\$" "$HOOK_FILE" 2>/dev/null; then
		[ -n "$(tail -c1 "$HOOK_FILE" 2>/dev/null)" ] && echo >> "$HOOK_FILE"
		echo "$SCRIPT_PATH startup & $HOOK_MARK" >> "$HOOK_FILE"
	fi
}

hook_del() {
	[ -f "$HOOK_FILE" ] && sed -i "/$HOOK_MARK\$/d" "$HOOK_FILE"
}

cmd_enable() {
	cfg_set AUTO enabled
	hook_add
	cron_add
	ok "Automatic mode enabled ($(cfg_get SCHEDULE '0 4 */3 * *'))"
}

cmd_disable() {
	cfg_set AUTO disabled
	cron_del
	ok "Automatic mode disabled"
}

cmd_startup() {
	cfg_init
	[ "$(cfg_get AUTO disabled)" = "enabled" ] && cron_add
	return 0
}

# Remove what version 1.x left behind (script in /jffs/scripts/quasardns.sh,
# cron line in services-start, backup/log files in /jffs)
migrate_legacy() {
	_legacy=""
	if [ -f "$HOOK_FILE" ] && grep -q 'cru a QuasarDNS' "$HOOK_FILE" 2>/dev/null; then
		sed -i '/cru a QuasarDNS/d' "$HOOK_FILE"
		_legacy=1
		info "Removed the old cron line from services-start"
	fi
	if [ -f "$JFFS_DIR/scripts/quasardns.sh" ]; then
		rm -f "$JFFS_DIR/scripts/quasardns.sh"
		_legacy=1
		info "Removed the old $JFFS_DIR/scripts/quasardns.sh"
	fi
	if [ -n "$_legacy" ]; then cron_del; fi
	if [ -f "$JFFS_DIR/quasar.log" ]; then
		cat "$JFFS_DIR/quasar.log" >> "$LOG_FILE" 2>/dev/null && rm -f "$JFFS_DIR/quasar.log"
	fi
	[ -f "$JFFS_DIR/dns_backup.txt" ] && info "You can delete $JFFS_DIR/dns_backup.txt (no longer used)"
	return 0
}

###############################################################################
# Install / uninstall
###############################################################################

cmd_install() {
	if [ "$(nvram get jffs2_scripts)" != "1" ]; then
		warn "JFFS custom scripts are disabled: enable them in Administration > System"
		warn "(Enable JFFS custom scripts and configs = Yes), then reboot."
	fi
	cfg_init
	if ! find_dig; then
		if [ -x /opt/bin/opkg ]; then
			info "Installing bind-dig via Entware..."
			/opt/bin/opkg update >/dev/null 2>&1
			/opt/bin/opkg install bind-dig || { err "Could not install bind-dig"; return 1; }
			find_dig || { err "bind-dig was installed but 'dig' still cannot be found"; return 1; }
		else
			err "Entware is required (amtm > 'ep'), then: opkg install bind-dig"
			return 1
		fi
	fi
	migrate_legacy
	hook_add
	[ "$(cfg_get AUTO disabled)" = "enabled" ] && cron_add
	ok "$SCRIPT_TITLE $SCRIPT_VERSION installed. Open the menu with: $RUN_CMD"
}

cmd_uninstall() {
	printf 'Remove %s? [y/N] ' "$SCRIPT_TITLE"; read -r _a
	case "$_a" in y|Y) ;; *) info "Cancelled."; return 0 ;; esac
	if [ -f "$STATE_FILE" ]; then
		printf 'Restore the DNS servers you had before the last change first? [y/N] '; read -r _a
		case "$_a" in y|Y) cmd_rollback ;; esac
	fi
	cron_del
	hook_del
	printf 'Also delete settings and logs (%s)? [y/N] ' "$ADDON_DIR"; read -r _a
	case "$_a" in y|Y) rm -rf "$ADDON_DIR" ;; esac
	rm -f "$SCRIPT_PATH"
	ok "$SCRIPT_TITLE removed."
	exit 0
}

###############################################################################
# Updates (own update function + amtm 'amtmupdate' support)
###############################################################################

# Plain curl first: on Merlin 386.14_2 the bundled curl rejects --capath (rc 48),
# so it is only used as a fallback for builds that need the CA path spelled out.
fetch() { # url dest
	_o="--retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60"
	# shellcheck disable=SC2086
	curl -fsL $_o "$1" -o "$2" 2>/dev/null && return 0
	if [ -d /rom/etc/ssl/certs ]; then
		# shellcheck disable=SC2086
		curl -fsL --capath /rom/etc/ssl/certs $_o "$1" -o "$2" 2>/dev/null && return 0
	fi
	return 1
}

ver_num() {
	printf '%s\n' "$1" | sed 's/^v//' | awk -F. '{printf "%d%03d%03d\n", $1, $2, $3}'
}

# Downloads and validates the remote script. Sets REMOTE_VER / REMOTE_FILE.
update_fetch() {
	mkdir -p "$TMP_DIR"
	REMOTE_FILE="$TMP_DIR/remote.sh"
	fetch "$SCRIPT_URL" "$REMOTE_FILE" || return 1
	REMOTE_VER=$(sed -n 's/^readonly SCRIPT_VERSION="\(.*\)"$/\1/p' "$REMOTE_FILE" | head -n 1)
	[ -n "$REMOTE_VER" ] || return 1
	grep -q '^readonly SCRIPT_NAME="quasardns"$' "$REMOTE_FILE" || return 1
	sh -n "$REMOTE_FILE" 2>/dev/null || return 1
	return 0
}

update_install() {
	cp "$REMOTE_FILE" "$SCRIPT_PATH.new" || return 1
	chmod 0755 "$SCRIPT_PATH.new"
	mv -f "$SCRIPT_PATH.new" "$SCRIPT_PATH"
}

# cmd_update [force]
cmd_update() {
	info "Checking for updates..."
	update_fetch || { err "Could not download or validate the latest version"; return 1; }
	_l=$(ver_num "$SCRIPT_VERSION"); _r=$(ver_num "$REMOTE_VER")
	if [ "$_r" -gt "$_l" ] || [ "$1" = "force" ]; then
		update_install || { err "Update failed"; return 1; }
		ok "Updated $SCRIPT_VERSION -> $REMOTE_VER. Run it again to use the new version."
		log_msg "updated $SCRIPT_VERSION -> $REMOTE_VER"
	else
		ok "You are running the latest version ($SCRIPT_VERSION)"
	fi
}

# amtm calls:  quasardns amtmupdate check   -> exit 0 = enabled, 1 = disabled
#              quasardns amtmupdate         -> perform the update quietly
cmd_amtmupdate() {
	if [ "$1" = "check" ]; then
		[ "$(cfg_get AMTMUPDATE enabled)" = "enabled" ] && return 0
		return 1
	fi
	info "i  Running function amtmupdate"
	if update_fetch; then
		_l=$(ver_num "$SCRIPT_VERSION"); _r=$(ver_num "$REMOTE_VER")
		if [ "$_r" -gt "$_l" ]; then
			update_install || { info "x  $SCRIPT_TITLE amtmupdate failed"; return 1; }
			log_msg "amtmupdate: $SCRIPT_VERSION -> $REMOTE_VER"
			info "✔  $SCRIPT_TITLE $REMOTE_VER amtmupdate complete"
		else
			info "✔  $SCRIPT_TITLE $SCRIPT_VERSION amtmupdate complete"
		fi
		return 0
	fi
	info "x  $SCRIPT_TITLE amtmupdate failed"
	return 1
}

###############################################################################
# Menu
###############################################################################

pause() { printf '\nPress Enter to continue...'; read -r _x; }

menu_header() {
	printf '\n%s  ●  %s %s%s  -  warp speed DNS for Asuswrt-Merlin\n' "$C_CYN" "$SCRIPT_TITLE" "$SCRIPT_VERSION" "$C_NC"
	echo "  -------------------------------------------------------"
}

menu_settings() {
	while true; do
		menu_header
		echo "  Settings"
		echo "  1) Resolver profile      : $(cfg_get PROFILE auto)   (auto|plain|security|ads|all)"
		echo "  2) Secondary DNS mode    : $(cfg_get DNS2_MODE auto)   (auto|next|same)"
		echo "  3) Samples per host      : $(cfg_get SAMPLES 5)   (1-5)"
		echo "  4) Min. gain in ms (auto): $(cfg_get MIN_GAIN_MS 5)"
		echo "  5) Min. gain in %  (auto): $(cfg_get MIN_GAIN_PCT 15)"
		echo "  6) Schedule (cron)       : $(cfg_get SCHEDULE '0 4 */3 * *')"
		echo "  7) amtm automatic update : $(cfg_get AMTMUPDATE enabled)"
		echo "  e) Back"
		printf '\n  Choose: '; read -r _c
		case "$_c" in
			1) printf '  Profile [auto|plain|security|ads|all]: '; read -r _v
			   case "$_v" in auto|plain|security|ads|all) cfg_set PROFILE "$_v" ;; *) warn "Invalid value" ;; esac ;;
			2) printf '  Secondary [auto|next|same]: '; read -r _v
			   case "$_v" in auto|next|same) cfg_set DNS2_MODE "$_v" ;; *) warn "Invalid value" ;; esac ;;
			3) printf '  Samples per host [1-5]: '; read -r _v
			   if is_int "$_v" && [ "$_v" -ge 1 ] && [ "$_v" -le 5 ]; then cfg_set SAMPLES "$_v"; else warn "Invalid value"; fi ;;
			4) printf '  Minimum gain in ms: '; read -r _v
			   if is_int "$_v"; then cfg_set MIN_GAIN_MS "$_v"; else warn "Invalid value"; fi ;;
			5) printf '  Minimum gain in %%: '; read -r _v
			   if is_int "$_v"; then cfg_set MIN_GAIN_PCT "$_v"; else warn "Invalid value"; fi ;;
			6) printf '  Cron schedule (m h dom mon dow): '; read -r _v
			   if valid_cron "$_v"; then
				cfg_set SCHEDULE "$_v"
				[ "$(cfg_get AUTO disabled)" = "enabled" ] && cron_add
			   else warn "Invalid cron expression"; fi ;;
			7) if [ "$(cfg_get AMTMUPDATE enabled)" = "enabled" ]; then cfg_set AMTMUPDATE disabled; else cfg_set AMTMUPDATE enabled; fi ;;
			e|E) return 0 ;;
		esac
	done
}

menu_main() {
	while true; do
		menu_header
		get_current_dns
		echo "  Current DNS: $CUR_LABEL"
		echo "  Auto mode  : $(cfg_get AUTO disabled)"
		echo ""
		echo "  1) Run speed test (no changes)"
		echo "  2) Apply the best DNS now"
		echo "  3) Roll back to the previous DNS"
		echo "  4) Toggle automatic mode"
		echo "  5) Settings"
		echo "  6) Status and log"
		echo "  u) Check for updates"
		echo "  un) Uninstall"
		echo "  e) Exit"
		printf '\n  Choose: '; read -r _c
		case "$_c" in
			1) cmd_run test; lock_release; pause ;;
			2) cmd_run apply; lock_release; pause ;;
			3) cmd_rollback; lock_release; pause ;;
			4) if [ "$(cfg_get AUTO disabled)" = "enabled" ]; then cmd_disable; else cmd_enable; fi; pause ;;
			5) menu_settings ;;
			6) cmd_status; pause ;;
			u|U) cmd_update; pause ;;
			un|UN) cmd_uninstall ;;
			e|E) exit 0 ;;
		esac
	done
}

usage() {
	cat <<EOF
$SCRIPT_TITLE $SCRIPT_VERSION - find the fastest DNS for your Merlin router
Usage: $SCRIPT_NAME [command]
  (no command)        Open the interactive menu
  --dry-run | test    Benchmark only, no changes
  --apply             Benchmark and apply the best DNS   (add --force to override safety checks)
  --auto              Apply only if the gain exceeds the configured thresholds (for cron)
  --rollback          Restore the DNS servers used before the last change
  --enable | --disable  Turn the scheduled automatic mode on / off
  status              Show settings and last log lines
  update              Check for and install a new version
  install | uninstall
  --help              Show this help
EOF
}

###############################################################################
# Entry point
###############################################################################

case "$1" in
	"")                   if [ -t 0 ]; then menu_main; else usage; fi ;;
	--dry-run|test)       cmd_run test ;;
	--apply|apply)        cmd_run apply "$2" ;;
	--auto|auto)          cmd_run auto ;;
	--rollback|rollback)  cmd_rollback ;;
	--enable|enable)      cmd_enable ;;
	--disable|disable)    cmd_disable ;;
	status)               cmd_status ;;
	update)               cmd_update ;;
	forceupdate)          cmd_update force ;;
	amtmupdate)           cmd_amtmupdate "$2" ;;
	install)              cmd_install ;;
	uninstall)            cmd_uninstall ;;
	startup)              cmd_startup ;;
	--help|-h|help)       usage ;;
	*)                    usage; exit 1 ;;
esac
exit $?
