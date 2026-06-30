# AYON Kitsu Processor 1.2.7 — KeyError email bug

**Date:** 2026-06-30  
**Symptom:** New users created on Kitsu were not syncing to AYON. The `aysvc_processor` container was crashing on every startup during full sync.

## Root Cause

`ynput/ayon-kitsu-processor:1.2.7` has a bug in `/service/processor/fullsync.py` line 39.

When iterating over task assignees, the code calls `gazu.person.get_person(id)["email"]` — but some accounts (bot/system accounts) are returned by the Kitsu API without an `email` field, causing `KeyError: 'email'` and crashing the processor before it can process any events.

**Error in logs:**
```
File "/service/processor/fullsync.py", line 39, in get_tasks
    "email": gazu.person.get_person(id)["email"]
             ~~~~~~~~~~~~~~~~~~~~~~~~~~^^^^^^^^^
KeyError: 'email'
```

## Fix

Patch `/service/processor/fullsync.py` inside the running container.

**Before (broken):**
```python
for id in record["assignees"]:
    record["persons"].append({
        "email": gazu.person.get_person(id)["email"]
    })
```

**After (fixed):**
```python
for id in record["assignees"]:
    person = gazu.person.get_person(id)
    if person:
        email = person.get("email") or person.get("login") or person.get("full_name", "")
        record["persons"].append({
            "email": email
        })
```

## How to Apply

```bash
sudo docker cp aysvc_processor:/service/processor/fullsync.py /tmp/fullsync.py
# edit /tmp/fullsync.py with the fix above
sudo docker cp /tmp/fullsync.py aysvc_processor:/service/processor/fullsync.py
sudo docker restart aysvc_processor
```

## Warning

This patch lives inside the container and is **lost if ASH recreates `aysvc_processor`** (e.g. after a server reboot). Re-apply using the steps above if the crash returns. A permanent fix requires waiting for `1.2.8+` or building a custom image.
