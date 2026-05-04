# Live VM Testing for Foreman Installer PRs

Testing foreman-installer PRs on forklift VMs. Applies to katello, foreman-proxy-content, and foreman scenarios.

## Setup

### Forklift Boxes
- VMs live in `~/forklift`, managed by vagrant.
- SSH: `cd ~/forklift && vagrant ssh <box-name>` or direct SSH with the vagrant key at `.vagrant/machines/<box-name>/libvirt/private_key`.
- The box `centos9-stream-katello-nightly` tracks nightly RPMs.

### Installing PR-Built RPMs via COPR
Packit builds RPMs for foreman-installer PRs automatically. Find the COPR build link in the PR's GitHub checks (`rpm-build:rhel-9-x86_64`).

```bash
# On the VM
sudo dnf copr enable -y packit/theforeman-foreman-installer-<PR_NUMBER> rhel-9-x86_64
sudo dnf upgrade -y foreman-installer
```

The COPR RPM bundles puppet modules from the `Puppetfile` at the time of build. If a dependent puppet module PR was merged after the COPR build was triggered, the COPR RPM will NOT include it.

### Dependent Puppet Module PRs
The foreman-installer RPM bundles these puppet modules (among others):
- `puppet-pulpcore` (from `theforeman/puppet-pulpcore`)
- `puppet-foreman_proxy_content` (from `theforeman/puppet-foreman_proxy_content`)
- `puppet-foreman` (from `theforeman/puppet-foreman`)

If a dependent module PR was merged AFTER the COPR build, you must manually patch the module on the VM:

1. Download the diff: `curl -sL https://github.com/<org>/<repo>/pull/<PR>.diff`
2. Apply to the installed module: `cd /usr/share/foreman-installer/modules/<module> && sudo patch -p1 < /tmp/pr.diff`
3. **Update the parser cache** (see below) or set the file mtime to match.

### Parser Cache
Kafo uses a parser cache (`/usr/share/foreman-installer/parser_cache/*.yaml`) to avoid re-parsing puppet modules on every run. The cache is keyed by file path and mtime.

If you modify a puppet module's `init.pp`, you must do ONE of:
- **Set the file mtime** to match the cache's `:mtime:` value: `sudo touch -d @<epoch> <file>`
- **Update the cache YAML** to add new parameters in all 6 sections: defaults (`:values:`), parameter list (`:parameters:`), docs (`:docs:`), types (`:types:`), groups (`:groups:`), and conditions.
- **Regenerate the cache** by deleting the cache file and running `sudo foreman-installer --help` (triggers a rebuild — but this may require all module dependencies to be present).

The mtime approach is simplest for small patches.

### Pulpcore Entrypoints
Both `pulpcore-api` and `pulpcore-content` use **Click-based CLI wrappers** around gunicorn, NOT raw gunicorn. They explicitly enumerate supported gunicorn options. If a new gunicorn option needs to be passed through (like `--control-socket`), pulpcore itself must be patched to expose it in the Click entrypoint.

- API entrypoint: `/usr/lib/python3.12/site-packages/pulpcore/app/entrypoint.py`
- Content entrypoint: `/usr/lib/python3.12/site-packages/pulpcore/content/entrypoint.py`
- Shared gunicorn app: `/usr/lib/python3.12/site-packages/pulpcore/app/pulpcore_gunicorn_application.py`

## Running the Installer

```bash
sudo foreman-installer --scenario katello
```

- **Downgrades are not possible.** Once you run the installer with a newer version, you cannot roll back. Plan accordingly.
- Kafo migrations run automatically on installer invocation. They are recorded in `/etc/foreman-installer/scenarios.d/<scenario>-migrations-applied`.
- Answers file: `/etc/foreman-installer/scenarios.d/katello-answers.yaml`
- Log: `/var/log/foreman-installer/katello.log`

## Running BATS Tests

Forklift includes BATS tests in `~/forklift/bats/`. These run on the VM, not the host.

### Setup
```bash
# Install bats on the VM (if not in repos, use npm or git install)
# npm install -g bats  OR  git clone https://github.com/bats-core/bats-core && cd bats-core && sudo ./install.sh /usr/local

# Copy test files to VM
cd ~/forklift
vagrant scp <box-name>:bats/ :/tmp/bats-tests/
```

### Running
```bash
# On the VM
sudo bats /tmp/bats-tests/fb-verify-selinux.bats       # SELinux check
sudo bats /tmp/bats-tests/fb-katello-content.bats       # Full katello content tests
```

### Key BATS Tests
| File | What it tests |
|---|---|
| `fb-verify-selinux.bats` | `ausearch --message AVC` returns no matches (exit 1) |
| `fb-katello-content.bats` | Full content workflow: repos, sync, publish, promote, export/import |
| `fb-katello-proxy.bats` | Smart proxy content functionality |
| `fb-katello-container.bats` | Container registry push/pull |

### SELinux Test Caveat
The SELinux test checks ALL audit entries ever recorded. If you're testing a fix for AVC denials, you must clear the audit log first to remove pre-fix historical entries:
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

# Check context of a file
ls -laZ /path/to/file

# Key SELinux contexts for Pulp
# /run/pulpcore-*/          -> pulpcore_server_var_run_t  (sockets allowed here)
# /var/lib/pulp/            -> pulpcore_var_lib_t         (sock_file NOT allowed)
# /etc/systemd/system/      -> systemd_unit_file_t
```

## Gotchas

### COPR RPMs may not include all dependent changes
The COPR RPM is built by packit at PR creation/update time. If dependent puppet module PRs are merged after, the COPR RPM won't include them. Always check what puppet module versions are bundled:
```bash
cat /usr/share/foreman-installer/modules/<module>/metadata.json | grep version
```

### Migration runs during RPM install too
The foreman-installer RPM's `%post` scriptlet runs `kafo-configure` which applies migrations. So migrations may already be applied in the answers file before you even run `foreman-installer` manually.

### Journal entries from crash-loops persist
If services crash-loop before a fix, old error entries in journald persist. The installer's puppet health checks read journald and may report old errors as current failures. Flush the journal before re-running:
```bash
sudo journalctl --rotate && sudo journalctl --vacuum-time=1s
```
