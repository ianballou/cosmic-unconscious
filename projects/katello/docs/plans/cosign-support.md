# Cosign Support in Katello

## Status: Research / Planning

## Summary

Container registries increasingly contain cosign (sigstore) artifacts alongside
container images. These appear as tags with `.sig`, `.att`, and `.sbom` suffixes.
Katello currently syncs them as regular manifests without understanding what they are.

## Goal

Give Katello awareness of cosign artifacts so it can:
- Identify and label cosign signatures, attestations, and SBOMs
- Link them to the container images they describe
- Surface this information in the UI and API
- Potentially support signature verification

## Detailed Knowledge

See the dedicated project: `projects/katello-cosign/`
- `docs/cosign-oci-artifacts.md` -- full analysis of how cosign stores artifacts in OCI registries
- Cosign source code: ~/cosign
