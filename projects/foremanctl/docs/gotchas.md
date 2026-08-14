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

## PROFILE=SYSTEM, TLS 1.2 vs TLS 1.3, and Candlepin's Tomcat FFM connector

### How PROFILE=SYSTEM works

`PROFILE=SYSTEM` is NOT an Apache or upstream OpenSSL feature. It is a RHEL/Fedora patch
to OpenSSL itself. The patch lives in Fedora's package source control:
https://src.fedoraproject.org/rpms/openssl/blob/rawhide/f/0005-RH-Add-support-for-PROFILE-SYSTEM-system-default-cip.patch

The patch modifies `ssl_create_cipher_list()` in `ssl/ssl_ciph.c` to intercept the string
`PROFILE=SYSTEM` and replace it with ciphers loaded from
`/etc/crypto-policies/back-ends/opensslcnf.config`. OpenSSL is compiled with
`-DSYSTEM_CIPHERS_FILE=` pointing to that file. Apache mod_ssl has zero code for
PROFILE=SYSTEM -- it just passes the cipher string verbatim to OpenSSL.

### The TLS 1.2 vs TLS 1.3 gap

OpenSSL has two completely separate APIs for cipher configuration:

- `SSL_CTX_set_cipher_list()` -- TLS 1.2 and below. This is a thin wrapper around
  `ssl_create_cipher_list()` (see [ssl_lib.c L3360](https://github.com/openssl/openssl/blob/openssl-3.5/ssl/ssl_lib.c#L3360-L3366)).
  The RHEL patch hooks this function. `PROFILE=SYSTEM` works here.

- `SSL_CTX_set_ciphersuites()` -- TLS 1.3. This calls `set_ciphersuites()` in
  `ssl/ssl_ciph.c`, a completely different code path. The RHEL patch does NOT hook this
  function. `PROFILE=SYSTEM` fails here with `no cipher match`.

On non-RHEL systems (Debian, Alpine, upstream OpenSSL), `PROFILE=SYSTEM` is invalid
for both APIs.

### How Tomcat FFM handles this

Candlepin 5.0's Tomcat uses the OpenSSL FFM (Foreign Function & Memory) connector, which
calls both OpenSSL APIs separately. The logic is in `OpenSSLContext.java`:

```java
boolean ciphersSet = false;

// TLS 1.2 path -- only runs if TLS 1.2 is in the protocols list
if (minTlsVersion <= TLS1_2_VERSION()) {
    if (SSL_CTX_set_cipher_list(sslCtx, getCiphers()) <= 0)
        tls12Warning = "...";
    else
        ciphersSet = true;   // success here suppresses ALL warnings
}

// TLS 1.3 path -- only runs if TLS 1.3 is in the protocols list
if (maxTlsVersion >= TLS1_3_VERSION()) {
    if (SSL_CTX_set_ciphersuites(sslCtx, getCipherSuites()) <= 0)
        tls13Warning = "...";
    else
        ciphersSet = true;
}

// warnings only shown if NEITHER path succeeded
if (!ciphersSet) {
    log.warn(tls12Warning);
    log.warn(tls13Warning);
}
```

Key behaviors:
- TLS 1.3 ciphersuites come from Tomcat's hardcoded defaults
  (`TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256`),
  NOT from the `ciphers` attribute in `server.xml`.
- If TLS 1.2 is enabled and its cipher setup succeeds, `ciphersSet = true` and
  any TLS 1.3 warning is suppressed -- even if TLS 1.3 setup also had issues.
- If only TLS 1.3 is enabled (TLS 1.2 path skipped), the TLS 1.3 warning becomes
  visible because nothing set `ciphersSet = true` first.

### What this means for a running Katello with PROFILE=SYSTEM

With `protocols="TLSv1.2,TLSv1.3"` and `ciphers="PROFILE=SYSTEM"`:

- TLS 1.2: `SSL_CTX_set_cipher_list("PROFILE=SYSTEM")` succeeds on RHEL. Candlepin
  gets the full set of system-crypto-policy-compliant TLS 1.2 ciphers.
- TLS 1.3: Tomcat uses its hardcoded defaults (standard strong ciphersuites). These
  are NOT governed by the system crypto policy, but all TLS 1.3 ciphersuites are
  considered strong so this is a non-issue in practice.
- No warning is logged because the TLS 1.2 path succeeds first.
- When the RHEL OpenSSL patch is eventually extended to cover
  `SSL_CTX_set_ciphersuites()`, TLS 1.3 will automatically start honoring the system
  crypto policy too -- no foremanctl changes needed.

### nmap caveat

nmap 7.92's `ssl-enum-ciphers` script does its own TLS handshakes to probe ciphers.
It cannot complete handshakes with ML-DSA-65 (PQC) certificates, so it reports nothing
on PQC machines even though TLS 1.3 is working. Use `openssl s_client` to verify instead.

Ref: https://github.com/theforeman/foremanctl/pull/724

## foreman-maintain definitions/ vs lib/
- `definitions/` = concrete checks, procedures, scenarios (the "what")
- `lib/foreman_maintain/` = framework classes and utilities (the "how")
- When porting, you care about definitions/ for feature inventory, lib/ for understanding the patterns
