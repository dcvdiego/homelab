resource "proxmox_lxc" "lxc-docker" {
    features {
        nesting = true
    }
    hostname = "container_name_here"
    network {
        name = "eth0"
        bridge = "vmbr0"
        ip = "dhcp"
        ip6 = "dhcp"
    }
    ostemplate = "local:ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
    password = "rootroot"
    pool = "terraform"
    target_node = "pvehost"
    unprivileged = true

    rootfs {
    storage = "disks"
    size    = "8G"
  }
}