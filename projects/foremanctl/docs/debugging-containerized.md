# Foremanctl Environment - Debugging Guide

Quick reference for debugging containerized Foreman/Katello deployed by foremanctl.
Source: https://gist.github.com/sjha4/2cb92057ad25298d5acaff5110577ff0

## Quick Reference

```bash
# All services status
systemctl list-units --type=service --state=running | grep -E "(postgresql|pulp|foreman|redis|candlepin)"
podman ps

# All container logs
journalctl -f -u postgresql -u pulp-api -u pulp-content -u candlepin

# Database access
podman exec -it postgresql psql -U postgres
podman exec -it postgresql psql -U foreman -d foreman
podman exec -it postgresql psql -U pulp -d pulp
podman exec -it postgresql psql -U candlepin -d candlepin

# Secrets
podman secret ls
podman secret inspect --showsecret <name> --format "{{.SecretData}}"

# Quadlet files
ls -la /etc/containers/systemd/
cat /etc/containers/systemd/postgresql.container

# Service restart order: postgresql → redis → pulp-api, pulp-content, pulp-worker → candlepin → foreman
```

## Architecture

- All backend services run as **Podman containers managed by systemd** (quadlets)
- Network mode: `host` — all containers communicate via localhost
- Service management via systemd units generated from `.container` files in `/etc/containers/systemd/`

## Services

| Service | Port | Container |
|---------|------|-----------|
| PostgreSQL | 5432 | postgresql |
| Redis | 6379 | redis |
| Pulp API | 24817 | pulp-api |
| Pulp Content | 24816 | pulp-content |
| Pulp Workers | — | pulp-worker@1-N |
| Candlepin | 23443 (HTTPS) | candlepin |
| Foreman | 3000 (dev) / 443 (prod) | foreman |

## Database Access

```bash
# PostgreSQL admin
podman exec -it postgresql psql -U postgres

# List databases
podman exec postgresql psql -U postgres -l

# Database sizes
podman exec postgresql psql -U postgres -c "SELECT pg_database.datname, pg_size_pretty(pg_database_size(pg_database.datname)) AS size FROM pg_database;"

# Active connections
podman exec postgresql psql -U postgres -c "SELECT datname, count(*) FROM pg_stat_activity GROUP BY datname;"
```

Default credentials (from `src/vars/database.yml`): all passwords are `CHANGEME` unless overridden via `parameters.yaml`.

## Podman Secrets

```bash
# List all secrets
podman secret ls

# View secret content
podman secret inspect --showsecret postgresql-admin-password --format "{{.SecretData}}"
podman secret inspect --showsecret candlepin-candlepin-conf --format "{{.SecretData}}"

# Naming convention:
#   Config files: <service>-<filename>-<extension>
#   Credentials: <service>-<descriptive-name>
```

## Quadlet Files

Located in `/etc/containers/systemd/`:

```bash
ls -la /etc/containers/systemd/
# postgresql.container, pulp-api.container, pulp-content.container,
# pulp-worker@.container, candlepin.container, redis.container,
# foreman.container, dynflow-sidekiq@.container, foreman-proxy.container

# Override dirs for per-feature config
ls /etc/containers/systemd/*.container.d/
```

After modifying: `systemctl daemon-reload && systemctl restart <service>`

## Pulp Debugging

```bash
# API status
curl http://localhost:24817/pulp/api/v3/status/

# Django shell
podman exec -it pulp-api pulpcore-manager shell

# Check migrations
podman exec pulp-api pulpcore-manager showmigrations

# Worker status
systemctl status 'pulp-worker@*'
```

## Candlepin Debugging

```bash
# API status
curl --insecure https://localhost:23443/candlepin/status

# Logs
journalctl -u candlepin -f
cat /var/log/candlepin/candlepin.log
```

## Storage Locations

| Path | Purpose |
|------|---------|
| `/var/lib/obsah/` | foremanctl persisted parameters + generated credentials |
| `/var/lib/pulp/` | Pulp content storage (bind-mounted into containers) |
| `/var/lib/redis/` | Redis data (bind-mounted) |
| `/etc/containers/systemd/` | Quadlet container definitions |
| `/etc/pki/katello/` | SSL certificates |
| `/root/ssl-build/` | Certificate build artifacts |
| `/etc/httpd/` | Apache config (not containerized) |

## Health Checks

```bash
# All services active?
systemctl is-active postgresql pulp-api pulp-content candlepin redis foreman

# Database reachable?
podman exec postgresql pg_isready

# Foreman API?
curl -k https://localhost/api/v2/ping

# Pulp API?
curl http://localhost:24817/pulp/api/v3/status/
```
