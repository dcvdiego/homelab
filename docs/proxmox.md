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

## Power saving

Hardware: i3-13100 (4C/8T, 4.5 GHz boost) on an ASUS PRIME B760M-K, RTL8125 NIC, 2× NVMe, 2× SATA SSD, 2× HDD.

### Done (2026-11-22)

- **CPU policy**: `ops/pvehost/cpu-powersave.service` sets intel_pstate to `powersave` with EPP
  `balance_power` at boot. The PVE kernel defaults to `performance`, which pins EPP at 0. With HWP,
  intel_pstate's `powersave` still boosts under load; it is not the old fixed-lowest-clock governor
  ([kernel docs](https://kernel.org/doc/html/v7.0/admin-guide/pm/intel_pstate.html)). Measured with
  `turbostat` (package, 60 s, similar load): 24.9 W / 60 °C / 4.1 GHz → 17.2 W / 51 °C / 2.4 GHz.
  To check: `sort /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference | uniq -c`.
- `linux-cpupower` installed for `turbostat`:
  `turbostat --quiet --show Busy%,Bzy_MHz,PkgWatt,PkgTmp,Pkg%pc2,Pkg%pc6,Pkg%pc8 -i 60 -n 1`.

### Open (needs physical access, in case the network drops)

- **Package C-states are 0%** (pc2/pc6/pc8). Core C-states reach C10 (`intel_idle`, MWAIT 0x60) and
  the NVMe links have ASPM L1, but the RTL8125 has `l1_aspm=0` (r8169 leaves it off by default),
  which is the usual blocker on Intel desktops. Test with an automatic revert, at the console:
  `systemd-run --on-active=10min sh -c 'echo 0 > /sys/bus/pci/devices/0000:04:00.0/link/l1_aspm'`,
  then `echo 1 > …/l1_aspm`, then watch `turbostat` and the link (`ip -s link`, `dmesg`).
- **BIOS** (names vary by version): CPU C-states on and the package C-state limit at C10/Auto, Native ASPM +
  PCH/DMI ASPM on, unused onboard devices (audio, serial) off. Optional: a lower PL2 (about 45–50 W instead
  of 89 W), which cuts the heat and fan spikes at a small cost in peak speed.

### Not doing

- `powertop --auto-tune`: it enables USB autosuspend, which can put the Zigbee coordinator to sleep,
  and it has been reported to raise power draw on PVE.
- HDD spindown: Frigate and the media apps touch the disks constantly.
- Forcing ASPM with `pcie_aspm=force` or `max_cstate` kernel parameters.
