# Backup Design for foremanctl

Design proposal for `foremanctl backup` — replacing foreman-maintain's backup functionality in the containerized world.

## How foreman-maintain backup works today

### Two strategies

**Offline backup** (services stopped):
1. Pre-checks: DB index integrity (`amcheck`), no running Foreman/Pulp tasks (or wait for them)
2. User confirmation that services will stop
3. Prepare backup directory (handle incremental `.snar` files)
4. Stop all services (dependency order)
5. Collect config files → `config_files.tar.gz` (retry up to 3x if files change during tar)
6. Backup Pulp content → `pulp_data.tar` (with incremental `.snar`)
7. Start PostgreSQL only
8. pg_dump for all databases (Foreman, Candlepin, Pulpcore, IoP x5)
9. Compress DB tars
10. Start all services
11. Write metadata.yml
12. On failure: rescue cleanup scenario starts services

**Online backup** (services running):
1. Same pre-checks
2. Stop **only workers** (dynflow-sidekiq workers, pulpcore workers) — API/web stays up
3. Collect config files → `config_files.tar.gz` with `--ignore-changed-files` + online exclusions
4. Backup Pulp content with **consistency checking** (checksum dir before and after tar, retry if changed)
5. pg_dump for all databases (pg_dump is safe for online use)
6. Start workers
7. Write metadata.yml

### Incremental backup support

Uses GNU tar's `--listed-incremental` (`.snar` files):
- First backup: full tar + creates `.snar` snapshot file
- Subsequent backups: copy `.snar` from previous backup dir → tar only creates archive of changed files
- Applies to both `config_files.tar.gz` and `pulp_data.tar`

### Pulp online consistency checking

During online backup, Pulp data might change while tar is running:
1. Compute checksum of all file modification times: `find . -printf '%T@\n' | sha1sum`
2. Run tar
3. Recompute checksum
4. If checksums don't match → data changed during backup → delete archive, retry
5. Loop until checksums match (content didn't change during the tar window)

### DB index integrity (amcheck)

Before any backup, runs PostgreSQL `amcheck` extension:
- Calls `bt_index_check()` on all btree indexes in the `public` schema
- Catches corrupted indexes before they end up in a backup
- Only runs if amcheck extension is installed and DB is local
- Runs for Foreman, Candlepin, and Pulpcore databases

### Config file retry logic

For offline backups, config file collection retries up to 3 times with 10-second delays if tar reports files changed during archiving (exit code 1). For online backups, changed files are ignored.

### Pre-flight checks

- **Foreman tasks**: Checks no tasks are running (or waits for them with `--wait-for-tasks`)
- **Pulp tasks**: Same check for Pulpcore running tasks
- **DB index**: amcheck integrity verification
- **Disk space**: (implied, not explicitly checked in current code)

---

## Proposed foremanctl backup design

### Architecture: Ansible playbook (same pattern as everything else)

```
src/playbooks/backup/
├── backup.yaml           # main playbook
└── metadata.obsah.yaml   # CLI params

src/playbooks/restore/
├── restore.yaml          # main playbook
└── metadata.obsah.yaml   # CLI params

src/roles/
├── backup_preflight/     # pre-checks
├── backup_config/        # config files + obsah state
├── backup_databases/     # pg_dump via containers
├── backup_pulp/          # /var/lib/pulp content
├── backup_metadata/      # container images, hostname, etc.
└── restore/              # restore + redeploy
```

### CLI

```bash
# Full offline backup (stops services)
foremanctl backup /var/backup/satellite-2026-05-01

# Online backup (workers stopped, API stays up)
foremanctl backup --online /var/backup/satellite-2026-05-01

# Skip Pulp content (fast, config+DB only)
foremanctl backup --skip-pulp-content /var/backup/quick

# Incremental (only changes since last backup)
foremanctl backup --incremental /var/backup/previous-backup /var/backup/incremental-2026-05-01

# Split large tar volumes
foremanctl backup --tar-volume-size 100G /var/backup/satellite-2026-05-01

# Wait for running tasks instead of failing
foremanctl backup --wait-for-tasks /var/backup/satellite-2026-05-01
```

### metadata.obsah.yaml

```yaml
---
help: |
  Backup Satellite data

variables:
  online:
    help: Perform online backup (API stays up, workers stopped)
    action: store_true
    persist: false
  skip_pulp_content:
    help: Skip Pulp content during backup
    action: store_true
    persist: false
  incremental:
    help: Path to previous backup directory for incremental backup
    persist: false
  tar_volume_size:
    help: Size of tar volume for splitting (e.g., 100G)
    persist: false
  wait_for_tasks:
    help: Wait for running tasks to complete instead of aborting
    action: store_true
    persist: false
```

Note: all params have `persist: false` — backup options shouldn't be saved.

### Playbook flow

#### Phase 1: Pre-flight checks (`backup_preflight` role)

```yaml
# 1. Disk space check on backup target
- name: Check available disk space
  # Compare against estimated backup size

# 2. Services healthy
- name: Check foreman.target is active
  ansible.builtin.systemd:
    name: foreman.target
  register: target_status

# 3. DB index integrity (amcheck)
- name: Run amcheck on Foreman DB
  containers.podman.podman_container:
    name: backup-amcheck-foreman
    image: "{{ postgresql_container_image }}"
    command: >
      psql -d foreman -c "
        SELECT bt_index_check(c.oid, i.indisunique)
        FROM pg_index i
        JOIN pg_opclass op ON i.indclass[0] = op.oid
        JOIN pg_am am ON op.opcmethod = am.oid
        JOIN pg_class c ON i.indexrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE am.amname = 'btree' AND n.nspname = 'public'
        AND c.relpersistence != 't';
      "
    detach: false
    rm: true
    network: host
    secrets:
      - 'postgresql-admin-password,type=env,target=PGPASSWORD'
  # Repeat for candlepin, pulpcore

# 4. No running tasks
- name: Check for running Foreman tasks
  ansible.builtin.uri:
    url: "{{ foreman_url }}/api/v2/tasks?search=state%3Drunning&per_page=1"
    ca_path: "{{ foreman_ca_certificate }}"
  register: running_tasks
  # If wait_for_tasks: poll until count=0
  # If not: fail if count > 0

# 5. No running Pulp tasks
- name: Check for running Pulp tasks
  # Similar check via pulp API or DB query
```

#### Phase 2: Service management (offline only)

```yaml
# Offline: stop everything
- name: Stop all services
  ansible.builtin.systemd:
    name: foreman.target
    state: stopped
  when: not online

# Online: stop only workers
- name: Stop workers for online backup
  ansible.builtin.systemd:
    name: "{{ item }}"
    state: stopped
  loop: "{{ worker_services }}"
  when: online
  # worker_services = dynflow-sidekiq@worker, dynflow-sidekiq@worker-hosts-queue, pulp-worker@*
  # Keep running: foreman, dynflow-sidekiq@orchestrator, pulp-api, pulp-content, candlepin, postgresql, redis
```

#### Phase 3: Config backup (`backup_config` role)

This is **much simpler** than foreman-maintain because most config is in one place.

```yaml
backup_config_paths:
  # Master config — the "answer file" for foremanctl
  - <state_dir>/

  # Certificates
  - /etc/pki/httpd/
  - # removed - doesn't exist in foremanctl
  - # /etc/pki/ca-trust/source/anchors/ - empty on test box
  - /root/certificates/
  - /root/candlepin.keystore
  - /root/candlepin.truststore

  # REX SSH keys
  - /root/foreman-proxy-ssh
  - /root/foreman-proxy-ssh.pub

  # httpd (not containerized — still on host)
  - /etc/httpd/
  - /var/www/html/pub/

  # Pulp generated keys (critical — can't be regenerated)
  - /var/lib/pulp/database_fields.symmetric.key
  - /var/lib/pulp/django_secret_key

# Conditional paths — read enabled features from parameters.yaml
backup_config_conditional:
  tftp:
    - /var/lib/tftpboot/
  dns:
    - /var/named/
    - /etc/named/
    - /etc/named.conf
  dhcp:
    - /var/lib/dhcpd/
  openscap:
    - /usr/share/xml/scap/
  ansible:
    - /etc/ansible/
```

Feature detection is trivial — read `enabled_features` from `parameters.yaml` instead of probing the system.

For offline backups, tar can retry on changed files (same logic). For online backups, use `--ignore-changed-files`. Support incremental via `--listed-incremental .snar` files — same as foreman-maintain.

#### Phase 4: Database dumps (`backup_databases` role)

```yaml
- name: Dump Foreman database
  containers.podman.podman_container:
    name: backup-foreman-db
    image: "{{ postgresql_container_image }}:{{ postgresql_container_tag }}"
    command: >
      bash -c 'pg_dump -Fc
      -h {{ foreman_database_host }}
      -p {{ foreman_database_port }}
      -U {{ foreman_database_user }}
      -f /backup/foreman.dump
      {{ foreman_database_name }}'
    detach: false
    rm: true
    network: host
    volumes:
      - "{{ backup_dir }}:/backup:Z"
    env:
      PGPASSWORD: "{{ foreman_database_password }}"

# Repeat for candlepin, pulpcore
# IoP databases if IoP feature enabled
```

Using one-shot containers for pg_dump is cleaner than exec — no dependency on the running postgresql container, and the backup container can mount the backup directory directly.

For offline mode: `foreman.target` is already stopped, but PostgreSQL needs to be started briefly for the dump (same as foreman-maintain does today).

#### Phase 5: Pulp content (`backup_pulp` role)

```yaml
- name: Backup Pulp content
  # Same tar approach as foreman-maintain
  # Supports:
  #   --listed-incremental for incremental
  #   --volume-size for splitting
  #   ensure_unchanged checksum loop for online mode
  ansible.builtin.command:
    cmd: >
      tar --create
      --file={{ backup_dir }}/pulp_data.tar
      --listed-incremental={{ backup_dir }}/.pulp.snar
      {% if tar_volume_size %}--tape-length={{ tar_volume_size }}{% endif %}
      --directory=/var/lib/pulp
      --exclude=database_fields.symmetric.key
      --exclude=django_secret_key
      .
  when: not skip_pulp_content
```

For online consistency:
```yaml
- name: Online Pulp backup with consistency check
  # Loop until checksums match (data didn't change during tar)
  ansible.builtin.script: backup_pulp_consistent.sh
  args:
    backup_dir: "{{ backup_dir }}"
    pulp_dir: /var/lib/pulp
  when: online and not skip_pulp_content
  # Script logic:
  #   1. checksum1 = find /var/lib/pulp -printf '%T@\n' | sha1sum
  #   2. tar create
  #   3. checksum2 = find /var/lib/pulp -printf '%T@\n' | sha1sum
  #   4. if checksum1 != checksum2: rm tar, retry
```

#### Phase 6: Metadata (`backup_metadata` role)

```yaml
metadata:
  hostname: "{{ ansible_facts['fqdn'] }}"
  os_version: "{{ ansible_facts['distribution'] }} {{ ansible_facts['distribution_version'] }}"
  foremanctl_version: "{{ foremanctl_version }}"
  backup_type: "{{ 'online' if online else 'offline' }}"
  incremental: "{{ incremental_dir | default(false) }}"
  timestamp: "{{ ansible_date_time.iso8601 }}"
  enabled_features: "{{ enabled_features }}"
  container_images: "{{ podman_images_list }}"  # replaces rpm -qa
  parameters_hash: "{{ parameters_yaml_content | hash('sha256') }}"
```

#### Phase 7: Service restart + cleanup

```yaml
# Offline: start everything
- name: Start all services
  ansible.builtin.systemd:
    name: foreman.target
    state: started
  when: not online

# Online: start workers
- name: Start workers
  ansible.builtin.systemd:
    name: "{{ item }}"
    state: started
  loop: "{{ worker_services }}"
  when: online
```

Rescue cleanup (on failure): always attempt to start `foreman.target` to avoid leaving the system down.

---

## Restore approach

Restore is simpler than foreman-maintain because `foremanctl deploy` handles the heavy lifting.

```bash
foremanctl restore /var/backup/satellite-2026-05-01
```

### Restore flow

1. **Stop services**: `systemctl stop foreman.target`
2. **Restore config**: extract `config_files.tar.gz` → `<state_dir>/`, certs, httpd, keys
3. **Restore databases**: drop + `pg_restore` for each database (start PostgreSQL container briefly)
4. **Restore Pulp content**: extract `pulp_data.tar` → `/var/lib/pulp/`
5. **Redeploy**: `foremanctl deploy` — reads restored `parameters.yaml`, regenerates all podman secrets, quadlet files, starts containers
6. **Verify**: ping Foreman API, check services healthy

The key insight: **step 5 replaces foreman-maintain's complex restore scenario.** Instead of replaying feature-by-feature config file restores, a single `foremanctl deploy` regenerates everything from the master config.

---

## What simplifies vs foreman-maintain

| Concern | foreman-maintain | foremanctl |
|---------|-----------------|------------|
| Feature detection for config paths | Probe 35+ features at runtime, each contributing paths | Read `parameters.yaml` — one file, one source of truth |
| Service stop/start | ~20 individual systemd units in dependency order | `systemctl stop/start foreman.target` — one command |
| Config file collection | Tar ~15 different host paths from scattered features | Tar `<state_dir>/` + certs + httpd — everything else is reproducible |
| DB connection info | Parse installer answers, find socket paths | Read from `parameters.yaml` / Ansible vars |
| What to back up | Complex discovery of what's installed | Static list + conditional on `enabled_features` |
| Restore | Complex feature-by-feature config replay | Restore source files + `foremanctl deploy` |
| RPM inventory | `rpm -qa` (thousands of packages) | `podman images` (handful of images) |
| Rescue cleanup | Custom scenario to restart scattered services | `systemctl start foreman.target` |

## What stays the same

| Concern | Approach |
|---------|----------|
| Online vs offline strategy | Same concept: offline stops all, online stops workers only |
| Incremental backups | Same GNU tar `--listed-incremental` `.snar` approach |
| Pulp consistency checking | Same checksum-before-and-after loop for online mode |
| DB index integrity | Same `amcheck` checks, run via one-shot container |
| pg_dump format | Same `-Fc` (custom format) dumps |
| Config tar retry logic | Same retry-on-changed-files for offline mode |
| Pulp content volume splitting | Same `--tape-length` tar option |
| Running task pre-checks | Same concept, check via API instead of Ruby feature |

## Open questions

- **Candlepin data volume**: foremanctl#478 plans to bind-mount `/var/lib/candlepin/` — once implemented, add to backup paths. Same online exclusion for `activemq-artemis`.
- **IoP databases**: IoP carries forward. Need to determine exact database names and whether the existing container-based IoP has its own pg_dump approach.
- **Disk space estimation**: foreman-maintain doesn't explicitly check disk space. Should foremanctl add a pre-flight check?
- **Encryption**: Should backup archives be encrypted? foreman-maintain doesn't do this today.
- **Remote backup targets**: Should foremanctl support backing up directly to NFS/S3/etc.? Or is local-only sufficient (user handles remote copy)?
