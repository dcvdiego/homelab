# Networking

## Current topology

```
ISP Modem/Router (192.168.1.1)
    └── Yuanley 7-port unmanaged switch (5x 2.5G BaseT, 2x 10G SFP)
            ├── pvehost        192.168.1.148  static (Proxmox bridge vmbr0)
            │     ├── LXC 100: vault         192.168.1.172  static
            │     ├── LXC 101: docker-prod   192.168.1.224  static
            │     ├── LXC 102: agents        192.168.1.226  static
            │     ├── LXC 104: docker-tower  192.168.1.248  static
            │     ├── LXC 105: pbs           192.168.1.251  static
            │     ├── LXC 106: warpgate      192.168.1.227  static
            │     └── LXC 201: jellyfin      192.168.1.174  static
            └── personal devices / other
```

All LXC IPs are set statically inside Proxmox (`/etc/pve/lxc/<vmid>.conf`) — not relying on
DHCP reservations. If the subnet ever changes (new router, new ISP), update the `ip=` field
in each LXC conf file and the Proxmox host's `/etc/network/interfaces`.

**External access:**
- Cloudflare Tunnel — no inbound ports open, selective services only
- Tailscale on docker-prod (and the agents box) — zero-trust VPN for remote admin

All LXCs sit on a single flat `192.168.1.0/24` network. No VLANs yet — requires a managed
switch to implement properly (see Phase 2 below).

---

## Hardware (current)

| Device | Purpose |
|--------|---------|
| ISP router | Gateway, DHCP server, WiFi (temporary) |
| Yuanley 7-port (5x 2.5G + 2x 10G SFP, unmanaged) | Switch — no VLAN support |

See Phase 2 for the planned upgrade.

---

## DNS

**Technitium DNS**, two instances (deployed):

- Instance 1: docker-prod (`192.168.1.224`, plus its tailnet `100.x` address), container `technitium-dns`
- Instance 2: docker-tower (`192.168.1.248`), LAN only (not on Tailscale)
- Router DHCP hands out both IPs. Fallback: `1.1.1.1` as tertiary.
- Both serve the `homelab.lan` primary zone and a `$DOMAIN` (the public domain) **Forwarder** zone with local
  A records (split DNS). Records are added **per instance**: add to both via the API.

### Tailnet DNS

The Tailscale admin console sets **one global nameserver, docker-prod's tailnet address, with
"Override DNS servers" on**. Every tailnet device (phones, laptops off-network) sends *all* DNS
there; only `*.ts.net` is answered by Tailscale itself. So if docker-prod is off the tailnet or
Technitium on it is down, tailnet devices can reach tailnet hosts but **no public names resolve**
(the symptom is "Tailscale on = no internet", while Collie/herdr over MagicDNS still load).

### Split-DNS records are A-only

Local overrides such as `frigate.`, `zigbee2mqtt.`, `status.$DOMAIN → 192.168.1.224` are A
records. AAAA queries fall through the forwarder to Cloudflare, so IPv6-preferring clients still go
out through Cloudflare (and Cloudflare Access) for those names. Scripts that must hit Traefik
locally force IPv4 (`curl -4`; the Kuma script patches `getaddrinfo`).

### Failure modes and monitoring

**Incident, 2026-07-04 → 2026-10-04 (3 months unnoticed):** `technitium-dns` on docker-prod failed
to restart with `bind 0.0.0.0:53: address already in use`: systemd-resolved's stub listener holds
`127.0.0.53:53`, which blocks Docker publishing `0.0.0.0:53`. A container that never starts isn't
retried by `restart: unless-stopped`. Around the same time docker-prod's Tailscale node key
expired. Together: the tailnet's only resolver was gone. Found 2026-10-04 when phone push
notifications (Collie) failed with Tailscale on.

Fixed by:
- `/etc/systemd/resolved.conf.d/no-stub-listener.conf` on docker-prod (`DNSStubListener=no`). Keep
  it: removing it re-breaks Technitium on the next restart.
- Re-authenticating docker-prod in Tailscale and starting the container.

Monitoring (Uptime Kuma, group **DNS**, from `scripts/uptime-kuma-monitors.py`):

| Monitor | What it proves |
|---|---|
| DNS: Technitium docker-prod | `192.168.1.224` resolves `example.com` (LAN) |
| DNS: Technitium docker-tower | `192.168.1.248` resolves `example.com` (LAN) |
| DNS: homelab.lan zone | the local zone is served (`frigate.homelab.lan`) |
| DNS: tailnet resolver (push) | docker-prod's tailnet address answers **over Tailscale**. Pushed every 5 min by the agents box (LXC 102, `tailnet-dns-check.timer`, token in `~/.config/homelab/kuma-push.env` there). Kuma runs on docker-prod and can't see docker-prod's own tailnet status, so a tailnet node does the check; no push for 6 min → alert. |

### Open recommendations

1. **Second tailnet resolver.** Put docker-tower on Tailscale and add its `100.x` address as a second
   global nameserver, so one container or one expired key can't take tailnet DNS down.
2. **Break docker-prod's DNS self-reference.** docker-prod accepts Tailscale DNS, which points at
   itself; when Technitium is down it can't resolve anything (no image pulls, no recovery).
   `tailscale set --accept-dns=false` there would use the router instead. Check first whether its
   containers rely on `homelab.lan` names.
3. **Disable key expiry on server nodes** (docker-prod, agents, and any future server) in the
   Tailscale admin console. Done for docker-prod and agents on 2026-10-04.
4. **AAAA for split-DNS names** (optional): add AAAA records to docker-prod's IPv6 address, or
   accept the IPv4-only behaviour above.

### Why a local DNS server (beyond ad blocking)

| Feature | Benefit |
|---------|---------|
| Ad/tracker blocking | Blocks at DNS level before leaving the house |
| Encrypted DNS (DoH/DoT) | ISP cannot log every site you visit |
| DNSSEC | Cryptographic proof DNS answers aren't tampered with |
| Local DNS zones | `grafana.homelab.lan` instead of `192.168.1.224:3000` |
| Per-client rules | Different filtering per device |
| Query logging | See every connection attempt from every device |
| Malware/phishing blocking | Block known-bad domains |
| Caching | Frequently visited domains resolve instantly |

### Why Technitium over AdGuard Home / Pi-hole

- **Native HA clustering**: two instances sync blocklists and records automatically — no
  third-party sync tool needed.
- **Full DNS zones**: create a `homelab.lan` zone with proper A/CNAME records for every
  service. AdGuard Home does this as a flat list; Technitium does it properly.
- **Actively maintained**, single Docker container, minimal footprint.
- Runs `.NET` — slightly heavier than AdGuard's Go binary but negligible on this hardware.

### Safe rollout (won't kill internet if server goes down)

Set three DNS entries in the router's DHCP:
1. `192.168.1.224` — Technitium primary (docker-prod)
2. `192.168.1.248` — Technitium secondary (docker-tower)
3. `1.1.1.1` — Cloudflare fallback (direct, bypasses filtering)

If both Technitium instances are down, devices fall back to Cloudflare automatically. Internet
never fully breaks — you temporarily lose ad blocking.

---

## Cameras / NVR

**Planned: Reolink cameras** (garden, front porch, doorbell — 3 total).

Short term: **Reolink NVR** — dedicated box, plug-and-play, no AI detection, ~5W.

Later upgrade path: **Frigate NVR** running on the homelab server with Intel OpenVINO.
- The i3-13100's UHD 730 iGPU handles object detection via OpenVINO (actively maintained,
  no extra hardware needed).
- Skip Google Coral TPU — Google abandoned it in 2022, upstream libraries are stale, Frigate
  is discussing deprecating Coral support, and it's eBay-only now.
- `/dev/dri` passthrough to an LXC is the same mechanism Jellyfin already uses for QuickSync.
- Estimated overhead for 3 cameras: ~20–30W system-wide, ~20ms inference per frame.

---

## Server compute headroom

**i3-13100, 32GB RAM (expanding to 64GB).**

The CPU is not the bottleneck — it's a desktop-class 4c/8t chip that's vastly overpowered for
homelab workloads. RAM is the ceiling with everything running simultaneously.

Planned additions and their rough RAM cost:

| Addition | ~RAM |
|----------|------|
| Home Assistant | 1–2 GB |
| Nextcloud | 2–4 GB |
| Paperless-ngx | 1–2 GB |
| Frigate (3 cameras) | 2–4 GB |

Adding a second 32GB DDR4 SODIMM (Asus Prime B760M-K D4 has 2 slots, currently 1×32GB)
resolves this for years. ~£50–60.

A second Proxmox node is not needed yet. It becomes worthwhile when you need high availability
(services that can't go down during maintenance) or genuinely run out of resources.

---

## Phase 2 — network upgrade plan

The goal: proper network segmentation, security, and a WiFi setup that covers a medium-sized
house.

### Architecture

```
ISP Modem (bridge/passthrough mode)
    ↓
OPNsense on N100 mini-PC (~£150, 2 NICs)
    ↓
Managed switch — TP-Link TL-SG2008 or UniFi USW-Lite-8-PoE (~£80–100)
    ├── UniFi U7 Pro AP (~£150) — WiFi only, no routing
    ├── Homelab server (pvehost + LXCs)
    └── Wired devices
```

### Why OPNsense instead of a consumer router

| Consumer router | OPNsense |
|-----------------|----------|
| Proprietary firmware, abandoned in 2–3 years | Open source, weekly security patches |
| Basic firewall (port block only) | Full stateful firewall, IDS/IPS (Suricata) |
| No VLANs or very limited | Full 802.1Q VLAN support |
| No split DNS, no local zones | Unbound DNS with full zone control |
| VPN bolt-on or none | WireGuard + OpenVPN built-in |
| WiFi + routing coupled together | Separated — update one without affecting other |

OPNsense itself is free. The N100 mini-PC (~£150) + managed switch (~£90) + UniFi AP (~£150)
= ~£390 total. This setup will last 5–10 years.

### Why separate the AP from the firewall

A consumer router combines modem interface, firewall, switch, and WiFi radio in one box.
Separating them means:
- Update/reboot WiFi without dropping internet
- Update/reboot firewall without killing WiFi
- Replace the AP when WiFi 9 comes out without touching firewall config
- WiFi hardware ages fast (standards every 3–4 years); firewall hardware lasts a decade

### Planned VLANs

| VLAN | Devices | Internet | Access homelab |
|------|---------|----------|----------------|
| Personal | Laptops, phones | ✅ | ✅ |
| Homelab | Proxmox, LXCs | ✅ | ✅ (admin) |
| IoT | Cameras, smart home | ✅ | ❌ (isolated) |
| Guest | Visitor WiFi | ✅ | ❌ |

### OPNsense resilience

A single OPNsense box is a single point of failure for internet. Mitigations:

1. **Keep ISP router in a drawer** — emergency bypass, plug it in and internet works in
   under 5 minutes. Free.
2. **UPS on N100 + switch** (~£60) — covers power outages entirely. An N100 at 8W + switch
   at 5W on a modest UPS gives 4–6 hours of runtime.
3. **Auto-backup OPNsense config** — exports an XML file to GitHub/cloud on every change.
   Replacement hardware restored in 20 minutes.
4. **Mobile hotspot** — always available as a gap measure.
5. OPNsense HA with CARP (two N100 boxes, automatic failover) exists but is overkill for home.

N100 hardware is fanless, runs cool, idles at 6–8W — hardware failure is rare. Most
"OPNsense is down" events are software/config issues, recoverable in minutes via console.

**Do NOT run OPNsense as a Proxmox VM** — if Proxmox has a problem, you lose both homelab
and internet simultaneously. Dedicated hardware keeps internet independent of the homelab.

### WiFi

For a typical house up to ~120 m² (≈ 1,300 sq ft), a single good WiFi 7 AP covers it comfortably
(most are rated 2,500–3,000 sq ft). No mesh needed.

If going the OPNsense route, buy an AP that can run in pure access point mode (no routing):
- **UniFi U7 Pro** (~£150) — best-in-class, managed by a controller (run in Docker)
- **TP-Link EAP670** (~£90) — cheaper, Omada ecosystem, good alternative

Don't buy until you can see where signal is actually weak.

### Static IP from ISP

Not worth it. The current architecture (Cloudflare Tunnel + Tailscale) is ISP-IP-agnostic.
DDNS is free via Cloudflare if ever needed. Static IP costs £2–10/month extra on residential.
