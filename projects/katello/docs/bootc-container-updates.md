# bootc Container Updates and Katello

How bootc pulls and updates OS images, and how Katello supports it.

## bootc pull architecture

bootc does NOT pull containers the way podman traditionally does. The pull
happens in two stages:

### Stage 1: podman pulls from registry → containers-storage

```
bootc upgrade
  → podman pull (via libpod HTTP API on a private unix socket)
    → containers/image (Go) talks to registry
    → containers/storage stores layers locally
```

bootc calls podman through the libpod HTTP API (`podman_client.rs`) to pull
into bootc's **private** containers-storage at `/ostree/bootc/storage/`.
This is separate from the user's podman storage.

Source: `crates/lib/src/deploy.rs` `pull_unified()` → `crates/lib/src/podman_client.rs`

For docker transport (registry pulls), it uses the libpod HTTP API directly.
For other transports (oci:, dir:, etc.), it falls back to `podman pull` subprocess.

### Stage 2: ostree-rs-ext reads from local storage → ostree repo

```
skopeo proxy (reads containers-storage locally)
  → ostree-rs-ext (Rust)
    → Decompressor (handles gzip OR zstd)
    → imports tar entries into ostree repo
```

After podman has the image in local containers-storage, bootc reads it via
the `containers-image-proxy` crate (which wraps skopeo as a subprocess).
skopeo streams each layer blob through a pipe. ostree-rs-ext decompresses
and imports into the ostree repository.

Source: `crates/ostree-ext/src/container/store.rs`, `unencapsulate.rs`

## Delta update mechanism

bootc images use the **ostree native container format**: many small gzip layers,
one per RPM component (or group of components). Both `centos-bootc` and
`fedora-bootc` publish this way.

Example from centos-bootc:stream10 (amd64): 66 layers, all `tar+gzip`,
ranging from ~0.5MB to ~238MB.

### Where deltas happen

**Network level (stage 1):** Standard OCI layer deduplication. podman compares
layer digests against what's already in local containers-storage. Unchanged
layers are skipped entirely — not downloaded. When a bootc OS update changes
5 packages out of 60, only ~5 layers need downloading.

**ostree import level (stage 2):** Each layer maps to an ostree ref. If the ref
already exists from a previous pull, the layer import is skipped:

```rust
// store.rs lines 1070-1074
if let Some(commit) = layer.commit.as_ref() {
    Self::ensure_ref_for_layer(&self.repo, &layer.ostree_ref, commit)?;
    continue;  // already imported, skip
}
```

For layers that ARE new, ostree does content-addressable object deduplication
at the file level.

### No zstd:chunked in published bootc images

Published bootc images from quay.io (centos-bootc, fedora-bootc) use **gzip
component layers**, NOT zstd:chunked. Verified by inspecting actual manifests
synced into Katello — all layers have mediaType `application/vnd.oci.image.layer.v1.tar+gzip`
with no `io.github.containers.zstd-chunked.*` annotations.

The component layer approach makes zstd:chunked unnecessary for these images.
zstd:chunked solves "one giant layer where only a few files changed" — but
bootc images don't have that problem because they're already split by component.

## zstd decompression support

ostree-rs-ext handles zstd layers at the decompression stage. From
`crates/ostree-ext/src/generic_decompress.rs`:

```rust
match media_type {
    MediaType::ImageLayerZstd => ZstdDecompressor(zstd::stream::read::Decoder::new(src)),
    MediaType::ImageLayerGzip => GzipDecompressor(flate2::bufread::GzDecoder::new(src)),
    MediaType::ImageLayer => TransparentDecompressor(src),
    ...
}
```

The test suite (`tests/it/main.rs`) explicitly tests both `zstd` and
`zstd:chunked` compressed layers via `test_container_zstd()` and
`test_container_zstd_chunked()`.

The `Decompressor::_finish()` method specifically handles zstd:chunked's
skippable metadata frames at the end of the stream to avoid deadlocking
the skopeo pipe.

## enable_partial_images (containers/storage)

`enable_partial_images` in `storage.conf` is the master switch for
**intra-layer** partial pulls in podman's `containers/storage` (Go library).

When **disabled** (default): every layer blob is downloaded in full.

When **enabled**: for each layer, containers/storage checks OCI annotations
for a Table of Contents (TOC). If found, it uses HTTP Range requests to
download only changed chunks within the layer instead of the full blob.

### Supports two TOC formats

| Format | Annotation key | Origin |
|--------|---------------|--------|
| zstd:chunked | `io.github.containers.zstd-chunked.manifest-checksum` | containers/storage (Red Hat) |
| eStargz | `containerd.io/snapshot/stargz/toc.digest` | stargz-snapshotter (Google/NTT) |

Source: `containers/storage` `pkg/chunked/storage_linux.go` `getProperDiffer()`

### How partial pull works (when enabled + TOC present)

1. Read TOC location from layer annotations
2. Fetch TOC via `GetBlobAt()` (HTTP Range request on the blob)
3. Parse TOC — lists every file with byte offset, size, checksum
4. Compare against local storage (overlay layers + ostree repos)
5. Fetch only changed chunks via more `GetBlobAt()` calls
6. Assemble layer locally from cached + newly downloaded files

If no TOC is found: falls back to full layer download (or converts to
zstd:chunked locally if `convert_images = true`).

### The GetBlobAt implementation — actual HTTP Range requests

From `containers/image` `docker/docker_image_src.go`:

```go
headers["Range"] = []string{fmt.Sprintf("bytes=%s", strings.Join(rangeVals, ","))}
```

Sends multi-range HTTP Range headers to `/v2/{name}/blobs/{digest}`.
Handles both 206 (Partial Content with multipart) and 200 (server doesn't
support Range — splits full response client-side as fallback).

### Relevance to bootc

Since bootc uses podman for stage 1, `enable_partial_images` in bootc's
private storage config could theoretically enable this. But published bootc
images don't have zstd:chunked/eStargz annotations, so it has no effect
on standard centos-bootc/fedora-bootc pulls. The component layer approach
provides the delta optimization at a different level.

## What Katello needs to support (and does)

### For standard bootc updates (component layers)

Just standard OCI registry operations:

| What bootc needs | Supported? | How |
|---|---|---|
| Serve manifest by tag/digest | ✅ | Proxied to Pulp, byte-for-byte passthrough |
| Serve individual blobs by digest | ✅ | 302 redirect to Pulp content app |
| Sync zstd-compressed layers | ✅ | Pulp stores blobs as opaque artifacts |
| Client skips layers by digest | ✅ | Client-side, no server involvement |

### For zstd:chunked partial pulls (if enable_partial_images is used)

HTTP Range requests work through the full chain:

| Component | Handles Range? | How |
|-----------|---------------|-----|
| Katello registry proxy | N/A — redirects only | `pull_blob` sends 302, never touches blob data |
| Apache mod_proxy | Passes through | No `RequestHeader unset Range` in config |
| Pulp content app | Yes — native 206 | `aiohttp.web.FileResponse` handles Range natively |
| pulpcore handler.py | Yes — explicit support | Parses `request.http_range`, returns 206 with Content-Range |

Katello does NOT forward the Range header to Pulp — it drops it in `pull_blob`
(only Accept is forwarded). This doesn't matter because Pulp's registry API
just returns a 302 redirect regardless. The client sends Range on the **follow-up
request directly to Pulp's content app**, bypassing Katello entirely.

### Verified by test

Range requests tested on this VM against a synced centos-bootc image:

```bash
# Get token
TOKEN=$(curl -sk "https://localhost/v2/token?scope=repository:REPO:pull" \
  -u admin:changeme | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

# Range request with redirect follow
curl -sk -D- -o /dev/null -L \
  -H "Authorization: Bearer $TOKEN" \
  -H "Range: bytes=0-99" \
  "https://localhost/v2/REPO/blobs/sha256:DIGEST"
```

Results: `HTTP/2 302` (Katello redirect) → `HTTP/2 206` (Pulp content app)
with `Content-Range: bytes 0-99/{total}` and `Accept-Ranges: bytes`.

All three range patterns work: absolute (bytes=0-99), middle (bytes=500000-500999),
and suffix (bytes=-50).

Test script: `katello/test-registry-range.sh`

### Sync — no configuration needed

Pulp syncs zstd content out of the box:
- `_include_layer()` only excludes FOREIGN layers; `REGULAR_BLOB_OCI_TAR_ZSTD`
  is not foreign
- `create_blob()` fetches from `/v2/{name}/blobs/{digest}` as opaque binary
- No recompression, no media type filtering
- Katello's `DockerBlob` is a thin wrapper with no media type awareness

## Key source files

### bootc (Rust)
- Pull orchestration: `crates/lib/src/deploy.rs` (`pull_unified`)
- podman client: `crates/lib/src/podman_client.rs`
- containers-storage: `crates/lib/src/podstorage.rs`
- ostree import: `crates/ostree-ext/src/container/store.rs`
- Layer decompression: `crates/ostree-ext/src/generic_decompress.rs`
- Unencapsulation: `crates/ostree-ext/src/container/unencapsulate.rs`

### containers/storage (Go) — partial pull
- Partial pull entry point: `pkg/chunked/storage_linux.go` (`NewDiffer`)
- TOC reading: `pkg/chunked/compression_linux.go`
- Seekable interface: `pkg/chunked/storage.go` (`ImageSourceSeekable`)

### containers/image (Go) — Range requests
- Registry Range impl: `docker/docker_image_src.go` (`GetBlobAt`)

### Katello/Pulp
- Registry controller: `app/controllers/katello/api/registry/registry_proxies_controller.rb`
- Pulp content handler: `pulpcore/content/handler.py` (Range support)
- Pulp container sync: `pulp_container/app/tasks/sync_stages.py`
