# Backup Comparison: foreman-maintain vs foremanctl

Three charts comparing what foreman-maintain backs up vs what foremanctl needs.

The "Verified on live box" column indicates whether each claim was checked on a running foremanctl deployment (2026-04-30). "yes - absent" means the path was confirmed to not exist on the host. Conditional items (TFTP, DNS, etc.) were not tested because those features were not enabled on the test box.

## Chart 1: Files foremanctl should NOT backup (no longer exist)

These paths are backed up by foreman-maintain today but do not exist on a containerized foremanctl host. They should be dropped from any future backup implementation.

| Path | foreman-maintain Feature | Why it's gone in foremanctl | Verified on live box |
|------|------------------------|-----------------------------|----------|
| `/etc/foreman-installer/` | installer | No foreman-installer. foremanctl uses Ansible roles + persisted parameters. | yes - absent |
| `/opt/puppetlabs/puppet/cache/foreman_cache_data` | installer | foreman-installer's Puppet cache, not related to BYOP. | yes - absent |
| `/opt/puppetlabs/puppet/cache/pulpcore_cache_data` | installer | Same. | yes - absent |
| `/etc/sysconfig/foreman` | foreman_server | Foreman runs in a container; env vars set via quadlet + podman secrets. | yes - absent |
| `/usr/share/ruby/vendor_ruby/puppet/reports/foreman.rb` | foreman_server, puppet_server | No Puppet on host. Report processor lives in the container image. | yes - absent |
| `/var/lib/foreman/` | foreman_server | App lives in container image. Only `/var/run/foreman` is volume-mounted. | yes - absent |
| `/etc/foreman/` (settings.yaml, plugins/, certs) | foreman_server, dynflow_sidekiq | Rendered from templates → podman secrets → mounted into containers. Reproducible from parameters + redeploy. | yes - absent |
| `/etc/foreman-proxy/` | foreman_proxy | Same — rendered templates → podman secrets. | yes - absent |
| `/usr/share/foreman-proxy/.ssh` | foreman_proxy | SSH keys stored as podman secrets. Source files at `/root/foreman-proxy-ssh*`. | yes - absent |
| `/var/lib/foreman-proxy/ssh` | foreman_proxy | Same. | yes - absent |
| `/etc/smart_proxy_dynflow_core/settings.yml` | foreman_proxy | Proxy containerized; no host config files. | yes - absent |
| `/etc/sudoers.d/foreman-proxy` | foreman_proxy | Proxy runs in container, no sudo needed. | yes - absent |
| `/etc/candlepin/` | katello | Rendered templates → podman secrets. | yes - absent |
| `/etc/sysconfig/tomcat*`, `/etc/tomcat*` | katello | Tomcat inside candlepin container. Config via podman secrets. | yes - absent |
| `/etc/pulp/settings.py` | pulpcore | Pulp config via env vars. No settings file on host. | yes - absent |
| `/etc/pulp/certs/database_fields.symmetric.key` | pulpcore | Source file at `/var/lib/pulp/database_fields.symmetric.key` (host, bind-mounted). Secret derived from it. | yes - absent |
| `/etc/foreman/dynflow/` | dynflow_sidekiq | Dynflow in container; config via podman secrets. | yes - absent |
| `/etc/redis`, `/etc/redis.conf` | redis | Redis containerized. Config in image, data bind-mounted. | yes - absent |
| `/etc/mosquitto/` | mosquitto | Not implemented in foremanctl yet. MQTT (pull-mqtt REX mode) may be added later. | yes - absent |
| `/etc/puppet`, `/etc/puppetlabs`, puppet SSL dirs | puppet_server | BYOP — Satellite stops shipping Puppet RPMs in 6.19+ (SAT-31846). Customer-managed. How integration works is not yet designed (SAT-40445). | yes - absent |
| `/opt/puppetlabs/puppet/ssl/`, `/var/lib/puppet/ssl` | puppet_server | Same. | yes - absent |
| `/etc/salt/` | salt_server | Salt plugin not yet foremanctl-compatible. Will likely follow template → secret pattern. | yes - absent |
| `postgresql.conf` (direct file) | foreman_database | PostgreSQL containerized. Config via env vars and podman secrets. | yes - absent |
| `/etc/hammer/**/*.yml`, `~/.hammer/**/*.yml` | hammer | TBD. May still be backed up if present. | — |
| `/etc/selinux/targeted/contexts/files/file_contexts.subs` | foreman_server | Not managed by foremanctl. | yes - absent |
| `/etc/pki/katello/`, `/etc/pki/katello-certs-tools/` | katello | **These directories don't exist in foremanctl.** Certs are at `/etc/pki/httpd/` and `/root/certificates/`. | yes - absent |
| `/root/ssl-build/` | katello | **Doesn't exist in foremanctl.** Cert build artifacts are at `/root/certificates/`. | yes - absent |

## Chart 2: Files foremanctl SHOULD still backup (still on the host)

These paths exist on the host and need to be backed up.

| Path | foreman-maintain Feature | Status in foremanctl | Verified on live box |
|------|------------------------|----------------------|----------|
| `/etc/httpd/` (vhosts, SSL config) | apache, foreman_server | httpd is **not containerized** — runs as a host RPM. Includes `foreman.conf`, `foreman-ssl.conf`. | yes - httpd RPM installed |
| `/etc/pki/httpd/` (certs + keys) | katello | **New path** — replaces `/etc/pki/katello/`. Contains `katello-apache.crt`, `katello-server-ca.crt`, `katello-default-ca.crt`, `katello-apache.key`. | yes |
| `/var/www/html/pub/katello-server-ca.crt` | foreman_server | CA cert for client trust. | yes |
| `/root/certificates/` (CA, server, client certs + keys) | katello | **New path** — replaces `/root/ssl-build/`. foremanctl's cert generation output. | yes |
| `/root/candlepin.keystore`, `/root/candlepin.truststore` | katello | Generated from certs during deploy. | yes |
| `/root/foreman-proxy-ssh`, `/root/foreman-proxy-ssh.pub` | foreman_proxy | REX SSH keypair. Generated once. Losing these breaks REX to all registered hosts. | yes |
| `/var/lib/pulp/` (artifact storage + generated keys) | pulpcore | **Bind-mounted** directly from host. Contains content + `database_fields.symmetric.key` + `django_secret_key`. | yes - bind-mount confirmed |
| `/var/lib/pgsql/data/` | foreman_database | PostgreSQL data. Bind-mounted into postgresql container. | yes - bind-mount confirmed |
| `/var/lib/redis/` | redis | Bind-mounted as `/data` inside redis container. | yes - bind-mount confirmed |
| Foreman DB dump (`foreman`) | DB procedures | pg_dump via `podman exec postgresql` or one-shot container. | yes - DB exists, 22 MB |
| Candlepin DB dump (`candlepin`) | DB procedures | Same. | yes - DB exists, 12 MB |
| Pulpcore DB dump (`pulp`) | DB procedures | Same. | yes - DB exists, 17 MB |
| Custom certs (if user-provided) | katello | Paths specified at deploy time, stored in persisted parameters. | — |
| `/var/lib/tftpboot/` (if TFTP) | foreman_proxy (conditional) | On host, bind-mounted into proxy container if enabled. | — |
| `/var/named/`, `/etc/named*` (if DNS) | foreman_proxy (conditional) | DNS zones on host if enabled. | — |
| `/var/lib/dhcpd/` (if DHCP ISC) | foreman_proxy (conditional) | DHCP data on host if enabled. | — |
| `/usr/share/xml/scap/` (if OpenSCAP) | foreman_proxy (conditional) | SCAP content on host if enabled. | — |
| `/etc/ansible/` (if Ansible feature) | foreman_proxy (conditional) | Ansible config on host if enabled. | — |
| `/var/lib/candlepin/` | katello | Expected to be bind-mounted per [foremanctl#478](https://github.com/theforeman/foremanctl/issues/478). Currently only log dirs mounted. | yes - not mounted yet |
| `/var/log/candlepin/`, `/var/log/tomcat/` | katello | Log dirs bind-mounted into candlepin container. May want for sosreport/debugging. | yes |
| `/var/lib/containers/storage/volumes/iop-*` (if IoP) | iop (conditional) | IoP carries forward, potentially same container setup. | — |
| IoP database dumps (if IoP) | iop (conditional) | Same pg_dump approach. | — |

## Chart 3: NEW files/data foremanctl needs to backup (did not exist in foreman-maintain)

**Key insight: podman secrets do NOT need independent backup.** They are derived outputs — rendered from Jinja2 templates during `foremanctl deploy`. Backing up source inputs + a redeploy regenerates them.

### Source inputs that must be backed up

| What | Path | Why it's new | Verified on live box |
|------|------|--------------|----------|
| **foremanctl state directory** | `<foremanctl_install_dir>/.var/lib/foremanctl/` | Contains `parameters.yaml` (master config), generated credentials, deploy logs, `.installed` flag. Path is relative to foremanctl install dir — set via `OBSAH_STATE` env var. **Not** at `/var/lib/obsah/`. | yes |
| **`parameters.yaml`** | `<state_dir>/parameters.yaml` | Replaces foreman-installer answer files. Contains DB passwords, features, org, location, tuning, admin password. | yes |
| **Generated OAuth credentials** | `<state_dir>/foreman-oauth-consumer-key`, `<state_dir>/foreman-oauth-consumer-secret` | Generated once by Ansible's `password` lookup. Embedded in rendered settings.yaml secret. | yes, matches secret |
| **Pulp symmetric key** | `/var/lib/pulp/database_fields.symmetric.key` | Generated once with `openssl rand`. Encrypts Pulp DB fields — losing it = data loss. | yes |
| **Pulp Django secret key** | `/var/lib/pulp/django_secret_key` | Generated once with `openssl rand`. | yes |
| **Deploy state flag** | `<state_dir>/.installed` | Tracks whether initial deploy completed. | yes |
| **Deploy logs** | `<state_dir>/foremanctl.log`, `<state_dir>/foremanctl.*.log` | Ansible run logs. Useful for debugging, not critical for restore. | yes |

### Metadata (replaces RPM inventory)

| What | How to collect | Verified on live box |
|------|----------------|----------|
| **Container image inventory** | `podman images --format json` | yes - 6 images |
| **Container runtime state** (optional) | `podman ps --format json` | yes - 14 containers |

### What does NOT need backup (reproducible from above)

| What | Why | Verified on live box |
|------|-----|----------|
| **Podman secrets** (41 on test box) | Rendered from templates + parameters.yaml + generated credentials. `foremanctl deploy` recreates them. | yes - 41 secrets, all derived |
| **Quadlet unit files** (`/etc/containers/systemd/`) | Generated by Ansible. Includes `.container.d/` per-feature overrides. | yes - 19 .container files + 4 overrides |
| **Container images** | Re-pulled from registry. | yes |

### Restore approach

1. Install foremanctl on fresh host
2. Restore `<state_dir>/` (parameters + generated credentials)
3. Restore `/root/certificates/`, `/root/candlepin.keystore`, `/root/candlepin.truststore`
4. Restore `/root/foreman-proxy-ssh*`
5. Restore `/var/lib/pulp/` (content + keys)
6. Restore database dumps
7. Run `foremanctl deploy` — regenerates all podman secrets, quadlet files, httpd config, starts containers
8. Restore conditional data (TFTP, DNS, DHCP, etc.)
