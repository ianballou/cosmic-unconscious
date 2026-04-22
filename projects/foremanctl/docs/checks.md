# Health Checks: Keep / Drop / Rethink

Evaluation of every foreman-maintain health check for containerized foremanctl.

## Architecture Context for Decisions

In foremanctl's containerized model:
- **Containers**: foreman, dynflow-sidekiq (×3), candlepin, pulp-api, pulp-content, pulp-worker (×N), redis, postgresql, foreman-proxy — all run as podman quadlet containers managed via systemd
- **Host RPMs**: Only podman, httpd, mod_ssl, hammer-cli, python3 deps, bash-completion
- **Systemd target**: `foreman.target` groups all container services; all containers have `PartOf=foreman.target`
- **Data volumes**: PostgreSQL at `/var/lib/pgsql/data` (bind mount), Pulp at `/var/lib/pulp` (bind mount), Redis at `/var/lib/redis`
- **Secrets**: Managed via `podman secret` (DB passwords, certs, config files)
- **Recurring tasks**: Systemd timers running one-shot containers (`foreman-recurring@{hourly,daily,weekly,monthly}`)
- **No cron**: Recurring tasks use systemd timers, not crond
- **No foreman-installer**: Configuration is Ansible-driven, no `foreman-installer` to call
- **No puppet server**: Not a default feature in containerized deployments
- **DHCP/TFTP**: Not currently supported in foremanctl
- **DB access**: Local DB is in a container; external DB also supported. Access via `community.postgresql` Ansible modules or `podman exec`

## Existing foremanctl Checks (already implemented)

| Check | What it does |
|-------|-------------|
| `check_features` | Validates requested features exist in features.yaml |
| `check_hostname` | Validates FQDN: not localhost, has dot, no underscores, lowercase |
| `check_database_connection` | Pings Foreman/Candlepin/Pulp databases (external DB mode only) |
| `check_system_requirements` | Validates CPU/RAM against tuning profile thresholds |
| `check_subuid_subgid` | Validates /etc/subuid and /etc/subgid entries for container user namespaces (not wired into checks playbook) |
| `certificate_checks` | Validates certificate/key/CA using foreman-certificate-check script (runs during deploy, not in checks playbook) |

---

## System / Environment Checks

### root_user — DROP
**What it does**: Asserts running as root.
**Decision**: Ansible handles privilege escalation via `become`. foremanctl/obsah already needs root. Add back if a specific need arises.

### check_tmout — KEEP
**What it does**: Checks if `TMOUT` shell env var is set, which can kill long-running operations.
**Decision**: Still dangerous in container world. Upgrades and backups can take a long time. Simple Ansible check: `assert: ansible_env.TMOUT is not defined or ansible_env.TMOUT == '0'`.

### env_proxy — KEEP
**What it does**: Checks if HTTP_PROXY/HTTPS_PROXY env vars are set.
**Decision**: Proxy env vars affect podman image pulls, container networking, and Ansible operations. Still relevant.

### check_ipv6_disable — KEEP
**What it does**: Checks if `ipv6.disable=1` is in kernel boot params.
**Decision**: Kernel-level issue that affects container networking too. Simple check against `/proc/cmdline`.

### check_subscription_manager_release — DOWNSTREAM ONLY
**What it does**: Checks if RHSM release is pinned to a minor version.
**Decision**: Downstream (Satellite) only. Still relevant — host OS version matters even for container deployments. Keep for downstream.

### system_registration — DOWNSTREAM ONLY
**What it does**: Checks if system is self-registered to its own Satellite.
**Decision**: Downstream only. Still a problematic configuration. Keep for downstream.

---

## Disk Checks

### disk/available_space — KEEP
**What it does**: Asserts root partition has ≥4GB free.
**Decision**: Containers need disk space for images, volumes, and operations. May want to also check specific mount points where volumes live.

### disk/available_space_candlepin — RETHINK
**What it does**: Checks /var/lib/candlepin usage < 90%.
**Decision**: In containerized foremanctl, Candlepin logs go to `/var/log/candlepin` (bind mount) but there's no `/var/lib/candlepin` on the host. Candlepin data lives in PostgreSQL. This specific check is **irrelevant** but checking disk usage on key mount points (DB data, Pulp data) is still valid. Consolidate into a general "check volume mount disk usage" check.

### disk/performance — KEEP (rethink paths)
**What it does**: Runs `fio` benchmarks, warns if <60 MB/sec.
**Decision**: Disk I/O affects containerized services equally. Paths need updating: check `/var/lib/pgsql/data` (PostgreSQL volume) and `/var/lib/pulp` (Pulp volume).

### disk/postgresql_mountpoint — DROP
**What it does**: Checks /var/lib/pgsql/data is same device as /var/lib/pgsql.
**Decision**: This checked for PostgreSQL RPM upgrade breakage from split mountpoints. PostgreSQL runs in a container now — the volume is a bind mount. This specific failure mode doesn't apply.

---

## Database Checks

### foreman/db_up, candlepin/db_up, pulpcore/db_up — KEEP (already exists)
**What they do**: Ping each database to verify it's responding.
**Decision**: foremanctl already has `check_database_connection` which does this for external DBs. Extend to also work for local (containerized) PostgreSQL — possibly via `podman exec postgresql pg_isready` or connecting from the host since it's on host networking.

### iop_*/db_up (5 checks) — DOWNSTREAM ONLY
**What they do**: Ping IoP databases (Advisor, Inventory, Remediations, Vmaas, Vulnerability).
**Decision**: Downstream (Satellite with IoP) only. If IoP is part of containerized Satellite, these carry over. Should be parameterized — one check role that loops over configured databases rather than 5 copies.

### foreman/db_index, candlepin/db_index, pulpcore/db_index — KEEP
**What they do**: Run PostgreSQL `amcheck` to verify B-tree index integrity.
**Decision**: Data integrity matters regardless of deployment model. Can run via `podman exec` or direct connection. Could be a single parameterized check role.

### foreman/validate_external_db_version — KEEP
**What it does**: Checks external PostgreSQL is at least version 13.
**Decision**: foremanctl supports external databases. Version requirements may change but the check pattern is valid.

### foreman/check_external_db_evr_permissions — KEEP
**What it does**: Checks `evr` extension ownership in external DB.
**Decision**: Still relevant for external DB + Katello configurations.

---

## Foreman Application Checks

### foreman/facts_names — KEEP
**What it does**: Warns if any host has >10,000 fact values (causes slow processing).
**Decision**: Application data issue — deployment model doesn't matter. Requires DB query (can run via container or direct connection).

### foreman/check_corrupted_roles — KEEP
**What it does**: Finds filters with permissions spanning multiple resource types.
**Decision**: Database content issue. Still valid. Requires DB query.

### foreman/check_duplicate_permissions — KEEP
**What it does**: Finds duplicate permission entries in DB.
**Decision**: Database content issue. Still valid. Requires DB query.

### foreman/check_tuning_requirements — KEEP (already exists)
**What it does**: Checks CPU/RAM match tuning profile.
**Decision**: foremanctl already has `check_system_requirements` doing exactly this with the same tuning profiles. Already covered.

### server_ping — KEEP
**What it does**: Calls `/api/v2/ping` to verify all backend services (candlepin, pulp, foreman_tasks, etc.) are healthy — not just running, but actually working end-to-end.
**Decision**: Keep as a standalone health check role. The deploy playbook already has this logic inline (waits for `/api/v2/ping` 200 + checks foreman_tasks status). Extract that into a reusable role that both `deploy` and `checks` can include.

### services_up — KEEP (rethink implementation)
**What it does**: Checks all managed systemd services are running.
**Decision**: In containerized world, this means checking container status via systemd (`systemctl is-active foreman candlepin redis postgresql pulp-api pulp-content pulp-worker@* foreman-proxy`). All services are `PartOf=foreman.target`, so could also check target status.

---

## Task Checks

### foreman_tasks/not_paused — KEEP
**What it does**: Checks for paused Foreman tasks.
**Decision**: Application-level concern. Can check via `/api/v2/ping` (which reports foreman_tasks status) or direct DB/API query.
**Note**: Investigate using Foreman Ansible Modules (`theforeman.foreman`) for task queries — need to verify if they expose task state.

### foreman_tasks/not_running — KEEP
**What it does**: Checks for running tasks before upgrade. Can wait for completion.
**Decision**: Critical pre-upgrade check — must not upgrade while tasks are running.
**Note**: Investigate using Foreman Ansible Modules for task queries.

### foreman_tasks/invalid/check_old — KEEP
**What it does**: Finds tasks >30 days old in paused/stopped state.
**Decision**: Database hygiene. Still valid.
**Note**: Investigate using Foreman Ansible Modules for task queries.

### foreman_tasks/invalid/check_pending_state — KEEP
**What it does**: Finds tasks stuck in pending state.
**Decision**: Still valid.
**Note**: Investigate using Foreman Ansible Modules for task queries.

### foreman_tasks/invalid/check_planning_state — KEEP
**What it does**: Finds tasks stuck in planning state.
**Decision**: Still valid.
**Note**: Investigate using Foreman Ansible Modules for task queries.

### pulpcore/no_running_tasks — KEEP
**What it does**: Checks for active Pulpcore tasks.
**Decision**: Critical pre-upgrade check. Can query via Pulp API.

---

## Certificate Checks

### check_sha1_certificate_authority — KEEP (partially exists)
**What it does**: Checks if server CA cert is SHA-1 signed.
**Decision**: Certificate issues are deployment-model independent. foremanctl already has `certificate_checks` role with `foreman-certificate-check` script. Verify SHA-1 detection is covered or add it.

---

## Repository / Package Checks

### repositories/check_non_rh_repository — DOWNSTREAM ONLY, reduced importance
**What it does**: Checks if EPEL or non-RH repos are enabled.
**Decision**: With fewer host RPMs, the risk is reduced. But could still interfere with foremanctl/hammer updates. Keep for downstream, lower priority.

### repositories/check_upstream_repository — DOWNSTREAM ONLY
**What it does**: Checks if upstream Foreman repos are enabled on Satellite.
**Decision**: Would cause version conflicts. Keep for downstream.

### repositories/validate — DOWNSTREAM ONLY
**What it does**: Validates required RHSM repos are available.
**Decision**: Needed to update foremanctl/hammer RPMs. Keep for downstream.

### check_hotfix_installed — DROP
**What it does**: Searches for HOTFIX RPMs and modified Ruby/Python/JS files in installed packages.
**Decision**: Application code is in container images now, not in host RPMs. Hotfix RPMs don't apply to containerized services. If someone patches a container image, that's a different detection mechanism entirely.

### non_rh_packages — DOWNSTREAM ONLY, reduced importance
**What it does**: Lists non-Red Hat RPMs.
**Decision**: Fewer host RPMs = fewer to worry about. Low value in container world. Keep for downstream completeness.

### package_manager/dnf/validate_dnf_config — DROP
**What it does**: Checks for `exclude` in `/etc/dnf/dnf.conf`.
**Decision**: DNF config could theoretically block foremanctl/hammer updates, but this is extremely low risk with so few packages. Not worth a dedicated check.

---

## Backup/Restore Checks

### backup/certs_tar_exist — RETHINK
**What it does**: Validates required certs tar exists before backup.
**Decision**: Certificates are managed differently in foremanctl (podman secrets, Ansible-managed files). The check concept is valid but the specifics change entirely. Part of backup Epic design.

### restore/validate_backup — RETHINK
**What it does**: Validates backup directory contains all required files.
**Decision**: Still needed but backup format will be different for containers. Part of restore Epic design.

### restore/validate_hostname — KEEP
**What it does**: Checks backup hostname matches current system.
**Decision**: Still relevant regardless of deployment model.

### restore/validate_interfaces — KEEP
**What it does**: Checks network interfaces match backup expectations.
**Decision**: Still relevant.

### restore/validate_postgresql_dump_permissions — RETHINK
**What it does**: Checks postgres user can read dump files.
**Decision**: DB restoration may work differently with containerized PostgreSQL (e.g., `podman exec` to restore). The permission model changes.

---

## Plugin-specific Checks

### foreman_openscap/invalid_report_associations — KEEP
**What it does**: Finds OpenSCAP reports with broken associations.
**Decision**: Application data issue. OpenSCAP is a supported plugin. DB query check.

### foreman_proxy/check_tftp_storage — KEEP (rethink implementation)
**What it does**: Cleans old kernel/initramfs files from TFTP boot dir.
**Decision**: TFTP is a major provisioning component and will be supported. Implementation may change depending on whether TFTP runs on host or in container.

### foreman_proxy/verify_dhcp_config_syntax — KEEP (rethink implementation)
**What it does**: Validates ISC DHCP config.
**Decision**: DHCP is a major provisioning component and will be supported. Implementation depends on where DHCP config lives in containerized model.

### puppet/verify_no_empty_cacert_requests — KEEP (BYOP context)
**What it does**: Checks for empty Puppet CA cert request files.
**Decision**: Puppet is BYOP (Bring Your Own Puppet) — not deployed by foremanctl, but Foreman still integrates with it. This check is only relevant if the user has Puppet set up. Should be conditional on puppet feature being detected.

### foreman/check_puppet_capsules — KEEP (BYOP context)
**What it does**: Finds Smart Proxies with Puppet feature.
**Decision**: Relevant for environments using BYOP. Conditional on puppet integration being present.

---

## Container-specific Checks (from foreman-maintain)

### container/podman_login — KEEP
**What it does**: Checks podman is logged into registry.redhat.io.
**Decision**: Directly relevant — foremanctl pulls all service images from registries. May already be handled in the deploy flow but should be a standalone health check too.

---

## Maintenance Mode Check

### maintenance_mode/check_consistency — KEEP (if maintenance mode stays)
**What it does**: Verifies all maintenance mode components are in consistent state.
**Decision**: Depends on maintenance-mode command decision (pending team discussion). Note: foremanctl uses systemd timers (`foreman-recurring@{hourly,daily,weekly,monthly}.timer`) instead of crond, so the implementation changes — stop/start those timers instead of crond.
**Important**: These systemd timers must be stopped during upgrades regardless of whether maintenance mode as a command survives. The upgrade workflow needs to stop recurring timers before upgrading and re-enable them after.

---

## New Checks to Consider

Checks that don't exist in foreman-maintain but are relevant for containerized Foreman:

### container_health — NEW
Check that all containers are healthy/running via `podman ps` or systemd service status. Replaces the RPM-era `services_up` with container-aware status.

### container_image_versions — NEW
Verify all running containers are using the expected image versions. Catch drift where some containers were updated but others weren't.

### podman_storage — NEW
Check podman storage usage and available space. Container images and layers consume disk.

### volume_permissions — NEW
Verify that host mount points (`/var/lib/pgsql/data`, `/var/lib/pulp`, `/var/lib/redis`) have correct ownership and permissions for their containers.

### systemd_target_status — NEW
Check that `foreman.target` is active and all `PartOf` services are in expected state. More holistic than checking individual services.

### secrets_exist — NEW
Verify that all required podman secrets exist (DB passwords, certificates, config files). Missing secrets = containers won't start.

### recurring_timers — NEW
Check that systemd timers for recurring Foreman tasks (hourly, daily, weekly, monthly) are active and enabled.

---

## Summary

| Decision | Count | Checks |
|----------|-------|--------|
| **KEEP** | ~28 | check_tmout, env_proxy, check_ipv6_disable, disk/available_space, disk/performance, db_up (×3), db_index (×3), validate_external_db_version, check_external_db_evr_permissions, facts_names, check_corrupted_roles, check_duplicate_permissions, server_ping, services_up, foreman_tasks (×5), pulpcore/no_running_tasks, check_sha1_ca, container/podman_login, restore/validate_hostname, restore/validate_interfaces, foreman_openscap, check_tftp_storage, verify_dhcp_config, puppet checks (×2 BYOP conditional) |
| **RETHINK** | ~4 | disk/available_space_candlepin → general volume usage, backup/certs_tar_exist, restore/validate_backup, restore/validate_postgresql_dump_permissions |
| **DOWNSTREAM ONLY** | ~8 | check_subscription_manager_release, system_registration, iop_*/db_up (×5), repositories/* (×3), non_rh_packages |
| **DROP** | ~3 | disk/postgresql_mountpoint, check_hotfix_installed, validate_dnf_config |
| **ALREADY EXISTS** | ~4 | check_tuning_requirements, check_database_connection, check_hostname, certificate_checks |
| **NEW** | ~7 | container_health, container_image_versions, podman_storage, volume_permissions, systemd_target_status, secrets_exist, recurring_timers |
