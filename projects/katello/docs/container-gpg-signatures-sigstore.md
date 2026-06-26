# Container GPG Signatures, Sigstore, and the Extensions API

How Red Hat's GPG-based container image signature mechanism works, how Pulp handles it,
what Katello is missing, and how it differs from cosign/OCI-native signatures.

## Two Completely Different Signature Systems

There are two unrelated signature systems for container images. They share the same
JSON payload schema (`critical.image.docker-manifest-digest`) but use completely
different cryptographic envelopes, storage mechanisms, and discovery protocols.

### 1. GPG Atomic Signatures (Red Hat sigstore)

Pre-OCI, Red Hat-specific. Signatures are OpenPGP inline-signed documents stored on
an **external HTTP server** (the "sigstore"), not in the container registry.

```
Container Registry                    Sigstore (separate HTTP server)
registry.redhat.io                    access.redhat.com/.../sigstore/
┌─────────────────┐                   ┌───────────────────────────────────┐
│ manifests/tags  │                   │ {repo}@sha256={digest}/signature-1│ ← GPG v4 (RSA)
│ (images only)   │                   │ {repo}@sha256={digest}/signature-2│ ← GPG v6 (PQC)
└─────────────────┘                   └───────────────────────────────────┘
```

- Binary OpenPGP packets wrapping a JSON payload
- Signed with long-lived Red Hat GPG release keys
- Client discovery via `/etc/containers/registries.d/*.yaml` (maps registries → sigstore URLs)
- Verification = GPG public key check
- Red Hat's sigstore URL: `https://access.redhat.com/webassets/docker/content/sigstore`
- URL convention: `{sigstore_base}/{repo_name}@sha256={digest_hex}/signature-{N}`

### 2. Cosign Signatures (in-registry, OCI-native)

Modern, OCI-spec-compatible. Signatures are stored **in the registry** as regular
OCI manifests using the tag convention `sha256-{digest}.sig`.

```
Container Registry
┌──────────────────────────────────────────────┐
│ myimage:latest                   ← the image │
│ myimage:sha256-XXXX.sig          ← cosign sig│
│ myimage:sha256-XXXX.att          ← attestation│
└──────────────────────────────────────────────┘
```

- Signature is ECDSA, stored in OCI manifest annotation
- Can be key-based (requires public key) or keyless (Fulcio + Rekor)
- Client discovery: `use-sigstore-attachments: true` in `registries.d`, or cosign CLI
- No external server needed

See [cosign-oci-artifacts.md](cosign-oci-artifacts.md) for full cosign details.

## Red Hat's Current Signing Status (as of 2026)

| Mechanism | Present for current builds? | Notes |
|---|---|---|
| External sigstore (GPG v4 RSA) | **Yes** | Primary mechanism |
| External sigstore (GPG v6 PQC ML-DSA-87) | **Yes** | Published alongside v4 |
| Cosign `.sig` tags | **No** for current builds | Red Hat stopped publishing these |
| OCI 1.1 referrers | **Not used** | Red Hat doesn't use referrers for signatures |
| `X-Registry-Supports-Signatures` header | **No** | Red Hat's registries don't return this |

Red Hat publishes **dual GPG signatures** per manifest: one traditional RSA (v4, ~850 bytes)
and one PQC ML-DSA-87 (v6, ~5200 bytes). You can verify with:

```bash
DIGEST=$(curl -sI "https://registry.access.redhat.com/v2/ubi10-micro/manifests/latest" \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  | grep -i docker-content-digest | awk '{print $2}' | tr -d '\r')
SIGPATH="ubi10-micro@${DIGEST/:/=}"
for i in 1 2 3 4; do
  SIZE=$(curl -sI "https://access.redhat.com/webassets/docker/content/sigstore/${SIGPATH}/signature-${i}" \
    | grep content-length | awk '{print $2}' | tr -d '\r')
  echo "signature-${i}: ${SIZE} bytes $([ ${SIZE:-0} -gt 2000 ] && echo 'PQC v6' || echo 'legacy v4')"
done
```

## How Pulp Handles GPG Signatures

### The `ManifestSignature` Model

Pulp stores GPG signatures as `ManifestSignature` content units (distinct from `Manifest`):

| Field | Description |
|---|---|
| `key_id` | GPG signing key ID (e.g., `199E2F91FD431D51`) |
| `fingerprint` | Full key fingerprint |
| `timestamp` | When the signature was created |
| `creator` | Who/what created it (e.g., `pubtools-sign`) |
| `signed_manifest` | FK to the `Manifest` it signs |
| `data` | Base64-encoded raw GPG signature |

This is a **separate model** from cosign signatures, which are stored as regular
`Manifest` objects with `type=cosign_signature`.

### Signature Sources During Sync

`sync_stages.py` → `get_signature_source()` determines where to get GPG signatures:

1. **`SIGSTORE`** — `remote.sigstore` is set → fetch from external sigstore URL
2. **`API_EXTENSION`** — registry returns `X-Registry-Supports-Signatures: 1` → fetch from
   `GET /extensions/v2/{name}/signatures/{digest}`
3. **`None`** — neither available → skip all signature processing

### The Extensions API

Pulp's registry always serves `X-Registry-Supports-Signatures: 1` on its `/v2/` response
(hardcoded in `registry_api.py` → `default_response_headers`).

**Routes** (`registry.py`):
- `GET /extensions/v2/{path}/signatures/{digest}` — returns all `ManifestSignature` objects for a manifest
- `PUT /extensions/v2/{path}/signatures/{digest}` — accepts a GPG signature push

**This is NOT part of the OCI spec.** It's a Docker Distribution / Pulp convention.
However, `containers/image` (used by podman, skopeo, buildah) natively supports it.

### `extract_data_from_signature()` — The Core Parser

Located in `pulp_container/app/utils.py`. Parses raw OpenPGP packets to extract
key ID, fingerprint, timestamp, and the embedded JSON payload.

Called by three code paths:
1. `sync_stages.py` → `_create_signature_declarative_content()` — during sync
2. `registry_api.py` → PUT handler — when a signature is pushed via extensions API
3. `sign.py` → `create_signature()` — when Pulp signs a manifest itself

### PQC Fix (pulp_container PR #2288)

The old implementation used `gnupg.GPG().decrypt()` + `subprocess.check_output(["gpg", "--list-packets"])`
to parse signatures. GPG cannot handle v6 OpenPGP packets (PQC), producing:
```
gpg: onepass_sig with unknown version 6
```

The fix replaced this with `pysequoia` (Rust-based OpenPGP library):
- Parses both v4 and v6 packets natively
- Extracts key ID from `issuer_key_id` or derives it from `issuer_fingerprint`
- v4 fingerprints (40 hex): key ID = last 8 bytes
- v6 fingerprints (64 hex): key ID = first 8 bytes
- Changed error contract: raises `ValueError` instead of returning `None`

**Impact without the fix:** PQC signatures are silently dropped (INFO log, not a failure).
Legacy signatures still sync. The sync task succeeds. This is data loss, not a sync failure.

## Client-Side Signature Discovery

`containers/image` (podman/skopeo) checks for GPG signatures in this priority order
(see `docker_image_src.go` → `GetSignaturesWithFormat()`):

1. **Extensions API** (preferred) — if registry returns `X-Registry-Supports-Signatures: 1`,
   fetch from `GET /extensions/v2/{name}/signatures/{digest}`
2. **Lookaside/sigstore** (fallback) — use URL from `registries.d/*.yaml`
3. **Sigstore attachments** (cosign) — always checked additionally if `use-sigstore-attachments: true`

This means if a registry serves the header, **clients auto-discover GPG signatures
with no client-side sigstore URL configuration**. The client still needs `policy.json`
with a `signedBy` rule to trigger verification.

### Identity Mismatch Problem

GPG signature payloads embed a `docker-reference` identity:
```json
{"critical": {"identity": {"docker-reference": "registry.access.redhat.com/ubi10-micro:10.2"}}}
```

When pulling from a mirror (e.g., Katello), the pull reference is different
(e.g., `satellite.example.com/org/library/ubi10-micro`). The default `signedIdentity`
policy (`matchRepoDigestOrExact`) requires exact name match, so verification fails.

Fix: configure `policy.json` with `remapIdentity`:
```json
{
  "type": "signedBy",
  "keyType": "GPGKeys",
  "keyPath": "/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release",
  "signedIdentity": {
    "type": "remapIdentity",
    "prefix": "satellite.example.com/org/library",
    "signedPrefix": "registry.access.redhat.com"
  }
}
```

The prefix must include the full Katello path (org, product/library) since Katello
prepends organization and content structure to the repository path.

## What Katello Is Missing

### 1. No sigstore field on container remotes

Katello's `Pulp3::Repository::Docker` does not pass `sigstore` in `remote_options`.
The field exists on Pulp's `ContainerRemote` model but is never set by Katello.

Relevant code: `app/services/katello/pulp3/repository/docker.rb` → `remote_options`

### 2. No extensions API route in the registry proxy

Katello's registry proxy (`Api::Registry::RegistryProxiesController`) routes only:
- `/v2/token`, manifests, blobs, uploads, `_catalog`, `tags/list`

Missing:
- `/extensions/v2/{path}/signatures/{digest}` — not proxied
- `X-Registry-Supports-Signatures: 1` header — not forwarded from Pulp

Without these, clients cannot discover or retrieve GPG signatures through Katello's registry.

Routes file: `config/routes/api/registry.rb`

### 3. No `signed_only` support

Katello's `sync_url_params` does not pass `signed_only`. This is a gating option that
rejects unsigned manifests during sync. Lower priority but part of the full feature.

### 4. No client-side configuration via global registration

Managed hosts need `policy.json` with `signedBy` + `remapIdentity` rules and GPG public
keys to verify signatures. This should be configurable through global registration templates.

## Comparison: ManifestSignature vs Cosign Manifest

| Aspect | ManifestSignature (GPG) | Cosign Manifest |
|---|---|---|
| Pulp model | `ManifestSignature` (dedicated) | `Manifest` with `type=cosign_signature` |
| Parsed metadata | key_id, fingerprint, timestamp, creator | None — opaque pass-through |
| Link to signed image | FK `signed_manifest` | Implicit via tag convention |
| Queryable by key | Yes (`?key_id=...`) | No |
| Bulk remove by key | Yes (`remove_signatures` action) | No |
| Served via extensions API | Yes | No — regular OCI manifest pull |
| Requires Katello integration | Yes (not yet implemented) | No (already works as regular tags) |

## Cosign Verification Through a Mirror (Future)

If Red Hat were to move to cosign/sigstore-attachments, verification through a mirror
would use a different `policy.json` type and `registries.d` config:

```yaml
# /etc/containers/registries.d/satellite.yaml
docker:
  satellite.example.com:
    use-sigstore-attachments: true
```

```json
{
  "type": "sigstoreSigned",
  "keyPath": "/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-cosign",
  "signedIdentity": {
    "type": "remapIdentity",
    "prefix": "satellite.example.com/org/library",
    "signedPrefix": "registry.redhat.io"
  }
}
```

This would work with **no Katello changes** — `.sig` tags sync as regular OCI manifests
and `use-sigstore-attachments` tells the client to look for them in the same registry.

## Key Files

### Pulp (pulp_container)

| File | What |
|---|---|
| `app/utils.py` | `extract_data_from_signature()`, `keyid_from_fingerprint()` — OpenPGP parsing |
| `app/tasks/sync_stages.py` | `get_signature_source()`, `create_signatures()` — sync-time signature fetch |
| `app/registry_api.py` | `Signatures` ViewSet — GET/PUT extensions API, `X-Registry-Supports-Signatures` header |
| `app/registry.py` | URL routing for `/extensions/v2/{path}/signatures/` |
| `app/models.py` | `ManifestSignature` model, `Manifest.is_cosign()` |
| `app/serializers.py` | `ManifestSignatureSerializer`, `RemoveSignaturesSerializer` |
| `app/viewsets.py` | `ManifestSignatureViewSet` — Pulp API for querying signatures |
| `constants.py` | `SIGNATURE_SOURCE`, `SIGNATURE_HEADER`, `SIGNATURE_TYPE` |
| `tests/functional/api/test_sync_signatures.py` | Tests including PQC test |

### Katello

| File | What |
|---|---|
| `app/services/katello/pulp3/repository/docker.rb` | `remote_options` — where `sigstore` would be added |
| `app/services/katello/pulp3/repository.rb` | `sync_url_params` — where `signed_only` would be added |
| `app/controllers/katello/api/registry/registry_proxies_controller.rb` | Registry proxy — needs extensions route |
| `config/routes/api/registry.rb` | Registry routes — needs `/extensions/v2/` |

## Testing PQC Signatures

Pulp's upstream CI test (`test_sync_image_with_pqc_signatures`) syncs `ubi10-micro:latest`
from `registry.access.redhat.com` with `sigstore=https://access.redhat.com/webassets/docker/content/sigstore`
and asserts:
- Legacy key IDs `199E2F91FD431D51` or `E60D446E63405576` present
- PQC key ID `FCD355B305707A62` and fingerprint `FCD355B305707A62DA143AB6E422397E50FE8467A2A95343D246D6276AFEDF8F` present
- Every child manifest in the manifest list has at least one signature

This test requires `pysequoia` (the PQC fix) and the external sigstore to be accessible.

On unpatched Satellite (pulp_container 2.24.2 without pysequoia), syncing with
sigstore configured produces:
- 779 legacy signatures stored successfully
- PQC signatures silently dropped with INFO log: `"It is not possible to read the signed document, GPG error: gpg: onepass_sig with unknown version 6"`
- Sync task completes successfully
