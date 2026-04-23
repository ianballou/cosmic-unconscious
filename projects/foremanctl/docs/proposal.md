# foreman-maintain to foremanctl: Migration Proposal

## Overview

This document covers the migration of foreman-maintain functionality into foremanctl. For each piece of existing functionality, it answers three questions:

1. Do we still need it in a containerized world?
2. If yes, where is it tracked?
3. How big is it?

## Architecture Comparison

| Aspect | foreman-maintain | foremanctl |
|--------|-----------------|------------|
| Language | Ruby (CLI via Clamp gem) | Python/Ansible (CLI via Obsah framework) |
| Extension model | Ruby classes: Check, Procedure, Scenario, Feature | Ansible roles + playbooks, registered via metadata.obsah.yaml |
| Command dispatch | Clamp subcommands to Scenarios to Steps (Checks/Procedures) | Obsah to argparse subcommands to Ansible playbooks |
| Feature detection | Runtime Ruby class introspection | Static features.yaml registry + Ansible facts |
| Config | /etc/foreman-maintain/foreman_maintain.yml | Persisted params in /var/lib/foremanctl/parameters.yaml |

### foremanctl Containerized Deployment Model

All Foreman services run as podman quadlet containers managed via systemd:

- **Containers**: foreman, dynflow-sidekiq (x3: orchestrator, worker, worker-hosts-queue), candlepin, pulp-api, pulp-content, pulp-worker (xN), redis, postgresql, foreman-proxy
- **Host RPMs**: podman, httpd, mod_ssl, hammer-cli, python3 deps, bash-completion
- **Systemd target**: `foreman.target` groups all container services; all containers have `PartOf=foreman.target`
- **Data volumes**: PostgreSQL at `/var/lib/pgsql/data` (bind mount), Pulp at `/var/lib/pulp` (bind mount), Redis at `/var/lib/redis`
- **Secrets**: Managed via `podman secret` (DB passwords, certs, config files mounted into containers)
- **Recurring tasks**: Systemd timers running one-shot containers (`foreman-recurring@{hourly,daily,weekly,monthly}`) -- replaces crond
- **No foreman-installer**: Configuration is Ansible-driven
- **External DB**: Supported via CLI parameters

## Design Principles

1. **User-first**: Do not port foreman-maintain commands blindly. Rethink what commands are needed from the user's perspective, not from the existing implementation.
2. **Ansible-native**: Leverage Ansible's strengths -- roles, playbooks, modules, facts, handlers. foreman-maintain reimplemented many things that Ansible already handles natively (service management, package operations, file operations, DB queries).
3. **Ansible-first, Python as escape hatch**: Write roles and playbooks using Ansible primitives. Only drop to Python (filters, modules, callback plugins) when Ansible gets too complex.
4. **Procedural playbooks**: Use Ansible's natural procedural flow. A playbook composing roles is a scenario -- do not recreate the Ruby class hierarchy.

---

## Command Decisions

### Commands to Keep

| Command | Tracked | Size | Notes |
|---------|---------|------|-------|
| upgrade | SAT-39696 | Epic (in progress) | Upgrade workflow must stop recurring systemd timers (`foreman-recurring@*.timer`) before upgrading and re-enable after. These replace crond from foreman-maintain's upgrade flow. |
| update | SAT-39697 | Epic (in progress) | |
| health | Needs ticket | Epic | Individual checks need per-check evaluation. See Health Checks section below. |
| service | Needs ticket | Story | Users still need service lifecycle management. Implementation shifts to systemd targets and container operations. Ansible has strong systemd/service primitives. |
| backup | Needs ticket | Epic | What to back up changes significantly: container volumes, podman secrets, DB dumps from containerized PostgreSQL, config files, certificates. Largest untracked work area. |
| restore | Needs ticket | Epic | Equally complex as backup in reverse. Must handle DB restoration into containers, config/secret restoration, service orchestration. |
| report | Needs ticket | Epic | 36 report definitions in foreman-maintain. Each queries Foreman API or DB. Need to evaluate which carry over. |
| maintenance-mode | Needs ticket (pending decision) | Story | Blocks external access (port 443 via firewall), stops timers, disables sync plans. Needs team discussion on whether this model applies to containerized upgrades. Implementation changes: systemd timers replace crond. |

### Commands to Drop

| Command | Rationale |
|---------|-----------|
| packages | foreman-maintain protected dozens of RPMs via foreman-protector DNF plugin. foremanctl installs very few host RPMs. Users can manage these directly with dnf. Upgrade/update workflows handle keeping the system current. |

### Commands Deferred

| Command | Rationale |
|---------|-----------|
| self-upgrade | Despite the name, this is a self-update -- it updates the tool's own RPM to the latest build within the same version line, not a major version jump. For foremanctl this is just `dnf upgrade foremanctl`. Do not build a dedicated command unless foremanctl's self-update requires more steps than a simple RPM update. |
| advanced | Dev/debug escape hatch to run individual procedures by label/tag. Since foremanctl is Ansible-based, developers can run individual roles/playbooks directly. Do not add unless someone identifies a need beyond raw Ansible calls. |

### Commands Reworked

| Command | Rationale |
|---------|-----------|
| plugin (purge-puppet) | SAT-40445 (in progress). The capability to remove a feature/plugin should exist but under feature management (e.g., `foremanctl deploy --remove-feature puppet`), not a separate `plugin` namespace. |

---

## Health Checks

### Already Implemented in foremanctl

| Check | What it does |
|-------|-------------|
| check_features | Validates requested features exist in features.yaml |
| check_hostname | Validates FQDN: not localhost, has dot, no underscores, lowercase |
| check_database_connection | Pings Foreman/Candlepin/Pulp databases (external DB mode only) |
| check_system_requirements | Validates CPU/RAM against tuning profile thresholds |
| check_subuid_subgid | Validates /etc/subuid and /etc/subgid entries for container user namespaces (exists but not wired into checks playbook) |
| certificate_checks | Validates certificate/key/CA using foreman-certificate-check script (runs during deploy, not in checks playbook) |

### Checks to Keep

#### System / Environment

| Check | What it does | Notes |
|-------|-------------|-------|
| check_tmout | Checks if TMOUT shell env var is set, which can kill long-running operations | Simple assert on env var |
| env_proxy | Checks if HTTP_PROXY/HTTPS_PROXY env vars are set | Affects podman pulls, container networking, Ansible |
| check_ipv6_disable | Checks if ipv6.disable=1 is in kernel boot params | Kernel-level issue affecting container networking |

#### Disk

| Check | What it does | Notes |
|-------|-------------|-------|
| disk/available_space | Asserts root partition has at least 4GB free | Containers need disk space for images, volumes, operations |
| disk/performance | Runs fio benchmarks, warns if read speed below 60 MB/sec | Paths need updating to volume mount points (/var/lib/pgsql/data, /var/lib/pulp) |

#### Database

| Check | What it does | Notes |
|-------|-------------|-------|
| foreman/db_up | Pings Foreman PostgreSQL database | Extend existing check_database_connection to cover local (containerized) DB too |
| candlepin/db_up | Pings Candlepin PostgreSQL database | Same as above |
| pulpcore/db_up | Pings Pulpcore PostgreSQL database | Same as above |
| foreman/db_index | Runs PostgreSQL amcheck on Foreman DB indexes | Can run via podman exec or direct connection |
| candlepin/db_index | Runs PostgreSQL amcheck on Candlepin DB indexes | Same |
| pulpcore/db_index | Runs PostgreSQL amcheck on Pulpcore DB indexes | Same |
| validate_external_db_version | Checks external PostgreSQL is at least version 13 | foremanctl supports external databases |
| check_external_db_evr_permissions | Checks evr extension ownership in external DB | External DB + Katello only |

#### Foreman Application

| Check | What it does | Notes |
|-------|-------------|-------|
| foreman/facts_names | Warns if any host has more than 10,000 fact values | DB query, deployment-model independent |
| foreman/check_corrupted_roles | Finds filters with permissions spanning multiple resource types | DB query |
| foreman/check_duplicate_permissions | Finds duplicate permission entries | DB query |
| server_ping | Calls /api/v2/ping to verify all backend services are healthy end-to-end | foremanctl deploy already has this logic inline. Extract into a reusable role that both deploy and checks can include. |
| services_up | Checks all managed services are running | Rethink for containers: check systemd service status for all quadlet containers and foreman.target |

#### Tasks

| Check | What it does | Notes |
|-------|-------------|-------|
| foreman_tasks/not_paused | Checks for paused Foreman tasks | Investigate using Foreman Ansible Modules (theforeman.foreman) for task queries -- need to verify |
| foreman_tasks/not_running | Checks for running tasks before upgrade, can wait for completion | Same -- investigate Foreman Ansible Modules |
| foreman_tasks/invalid/check_old | Finds tasks older than 30 days in paused/stopped state | Same |
| foreman_tasks/invalid/check_pending_state | Finds tasks stuck in pending state | Same |
| foreman_tasks/invalid/check_planning_state | Finds tasks stuck in planning state | Same |
| pulpcore/no_running_tasks | Checks for active Pulpcore tasks | Can query via Pulp API |

#### Container / Registry

| Check | What it does | Notes |
|-------|-------------|-------|
| container/podman_login | Checks podman is logged into registry.redhat.io | Directly relevant -- foremanctl pulls all service images from registries |

#### Plugin-specific

| Check | What it does | Notes |
|-------|-------------|-------|
| foreman_openscap/invalid_report_associations | Finds OpenSCAP reports with broken associations | OpenSCAP is a supported plugin. DB query. |
| foreman_proxy/check_tftp_storage | Cleans old kernel/initramfs files from TFTP boot dir | TFTP is a major provisioning component. Implementation may change depending on host vs container. |
| foreman_proxy/verify_dhcp_config_syntax | Validates ISC DHCP config syntax | DHCP is a major provisioning component. Implementation depends on config location. |
| puppet/verify_no_empty_cacert_requests | Checks for empty Puppet CA cert request files | Puppet is BYOP (Bring Your Own Puppet). Conditional on puppet integration being detected. |
| foreman/check_puppet_capsules | Finds Smart Proxies with Puppet feature | BYOP. Conditional on puppet integration. |

#### Maintenance Mode

| Check | What it does | Notes |
|-------|-------------|-------|
| maintenance_mode/check_consistency | Verifies all maintenance mode components are in consistent state | Depends on maintenance-mode command decision. foremanctl uses systemd timers instead of crond. Important: timers must be stopped during upgrades regardless of whether maintenance mode as a command survives. |

#### Backup / Restore

| Check | What it does | Notes |
|-------|-------------|-------|
| restore/validate_hostname | Checks backup hostname matches current system | Deployment-model independent |
| restore/validate_interfaces | Checks network interfaces match backup expectations | Deployment-model independent |

### Downstream-only Checks (Satellite)

| Check | What it does | Notes |
|-------|-------------|-------|
| check_subscription_manager_release | Checks if RHSM release is pinned to a minor version | Host OS version matters even for container deployments |
| system_registration | Checks if system is self-registered to its own Satellite | Still a problematic configuration |
| iop_advisor/db_up | Pings IoP Advisor database | Should be parameterized as one check role, not 5 copies |
| iop_inventory/db_up | Pings IoP Inventory database | Same |
| iop_remediations/db_up | Pings IoP Remediations database | Same |
| iop_vmaas/db_up | Pings IoP Vmaas database | Same |
| iop_vulnerability/db_up | Pings IoP Vulnerability database | Same |
| repositories/check_non_rh_repository | Checks if EPEL or non-RH repos are enabled | Reduced importance with fewer host RPMs |
| repositories/check_upstream_repository | Checks if upstream Foreman repos are enabled on Satellite | Would cause version conflicts |
| repositories/validate | Validates required RHSM repos are available | Needed to update foremanctl/hammer RPMs |
| non_rh_packages | Lists non-Red Hat RPMs | Reduced importance with fewer host RPMs |

### Checks to Rethink

| Check | What it does | Blocker / Question |
|-------|-------------|-------------------|
| disk/available_space_candlepin | Checks /var/lib/candlepin usage below 90% | No /var/lib/candlepin on host in containerized model. Candlepin data lives in PostgreSQL. Consolidate into a general "check volume mount disk usage" check covering /var/lib/pgsql/data, /var/lib/pulp, /var/lib/redis. |
| disk/postgresql_mountpoint | Checks /var/lib/pgsql/data is on same device as /var/lib/pgsql | May still matter for PG major version upgrades. Need to investigate how foremanctl handles PG major version migration before deciding. |
| check_hotfix_installed | Searches for HOTFIX RPMs and modified files in installed packages | Current implementation (scanning host RPMs) does not apply to containers. However, hotfixes will likely still be delivered in some form. Blocked on the general hotfix delivery design for containerized Foreman. |
| check_sha1_certificate_authority | Checks if server CA cert chain contains SHA-1 signatures | Likely unnecessary -- containerized Foreman requires RHEL 9+ where SHA-1 is already restricted. Users should have already migrated. Edge cases with custom CA chains may exist. Low priority. |
| backup/certs_tar_exist | Validates required certs tar exists before backup | Certificate storage changes with containers (podman secrets). Part of backup Epic design. |
| restore/validate_backup | Validates backup directory contains required files | Backup format will be different for containers. Part of restore Epic design. |
| restore/validate_postgresql_dump_permissions | Checks postgres user can read dump files | DB restoration may work differently with containerized PostgreSQL. Permission model changes. |

### Checks to Drop

| Check | What it does | Rationale |
|-------|-------------|-----------|
| root_user | Asserts running as root | Ansible handles privilege escalation via become. Add back if needed. |
| validate_dnf_config | Checks for exclude directive in /etc/dnf/dnf.conf | Extremely low risk with so few host packages. Not worth a dedicated check. |

### New Checks to Consider

| Check | What it would do |
|-------|-----------------|
| container_health | Check that all containers are healthy/running via podman or systemd service status. Container-aware replacement for services_up. |

---

## Cross-cutting Concerns

### Feature Detection

foreman-maintain uses runtime Ruby class introspection to detect what is installed. foremanctl uses a static `features.yaml` registry plus Ansible facts. Checks and procedures need to know what is deployed to run conditionally (e.g., skip Katello checks if Katello is not enabled). Ansible facts plus features.yaml should cover most cases.

### Interactive Prompts

foreman-maintain supports `--assumeyes`, confirmation dialogs, and decision prompts. Ansible is non-interactive by default. Some operations (destructive backup, restore) benefit from confirmation. Need to decide on approach: CLI flag, Ansible pause module, or Obsah-level parameter. Needs ticket.

### Error Handling

foreman-maintain's runner tracks step success/failure, offers next steps, and supports whitelisting failed checks. Ansible has `block/rescue/always`, `--force-handlers`, and the foremanctl callback plugin for output. Complex workflows (upgrade, backup) need graceful failure handling. This is part of each Epic's implementation.

### Foreman Ansible Modules

The `theforeman.foreman` Ansible collection may be usable for task state queries (checking paused/running/pending tasks) instead of direct DB queries. This needs investigation and verification.

---

## Summary Table

| Functionality | Need it? | Tracked | Size |
|---------------|----------|---------|------|
| upgrade | Yes | SAT-39696 | Epic (in progress) |
| update | Yes | SAT-39697 | Epic (in progress) |
| health checks | Yes | Needs ticket | Epic |
| service management | Yes | Needs ticket | Story |
| backup | Yes | Needs ticket | Epic |
| restore | Yes | Needs ticket | Epic |
| maintenance-mode | Pending discussion | Needs ticket | Story |
| report | Yes | Needs ticket | Epic |
| packages | No | N/A | -- |
| self-upgrade | Not yet | N/A | -- |
| advanced | Not yet | N/A | -- |
| plugin/puppet purge | Yes | SAT-40445 | Story (in progress) |
| feature detection | Yes | Implicit | Story |
| interactive prompts | Pending decision | Needs ticket | Story |
