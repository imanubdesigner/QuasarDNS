# QuasarDNS

<p align="center">
  <img src="logo.svg" width="100%" alt="QuasarDNS - Warp Speed DNS">
</p>

> DNS speed test and optimizer for Asuswrt-Merlin — find the fastest DNS for your connection, and keep it that way.

Inspired by [dnsspeedtest.online](https://dnsspeedtest.online) but built for routers. Runs directly on your **Asuswrt-Merlin** router, works with **amtm**, and plays nicely with Diversion & Skynet.

![QuasarDNS](https://img.shields.io/badge/QuasarDNS-v2.0-7c3aed?style=for-the-badge&logo=starship&logoColor=white) ![Merlin](https://img.shields.io/badge/Merlin-386.x%20%7C%203006.x-0ea5e9?style=for-the-badge&logo=asus&logoColor=white) ![BusyBox](https://img.shields.io/badge/BusyBox-ash-ff6b35?style=for-the-badge&logo=gnubash&logoColor=white) ![License](https://img.shields.io/badge/License-MIT-22c55e?style=for-the-badge&logo=opensourceinitiative&logoColor=white)

### Why Quasar?

A quasar is the brightest, most energetic object in the universe — like the fastest DNS path through the cosmic noise of the internet.

### Features

- **Real benchmark** — 7 public resolvers × 3 popular domains × 5 rounds, measured with `dig +stats` (`Query time`); the score is the **mean after dropping the slowest 20 %**, failed queries get a `5000 ms` penalty
- **Never changes the kind of DNS you use** — resolvers are grouped as `plain`, `security` (malware/phishing blocking) or `ads`; in `auto` mode only resolvers of the same group as your current DNS are considered, so your filtering is never silently added or removed
- **Safe by design** — refuses to run when it would have no effect or conflict: DNS-over-TLS, Unbound, AdGuardHome, dnscrypt-proxy (override with `--force`); verifies the new servers answer *before* applying; verifies the router still resolves *after* applying and **rolls back automatically** if not
- **Auto mode** — cron job (default: every 3 days at 04:00) that applies changes only when the gain is `>= 5 ms` **and** `>= 15 %` (no flapping); never takes over DNS that is provided by your ISP
- **One-step rollback** — `quasardns --rollback` restores the previous settings; changes take effect immediately, without restarting the WAN
- **Interactive menu** and full CLI
- **amtm ready** — supports `amtmupdate`, so `amtm` can update it together with your other add-ons
- **Housekeeping** — lock file (no overlapping runs), log rotation, idempotent cron / startup hook, no writes at all on a dry-run
- **BusyBox compatible** — plain POSIX `sh`, no bashisms

### Requirements

- Asuswrt-Merlin with *Administration → System → Enable JFFS custom scripts and configs = Yes*
- [Entware](https://github.com/Entware/Entware/wiki) (amtm → `ep`) for `dig` — the installer runs `opkg install bind-dig` for you

### Install

```sh
# one-liner (SSH into the router first)
curl -fsL https://raw.githubusercontent.com/imanubdesigner/QuasarDNS/master/install.sh | sh
```

or manually from a clone / zip:

```sh
scp -r QuasarDNS-master admin@192.168.1.1:/tmp/
ssh admin@192.168.1.1
cd /tmp/QuasarDNS-master && sh install.sh
```

The installer copies the script to `/jffs/scripts/quasardns`, keeps its data in `/jffs/addons/quasardns.d/`, installs `bind-dig` if needed, adds a startup hook, and runs a dry-run.

Upgrading from v1.x? The installer removes the old `quasardns.sh`, the old cron line and migrates the old log. You can then delete `/jffs/dns_backup.txt`.

### Usage

```
quasardns                 Open the interactive menu
quasardns --dry-run       Benchmark only, no changes         (alias: test)
quasardns --apply         Benchmark and apply the best DNS   (add --force to override safety checks)
quasardns --auto          Apply only if clearly faster (what cron runs)
quasardns --rollback      Restore the DNS servers used before the last change
quasardns --enable        Schedule the automatic mode
quasardns --disable       Remove the schedule
quasardns status          Settings, cron state and last log lines
quasardns update          Check for and install a new version
quasardns uninstall
```

`/jffs/scripts` is not in the router's `PATH`: run these as `sh /jffs/scripts/quasardns <command>`.

### Example output

```
=== QuasarDNS SpeedTest (Sun Sep 20 13:37:59 UTC 2026) ===
Hosts: google.com youtube.com wikipedia.org  |  samples: 5  |  resolvers: plain (same type as your current DNS)

Cloudflare      1.1.1.1           25 ms (15/15 ok) [plain]
Google          8.8.8.8           12 ms (15/15 ok) [plain]
NextDNS         45.90.28.0        30 ms (15/15 ok) [plain]
DNS4EU          86.54.11.100      40 ms (15/15 ok) [plain]
Quad9           9.9.9.9           15 ms (15/15 ok) [security]
OpenDNS         208.67.222.222    60 ms (15/15 ok) [security]
AdGuard         94.140.14.14      20 ms (15/15 ok) [ads]

--- Ranking (fastest -> slowest) ---
1 12 ms Google 8.8.8.8 (15/15 ok)
2 25 ms Cloudflare 1.1.1.1 (15/15 ok)
3 30 ms NextDNS 45.90.28.0 (15/15 ok)
4 40 ms DNS4EU 86.54.11.100 (15/15 ok)

Current: 1.1.1.1 1.0.0.1 -> 25 ms
DRY-RUN current: 1.1.1.1 1.0.0.1 -> best: 8.8.8.8 1.1.1.1 (Google 12ms)
```

*(Illustrative numbers.)*

### Settings

Stored in `/jffs/addons/quasardns.d/config` (edit from the menu → *Settings*):

| Key | Default | Meaning |
| --- | --- | --- |
| `PROFILE` | `auto` | `auto` = same group as your current DNS (`plain` if unknown) · `plain` · `security` · `ads` · `all` |
| `DNS2_MODE` | `auto` | Secondary DNS: `next` = second-best provider · `same` = the provider's own secondary · `auto` = `next` for `plain`, `same` otherwise |
| `SAMPLES` | `5` | Rounds per domain (1–5) |
| `MIN_GAIN_MS` / `MIN_GAIN_PCT` | `5` / `15` | Thresholds for `--auto` |
| `AUTO` | `disabled` | Whether the cron job is scheduled |
| `SCHEDULE` | `0 4 */3 * *` | Cron expression for `--auto` |
| `AMTMUPDATE` | `enabled` | Let amtm update this add-on |

### How it works

Each resolver is queried for `google.com`, `youtube.com` and `wikipedia.org` (`SAMPLES` rounds) over plain UDP/53 with `dig`, exactly what `dnsmasq` uses upstream. The score is the mean `Query time` after dropping the slowest 20 % of the samples; queries that fail count as `5000 ms`, and resolvers that fail more than a third of their queries are discarded.

On some routers `dig` only reports times in 10 ms steps (19, 29, 39 ms...). That is why the score is a mean over many queries and not a median or a single query: it stays reliable to a few milliseconds even with a coarse timer, and QuasarDNS tells you when it detects this.

These domains are almost always cached, so the score reflects mainly the network latency to each resolver — which is what dominates the DNS time of most lookups — rather than cold-cache recursion speed.

Applying a result sets `wan_dnsenable_x=0` and the manual servers (`wan0_/wan_dns1_x`, `dns2_x`) in nvram — the same values as *WAN → DNS Server* in the WebUI. On Merlin that alone is not enough: the router keeps a separate *live* list (`wan0_dns` / `wan_dns`) that feeds `/tmp/resolv.dnsmasq`, and `service restart_dnsmasq` does not refresh it. QuasarDNS therefore also sets the live list, runs `service updateresolv`, **waits until the resolver files really list the new servers**, restarts dnsmasq and checks that the router still resolves. If any step fails, the previous values are restored and nothing is left half-applied. No WAN restart is needed.

The previous values (configured and live) are saved to `/jffs/addons/quasardns.d/previous_dns` for `--rollback`.

### When QuasarDNS will not change anything

WAN DNS servers are not the main upstream if you use **DNS-over-TLS**, **Unbound**, **AdGuardHome** or **dnscrypt-proxy**, so `--apply` refuses (and `--auto` skips) in those cases. **DNS Director** and **Dual WAN** produce a warning. `--auto` also skips when your DNS comes from the ISP: run `--apply` once to switch to manual servers.

### Diversion & Skynet

Diversion filters **before** forwarding, so changing the upstream WAN DNS does not disable blocking. QuasarDNS only touches nvram values — never `dnsmasq.conf.add`, `pixelserv` or firewall rules — and warns you only if ad blocking that worked before a change stops working after it.

### Updating

`quasardns update`, the menu, or `amtm` → `u`. Updates are downloaded, syntax-checked and validated before replacing the installed script.

### Uninstall

```sh
quasardns uninstall
```

Optionally restores your previous DNS, removes the cron job, the startup hook, the script, and (if you say so) your settings and logs.

### Compatibility

Developed and tested on an **Asus RT-AC86U** (Merlin 386.14_2, BusyBox 1.25.1). The code is plain POSIX `sh` and should work on other Merlin routers, including 3006.x firmware, but the way DNS changes are made effective (`service updateresolv`) has only been verified on 386.14_2 so far. Reports are welcome — please open an issue.

### License

MIT — see [LICENSE](LICENSE)

### Credits

Inspired by [Silviu Stroe - dnsspeedtest.online](https://dnsspeedtest.online) (GPL-3.0). QuasarDNS is an original BusyBox/sh implementation.
