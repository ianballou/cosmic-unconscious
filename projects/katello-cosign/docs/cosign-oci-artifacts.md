# Cosign OCI Artifact Storage

How sigstore/cosign stores signatures and attestations in OCI container registries,
and why they appear in Katello/Pulp container syncs.

Source: analysis of the [sigstore/cosign](https://github.com/sigstore/cosign) codebase (~/cosign).

## Overview

Cosign uses a **tag-based discovery** scheme to store signatures and attestations as
**separate OCI Image Manifests** alongside the original container image, in the **same
repository**. These are valid OCI content -- just not runnable container images.

When Katello (via Pulp) syncs a container repository, it mirrors **all tags**, so
these cosign artifacts are faithfully synced alongside the actual container images.

## Tag Naming Convention

Defined in `pkg/oci/remote/options.go`:

```go
const (
    SignatureTagSuffix   = "sig"
    AttestationTagSuffix = "att"
    SBOMTagSuffix        = "sbom"
)
```

Given a container image digest, cosign computes the tag for related artifacts using
this formula (from `normalizeWithSeparator` in `pkg/oci/remote/remote.go`):

```
<algorithm>-<hex>.<suffix>
```

### Example

| Step | Value |
|------|-------|
| Original image | `registry.example.com/org/app:latest` |
| Resolved digest | `sha256:97fc222cee7991...` |
| Signature tag | `sha256-97fc222cee7991...sig` |
| Attestation tag | `sha256-97fc222cee7991...att` |
| SBOM tag | `sha256-97fc222cee7991...sbom` |

## What .sig Manifests Contain

A `.sig` tag points to an OCI Image Manifest where:

- **Layers** contain signature payloads
  - Media type: `application/vnd.dev.cosign.simplesigning.v1+json`
  - Payload format: [Simple Signing](https://github.com/containers/image/blob/main/docs/containers-signature.5.md) -- a JSON doc containing the image digest and optional claims
- **Annotations** on each layer descriptor carry:
  - `dev.cosignproject.cosign/signature` -- base64-encoded cryptographic signature
  - `dev.sigstore.cosign/certificate` -- optional PEM x509 certificate (keyless signing)
  - `dev.sigstore.cosign/chain` -- optional PEM certificate chain
  - `dev.sigstore.cosign/bundle` -- optional JSON bundle for offline verification (contains Rekor transparency log entry)
  - `dev.sigstore.cosign/rfc3161timestamp` -- optional RFC3161 timestamp response
- Multiple signatures can be embedded as multiple layers in one manifest

## What .att Manifests Contain

A `.att` tag points to an OCI Image Manifest where:

- **Layers** contain attestations in [DSSE envelope](https://github.com/secure-systems-lab/dsse/blob/master/envelope.md) format
  - Media type: `application/vnd.dsse.envelope.v1+json`
  - These wrap [in-toto Statements](https://github.com/in-toto/attestation) that can carry SBOMs, provenance data, vulnerability scan results, etc.
- Like signatures, multiple attestations can be stacked as layers

## Signature Schemes

- Required: ECDSA-P256 with SHA256
- Hash algorithm is pinned to the registry's content-addressable storage algorithm (SHA256 in practice)
- No algorithm information is stored with the signature -- verifiers determine the scheme out-of-band

## Key Source Files

All paths relative to the cosign repo root (~/cosign):

| File | Purpose |
|------|---------|
| `pkg/oci/remote/options.go` | Defines `.sig`, `.att`, `.sbom` suffix constants |
| `pkg/oci/remote/remote.go` | `normalize()`, `SignatureTag()`, `AttestationTag()` -- tag computation |
| `pkg/oci/remote/write.go` | `WriteSignatures()`, `WriteAttestations()` -- publishing to registry |
| `pkg/types/media.go` | Media type constants (`SimpleSigningMediaType`, etc.) |
| `specs/SIGNATURE_SPEC.md` | Full signature specification |
| `specs/ATTESTATION_SPEC.md` | Full attestation specification |
| `pkg/oci/internal/signature/layer.go` | Annotation key constants for certificate, chain, bundle |

## OCI 1.1 Referrers API (Newer Approach)

The codebase also supports a newer approach using the **OCI 1.1 Referrers API**
(see `WriteSignaturesExperimentalOCI`, `WriteAttestationsReferrer`, `WriteReferrer`
in `pkg/oci/remote/write.go`).

Instead of tag-based discovery, this uses:
- The `subject` field in OCI manifests to point back to the signed image
- `artifactType` for discovery via the referrers API

This is the direction the ecosystem is moving, but the tag-based `.sig`/`.att`
scheme (called "legacy" mode via `--registry-referrers-mode`) remains the default
and is what most registries currently use.

Key difference for Pulp: with the referrers API, these artifacts may not appear as
regular tags, but instead be discoverable via the `/v2/<repo>/referrers/<digest>`
endpoint. Pulp would need to understand this API to sync them.

## Artifact Summary

| Artifact | Tag Suffix | Contents | Layer Media Type |
|----------|------------|----------|-----------------|
| Signature | `.sig` | Cosign simple signing payloads + signature annotations | `application/vnd.dev.cosign.simplesigning.v1+json` |
| Attestation | `.att` | DSSE-wrapped in-toto statements (SBOM, provenance, vuln) | `application/vnd.dsse.envelope.v1+json` |
| SBOM | `.sbom` | SBOM data (CycloneDX, SPDX, Syft) | varies by format |

## Implications for Katello/Pulp

1. **These are not container images** -- they are OCI manifests used for supply chain security metadata.
2. **They live in the same repo** as the images they describe, linked by digest in the tag name.
3. **Pulp syncs them as regular manifests** because they are valid OCI content with standard tags.
4. **Users see them as noise** unless Katello understands and surfaces them appropriately.
5. **Verification** would require understanding the cosign signature format and possibly talking to Rekor/Fulcio for keyless signatures.
6. **The link between an image and its .sig/.att** can be computed: parse the tag, extract the digest, and find the image with that digest.
