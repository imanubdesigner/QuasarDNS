# Testing QuasarDNS on a real router

v3.1.1 was checked with `sh -n`, with unit tests of the timer (uptime fractions, bad reads) and of the query-result filter, and with full dry-runs on a real RT-AC86U running Merlin 386.14_2 / BusyBox 1.25.1. The installer, the automatic mode and the uninstaller were each exercised on that router over repeated install → uninstall → reinstall cycles. The items below can only be verified on hardware. Run them over SSH, in order. Tick each one.

## 1. Install
- [ ] `sh install.sh` finishes without errors; `/jffs/scripts/quasardns` and `/jffs/addons/quasardns.d/config` exist
- [ ] It prints `Measurement: drill (/opt/bin/drill) + timeout — 1 ms resolution.` — or, without Entware, it prints the `[!] Measurement dependencies missing` block and offers to install them
- [ ] `grep QuasarDNS /jffs/scripts/services-start` shows **one** line (run the installer twice to check)
- [ ] Upgrading from v1.x: old `quasardns.sh` and its cron line are gone

## 1b. The installer only asks when it can be answered
The installer decides by testing whether stdin is a terminal, so these two runs must behave differently. This is worth checking on purpose: a silent wrong default is worse than no prompt.
- [ ] `ssh -t admin@192.168.1.1 'cd /tmp/QuasarDNS && sh install.sh'` → the question `Enable automatic checks …? [y/N]` is **printed and waits**
- [ ] Answering `y` prints `Enabling automatic checks...` followed by `[OK] Automatic mode enabled (0 4 */3 * *)`; answering `n` prints `Automatic mode is off` and the command to turn it on later
- [ ] `ssh admin@192.168.1.1 'cd /tmp/QuasarDNS && sh install.sh'` (no `-t`) → it prints `Automatic mode is OFF (no terminal attached, so nothing was asked)` and **asks nothing**, rather than pretending to ask and taking a default
- [ ] After answering, the summary block `=== installed ===` ends with the `remove` line and **no stray `EOF`**

## 2. Dry-run (must not change anything)
- [ ] `quasardns --dry-run` prints 7 resolvers, a ranking and a `DRY-RUN current: ...` line
- [ ] `nvram get wan0_dns1_x` is unchanged and `/jffs/addons/quasardns.d/` has no new files besides `config`

## 2b. Measurement tool (v3.1.0+)

QuasarDNS measures with Entware's `drill` when present and falls back to BusyBox `nslookup`. The two do not agree — not on the numbers, and not on the ranking — so check the one you have.
- [ ] `ls -l /opt/bin/drill /opt/bin/timeout` both exist; if not: `opkg update && opkg install drill coreutils-timeout`
- [ ] The menu shows `Measuring  : drill, 1 ms resolution` — and `quasardns status` shows the same on its `Measuring` line
- [ ] Force the fallback and confirm the menu follows: `QUASARDNS_DRILL=/nonexistent sh /jffs/scripts/quasardns status` → `nslookup, 10 ms clock (coarse)`
- [ ] `quasardns --dry-run` prints scores in the tens of milliseconds and **does not** print the `query times only move in 10 ms steps` note
- [ ] Force the fallback and confirm the coarse notice comes back: `QUASARDNS_DRILL=/nonexistent sh /jffs/scripts/quasardns --dry-run` — scores jump to the hundreds of ms and the `[i] query times only move in 10 ms steps` note is printed
- [ ] A fast failure must be treated as a failure, never as a fast success: `drill x.does-not-exist.invalid @1.1.1.1 | grep -E 'rcode|Query time'` shows an `rcode` other than `NOERROR`, while QuasarDNS only scores a lookup when the answer is `NOERROR` **and** an `ANSWER SECTION` is present
- [ ] An unreachable resolver must not stall the run: `time /opt/bin/timeout 3 /opt/bin/drill google.com @192.0.2.1` returns in ~3 s (`192.0.2.1` is TEST-NET-1). Without the timeout the same query takes ~15 s
- [ ] Compare the two rankings on your own line — if `nslookup` and `drill` agree, you have an unusually stable connection; if they disagree, `drill` is the one to trust

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
The important property here is that the config and the crontab cannot disagree. `AUTO=enabled` with no cron job means the check will never run and nothing says so, which is the failure this section exists to catch.
- [ ] `quasardns --enable` → `cru l | grep QuasarDNS` shows the job, and the run ends with `[OK] Automatic mode enabled (…)`
- [ ] **Both agree**: `AUTO` in `/jffs/addons/quasardns.d/config` and `cru l | grep QuasarDNS` report the same state. Check this after installing, after `--enable` and after `--disable`
- [ ] Break it on purpose and confirm you are told: `cfg_set AUTO enabled` by hand without a cron entry, then `quasardns --enable` → prints `[X] Auto mode is marked enabled but the cron job was NOT created.` and exits non-zero, instead of a false `[OK]`
- [ ] Same in reverse: `quasardns --disable` with a cron entry still present → `[!] Auto mode is disabled but the cron job is still listed.`
- [ ] Interrupting `--enable` part-way (it is silent for a few seconds while `cru` works) must not leave the two states inconsistent: re-run it and check the line above
- [ ] `reboot`, then `cru l | grep QuasarDNS` shows it again (startup hook)
- [ ] Set `MIN_GAIN_MS=0` and `MIN_GAIN_PCT=0` in the menu, run `quasardns --auto`, read `quasardns status`; restore the defaults afterwards
- [ ] `quasardns --disable` removes the job

## 6b. Under cron's own environment (important)
cron runs jobs with a different environment than your SSH session (`PATH` and `LD_LIBRARY_PATH` point at the firmware), and a script that works over SSH can still fail there. This was found on a real RT-AC86U: Entware's `grep` broke with `relocation error` / `Bus error` when it came first in `PATH`.
- [ ] Read the current minute with `date +%M`, then schedule a **single** run two minutes later (a full benchmark takes ~2 minutes on `nslookup`, less on `drill`, so `* * * * *` would overlap with itself): `cru a qtest "47 13 * * * /jffs/scripts/quasardns --dry-run > /tmp/qtest.out 2>&1"` (use your own minute/hour)
- [ ] After that minute plus ~3 minutes: `cat /tmp/qtest.out` shows the normal ranking, with **no** `relocation error`, no `Bus error` and no `arithmetic syntax error`
- [ ] That cron output also shows scores in the tens of milliseconds, proving `drill` was found (it is called by absolute path, because cron's `PATH` does not include `/opt/bin`) rather than silently falling back to `nslookup`
- [ ] Remove it: `cru d qtest`

## 7. amtm / updates
- [ ] `sh /jffs/scripts/quasardns amtmupdate check; echo $?` prints `0`
- [ ] Publish a test version (e.g. bump `SCRIPT_VERSION` to `v2.0.1` on a branch and point `SCRIPT_REPO` at it), then `sh /jffs/scripts/quasardns amtmupdate` prints two lines and exits `0`
- [ ] `quasardns update` on the latest version says you are up to date

## 8. Uninstall
The uninstaller must not claim success on faith. It checks, and names anything it could not remove.
- [ ] `quasardns uninstall` asks its three questions and removes the script, the `/jffs/addons/quasardns.d/` directory, the cron job, the startup hook line and the run lock
- [ ] It ends with `[OK] QuasarDNS removed. Nothing left behind.`
- [ ] Independently confirm nothing survived: `grep -rli quasar /jffs/scripts /jffs/addons` returns nothing, and `cru l | grep QuasarDNS` is empty
- [ ] `grep -c QuasarDNS /jffs/scripts/services-start` is `0`
- [ ] Other add-ons are untouched — in particular any `*.bak` belonging to another script survives
- [ ] Reinstalling afterwards asks about the automatic mode **again** (proves the config was really removed, not left behind with a stale `AUTO=enabled`)
- [ ] To exercise the reporting path, leave something behind on purpose (e.g. a file the script does not know about) and confirm it is listed by path instead of being silently ignored

## Firmware / hardware matrix

| Router | Firmware | BusyBox | Result |
| --- | --- | --- | --- |
| RT-AC86U | 386.x | 1.25.1 | |
| | 3006.x | | |
