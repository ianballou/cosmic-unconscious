# pulp-oci-images

Repo: https://github.com/theforeman/pulp-oci-images

Builds the Pulp container images used by Katello/Foreman. There are two image
types controlled by the `PROJECT` make variable.

## Two image types

| `PROJECT` | Purpose | Install method | Repo |
|---|---|---|---|
| `pulp` (default) | Production | DNF RPMs from Foreman Pulpcore repo | `images/pulp/` |
| `pulp-development` | Testing/dev | pip from PyPI via `requirements.txt` | `images/pulp-development/` |

The production image bases on `quay.io/centos/centos:stream9` and installs from
`https://yum.theforeman.org/pulpcore/${VERSION}/el9/`. VERSION selects the RPM repo
(e.g. `nightly`, `3.85`).

The development image bases on `quay.io/pulp/pulp:${PULPCORE_VERSION}` and installs
plugins from PyPI. It is what you use when testing Katello against a newer Pulp version
before RPMs are available.

## Testing Katello against a newer Pulp version

### Normal case (pulp-smart-proxy supports the version)

1. Find compatible versions from the nightly RPM repo:
   https://yum.theforeman.org/pulpcore/nightly/el9/x86_64/
   Look for `python3.12-pulpcore-X.Y.Z`, `python3.12-pulp-ansible-X.Y.Z`, etc.

2. Pin versions in `images/pulp-development/requirements.txt`:
   ```
   pulpcore==3.105.3
   pulp-ansible==0.29.7
   pulp-container==2.27.6
   pulp-rpm==3.35.2
   pulp-ostree==2.6.0
   pulp-python==3.27.2
   pulp-deb==3.8.1
   pulp-smart-proxy==0.4.0
   ```

3. Build and push:
   ```bash
   PROJECT=pulp-development make build
   PROJECT=pulp-development make push
   ```
   The image tags as `quay.io/foreman/pulp-development:3.105.3` (derived from
   the `pulpcore==` pin in requirements.txt; tags as `:latest` if unpinned).

### Unsupported case (pulp-smart-proxy doesn't support the new pulpcore yet)

pulp-smart-proxy declares an upper version bound on pulpcore. When testing a pulpcore
version beyond that bound, use the escape hatch:

1. Pin versions in `images/pulp-development/requirements-custom-pulp-smart-proxy.txt`
   (same as requirements.txt but **without** the `pulp-smart-proxy` line):
   ```
   pulpcore==3.105.3
   pulp-ansible==0.29.7
   ...
   ```

2. Build with the flag:
   ```bash
   PROJECT=pulp-development PULP_SMART_PROXY_ALLOW_UNSUPPORTED_VERSIONS=true make build
   ```
   This clones `pulp-smart-proxy` from the `develop` branch, removes the pulpcore upper
   version bound from `pyproject.toml`, and installs that patched version.

3. Push:
   ```bash
   PROJECT=pulp-development PULP_SMART_PROXY_ALLOW_UNSUPPORTED_VERSIONS=true make push
   ```

## Gotchas

- **Silent `:latest` tag** — if `pulpcore` is unpinned in whichever requirements file
  is active (requirements.txt for normal builds,
  requirements-custom-pulp-smart-proxy.txt for unsupported builds), the image tags as
  `:latest`. Always pin pulpcore when you want a meaningful tag.

- **Two requirements files only matter for the unsupported case** — `requirements-custom-pulp-smart-proxy.txt`
  only needs to be updated if you're using `PULP_SMART_PROXY_ALLOW_UNSUPPORTED_VERSIONS=true`.
  Normal builds only use `requirements.txt`.

- **`VERSION` is not a user input for dev builds** — unlike the production image,
  the dev build derives everything from `requirements.txt`. Do not pass `VERSION=` for
  `PROJECT=pulp-development`.
