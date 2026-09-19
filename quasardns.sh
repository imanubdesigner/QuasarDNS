#!/bin/sh
# QuasarDNS - Futuristic DNS SpeedTest for Asuswrt-Merlin
# Replica of dnsspeedtest.online logic for routers (BusyBox compatible)
# Cosmic nerd edition - Diversion / Skynet safe
# https://github.com/imanubdesigner/QuasarDNS
# Tested on RT-AC86U (Merlin 386.x) - BusyBox v1.25.1

HOSTS="google.com youtube.com wikipedia.org"
SERVERS="
Cloudflare|1.1.1.1
Google|8.8.8.8
Quad9|9.9.9.9
OpenDNS|208.67.222.222
AdGuard|94.140.14.14
NextDNS|45.90.28.0
DNS4EU|86.54.11.100
"

TMP="/tmp/quasar_$$.log"
trap 'rm -f "$TMP" "${TMP}.sorted" 2>/dev/null' EXIT INT TERM
MODE="dry"
[ "$1" = "--apply" ] && MODE="apply"
[ "$1" = "--auto" ] && MODE="auto"
[ "$1" = "--help" ] || [ "$1" = "-h" ] && {
  echo "QuasarDNS - Find the fastest DNS for your Merlin router"
  echo "Usage: sh quasardns.sh [--help|--apply|--auto]"
  echo "  (no args)  Dry-run only, no changes"
  echo "  --apply    Benchmark and apply best 2 DNS to nvram"
  echo "  --auto     Apply only if >5ms and >15% faster (for cron)"
  echo "Cron: cru a QuasarDNS \"0 4 */3 * * /jffs/scripts/quasardns.sh --auto >> /jffs/quasar.log 2>&1\""
  exit 0
}

OLD1=$(nvram get wan0_dns1_x); OLD2=$(nvram get wan0_dns2_x)
[ -z "$OLD1" ] && OLD1=$(nvram get wan_dns1_x)
[ -z "$OLD2" ] && OLD2=$(nvram get wan_dns2_x)
echo "$(date): backup $OLD1 $OLD2" >> /jffs/dns_backup.txt

> "$TMP"
echo "=== QuasarDNS SpeedTest ($(date)) ==="
echo "Hosts: $HOSTS"
echo ""
for E in $SERVERS; do
  [ -z "$E" ] && continue
  NAME=$(echo "$E" | cut -d'|' -f1); IP=$(echo "$E" | cut -d'|' -f2)
  TOTAL=0; COUNT=0; OK=0
  for H in $HOSTS; do
    OUT=$(dig "@$IP" "$H" +time=2 +tries=1 +stats 2>&1)
    MS=$(echo "$OUT" | grep "Query time" | awk '{print $4}')
    if echo "$OUT" | grep -q "status: NOERROR" && [ -n "$MS" ]; then OK=$((OK+1)); else MS=5000; fi
    [ -z "$MS" ] && MS=5000
    TOTAL=$((TOTAL+MS)); COUNT=$((COUNT+1))
  done
  AVG=$((TOTAL/COUNT))
  echo "$AVG $NAME $IP $OK" >> "$TMP"
  printf "%-15s %-15s %4d ms (%d/%d ok)\n" "$NAME" "$IP" "$AVG" "$OK" "$COUNT"
done

sort -n "$TMP" > "${TMP}.sorted"
echo ""
echo "--- Ranking (fastest -> slowest) ---"
awk '{print NR" "$1" ms "$2" "$3" ("$4"/3 ok)"}' "${TMP}.sorted"

BEST1=$(awk 'NR==1{print $3}' "${TMP}.sorted")
BEST2=$(awk 'NR==2{print $3}' "${TMP}.sorted")
BESTAVG=$(awk 'NR==1{print $1}' "${TMP}.sorted")
BESTNAME=$(awk 'NR==1{print $2}' "${TMP}.sorted")
[ -z "$BEST1" ] && echo "No valid DNS found" && exit 1

if [ "$MODE" = "dry" ]; then
  echo ""
  echo "DRY-RUN current: $OLD1 $OLD2 -> best: $BEST1 ($BESTNAME ${BESTAVG}ms)"
  echo "Use --apply to apply or --auto for cron"
  rm -f "$TMP" "${TMP}.sorted"
  exit 0
fi

# calculate current DNS avg for threshold
OLD_AVG=0; CNT=0
for H in $HOSTS; do
  OUT=$(dig "@$OLD1" "$H" +time=2 +tries=1 +stats 2>&1)
  MS=$(echo "$OUT" | grep "Query time" | awk '{print $4}')
  [ -z "$MS" ] && MS=5000
  OLD_AVG=$((OLD_AVG+MS)); CNT=$((CNT+1))
done
OLD_AVG=$((OLD_AVG/CNT))
echo ""
echo "Current $OLD1: ${OLD_AVG}ms vs Best $BEST1 ($BESTNAME): ${BESTAVG}ms" | tee -a /jffs/quasar.log
DIFF=$((OLD_AVG-BESTAVG))
PCT=0; [ "$OLD_AVG" -gt 0 ] && PCT=$((DIFF*100/OLD_AVG))

if [ "$MODE" = "auto" ] && { [ "$DIFF" -lt 5 ] || [ "$PCT" -lt 15 ]; }; then
  echo "$(date): no significant improvement ($DIFF ms $PCT%) - skipping" | tee -a /jffs/quasar.log
  rm -f "$TMP" "${TMP}.sorted"
  exit 0
fi

# validate before apply
for IP in "$BEST1" "$BEST2"; do
  dig "@$IP" google.com +time=2 +short >/dev/null 2>&1 || { echo "FAIL $IP does not resolve - abort"; exit 1; }
done

echo "Applying $BEST1 $BEST2 (was $OLD1 $OLD2)..."
nvram set wan0_dns1_x="$BEST1"; nvram set wan0_dns2_x="$BEST2"
nvram set wan_dns1_x="$BEST1"; nvram set wan_dns2_x="$BEST2"
nvram commit
service restart_dnsmasq
sleep 5
echo "New DNS: $(nvram get wan0_dns1_x) / $(nvram get wan0_dns2_x)"
echo "$(date): applied $BEST1 $BEST2 (was $OLD1 $OLD2)" | tee -a /jffs/quasar.log

# Diversion check - does not touch /jffs/configs/dnsmasq.conf.add
if [ -f /jffs/configs/dnsmasq.conf.add ]; then
  grep -q "address=/" /jffs/configs/dnsmasq.conf.add 2>/dev/null && echo "[OK] Diversion config intact" || echo "[WARN] check Diversion"
  nslookup doubleclick.net 127.0.0.1 2>&1 | grep -q "0.0.0.0" && echo "[OK] Diversion still blocking (doubleclick.net -> 0.0.0.0)" || echo "[WARN] Diversion not blocking - check"
fi

rm -f "$TMP" "${TMP}.sorted"
