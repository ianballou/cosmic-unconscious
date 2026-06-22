# Plan: Cosign Display & OCI 1.1 Referrers

Status: Planning / Open Questions
Date: 2025-06-22

## Context

Container repos synced via Katello/Pulp now contain cosign artifacts (`.sig`, `.att`,
`.sbom` tags). Pulp already classifies these by type in the Manifest model, but
Katello does not surface this information to users in a meaningful way.

Meanwhile, the OCI ecosystem is moving toward the OCI 1.1 Referrers API as the
standard way to associate artifacts with images. Cosign already supports this as
an opt-in mode (`--registry-referrers-mode oci-1-1`), but it is unclear how fast
adoption will move or whether the legacy tag-based approach will persist long-term.

## Two Tracks

### Track 1: Improve Display of Existing Cosign Tags (Near-Term, Clear Value)

Pulp-container already classifies manifests by type (`cosign_signature`,
`cosign_attestation`, `cosign_attestation_bundle`, `cosign_sbom`). Katello can
leverage this to:

- Display cosign artifact type alongside tags in the UI
- Filter/group tags by type (image vs. signature vs. attestation vs. SBOM)
- Link cosign artifacts back to the images they sign (parse the tag name to
  extract the digest, match to the image with that digest)
- Suppress cosign tags from default views if they are noise, but make them
  accessible for users who care about supply chain security

This track requires no Pulp changes -- it is purely Katello UI/API work on top
of data Pulp already provides.

Questions:
- Does Katello already expose `Manifest.type` from Pulp? If so, where?
- What UI changes would be most useful? A separate "Signatures" tab? Type badges
  on the tags list? A linked view ("this image is signed by...")?
- Should cosign tags be hidden by default or shown with a visual distinction?

### Track 2: OCI 1.1 Referrers API Support (Future, Uncertain Timeline)

The OCI Distribution Spec v1.1 defines a proper referrers API for artifact
discovery. For full support, Pulp-container would need:

1. A `subject` relationship tracked in the Manifest model (FK or indexed field)
2. A `/v2/<repo>/referrers/<digest>` endpoint serving an index of referring manifests
3. Referrers-aware sync that queries upstream referrers endpoints
4. Referrers tag schema fallback for registries without native support

This is a Pulp-container feature request, not a Katello change. Katello would
then build on top of whatever Pulp exposes.

Questions:
- Is there upstream interest in pulp-container for referrers API support?
- Which major registries have adopted OCI 1.1 referrers in production?
  (Docker Hub, Quay, GHCR, ECR, ACR, GCR, etc.)
- Will cosign eventually deprecate the legacy tag-based mode? No signal yet.
- Should Katello wait for Pulp to implement referrers, or start with the tag-based
  approach and evolve?

## Open Questions

The core uncertainty: it is unclear right now which path deserves the most focus.

Arguments for prioritizing Track 1 (legacy tags):
- Works today with zero Pulp changes
- All existing cosign-signed content uses this convention
- Immediate user value (cleaner UI, artifact visibility)
- Low risk -- the data is already there

Arguments for prioritizing Track 2 (OCI 1.1 referrers):
- It is the OCI standard and will eventually win
- More robust than tag-based hacks (no tag race conditions)
- Ecosystem tooling is converging on it
- Forward-looking investment

Likely best approach: Start with Track 1 for immediate value while monitoring
OCI 1.1 adoption. Design any new Katello UI/API in a way that is agnostic to
the discovery mechanism (show "this image has these signatures/attestations"
regardless of whether they came from tags or referrers).

## Registry Layers That Would Need Referrers API Support

OCI 1.1 referrers support is not just a Pulp change. There are three registry layers
in the Katello ecosystem, and all three would need work to serve the
`GET /v2/<repo>/referrers/<digest>` endpoint for clients to discover cosign artifacts
via OCI 1.1.

### 1. Pulp-container Registry (pulp_container)

Pulp's built-in registry serves the OCI Distribution API for content distribution.

Routes defined in `pulp_container/app/urls.py`:
- `/v2/<path>/blobs/uploads/`
- `/v2/<path>/blobs`
- `/v2/<path>/manifests`
- `/v2/_catalog`
- `/v2/<path>/tags/list`
- `/extensions/v2/<path>/signatures` (atomic container signature extension)

No `/v2/<repo>/referrers/<digest>` endpoint exists. Pulp would need:
- A new referrers view in `registry_api.py`
- A new URL pattern in `urls.py`
- A `subject` relationship tracked in the `Manifest` model (currently only accepted
  during JSON validation but not persisted as a queryable field)
- Referrers tag schema fallback support

### 2. Katello Registry Proxy (katello)

Katello's registry proxy controller (`app/controllers/katello/api/registry/registry_proxies_controller.rb`)
acts as an authenticated front-end to Pulp's registry. It handles auth, token
management, and proxies requests to Pulp.

Routes defined in `config/routes/api/registry.rb`:
- `/v2/token` (auth)
- `/v2/*repository/manifests/:tag` (GET, PUT)
- `/v2/*repository/blobs/:digest` (GET, HEAD)
- `/v2/*repository/blobs/uploads` (POST)
- `/v2/*repository/blobs/uploads/:uuid` (PUT, PATCH)
- `/v2/_catalog`
- `/v2/*repository/tags/list`
- `/v2` (ping)
- `/v1/_ping`, `/v1/search` (legacy)
- `/index/static` (flatpak)

No referrers route. Katello would need a new route and controller action to proxy
referrers requests to Pulp (similar to how manifests/blobs are proxied today).
Auth handling for referrers requests would also need consideration.

### 3. Smart Proxy Container Gateway (smart_proxy_container_gateway)

The smart proxy container gateway (`lib/smart_proxy_container_gateway/container_gateway_api.rb`)
runs on Capsules/Smart Proxies and provides registry access to hosts for content
consumption. It is a Sinatra app that proxies to Pulp and handles cert-based and
token-based auth for hosts.

Routes defined in the Sinatra API:
- `/v2` (ping)
- `/v2/*/manifests/*` (GET only, PUT returns UNSUPPORTED)
- `/v2/*/blobs/*` (GET, HEAD)
- `/v2/*/tags/list`
- `/v2/_catalog`
- `/v2/token`
- `/v1/_ping`, `/v1/search` (legacy)
- `/index/static` (flatpak)

No referrers route. Push is explicitly unsupported (returns 404 UNSUPPORTED).
The gateway would need a new referrers route that proxies to Pulp, plus auth
handling consistent with the existing manifest/blob patterns.

### Summary of Registry Work for OCI 1.1

| Layer | Role | Location | Referrers Support |
|---|---|---|---|
| Pulp-container | Content storage + API | ~/pulp_container | Not implemented |
| Katello registry proxy | Auth frontend to Pulp | ~/katello | Not implemented |
| Smart proxy container gateway | Capsule-side registry for hosts | ~/smart_proxy_container_gateway | Not implemented |

All three layers would need coordinated changes. Pulp is the foundation -- it must
implement referrers first. Then Katello and smart-proxy can proxy referrers requests
the same way they proxy manifests and blobs today.

## Dependencies

- Pulp-container: Track 1 needs nothing. Track 2 needs upstream feature work.
- Katello registry proxy: Track 2 needs a new route + controller action.
- Smart proxy container gateway: Track 2 needs a new Sinatra route.
- Cosign source analysis: ~/cosign (see cosign-oci-artifacts.md)
- Pulp-container analysis: ~/pulp_container (see pulp-container-cosign-support.md)
