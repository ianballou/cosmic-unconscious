# Katello Container Registry Proxy

How Katello's container registry works and what it supports for OCI pulls.

## Architecture

Katello's registry (`Api::Registry::RegistryProxiesController`) is a proxy layer
in front of Pulp's `pulpcore_registry` endpoint. It handles authentication,
authorization, and repository resolution, then delegates to Pulp for actual
content serving.

The Pulp connection is configured via `Resources::Registry::RegistryResource`,
which targets `{content_app_url}/pulpcore_registry/`.

### Pull flow for manifests

1. Client sends `GET /v2/{repo}/manifests/{tag}` to Katello
2. Katello forwards all HTTP headers to Pulp's registry API
3. Pulp returns the manifest JSON body directly (not a redirect)
4. Katello passes the response through verbatim via `render json:` (which skips
   `.to_json` for String objects -- RestClient::Response inherits from String)
5. Content-Type is set from Pulp's response before `render`, so Rails does not
   overwrite it with `application/json`

No JSON parsing, no field filtering. All OCI annotations are preserved byte-for-byte.

### Pull flow for blobs

1. Client sends `GET /v2/{repo}/blobs/{digest}` to Katello
2. Katello's `pull_blob` builds headers with only `Accept` (other headers dropped)
3. Forwards to Pulp with `max_redirects: 0`
4. Pulp returns a 302 redirect pointing to its content app
5. Katello's `redirect_client` rewrites the host and sends a 302 to the client
6. Client follows the redirect and fetches the blob directly from Pulp's content app

Katello never touches blob data. The client talks directly to Pulp for the download.

### HEAD for blobs (check_blob)

Proxies the HEAD request to Pulp and forwards Content-Type and Content-Length headers.
Returns the same status code Pulp returns.

## HTTP Range request support

Katello's registry supports HTTP Range requests for blob downloads, enabling
partial/chunked pull optimizations (zstd:chunked, eStargz).

### Why it works: Katello gets out of the way

Katello does NOT forward the Range header — `pull_blob` only copies `Accept`.
This doesn't matter because Pulp's registry API returns a 302 redirect
regardless. The client sends Range on the **follow-up request directly to
Pulp's content app**, bypassing Katello entirely.

| Hop | Range present? | Why it's fine |
|-----|---------------|---------------|
| Client → Katello | Sent by client, dropped by pull_blob | Katello only does auth + 302, no data |
| Katello → Pulp registry API | No | Registry API only returns redirects |
| Client → Apache → Pulp content app | Yes (fresh request) | FileResponse handles Range natively (206) |

### Range support in the serving chain

- **Pulp content app**: `aiohttp.web.FileResponse` natively handles Range headers,
  returns HTTP 206 with `Content-Range` and `Accept-Ranges: bytes`
- **pulpcore handler.py**: explicit Range handling with `request.http_range`,
  raises `HTTPRequestRangeNotSatisfiable` for invalid ranges per RFC 7233
- **Apache mod_proxy**: passes Range headers through (no `RequestHeader unset Range`
  in config)

### Verified by test

Range requests tested against synced container images:

```
HTTP/2 302  (Katello redirect)
HTTP/2 206  (Pulp content app)
content-range: bytes 0-99/1168174
accept-ranges: bytes
content-length: 100
```

All range patterns work: absolute (bytes=0-99), middle, and suffix (bytes=-50).

Test script: `katello/test-registry-range.sh`

## Header passthrough

### pull_manifest
Forwards all `HTTP_*` headers from the client request to Pulp.

### pull_blob
Forwards only the `Accept` header to Pulp's registry API. Since the client
is redirected to Pulp's content app, all subsequent headers (including Range)
go directly to Pulp.

### check_blob (HEAD)
Forwards only `Accept` to Pulp. Returns Content-Type and Content-Length from
Pulp's response.

### Push operations (start_upload_blob, upload_blob, finish_upload_blob, push_manifest)
Forward `Content-Type`, `Content-Length`, `Content-Range` as appropriate.

## No filtering or hardcoding

- No content-type allowlist or blocklist on pulls
- No manifest annotation filtering
- No header stripping on redirects
- `authorize_repository_read` checks repository existence and permissions only,
  not content types or media types
- `check_media_type` (Foreman base controller) only applies to POST/PUT, not GET

## Pulp media type support

`pulp_container` recognizes zstd-compressed layers in its constants:
- `application/vnd.oci.image.layer.v1.tar+zstd` (distributable)
- `application/vnd.oci.image.layer.nondistributable.v1.tar+zstd` (non-distributable)

Pulp syncs zstd content with no special configuration:
- `_include_layer()` only excludes FOREIGN layers
- `REGULAR_BLOB_OCI_TAR_ZSTD` is NOT foreign — always included
- `create_blob()` fetches blobs as opaque binary, no recompression
- Katello's `DockerBlob` has no media type awareness

## Apache proxy configuration

The relevant Apache rules in `05-foreman-ssl.conf`:

```
# Pulp registry API (used by Katello controller internally)
ProxyPass /pulpcore_registry/ unix:///run/pulpcore-api.sock|...

# Pulp content app (where clients are redirected for blob downloads)
ProxyPass /pulp/container/ unix:///run/pulpcore-content.sock|...
```

## Key files

- Controller: `app/controllers/katello/api/registry/registry_proxies_controller.rb`
- Registry resource: `app/lib/katello/resources/registry.rb`
- Routes: `config/routes/api/registry.rb`
- Apache config: `/etc/httpd/conf.d/05-foreman-ssl.conf`
- Pulp registry API: `pulp_container/app/registry_api.py`
- Pulp content app: `pulp_container/app/registry.py`
- Pulp redirects: `pulp_container/app/redirects.py`
- Pulp constants: `pulp_container/constants.py`
- Pulp content handler: `pulpcore/content/handler.py` (Range support)

## Cosign / sigstore compatibility

Katello's registry fully supports cosign workflows (sign, verify, attest,
verify-attestation, attach sbom) on container push repos. All cosign operations
are standard OCI distribution spec calls — no special registry support needed.

Cosign artifacts are stored as ordinary OCI manifests under tag conventions:
- `sha256-<digest>.sig` — signatures
- `sha256-<digest>.att` — attestations (DSSE-wrapped SBOMs/provenance)
- `sha256-<digest>.sbom` — raw SBOMs (deprecated)

### Historical charset=utf-8 bug

pulp_container < 2.25.1 had a bug where `aiohttp.web.Response(text=...)` appended
`; charset=utf-8` to Content-Type headers on manifest responses. Cosign's strict
media type parser rejected this. Fixed in pulp_container 2.25.1/2.26.0 via
[PR #2002](https://github.com/pulp/pulp_container/pull/2002) (changed `text=` to
`body=`).

### Known gaps

- **Synced repos**: cosign cannot push signatures to synced (pull-type) repos.
  Only container push repos support the write operations cosign needs.
- **Tag visibility**: `.sig`/`.att`/`.sbom` tags appear as regular tags in the
  Katello UI with no special labeling or linkage to parent images.
- **Referrers API**: The OCI Referrers API (`GET /v2/{repo}/referrers/{digest}`)
  is not yet supported. Cosign is migrating from tag-based to referrers-based
  artifact discovery. Katello and Pulp will need to support this endpoint.

See [plans/cosign-support.md](plans/cosign-support.md) for the full plan.

## Related docs

- [bootc Container Updates](bootc-container-updates.md) — bootc pull architecture,
  delta mechanisms, zstd:chunked/enable_partial_images details
