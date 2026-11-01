# Proxmox host (pvehost)

## Proxmox VE 8 → 9 upgrade

PVE 8 reached end of life on 2026-08-31. Plan checked against the official guide
(https://pve.proxmox.com/wiki/Upgrade_from_8_to_9) and `pve8to9 --full` on 2026-10-24.

### Checker results (2026-10-24)

- `pve8to9 --full`: 0 failures. Warnings: pending updates (fixed), running guests (stop them in
  Phase B), removable bootloader not maintained by GRUB (fixed), no `intel-microcode` (fixed).
  Notice "unusual suite" = the third-party `deb.gierens.de stable` repo (eza): expected.
- `pbs3to4 --full` in CT 105: the "proxmox-backup package" FAIL is the known false positive for PBS
  in an LXC; NTP and GRUB warnings don't apply in a container.
- Containers: Ubuntu 22.04 / Debian 12 (systemd ≥ 249), so the cgroup v1 removal doesn't affect them.
- `/etc/sysctl.conf` is empty; `sshd_config` has no deprecated options.
- `lvm.conf`, `/etc/default/grub`, `chrony.conf`, `/etc/issue` differ from the package defaults:
  keep the local versions (`--force-confold`), then review the `.dpkg-dist` files.

### Phase A: prep (done 2026-10-24, no downtime)

| Step | State |
|---|---|
| `apt full-upgrade` on 8.4 (24 packages) | done, pve-manager 8.4.21 |
| `non-free-firmware` on the Debian lines of `/etc/apt/sources.list`, `intel-microcode` installed | done; backup `sources.list.bak-2026-10-24`; microcode loads at next reboot |
| Removable bootloader: `grub2/force_efi_extra_removable=true`, `apt install --reinstall grub-efi-amd64` | done; ESP backup `/root/esp-backup-2026-10-24.tar.gz`; boot entry 0000 `proxmox` (shim) first |
| NIC pinning: `pve-network-interface-pinning generate` (enp4s0 → `nic0`) | applied at the 2026-11-01 reboot: `nic0` in `vmbr0` (see below) |
| Fresh backups (all CTs to PBS + `pve-host-backup.service`) | done 2026-11-01, all OK: 100, 101, 104, 106, 201 to `pbs-lxc`; 105 to local `backups`; host config |

#### NIC rename (applied 2026-11-01)

- `/usr/local/lib/systemd/network/50-pve-nic0.link`: matches the onboard NIC by MAC (only in that file, not here) → `nic0`.
- `/etc/network/interfaces` uses `nic0` (`iface` and `bridge-ports` of `vmbr0`); `interfaces.new` was swapped in at boot.
- Side effect: an empty `/etc/pve/sdn/controllers.cfg` (SDN unused).
- Undo: delete the `.link` file, put `enp4s0` back in `/etc/network/interfaces`, reboot.
  Originals: `/root/nic-pinning-backup-2026-10-24/`.

### Phase B: 8.4 → 9 (done 2026-11-01)

The plan as written:

1. Step 5 of Phase A: fresh backups. Re-run `pve8to9 --full` (expect only "running guests").
2. Sources to trixie in deb822 format (`.sources`), keep the gierens repo; `apt update`. Review before continuing.
3. Stop all containers.
4. `apt dist-upgrade` detached, `--force-confdef --force-confold`; check `dpkg --audit`.
5. Review `.dpkg-dist` files (`lvm.conf`, `grub`, `chrony.conf`, `sshd_config`) before rebooting.
6. Reboot. Check: `nic0` exists and is in `vmbr0`, host reachable, kernel, ZFS module/tools match,
   all onboot containers up, USB (`/dev/ttyUSB0` Zigbee, `/dev/ttyACM0` Thread) and `/dev/dri` in
   CT 101/201, SMB on CT 100, `pvesm status` (pbs-lxc), Prometheus targets, Kuma green.

Result after the reboot (checked 2026-11-01): pve-manager 9.2.24, Debian 13, kernel 7.0.14-26-pve,
ZFS 2.4.4, both pools healthy, `pve8to9`: 0 warnings, 0 failures, `dpkg --audit` clean. `nic0` up in
`vmbr0`; all 7 containers running; USB and `/dev/dri` present in CT 101/201; Samba active; PBS
storage active.

Follow-ups done the same day:
- **Traefik came up with every `crowdsec@docker` route broken (404 on every site).** At boot it
  timed out downloading the CrowdSec bouncer plugin from plugins.traefik.io, disabled plugins, and
  the middleware never existed. `docker restart traefik` fixed it. This can happen at any host
  reboot; open item: make the plugin load offline or start Traefik only once DNS/internet is up.
- `pve-enterprise.sources` (added by the upgrade) got `Enabled: no`: no subscription, so `apt update`
  failed with 401. Backup `/root/pve-enterprise.sources.bak-2026-11-01`.
- Kept the local `lvm.conf` (only comments differ), `sshd_config` (explicit key-only root login) and
  `/etc/issue` (Proxmox banner). The packages' versions are in `/root/phaseb-dpkg-dist/`.

Still open: PBS in CT 105 runs 3.4.8 with 3.4.9 installed (Phase C restarts it); `openipmi.service`
fails (no IPMI hardware, also before the upgrade); old 6.8 kernels (Phase D); commented bookworm
`.list` files (`apt modernize-sources`, Phase D).

### Phase C: PBS 3 → 4 (CT 105, done 2026-11-01)

Followed https://pbs.proxmox.com/wiki/Upgrade_from_3_to_4 (it doesn't cover PBS in an LXC):
config tar `/root/pbs3-etc-backup-2026-11-01.tar.gz` (on pvehost) + `vzdump 105` to `backups` →
datastore read-only maintenance → latest 3.4 (3.4.9) → `sources.list` to trixie, `pbs.list` and the
empty `pbs-enterprise.list` replaced by `proxmox.sources` (`pbs-no-subscription`; old files in
`/root/apt-backup-2026-11-01/` in the CT) → `dist-upgrade` with `--force-confold` (≈2 min) →
`pct reboot 105` → maintenance cleared.

Result: PBS 4.2.8 on Debian 13; `dpkg --audit` clean; ntfy test notification sent; a host config
backup from PVE 9 to PBS 4 worked. `pbs3to4` still shows the container false positives (package
FAIL, kernel, NTP, GRUB). Took the package `/etc/cron.d/e2scrub_all`; kept `/etc/crontab` and
`/etc/issue` (package versions in `/root/phasec-dpkg-dist/`). `zfs-mount`, `zfs-share` and
`zfs-zed` fail inside the CT: zfsutils is a PBS dependency, but the container has no `/dev/zfs`.
Harmless.

### Phase D: later

`apt modernize-sources`, remove old kernels after a stable period, `zpool upgrade` only once a
rollback is no longer wanted. Then: move CT rootfs volumes to `zfspool` storage so vzdump can use
snapshot mode (see [backups.md](backups.md)).

## Recovery prompt for an outside agent

If the host breaks, the agents box (CT 102) is down with it. Paste this into any assistant on a
phone or laptop and run the commands at the host's console. It has no secrets and no MAC address.
Update it when the setup changes.

````text
You are helping me recover my Proxmox homelab server. I am at its physical console (keyboard
and monitor). You cannot reach the server: I will type the commands and paste you the output.
Work one step at a time. Explain what each command does before I run it. Diagnose first, using
read-only commands, and fix only after that. Use web search and prefer the official Proxmox
docs and forum (pve.proxmox.com/wiki, forum.proxmox.com). If you are unsure, say so and stop.
Never ask me for passwords, tokens or keys.

NEVER suggest these without stopping first, explaining the risk and getting my explicit OK:
zpool destroy/create/labelclear/upgrade, wipefs, partitioning or formatting disks,
`apt remove proxmox-ve`, rm on /etc/pve or on the ZFS pools, `pct destroy`, reinstalling Proxmox.
If apt says it will remove `proxmox-ve`, stop. That almost always means the repositories are wrong.

## The setup
- One Proxmox VE host, "pvehost", 192.168.1.148, no cluster. Single NIC bridged as vmbr0.
- ZFS pools: `flash` (NVMe mirror) and `vault` (HDD mirror). Container disks are .raw files on
  directory storages on those pools, so the data survives a Proxmox reinstall if the pools are
  imported again.
- LXC containers (no VMs):
  100 vault (Samba file shares), 101 docker-prod 192.168.1.224 (most services, DNS (Technitium),
  ntfy, Uptime Kuma), 102 agents, 104 docker-tower 192.168.1.248, 105 pbs 192.168.1.251
  (Proxmox Backup Server, datastore "homelab-backups"), 106 warpgate, 201 jellyfin.
  CT 101 and 201 use passthrough of /dev/dri, plus USB /dev/ttyUSB0 (Zigbee) and /dev/ttyACM0 (Thread) in 101.
- My monitoring and alerts (Uptime Kuma, ntfy) and my LAN DNS run in CT 101 on this host.
  If the host is down, I get no alerts and LAN DNS may fail. Use IPs, not hostnames.
- Backups: weekly vzdump of the containers to PBS in CT 105, plus a weekly host config backup
  (/etc, /etc/pve, /var/lib/pve-cluster, /root) to the same PBS as backup type "host",
  backup id "pvehost". Database dumps are in /docker/db-dumps inside CT 101.
  The data and docker folders are also in Backblaze (cloud).

## Current state and recent changes
- Upgraded from PVE 8.4 to Proxmox VE 9.2.24 (Debian 13 trixie) on 2026-11-01. Running kernel
  7.0.14-26-pve; the old 6.8.12-43-pve kernel is still installed as a fallback. ZFS 2.4.4.
  Repositories: Debian in /etc/apt/sources.list (trixie), Proxmox no-subscription in
  /etc/apt/sources.list.d/proxmox.sources, enterprise repo disabled (`Enabled: no`).
- The onboard NIC is called "nic0" (was "enp4s0"), pinned by MAC in
  /usr/local/lib/systemd/network/50-pve-nic0.link; vmbr0's bridge-ports is nic0.
  Undo: delete the .link file, put enp4s0 back in /etc/network/interfaces, reboot.
  Originals: /root/nic-pinning-backup-2026-10-24/
- GRUB also maintains the fallback EFI bootloader (grub2/force_efi_extra_removable=true).
  ESP backup: /root/esp-backup-2026-10-24.tar.gz
- Known reboot issue: Traefik in CT 101 can start before the internet is reachable, fail to download
  its CrowdSec plugin, and then return 404 for every website. Fix: `pct exec 101 -- docker restart traefik`.
Guide used: https://pve.proxmox.com/wiki/Upgrade_from_8_to_9
My notes are in docs/proxmox.md in my GitHub repo (dcvdiego/homelab).

## Likely problems, and where to start
- Host boots but has no network: compare `ip -br link` and `ip -br addr` with
  /etc/network/interfaces. Either the NIC is still called enp4s0 while the config says nic0, or the
  other way round. Also check `bridge link` and `journalctl -b -u networking`.
- Host doesn't boot: in the GRUB menu, try "Advanced options" with the older kernel (6.8.12-43-pve). Find out the boot setup: `proxmox-boot-tool status`, `efibootmgr -v`,
  `findmnt /`. The Proxmox ISO has a rescue boot option.
- After an update or reboot, every website shows 404: see the Traefik note above.
- Upgrade interrupted or half-done: `dpkg --audit`, `dpkg --configure -a`, `apt -f install`.
  Check that every repository uses the same Debian release (no bookworm/trixie mix) before
  running `apt dist-upgrade` again.
- ZFS pools missing: `zpool status`, `zpool import` (read the output; don't force anything without asking).
- A container doesn't start: `pct start <id> --debug`, `journalctl -b`, `pct config <id>`.
  Missing /dev/dri or USB devices are a common cause after an upgrade.
- Restoring from backup: PBS runs in CT 105 on this same host, so it has to start first.
  Container backups can be restored with `pct restore` from the "pbs-lxc" storage. Restore to a
  NEW container ID first, not over the original.
- Last resort, ONLY with my OK: a fresh Proxmox VE install on the OS disk, then
  `zpool import` flash and vault, then restore the host config backup from PBS. Do not overwrite
  the pool disks during the install.

Start by asking me what I see on the screen and when the problem started.
````
