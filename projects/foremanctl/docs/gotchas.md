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

## Container gateway DB connection doesn't support SSL (yet)
The smart_proxy_container_gateway plugin passes its `db_connection_string` setting directly
to `Sequel.connect`. Unlike foreman/candlepin/pulp, which have separate application-level
SSL config, container gateway would need SSL parameters embedded in the connection string
as PostgreSQL query parameters (e.g. `?sslmode=verify-full&sslrootcert=/path/to/ca.pem`).
The `database.yml` layer is missing `container_gateway_database_ssl_mode` and
`container_gateway_database_ssl_ca` variables, and the connection string template in the
foreman_proxy role defaults would need to conditionally append them.

## PROFILE=SYSTEM is a RHEL OpenSSL patch, not an OpenSSL or Apache feature

`PROFILE=SYSTEM` is injected by Fedora/RHEL's `0005-RH-Add-support-for-PROFILE-SYSTEM-system-default-cip.patch`
into `ssl_create_cipher_list()` in `ssl/ssl_ciph.c`. It reads ciphers from
`/etc/crypto-policies/back-ends/opensslcnf.config`. Apache mod_ssl has zero code for it --
it passes the cipher string verbatim to `SSL_CTX_set_cipher_list()`.

Critical limitation: the patch only covers `SSL_CTX_set_cipher_list()` (TLS 1.2 ciphers).
`SSL_CTX_set_ciphersuites()` (TLS 1.3) is NOT patched and does NOT understand PROFILE=SYSTEM.
On non-RHEL systems (Debian, Alpine, upstream OpenSSL), PROFILE=SYSTEM is an invalid cipher string.

## Tomcat FFM OpenSSL connector splits TLS 1.2 and TLS 1.3 cipher configuration

In `OpenSSLContext.java` (Tomcat 9.0.x FFM connector), the `ciphers` attribute from
`server.xml` is split by `SSLHostConfig.setCiphers()` into TLS 1.2 names
(`SSL_CTX_set_cipher_list`) and TLS 1.3 names (`SSL_CTX_set_ciphersuites`). Passing
`PROFILE=SYSTEM` as the cipher string works for TLS 1.2 on RHEL but produces a WARNING
log for TLS 1.3 (though TLS 1.3 still works via hardcoded defaults:
`TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256`).
The warning is misleading -- it only fires when NEITHER cipher path succeeds, but the
TLS 1.3 default path silently succeeds. PR 724's approach of explicit OpenSSL-style
cipher names (e.g. `ECDHE-RSA-AES256-GCM-SHA384`) is correct and portable.
Ref: https://github.com/theforeman/foremanctl/pull/724

## foreman-maintain definitions/ vs lib/
- `definitions/` = concrete checks, procedures, scenarios (the "what")
- `lib/foreman_maintain/` = framework classes and utilities (the "how")
- When porting, you care about definitions/ for feature inventory, lib/ for understanding the patterns
