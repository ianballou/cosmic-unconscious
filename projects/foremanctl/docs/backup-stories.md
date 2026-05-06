# Backup & Restore Stories for foremanctl

Epic: [SAT-44838](https://redhat.atlassian.net/browse/SAT-44838) -- Backup and restore via foremanctl

## Delivery order

```
Story 1 (offline DB backup)         -- minimum viable, most critical data protected
    |
Story 2 (config files)              -- full config protection, restorable state
    |
Story 3 (Pulp content)              -- offline backup feature-complete
    |
Story 4 (restore)                   -- round-trip backup/restore proven
    |
Story 5 (online backup)             -- non-disruptive option
    |
Story 6 (incremental)               -- optimization for large deployments

Story 7 (Capsule)                   -- when containerized Capsule is available
```

Stories 1-3 build on each other sequentially. Story 4 (restore) could start in parallel once Story 1 is merged, since the restore playbook can be developed against DB-only backups first and extended as config/Pulp stories land. Story 7 floats independently -- it slots in whenever the containerized Capsule lands, as long as Stories 1-6 are done.

### Engineering rationale for this order

- **Story 1 first** because databases are the most critical data and the hardest to recreate. This story also establishes the entire playbook structure, CLI, service orchestration, and error recovery -- everything subsequent stories plug into.
- **Story 2 before Pulp** because config files (especially `parameters.yaml`, credentials, and Pulp encryption keys) are required for a meaningful restore. Without them, DB dumps alone are insufficient -- you'd need to manually reconstruct the foremanctl state directory.
- **Story 3 completes offline backup** -- Pulp content is the largest component but also the most straightforward (just a tar). It also introduces `--tar-volume-size` and `--skip-pulp-content`.
- **Story 4 after Stories 1-3** because restore needs something complete to restore from. A restore that can't restore config files isn't useful in practice -- `foremanctl deploy` needs `parameters.yaml` to regenerate everything.
- **Story 5 (online) after restore** because online backup changes behavior in all three data roles (config: no retry on changed files; Pulp: consistency loop; services: stop workers only). Having the offline path proven and restorable first means online changes can be validated against a known-good baseline.
- **Story 6 (incremental) last** because it's an optimization, not a functional requirement. The `.snar` files are already produced as a side effect of `--listed-incremental` in Stories 2 and 3 -- this story only adds the "copy `.snar` from previous backup" logic and the CLI param.

---

## Story 1: Offline database backup

**Jira:** [SAT-44895](https://redhat.atlassian.net/browse/SAT-44895)

**Summary:** Deliver a working `foremanctl backup` command that stops services, runs preflight checks, dumps all databases, writes metadata, restarts services, and recovers on failure. This is the minimum viable backup -- the most critical data (databases) is protected.

**Scope:**

CLI and playbook scaffold:
- `src/playbooks/backup/backup.yaml` -- main playbook with block/rescue for error recovery
- `src/playbooks/backup/metadata.obsah.yaml` -- CLI params (all with `persist: false`): positional `backup_dir`, `online`, `skip_pulp_content`, `incremental`, `tar_volume_size`, `wait_for_tasks`
- Backup directory creation with permission validation
- Params not yet implemented (`online`, `incremental`, `tar_volume_size`) should fail early with a clear "not yet supported" message rather than being silently ignored (or keep placeholders)
  - `tar_volume_size` is only for Pulp, will be implemented with the Pulp backup later

Preflight checks:
- DB index integrity via `amcheck` (skip gracefully if amcheck extension is unavailable or DB is remote)
- No running Foreman tasks (API query; `--wait-for-tasks` polls with timeout instead of failing)
- No running Pulp tasks (API or DB query)

Service orchestration:
- `systemctl stop foreman.target`
- Start PostgreSQL briefly for dumps
- `pg_dump` for each database that exists
- Stop PostgreSQL after dumps
- `systemctl start foreman.target`

Database dumps:
- `pg_dump -Fc` for each database
- Connection info from `parameters.yaml` / Ansible vars
- Dump only databases that exist on this instance:
  - Server: `foreman` + `candlepin` + `pulpcore` (+ IoP databases if enabled)
  - Capsule: `pulpcore` + `container_gateway`
- Skip missing databases without error

Metadata:
- Write `metadata.yml` to backup directory (carried over from foreman-maintain's `metadata.rb` procedure):
  - `hostname` (FQDN)
  - `os_version`
  - `foremanctl_version`
  - `backup_type` (online/offline)
  - `timestamp` (ISO 8601)
  - `incremental` flag
  - `enabled_features` (from parameters.yaml)
  - `container_images` (from `podman images --format json` -- replaces foreman-maintain's `rpm -qa`)
  - `parameters_hash` (sha256 of parameters.yaml)
  - `proxy_config` (DNS/DHCP interface settings from parameters.yaml -- needed for restore validation)
  - The above may need adjustment during implementation

Error recovery:
- Rescue block always restarts `foreman.target` on failure
- Clear error message about what failed and that services have been restarted

**Acceptance criteria:**
- `foremanctl backup /path` produces a directory with DB dumps + `metadata.yml`
- `foremanctl backup --help` shows all documented options
- Services are always restarted on both success and failure
- Preflight catches corrupt indexes and running tasks
- Works for both local and remote PostgreSQL configurations
- On a Capsule instance, only `pulpcore.dump` and `container_gateway.dump` are produced (no `foreman.dump` or `candlepin.dump`)
  - Leave validation for later depending on status of containerized capsules

---

## Story 2: Offline config file backup

**Jira:** [SAT-44896](https://redhat.atlassian.net/browse/SAT-44896)

**Summary:** Add config file collection to the backup flow. After this, backups contain everything needed for a (Pulp-less) restore -- databases plus all host-level configuration and credentials.

**Scope -- add config file backup phase to existing playbook (role or tasks):**

Static paths:
- foremanctl state files (parameters.yaml, generated credentials, .installed flag, OAuth keys)
  - Secrets for things like yaml configs are generated from this.
- `/etc/pki/httpd/`, `/root/certificates/`
- `/root/candlepin.keystore`, `/root/candlepin.truststore`
- `/root/foreman-proxy-ssh`, `/root/foreman-proxy-ssh.pub`
- `/etc/httpd/`, `/var/www/html/pub/`
- `/var/lib/pulp/database_fields.symmetric.key`, `/var/lib/pulp/django_secret_key`
- Custom cert paths if specified in `parameters.yaml`

Conditional paths (based on `enabled_features` from `parameters.yaml`):
- TFTP: `/var/lib/tftpboot/`
- DNS: `/var/named/`, `/etc/named*`
- DHCP: `/var/lib/dhcpd/`
- OpenSCAP: `/usr/share/xml/scap/`
- Ansible: `/etc/ansible/`

Behavior:
- Tar into `config_files.tar.gz`
- Always use `--listed-incremental` (creates `.config.snar` as a side effect -- lays groundwork for [SAT-44903](https://redhat.atlassian.net/browse/SAT-44903))
  - Or, consider just implementing incremental here if it doesn't seem difficult.
- Retry up to 3x on tar exit code 1 (files changed during archive), 10s delay between retries
  - foreman-maintain does this today.
- Skip paths that don't exist (no error)

Instance type awareness:
- Capsule instances have the same cert/key paths and proxy feature paths
- Server-only paths (e.g., `candlepin.keystore`) are naturally skipped when absent on a Capsule

**Acceptance criteria:**
- `config_files.tar.gz` is created alongside the DB dumps
- Contains all required static paths that exist on the system
- Conditional paths included/excluded based on feature detection from `parameters.yaml`
- Missing paths silently skipped
- Retry logic handles files changing during tar
- Generally, the offline backup matches the experience you get from `foreman-maintain backup offline` with Pulp skipped.

---

## Story 3: Offline Pulp content backup

**Jira:** [SAT-44897](https://redhat.atlassian.net/browse/SAT-44897)

**Summary:** Add Pulp data backup. After this, offline backup is feature-complete.

**Scope -- add Pulp content backup phase to existing playbook (role or tasks):**
- Tar `/var/lib/pulp/` into `pulp_data.tar`
- Exclude `database_fields.symmetric.key` and `django_secret_key` (already in config backup)
- Always use `--listed-incremental` (creates `.pulp.snar` -- lays groundwork for [SAT-44903](https://redhat.atlassian.net/browse/SAT-44903))
  - Reference: [GNU tar incremental dumps](https://www.gnu.org/software/tar/manual/html_section/Incremental-Dumps.html)
- Support `--tar-volume-size` (split via `--tape-length`)
- `--skip-pulp-content` skips this phase entirely

Instance type awareness:
- Backup for Pulp is likely the same on Capsules.

**Acceptance criteria:**
- `pulp_data.tar` created in backup directory
- Pulp keys excluded (they're in `config_files.tar.gz`)
- `--skip-pulp-content` works
- Volume splitting works with specified size
- Works on both Server and Capsule instances

---

## Story 4: Restore

**Jira:** [SAT-44898](https://redhat.atlassian.net/browse/SAT-44898)

**Summary:** Deliver `foremanctl restore`. Validate a backup, extract it, restore databases, restore Pulp content, and redeploy.

**Scope:**

Command scaffold:
- `src/playbooks/restore/restore.yaml`
- `src/playbooks/restore/metadata.obsah.yaml` -- params: positional `backup_dir`, `dry_run`

Validation (runs before any destructive action):
- Validate backup contents -- required files vary by instance type:
  - Server (Katello): `config_files.tar.gz` + `foreman.dump` + `candlepin.dump` + `pulpcore.dump`
  - Capsule (Proxy with Content): `config_files.tar.gz` + `pulpcore.dump` + `container_gateway.dump` (no foreman/candlepin dumps)
  - Vanilla Foreman: `config_files.tar.gz` + `foreman.dump`
  - `pulp_data.tar` optional in all cases
- Hostname matches current FQDN (from `metadata.yml`)
- Network interfaces exist if DNS/DHCP config recorded in metadata
- DB dump files are readable
- `--dry-run` runs all validation and reports results without performing any destructive action

Restore execution:
1. Stop `foreman.target`
2. Extract `config_files.tar.gz` over `/` (with `--overwrite --listed-incremental /dev/null`)
3. Start PostgreSQL
4. Drop databases that have corresponding dump files
5. `pg_restore` each dump
6. Stop PostgreSQL
7. Extract `pulp_data.tar` to `/var/lib/pulp/` (if present; handle split volumes)
8. Run `foremanctl deploy` -- reads restored `parameters.yaml`, regenerates all podman secrets, quadlet files, httpd config, starts containers
9. Verify: ping Foreman API (or proxy ping for Capsule), check services healthy

Restore does not differ between online and offline backups. The output files are the same set; the difference is in consistency guarantees (online backups may have config/DB/Pulp from slightly different points in time). Restore just extracts and restores whatever files it finds.

Error recovery:
- On failure: leave system stopped for investigation (consistent with foreman-maintain)
- Clear message about which step failed

Instance type awareness:
- Backup validation adapts required files based on instance type (detected from `metadata.yml` or restored `parameters.yaml`)
- Restore only attempts to drop/restore databases that are present in the backup
- Step 8 (`foremanctl deploy`) naturally handles Server vs. Capsule.
- Note: foreman-maintain passes `--foreman-proxy-register-in-foreman false` during Capsule restore to prevent re-registration.

**Acceptance criteria:**
- `foremanctl restore /path` restores a working system from a foremanctl backup
- `--dry-run` validates without making changes
- Hostname mismatch is caught before any destructive action
- Validation adapts required files based on instance type
- `foremanctl deploy` after restore regenerates all derived config (secrets, quadlets, httpd)
- Works with backups that omit `pulp_data.tar`
- System verified healthy after restore (API ping, services up)

---

## Story 5: Online backup

**Jira:** [SAT-44902](https://redhat.atlassian.net/browse/SAT-44902)

**Summary:** Add online backup mode. API stays up, only workers are stopped. Adds Pulp consistency checking and changed-file handling for config.

**Scope -- modify existing backup playbook and roles:**

Service orchestration (when `--online`):
- Stop only worker services instead of `foreman.target`:
  - dynflow-sidekiq workers, pulpcore workers
  - Keep running: foreman, dynflow-sidekiq orchestrator, pulp-api, pulp-content, candlepin, postgresql, redis
- Worker list should be a variable, not hardcoded

Config files (when `--online`):
- Like foreman-maintain, we can collect the config files without retrying. Since services are up, the files are likely to change.
  - See `--ignore-changed-files` in foreman-maintain.

Pulp content (when `--online`):
- Consistency checking loop:
  1. Compute sha1 checksum of all file modification times (`find . -printf '%T@\n' | sha1sum`)
  2. Back up the `.snar` file (for retry)
  3. Run tar
  4. Recompute checksum
  5. If checksums don't match: discard archive, restore `.snar` backup, retry
  6. Loop until consistent

DB dumps (when `--online`):
- No special handling -- `pg_dump` is snapshot-safe against live databases

Error recovery:
- Rescue block restarts workers (not `foreman.target`) on failure

**Acceptance criteria:**
- `foremanctl backup --online /path` keeps API accessible throughout
- Dynflow and Pulp workers are stopped and restarted correctly
- Pulp consistency loop retries until data is stable

**Dependencies:** Recommended to work on offline backup and restore first.

---

## Story 6: Incremental backup and restore

**Jira:** [SAT-44903](https://redhat.atlassian.net/browse/SAT-44903)

**Summary:** Add incremental backup support using GNU tar's `--listed-incremental` mechanism.

**Scope:**

Backup:
- `--incremental <previous_backup_dir>` CLI option
- Copy `.config.snar` and `.pulp.snar` files from `<previous_backup_dir>` into the new backup directory before tar runs
- Fail with clear error if previous directory has no `.snar` files
- Tar automatically produces differential archives based on the copied `.snar` state
- `metadata.yml` records `incremental: true` and previous backup path

Restore:
- Detect incremental from `metadata.yml`
- Require full backup chain restored in order (full first, then incrementals)
- Clear error message if chain is incomplete

Implementation note:
- The `.snar` files are already produced as a side effect of `--listed-incremental` in the previous stories. This story only adds: (1) the CLI param, (2) the "copy `.snar` from previous backup dir" logic in the directory preparation phase, and (3) restore-side chain validation. The tar commands themselves don't change.

**Acceptance criteria:**
- Incremental backup is significantly smaller than full
- Incremental restore applied on top of full produces correct state
- Clear error if `.snar` files missing or chain incomplete
- `metadata.yml` records incremental status

**Dependencies:** Non-incremental backup and restore working. Backup already passes `--listed-incremental` to tar.

---

## Story 7: Capsule backup and restore

**Jira:** [SAT-45029](https://redhat.atlassian.net/browse/SAT-45029)

**Summary:** Validate and complete backup/restore support for containerized Capsule instances. The initial stories are designed with instance-type awareness, but this story covers the actual testing, gap-filling, and any Capsule-specific behavior that emerges once the containerized Capsule exists in foremanctl.

**Scope:**

Validate existing behavior on a Capsule instance:
- Preflight checks work (Capsule has `pulpcore` and `container_gateway` databases -- amcheck runs against those only)
- Database backup produces only `pulpcore.dump` and `container_gateway.dump` (no foreman/candlepin)
- Config file backup collects the correct paths for a Capsule (proxy config, certs, SSH keys, container gateway config, feature-conditional paths like TFTP/DNS/DHCP)
- Pulp content backup works against Capsule's `/var/lib/pulp/`
- Metadata correctly identifies enabled features
- Online backup correctly identifies Capsule worker services

Validate restore on a Capsule instance:
- Backup validation accepts Capsule file set (`config_files.tar.gz` + `pulpcore.dump` + `container_gateway.dump`, no foreman/candlepin dumps)
- `foremanctl deploy` after restore correctly provisions a Capsule (not a Server)
- Investigate whether deploy needs a flag to prevent Capsule re-registration with the Server during restore (foreman-maintain passes `--foreman-proxy-register-in-foreman false` for this)
- Post-restore verification uses proxy ping, not Foreman API ping

Address gaps discovered during implementation:
- Container gateway config paths
- Capsule-specific config paths not present on a Server
- Certs tar handling -- foreman-maintain checks that the certs tarball exists on standalone proxies before backup. Determine whether this applies in the containerized model.
- Any Capsule-specific preflight checks

**Acceptance criteria:**
- `foremanctl backup` on a Capsule produces a valid, restorable backup
- `foremanctl restore` on a Capsule restores a working Capsule instance
- Online and incremental modes work on Capsule

**Dependencies:** Stories 1-6, containerized Capsule availability in foremanctl

---

## Out of scope / future work

| Item | Rationale |
|------|-----------|
| Encryption | foreman-maintain doesn't encrypt backups today. Can be added later if needed. |
| Remote backup targets (NFS/S3) | User handles remote copy. Local-only for now. |
| Candlepin data volume | Depends on [foremanctl#478](https://github.com/theforeman/foremanctl/issues/478). Add to config backup paths once that bind-mount is implemented. |
| IoP databases | Pattern is included (dump only databases that exist), but actual testing deferred until IoP support is confirmed in foremanctl. |
| Puppet/Salt/Mosquitto backup paths | Not yet in foremanctl. Add when those features are implemented. |
| Backup disk space check | Dropped from initial scope. Can be added later as a preflight check. |
