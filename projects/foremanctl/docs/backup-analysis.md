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

### How podman secrets work in foremanctl

In foremanctl, most service config files are **not on the host filesystem**. Instead:

1. Jinja2 templates in Ansible roles are rendered using variables from `parameters.yaml` + defaults
2. The rendered output is stored as a **podman secret** (via `containers.podman.podman_secret`)
3. The secret is **mounted into the container** as a file (e.g., `type=mount,target=/etc/foreman/settings.yaml`)

Example: `foreman-settings-yaml` secret = rendered `settings.yaml.j2` template, mounted at `/etc/foreman/settings.yaml` inside the foreman container.

**Key insight: podman secrets are derived outputs, not source data.** They are fully reproducible from `parameters.yaml` + generated credential files + a `foremanctl deploy`. They do NOT need independent backup.

### Gone entirely — no longer exists on the host

| What | Why |
|------|-----|
| `/etc/foreman-installer/` (scenarios, answer files, custom-hiera.yaml) | **No installer.** Replaced by `<foremanctl_install_dir>/.var/lib/foremanctl/parameters.yaml`. |
| `/opt/puppetlabs/puppet/cache/foreman_cache_data` | foreman-installer's Puppet agent cache — not related to BYOP. |
| `/opt/puppetlabs/puppet/cache/pulpcore_cache_data` | Same. |
| `/etc/sysconfig/foreman` | Foreman runs in a container; env vars set via quadlet. |
| `/usr/share/ruby/vendor_ruby/puppet/reports/foreman.rb` | No Puppet on host. Report processor lives in the container image. |
| `/var/lib/foreman/` | App lives in container image. Only `/var/run/foreman` is volume-mounted (`foreman-data-run`). |
| `/etc/foreman/` (settings.yaml, plugins/, dynflow/, certs) | Rendered from templates → podman secrets → mounted into containers. Reproducible from `parameters.yaml`. |
| `/etc/foreman-proxy/` | Same — rendered templates → podman secrets. |
| `/usr/share/foreman-proxy/.ssh`, `/var/lib/foreman-proxy/ssh` | SSH keys stored as podman secrets. Source files at `/root/foreman-proxy-ssh*` (see "still on host"). |
| `/etc/smart_proxy_dynflow_core/settings.yml` | Proxy containerized; no host config files. |
| `/etc/sudoers.d/foreman-proxy` | Proxy runs in container, no sudo needed. |
| `/etc/candlepin/` | Rendered templates → podman secrets. |
| `/etc/sysconfig/tomcat*`, `/etc/tomcat*` | Tomcat runs inside candlepin container. Config via podman secrets. |
| `/etc/pulp/settings.py` | Pulp config injected via env vars. No settings file on host. |
| `/etc/foreman/dynflow/` | Dynflow runs in container; config via podman secrets. |
| `/etc/redis`, `/etc/redis.conf` | Redis containerized. Config in image, data dir bind-mounted. |
| `/etc/mosquitto` | Mosquitto not implemented in foremanctl yet. MQTT may be added later. |
| Puppet server paths (`/etc/puppet`, `/etc/puppetlabs`, SSL dirs) | BYOP — Satellite stops shipping Puppet RPMs in 6.19+ (SAT-31846). Customer-managed. How integration works is not yet designed (SAT-40445). |
| Salt paths (`/etc/salt`) | Salt plugin not yet compatible with foremanctl. Once supported, will likely follow the same template → secret pattern. |
| `postgresql.conf` (direct file) | PostgreSQL containerized. Config via env vars and podman secrets. |
| `/etc/selinux/targeted/contexts/files/file_contexts.subs` | Not managed by foremanctl. |

### Still exists on the host

| What | Status in foremanctl |
|------|---------------------|
| `/etc/httpd/` | **httpd is NOT containerized** — runs on the host as an RPM. Apache config, vhosts, SSL certs all still on host. |
| `/var/www/html/pub/katello-*` | Still on host (httpd pub dir). |
| `/etc/pki/httpd/, /root/certificates/` | Certs managed by foremanctl cert roles. Still on host. |
| `/var/lib/pulp/` | **Bind-mounted** from host into pulp containers (`/var/lib/pulp:/var/lib/pulp`). Also contains generated keys (`database_fields.symmetric.key`, `django_secret_key`). |
| `/var/lib/candlepin/` | Expected to be on host FS via bind mount ([foremanctl#478](https://github.com/theforeman/foremanctl/issues/478)). Not mounted yet but planned. |
| PostgreSQL data | Host directory mounted into container. Still needs backup (pg_dump). |
| `/var/lib/redis/` | Bind-mounted into redis container (`/var/lib/redis:/data:Z`). |
| `/var/lib/containers/storage/volumes/iop-*` | IoP carries forward into containerized Satellite, potentially as the same container setup. |
| `/root/candlepin.keystore`, `/root/candlepin.truststore` | Generated from certs during deploy. On host filesystem. |
| `/root/foreman-proxy-ssh`, `/root/foreman-proxy-ssh.pub` | REX SSH keypair generated on first deploy. On host filesystem. |

### New — did not exist in foreman-maintain

| What | Path | Why |
|------|------|-----|
| **foremanctl persisted parameters** | `<foremanctl_install_dir>/.var/lib/foremanctl/parameters.yaml` | The master config file. Replaces foreman-installer answer files. Contains all deploy-time params. |
| **Generated credential files** | `<state_dir>/foreman-admin-init-passwd (does not exist if password set in parameters.yaml)`, `foreman-oauth-consumer-key`, `foreman-oauth-consumer-secret` | Generated once by Ansible's `password` lookup. Cannot be regenerated. |
| **obsah state flag** | `<state_dir>/.installed` | Tracks whether initial deploy completed. |
| **Pulp generated keys** | `/var/lib/pulp/database_fields.symmetric.key`, `/var/lib/pulp/django_secret_key` | Generated once with `openssl rand`. The symmetric key encrypts Pulp DB fields — losing it = data loss. |
| **Container image inventory** | `podman images --format json` | Replaces RPM inventory (`rpm -qa`). Need image names, tags, digests. |

### What does NOT need backup (reproducible)

| What | Why |
|------|----|
| **Podman secrets** | All are rendered from Jinja2 templates + `parameters.yaml` + generated credential files. A `foremanctl deploy` recreates them. |
| **Quadlet unit files** (`/etc/containers/systemd/*.container`) | Generated by Ansible during deploy. Recreated from `parameters.yaml`. |
| **Container images** | Re-pulled from registry using image inventory metadata. |

---

## Summary: foremanctl backup needs

1. **`<foremanctl_install_dir>/.var/lib/foremanctl/`** — the master config + generated credentials. This is the new "answer file."
2. **Certificate files** — `/etc/pki/httpd/ (was /etc/pki/katello/ in foreman-maintain)`, `/root/certificates/ (was /root/ssl-build/ in foreman-maintain)`, `/root/candlepin.keystore`, `/root/candlepin.truststore`, `/root/foreman-proxy-ssh*`
3. **Host-level config** — `/etc/httpd/` (not containerized), `/var/www/html/pub/`
4. **Database dumps** — Foreman, Candlepin, Pulpcore (same pg_dump approach, connection info from `parameters.yaml`)
5. **Pulp content + keys** — `/var/lib/pulp/` (includes artifact storage and generated keys)
6. **Conditional data** — TFTP, DNS, DHCP, OpenSCAP, Ansible (same as foreman-maintain)
7. **Metadata** — container image inventory replaces RPM inventory

**Restore approach**: restore source files → `foremanctl deploy` → all secrets/quadlets/containers are regenerated.

---

## Source references

- foreman-maintain backup scenario: `definitions/scenarios/backup.rb`
- foreman-maintain config file collection: `definitions/procedures/backup/config_files.rb`
- foreman-maintain feature config_files methods: `definitions/features/*.rb`
- foreman-maintain backup metadata: `definitions/procedures/backup/metadata.rb`
- foremanctl container definitions: `src/roles/*/tasks/main.yaml` (or `main.yml`)
- foremanctl parameters persistence: obsah framework, default `<foremanctl_install_dir>/.var/lib/foremanctl/parameters.yaml`
- foremanctl credential generation: `src/vars/foreman.yml` (Ansible `password` lookup)
- foremanctl Pulp key generation: `src/roles/pulp/tasks/main.yaml` (`openssl rand`)
