# Chat: Kitsu VPS Installer — Backup, PostgreSQL Auth & Git Sync

Session: 2026-06-13 — verifying backup tool correctness, reviewing PostgreSQL auth hardening, and syncing VPS/local/origin repos.

---

## VPS & Access

**Where is Kitsu running?**

Bare-metal VPS at `191.252.182.177`. SSH as `root` (no sudo needed). Kitsu/Zou is served at `https://kitsu.zombiepetshop.work` (Cloudflare, valid cert). The AYON Kitsu processor connects to it as `fjorge@live.com`.

**Where is the installer?**

`/root/kitsu/install_kitsu_debian.sh` on the VPS. Local copy at `/home/fernandojorge/dev/git/kitsu/install_kitsu_debian.sh`. Git remote: `github.com:fjorgequeiroz/kitsu.git` branch `main`.

---

## Backup

**How does the Kitsu backup work?**

Uses `zou dump-database` which writes a `.sql.gz` to the current working directory. The installer does `cd "$backup_path" && zou dump-database` so the dump lands in the right place. There is no `--store` flag for zou — CWD is the only way to control output location.

Run a non-interactive backup with:
```bash
./install_kitsu_debian.sh --backup-run
```

**Is an automated backup cron scheduled?**

No — as of 2026-06-13 no cron is active on the VPS. Run "Setup Backup" via the installer menu to schedule it.

---

## PostgreSQL Auth Hardening

**Why was the old password-setting approach fragile?**

The original installer used:
```bash
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${db_password}';"
```
This sets the password in the DB but doesn't configure `pg_hba.conf` for TCP auth. If pg_hba.conf still had `peer` or `trust` for TCP connections, `zou` (which connects via TCP as `postgres`) would fail or bypass the password entirely.

**What was fixed (commits `cfd5310` and `e719b36`)?**

1. Locate `pg_hba.conf` via `SHOW hba_file`
2. Replace `peer`/`trust`/`ident` on host (TCP) lines with `scram-sha-256`
3. Ensure explicit rules exist for `127.0.0.1/32` and `::1/128`
4. `systemctl reload postgresql`
5. Write password via a temp SQL file (handles special characters safely — single quotes doubled)
6. Verify TCP connectivity: `PGPASSWORD=... psql -h 127.0.0.1 -U postgres -c "SELECT 1;"` — abort install if it fails

**Why use a temp SQL file instead of passing password on the command line?**

Special characters (like `!`, `$`, `&`) in passwords break shell quoting when passed as a `psql -c` argument. Writing to a `chmod 600` temp file and using `psql -f` avoids all quoting issues.

---

## Git Sync

**Why did `git push` from the VPS fail in this session?**

The VPS had 2 local commits (conf file additions from Jun 9) that were ahead of origin. Meanwhile the local machine had newer commits (`e719b36` PostgreSQL hardening) that were already on origin but not on the VPS. Running `git push` from the VPS was rejected because origin was ahead.

Fix: `git pull --rebase origin main` on the VPS first, then `git push`. Rebased the VPS conf-file commits on top of the local hardening commits.

**Current state after fix (2026-06-13):**

All three (VPS `/root/kitsu`, local `/home/fernandojorge/dev/git/kitsu`, origin) are at commit `534c879`.

---

## SSL / Avatar Sync

The Kitsu processor on the AYON server (192.168.18.102) tries to download user avatars from `kitsu.zombiepetshop.work` but may encounter SSL issues. User accounts sync correctly — only avatars fail. This is benign; no action needed unless avatars are required.

---

## Actionable Notes

- VPS: no sudo needed, direct root SSH.
- `zou dump-database` has no output path flag — always `cd` to target dir first.
- No cron scheduled — set up via installer menu "Setup Backup".
- PostgreSQL auth: `pg_hba.conf` must have `scram-sha-256` for TCP host lines, otherwise `zou` can't connect via password. The installer now verifies this before proceeding.
- After any git conflict between VPS and local: always `git pull --rebase` on the VPS before pushing, since the local machine may have newer commits already on origin.
