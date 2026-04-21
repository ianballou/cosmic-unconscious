# Migration Map: foreman-maintain → foremanctl

## Architecture Comparison

| Aspect | foreman-maintain | foremanctl |
|--------|-----------------|------------|
| Language | Ruby (CLI via Clamp gem) | Python/Ansible (CLI via Obsah framework) |
| Extension model | Ruby classes: Check, Procedure, Scenario, Feature | Ansible roles + playbooks, registered via metadata.obsah.yaml |
| Command dispatch | Clamp subcommands → Scenarios → Steps (Checks/Procedures) | Obsah → argparse subcommands → Ansible playbooks |
| Feature detection | Runtime Ruby class introspection (Detector) | Static features.yaml registry |
| Config | /etc/foreman-maintain/foreman_maintain.yml | Persisted params in .var/lib/foremanctl/parameters.yaml |
| Reporting | Interactive CLI reporter (spinners, prompts) | Ansible callback plugin (foremanctl.py) |

## foreman-maintain CLI Commands → foremanctl Mapping

| foreman-maintain Command | Description | foremanctl Status | Notes |
|--------------------------|-------------|-------------------|-------|
| `health check` | Run health checks | 🟡 Partial (`checks`) | foremanctl has 4 checks (features, hostname, db_connection, system_requirements). foreman-maintain has ~50 checks. |
| `health check --label X` | Run specific check | ❌ Not yet | Need per-check selection mechanism |
| `health list` | List available checks | ❌ Not yet | |
| `health list-tags` | List available tags | ❌ Not yet | |
| `service start/stop/restart` | Manage services | ❌ Not yet | foremanctl uses systemd targets (foreman.target) directly |
| `service status` | Service status | ❌ Not yet | |
| `service list` | List managed services | ❌ Not yet | |
| `service enable/disable` | Enable/disable services | ❌ Not yet | |
| `backup online/offline` | Create backup | ❌ Not yet | Complex scenario with many procedures |
| `restore` | Restore from backup | ❌ Not yet | Complex scenario |
| `upgrade check/run` | Pre-upgrade checks, run upgrade | ❌ Not yet | |
| `update check/run` | Update checks, run update | ❌ Not yet | |
| `packages lock/unlock/status` | Package version locking | ❌ Not yet | Uses foreman-protector DNF plugin |
| `packages check-update` | Check for package updates | ❌ Not yet | |
| `packages install/update` | Install/update packages | ❌ Not yet | |
| `maintenance-mode start/stop/status` | Maintenance mode | ❌ Not yet | |
| `advanced procedure run` | Run individual procedure | ❌ Not yet | |
| `advanced procedure by-tag` | Run procedures by tag | ❌ Not yet | |
| `plugin purge-puppet` | Remove puppet | ❌ Not yet | |
| `self-upgrade` | Major version self-upgrade | ❌ Not yet | |
| `report` | Generate usage report | ❌ Not yet | 36 report definitions |

## foreman-maintain Feature Inventory (definitions/features/)

These are service/component abstractions used by checks and procedures:

| Feature | Purpose |
|---------|---------|
| apache | Apache/httpd service management |
| candlepin | Candlepin service + DB |
| candlepin_database | Candlepin DB operations |
| capsule | Capsule-specific behavior |
| containers | Container management |
| cron | Cron service |
| dynflow_sidekiq | Dynflow/Sidekiq workers |
| foreman_cockpit | Cockpit integration |
| foreman_database | Foreman DB operations |
| foreman_install | Foreman installation detection |
| foreman_openscap | OpenSCAP plugin |
| foreman_proxy | Smart Proxy management (largest: 257 LOC) |
| foreman_server | Foreman server detection |
| foreman_tasks | Task management (212 LOC) |
| hammer | Hammer CLI (181 LOC) |
| installer | foreman-installer wrapper |
| instance | Instance metadata (201 LOC) |
| iop* (6 features) | Insights on Prem databases |
| iptables/nftables | Firewall management |
| katello | Katello plugin |
| katello_install | Katello installation detection |
| mosquitto | MQTT broker |
| pulpcore | Pulp service |
| pulpcore_database | Pulp DB operations |
| puppet_server | Puppet integration |
| redis | Redis service |
| rh_cloud | RH Cloud plugin |
| salt_server | Salt integration |
| satellite | Satellite-specific |
| service | Generic service abstraction (128 LOC) |
| sync_plans | Sync plan management (107 LOC) |
| tar | Tar/backup operations (98 LOC) |
| timer | Systemd timer management (96 LOC) |

## foreman-maintain Checks Inventory (definitions/checks/)

| Category | Checks | Count |
|----------|--------|-------|
| backup | certs_tar_exist | 1 |
| candlepin | db_index, db_up | 2 |
| container | podman_login | 1 |
| disk | available_space, available_space_candlepin, performance, postgresql_mountpoint | 4 |
| foreman | check_corrupted_roles, check_duplicate_permission, check_external_db_evr_permissions, check_puppet_capsules, check_tuning_requirements, db_index, db_up, facts_names | 8 |
| foreman_openscap | invalid_report_associations | 1 |
| foreman_proxy | check_tftp_storage, verify_dhcp_config_syntax | 2 |
| foreman_tasks | invalid/check_old, invalid/check_pending_state, invalid/check_planning_state, not_paused, not_running | 5 |
| iop_* | db_up (×5) | 5 |
| maintenance_mode | check_consistency | 1 |
| package_manager | dnf/validate_dnf_config | 1 |
| pulpcore | db_index, db_up, no_running_tasks | 3 |
| puppet | verify_no_empty_cacert_requests | 1 |
| repositories | check_non_rh_repository, check_upstream_repository, validate | 3 |
| restore | validate_backup, validate_hostname, validate_interfaces, validate_postgresql_dump_permissions | 4 |
| top-level | check_hotfix_installed, check_ipv6_disable, check_sha1_certificate_authority, check_subscription_manager_release, check_tmout, env_proxy, non_rh_packages, root_user, server_ping, services_up, system_registration | 11 |
| **Total** | | **~53** |

## foremanctl Existing Checks (src/roles/)

| Check Role | Description |
|------------|-------------|
| check_features | Validates enabled features |
| check_hostname | Validates hostname configuration |
| check_database_connection | Tests database connectivity |
| check_system_requirements | System prereqs (CPU, memory, etc.) |
| check_subuid_subgid | Container user namespace setup (exists but not wired into checks playbook) |
| certificate_checks | Certificate validation (exists but not wired into checks playbook) |

## Scenarios (complex workflows)

| Scenario | Complexity | foreman-maintain Steps |
|----------|-----------|----------------------|
| backup (online/offline) | HIGH | ~15 procedures, multiple DB dumps, config files, pulp content |
| restore | HIGH | ~15 procedures, DB restoration, config restoration |
| foreman_upgrade | HIGH | Pre-checks, package updates, installer run, post-checks |
| satellite_upgrade | HIGH | Similar to foreman_upgrade + satellite-specific |
| update | MEDIUM | Check + package update + installer |
| self_upgrade | MEDIUM | Major version upgrade of foreman-maintain itself |
| services | LOW | Start/stop/restart/status/enable/disable/list |
| maintenance_mode | LOW | Enable/disable/status |
| packages | MEDIUM | Lock/unlock/install/update with protector plugin |
| puppet | LOW | Purge puppet data |
| report | MEDIUM | 36 report generators |

## Priority Recommendation

### Phase 1: Quick Wins (LOW complexity, high value)
1. **Health checks** — Expand existing `checks` playbook with more checks from foreman-maintain
2. **Service management** — start/stop/restart/status (foremanctl already uses systemd targets)

### Phase 2: Medium Complexity
3. **Maintenance mode** — enable/disable/status
4. **Package management** — lock/unlock/status
5. **Report generation** — usage reports

### Phase 3: High Complexity
6. **Backup** — online/offline backup workflows
7. **Restore** — restore from backup
8. **Upgrade/Update** — upgrade orchestration
