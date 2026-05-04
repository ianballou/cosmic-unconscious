# Foreman Installer: Live VM Testing Notes

Installer-specific details. See also `global/live-vm-testing.md` for general forklift/BATS/SELinux patterns.

## Dependent Puppet Module PRs

The foreman-installer RPM bundles puppet modules at build time via the `Puppetfile`. They live under `/usr/share/foreman-installer/modules/`. There are no separate RPMs.

Key bundled modules:
- `puppet-pulpcore` → `modules/pulpcore/`
- `puppet-foreman_proxy_content` → `modules/foreman_proxy_content/`
- `puppet-foreman` → `modules/foreman/`
- `puppet-foreman_proxy` → `modules/foreman_proxy/`

If a dependent module PR was merged AFTER the COPR build, patch it manually:

```bash
# Download and apply
curl -sL https://github.com/<org>/<repo>/pull/<PR>.diff > /tmp/pr.diff
cd /usr/share/foreman-installer/modules/<module> && sudo patch -p1 < /tmp/pr.diff
```

Then fix the parser cache (see below).

## Parser Cache

Kafo caches parsed puppet module metadata in `/usr/share/foreman-installer/parser_cache/*.yaml`. The cache is keyed by file path and **mtime**.

If you modify a module's `init.pp`, you must do ONE of:
- **Set the file mtime** to match the cache's `:mtime:` value: `sudo touch -d @<epoch> <path>/init.pp` — simplest for small patches.
- **Update the cache YAML** — new parameters need entries in 6 sections: defaults (`:values:`), parameter list, docs (`:docs:`), types (`:types:`), groups (`:groups:`), and conditions.
- **Delete the cache file** and run `sudo foreman-installer --help` to regenerate (may fail without all dependencies).

## Migrations

- Kafo migrations run automatically on installer invocation.
- They are also triggered by the RPM `%post` scriptlet during `dnf install/upgrade`, so migrations may already be applied in the answers file before you run `foreman-installer` manually.
- Applied migrations are recorded in `/etc/foreman-installer/scenarios.d/<scenario>-migrations-applied`.
- Answers file: `/etc/foreman-installer/scenarios.d/katello-answers.yaml`
- Log: `/var/log/foreman-installer/katello.log`

## Running the Installer

```bash
sudo foreman-installer --scenario katello
```

The `foreman_proxy_content` class is the installer-level wrapper for `pulpcore`. New pulpcore parameters need changes in three places:
1. `puppet-pulpcore` (the parameter and template usage)
2. `puppet-foreman_proxy_content` (the passthrough mapping)
3. `foreman-installer` (the migration to set default answers)
