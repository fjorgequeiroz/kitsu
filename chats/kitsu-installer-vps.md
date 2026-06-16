---
name: kitsu-installer-vps
description: "Kitsu VPS installer state, git repo, backup verification, and PostgreSQL auth fixes"
metadata: 
  node_type: memory
  type: project
  originSessionId: 53b3e601-670d-47cf-a611-668e2bfb6a6c
---

## VPS access

- Host: `191.252.182.177` (bare-metal VPS)
- SSH: `root@191.252.182.177` (root login, no sudo needed)
- Installer: `/root/kitsu/install_kitsu_debian.sh`
- Git remote: `github.com:fjorgequeiroz/kitsu.git` branch `main`
- Kitsu URL: `https://kitsu.zombiepetshop.work` (Cloudflare, valid cert)

## Kitsu PostgreSQL DB

PostgreSQL runs as system service on VPS. Connect as `postgres` user (no password needed via peer auth):
```bash
su -s /bin/bash postgres -c "psql -d zoudb"
```

Database: `zoudb`

Key tables and useful columns:
- `person` — `id`, `email`, `first_name`, `last_name`, `active`
- `project` — `id`, `name`, `code`
- `entity` — `id`, `name`, `project_id`, `entity_type_id` (assets, shots, etc.)
- `task` — `id`, `project_id`, `entity_id`, `task_type_id`
- `task_type` — `id`, `name`
- `task_person_link` — `task_id`, `person_id` (the assignees join table — NOT called `assignations`)
- `task_status` — `id`, `name`

Useful queries:
```sql
-- All persons with emails
SELECT email, first_name, last_name FROM person WHERE active = true ORDER BY last_name;

-- All task assignees for a project
SELECT t.id, e.name, tt.name, p.email
FROM task t
JOIN entity e ON t.entity_id = e.id
JOIN task_type tt ON t.task_type_id = tt.id
JOIN task_person_link tpl ON tpl.task_id = t.id
JOIN person p ON tpl.person_id = p.id
WHERE t.project_id = (SELECT id FROM project WHERE name = '2026_Zombie_Petshop')
ORDER BY e.name, tt.name;
```

## Backup (Kitsu/Zou)

- Backup tool: `zou dump-database` — writes `.sql.gz` to CWD. Installer uses `cd "$backup_path" && zou dump-database`.
- Run non-interactive backup: `./install_kitsu_debian.sh --backup-run`
- Backup verified working as of 2026-06-13.
- **No cron scheduled** — needs "Setup Backup" via installer menu. See [[ayon-installer-backup]] for Ayon side.

## PostgreSQL auth fixes (already committed)

The installer had a naive `ALTER USER postgres WITH PASSWORD '...'` that didn't configure `pg_hba.conf` for TCP auth. Fixed in commits `cfd5310` and `e719b36`:
- Rewrites `pg_hba.conf` TCP lines to `scram-sha-256`
- Ensures `127.0.0.1/32` and `::1/128` host rules exist
- Reloads postgres, then verifies TCP connection before continuing install

## Git sync status (as of 2026-06-13)

VPS had 2 commits (conf file additions) ahead of origin that weren't on local. Resolved by `git pull --rebase` on VPS then push. All three (VPS, local, origin) now at `534c879`.

Local repo: `/home/fernandojorge/dev/git/kitsu/`

## SSL avatar sync

Kitsu tries to download user avatars from `kitsu.zombiepetshop.work` but the Kitsu processor runs on the Ayon server (192.168.18.102) which may have SSL issues reaching that domain. Users sync fine, just no avatars — benign.
