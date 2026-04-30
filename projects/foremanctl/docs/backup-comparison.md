# Backup Comparison: foreman-maintain vs foremanctl

Three charts comparing what foreman-maintain backs up vs what foremanctl needs.

## Chart 1: Files foremanctl should NOT backup (no longer exist)

These paths are backed up by foreman-maintain today but do not exist on a containerized foremanctl host. They should be dropped from any future backup implementation.

| Path | foreman-maintain Feature | Why it's gone in foremanctl |
|------|------------------------|-----------------------------|
| `/etc/foreman-installer/` (scenarios, answer files, custom-hiera.yaml) | installer | No foreman-installer. foremanctl uses Ansible roles + persisted parameters. |
| `/opt/puppetlabs/puppet/cache/foreman_cache_data` | installer | No Puppet agent on the host. |
| `/opt/puppetlabs/puppet/cache/pulpcore_cache_data` | installer | No Puppet agent on the host. |
| `/etc/sysconfig/foreman` | foreman_server | Foreman runs in a container; env vars set via quadlet + podman secrets. |
| `/usr/share/ruby/vendor_ruby/puppet/reports/foreman.rb` | foreman_server, puppet_server | No Puppet on host. Report processor lives in the container image. |
| `/var/lib/foreman/` | foreman_server | App data lives inside the container image. Only a run dir (`foreman-data-run`) is volume-mounted. |
| `/etc/foreman/` (settings.yaml, plugins/, dynflow/, certs) | foreman_server, dynflow_sidekiq | All config is injected via podman secrets, not host files. |
| `/etc/foreman-proxy/` | foreman_proxy | Proxy is containerized. Config injected via podman secrets. |
| `/usr/share/foreman-proxy/.ssh` | foreman_proxy | SSH keys are podman secrets (`foreman_proxy-remote_execution_ssh-*`). |
| `/var/lib/foreman-proxy/ssh` | foreman_proxy | Same — moved to podman secrets. |
| `/etc/smart_proxy_dynflow_core/settings.yml` | foreman_proxy | Proxy containerized; no host config files. |
| `/etc/sudoers.d/foreman-proxy` | foreman_proxy | Proxy runs in container, no sudo needed. |
| `/etc/candlepin/` | katello | Candlepin is containerized. All config via podman secrets (`candlepin-candlepin-conf`, etc.). |
| `/etc/sysconfig/tomcat*`, `/etc/tomcat*` | katello | Tomcat runs inside the candlepin container. Config via podman secrets. |
| `/var/lib/candlepin/` | katello | Candlepin data lives in the container. |
| `/etc/pulp/settings.py` | pulpcore | Pulp is containerized. Settings injected via env vars and podman secrets. |
| `/etc/pulp/certs/database_fields.symmetric.key` | pulpcore | Moved to podman secret (`pulp-symmetric-key`). |
| `/etc/foreman/dynflow/` | dynflow_sidekiq | Dynflow runs in container; config baked in or via secrets. |
| `/etc/redis`, `/etc/redis.conf` | redis | Redis is containerized. Data dir bind-mounted, but config is in the image. |
| `/etc/mosquitto/` | mosquitto | Mosquitto is containerized. |
| `/etc/puppet`, `/etc/puppetlabs`, puppet SSL dirs | puppet_server | Puppet server is optional/TBD in containerized model. |
| `/opt/puppetlabs/puppet/ssl/`, `/var/lib/puppet/ssl` | puppet_server | Same. |
| `/etc/salt/` | salt_server | Salt not yet supported in containerized model. |
| `/var/lib/containers/storage/volumes/iop-*` | iop | IoP is Satellite-specific; unclear if it carries forward. |
| `postgresql.conf` (direct file) | foreman_database | PostgreSQL is containerized. Config via env vars and podman secrets. |
| `/etc/hammer/**/*.yml`, `~/.hammer/**/*.yml` | hammer | Hammer is an RPM on the host but its config is TBD. May still be backed up if present. |
| `/etc/selinux/targeted/contexts/files/file_contexts.subs` | foreman_server | Not managed by foremanctl. |

## Chart 2: Files foremanctl SHOULD still backup (still on the host)

These paths still exist on the host in a containerized deployment and need to be backed up, similar to how foreman-maintain handles them.

| Path | foreman-maintain Feature | Status in foremanctl |
|------|------------------------|----------------------|
| `/etc/httpd/` (vhosts, SSL config, modules) | apache, foreman_server | httpd is **not containerized** — runs as a host RPM. Must still backup. |
| `/var/www/html/pub/katello-*` | foreman_server | CA cert published for client trust. Still on the host. |
| `/etc/pki/katello/` | katello | Certs managed by foremanctl cert roles. Still on host filesystem. |
| `/etc/pki/katello-certs-tools/` | katello | Same. |
| `/etc/pki/ca-trust/` | katello | System CA trust store. Still on host. |
| `/root/ssl-build/` | katello | Certificate build artifacts. Still on host. |
| `/var/lib/pulp/` (artifact storage) | pulpcore (via Pulp procedure) | **Bind-mounted** directly from host into pulp containers. Same backup approach works. |
| PostgreSQL data directory | foreman_database (via DB dump procedures) | Host directory mounted into postgresql container. Backup via `pg_dump` as before. |
| `/var/lib/redis/` (data dir) | redis | Bind-mounted into redis container (`/var/lib/redis:/data:Z`). |
| Foreman DB dump | Online/Offline DB procedures | Same `pg_dump` approach. Connection string comes from podman secret now. |
| Candlepin DB dump | Online/Offline DB procedures | Same. |
| Pulpcore DB dump | Online/Offline DB procedures | Same. |
| Custom certs (if user-provided) | katello (from installer answers) | Paths specified at deploy time. foremanctl stores the source paths in persisted parameters. |
| `/var/lib/tftpboot/` (if TFTP enabled) | foreman_proxy (conditional) | TFTP content is on the host, bind-mounted into proxy container. Still needs backup if enabled. |
| `/var/named/`, `/etc/named*` (if DNS enabled) | foreman_proxy (conditional) | DNS zones are on the host. Still needs backup if enabled. |
| `/var/lib/dhcpd/`, dhcpd config (if DHCP ISC) | foreman_proxy (conditional) | DHCP data is on the host. Still needs backup if enabled. |
| `/usr/share/xml/scap/` (if OpenSCAP) | foreman_proxy (conditional) | SCAP content is on the host. Still needs backup if enabled. |
| `/etc/ansible/` (if Ansible feature) | foreman_proxy (conditional) | Ansible config is on the host. Still needs backup if enabled. |

## Chart 3: NEW files/data foremanctl needs to backup (did not exist in foreman-maintain)

These are new to the containerized architecture. foreman-maintain had no equivalent because these concepts didn't exist.

| What to backup | How to collect | Why it's new |
|----------------|----------------|--------------|
| **All podman secrets** | `podman secret ls` + `podman secret inspect --showsecret` | Config files (settings.yaml, candlepin.conf, etc.), certs, keys, and passwords are now stored as podman secrets instead of host files. This is the single biggest change. |
| **Podman secret list (Foreman)** | `foreman-database-url`, `foreman-settings-yaml`, `foreman-katello-yaml`, `foreman-ca-cert`, `foreman-client-cert`, `foreman-client-key`, `foreman-db-ca`, `foreman-seed-admin-user`, `foreman-seed-admin-password` | Foreman app config + certs + DB connection string. |
| **Podman secret list (Candlepin)** | `candlepin-ca-cert`, `candlepin-ca-key`, `candlepin-tomcat-keystore`, `candlepin-tomcat-truststore`, `candlepin-candlepin-conf`, `candlepin-artemis-broker-xml`, `candlepin-tomcat-server-xml`, `candlepin-tomcat-conf`, `candlepin-artemis-login-config`, `candlepin-artemis-cert-roles-properties`, `candlepin-artemis-cert-users-properties`, `candlepin-artemis-jaas-conf`, `candlepin-db-ca` | 13 secrets for Candlepin config, certs, keystores, and Artemis messaging. |
| **Podman secret list (Pulp)** | `pulp-symmetric-key`, `pulp-db-password`, `pulp-db-ca`, `pulp-django-secret-key` | Pulp encryption key, DB credentials, Django secret. |
| **Podman secret list (Foreman Proxy)** | `foreman-proxy-settings-yml`, `foreman-proxy-ssl-ca`, `foreman-proxy-ssl-cert`, `foreman-proxy-ssl-key`, `foreman-proxy-foreman-ssl-ca`, `foreman-proxy-foreman-ssl-cert`, `foreman-proxy-foreman-ssl-key`, plus per-feature: `foreman-proxy-<feature>-yml`, `foreman_proxy-remote_execution_ssh-*` | Proxy config + SSL + per-feature settings and SSH keys. |
| **Podman secret list (PostgreSQL)** | `postgresql-admin-password`, optional: `postgresql-ssl-crt`, `postgresql-ssl-key`, `postgresql-ssl-conf` | DB admin password and optional SSL config. |
| **foremanctl persisted parameters** | `/var/lib/obsah/parameters.yaml` (default path, may be overridden via `OBSAH_STATE` env var) | Replaces foreman-installer answer files. Contains all deploy-time parameters (features, org, location, cert paths, tuning, etc.). |
| **Quadlet unit files** | `/etc/containers/systemd/*.container`, `/etc/containers/systemd/*.container.d/` override dirs | Systemd quadlet definitions that define how each container runs (image, volumes, secrets, env vars, dependencies). |
| **Container image inventory** | `podman images --format json` or equivalent | Replaces RPM inventory. Need to record image names, tags, and digests for each service to enable restore to the same versions. |
| **Container runtime state** (optional) | `podman ps --format json` | May be useful for metadata: which containers were running, health status, restart counts. |

### Notes

- **Approach**: Rather than selectively backing up known secrets, the safest approach may be to back up ALL podman secrets (`podman secret ls` → iterate and export each). This is forward-compatible as new features add new secrets.
- **Encryption**: Podman secrets are stored under `/var/lib/containers/storage/secrets/` (rootful) or `~/.local/share/containers/storage/secrets/` (rootless). Backing up this directory wholesale is another option, but `podman secret inspect --showsecret` is the supported API.
- **Quadlet files are generated**: They're created by Ansible during `foremanctl deploy`. They could be regenerated from parameters.yaml, but backing them up preserves the exact running state including any manual `.container.d/` overrides.
