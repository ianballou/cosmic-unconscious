# Foreman Installer Gotchas

Surprising behaviors and hard-won knowledge.

## Puppet modules are bundled, not installed separately
The foreman-installer RPM bundles all puppet modules at build time via the `Puppetfile`. They live under `/usr/share/foreman-installer/modules/`. There are no separate RPMs for puppet-pulpcore, puppet-foreman_proxy_content, etc.

## Parser cache is mtime-sensitive
Kafo caches parsed puppet module metadata in `/usr/share/foreman-installer/parser_cache/`. If you modify a module file without updating the cache or matching the mtime, kafo will reject the cache and try to re-parse (which may fail without all dependencies).

## `foreman_proxy_content` is the installer-level wrapper for `pulpcore`
The `foreman_proxy_content` puppet class wraps `pulpcore` and maps installer answer keys (prefixed `pulpcore_`) to the underlying `pulpcore` class parameters. New pulpcore parameters need changes in three places:
1. `puppet-pulpcore` (the parameter and template usage)
2. `puppet-foreman_proxy_content` (the passthrough mapping)
3. `foreman-installer` (the migration to set default answers)

## Migrations use `||=` pattern for safe defaults
Installer migrations use `answers['module']['param'] ||= 'value'` to set defaults only when not already set. This preserves custom values on upgrade.

## pulpcore CLI entrypoints are Click wrappers, not raw gunicorn
Both `pulpcore-api` and `pulpcore-content` are Click commands that explicitly enumerate which gunicorn options they accept. New gunicorn options (like `--control-socket` in gunicorn 25.1+) require upstream pulpcore changes to expose them through the Click entrypoints. You cannot simply add flags to the systemd service file.
