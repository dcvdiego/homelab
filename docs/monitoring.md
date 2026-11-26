# Monitoring

Everything is in the `monitoring` stack on docker-prod (`docker-compose/monitoring`). The config files
are mounted from git (Komodo's checkout), so a merge plus a deploy changes them. Nothing is copied by hand.

| What | Where it comes from | Stored in | Dashboard |
|---|---|---|---|
| Host CPU, memory, disk (pvehost, docker-prod, docker-tower) | node_exporter on each, scraped every 15s | Prometheus | Node Exporter Full |
| Containers on docker-prod: CPU, memory, network, block I/O | Alloy's built-in cAdvisor, remote-written every 30s | Prometheus | Homelab → Docker containers (cAdvisor) |
| Proxmox guests (each LXC's CPU, memory, disk, network), storage | `pve-exporter` → pvehost API, read-only token (`/docker/grafana-monitoring/pve-exporter/token` in CT 101) | Prometheus | Homelab → Proxmox (pve-exporter) |
| Frigate | its `/api/metrics` | Prometheus | — |
| Logs (all containers, `/var/log`) | Alloy | Loki, 14 days | Logging Dashboard via Loki, Logs / App |
| Up/down, alerts to ntfy | Uptime Kuma | its embedded MariaDB | status page |

Prometheus keeps 30 days, capped at 5 GB on disk. There used to be a second database, InfluxDB 2, fed by
Telegraf. It was removed on 2026-11-26: Prometheus does the same job with one database instead of two, and
the Proxmox feed into InfluxDB had already stopped working.

## Memory

Each service has a `mem_limit` sized well above what it normally uses. This stops a runaway (a leak, or a
huge query) from pushing the whole host into swap. The Go services (Prometheus, Loki, Alloy) also set
`GOMEMLIMIT` to about 80% of their cap, so the garbage collector works harder as usage nears the cap
instead of being killed at it. If a service is OOM-killed (`docker inspect -f '{{.State.OOMKilled}}'`),
raise its cap rather than removing it.

What keeps the footprint small:
- The cAdvisor feed covers Docker containers only, keeps only the compose project and service labels, and
  sends only the metric groups the dashboard uses (cpu, memory, network, diskIO, oom_event), about 35
  series per container.
- There is a single time-series database. Every new feed goes into Prometheus.
- Uptime Kuma: most of its memory is its embedded MariaDB. Settings → Monitor History at 30 days keeps
  that database small.

## Grafana

Provisioned from `docker-compose/monitoring/grafana/`:
- Prometheus is the default data source, and the old InfluxDB data sources are deleted.
- The dashboards in `dashboards/` go in the **Homelab** folder. They can't be saved from the UI: export
  the JSON and commit it instead. Both were imported from grafana.com (10347, 14282), with the data
  source changed to a `$ds` variable.

Dashboards made in the UI (Node Exporter Full, the Loki ones) stay in Grafana's own database.
