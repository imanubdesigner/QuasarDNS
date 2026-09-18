#!/bin/sh
# QuasarDNS installer for Asuswrt-Merlin
# Usage: sh install.sh (run on router via ssh)

set -e
echo "=== QuasarDNS installer ==="

# check Entware
if ! which dig >/dev/null 2>&1; then
  echo "Installing bind-dig via Entware..."
  opkg update && opkg install bind-dig
fi

# install script
cp -v quasardns.sh /jffs/scripts/quasardns.sh
chmod +x /jffs/scripts/quasardns.sh
echo "Installed to /jffs/scripts/quasardns.sh"

# dry-run
echo ""
echo "Running dry-run..."
sh /jffs/scripts/quasardns.sh

echo ""
read -p "Schedule auto-check every 3 days at 04:00? [y/N] " ans
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
  cru a QuasarDNS "0 4 */3 * * /jffs/scripts/quasardns.sh --auto >> /jffs/quasar.log 2>&1"
  grep -q QuasarDNS /jffs/scripts/services-start 2>/dev/null || echo 'cru a QuasarDNS "0 4 */3 * * /jffs/scripts/quasardns.sh --auto >> /jffs/quasar.log 2>&1"' >> /jffs/scripts/services-start
  chmod +x /jffs/scripts/services-start
  echo "Cron added. Check with: cru l | grep Quasar"
fi

echo "Done. Use: sh /jffs/scripts/quasardns.sh --apply"
