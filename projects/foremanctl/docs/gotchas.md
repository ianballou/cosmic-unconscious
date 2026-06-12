# Gotchas & Surprises

## foremanctl "features" ≠ foreman-maintain "features"
- foremanctl features = plugins/components to install (katello, REX, etc.)
- foreman-maintain features = runtime-detected system capabilities used by checks/procedures
- Don't confuse these — they serve completely different purposes

## check_subuid_subgid and certificate_checks roles exist but aren't wired into the checks playbook
- They exist as roles in src/roles/ but aren't in the loop in src/roles/checks/tasks/main.yml
- May be run separately or may be WIP

## obsah auto-discovers playbooks
- Any `src/playbooks/<name>/<name>.yaml` automatically becomes a CLI command
- Prefixed with `_` (like `_tuning`, `_flavor_features`) are included/internal, not exposed as commands

## sosreport depends on foreman-maintain report
- The sos plugin for Foreman (`sos/report/plugins/foreman_installer.py`) calls `foreman-maintain` commands like `foreman-maintain service status` and `foreman-maintain report` to collect debug/reporting data.
- Since foreman-maintain is merging into foremanctl, sosreport needs updating to call the new tool instead ([SAT-44834](https://redhat.atlassian.net/browse/SAT-44834)).
- This means wherever `report` functionality lands (foremanctl or a separate tool), the sos plugin must be updated to invoke it. The sos plugin is in the [sosreport/sos](https://github.com/sosreport/sos) repo, not in foremanctl or foreman-maintain.
- Parent epic for containerized log handling: [SAT-43762](https://redhat.atlassian.net/browse/SAT-43762)
- foremanctl already runs sosreport in CI: `development/playbooks/sos/sos.yaml`
- Upstream foremanctl issue: https://github.com/theforeman/foremanctl/issues/49

## health.yml vars file doesn't exist
The health playbook (`src/playbooks/health/health.yaml`) references `../../vars/health.yml`
in `vars_files`, but this file does not exist. It works because Ansible 2.15+ silently
ignores missing `vars_files` entries — but this is undocumented/fragile behavior.

## `db:` parameter is deprecated in community.postgresql
The health check roles use `db:` in `community.postgresql.postgresql_query` tasks.
This triggers a deprecation warning — `login_db:` is the correct parameter. The existing
`check_database_connection` role already uses `login_db:` correctly.

## httpd wasn't always in foreman.target
The commit adding httpd to `foreman.target` via a systemd drop-in (`Fixes #535`) landed
on 2026-06-03. Systems deployed before that date don't have the drop-in, so `systemctl
list-dependencies foreman.target` won't include httpd. The dynamic service check
(`check_services`) won't catch httpd being down on those older deployments — though
`check_foreman_api` will still detect the effect (503/connection refused). Running
`foremanctl deploy` on an older system will install the drop-in.

## has_feature() checks transitive dependencies
The `has_feature()` Ansible filter plugin checks both direct features (in
`enabled_features`) and transitive dependencies via `features.yaml`. For example,
`has_feature('tasks')` returns True when `katello` is enabled because `katello` depends
on `tasks`. This is correct behavior but can be surprising when debugging.

## foreman-maintain definitions/ vs lib/
- `definitions/` = concrete checks, procedures, scenarios (the "what")
- `lib/foreman_maintain/` = framework classes and utilities (the "how")
- When porting, you care about definitions/ for feature inventory, lib/ for understanding the patterns
