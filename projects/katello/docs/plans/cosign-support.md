# Cosign Support in Katello

## Status: Confirmed Working / UX Improvements Needed

## Summary

Cosign (sigstore) workflows — sign, verify, attest, verify-attestation, attach sbom —
all work with Katello's container push registry today. Every cosign operation maps to
standard OCI distribution spec calls (manifest GET/PUT, blob upload, tag creation).
No special registry-side support is needed for basic functionality.

A historical bug in pulp_container used `aiohttp.web.Response(text=...)` which
appended `; charset=utf-8` to Content-Type headers on manifest responses. Cosign's
strict media type parser rejected this. Fixed upstream in pulp_container ≥ 2.25.1 /
2.26.0.

## What Works Today

All cosign operations on container push repos:

| Cosign operation | Registry calls | Result |
|---|---|---|
| `cosign sign` | GET manifest, POST+PUT blob, PUT `.sig` manifest | ✅ |
| `cosign verify` | GET `.sig` manifest, GET blob | ✅ |
| `cosign attest` | GET manifest, POST+PUT blob, PUT `.att` manifest | ✅ |
| `cosign verify-attestation` | GET `.att` manifest, GET blob | ✅ |
| `cosign attach sbom` | POST+PUT blob, PUT `.sbom` manifest | ✅ |

Cosign artifacts are just ordinary OCI manifests stored under tag naming conventions:
- `sha256-<digest>.sig` — signatures
- `sha256-<digest>.att` — attestations (DSSE-wrapped SBOMs, provenance)
- `sha256-<digest>.sbom` — raw SBOMs (deprecated in favor of `attest`)

### Limitation: push repos only

Cosign needs write access to push signature/attestation artifacts back to the same
repo. Synced (pull-type) repos don't support push, so cosign can only sign images
in container push repos. This is by design.

## Historical Bug: charset=utf-8 in Content-Type

- **Upstream issue**: https://github.com/pulp/pulp_container/issues/1997
- **Fix PR**: https://github.com/pulp/pulp_container/pull/2002
- **Root cause**: `aiohttp.web.Response(text=manifest_body)` auto-appends
  `; charset=utf-8` to Content-Type. Fix changed to `body=` instead.
- **Fixed in**: pulp_container 2.25.1 (backport), 2.26.0 (main)

## Remaining Work

### 1. Tag visibility / UI awareness (UX improvement)

Cosign signature tags (`.sig`, `.att`, `.sbom`) appear as regular tags in Katello's
UI/API with no special labeling. Users cannot easily tell which tags are signatures
vs actual images. Katello should:

- Identify cosign artifact tags by naming convention
- Show them linked to their parent image digest in the UI
- Potentially group or filter them (e.g., "show signatures for this image")

### 2. OCI Referrers API support (spec compliance)

The OCI distribution spec defines a Referrers API (`GET /v2/{repo}/referrers/{digest}`)
that allows clients to discover artifacts (signatures, SBOMs, attestations) linked to
a given manifest digest without relying on tag naming conventions. Cosign is migrating
toward this API (it's the successor to the tag-based scheme).

Katello and Pulp need to support this endpoint for forward compatibility:
- Pulp Container tracks this at: https://github.com/pulp/pulp_container/issues/TBD
- Katello would need to proxy this endpoint like other registry API calls

### 3. Signature verification (stretch goal)

Optionally allow Katello to verify cosign signatures using a configured public key
or keyless (Fulcio) verification. This would enable policy enforcement (e.g., only
promote signed images to lifecycle environments).

## Key References

- pulp_container #1997: The charset=utf-8 fix
- pulp_container PR #2002: The actual code change
- OCI Referrers spec: https://github.com/opencontainers/distribution-spec/blob/main/spec.md#listing-referrers
- Cosign OCI layout: https://github.com/sigstore/cosign/blob/main/specs/SIGNATURE_SPEC.md

## Detailed Knowledge

See the dedicated project: `projects/katello-cosign/`
- `docs/cosign-oci-artifacts.md` -- full analysis of how cosign stores artifacts in OCI registries
- Cosign source code: ~/cosign
