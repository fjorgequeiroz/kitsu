# AYON → Kitsu Transmitter

Custom service that listens to AYON events and pushes changes back to Kitsu, making the sync bidirectional.

## What it syncs (AYON → Kitsu)

| AYON change | Kitsu field updated |
|---|---|
| Task status | `task_status_id` |
| Task assignees | assignation (add/remove persons) |
| Task type | `task_type_id` |
| Task renamed | `name` |
| Folder renamed | asset or shot `name` |
| Task start date (`startDate`) | `start_date` |
| Task end date (`endDate`) | `due_date` |

The reverse direction (Kitsu → AYON) is handled by the standard `ynput/ayon-kitsu-processor` container.

## Loop prevention

The kitsu processor writes to AYON with `sender=None`. The transmitter skips all events where `sender` is null, so processor-originated changes are never forwarded back to Kitsu.

## Deployment

The service runs as a Docker container on the AYON server (`192.168.18.102`).

The script is mounted from the host at `/opt/ayon/kitsu_transmitter.py` — edit that file to update the service, then restart the container.

### Environment variables

| Variable | Description |
|---|---|
| `AYON_SERVER_URL` | AYON server URL (e.g. `http://172.18.0.1:5100`) |
| `AYON_API_KEY` | AYON service API key |
| `KITSU_SERVER_URL` | Kitsu base URL (e.g. `https://kitsu.zombiepetshop.work`) |
| `KITSU_EMAIL` | Kitsu login email |
| `KITSU_PASSWORD` | Kitsu login password |
| `POLL_INTERVAL` | Seconds between AYON event polls (default: `5`) |

### Run command

```bash
docker run -d \
  --name ayon-kitsu-transmitter \
  --restart unless-stopped \
  -v /opt/ayon/kitsu_transmitter.py:/app/kitsu_transmitter.py:ro \
  -e AYON_SERVER_URL=http://172.18.0.1:5100 \
  -e AYON_API_KEY=<key> \
  -e KITSU_SERVER_URL=https://kitsu.zombiepetshop.work \
  -e KITSU_EMAIL=ayon@zombiepetshop.work \
  -e KITSU_PASSWORD=<password> \
  python:3.11-slim \
  bash -c "pip install 'ayon-python-api==1.0.0rc3' 'gazu>=0.9.9' -q && python /app/kitsu_transmitter.py"
```

### Update the script

```bash
# Edit on host
sudo nano /opt/ayon/kitsu_transmitter.py

# Restart container to pick up changes
sudo docker restart ayon-kitsu-transmitter

# Watch logs
sudo docker logs ayon-kitsu-transmitter -f
```

## Troubleshooting

**Dates not syncing:** Make sure AYON is firing `entity.task.attrib_changed` events. Check logs with `sudo docker logs ayon-kitsu-transmitter -f`.

**Status not syncing:** Status names in AYON must match Kitsu status names (case-insensitive). Check the lookup table count in startup logs — it should list the number of statuses found.

**Kitsu session expired:** The transmitter auto-reconnects on `AuthFailedException`. If it keeps failing, check `KITSU_EMAIL`/`KITSU_PASSWORD` env vars.
