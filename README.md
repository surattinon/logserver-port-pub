# logserver-port-pub

> [!NOTE]
> This repository is a copy of a private production repository, published for portfolio purposes only.

**Centralized Log Server**

| Field | Value |
| -------------- | -------------------------------- |
| Hostname | `logserver` |
| Environment | Production |
| Platform | Nutanix AHV - Ubuntu 24.04 LTS |
| App Root | `/opt/logserver` |
| Timezone | Asia/Bangkok (ICT, UTC+7) |

Firewall devices at Bangkok HO forward syslog over UDP/514 to Graylog. Graylog parses and routes logs to OpenSearch. Grafana reads OpenSearch and Prometheus for dashboards and alerts, delivering notifications to Microsoft Teams. Deployment is GitOps: a service account pulls from a private Git repository and applies changes to production.

**Stack:** Graylog 7.1.0 · OpenSearch 2.19.5 · MongoDB 7.0 · Grafana 13.0.1+security-01 · Prometheus v3.11.3 · Node Exporter v1.11.1 — all Docker Compose, managed via `Makefile`.

**Log sources (current scope — 2 sources):** Palo Alto PA-3220 (`192.168.1.X`) and WatchGuard HQ (`192.168.1.X`). A WatchGuard PPD device is referenced in earlier planning material but is **out of scope** for this deployment and is not wired into any stream, pipeline, or index set.

______________________________________________________________________

# Centralized Log Server — Architecture Overview

| Field | Value |
| ------------------ | -------------------------------- |
| **Project** | Centralized Log Server |
| **Environment** | Production |
| **Hostname** | logserver-prod |
| **Platform** | Nutanix AHV — Ubuntu 24.04 LTS |
| **App Root** | `/opt/logserver` |
| **Timezone** | Asia/Bangkok (ICT, UTC+7) |
| **Author** | Author |
| **Version** | 2.0 |
| **Classification** | CONFIDENTIAL — Internal Use Only |

______________________________________________________________________

## Graylog Content Pack

Imports the full custom Graylog configuration in one operation with content pack file:

- 1 Syslog UDP input (port 514)
- 2 streams: `Syslog UDP - ALL`, `PAN-OS Logs`, plus `WatchGuard Logs`
- 3 pipelines: Device Router, PAN-OS Log Parser, WatchGuard Log Parser
- All pipeline rules (routing, field extraction, LEEF parsing, schema normalization)
- Lookup tables and data adapters for WatchGuard log catalog classification

> **Import order matters:** Create index sets in Graylog before importing the content pack (System → Index Sets → Create), or stream-to-index-set mapping will fail. Export/download via `GET /api/system/content_packs/{id}/{rev}/download` — not `/export`.

______________________________________________________________________

## Repository Structure

```
logserver/
├── README.md
├── Makefile                        # Stack management (make up / down / logs / ps / pull / install-cron)
├── docker-compose.yml              # Base compose — shared services and network
├── .env.example                    # Template for .env.prod (do not commit .env.prod)
├── .gitignore
├── .pre-commit-config.yaml         # Mirrors CI checks on staged files
│
├── .github/
│   └── workflows/
│       ├── quality.yml             # gitleaks, shellcheck, markdownlint
│       └── config-validation.yml   # compose-config, yamllint, cron-syntax (parallel jobs)
│
├── services/
│   ├── graylog.yml
│   ├── grafana.yml
│   └── prometheus.yml
│
├── configs/
│   ├── graylog/
│   │   └── lookup/
│   │       ├── device-info/
│   │       └── wg-log-catalogs/
│   │
│   ├── opensearch/
│   │   └── opensearch.yml          # Mounted read-only; node/cluster-level settings
│   │
│   ├── grafana/
│   │   └── provisioning/
│   │       ├── datasources/        # OpenSearch + Prometheus datasource YAML
│   │       └── alerting/           # Alert rules, contact points, notification policy
│   │
│   ├── prometheus/
│   │   └── prometheus.yml          # Scrape config: Graylog, OpenSearch, Node Exporter
│   │
│   └── cron/
│       └── logserver         # Installed to /etc/cron.d/ as a copy via `make install-cron`
│
├── grafana-gitsync/                 # Dashboard JSON (v2 schema) — synced by Grafana Git Sync, replaces classic file provider
│   ├── Firewall Ops/
│   └── Host Metrics/
│
├── scripts/
│   ├── deploy.sh                    # GitOps pull-based deploy, run as svc-logserver
│   ├── update-snapshot-scope.sh     # Daily 01:30 — scopes SM policy to last 7 days of indices
│   ├── export-content-pack.sh
│   ├── mongodump.sh
│   └── git-autocommit.sh
│
├── content-packs/
│   └── content-pack-307cb4eb-...-4.json
│
└── assets/
    ├── hl-tascologserver-arch.png
    └── logserver-backup-arch-v1.png
```

______________________________________________________________________

## Quick Reference

### Stack Management

```bash
cd /opt/logserver

ENV=prod make up        # Start all services
ENV=prod make down      # Stop all services
ENV=prod make ps        # Check container status
ENV=prod make logs      # Tail all logs
ENV=prod make pull      # Pull latest images (before upgrade)
ENV=prod make restart   # Restart all services
ENV=prod make install-cron   # Install/refresh cron jobs from configs/cron/
```

### Key Endpoints (internal only — no public exposure)

| Service | URL | Purpose |
| -------------- | ----------------------- | ----------------------------------------------- |
| Graylog Web UI | `http://<vm-ip>:9000` | Log search, stream/pipeline management |
| Grafana | `http://<vm-ip>:3000` | Dashboards and alert management |
| Prometheus | `http://<vm-ip>:9090`\* | Host/service metrics (confirm exposure/binding) |
| OpenSearch API | `http://localhost:9200` | Index management, snapshot API (localhost only) |

\* Prometheus port exposure was not confirmed in source material — verify against `services/prometheus.yml` before treating this as authoritative.

### Log Sources (current scope)

| Device | Site | Protocol | Source IP |
| ------------------ | ------------------- | -------------- | ------------ |
| Palo Alto PA-3220 |  | Syslog UDP/514 |  |
| WatchGuard HQ |  | Syslog UDP/514 |  |

### Secrets

Never commit `.env.prod` to git. Use `.env.example` for the template with relative paths; `.env.prod` holds absolute paths and is GPG-backed up after every change.

---

# Documentation

## 1. Purpose & Scope

This document describes the architecture of the Centralized Log Server — what each component is, how they connect, and why the system is designed the way it is. It is the primary reference for understanding the system before reading any runbook.

**In scope:**

- All infrastructure components running on the production VM
- Log ingestion, parsing, indexing, dashboarding, and alerting pipeline
- Host/service monitoring (Prometheus + Grafana)
- Backup architecture summary (full detail in doc 04)
- GitOps/CI-CD summary (full detail in doc 05)
- Security design
- Known limitations and future improvement paths

**Out of scope:**

- Firewall device configuration (PAN-OS, WatchGuard)
- Commvault CommServe and MediaAgent infrastructure
- Network routing between sites
- WatchGuard PPD — not part of the current deployment (see §3.3)

______________________________________________________________________

## 2. High-Level Architecture

Firewall devices at Bangkok HO forward syslog over UDP/514 to Graylog. Graylog receives, routes, and parses the logs, then writes them to OpenSearch. Grafana reads OpenSearch (log data) and Prometheus (host/service metrics) for dashboards and alert evaluation, and delivers alerts to Microsoft Teams.

![HL-log-arch](./assets/hl-logserver-arch.png)

### Component Summary

| Component | Role | Technology |
| --------------- | ------------------------------------------- | --------------------------------- |
| Graylog | Log ingestion, routing, parsing, enrichment | Graylog 7.1.0 (Docker) |
| OpenSearch | Log storage and full-text search engine | OpenSearch 2.19.5 (Docker) |
| MongoDB | Graylog configuration and metadata store | MongoDB 7.0 (Docker) |
| Grafana | Dashboards and alert evaluation | Grafana 13.0.1+security-01 (Docker) |
| Prometheus | Host/service metrics collection | Prometheus v3.11.3 (Docker) |
| Node Exporter | Host-level metrics for Prometheus | Node Exporter v1.11.1 (Docker) |
| Microsoft Teams | Alert delivery channel | Webhook / Power Automate Workflow (migration in progress — see doc 06) |

All Docker services run on a single Nutanix AHV VM and communicate over an internal Docker bridge network (`logserver_net_${ENV}`). No service is exposed directly to the internet.

______________________________________________________________________

## 3. Infrastructure & VM Specification

### 3.1 Virtual Machine Resources

| Parameter | Value |
| ------------- | ---------------------- |
| Host Platform | Nutanix AHV |
| OS | Ubuntu 24.04 LTS |
| vCPU | 8 |
| RAM | 32 GB |
| App Root | `/opt/logserver` |

### 3.2 vDisk Layout

| vDisk | Size | Mount Point | Filesystem | Purpose |
| ------- | ------ | ----------------------------- | -------------- | ---------------------------------------------------------------- |
| vDisk 0 | 80 GB | `/` | ext4 (default) | OS, Docker Engine, app root, compose files, configs |
| vDisk 1 | 2.9 TB | `/data/opensearch` | xfs | OpenSearch live index data |
| vDisk 2 | 175 GB | `/data/gl-journal` | xfs | Graylog ingestion journal (excluded from all backups by design) |
| vDisk 3 | 8 GB | `/data/mongodb` | xfs | MongoDB data (Graylog config state) |
| vDisk 4 | 350 GB | `/data/opensearch-snapshots` | xfs | OpenSearch snapshot repository (dedicated) |

### 3.3 Log Source Network — Current Scope

| Source | Device | Protocol | Source IP | Destination Port |
| ---------------- | ------------------- | ---------- | ------------ | ----------------- |
| PAN-OS | PA-3220 | Syslog UDP | 192.168.1.X | 514 |
| WatchGuard | WatchGuard HQ | Syslog UDP | 192.168.1.X | 514 |

Both sources share a single Graylog Syslog UDP input. Device identity is resolved by source IP inside the Device Router pipeline.

______________________________________________________________________

## 4. Docker Stack

### 4.1 Services

| Service | Image | Host Port(s) | Container Path | Resource Limit |
| ------------- | ------------------------------------ | -------------------- | ---------------------------------- | -------------------------- |
| `graylog` | graylog/graylog:7.1.0 | 9000/tcp, 514/udp | `/usr/share/graylog/data/journal` | 4.0/2.0 vCPU · 6 GB/3 GB RAM |
| `opensearch` | opensearchproject/opensearch:2.19.5 (custom, + prometheus-exporter-plugin 2.19.5.0) | 127.0.0.1:9200/tcp | `/usr/share/opensearch/data` | 6.0/3.0 vCPU · **22 GB**/10 GB RAM |
| `mongodb` | mongo:7.0 | — (internal only) | `/data/db` | 1.0 vCPU · 2 GB RAM |
| `grafana` | grafana/grafana-oss:13.0.1+security-01 | 3000/tcp | `/etc/grafana/provisioning` | — |
| `prometheus` | (Prometheus v3.11.3) | internal / TBD | — | — |
| `node-exporter` | (Node Exporter v1.11.1) | internal | host metrics | — |


### 4.2 Container Dependency Order

MongoDB and OpenSearch must reach healthy state before Graylog starts. Graylog must reach healthy state before log ingestion can begin.

```
mongodb --> (healthy)
opensearch --> (healthy)
               └--> graylog --> (healthy) --> grafana
prometheus --> node-exporter (independent of the above chain)
```

Healthcheck endpoints:

- **Graylog:** `GET /api/system/lbstatus` → `{"status":"alive"}`
- **OpenSearch:** `GET /_cluster/health` → `status: green or yellow`
- **MongoDB:** `mongosh --eval "db.adminCommand('ping')"` → `{ ok: 1 }`

### 4.3 Internal Network

All containers communicate over a Docker bridge network. Container-to-container addressing uses Docker service names as hostnames:

| Connection | Address |
| -------------------- | --------------------------------- |
| Graylog → OpenSearch | `http://opensearch:9200` |
| Graylog → MongoDB | `mongodb://mongodb:27017/graylog` |
| Grafana → OpenSearch | `http://opensearch:9200` |
| Grafana → Prometheus | `http://prometheus:9090` (datasource uid `ds-prometheus-host-metrics`) |
| Prometheus → Graylog | `http://graylog:9833` (native exporter) |
| Prometheus → OpenSearch | `http://opensearch:9200/_prometheus/metrics` |

### 4.4 Compose Management

The stack is managed via a `Makefile` wrapping Docker Compose, layering `docker-compose.yml` + `services/graylog.yml` + `services/grafana.yml` + `services/prometheus.yml`. `ENV` selects `.env.$(ENV)`.

```bash
ENV=prod make up        # start all containers
ENV=prod make down      # stop all containers
ENV=prod make ps        # show container status
ENV=prod make logs      # tail all logs
ENV=prod make restart   # restart all containers
ENV=prod make pull      # pull latest images
ENV=prod make install-cron   # copy configs/cron file to /etc/cron.d + reload cron
```

> The Makefile default is `ENV=dev`. Always prefix with `ENV=prod` in production.

______________________________________________________________________

## 5. Log Flow

### 5.1 End-to-End Path

![LogPipeline](../assets/Logserver%20Pipeline.png)

### 5.2 Syslog Transit Stream

All messages from the Syslog UDP input first land in the `Syslog UDP - ALL` stream backed by the `syslog_transit` index set (3-day retention). This stream is a staging point from which the Device Router pipeline routes messages to the appropriate device stream. It is not used for long-term querying.

______________________________________________________________________

## 6. Graylog Pipeline Design

### 6.1 Pipeline: Device Router

**Connected stream:** Syslog UDP - ALL

Runs on every message arriving on the Syslog UDP input. It identifies the sending device by source IP (`gl2_remote_ip`), tags the message with `site` and `device_vendor` fields, and routes it to the correct stream.

| Stage | Purpose |
| ------- | ------------------------------------------------------------------------------------------------- |
| Stage 0 | Match source IP → set tag `site` (BKK_HO) and `device_vendor` (PaloAlto or WatchGuard) |
| Stage 1 | Route to `PAN-OS Logs` stream if `device_vendor = PaloAlto`, or `WatchGuard Logs` if `WatchGuard` |

Messages that don't match a known source IP remain in `Syslog UDP - ALL` only and are not routed.

### 6.2 Pipeline: PAN-OS Log Parser

**Connected stream:** PAN-OS Logs

Parses raw PAN-OS syslog messages (comma-separated CSV), extracting fields such as `src_ip`, `dst_ip`, `action`, `bytes`, and normalizing to a common schema.

### 6.3 Pipeline: WatchGuard Log Parser

**Connected stream:** WatchGuard Logs

Parses LEEF tab-delimited key/value pairs, classifies against the WatchGuard log catalog via CSV lookup, and normalizes to the common schema.

______________________________________________________________________

## 7. OpenSearch Index Design

### 7.1 Index Sets

| Index Set | Prefix | Rotation | Max Indices | Retention | Purpose |
| -------------- | ----------------- | ----------- | ----------- | --------- | ---------------------------- |
| syslog_transit | `syslog_transit` | Daily (P1D) | 3 | 3 days | Staging before routing |
| pan_os_log | `pan_os_logs` | Daily (P1D) | 100 | 100 days | PAN-OS long-term storage |
| watchguard_log | `watchguard_logs` | Daily (P1D) | 100 | 100 days | WatchGuard long-term storage |

> Index names are numbered per set (`pan_os_logs_0`, `pan_os_logs_1`, …) — there is no date embedded in the name, so date-math index patterns are not usable. Retention is driven by the Thai Computer Crime Act (minimum 90 days; implemented as 95–100 days).

### 7.2 Capacity Planning

| Index Set | Est. Daily Volume (post-indexed) | Retention | Est. Total |
| -------------- | --------------------------------- | ----------- | ------------- |
| syslog_transit | ~25 GB/day | 3 days | ~75 GB |
| pan_os_log | ~12 GB/day | 95–100 days | ~1,140–1,200 GB |
| watchguard_log | ~7 GB/day | 95–100 days | ~665–700 GB |
| **Total** | - | - | **~1,975 GB** |


### 7.3 Key Runtime Settings

Node/cluster settings live in `configs/opensearch/opensearch.yml`, mounted read-only to `/usr/share/opensearch/config/opensearch.yml`. This file replaces the image's demo config, so it must reproduce every setting still needed.

| Parameter | Value | Reason |
| --------------------------- | ------------------------------------------- | --------------------------------------------------------- |
| `discovery.type` | `single-node` | Disables ZenDiscovery for single-node deploy |
| `network.host` | `0.0.0.0` | Bind for container networking |
| `action.auto_create_index` | `false` | Critical — Graylog manages index lifecycle |
| `path.repo` | `/usr/share/opensearch/snapshots` | Snapshot repository mount point inside the container |
| `plugins.security.disabled` | `true` | Security plugin disabled — internal Docker network only |
| `bootstrap.memory_lock` | `true` | Prevents JVM heap from being swapped to disk |
| Disk watermarks | low 85% / high 90% / flood 95% | See §7.4 |
| `vm.max_map_count` | `262144` | Host-level sysctl — required by OpenSearch |
| JVM heap (`Xms`/`Xmx`) | **10g / 10g** | Set via `OPENSEARCH_JAVA_OPTS` env var — stays as env var, not in the file |

**Settings that remain as compose env vars** (not in `opensearch.yml`): `OPENSEARCH_JAVA_OPTS`, `OPENSEARCH_INITIAL_ADMIN_PASSWORD`, `TZ`.

> Watermarks live in the file *or* as dynamic `_cluster/settings` — never both, since dynamic settings override the file and can silently diverge from it.

### 7.4 Disk Watermarks

| Watermark | Threshold | Effect |
| --------- | --------- | ---------------------------------------------------- |
| Low | 85% | Stops shard allocation to the node |
| High | 90% | Triggers shard relocation away from the node |
| Flood | 95% | Sets **all** indices read-only; requires manual API recovery |

### 7.5 Compression

`zstd` codec, compression level 3 (minimum restore-compatible version OpenSearch 2.9 — pin the image tag, never use `latest`). Applied via **legacy `_template` entries only**, settings-only, `order: 10` (higher than Graylog's `order: 0`, so it merges rather than replaces):

- `_template/pan_os_logs-zstd-codec`
- `_template/watchguard_logs-zstd-codec`

> **Do not** use a composable `_index_template` for this. Composable templates always win over legacy `_template` regardless of priority order and will silently **replace** Graylog's legacy mappings — this previously caused `timestamp` fields to become `text` type and broke index time ranges. Legacy `_template` entries merge and preserve Graylog's mappings; that's why this approach is mandatory, not a style preference.

**Applied by:** `scripts/opensearch-bootstrap.sh` — idempotent, from JSON seed files `configs/opensearch/legacy-template-pan_os_logs-zstd-codec.json` and `configs/opensearch/legacy-template-watchguard_logs-zstd-codec.json`. See doc 02 §7.2 and doc 05 §8 for the full bootstrap flow, including why it never touches a live SM policy.

______________________________________________________________________

## 8. Grafana & Alerting

### 8.1 Datasources

| Parameter | Value |
| -------------- | ------------------------------------------------- |
| Type | OpenSearch (grafana-opensearch-datasource plugin) |
| Name | Graylog OpenSearch (`ds-graylog-opensearch`) |
| URL | `http://opensearch:9200` |
| Index patterns | `pan_os_logs_*`, `watchguard_logs_*` |
| Time field | `timestamp` (not `@timestamp`) |
| Type | Prometheus |
| Name | Host Metrics (`ds-prometheus-host-metrics`) |
| URL | `http://prometheus:9090` |

> Index patterns must match the actual index prefix (`pan_os_logs`, `watchguard_logs` — plural). An index pattern of `pan_os_log_*` (singular) will not match real index names.

### 8.2 Dashboard Provisioning — Grafana Git Sync

Dashboards are provisioned via **Grafana Git Sync** (GA in Grafana 13, repo `r8tjtk`), not the classic file provider. Dashboard JSON uses the v2 resource schema.

The home dashboard is set via `PATCH /api/org/preferences` with `homeDashboardUID` — the `GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH` env var cannot parse v2 schema and is not used.

### 8.3 Alerting

Grafana evaluates alert rules against OpenSearch and Prometheus query results. Alerts route to Microsoft Teams via a **two-channel model**: `logserver-critical` and `logserver-warning`, selected by severity label.

| Parameter | Value |
| ------------------- | -------------------------------------------------------------- |
| Contact points | `logserver-critical`, `logserver-warning` (Microsoft Teams) |
| Notification policy | Route by `severity` label |
| Delivery mechanism | Migrating from classic O365 webhooks to Power Automate Workflows — see doc 06 |

______________________________________________________________________

## 9. Monitoring (Prometheus + Grafana)

Prometheus scrapes:

- **Graylog** — native exporter, port 9833
- **OpenSearch** — `/_prometheus/metrics` on 9200, via a custom image with `prometheus-exporter-plugin 2.19.5.0`; per-index metrics enabled (`prometheus.indices: true` with `selected_indices` filtering) in `opensearch.yml`
- **Node Exporter** — host-level metrics

A five-dashboard plan (D1 Overview, D2 Graylog Pipeline, D3 Per-Source Flow, D4 OpenSearch Cluster/Storage, D5 Host) is provisioned through Grafana Git Sync.

______________________________________________________________________

## 10. Backup Architecture

### 10.1 Design Principle

Commvault does not back up the live OpenSearch data directory (vDisk 1) directly — a raw hypervisor-level copy of a live OpenSearch data directory risks index file inconsistency. Instead:

1. OpenSearch writes application-consistent snapshots to a **dedicated vDisk 4** via the Snapshot API.
1. Commvault backs up **vDisk 4** — which contains only closed, immutable snapshot files that are safe to copy at any time. Daily compression of the snapshot repo before Commvault ingestion is counterproductive to incremental efficiency, so Commvault does direct file-level backup of the snapshot directory instead.

### 10.2 Backup Layer Summary

| Component | Primary | Class | Fallback |
| ------------------- | -------------------------------------- | ---------- | --------------------- |
| Compose + configs | Git (auto-commit cron + GitOps deploy) | Hot | Commvault file-level |
| Secrets | GPG encrypted copy | Hot/manual | — |
| Graylog config | mongodump daily | Hot | Commvault vDisk 3 |
| Grafana dashboards | Git Sync (dashboards live in Git) | Hot | JSON export fallback |
| OpenSearch log data | Snapshot API → vDisk 4 (hourly, **scoped to last 7 days of indices**) | Warm | Commvault vDisk 4 |
| Full VM | Commvault VM backup (excl. vDisk 1) | Cold | Nutanix snapshot |

> **Acknowledged risk:** the snapshot scope is limited to the 7 most recent days of indices (see doc 04 §snapshot scope decision). Indices older than 7 days have no snapshot-based recovery and depend solely on vDisk 1 integrity (Nutanix pool redundancy). This narrows disaster-recovery coverage for logs older than 7 days even though legal retention on vDisk 1 is 95–100 days.

______________________________________________________________________

## 11. GitOps & CI Summary

- **Deployment model:** pull-based. `scripts/deploy.sh` runs as `svc-logserver`, captures local drift to a `prod-autobackup` branch, then forces production to `origin/main` via `git reset --hard`.
- **Service account:** `svc-logserver` (home `/var/lib/svc-logserver`) holds the GitHub SSH deploy key and is a member of `docker` (accepted security tradeoff — `docker` group membership is root-equivalent) and `logserver-dev`.
- **CI:** `quality.yml` (gitleaks 8.30.1 pinned binary, shellcheck, markdownlint) and `config-validation.yml` (compose-config, yamllint, cron-syntax — parallel jobs). A pre-commit hook mirrors CI checks on staged files.
- **Human workflow:** humans never author commits directly on prod. Config changes go PR → merge → `git pull`/GitOps deploy on prod. Emergency hotfixes are surgical, applied as a `logserver-dev` member (never root), with same-day backport to Git.

______________________________________________________________________

## 12. Security Design

### 12.1 Host Firewall (UFW)

Default policy: deny all inbound, allow all outbound.

| Rule | Port/Protocol | Source | Purpose |
| ----- | -------------- | ---------------- | ---------------------- |
| Allow | 22/tcp | `<ADMIN_IP>` | SSH management |
| Allow | 9000/tcp | `<ADMIN_IP>` | Graylog Web UI |
| Allow | 3000/tcp | `<ADMIN_IP>` | Grafana Web UI |
| Allow | 514/udp | - | Syslog — PAN-OS |
| Allow | 514/udp | - | Syslog — WatchGuard HQ |

OpenSearch (9200) and MongoDB are not exposed to the host network — accessible only within the Docker bridge network.

### 12.2 DOCKER-USER Chain

Docker bypasses UFW's INPUT chain rules for published ports by inserting its own iptables rules — UFW INPUT rules alone are ineffective for Docker-published ports. All container access control must go through the `DOCKER-USER` chain in `/etc/ufw/after.rules`.

### 12.3 Secrets Management

- All stack secrets are stored in `.env.prod` on the host, never committed to Git.
- `.env.prod` permissions: `640 root:svc-logserver`.
- Encrypted backup: GPG-encrypted copy, updated after every secret change; destination path `backups/secret`, exported to the infra team's secure store.
- Container UIDs are non-root: OpenSearch (1000), Graylog (1100), MongoDB (999), Grafana (472).

### 12.4 Bind Mounts

All configuration bind mounts into containers are read-only (`:ro`). Only data volumes (journal, OpenSearch data, MongoDB data) are read-write.

______________________________________________________________________

## 13. Known Limitations & Future Improvements

| # | Limitation | Impact | Mitigation / Future Path |
| --- | ------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| L1 | OpenSearch single-node, no HA | Cluster unavailable during node restart or failure | Acceptable for a log server; add a second node if uptime SLA requires it |
| L2 | Snapshot scope limited to last 7 days | No snapshot-based recovery for older indices | Requires explicit sign-off; consider resizing vDisk 4 to extend scope |
| L3 | Commvault RTO figures are estimates | Actual restore time unknown until tested | Run full VM restore test and record measured RTO |
| L4 | Teams webhook still partly on classic O365 | Delivery model in flux during Power Automate migration | Complete migration — tracked in doc 06 |
| L5 | `docker` group membership for svc-logserver | Root-equivalent access via the service account | Documented and accepted; revisit if a less-privileged deploy path becomes available |

______________________________________________________________________
