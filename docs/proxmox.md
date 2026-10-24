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

- `/usr/local/lib/systemd/network/50-pve-nic0.link`: MAC `10:7c:61:76:80:ae` → `nic0`.
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
