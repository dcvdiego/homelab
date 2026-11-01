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
| NIC pinning: `pve-network-interface-pinning generate` (enp4s0 → `nic0`) | generated, **pending until the next reboot** (see below) |
| Fresh backups (all CTs to PBS + `pve-host-backup.service`) | **do right before Phase B** |

#### Pending NIC rename (applies at the next reboot, planned or not)

- `/usr/local/lib/systemd/network/50-pve-nic0.link`: matches the onboard NIC by MAC (only in that file, not here) → `nic0`.
- `/etc/network/interfaces.new`: `enp4s0` → `nic0` in `iface` and `bridge-ports` of `vmbr0`; swapped in at boot.
- Side effect: an empty `/etc/pve/sdn/controllers.cfg` (SDN unused).
- **Don't** "Apply Configuration" in the web UI's Network panel or run `ifreload -a` before that
  reboot: `nic0` doesn't exist until then, so the host would lose its network. "Revert" is safe.
- Undo before rebooting: delete the `.link` file, `/etc/network/interfaces.new` and the empty
  `controllers.cfg`. Backups: `/root/nic-pinning-backup-2026-10-24/`.

### Phase B: 8.4 → 9 (about 45–60 min downtime; needs physical console access)

1. Step 5 of Phase A: fresh backups. Re-run `pve8to9 --full` (expect only "running guests").
2. Sources to trixie in deb822 format (`.sources`), keep the gierens repo; `apt update`. Review before continuing.
3. Stop all containers.
4. `apt dist-upgrade` detached, `--force-confdef --force-confold`; check `dpkg --audit`.
5. Review `.dpkg-dist` files (`lvm.conf`, `grub`, `chrony.conf`, `sshd_config`) before rebooting.
6. Reboot. Check: `nic0` exists and is in `vmbr0`, host reachable, kernel, ZFS module/tools match,
   all onboot containers up, USB (`/dev/ttyUSB0` Zigbee, `/dev/ttyACM0` Thread) and `/dev/dri` in
   CT 101/201, SMB on CT 100, `pvesm status` (pbs-lxc), Prometheus targets, Kuma green.

### Phase C: PBS 3 → 4 (CT 105, about 15 min, backups only)

`apt full-upgrade` on 3.4 → `vzdump 105` to local `backups` storage → sources to trixie →
`dist-upgrade` → restart → test backup + `proxmox-backup-manager notification target test ntfy`.

### Phase D: later

`apt modernize-sources`, remove old kernels after a stable period, `zpool upgrade` only once a
rollback is no longer wanted. Then: move CT rootfs volumes to `zfspool` storage so vzdump can use
snapshot mode (see [backups.md](backups.md)).

## Recovery prompt for an outside agent

If the host breaks, the agents box (CT 102) is down with it. Paste this into any assistant on a
phone or laptop and run the commands at the host's console. It has no secrets and no MAC address.
Update it when the setup changes (for example after Phase B: the "before" state becomes PVE 9).

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

## What changed recently (prep for the Proxmox VE 8.4 -> 9 upgrade, done 2026-10-24)
Before this, the host was on PVE 8.4.21 (Debian 12 bookworm), kernel 6.8.12-43-pve.
1. /etc/apt/sources.list: non-free-firmware added; intel-microcode installed.
   Backup: /etc/apt/sources.list.bak-2026-10-24
2. GRUB: debconf grub2/force_efi_extra_removable=true, grub-efi-amd64 reinstalled
   (installs the fallback EFI bootloader too). ESP backup: /root/esp-backup-2026-10-24.tar.gz
3. NIC name pinning (Proxmox's pve-network-interface-pinning tool): the onboard NIC, previously
   "enp4s0", is renamed to "nic0" at boot by /usr/local/lib/systemd/network/50-pve-nic0.link
   (matches by MAC address). /etc/network/interfaces.new uses nic0 (iface and vmbr0
   bridge-ports); Proxmox moves it to /etc/network/interfaces at boot. An empty
   /etc/pve/sdn/controllers.cfg was created. Backups of the originals:
   /root/nic-pinning-backup-2026-10-24/
   Undo: delete the .link file, put enp4s0 back in /etc/network/interfaces (and remove
   interfaces.new if it is there), then reboot or `systemctl restart networking`.
The planned upgrade (Phase B): sources switched to trixie in deb822 .sources files, all containers
stopped, `apt dist-upgrade` with --force-confold, review the .dpkg-dist files, reboot.
Guide: https://pve.proxmox.com/wiki/Upgrade_from_8_to_9
My plan notes are in docs/proxmox.md in my GitHub repo (dcvdiego/homelab).

## Likely problems, and where to start
- Host boots but has no network: compare `ip -br link` and `ip -br addr` with
  /etc/network/interfaces. Either the NIC is still called enp4s0 while the config says nic0, or the
  other way round. Also check `bridge link` and `journalctl -b -u networking`.
- Host doesn't boot: in the GRUB menu, try "Advanced options" with an older kernel (6.8.12-43-pve should
  still be installed). Find out the boot setup: `proxmox-boot-tool status`, `efibootmgr -v`,
  `findmnt /`. The Proxmox ISO has a rescue boot option.
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
