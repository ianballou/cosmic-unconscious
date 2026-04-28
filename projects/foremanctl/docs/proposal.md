# foreman-maintain to foremanctl: Migration Proposal

## Overview

This document covers the migration of foreman-maintain functionality into foremanctl. For each piece of existing functionality, it answers three questions:

1. Do we still need it in a containerized world?
2. If yes, where is it tracked?
3. How large is the effort?

This document also provides guidance for how to architect the functionality that needs to be ported over. With this document and its stories, there should be enough information to begin implementing foreman-maintain functionality in foremanctl.

The document has the following flow:

1. Information about foreman-maintain and foremanctl today
2. Which foreman-maintain commands to keep, which to drop, and which are questionable
3. Which foreman-maintain checks to keep, which to drop, and which are questionable
4. General foreman-maintain functionality to keep (to be added)
5. List of tickets needed with descriptions & high-level design proposals

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

## foreman-maintain Commands

### Commands to Keep

| Command | Tracked | Size | Notes |
|---------|---------|------|-------|
| upgrade | SAT-39696 | Epic (in progress) | In progress. |
| update | SAT-39697 | Epic (in progress) | In progress. |
| health | Needs ticket | Story within a small Epic combined with service | New `foremanctl health` command for runtime health checks. |
| backup | Needs ticket | Epic (combined with restore) | Largest untracked area. What to back up may change significantly. |
| restore | Needs ticket | Epic (combined with backup) | To be implemented in the backup epic. |
| maintenance-mode | Needs ticket | Story (within upgrade Epic) | Link as related to `update` & `backup` Epics. Blocks port 443, stops timers, disables sync plans. |

### Commands to Drop

| Command | Rationale |
|---------|-----------|
| service | With foreman.target, this becomes less necessary. Introduce only as necessary. |
| packages | Very few host RPMs in containerized model. Can users just manage RPMs with dnf? Or do we still need gating with dnf filtering? |
| advanced | Developers can run Ansible roles/playbooks directly. Don't build unless a need (e.g. support?) is identified. |

### Commands to Rethink

| Command | Rationale |
|---------|-----------|
| self-upgrade | Enables newer maintenance repository and updates foreman-maintain today. The upgrade process will define if this is still necessary. Track in SAT-39696. |

### Commands to Move

| Command | Rationale |
|---------|-----------|
| report | SatStats reporting should ideally move to another tool since it's unrelated to configuring Foreman. This way it could remain Ruby too. |

### Commands Reworked

| Command | Rationale |
|---------|-----------|
| plugin (purge-puppet) | SAT-40445. Rework is in-progress. `plugin` can likely go away, but removing Puppet is to-be-determined. Story (within the Puppet epic). |

---

## Orchestration

foreman-maintain scenarios run a number of tasks sequentially. If one task is failing, users have the ability to skip it via `--whitelist`. With foremanctl, this functionality may be missed. If it is, we can consider implementing skips via Ansible `--skip-tags`.

---

## Checks

### Already Implemented in foremanctl

| Check | What it does |
|-------|-------------|
| check_features | Validates requested features exist in features.yaml |
| check_hostname | Validates FQDN: not localhost, has dot, no underscores, lowercase |
| check_database_connection | Pings Foreman/Candlepin/Pulp databases (external DB mode only) |
| check_system_requirements | Validates CPU/RAM against tuning profile thresholds |
| check_subuid_subgid | Validates /etc/subuid and /etc/subgid entries for container user namespaces (role exists but is not used) |
| certificate_checks | Validates certificate/key/CA using foreman-certificate-check script (runs during deploy, not in checks playbook). Centralize to checks playbook? |

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
| disk/performance | Runs fio benchmarks, warns if read speed below 60 MB/sec | Run fio benchmarks on Pulp and Foreman DB data |

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

#### Foreman Application

| Check | What it does | Notes |
|-------|-------------|-------|
| foreman/facts_names | Warns if any host has more than 10,000 fact values | DB query, deployment-model independent |
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
| foreman_proxy/check_tftp_storage | Cleans old kernel/initramfs files from TFTP boot dir | TFTP is a major provisioning component. Implementation may change depending on host vs container. |
| foreman_proxy/verify_dhcp_config_syntax | Validates ISC DHCP config syntax | DHCP is a major provisioning component. Implementation depends on config location. |
| puppet/verify_no_empty_cacert_requests | Checks for empty Puppet CA cert request files | Puppet is BYOP (Bring Your Own Puppet). Conditional on puppet integration being detected. |
| foreman/check_puppet_capsules | Finds Smart Proxies with Puppet feature | BYOP. Conditional on puppet integration. |

#### Backup / Restore

| Check | What it does | Notes |
|-------|-------------|-------|
| restore/validate_hostname | Checks backup hostname matches current system | Deployment-model independent |
| restore/validate_interfaces | Checks network interfaces match backup expectations | Deployment-model independent |

### Checks to Keep (Satellite only)

| Check | What it does | Notes |
|-------|-------------|-------|
| check_subscription_manager_release | Checks if RHSM release is pinned to a minor version | Host OS version matters even for container deployments |
| system_registration | Checks if system is self-registered to its own Satellite | Still a problematic configuration |
| iop_*/db_up (x5) | Pings IoP databases (Advisor, Inventory, Remediations, Vmaas, Vulnerability) | Should be parameterized as one check role, not 5 copies |
| non_rh_packages | Lists non-Red Hat RPMs | Reduced importance with fewer host RPMs |

### Checks to Rethink

| Check | What it does | Blocker / Question |
|-------|-------------|-------------------|
| disk/available_space_candlepin | Checks /var/lib/candlepin usage below 90% | No /var/lib/candlepin on host in containerized model. Mount CP data to /var/lib? |
| disk/postgresql_mountpoint | Checks /var/lib/pgsql/data is on same device as /var/lib/pgsql | /var/lib/pgsql/data seems to be outside of the container, where /var/lib/pgsql/16/ is only within the container. |
| foreman/check_corrupted_roles | Finds filters with permissions spanning multiple resource types | Is this check still necessary? |
| foreman/check_duplicate_permissions | Finds duplicate permission entries | Is this check still necessary? |
| foreman_openscap/invalid_report_associations | Finds OpenSCAP reports with broken associations | OpenSCAP is a supported plugin. DB query. Is this still necessary? |
| maintenance_mode/check_consistency | Verifies all maintenance mode components are in consistent state | Depends on maintenance-mode command design. foremanctl uses systemd timers instead of crond. |
| check_hotfix_installed | Searches for HOTFIX RPMs and modified files in installed packages | Current implementation (scanning host RPMs) does not apply to containers. Blocked on the general hotfix delivery design for containerized Foreman. |
| backup/certs_tar_exist | Validates required certs tar exists before backup | Certificate storage changes with containers (podman secrets). Part of backup Epic design. |
| restore/validate_backup | Validates backup directory contains required files | Backup format will be different for containers. Part of restore Epic design. |
| restore/validate_postgresql_dump_permissions | Checks postgres user can read dump files | DB restoration may work differently with containerized PostgreSQL. Permission model changes. |
| repositories/check_non_rh_repository (Satellite) | Checks if EPEL or non-RH repos are enabled | Should we continue being strict about RPM repos? |
| repositories/check_upstream_repository (Satellite) | Checks if upstream Foreman repos are enabled on Satellite | Would cause version conflicts. |
| repositories/validate | Validates required RHSM repos are available | Useful for foremanctl/hammer RPM updates. Make this work for upstream and Satellite? |

### Checks to Drop

| Check | What it does | Rationale |
|-------|-------------|-----------|
| root_user | Asserts running as root | Ansible handles privilege escalation via become. Add back if needed. |
| validate_dnf_config | Checks for exclude directive in /etc/dnf/dnf.conf | Extremely low risk with so few host packages. Not worth a dedicated check. |
| check_sha1_certificate_authority | Checks if server CA cert chain contains SHA-1 signatures | sha1 should likely no longer exist in certificates after the upgrade to RHEL 9. |
| check_external_db_evr_permissions | Checks evr extension ownership in external DB | Was only needed during a past upgrade. |

### New Checks

| Check | What it would do |
|-------|-----------------|
| recurring_timers | Check that systemd timers for recurring Foreman tasks (hourly, daily, weekly, monthly) are active and enabled. |

---

## General foreman-maintain functionality missing from foremanctl

### Feature Detection

foreman-maintain uses runtime Ruby class introspection to detect what is installed. foremanctl uses a static `features.yaml` registry plus Ansible facts. Checks and procedures need to know what is deployed to run conditionally (e.g., skip Katello checks if Katello is not enabled). Ansible facts plus features.yaml may cover most cases.

### Interactive Prompts

foreman-maintain supports `--assumeyes`, confirmation dialogs, and decision prompts. Ansible is non-interactive by default. Some operations (destructive backup, restore) benefit from confirmation. Need to decide on approach.

### Error Handling

foreman-maintain's runner tracks step success/failure, offers next steps, and supports whitelisting failed checks. Ansible has `block/rescue/always`, `--force-handlers`, and the foremanctl callback plugin for output. Complex workflows (upgrade, backup) need graceful failure handling. This is part of each Epic's implementation.

---

## Ticket Proposals

High-level goals and design sketches for each work item that needs a ticket. These are starting points -- each will need detailed design before implementation.

### Checks: Per-feature Conditional Execution

- [x] Idea verified

**Goal**: Checks should run only when relevant. Katello-specific checks should not run if Katello is not enabled. Downstream-only checks should not run on upstream. External DB checks should not run on internal DB deployments.

**What foreman-maintain does**: Each check declares `for_feature :foo` or `confine do feature(:bar) end` in its metadata. At runtime, the framework introspects which features are present and skips checks whose feature requirements are not met. About half of all checks (~25 of ~53) are conditional on a feature being present.

**Proposal**: Each check role gates itself with `when:` conditions on persisted configuration. No framework changes needed -- the existing `execute_check.yml` block/rescue wrapper handles skipped roles as passing checks. Three gating axes, all derived from persisted foremanctl config:

| Axis | Variable | Example condition | Example checks |
|------|----------|-------------------|----------------|
| **Feature** | `enabled_features` | `'katello' in enabled_features` | Katello DB checks, OpenSCAP, sync plans, puppet |
| **Flavor** | `flavor` | `flavor == 'satellite'` | CDN registration, RHSM release pin, non-RH repos, IoP DB checks |
| **Infrastructure** | `database_mode` | `database_mode == 'external'` | External DB version |

This pattern already exists in foremanctl today: `check_database_connection` uses `when: database_mode == 'external'`.

**Prerequisite**: The checks playbook must load `../../vars/flavors/{{ flavor }}.yml` in its `vars_files` so that `flavor_features` resolves and `enabled_features` (defined as `flavor_features + features` in `defaults.yml`) becomes available. This is a one-line addition to `src/playbooks/checks/checks.yaml`.

### Health Command

- [ ] Idea verified

**Goal**: Give users a `foremanctl health` command that checks whether a running Foreman installation is healthy. This is distinct from the existing `foremanctl checks` command, which runs install/deploy preflight validation.

**The problem today**: foremanctl has a single `checks` playbook described as "Run preflight checks before installing Foreman." It validates prerequisites *before* deployment -- hostname, system requirements, DB connectivity, feature validity. There is no command to check the health of an already-running system (are services up? are tasks stuck? is disk filling up?).

foreman-maintain conflates these -- `health check` runs checks tagged `:default`, while upgrade/backup scenarios pull in checks tagged `:pre_upgrade` or `:backup`. foremanctl should not replicate this tagging system.

**Proposal**: A new `foremanctl health` playbook at `src/playbooks/health/health.yaml` that runs health-specific check roles against a running system. The key design decision: **each playbook explicitly lists the check roles it needs**. Check roles are reusable building blocks -- the same role can appear in multiple playbooks. The playbook IS the scenario.

Separation of concerns:

| Playbook | Purpose | Example checks |
|----------|---------|----------------|
| `checks` (existing) | Install/deploy preflight | `check_hostname`, `check_features`, `check_system_requirements`, `check_database_connection` |
| `health` (new) | Runtime health of a running system | `check_server_ping`, `check_services_up`, `check_disk_space`, `check_facts_names`, `check_env_proxy`, `check_recurring_timers` |
| `upgrade` (in progress) | Pre-upgrade validation, inline | `check_no_running_tasks`, `check_disk_space`, `check_tmout`, `check_db_index` |
| `backup` (future) | Pre-backup validation, inline | `check_no_running_tasks`, `check_db_index` |

The health playbook reuses the same `execute_check.yml` block/rescue pattern from the existing checks role, and loads the same vars files (including `flavors/{{ flavor }}.yml` for feature/flavor gating). Its `metadata.obsah.yaml` needs no special parameters -- it runs all applicable health checks, gated by `when:` conditions on each role.

No tagging system. No check registry. Each playbook owns its check list.

### Checks: Missing Implementations

- [ ] Idea verified

**Goal**: Implement the checks identified as "keep" in the Checks section above, plus the new container-specific checks. foremanctl currently has 4 active checks; this work brings it to feature parity with foreman-maintain's health check coverage.

**What foremanctl has today**: 4 checks wired into the checks playbook (`check_features`, `check_hostname`, `check_database_connection`, `check_system_requirements`), plus 2 existing but unused roles (`check_subuid_subgid`, `certificate_checks`).

**Proposal**: Group the checks into implementation batches by category and dependency. Each check is a new Ansible role in `src/roles/check_<name>/` following the existing pattern (`ansible.builtin.assert` or `ansible.builtin.fail` for pass/fail, registered in `src/roles/checks/tasks/main.yml`). Suggested batches:

1. **System/environment** (3 checks: `check_tmout`, `check_env_proxy`, `check_ipv6_disable`) -- simple asserts on env vars and `/proc/cmdline`. No external dependencies.
2. **Disk** (2 checks: `check_disk_space`, `check_disk_performance`) -- `ansible.builtin.assert` on `ansible_mounts` facts for space; shell task running `fio` for performance. Paths target `/var/lib/pgsql/data`, `/var/lib/pulp`.
3. **Database** (extend existing + new: extend `check_database_connection` to local DB, `check_db_index` parameterized across 3 DBs, `check_external_db_version`) -- use `community.postgresql` Ansible modules. The index check can use `amcheck` via `podman exec` for local DB or direct SQL for external.
4. **Application** (3 checks: `check_facts_names`, `check_server_ping`, `check_services_up`) -- DB queries via `community.postgresql.postgresql_query` for facts_names; `ansible.builtin.uri` to `/api/v2/ping` for server_ping (extract from deploy role into reusable role); `ansible.builtin.systemd` facts for services_up.
5. **Tasks** (6 checks: 5 foreman_tasks checks + `check_pulpcore_no_running_tasks`) -- investigate `theforeman.foreman` Ansible collection first; fall back to `ansible.builtin.uri` against Foreman/Pulp APIs or direct DB queries.
6. **Container/registry** (1 check: `check_podman_login`) -- shell task checking `podman login --get-login registry.redhat.io`.
7. **Plugin-specific** (4 checks: tftp, dhcp, puppet x2) -- conditional on features. DB queries or file system checks.
8. **New container-specific** (1 check: `check_recurring_timers`) -- use `systemctl` via shell/command modules.

Wire the 2 existing unused checks (`check_subuid_subgid`, `certificate_checks`) into the checks playbook as part of this work.

### Service Management — DROPPED

**Status**: Dropped. With `foreman.target`, this becomes less necessary. Introduce only as necessary.

**Original goal**: Give users a `foremanctl service` command to start, stop, restart, check status, enable, disable, and list all Foreman services. This is a frequently used operational command.

**What foreman-maintain does**: The `service` command dispatches to scenarios (ServiceStart, ServiceStop, ServiceRestart, ServiceStatus, ServiceList, ServiceEnable, ServiceDisable). Each calls into the `Features::Service` class, which discovers all managed systemd services from registered features, supports `--only` and `--exclude` filters, groups services by priority for ordered start/stop, forks threads for parallel operations within a priority group, and reverses order for stop.

**Proposal**: A new `foremanctl service` playbook at `src/playbooks/service/service.yaml` with a `metadata.obsah.yaml` defining parameters for `action` (start/stop/restart/status/enable/disable/list), `--only`, and `--exclude`. The playbook includes a `service_management` role that:

- Defines the full service list as an Ansible variable (all quadlet container service names + `foreman.target` + recurring timers). This is static and derived from the deployment -- not runtime-discovered like foreman-maintain.
- For start: `systemctl start foreman.target` (pulls in all `PartOf` services). For stop: `systemctl stop foreman.target`. For restart: stop then start. Ansible's `systemd` module handles this natively.
- For status: query `systemctl is-active` for each container service, format output via the callback plugin.
- For list: query `systemctl list-unit-files` filtered to known Foreman services.
- `--only` / `--exclude` filter the service list before operating. Implement as Ansible variable filters.
- Use the `foremanctl_suppress_default_output` tag with the callback plugin for clean status/list output.

The key simplification: foremanctl's service list is static and known at deploy time (no runtime feature detection needed). All services are `PartOf=foreman.target`, so start/stop can operate on the target directly.

### Backup

- [ ] Idea verified

**Goal**: Give users a `foremanctl backup` command to create a complete, restorable backup of a containerized Foreman installation. Support online (services running) and offline (services stopped) strategies.

**What foreman-maintain does**: The backup scenario runs pre-checks (DB index integrity, no running tasks), then: prepares a backup directory, generates metadata (OS version, plugin list, installed packages, hostname), backs up config files (tar of config paths gathered from all features), dumps each database (Foreman, Candlepin, Pulpcore, and IoP DBs if present) via `pg_dump`, backs up Pulp content (`/var/lib/pulp` as tar, optionally skippable), and compresses everything. Offline mode stops services first, starts PostgreSQL for dumps, then restarts. Online mode stops workers to quiesce, uses `--ensure-unchanged` for Pulp data consistency. Supports incremental backups via `.snar` files.

**Proposal**: A new `foremanctl backup` playbook with parameters: `--strategy` (online/offline), `--backup-dir`, `--skip-pulp-content`, `--incremental-dir`. The playbook composes roles:

1. **Pre-checks role**: Run DB index checks, verify no running Foreman/Pulp tasks.
2. **Prepare directory role**: Create backup dir, set permissions.
3. **Metadata role**: Gather and save metadata -- hostname, OS version, enabled features, container image versions (new: replaces RPM list), foremanctl parameters.
4. **Config files role**: Tar relevant config paths. In containerized model this is: `/etc/foreman-proxy/`, httpd configs, certificates, podman secrets export, `parameters.yaml`, `features.yaml`. Each feature's config paths should be defined as variables.
5. **Database dump role**: Parameterized role that loops over configured databases. For local DB: `podman exec postgresql pg_dump` or connect from host (PostgreSQL is on host networking). For external DB: direct `pg_dump` connection. Use `community.postgresql` modules where possible.
6. **Pulp data role**: Tar `/var/lib/pulp` (bind mount on host, so directly accessible). Use Ansible's `archive` module or shell `tar`.
7. **Compress role**: Final compression of the backup directory.

For offline mode: stop `foreman.target`, start only postgresql container for dumps, then restart. For online mode: stop worker containers (dynflow-sidekiq, pulp-worker) during backup, restart after. Ansible's `block/rescue/always` ensures services restart even on failure.

Key differences from foreman-maintain: no `foreman-installer` answers to back up; podman secrets need explicit export; container image versions should be recorded for restore validation; the config file list is smaller and more predictable.

### Restore

- [ ] Idea verified

**Goal**: Give users a `foremanctl restore` command to restore a Foreman installation from a backup created by `foremanctl backup`. To be implemented in the backup epic.

**What foreman-maintain does**: Validates the backup (hostname match, network interfaces, required files present, PostgreSQL dump permissions), confirms with user, installs required packages, restores config files from tar, stops cron/timers, optionally resets installer state, stops all services, drops and re-creates databases, restores each DB dump, extracts Pulp data tar, runs `foreman-installer` to reconfigure, runs upgrade rake tasks, and restarts cron/timers.

**Proposal**: A new `foremanctl restore` playbook with parameters: `--backup-dir`, `--dry-run` (validate only). The playbook composes roles:

1. **Validation role**: Check backup directory contents (expected files exist), hostname matches current system, network interfaces match, backup metadata is readable and compatible.
2. **Confirmation role**: If not `--assumeyes`, pause for user confirmation (Ansible `pause` module or a pre-flight prompt mechanism -- ties into the interactive prompts design decision).
3. **Stop services role**: Stop `foreman.target` and recurring timers.
4. **Restore configs role**: Extract config files tar to `/`, restore podman secrets.
5. **Database restore role**: Parameterized role -- drop databases, restore each dump. For local DB: start postgresql container, use `pg_restore` via `podman exec` or host connection. For external DB: direct connection.
6. **Restore Pulp data role**: Extract Pulp data tar to `/var/lib/pulp`.
7. **Reconfigure role**: Run `foremanctl deploy` (or a subset) to re-apply configuration -- this replaces `foreman-installer` from the old flow. Ensures container definitions, systemd units, and secrets are all consistent with restored config.
8. **Start services role**: Start `foreman.target` and recurring timers, verify via `/api/v2/ping`.

Key differences from foreman-maintain: no `foreman-installer --reset`; reconfiguration is `foremanctl deploy`; database operations go through containers; no RPM package restoration needed (services are container images, not RPMs).

### Maintenance Mode

- [ ] Idea verified

**Goal**: Give users a `foremanctl maintenance-mode` command to block external access and quiesce the system during planned maintenance windows. Operations: start, stop, status.

**What foreman-maintain does**: Start maintenance mode does four things in order: (1) add nftables/iptables rules to block port 443 from external access, (2) stop crond, (3) stop systemd timers, (4) disable Katello sync plans via Hammer CLI. Stop reverses the order. Status checks consistency across all four components and reports which are in/out of expected state, offering remediation if inconsistent.

**Proposal**: A new `foremanctl maintenance-mode` playbook with a parameter for `action` (start/stop/status). The playbook includes a `maintenance_mode` role that:

- **Firewall**: Uses `ansible.builtin.command` to add/remove nftables rules (RHEL 9+ uses nftables by default). Block port 443 to external traffic while allowing localhost. Same `FOREMAN_MAINTAIN_TABLE` / `FOREMAN_MAINTAIN_CHAIN` pattern, or a simplified equivalent.
- **Recurring timers**: Stop/start `foreman-recurring@{hourly,daily,weekly,monthly}.timer` via `ansible.builtin.systemd`. These replace crond from foreman-maintain -- there is no crond in containerized Foreman.
- **Sync plans**: Disable/re-enable active sync plans. foreman-maintain uses Hammer CLI (`hammer sync-plan update --enabled false`). foremanctl could do the same (Hammer is a host RPM) or use the Foreman API directly via `ansible.builtin.uri`. The tricky part is state tracking -- foreman-maintain persists which sync plans it disabled to a storage file so it can re-enable only those. foremanctl should do the same, persisting to a file under `/var/lib/foremanctl/`.
- **Status**: Check all three components (firewall rules present?, timers stopped?, sync plans state file exists?) and report consistency. Use the callback plugin's `foremanctl_suppress_default_output` tag for clean output.

The sync plan disable/enable roles are independently useful for upgrade workflows regardless.

### Report Generation — MOVE TO SEPARATE TOOL

**Status**: SatStats reporting should ideally move to another tool since it's unrelated to configuring Foreman. This way it could remain Ruby too.

**Original goal**: Give users a `foremanctl report` command that generates a usage/inventory report for support cases, pre-upgrade audits, and understanding what is deployed.

**What foreman-maintain does**: Has 36 report definitions (Ruby classes), each collecting data via SQL queries against the Foreman database or system commands. Reports cover: platform usage (users, roles, settings, bookmarks), content metrics (repositories, RPMs, errata, content views, sync plans, activation keys), host metrics (counts, multi-CV hosts, smart proxy assignments), provisioning (compute resources, templates, PXE), smart proxy metrics, networking (IPv4/IPv6 subnets, interfaces), authentication (LDAP, Kerberos, OIDC, PATs), compliance (OpenSCAP), IoP remediations, SELinux status, virt-who, webhooks, and more. Many reports are conditional on features (e.g., Katello content reports only run if Katello is present). Output is a flat key-value data structure collected from all reports.

**Proposal**: A new `foremanctl report` playbook that includes a `report` role. Implementation approach:

- Each report category becomes a tasks file included by the main role (e.g., `tasks/platform.yaml`, `tasks/content.yaml`, `tasks/hosts.yaml`). Feature-conditional reports use `when:` guards.
- SQL queries run via `community.postgresql.postgresql_query` against the Foreman database (local via `podman exec` or host connection; external via direct connection). This replaces foreman-maintain's Ruby `query()` helper.
- System-level reports (SELinux, networking) use Ansible facts and modules.
- Results are collected into a single dictionary variable and written to a YAML or JSON file.
- New container-specific report fields: container image versions, podman storage usage, systemd timer status, enabled features list. These replace RPM-based fields from foreman-maintain.

This is an Epic because of the sheer volume of reports (~36 definitions, ~2000 lines of Ruby). However, each report is independent, so implementation can be parallelized. Not all reports may carry over -- some are downstream-only (IoP remediations) and some may be obsolete. A triage pass similar to what was done for health checks should determine the final list.

---

## Summary Table

| Functionality | Recommendation | Tracked | Size | Notes |
|---------------|---------------|---------|------|-------|
| upgrade | Keep | SAT-39696 | Epic (in progress) | In progress. |
| update | Keep | SAT-39697 | Epic (in progress) | In progress. |
| health command | Keep | Needs ticket | Story within a small Epic combined with service | New `foremanctl health` command for runtime health checks. |
| check implementations | Keep | Needs ticket | Story within a small Epic combined with health | |
| service management | Drop | N/A | -- | With foreman.target, less necessary. Introduce only as necessary. |
| backup | Keep | Needs ticket | Epic (combined with restore) | Largest untracked area. What to back up may change significantly. |
| restore | Keep | Needs ticket | Epic (combined with backup) | To be implemented in the backup epic. |
| maintenance-mode | Keep | Needs ticket | Story (within upgrade Epic) | Link as related to `update` & `backup` Epics. |
| report | Move | Needs ticket | Epic | SatStats reporting should move to another tool. |
| packages | Drop | N/A | -- | Very few host RPMs in containerized model. |
| self-upgrade | Rethink | Needs tracking in SAT-39696 | -- | The upgrade process will define if this is still necessary. |
| advanced | Drop | N/A | -- | Developers can run Ansible roles/playbooks directly. |
| plugin/puppet purge | Reworked | SAT-40445 | Story (within Puppet epic) | Rework is in-progress. |
| feature detection | Keep | Implicit | N/A - via other stories? | |
| interactive prompts | TBD | Needs ticket | Story | |
