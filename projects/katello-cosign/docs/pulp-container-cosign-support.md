# Pulp Container: Current Cosign & OCI 1.1 Support

Analysis of pulp-container 2.28.0.dev (~/pulp_container) to understand what exists
today and what gaps remain.

## What Pulp-Container Already Has

### 1. Cosign Media Type Recognition

In `constants.py`, Pulp defines all three cosign artifact media types:

```python
COSIGN_BLOB        = "application/vnd.dev.cosign.simplesigning.v1+json"  # .sig layers
COSIGN_ATTESTATION = "application/vnd.dsse.envelope.v1+json"             # .att layers
COSIGN_ATTESTATION_BUNDLE = "application/vnd.dev.sigstore.bundle.v0.3+json"
```

Plus SBOM formats: CycloneDX, SPDX, Syft (with JSON/XML suffixes).

### 2. Manifest Type Classification

The `Manifest` model (`app/models.py`) classifies cosign artifacts via `is_cosign()`
which inspects layer media types, then `get_cosign_type()` maps them to types:

| Manifest Type Constant | Meaning |
|---|---|
| `MANIFEST_TYPE.COSIGN_SIGNATURE` | Cosign signature (.sig tag) |
| `MANIFEST_TYPE.COSIGN_ATTESTATION` | DSSE attestation (.att tag) |
| `MANIFEST_TYPE.COSIGN_ATTESTATION_BUNDLE` | Sigstore bundle v0.3 |
| `MANIFEST_TYPE.COSIGN_SBOM` | SBOM attachment (.sbom tag) |
| `MANIFEST_TYPE.ARTIFACT` | Generic OCI artifact (has artifactType or empty config) |

### 3. OCI 1.1 JSON Schema Validation

In `json_schemas.py`, both `OCI_MANIFEST_SCHEMA` and `OCI_INDEX_SCHEMA` accept:
- `subject` field (descriptor pointing to the image this manifest refers to)
- `artifactType` field

This means Pulp will not reject OCI 1.1 manifests during validation -- it can
store them. But it does not act on these fields beyond validation.

### 4. Cosign-Aware Sync Filtering

The sync stage (`app/tasks/sync_stages.py`) recognizes cosign's tag convention
for `signed_only` filtering:

```python
# cosign signature has a tag convention 'sha256-1234.sig'
tag_name.endswith(".sig") and tag_name.startswith("sha256-")
```

If `signed_only` is enabled on the remote, images without a corresponding `.sig`
tag are skipped during sync.

## What Pulp-Container is Missing

### 1. No Referrers API Endpoint

The OCI Distribution Spec defines `GET /v2/<repo>/referrers/<digest>` for
discovering artifacts related to an image. Pulp's `urls.py` has no such route.
Only: blobs, manifests, tags/list, catalog, and the signature extension API.

### 2. No Referrers Tag Schema Fallback

The OCI Distribution Spec defines a fallback for registries without native
referrers support: store a referrers index at tag `sha256-<hex>` (no suffix).
Pulp does not produce or consume these.

### 3. No Subject Field Tracking

The `Manifest` model has no database field to record the `subject` relationship
(which image a manifest refers to). The JSON schema accepts `subject` during
validation, but it is not persisted in a queryable way.

The raw manifest data is stored in `Manifest.data` (TextField), so the `subject`
is technically present in the JSON, but there is no FK, no index, and no API
to query "give me all referrers for this digest."

### 4. No Referrers-Aware Sync

The sync pipeline does not query upstream registries for referrers. It relies
entirely on the tag list. If an upstream registry stores cosign artifacts via
the OCI 1.1 referrers API (no `.sig`/`.att` tags), Pulp will not discover or
sync them.

## Gap Summary

| OCI 1.1 Feature | Schema Validation | DB Storage | API Serving | Sync from Upstream |
|---|---|---|---|---|
| `artifactType` field | Accepted | Partial (`is_artifact()`) | Not exposed | Not used |
| `subject` field | Accepted | Not tracked (in raw JSON only) | Not exposed | Not used |
| Referrers API endpoint | N/A | N/A | Not implemented | N/A |
| Referrers tag schema | N/A | N/A | Not implemented | Not implemented |

## Key Source Files

All paths relative to ~/pulp_container/pulp_container/:

| File | What It Does |
|---|---|
| `constants.py` | Cosign media types, manifest type constants, SBOM formats |
| `app/models.py` | `Manifest.is_cosign()`, `get_cosign_type()`, `is_artifact()` |
| `app/json_schemas.py` | OCI manifest/index schemas (accept `subject`, `artifactType`) |
| `app/tasks/sync_stages.py` | Cosign tag convention check during sync |
| `app/urls.py` | Registry API routes (no referrers endpoint) |
| `app/registry_api.py` | Registry views (no referrers view) |
