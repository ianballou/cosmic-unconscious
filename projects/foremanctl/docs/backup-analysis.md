# Backup Analysis: foreman-maintain vs foremanctl

What foreman-maintain backs up today and what changes in the containerized foremanctl world.

## What foreman-maintain backup collects today

The backup scenario (`definitions/scenarios/backup.rb`) has three main components plus metadata.

### 1. Config files (`config_files.tar.gz`)

Each "feature" contributes its config paths via `config_files` methods:

| Feature | Paths backed up |
|---------|----------------|
| **installer** | `/etc/foreman-installer/` (scenarios, answer files, custom-hiera.yaml), `/opt/puppetlabs/puppet/cache/foreman_cache_data`, `/opt/puppetlabs/puppet/cache/pulpcore_cache_data`, answer file |
| **foreman_server** | `/etc/httpd/`, `/var/www/html/pub/katello-*`, `/etc/foreman/`, `/etc/selinux/targeted/contexts/files/file_contexts.subs`, `/etc/sysconfig/foreman`, `/usr/share/ruby/vendor_ruby/puppet/reports/foreman.rb`, `/var/lib/foreman/` (excl `/var/lib/foreman/public`) |
| **foreman_database** | `postgresql.conf` (on EL) |
| **foreman_proxy** | `/etc/foreman-proxy/`, `/usr/share/foreman-proxy/.ssh`, `/var/lib/foreman-proxy/ssh`, `/etc/smart_proxy_dynflow_core/settings.yml`, `/etc/sudoers.d/foreman-proxy`, certs tarball, plus feature-conditional: tftp (`/var/lib/tftpboot`), dns (`/var/named/`, `/etc/named*`), dhcp (`/var/lib/dhcpd`, dhcpd config), openscap (`/usr/share/xml/scap`), ansible (`/etc/ansible`) |
| **katello** | `/etc/pki/katello`, `/etc/pki/katello-certs-tools`, `/etc/pki/ca-trust`, `/root/ssl-build`, `/etc/candlepin`, `/etc/sysconfig/tomcat*`, `/etc/tomcat*`, `/var/lib/candlepin` (excl `activemq-artemis` for online), custom certs from installer answers |
| **apache** | `/etc/httpd` (EL) or `/etc/apache2` (Debian) |
| **pulpcore** | `/etc/pulp/settings.py`, `/etc/pulp/certs/database_fields.symmetric.key` |
| **hammer** | `/etc/hammer/**/*.yml`, `~/.hammer/**/*.yml` (dynamically discovered) |
| **dynflow_sidekiq** | `/etc/foreman/dynflow/` |
| **puppet_server** | `/etc/puppet`, `/etc/puppetlabs`, puppet SSL dirs, foreman report processor |
| **redis** | `/etc/redis`, `/etc/redis.conf` |
| **mosquitto** | `/etc/mosquitto` |
| **salt_server** | `/etc/salt` |
| **iop** | `/var/lib/containers/storage/volumes/iop-core-kafka-data`, `iop-service-vmaas-data` |

### 2. Database dumps

- Foreman DB (pg_dump)
- Candlepin DB (pg_dump)
- Pulpcore DB (pg_dump)
- IoP databases x5 (if present)

### 3. Pulp content (`pulp_data.tar`)

- `/var/lib/pulp/*` (the actual artifact storage)

### 4. Metadata (`metadata.yml`)

- OS version
- Installed RPMs/debs (full `rpm -qa` / `dpkg -l`)
- Plugin list (from `foreman-rake plugin:list`)
- Proxy features
- Proxy config (dns/dhcp interface settings from installer answers)
- Hostname
- Incremental/online flags

---

## What disappears or changes in containerized foremanctl

### 🚫 Gone entirely — no longer exists on the host

| What | Why |
|------|-----|
| `/etc/foreman-installer/` (scenarios, answer files, custom-hiera.yaml) | **No installer.** foremanctl uses persisted parameters + Ansible roles instead. This is the biggest conceptual change. |
| `/opt/puppetlabs/puppet/cache/foreman_cache_data` | Puppet cache doesn't exist — no Puppet agent runs on the host |
| `/opt/puppetlabs/puppet/cache/pulpcore_cache_data` | Same |
| `/etc/sysconfig/foreman` | Foreman runs in a container; env vars are set via quadlet + podman secrets |
| `/usr/share/ruby/vendor_ruby/puppet/reports/foreman.rb` | No Puppet on host |
| `/var/lib/foreman/` | App lives in the container image; only `/var/run/foreman` is mounted as a volume (`foreman-data-run`) |
| `/etc/smart_proxy_dynflow_core/settings.yml` | Smart proxy is containerized; no host config files |
| `/etc/sudoers.d/foreman-proxy` | Proxy runs in container, no sudo needed |
| `/etc/foreman/dynflow/` | Dynflow sidekiq runs in a container with config baked in or via secrets |
| `/etc/selinux/targeted/contexts/files/file_contexts.subs` | Not managed |
| Puppet server paths (`/etc/puppet`, `/etc/puppetlabs`, SSL dirs) | Puppet server is optional/TBD in containerized model |
| Salt paths (`/etc/salt`) | Not containerized yet |
| `/etc/redis`, `/etc/redis.conf` | Redis runs in container; data at `/var/lib/redis:/data:Z` |
| `/etc/mosquitto` | Mosquitto is containerized (no visible volume mounts) |
| IoP volume paths | IoP is Satellite-specific, unclear if it carries forward |

### ✅ Still exists on the host (but possibly in different form)

| What | Status in foremanctl |
|------|---------------------|
| `/etc/httpd/` | **httpd is NOT containerized** — it runs on the host as an RPM. Apache config, vhosts, SSL certs all still on the host. |
| `/var/www/html/pub/katello-*` | Still on host (httpd pub dir) |
| `/etc/pki/katello*`, `/etc/pki/ca-trust`, `/root/ssl-build` | Certs are managed by foremanctl cert roles. Still on host. |
| `/var/lib/pulp/` | **Bind-mounted directly** from host into pulp containers (`/var/lib/pulp:/var/lib/pulp`). Still needs backup. |
| PostgreSQL data | Host directory `postgresql_data_dir` mounted into container. Still needs backup (pg_dump). |

### 🔄 Moved to Podman secrets (new backup paradigm)

This is the big shift. In foremanctl, most config files are stored as **Podman secrets** rather than files on disk:

| Service | Podman Secrets (examples) |
|---------|--------------------------|
| **Foreman** | `foreman-database-url`, `foreman-settings-yaml`, `foreman-katello-yaml`, `foreman-ca-cert`, `foreman-client-cert`, `foreman-client-key`, `foreman-db-ca`, seed admin user/password |
| **Candlepin** | `candlepin-ca-cert`, `candlepin-ca-key`, `candlepin-tomcat-keystore`, `candlepin-candlepin-conf`, `candlepin-artemis-broker-xml`, `candlepin-tomcat-server-xml`, etc. (12+ secrets) |
| **Pulp** | `pulp-symmetric-key`, `pulp-db-password`, `pulp-db-ca`, `pulp-django-secret-key` |
| **Foreman Proxy** | `foreman-proxy-settings-yml`, SSL certs/keys (7 secrets), plus per-feature secrets |
| **PostgreSQL** | `postgresql-admin-password`, optional SSL cert/key/conf |

These secrets **would not be caught by a traditional file-based backup**. A containerized backup needs `podman secret ls` + `podman secret inspect` to enumerate and capture them.

### 📝 Metadata changes

| Old (foreman-maintain) | New (foremanctl) |
|------------------------|------------------|
| Installed RPMs (`rpm -qa`) | Very few host RPMs. Container images are the "packages" now. Need image IDs/tags instead. |
| Plugin list (`foreman-rake plugin:list`) | Exec into foreman container or read `FOREMAN_ENABLED_PLUGINS` env var |
| Proxy features | Read from foremanctl feature config, or exec into proxy container |
| Proxy config from installer answers | No installer answers. Read from foremanctl's persisted parameters. |

---

## Summary: what foremanctl backup needs to account for

1. **Podman secrets are the new config files** — this is the single biggest difference. Backup must enumerate and capture all `podman secret` values.
2. **No `/etc/foreman-installer/`** — foremanctl's equivalent is its persisted parameters (wherever obsah stores them). The "answer file" concept is replaced.
3. **Host-level config is mostly just httpd and certs** — Apache vhosts, SSL certs under `/etc/pki/katello*`, `/root/ssl-build` still need traditional file backup.
4. **Database dumps are largely the same** — PostgreSQL, Candlepin DB, Pulpcore DB all still exist and need pg_dump. Connection details come from secrets now.
5. **Pulp content is the same** — `/var/lib/pulp` is bind-mounted, same backup approach works.
6. **Container image inventory replaces RPM inventory** — metadata needs to record which images/tags are deployed.
7. **No Puppet cache, no SCL paths, no systemd sysconfig overrides** — big simplification.

---

## Source references

- foreman-maintain backup scenario: `definitions/scenarios/backup.rb`
- foreman-maintain config file collection: `definitions/procedures/backup/config_files.rb`
- foreman-maintain feature config_files methods: `definitions/features/*.rb`
- foreman-maintain backup metadata: `definitions/procedures/backup/metadata.rb`
- foremanctl container definitions: `src/roles/*/tasks/main.yaml` (or `main.yml`)
- foremanctl parameters: persisted by obsah framework
