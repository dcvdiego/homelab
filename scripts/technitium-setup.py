#!/usr/bin/env python3
"""
Creates the homelab.lan zone and all A records on both Technitium instances.
Run with:
    set -a && source .env && set +a && python3 scripts/technitium-setup.py
Requires TECHNITIUM_PASS in env (defaults to 'changeme').
"""

import os
import sys
import requests
import urllib3

urllib3.disable_warnings()

INSTANCES = [
    {"name": "dns-prod",  "url": "http://192.168.1.224:5380"},
    {"name": "dns-tower", "url": "http://192.168.1.248:5380"},
]

ZONE = "homelab.lan"
TTL  = 3600

# All records for homelab.lan
# Format: (name, ip)  →  name.homelab.lan  →  ip
RECORDS = [
    # --- Proxmox host ---
    ("pvehost",         "192.168.1.148"),

    # --- LXC containers ---
    ("vault",           "192.168.1.172"),
    ("docker-prod",     "192.168.1.224"),
    ("proxy",           "192.168.1.230"),
    ("docker-tower",    "192.168.1.248"),
    ("jellyfin",        "192.168.1.174"),

    # --- Monitoring (docker-prod) ---
    ("grafana",         "192.168.1.224"),
    ("prometheus",      "192.168.1.224"),
    ("uptime-kuma",     "192.168.1.224"),
    ("loki",            "192.168.1.224"),
    ("influxdb",        "192.168.1.224"),

    # --- Media (docker-prod) ---
    ("immich",          "192.168.1.224"),
    ("navidrome",       "192.168.1.224"),
    ("jellyseerr",      "192.168.1.224"),
    ("sonarr",          "192.168.1.224"),
    ("radarr",          "192.168.1.224"),
    ("prowlarr",        "192.168.1.224"),
    ("bazarr",          "192.168.1.224"),
    ("readarr",         "192.168.1.224"),

    # --- Apps (docker-prod) ---
    ("authentik",       "192.168.1.224"),
    ("tandoor",         "192.168.1.224"),
    ("vaultwarden",     "192.168.1.224"),
    ("vikunja",         "192.168.1.224"),
    ("paperless",       "192.168.1.224"),

    # --- Infrastructure ---
    ("portainer",       "192.168.1.248"),
    ("dns-prod",        "192.168.1.224"),
    ("dns-tower",       "192.168.1.248"),
]


def login(base_url: str, password: str) -> str:
    r = requests.get(
        f"{base_url}/api/user/login",
        params={"user": "admin", "pass": password},
        verify=False, timeout=10
    )
    r.raise_for_status()
    data = r.json()
    if data.get("status") != "ok":
        raise RuntimeError(f"Login failed: {data}")
    return data["token"]


def create_zone(base_url: str, token: str, zone: str) -> None:
    r = requests.get(
        f"{base_url}/api/zones/create",
        params={"token": token, "zone": zone, "type": "Primary"},
        verify=False, timeout=10
    )
    r.raise_for_status()
    data = r.json()
    if data.get("status") == "ok":
        print(f"  ✓ Zone '{zone}' created")
    elif "already exists" in str(data).lower():
        print(f"  ~ Zone '{zone}' already exists, skipping")
    else:
        raise RuntimeError(f"Zone creation failed: {data}")


def add_record(base_url: str, token: str, domain: str, ip: str, ttl: int) -> None:
    r = requests.get(
        f"{base_url}/api/zones/records/add",
        params={
            "token": token,
            "domain": domain,
            "type": "A",
            "ipAddress": ip,
            "ttl": ttl,
            "overwrite": "true",
        },
        verify=False, timeout=10
    )
    r.raise_for_status()
    data = r.json()
    if data.get("status") == "ok":
        print(f"  ✓ {domain} → {ip}")
    else:
        print(f"  ✗ {domain}: {data}")


def setup_instance(instance: dict, password: str) -> None:
    print(f"\n=== {instance['name']} ({instance['url']}) ===")
    token = login(instance["url"], password)
    print(f"  ✓ Logged in")

    create_zone(instance["url"], token, ZONE)

    print(f"  Adding {len(RECORDS)} records...")
    for name, ip in RECORDS:
        domain = f"{name}.{ZONE}"
        add_record(instance["url"], token, domain, ip, TTL)


if __name__ == "__main__":
    password = os.environ.get("TECHNITIUM_PASS", "changeme")
    if password == "changeme":
        print("Warning: using default password 'changeme' — set TECHNITIUM_PASS in .env to override")

    errors = []
    for instance in INSTANCES:
        try:
            setup_instance(instance, password)
        except Exception as e:
            print(f"  ERROR on {instance['name']}: {e}")
            errors.append(instance["name"])

    print()
    if errors:
        print(f"Failed instances: {errors}")
        sys.exit(1)
    else:
        print("All instances configured successfully.")
