# Live VM Testing (Production / Packaged Environments)

Testing and interacting with Foreman/Katello/Satellite on forklift vagrant boxes, Satellite QA boxes, or any RPM-installed (production-like) VM.

> **Scope:** This doc covers **production/packaged** environments where Foreman and Katello are installed via RPMs, services run under systemd, and tools like `foreman-rake` and `satellite-maintain` are available. Development environments (source checkouts, `bundle exec`, Puma via CLI) work differently and are not covered here.

## Connecting to a VM

### Forklift Vagrant Boxes
VMs managed by forklift live in `~/forklift`, managed by vagrant.

```bash
# SSH into a box
cd ~/forklift && vagrant ssh <box-name>

# Get SSH config (hostname, IP, key path)
cd ~/forklift && vagrant ssh-config <box-name>

# Direct SSH with the vagrant key
ssh -i .vagrant/machines/<box-name>/libvirt/private_key vagrant@<ip>
```

Nightly boxes (e.g., `centos9-stream-katello-nightly`) track the latest nightly RPMs.

**Downgrades are not possible.** Once you upgrade, you cannot roll back. Plan accordingly.

### Running Commands from the Host
You can run one-off commands without an interactive session:

```bash
cd ~/forklift && vagrant ssh <box-name> -c "sudo hammer ping"
```

For any VM accessible via SSH:
```bash
ssh -i /path/to/key vagrant@<ip> "sudo hammer ping"
```

## Hammer CLI

Hammer is the primary CLI tool for interacting with Foreman/Katello/Satellite.

### Credentials
Hammer credentials are stored in `/root/.hammer/cli.modules.d/foreman.yml` on the VM:
```yaml
:foreman:
  :username: 'admin'
  :password: 'changeme'
```

With `sudo`, hammer reads root's config and authenticates automatically. Without sudo, pass credentials explicitly:
```bash
hammer -u admin -p changeme organization list
```

### Common Operations

```bash
# Health check -- pings all services (DB, candlepin, pulp, redis, tasks)
sudo hammer ping

# List organizations
sudo hammer organization list

# List products and repositories
sudo hammer product list --organization-id 1
sudo hammer repository list --organization-id 1

# Content workflow: create product, repo, sync
sudo hammer product create --organization-id 1 --name 'Test Product'
sudo hammer repository create \
  --organization-id 1 \
  --product 'Test Product' \
  --name 'Test Repo' \
  --content-type yum \
  --url 'https://fixtures.pulpproject.org/rpm-unsigned/'
sudo hammer repository synchronize \
  --organization-id 1 \
  --product 'Test Product' \
  --name 'Test Repo' \
  --async

# Check task status
sudo hammer task list --search 'label=Actions::Katello::Repository::Sync'

# Cleanup
sudo hammer repository delete --organization-id 1 --product 'Test Product' --name 'Test Repo'
sudo hammer product delete --organization-id 1 --name 'Test Product'
```

## REST API

The Foreman/Katello API is available over HTTPS on the VM. It is also accessible remotely from any host that can reach the VM's IP.

### From the VM
```bash
curl -sk -u admin:changeme https://localhost/api/v2/status
curl -sk -u admin:changeme https://localhost/katello/api/v2/ping
```

### From the Host (Remote)
```bash
# Use the VM's IP (from vagrant ssh-config or similar)
curl -sk -u admin:changeme https://<vm-ip>/api/v2/status
curl -sk -u admin:changeme https://<vm-ip>/katello/api/v2/repositories?organization_id=1
```

### Key API Endpoints

| Endpoint | Description |
|---|---|
| `/api/v2/status` | Server version and status |
| `/katello/api/v2/ping` | Service health (candlepin, pulp, tasks) |
| `/api/v2/hosts` | Registered hosts |
| `/katello/api/v2/repositories` | Content repositories |
| `/katello/api/v2/content_views` | Content views |
| `/katello/api/v2/products` | Products |
| `/api/v2/organizations` | Organizations |
| `/pulp/api/v3/status/` | Pulp 3 status (component versions) |

### API Notes
- Always use `-sk` with curl (self-signed certs, suppress progress).
- Default admin credentials on forklift boxes: `admin` / `changeme`.
- API responses are JSON. Pipe through `python3 -m json.tool` for readability.
- Pagination: responses include `total`, `subtotal`, `page`, `per_page`. Use `?per_page=100` for larger result sets.

## Rails Console

Run one-off Ruby commands or start an interactive console on the VM:

```bash
# Interactive console
sudo foreman-rake console

# One-liner (pipe a command)
echo 'puts Katello::Repository.count' | sudo foreman-rake console

# Multi-line
sudo foreman-rake console <<'EOF'
Katello::Product.all.each { |p| puts "#{p.id}: #{p.name}" }
EOF
```

### Useful Console Queries

```ruby
# Count resources
Katello::Repository.count
Katello::ContentView.count

# List products
Katello::Product.pluck(:id, :name)

# Find a task
ForemanTasks::Task.where(label: 'Actions::Katello::Repository::Sync').last

# Check Pulp status
Katello::Pulp3::Api::Core.new(SmartProxy.pulp_primary).api_client
```

## Satellite-Maintain / Foreman-Maintain

The maintenance tool is `satellite-maintain` on Satellite or `foreman-maintain` on upstream Foreman. It wraps common administrative operations.

```bash
# Service management
sudo satellite-maintain service status      # Check all services
sudo satellite-maintain service restart     # Restart all services
sudo satellite-maintain service list        # List managed services

# Health checks
sudo satellite-maintain health check        # Run all health checks
sudo satellite-maintain health check -y     # Auto-answer yes

# Backup
sudo satellite-maintain backup offline /tmp/backup    # Offline backup
sudo satellite-maintain backup online /tmp/backup     # Online backup

# Upgrade
sudo satellite-maintain upgrade check --target-version <version>
sudo satellite-maintain upgrade run --target-version <version>
```

### Managed Services
The tool manages these services (varies by installation):
- `redis`, `postgresql`
- `pulpcore-api`, `pulpcore-content`, `pulpcore-worker@*`
- `tomcat` (candlepin)
- `dynflow-sidekiq@orchestrator`, `dynflow-sidekiq@worker-*`
- `foreman`, `httpd`, `foreman-proxy`

## Foreman-Rake Tasks

```bash
# List katello-related rake tasks
sudo foreman-rake -T | grep katello

# Useful tasks
sudo foreman-rake katello:check_ping
sudo foreman-rake db:migrate:status | tail -20
```

## Log Locations

| Log | Path |
|---|---|
| Foreman (production) | `/var/log/foreman/production.log` |
| Foreman installer | `/var/log/foreman-installer/katello.log` |
| Foreman proxy | `/var/log/foreman-proxy/proxy.log` |
| Candlepin | `/var/log/candlepin/` |
| Pulp | `journalctl -u pulpcore-api`, `journalctl -u pulpcore-content` |
| Audit (SELinux) | `/var/log/audit/audit.log` |

```bash
# Tail foreman log
sudo tail -f /var/log/foreman/production.log

# Recent pulp errors
sudo journalctl -u pulpcore-api --since '5 minutes ago' --no-pager

# Installer log from last run
sudo tail -100 /var/log/foreman-installer/katello.log
```

## Installing PR-Built RPMs via COPR

Packit builds RPMs for PRs in several projects (foreman-installer, katello, etc.). Find the COPR build link in the PR's GitHub checks (e.g., `rpm-build:rhel-9-x86_64`).

```bash
# On the VM
sudo dnf copr enable -y packit/theforeman-<project>-<PR_NUMBER> rhel-9-x86_64
sudo dnf upgrade -y <package-name>
```

**Caveat:** COPR RPMs are built at PR creation/update time. If dependent PRs in other repos were merged after, the COPR RPM won't include them. Always verify what's actually installed.

## Running BATS Tests

Forklift includes BATS tests in `~/forklift/bats/`. These run on the VM, not the host.

### Setup
```bash
# Copy test files to VM
cd ~/forklift
vagrant scp <box-name>:bats/ :/tmp/bats-tests/

# Or via direct SCP
scp -r -i .vagrant/machines/<box>/libvirt/private_key bats/* vagrant@<ip>:/tmp/bats-tests/
```

### Running
```bash
# On the VM (must run as root for most tests)
sudo bats /tmp/bats-tests/fb-verify-selinux.bats
sudo bats /tmp/bats-tests/fb-katello-content.bats
```

### Key BATS Tests
| File | What it tests |
|---|---|
| `fb-verify-selinux.bats` | `ausearch --message AVC` returns no matches (exit 1) |
| `fb-katello-content.bats` | Full content workflow: repos, sync, publish, promote, export/import |
| `fb-katello-proxy.bats` | Smart proxy content functionality |
| `fb-katello-container.bats` | Container registry push/pull |

### SELinux Test Caveat
The SELinux BATS test checks ALL audit entries ever recorded. If testing a fix for AVC denials, clear the audit log first to remove pre-fix historical entries:
```bash
sudo sh -c '> /var/log/audit/audit.log'
sudo systemctl restart auditd
```

## SELinux Debugging

```bash
# Check enforcing status
getenforce

# Search for AVC denials
sudo ausearch -m avc -ts today
sudo ausearch -m avc -ts recent    # last 10 minutes

# Check context of a file/socket
ls -laZ /path/to/file

# Key SELinux contexts for Pulp
# /run/pulpcore-*/          -> pulpcore_server_var_run_t  (sockets allowed here)
# /var/lib/pulp/            -> pulpcore_var_lib_t         (sock_file NOT allowed)
```

## Service Debugging

```bash
# Check service status
sudo systemctl status pulpcore-api pulpcore-content foreman

# Journal (recent entries only)
sudo journalctl -u pulpcore-api --since '5 minutes ago' --no-pager

# Flush old journal entries (useful when crash-loop errors pollute health checks)
sudo journalctl --rotate && sudo journalctl --vacuum-time=1s
```

## Gotchas

### Journal entries from crash-loops persist
If services crash-loop before a fix, old error entries in journald persist. The installer's puppet health checks read journald and may report old errors as current failures. Flush the journal before re-running the installer.

### BATS needs root
Most BATS tests call `hammer`, `ausearch`, or other commands that require root. Always run with `sudo bats`.

### bats may not be packaged
On CentOS Stream 9, `bats` is not in the default repos. Install from git:
```bash
git clone https://github.com/bats-core/bats-core && cd bats-core && sudo ./install.sh /usr/local
```

### Hammer without sudo requires explicit credentials
Root's hammer config (`/root/.hammer/`) has saved credentials. The vagrant user does not. Either use `sudo hammer ...` or pass `-u admin -p changeme`.

### Self-signed certificates
All HTTPS endpoints on forklift/dev VMs use self-signed certs. Always use `curl -sk` or configure trust:
```bash
# Copy the CA cert if you need browser/tool trust
sudo cp /etc/pki/katello/certs/katello-default-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

### Pulp API is not directly exposed
Pulp's API (`/pulp/api/v3/`) is proxied through Apache. It uses the same HTTPS endpoint as Foreman but does not require Foreman credentials -- it uses cert-based auth or is accessible locally.
