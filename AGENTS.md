# AGENTS.md

## Deploy cycle (do this every time a file changes)

The router copy is authoritative for what runs, the repo copy for what is
committed. They drift silently, so the sequence is always the same:

1. `sh -n` the changed script locally. Never skip: BusyBox ash is stricter than
   bash in places, and a syntax error only shows up on the router.
2. Recreate the staging dir first. `rm -rf /tmp/QuasarDNS` is part of the wipe,
   and `/tmp` is cleared on reboot, so `scp` fails with
   `No such file or directory` until you do:
   ```bash
   ssh -t admin@192.168.1.1 'mkdir -p /tmp/QuasarDNS'
   ```
3. Copy only the two files the installer needs. `install.sh` uses `./quasardns.sh`
   when present and downloads otherwise; `logo.svg`, `menu.png`, `LICENSE`,
   `README.md` and `TESTING.md` are not referenced by either script. Do not use
   `scp -r`: it drags `.git/` onto the router.
4. Verify with `md5sum` on both sides before installing. A silent `scp` is not
   proof of transfer.
5. Install with `ssh -t`. Without a TTY, stdin is not a terminal and interactive
   prompts cannot be answered.

## Testing prompts

`install.sh` decides whether to ask by testing `[ -t 0 ]`. To verify prompt
behaviour locally, use a real pty (`python3 -m pty` or `pty.fork()`), not a
pipe: a pipe makes every check fail and hides the bug you are looking for.

Two traps inside `ask()`:

- the question must go to **stderr**. `ask()` runs inside `$( )`, so stdout is a
  pipe and printing there prepends the question text to the captured answer.
- only fd 0 is tested. `[ -t 1 ]` always fails inside a command substitution.

## Cleanup

`sh /jffs/scripts/quasardns uninstall` removes the script, the addon dir, the
cron entry, the startup hook line and the run lock, then reports anything it
could not remove instead of assuming success.

Do not chase `.bak` files on the router: `sed -i` was verified on this Merlin
build and does **not** create them. Existing `.bak` files predate the current
code. `switch_channel_v1.bak` belongs to another add-on, leave it alone.

## Reporting

State what a check actually proved. Two false diagnoses came from asserting a
Merlin behaviour that a timestamp or a one-line test contradicted: that `sed -i`
writes a backup, and that `[ -t 1 ]` works inside a command substitution. When
a claim about the router cannot be verified from the repo, run the check on the
router before building on it.
