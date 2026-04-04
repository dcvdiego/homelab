#!/usr/bin/env python3
"""Create Uptime Kuma monitors for all homelab services via Socket.IO."""

import socketio
import time
import sys

import os

UK_URL = "http://192.168.1.224:3001"
KUMA_USER = os.environ["KUMA_USER"]
KUMA_PWD  = os.environ["KUMA_PWD"]

MONITORS = [
    # --- Monitoring ---
    {"name": "Grafana",          "url": "http://192.168.1.224:3000",             "parent_name": "Monitoring"},
    {"name": "Prometheus",       "url": "http://192.168.1.224:9090",             "parent_name": "Monitoring"},
    {"name": "Loki",             "url": "http://192.168.1.224:3100/ready",       "parent_name": "Monitoring"},
    {"name": "InfluxDB",         "url": "http://192.168.1.224:8086/health",      "parent_name": "Monitoring"},
    {"name": "Uptime Kuma",      "url": "http://192.168.1.224:3001",             "parent_name": "Monitoring"},
    # --- Infrastructure ---
    {"name": "Portainer",        "url": "https://192.168.1.248:9443",            "parent_name": "Infrastructure"},
    {"name": "Proxmox",          "url": "https://192.168.1.148:8006",            "parent_name": "Infrastructure"},
    {"name": "Authentik",        "url": "http://192.168.1.224:9000/api/v3/root/hello/", "parent_name": "Infrastructure"},
    # --- Media ---
    {"name": "Jellyseerr",       "url": "http://192.168.1.224:5055",             "parent_name": "Media"},
    {"name": "Radarr",           "url": "http://192.168.1.224:7878",             "parent_name": "Media"},
    {"name": "Sonarr",           "url": "http://192.168.1.224:8989",             "parent_name": "Media"},
    {"name": "Prowlarr",         "url": "http://192.168.1.224:9696",             "parent_name": "Media"},
    {"name": "Bazarr",           "url": "http://192.168.1.224:6767",             "parent_name": "Media"},
    {"name": "Readarr",          "url": "http://192.168.1.224:8787",             "parent_name": "Media"},
    {"name": "Navidrome",        "url": "http://192.168.1.224:4533",             "parent_name": "Media"},
    {"name": "Deemix",           "url": "http://192.168.1.224:6595",             "parent_name": "Media"},
    # --- Apps ---
    {"name": "Immich",           "url": "http://192.168.1.224:2283",             "parent_name": "Apps"},
    {"name": "Vaultwarden",      "url": "http://192.168.1.224:80",               "parent_name": "Apps"},
    {"name": "Tandoor",          "url": "http://192.168.1.224:8080",             "parent_name": "Apps"},
    {"name": "Vikunja (Notes)",  "url": "http://192.168.1.224:3456",             "parent_name": "Apps"},
    {"name": "Obsidian LiveSync","url": "http://192.168.1.224:5984",             "parent_name": "Apps"},
]

GROUPS = ["Monitoring", "Infrastructure", "Media", "Apps"]

sio = socketio.Client(logger=False, engineio_logger=False)
results = {}
auth_ok = False

@sio.event
def connect():
    print("Socket.IO connected")

@sio.event
def disconnect():
    print("Socket.IO disconnected")

def call(event, *args):
    """Emit and wait for callback response."""
    response = {}
    done = [False]

    def cb(*a):
        response["data"] = a
        done[0] = True

    sio.emit(event, args, callback=cb)
    deadline = time.time() + 10
    while not done[0] and time.time() < deadline:
        time.sleep(0.05)
    if not done[0]:
        raise TimeoutError(f"No response for event: {event}")
    return response["data"]

def main():
    print(f"Connecting to {UK_URL} ...")
    sio.connect(UK_URL, transports=["websocket", "polling"])
    time.sleep(0.5)

    print(f"Logging in as {KUMA_USER}...")
    r = call("login", {"username": KUMA_USER, "password": KUMA_PWD, "token": ""})
    if not (r and r[0] and r[0].get("ok")):
        print(f"Login failed: {r}")
        sio.disconnect()
        sys.exit(1)

    print("Logged in OK")

    # Get existing monitors
    r = call("getMonitorList")
    raw = r[0] if r else {}
    # v2 returns {id: monitor_obj, ...} but some values may be booleans (ok flag) — filter
    if isinstance(raw, dict):
        monitor_list = [v for v in raw.values() if isinstance(v, dict) and "name" in v]
    else:
        monitor_list = []
    existing_names = {m["name"] for m in monitor_list}
    existing_by_name = {m["name"]: m["id"] for m in monitor_list}
    print(f"Existing monitors: {existing_names or 'none'}")

    # Create groups
    group_ids = {}
    for group in GROUPS:
        if group in existing_by_name:
            group_ids[group] = existing_by_name[group]
            print(f"  Group exists: {group} (id={group_ids[group]})")
        else:
            r = call("add", {"type": "group", "name": group, "active": True})
            if r and r[0] and r[0].get("ok"):
                group_ids[group] = r[0]["monitorID"]
                print(f"  Created group: {group} (id={group_ids[group]})")
            else:
                print(f"  ERROR creating group {group}: {r}")

    # Create monitors
    created = skipped = errors = 0
    for m in MONITORS:
        if m["name"] in existing_names:
            print(f"  Skip: {m['name']}")
            skipped += 1
            continue

        payload = {
            "type": "http",
            "name": m["name"],
            "url": m["url"],
            "method": "GET",
            "interval": 60,
            "retryInterval": 30,
            "maxretries": 3,
            "active": True,
            "ignoreTls": True,
            "accepted_statuscodes": ["200-299", "301", "302", "401", "403"],
        }
        if m["parent_name"] in group_ids:
            payload["parent"] = group_ids[m["parent_name"]]

        r = call("add", payload)
        if r and r[0] and r[0].get("ok"):
            print(f"  Created: {m['name']} -> {m['url']}")
            created += 1
        else:
            print(f"  ERROR: {m['name']}: {r}")
            errors += 1

    print(f"\nDone — created: {created}, skipped: {skipped}, errors: {errors}")
    sio.disconnect()

if __name__ == "__main__":
    main()
