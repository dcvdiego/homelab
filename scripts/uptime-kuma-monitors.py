#!/usr/bin/env python3
"""Create/reconcile Uptime Kuma monitors for all homelab services via Socket.IO.

Idempotent: creates missing groups/monitors, updates the URL of existing HTTP monitors that
differ from MONITORS, deletes RETIRED monitors, and creates the ntfy notification once.
"""

import socket
import socketio
import time
import sys

import os

# Kuma publishes no host port and status.$DOMAIN is behind Cloudflare Access.
# Technitium's split-DNS A record sends LAN/tailnet clients straight to Traefik on
# docker-prod; it has no AAAA override, so force IPv4 or IPv6 lookups go to Cloudflare.
UK_URL = os.environ.get("KUMA_URL") or f"https://status.{os.environ['DOMAIN']}"  # DOMAIN from site.env
_getaddrinfo = socket.getaddrinfo
socket.getaddrinfo = lambda host, port, family=0, *a, **kw: _getaddrinfo(host, port, socket.AF_INET, *a, **kw)
KUMA_USER = os.environ["KUMA_USER"]
KUMA_PWD  = os.environ["KUMA_PWD"]

# Kuma runs on docker-prod in network_default, like every app below. Web UIs publish no host
# port (Traefik only), so HTTP checks use container names on that network. Services that do
# publish a port (Prometheus, Loki, InfluxDB, CouchDB) or live on another host keep their IP.
MONITORS = [
    # --- Monitoring ---
    {"name": "Grafana",          "url": "http://grafana:3000/api/health",       "parent_name": "Monitoring"},
    {"name": "Prometheus",       "url": "http://192.168.1.224:9090",             "parent_name": "Monitoring"},
    {"name": "Loki",             "url": "http://192.168.1.224:3100/ready",       "parent_name": "Monitoring"},
    {"name": "InfluxDB",         "url": "http://192.168.1.224:8086/health",      "parent_name": "Monitoring"},
    {"name": "Uptime Kuma",      "url": "http://localhost:3001",                "parent_name": "Monitoring"},
    # --- Infrastructure ---
    {"name": "Komodo",           "url": "http://192.168.1.248:9120",             "parent_name": "Infrastructure"},
    {"name": "Proxmox",          "url": "https://192.168.1.148:8006",            "parent_name": "Infrastructure"},
    {"name": "Authentik",        "url": "http://authentik-server:9000/-/health/ready/", "parent_name": "Infrastructure"},
    # Nightly database dumps on docker-prod (scripts/db-dumps.sh, cron 01:30) push up/down here.
    # 25h interval: one missed nightly run alerts.
    {"name": "Backups: database dumps (push)", "type": "push", "push_env": "KUMA_PUSH_DB_DUMPS",
     "push_token": os.environ.get("KUMA_PUSH_DB_DUMPS", ""), "interval": 90000, "maxretries": 0,
     "parent_name": "Infrastructure"},
    # --- DNS (see docs/networking.md#dns-failure-modes) ---
    # Technitium answering on the LAN, per instance, plus the local zone it serves.
    {"name": "DNS: Technitium docker-prod",  "type": "dns", "hostname": "example.com",         "dns_server": "192.168.1.224", "parent_name": "DNS"},
    {"name": "DNS: Technitium docker-tower", "type": "dns", "hostname": "example.com",         "dns_server": "192.168.1.248", "parent_name": "DNS"},
    {"name": "DNS: homelab.lan zone",        "type": "dns", "hostname": "frigate.homelab.lan", "dns_server": "192.168.1.224", "parent_name": "DNS"},
    # The tailnet's resolver (docker-prod's 100.x address) as tailnet devices reach it. Kuma runs on
    # docker-prod and can't see docker-prod drop off Tailscale, so the agents box
    # (LXC 102) queries it over the tailnet and pushes here only when that works.
    {"name": "DNS: tailnet resolver (push)", "type": "push", "push_token": os.environ.get("KUMA_PUSH_TAILNET_DNS", ""), "parent_name": "DNS"},
    # --- Media ---
    {"name": "Jellyseerr",       "url": "http://jellyseerr:5055",             "parent_name": "Media"},
    {"name": "Radarr",           "url": "http://radarr:7878",             "parent_name": "Media"},
    {"name": "Sonarr",           "url": "http://sonarr:8989",             "parent_name": "Media"},
    {"name": "Prowlarr",         "url": "http://prowlarr:9696",             "parent_name": "Media"},
    {"name": "Bazarr",           "url": "http://bazarr:6767",             "parent_name": "Media"},
    {"name": "Readarr",          "url": "http://readarr:8787",             "parent_name": "Media"},
    {"name": "Navidrome",        "url": "http://deezer-navidrome-1:4533",             "parent_name": "Media"},
    {"name": "Deemix",           "url": "http://deemix:6595",             "parent_name": "Media"},
    # --- Apps ---
    {"name": "Immich",           "url": "http://immich_server:2283/api/server/ping",             "parent_name": "Apps"},
    {"name": "Vaultwarden",      "url": "http://vaultwarden:80/alive",             "parent_name": "Apps"},
    {"name": "Tandoor",          "url": "http://tandoor:8080",             "parent_name": "Apps"},
    {"name": "Vikunja (Notes)",  "url": "http://notes-vikunja-1:3456",             "parent_name": "Apps"},
    {"name": "Obsidian LiveSync","url": "http://192.168.1.224:5984",             "parent_name": "Apps"},
]

GROUPS = ["Monitoring", "Infrastructure", "DNS", "Media", "Apps"]

# Monitors for services that no longer exist; deleted if present.
RETIRED = ["Portainer"]  # replaced by Komodo (2026-10-07)

# ntfy alerts: Kuma reaches ntfy over network_default (no Cloudflare). Token for ntfy user
# "kuma" (write-only on topic homelab) in KUMA_NTFY_TOKEN; skipped when unset.
NTFY = {"name": "ntfy", "url": "http://ntfy", "topic": "homelab", "token": os.environ.get("KUMA_NTFY_TOKEN", "")}

sio = socketio.Client(logger=False, engineio_logger=False)
results = {}
auth_ok = False
monitor_list_event = {}
notification_list_event = []

@sio.on("monitorList")
def on_monitor_list(data):
    """Kuma v2 pushes the monitor list as an event after login (getMonitorList's
    callback is not the list), so collect it here."""
    monitor_list_event.update(data)

@sio.on("notificationList")
def on_notification_list(data):
    notification_list_event[:] = data

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

    # Existing monitors arrive via the monitorList event. Refuse to continue without
    # it: an empty list here would re-create every monitor as a duplicate.
    deadline = time.time() + 15
    while not monitor_list_event and time.time() < deadline:
        time.sleep(0.1)
    monitor_list = [v for v in monitor_list_event.values() if isinstance(v, dict) and "name" in v]
    if not monitor_list:
        print("No monitorList received from Kuma; refusing to run (would duplicate monitors).")
        sio.disconnect()
        sys.exit(1)
    existing_names = {m["name"] for m in monitor_list}
    existing_by_name = {m["name"]: m["id"] for m in monitor_list}
    existing_beans = {m["name"]: m for m in monitor_list}
    print(f"Existing monitors: {existing_names or 'none'}")

    # ntfy notification (created once, default for new monitors, applied to existing ones)
    time.sleep(2)  # notificationList arrives with monitorList after login; an empty list is valid
    ntfy_id = None
    known = {n.get("name"): n.get("id") for n in notification_list_event}
    if NTFY["name"] in known:
        ntfy_id = known[NTFY["name"]]
        print(f"  Notification exists: {NTFY['name']} (id={ntfy_id})")
    elif NTFY["token"]:
        r = call("addNotification", {
            "name": NTFY["name"], "type": "ntfy", "isDefault": True, "applyExisting": True,
            "ntfyserverurl": NTFY["url"], "ntfytopic": NTFY["topic"], "ntfyPriority": 4,
            "ntfyAuthenticationMethod": "accessToken", "ntfyaccesstoken": NTFY["token"],
        }, None)
        if r and r[0] and r[0].get("ok"):
            ntfy_id = r[0].get("id")
            print(f"  Created notification: {NTFY['name']} -> {NTFY['url']}/{NTFY['topic']} (applied to all monitors)")
        else:
            print(f"  ERROR creating notification {NTFY['name']}: {r}")
    else:
        print(f"  Skip notification {NTFY['name']} (KUMA_NTFY_TOKEN not set in .env)")

    # Retired services
    for name in RETIRED:
        if name in existing_by_name:
            r = call("deleteMonitor", existing_by_name[name], False)
            print(f"  Deleted retired monitor: {name}" if r and r[0] and r[0].get("ok") else f"  ERROR deleting {name}: {r}")

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
    created = updated = skipped = errors = 0
    for m in MONITORS:
        if m["name"] in existing_names:
            bean = existing_beans[m["name"]]
            # Only the target URL is reconciled; everything else set in the UI is kept.
            if m.get("type", "http") == "http" and bean.get("url") != m["url"]:
                edit = dict(bean)
                edit["url"] = m["url"]
                r = call("editMonitor", edit)
                if r and r[0] and r[0].get("ok"):
                    print(f"  Updated: {m['name']}: {bean.get('url')} -> {m['url']}")
                    updated += 1
                else:
                    print(f"  ERROR updating {m['name']}: {r}")
                    errors += 1
            else:
                print(f"  Skip: {m['name']}")
                skipped += 1
            continue

        kind = m.get("type", "http")
        payload = {
            "type": kind,
            "name": m["name"],
            "interval": 60,
            "retryInterval": 30,
            "maxretries": 3,
            "active": True,
            "accepted_statuscodes": ["200-299", "301", "302", "401", "403"],
        }
        if kind == "http":
            payload.update({"url": m["url"], "method": "GET", "ignoreTls": True})
        elif kind == "dns":
            payload.update({"hostname": m["hostname"], "dns_resolve_server": m["dns_server"],
                            "dns_resolve_type": "A", "port": 53})
        elif kind == "push":
            if not m["push_token"]:
                print(f"  Skip: {m['name']} ({m.get('push_env', 'KUMA_PUSH_TAILNET_DNS')} not set in .env)")
                skipped += 1
                continue
            # Default pusher runs every 5 min; allow one missed beat before alerting.
            payload.update({"pushToken": m["push_token"], "interval": m.get("interval", 360),
                            "maxretries": m.get("maxretries", 1)})
        if m["parent_name"] in group_ids:
            payload["parent"] = group_ids[m["parent_name"]]
        if ntfy_id:
            payload["notificationIDList"] = {str(ntfy_id): True}

        r = call("add", payload)
        if r and r[0] and r[0].get("ok"):
            print(f"  Created: {m['name']} ({kind})")
            created += 1
        else:
            print(f"  ERROR: {m['name']}: {r}")
            errors += 1

    print(f"\nDone — created: {created}, updated: {updated}, skipped: {skipped}, errors: {errors}")
    sio.disconnect()

if __name__ == "__main__":
    main()
