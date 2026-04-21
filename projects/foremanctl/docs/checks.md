# Health Checks Inventory

Detailed evaluation of every foreman-maintain health check and its relevance to foremanctl.

## Legend
- **Context**: What the check does and why it exists
- **Tags**: When it runs in foreman-maintain (e.g., `pre_upgrade`, `default`)
- **Decision**: Pending evaluation by the team

---

## System / Environment Checks

### root_user
**What it does**: Asserts the command is running as root (checks `Process.uid == 0`).
**Tags**: Used as a prerequisite step in many scenarios.
**Relevance**: Ansible can handle privilege escalation via `become`. May still be useful as a preflight check for foremanctl itself.

### check_tmout
**What it does**: Checks if the `TMOUT` environment variable is set. If set, long-running operations (like upgrades) can be killed mid-process when the shell times out.
**Tags**: `pre_upgrade`
**Relevance**: Still relevant — containerized or not, a shell timeout during an upgrade is dangerous.

### env_proxy
**What it does**: Checks if `HTTP_PROXY`/`HTTPS_PROXY` environment variables are set. These can interfere with service-to-service communication.
**Tags**: `env_proxy`
**Relevance**: Still relevant — proxy env vars affect container operations and Ansible connections.

### check_ipv6_disable
**What it does**: Checks if `ipv6.disable=1` is set in kernel boot params (`/proc/cmdline`). This is known to break installation and upgrades.
**Tags**: (default)
**Relevance**: Still relevant — this is a kernel-level issue that affects containerized deployments too.

### check_subscription_manager_release
**What it does**: Checks if `subscription-manager release` is pinned to a minor RHEL version. Satellite is only supported on the latest RHEL (no minor pin).
**Tags**: (default)
**Relevance**: Downstream (Satellite) only. Still relevant if the host OS matters for container deployments.

### system_registration
**What it does**: Checks if the system is registered to itself via subscription-manager (self-registered). This is a known problematic configuration.
**Tags**: `default`, downstream only
**Relevance**: Downstream only. Still relevant if RHSM registration matters.

---

## Disk Checks

### disk/available_space
**What it does**: Asserts root partition (/) has at least 4GB free.
**Tags**: `pre_upgrade`
**Relevance**: Still relevant — containers need disk space too.

### disk/available_space_candlepin
**What it does**: Asserts `/var/lib/candlepin` has less than 90% disk usage.
**Tags**: `pre_upgrade`, requires candlepin feature
**Relevance**: Needs rethinking — in containers, Candlepin data lives in volumes. The check concept is valid but the path will differ.

### disk/performance
**What it does**: Runs `fio` benchmarks on Pulp and PostgreSQL data directories. Warns if read speed < 60 MB/sec.
**Tags**: Requires pulp feature, installs `fio` as prerequisite
**Relevance**: Still relevant — disk performance affects containerized services the same way. Paths may change to volume mount points.

### disk/postgresql_mountpoint
**What it does**: Checks that `/var/lib/pgsql/data` is on the same device as `/var/lib/pgsql`. Separate mountpoints break PostgreSQL upgrades.
**Tags**: Local PostgreSQL only, EL only
**Relevance**: Likely irrelevant — foremanctl runs PostgreSQL in a container. The volume mount is what matters.

---

## Database Checks

### foreman/db_up
**What it does**: Pings the Foreman PostgreSQL database to verify it's responding.
**Tags**: (default)
**Relevance**: Still relevant. foremanctl already has `check_database_connection` role doing similar work.

### candlepin/db_up
**What it does**: Pings the Candlepin PostgreSQL database.
**Tags**: (default)
**Relevance**: Still relevant. Could be consolidated into a single "check all databases" role.

### pulpcore/db_up
**What it does**: Pings the Pulpcore PostgreSQL database.
**Tags**: (default)
**Relevance**: Still relevant. Same consolidation opportunity.

### iop_advisor/db_up, iop_inventory/db_up, iop_remediations/db_up, iop_vmaas/db_up, iop_vulnerability/db_up
**What they do**: Ping each Insights on Prem database (5 identical checks, different DBs).
**Tags**: (default)
**Relevance**: Downstream (Satellite) only. If IoP is part of containerized Satellite, these carry over. Could be a parameterized single check.

### foreman/db_index, candlepin/db_index, pulpcore/db_index
**What they do**: Run PostgreSQL `amcheck` extension to verify B-tree index integrity. Local DB only.
**Tags**: `db_index`
**Relevance**: Still relevant for data integrity. Works regardless of containerization as long as we can access the DB.

### foreman/validate_external_db_version
**What it does**: Checks that external PostgreSQL is at least version 13.
**Tags**: `pre_upgrade`, external DB only
**Relevance**: Still relevant — foremanctl supports external databases.

### foreman/check_external_db_evr_permissions
**What it does**: Checks that the `evr` PostgreSQL extension is owned by the foreman DB user (not postgres). External DB + Katello only.
**Tags**: `pre_upgrade`
**Relevance**: Still relevant if Katello uses external DB.

---

## Foreman Application Checks

### foreman/facts_names
**What it does**: Queries the Foreman DB for hosts with >10,000 fact values. Warns about slow fact processing.
**Tags**: `default`
**Relevance**: Still relevant — this is application-level data, not deployment-model dependent.

### foreman/check_corrupted_roles
**What it does**: Queries DB for filters that have permissions with multiple resource types attached. Offers automated fix.
**Tags**: `pre_upgrade`
**Relevance**: Still relevant — database content issue, deployment-model independent.

### foreman/check_duplicate_permissions
**What it does**: Queries DB for duplicate permission entries. Offers automated cleanup.
**Tags**: `pre_upgrade`
**Relevance**: Still relevant — database content issue.

### foreman/check_tuning_requirements
**What it does**: Checks if system CPU/memory meets the requirements of the configured tuning profile (default, medium, large, etc.). Katello only.
**Tags**: `pre_upgrade`, `do_not_whitelist`
**Relevance**: Still relevant — containers still need adequate host resources. foremanctl already has `check_system_requirements` which may cover this.

### server_ping
**What it does**: Calls `/katello/api/ping` (or `/api/ping`) to verify all backend services are responding correctly.
**Tags**: `default`, runs after `services_up`
**Relevance**: Still relevant — validates the application is actually working end-to-end.

### services_up
**What it does**: Checks that all managed systemd services are running.
**Tags**: `default`
**Relevance**: Still relevant but the service list changes. In containerized world, this checks container/pod/systemd-target status.

---

## Task Checks

### foreman_tasks/not_paused
**What it does**: Checks for paused Foreman tasks. Offers to resume or delete them.
**Tags**: `default`, runs after `services_up` and `server_ping`
**Relevance**: Still relevant — application-level concern.

### foreman_tasks/not_running
**What it does**: Checks for running Foreman tasks before upgrade. Can optionally wait for them to finish.
**Tags**: `pre_upgrade`
**Relevance**: Still relevant — must not upgrade while tasks are running.

### foreman_tasks/invalid/check_old
**What it does**: Finds paused/stopped tasks older than 30 days. Offers to delete them.
**Tags**: `pre_upgrade`
**Relevance**: Still relevant — database hygiene.

### foreman_tasks/invalid/check_pending_state
**What it does**: Finds tasks stuck in pending state. Offers to delete them.
**Tags**: `pre_upgrade`
**Relevance**: Still relevant.

### foreman_tasks/invalid/check_planning_state
**What it does**: Finds tasks stuck in planning state. Offers to delete them.
**Tags**: `pre_upgrade`
**Relevance**: Still relevant.

### pulpcore/no_running_tasks
**What it does**: Checks for active Pulpcore tasks. Can wait for completion.
**Tags**: `pre_upgrade`
**Relevance**: Still relevant — must not upgrade while Pulp tasks are running.

---

## Certificate Checks

### check_sha1_certificate_authority
**What it does**: Reads the server CA certificate (from installer answers) and checks if it's signed with SHA-1. SHA-1 CAs break on upgrade.
**Tags**: Requires katello or foreman_proxy feature, `do_not_whitelist`
**Relevance**: Still relevant — certificate algorithm issues are deployment-model independent. Note: foremanctl already has a `certificate_checks` role.

---

## Repository / Package Checks

### repositories/check_non_rh_repository
**What it does**: Checks if EPEL or other non-RH repos are enabled. These can interfere with upgrades.
**Tags**: `pre_upgrade`, downstream only
**Relevance**: Reduced relevance — with fewer host RPMs, non-RH repos are less dangerous. But they could still interfere with foremanctl/hammer package updates.

### repositories/check_upstream_repository
**What it does**: Checks if upstream Foreman/Katello repos are enabled on a downstream (Satellite) system.
**Tags**: `pre_upgrade`, downstream only
**Relevance**: Still relevant for downstream — upstream repos on a Satellite system would cause version conflicts.

### repositories/validate
**What it does**: Validates that all required RHSM repositories for the current version are available.
**Tags**: `pre_upgrade`, downstream only
**Relevance**: Still relevant for downstream — need correct repos to update foremanctl/hammer RPMs.

### check_hotfix_installed
**What it does**: Searches for RPMs with "HOTFIX" in their release string, and checks for modified Ruby/Python/JS/ERB files in installed packages. Warns that hotfixes may be lost on upgrade.
**Tags**: `pre_upgrade`, downstream only
**Relevance**: Significantly reduced — with containerized services, application code isn't in host RPMs. May still apply to hammer CLI packages.

### non_rh_packages
**What it does**: Lists all installed RPMs not from Red Hat vendors.
**Tags**: `pre_upgrade`, downstream only
**Relevance**: Reduced relevance — fewer host RPMs means fewer non-RH packages to worry about.

### package_manager/dnf/validate_dnf_config
**What it does**: Checks if `exclude` is set in `/etc/dnf/dnf.conf`, which can block necessary package updates during upgrade.
**Tags**: `pre_upgrade`
**Relevance**: Reduced but still valid — dnf config could block foremanctl/hammer updates.

---

## Backup/Restore Checks

### backup/certs_tar_exist
**What it does**: Checks that a required certs tar file exists before backup.
**Tags**: Backup scenario only
**Relevance**: Needs rethinking — certificate storage location changes with containers.

### restore/validate_backup
**What it does**: Validates a backup directory contains all required files (DB dumps, configs, etc.).
**Tags**: Restore scenario only
**Relevance**: Still relevant — backup format may change but validation is still needed.

### restore/validate_hostname
**What it does**: Checks that the hostname in the backup matches the current system hostname.
**Tags**: Restore scenario only
**Relevance**: Still relevant.

### restore/validate_interfaces
**What it does**: Checks that network interfaces used by features in the backup exist on the current system.
**Tags**: Restore scenario only
**Relevance**: Still relevant.

### restore/validate_postgresql_dump_permissions
**What it does**: Checks that the `postgres` system user can read the DB dump files (for local DB restores).
**Tags**: Restore scenario only
**Relevance**: Needs rethinking — DB runs in container, so permissions model differs.

---

## Plugin-specific Checks

### foreman_openscap/invalid_report_associations
**What it does**: Finds OpenSCAP reports missing policy, proxy, or host associations. Offers cleanup.
**Tags**: `pre_upgrade`, requires foreman_openscap feature
**Relevance**: Still relevant if OpenSCAP feature is enabled — application data issue.

### foreman_proxy/check_tftp_storage
**What it does**: Cleans old kernel/initramfs files from TFTP boot directory based on token duration.
**Tags**: `default`, requires satellite + foreman_proxy + tftp
**Relevance**: Depends on whether TFTP runs on host or in container.

### foreman_proxy/verify_dhcp_config_syntax
**What it does**: Validates ISC DHCP server configuration syntax.
**Tags**: `default`, requires foreman_proxy + dhcp-isc
**Relevance**: Depends on whether DHCP runs on host or in container.

### puppet/verify_no_empty_cacert_requests
**What it does**: Checks for empty files in Puppet CA certificate request directory.
**Tags**: `default`, requires puppet_server feature
**Relevance**: Only if Puppet is supported in containerized deployments.

### foreman/check_puppet_capsules
**What it does**: Queries DB for Smart Proxies with Puppet feature enabled.
**Tags**: Manual detection only
**Relevance**: Only relevant for Puppet removal workflows.

---

## Container-specific Checks (foreman-maintain)

### container/podman_login
**What it does**: Checks if podman is logged into `registry.redhat.io` using the auth file at `/etc/foreman/registry-auth.json`.
**Tags**: `pre_upgrade`, downstream + containers only
**Relevance**: Directly relevant — foremanctl is container-based. Already partially covered by foremanctl's deployment flow.

---

## Maintenance Mode Check

### maintenance_mode/check_consistency
**What it does**: Verifies that all maintenance mode components (firewall rule, cron, timers, sync plans) are in a consistent state — all on or all off.
**Tags**: Used by `maintenance-mode status` command
**Relevance**: Relevant if maintenance mode is kept (pending team discussion).

---

## Summary Counts by Relevance Category

| Category | Count | Examples |
|----------|-------|---------|
| Still relevant (carry over) | ~25 | DB checks, task checks, disk space, server_ping, tuning |
| Still relevant but needs rethinking | ~8 | disk paths, backup validation, service lists |
| Reduced relevance | ~6 | RPM/repo checks (fewer host packages) |
| Downstream only | ~10 | RHSM, non-RH packages, subscription checks |
| Likely irrelevant | ~4 | postgresql_mountpoint, hotfix RPMs, puppet checks |
