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

## Common Pre-existing Issues (as of 6.19)
- `NoSuchFieldError: content_view_environment_ids` -- Nailgun's ActivationKey entity definition is out of date. Cascades through errata test fixtures.
- ACS tests fail with `IndexError` in `robottelo/hosts.py` when smart proxy list is empty or incorrectly indexed.

## Test Selection
- `--team artemis` selects tests with `:team: Artemis` docstrings (content management).
- Capsule tests: exclude with `-k "not capsulecontent and not capsule_content"` and `--ignore` on capsule test files.
- Destructive tests live in `tests/foreman/destructive/` -- exclude with `--ignore`.
- `INSTALL_METHOD` in `conf/server.yaml` should match the Satellite type (`foremanctl` or `foreman_installer`). Tests are auto-deselected based on this.
