#!/usr/bin/env python3
"""AYON→Kitsu transmitter: pushes AYON task/folder changes back to Kitsu.

Loop prevention: the existing kitsu processor writes to AYON with sender=None
(null). The web UI writes with a non-null session token. We only process
events where sender is not None, which safely filters out processor-originated
events without any prefix matching.
"""

import json
import logging
import os
import sys
import time

import ayon_api
import gazu

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("kitsu-transmitter")

AYON_SERVER_URL = os.environ["AYON_SERVER_URL"]
AYON_API_KEY = os.environ["AYON_API_KEY"]
KITSU_SERVER_URL = os.environ["KITSU_SERVER_URL"].rstrip("/")
KITSU_EMAIL = os.environ["KITSU_EMAIL"]
KITSU_PASSWORD = os.environ["KITSU_PASSWORD"]
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "5"))
LOOKUP_REFRESH_INTERVAL = 300  # rebuild lookup tables every 5 minutes

WATCHED_TOPICS = [
    "entity.task.status_changed",
    "entity.task.assignees_changed",
    "entity.task.type_changed",
    "entity.task.renamed",
    "entity.task.attrib_changed",
    "entity.folder.renamed",
]


class KitsuTransmitter:
    def __init__(self):
        self._connect_ayon()
        self._connect_kitsu()
        self.status_map = {}      # ayon_status_name.lower() → kitsu_status_id
        self.person_map = {}      # email → kitsu_person_id
        self.ayon_user_email = {} # ayon_username → email
        self.task_type_map = {}   # name.lower() → kitsu_task_type_id
        self._last_lookup_refresh = 0
        self._build_lookups()

    def _connect_ayon(self):
        # Set env vars so init_service picks them up (same pattern as processor)
        os.environ["AYON_SERVER_URL"] = AYON_SERVER_URL
        os.environ["AYON_API_KEY"] = AYON_API_KEY
        ayon_api.init_service()
        log.info(f"Connected to AYON at {AYON_SERVER_URL}")

    def _connect_kitsu(self):
        gazu.set_host(f"{KITSU_SERVER_URL}/api")
        if not gazu.client.host_is_valid():
            log.error(f"Kitsu host not reachable: {KITSU_SERVER_URL}")
            sys.exit(1)
        gazu.log_in(KITSU_EMAIL, KITSU_PASSWORD)
        log.info(f"Logged into Kitsu as {KITSU_EMAIL}")

    def _build_lookups(self):
        log.info("Building lookup tables...")
        try:
            statuses = gazu.task.all_task_statuses()
            self.status_map = {s["name"].lower(): s["id"] for s in statuses}
        except Exception as e:
            log.warning(f"Could not build status map: {e}")

        # Build person map from AYON user list: email → Kitsu person ID.
        # We look up each person by email in Kitsu because all_persons()
        # doesn't return emails for non-admin Kitsu accounts.
        try:
            users = list(ayon_api.get_users())
            self.ayon_user_email = {
                u["name"]: (u.get("attrib") or {}).get("email", "")
                for u in users
            }
            self.person_map = {}
            for uname, email in self.ayon_user_email.items():
                if not email:
                    continue
                try:
                    person = gazu.person.get_person_by_email(email)
                    if person:
                        self.person_map[email] = person["id"]
                except Exception:
                    pass
        except Exception as e:
            log.warning(f"Could not build person/user map: {e}")

        try:
            task_types = gazu.task.all_task_types()
            self.task_type_map = {t["name"].lower(): t["id"] for t in task_types}
        except Exception as e:
            log.warning(f"Could not build task type map: {e}")

        self._last_lookup_refresh = time.time()
        log.info(
            f"Lookups ready — {len(self.status_map)} statuses, "
            f"{len(self.person_map)} persons, {len(self.task_type_map)} task types"
        )

    def _maybe_refresh_lookups(self):
        if time.time() - self._last_lookup_refresh > LOOKUP_REFRESH_INTERVAL:
            self._build_lookups()

    def _get_kitsu_task(self, ayon_task_id, project_name):
        try:
            task = ayon_api.get_task_by_id(project_name, ayon_task_id)
            if not task:
                return None
            kitsu_id = (task.get("data") or {}).get("kitsuId")
            if not kitsu_id:
                return None
            return gazu.task.get_task(kitsu_id)
        except Exception as e:
            log.warning(f"Could not fetch Kitsu task for AYON task {ayon_task_id}: {e}")
            return None

    def _get_kitsu_entity(self, ayon_folder_id, project_name):
        try:
            folder = ayon_api.get_folder_by_id(project_name, ayon_folder_id)
            if not folder:
                return None
            kitsu_id = (folder.get("data") or {}).get("kitsuId")
            if not kitsu_id:
                return None
            # Try as asset first, then shot
            try:
                entity = gazu.asset.get_asset(kitsu_id)
                if entity:
                    return ("asset", entity)
            except Exception:
                pass
            try:
                entity = gazu.shot.get_shot(kitsu_id)
                if entity:
                    return ("shot", entity)
            except Exception:
                pass
            return None
        except Exception as e:
            log.warning(f"Could not fetch Kitsu entity for AYON folder {ayon_folder_id}: {e}")
            return None

    def _parse_json(self, value):
        if isinstance(value, str):
            try:
                return json.loads(value)
            except Exception:
                return {}
        return value or {}

    def handle_status_changed(self, event):
        summary = self._parse_json(event.get("summary"))
        payload = self._parse_json(event.get("payload"))
        task_id = summary.get("entityId")
        project = event.get("project")
        new_status = payload.get("newValue") or summary.get("value")
        if not (task_id and project and new_status):
            return

        kitsu_status_id = self.status_map.get(new_status.lower())
        if not kitsu_status_id:
            log.warning(f"No Kitsu status found for '{new_status}'")
            return

        kitsu_task = self._get_kitsu_task(task_id, project)
        if not kitsu_task:
            return

        kitsu_task["task_status_id"] = kitsu_status_id
        gazu.task.update_task(kitsu_task)
        log.info(f"Status → Kitsu task {kitsu_task['id']}: {new_status}")

    def handle_assignees_changed(self, event):
        summary = self._parse_json(event.get("summary"))
        payload = self._parse_json(event.get("payload"))
        task_id = summary.get("entityId")
        project = event.get("project")
        new_assignees = payload.get("newValue") or summary.get("value") or []
        old_assignees = payload.get("oldValue") or []
        if not (task_id and project):
            return

        kitsu_task = self._get_kitsu_task(task_id, project)
        if not kitsu_task:
            return

        # Convert AYON usernames → Kitsu person IDs
        def ayon_users_to_kitsu_ids(usernames):
            ids = []
            for uname in usernames:
                email = self.ayon_user_email.get(uname, "")
                kitsu_id = self.person_map.get(email)
                if kitsu_id:
                    ids.append(kitsu_id)
                else:
                    log.debug(f"No Kitsu person for AYON user '{uname}' (email: '{email}')")
            return ids

        new_ids = set(ayon_users_to_kitsu_ids(new_assignees))
        old_ids = set(ayon_users_to_kitsu_ids(old_assignees))

        to_add = new_ids - old_ids
        to_remove = old_ids - new_ids

        # gazu.task.assign_task sends task_ids as a string but the Zou API
        # requires a list. Call the endpoint directly with the correct payload.
        for person_id in to_add:
            gazu.client.put(
                f"/actions/persons/{person_id}/assign",
                {"task_ids": [kitsu_task["id"]]},
            )
            log.info(f"Assigned person {person_id} to Kitsu task {kitsu_task['id']}")

        for person_id in to_remove:
            gazu.client.put(
                "/actions/tasks/clear-assignation",
                {"task_ids": [kitsu_task["id"]], "person_id": person_id},
            )
            log.info(f"Unassigned person {person_id} from Kitsu task {kitsu_task['id']}")

    def handle_task_renamed(self, event):
        summary = self._parse_json(event.get("summary"))
        payload = self._parse_json(event.get("payload"))
        task_id = summary.get("entityId")
        project = event.get("project")
        new_name = payload.get("newValue") or summary.get("value")
        if not (task_id and project and new_name):
            return

        kitsu_task = self._get_kitsu_task(task_id, project)
        if not kitsu_task:
            return

        kitsu_task["name"] = new_name
        gazu.task.update_task(kitsu_task)
        log.info(f"Renamed Kitsu task {kitsu_task['id']} → '{new_name}'")

    def handle_folder_renamed(self, event):
        summary = self._parse_json(event.get("summary"))
        payload = self._parse_json(event.get("payload"))
        folder_id = summary.get("entityId")
        project = event.get("project")
        new_name = payload.get("newValue") or summary.get("value")
        if not (folder_id and project and new_name):
            return

        result = self._get_kitsu_entity(folder_id, project)
        if not result:
            return
        entity_type, kitsu_entity = result
        kitsu_entity["name"] = new_name

        if entity_type == "asset":
            gazu.asset.update_asset(kitsu_entity)
        else:
            gazu.shot.update_shot(kitsu_entity)
        log.info(f"Renamed Kitsu {entity_type} {kitsu_entity['id']} → '{new_name}'")

    def handle_attrib_changed(self, event):
        summary = self._parse_json(event.get("summary"))
        payload = self._parse_json(event.get("payload"))
        task_id = summary.get("entityId")
        project = event.get("project")
        attrib = payload.get("attrib") or summary.get("attrib")
        if not (task_id and project and attrib):
            return

        # Only care about date fields
        start_date = attrib.get("startDate")
        end_date = attrib.get("endDate")
        if start_date is None and end_date is None:
            return

        kitsu_task = self._get_kitsu_task(task_id, project)
        if not kitsu_task:
            return

        # AYON stores dates as ISO datetime strings; Kitsu expects YYYY-MM-DD
        def to_kitsu_date(value):
            if not value:
                return None
            return value[:10]  # trim time portion if present

        changed = []
        if start_date is not None:
            kitsu_task["start_date"] = to_kitsu_date(start_date)
            changed.append(f"start_date={kitsu_task['start_date']}")
        if end_date is not None:
            kitsu_task["due_date"] = to_kitsu_date(end_date)
            changed.append(f"due_date={kitsu_task['due_date']}")

        gazu.task.update_task(kitsu_task)
        log.info(f"Dates → Kitsu task {kitsu_task['id']}: {', '.join(changed)}")

    def handle_type_changed(self, event):
        summary = self._parse_json(event.get("summary"))
        payload = self._parse_json(event.get("payload"))
        task_id = summary.get("entityId")
        project = event.get("project")
        new_type_name = payload.get("newValue") or summary.get("value")
        if not (task_id and project and new_type_name):
            return

        kitsu_type_id = self.task_type_map.get(new_type_name.lower())
        if not kitsu_type_id:
            log.warning(f"No Kitsu task type found for '{new_type_name}'")
            return

        kitsu_task = self._get_kitsu_task(task_id, project)
        if not kitsu_task:
            return

        kitsu_task["task_type_id"] = kitsu_type_id
        gazu.task.update_task(kitsu_task)
        log.info(f"Task type → Kitsu task {kitsu_task['id']}: {new_type_name}")

    def _dispatch(self, event):
        topic = event.get("topic")
        try:
            if topic == "entity.task.status_changed":
                self.handle_status_changed(event)
            elif topic == "entity.task.assignees_changed":
                self.handle_assignees_changed(event)
            elif topic == "entity.task.renamed":
                self.handle_task_renamed(event)
            elif topic == "entity.task.attrib_changed":
                self.handle_attrib_changed(event)
            elif topic == "entity.folder.renamed":
                self.handle_folder_renamed(event)
            elif topic == "entity.task.type_changed":
                self.handle_type_changed(event)
        except Exception as e:
            log.error(f"Error handling {topic} event {event.get('id')}: {e}", exc_info=True)

    def run(self):
        log.info("Kitsu transmitter started. Polling AYON events...")

        # Bootstrap: start from now to skip historical backlog
        last_event_time = None
        try:
            recent = list(ayon_api.get_events(
                topics=WATCHED_TOPICS,
                fields=["id", "createdAt"],
            ))
            if recent:
                last_event_time = recent[-1]["createdAt"]
                log.info(f"Starting from event time {last_event_time}")
        except Exception as e:
            log.warning(f"Could not fetch initial event cursor: {e}")

        while True:
            try:
                self._maybe_refresh_lookups()

                events = list(ayon_api.get_events(
                    topics=WATCHED_TOPICS,
                    newer_than=last_event_time,
                    fields=["id", "topic", "sender", "project", "summary", "payload", "createdAt"],
                ))

                for event in events:
                    sender = event.get("sender")
                    if sender is None:
                        # Null sender = written by the kitsu processor (full sync)
                        # Skip to avoid forwarding processor writes back to Kitsu
                        continue

                    self._dispatch(event)
                    last_event_time = event["createdAt"]

            except gazu.exception.AuthFailedException:
                log.warning("Kitsu session expired, re-logging in...")
                try:
                    gazu.log_in(KITSU_EMAIL, KITSU_PASSWORD)
                except Exception as e:
                    log.error(f"Re-login failed: {e}")
            except Exception as e:
                log.error(f"Poll loop error: {e}", exc_info=True)

            time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    KitsuTransmitter().run()
