# Testing QuasarDNS on a real router

v2.0.0 was checked with `shellcheck`, `sh -n` under dash and BusyBox ash, and a simulated router (stubbed `nvram`, `dig`, `cru`, ...). The items below can only be verified on hardware. Run them over SSH, in order. Tick each one.

## 1. Install
- [ ] `sh install.sh` finishes without errors; `/jffs/scripts/quasardns` and `/jffs/addons/quasardns.d/config` exist
- [ ] `grep QuasarDNS /jffs/scripts/services-start` shows **one** line (run the installer twice to check)
- [ ] Upgrading from v1.x: old `quasardns.sh` and its cron line are gone

## 2. Dry-run (must not change anything)
- [ ] `quasardns --dry-run` prints 7 resolvers, a ranking and a `DRY-RUN current: ...` line
- [ ] `nvram get wan0_dns1_x` is unchanged and `/jffs/addons/quasardns.d/` has no new files besides `config`

## 3. Apply — the most important check
- [ ] `quasardns --apply` ends with `[OK] New DNS: ... (active in /tmp/resolv.dnsmasq)`. If instead it says the new DNS did not reach the resolver files and rolled back, `service updateresolv` does not work on your firmware: please report the firmware version
- [ ] `cat /tmp/resolv.dnsmasq` lists **both** new servers (the old ones are gone) and `nvram get wan0_dns` shows the same list
- [ ] From a LAN client: `nslookup example.com <router-ip>` works
- [ ] WebUI → WAN → DNS Server shows the new servers with *Connect to DNS Server automatically = No*
- [ ] Diversion users: `[OK] Diversion is still blocking` (or the `[i]` note explains why not)
- [ ] The WAN connection did not drop (no WAN restart is performed)

## 4. Rollback
- [ ] `quasardns --rollback` restores the previous values (`nvram get wan0_dns1_x`, `wan0_dns2_x`, `wan0_dnsenable_x`) **and** the live list: `cat /tmp/resolv.dnsmasq` shows the old servers again

## 5. Safety checks
- [ ] Enable DNS-over-TLS in the WebUI → `quasardns --apply` refuses with an explanation; `--apply --force` overrides
- [ ] (If installed) with Unbound / AdGuardHome running, `--apply` refuses
- [ ] With *Connect to DNS Server automatically = Yes*: `--auto` logs "DNS is provided by the ISP" and changes nothing

## 6. Automatic mode
- [ ] `quasardns --enable` → `cru l | grep QuasarDNS` shows the job
- [ ] `reboot`, then `cru l | grep QuasarDNS` shows it again (startup hook)
- [ ] Set `MIN_GAIN_MS=0` and `MIN_GAIN_PCT=0` in the menu, run `quasardns --auto`, read `quasardns status`; restore the defaults afterwards
- [ ] `quasardns --disable` removes the job

## 7. amtm / updates
- [ ] `sh /jffs/scripts/quasardns amtmupdate check; echo $?` prints `0`
- [ ] Publish a test version (e.g. bump `SCRIPT_VERSION` to `v2.0.1` on a branch and point `SCRIPT_REPO` at it), then `sh /jffs/scripts/quasardns amtmupdate` prints two lines and exits `0`
- [ ] `quasardns update` on the latest version says you are up to date

## 8. Uninstall
- [ ] `quasardns uninstall` removes the script, cron job and hook, and restores the DNS if you ask for it

## Firmware / hardware matrix

| Router | Firmware | BusyBox | Result |
| --- | --- | --- | --- |
| RT-AC86U | 386.x | 1.25.1 | |
| | 3006.x | | |
