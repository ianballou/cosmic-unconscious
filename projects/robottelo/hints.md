# Robottelo Testing Hints

## Content Host Provisioning
- Content hosts are provisioned as **containers by default** via Broker's Container provider (podman).
- If the Satellite under test does not have a working container runtime (podman socket), ALL content host tests will fail in fixture setup with: `ProviderError: Unable to find image: localhost/ubi9:latest ... connection refused`
- Use `--no-containers` pytest flag to force VM provisioning via Broker/AnsibleTower instead.
- Individual tests can also use the `@pytest.mark.no_containers` marker.

## Selenium Grid / UI Testing
- UI tests use a remote Selenium Grid. The grid config lives at `/root/config.toml` on the grid host, mounted into the `selenium-node` container at `/opt/selenium/docker.toml`.
- The grid uses Dynamic Grid mode: the selenium-node container spawns separate browser containers on demand. Chrome is NOT installed inside selenium-node itself.
- To change Chrome version: update the image in `config.toml` and `podman restart selenium-node`.
- PQC (ML-DSA) certificates require Chrome 150+ for TLS support. Chrome <150 fails with `ERR_SSL_VERSION_OR_CIPHER_MISMATCH`.

## Vault Authentication
- Robottelo uses HashiCorp Vault for secrets (admin passwords, SSH keys).
- Vault auto-authenticates if you have a valid Kerberos ticket (`kinit`).
- The `auto_vault` pytest plugin calls `Vault().login()` during option parsing.
- To test settings manually: `from robottelo.utils.vault import Vault; Vault().login()`

## xdist Behavior
- `XDIST_BEHAVIOR: on-demand` in `conf/server.yaml` causes Broker to dispatch extra workers to OTHER satellites from its inventory when there are more workers than configured hostnames. This silently contaminates test results.
- **Always use `XDIST_BEHAVIOR: run-on-one`** when testing a single specific satellite. All workers will share that one box.
- Verify which satellite each test ran on by checking hostnames in the JUnit XML `system-out`/`system-err`/`error`/`failure` text.

## pip / Dependencies
- `pip install -r requirements.txt` does NOT upgrade packages already installed with a matching version string. If a dependency (like nailgun) is installed from PyPI but `requirements.txt` points to a git repo, pip sees the version match and skips the update.
- Use `pip install --force-reinstall --no-deps "pkg @ git+https://github.com/org/repo.git@master"` to force code updates.

## Podman Secret Workflow (foremanctl / containerized satellite)
- Configs like `candlepin.conf` are injected as podman secrets, not bind mounts.
- To view: `podman secret inspect <name> --showsecret --format '{{.SecretData}}'`
- To update: dump → edit → `podman secret rm <name>` → `podman secret create <name> <file>` → restart service.
- In-container edits (e.g., `podman exec ... sed -i`) are lost on restart.
- Quadlet files live at `/etc/containers/systemd/<service>.container`.

## PQC (Post-Quantum Cryptography) Testing
- ML-DSA-65 certificates are ~14KB vs ~2KB for RSA. This breaks any component passing certs via HTTP headers.
- pulp-content uses aiohttp with `max_field_size=8190` default — rejects PQC client certs in headers.
- Chrome 150+ required for UI testing (ML-DSA TLS support).
- Candlepin `Importer.java` has a code gap: when manifests lack a scheme file, it falls back to the default crypto scheme only — never tries alternative schemes. Config-only fix is not possible.
- You cannot do a partial hybrid setup (PQC signing + RSA fallback) without propagating the RSA CA into the full TLS chain (Apache, Pulp, content hosts).
- Content hosts need `DEFAULT:PQ` crypto policy + OpenSSL 3.5+ to connect to PQC satellites.

## Known Issues (as of 6.20 stream)
- `NoSuchFieldError: content_view_environment_ids` -- Nailgun's ActivationKey entity definition may be out of date if installed from PyPI. Install from git master.
- ACS tests fail with `IndexError` in `robottelo/hosts.py` when smart proxy list is empty or incorrectly indexed.

## Test Selection
- `--team artemis` selects tests with `:team: Artemis` docstrings (content management).
- Capsule tests: exclude with `-k "not capsulecontent and not capsule_content"` and `--ignore` on capsule test files.
- Destructive tests live in `tests/foreman/destructive/` -- exclude with `--ignore`.
- `INSTALL_METHOD` in `conf/server.yaml` should match the Satellite type (`foremanctl` or `foreman_installer`). Tests are auto-deselected based on this.
