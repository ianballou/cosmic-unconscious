# Live VM Testing

Testing PRs on forklift vagrant boxes. Applies to foreman-installer, katello, foreman, and plugin PRs.

## Forklift Basics

### Boxes and SSH
- VMs live in `~/forklift`, managed by vagrant.
- SSH: `cd ~/forklift && vagrant ssh <box-name>` or direct SSH with the vagrant key at `.vagrant/machines/<box-name>/libvirt/private_key`.
- Nightly boxes (e.g., `centos9-stream-katello-nightly`) track the latest nightly RPMs.
- **Downgrades are not possible.** Once you upgrade, you cannot roll back. Plan accordingly.

### Installing PR-Built RPMs via COPR
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
