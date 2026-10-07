#!/usr/bin/env python3
"""Push an ntfy notification for every Warpgate session waiting for admin approval.

Runs on the Warpgate LXC as the warpgate user and reads Warpgate's SQLite database read-only,
so it needs no Warpgate API token. Approving still happens in the Warpgate admin UI (with OTP).
Config (EnvironmentFile /etc/warpgate-notify.env): NTFY_URL, NTFY_TOKEN, NTFY_TOPIC, WARPGATE_ADMIN_URL.
"""
import json
import os
import sqlite3
import sys
import time
import urllib.request

DB = "file:/var/lib/warpgate/db/db.sqlite3?mode=ro"
NTFY = f"{os.environ['NTFY_URL'].rstrip('/')}/{os.environ.get('NTFY_TOPIC', 'warpgate')}"
TOKEN = os.environ["NTFY_TOKEN"]
ADMIN_URL = os.environ.get("WARPGATE_ADMIN_URL", "https://warpgate.homelab.lan:8888/@warpgate/admin")


def notify(target, username, address):
    body = f"{username} wants a session on {target}" + (f" from {address}" if address else "")
    req = urllib.request.Request(NTFY, data=body.encode(), method="POST", headers={
        "Authorization": f"Bearer {TOKEN}",
        "Title": f"Approve {target}?",
        "Priority": "high",
        "Tags": "key",
        "Click": ADMIN_URL,
        "Actions": f"view, Open Warpgate, {ADMIN_URL}",
    })
    urllib.request.urlopen(req, timeout=10).read()


def main():
    seen = set()
    while True:
        try:
            db = sqlite3.connect(DB, uri=True, timeout=5)
            rows = db.execute(
                "SELECT session_id, target, username, remote_address FROM session_approval_requests"
                " WHERE status = 'pending'").fetchall()
            db.close()
            for sid, target, username, address in rows:
                if (sid, target) not in seen:
                    notify(target, username, address)
                    print(json.dumps({"notified": target, "user": username, "from": address}), flush=True)
                    seen.add((sid, target))
            seen &= {(r[0], r[1]) for r in rows}
        except Exception as e:  # keep running; systemd logs the error
            print(f"error: {e.__class__.__name__}: {e}", file=sys.stderr, flush=True)
        time.sleep(3)


if __name__ == "__main__":
    main()
