# Satellite Installation Scenarios & Foremanctl Deployment Planning

## Purpose

Documents how Satellite prescribes installation for connected, disconnected, and capsule scenarios today (RPM/installer-based), and how those flows map to the containerized foremanctl model.

## Current Satellite Installation (RPM-based, Satellite 6.x)

### Connected Satellite

1. Register host to Red Hat CDN (`subscription-manager register`)
2. Enable Satellite repos (`satellite-6.x-for-rhel-9-x86_64-rpms`, etc.)
3. `dnf install satellite`
4. `satellite-installer --scenario satellite`
5. Upload subscription manifest, enable and sync repos from Red Hat CDN

### Disconnected Satellite

1. Download RHEL Binary DVD + Satellite Binary DVD on a connected machine
2. Transfer ISOs to the disconnected host (sneakernet)
3. Mount both ISOs, configure local yum repos pointing at mount points
4. `./install_packages` from mounted Satellite ISO
5. `satellite-installer --scenario satellite`
6. Disable subscription connection (`hammer settings set --name subscription_connection_enabled --value false`)
7. Upload manifest (transferred from connected machine)
8. Configure content source:
   - **ISS Export Sync** (air-gapped): connected upstream Satellite exports content to disk, sneakernet, import on disconnected Satellite
   - **ISS Network Sync**: downstream Satellite can reach an upstream Satellite (but not the internet)
   - **Custom CDN**: local web server mirrors Red Hat CDN structure

### Capsule (any parent -- connected or disconnected)

The capsule flow is identical regardless of the parent Satellite's connectivity. Capsules never register to Red Hat CDN. They always get everything from the parent Satellite.

> "Do not register Capsule Server to the Red Hat Content Delivery Network (CDN)."
> -- Red Hat Satellite 6.19 Installing Capsule Server

1. Register capsule host to the parent Satellite
2. Enable capsule repos via `subscription-manager repos` (served by the Satellite)
3. `dnf install satellite-capsule`
4. On Satellite: `capsule-certs-generate --foreman-proxy-fqdn <capsule-fqdn> --certs-tar <path>`
5. Transfer cert tarball to capsule
6. On capsule: run the `satellite-installer --scenario capsule` command that `capsule-certs-generate` printed (includes cert paths, oauth keys, Satellite URL)
7. On Satellite: assign lifecycle environments to the capsule
8. Sync content to capsule: `hammer capsule content synchronize --id <capsule-id>`

### Key patterns

- **Capsules are always downstream of Satellite** -- packages, certs, and content all flow from the parent Satellite, never from external sources.
- **Connected vs disconnected** only affects how software and content reach the Satellite itself. The capsule never knows or cares.
- **Binary DVD** is only strictly necessary for air-gapped (ISS Export Sync) Satellites. If the downstream Satellite can reach an upstream Satellite (ISS Network Sync), it could theoretically get packages from there too.

## IoP (Red Hat Lightspeed in Satellite) -- Container Precedent

IoP is the first Satellite component delivered as container images. It provides a preview of the distribution problem foremanctl solves at larger scale.

### Connected Satellite
- `podman pull` from `registry.redhat.io` (or configure Podman HTTP proxy)
- `satellite-installer --enable-iop`

### Disconnected Satellite (ISO method)
- Satellite ISO includes container image archives
- `/media/sat6/setup_containers` script loads images into local Podman storage
- `satellite-installer --enable-iop`

### Disconnected Satellite (export/import method)
- On connected machine: `podman pull` + `podman save --output /tmp/<name>.tar` for each image
- Transfer tarballs to disconnected host
- On disconnected host: `podman load --input /tmp/<name>.tar` for each image
- `satellite-installer --enable-iop`

IoP uses ~14 container images. Containerized Satellite will have all core services as images, making this same problem much larger in scale.

## Foremanctl Deployment (Containerized)

### Connected Satellite

1. Register host to Red Hat CDN
2. Enable foremanctl repo, install foremanctl
3. `podman login registry.redhat.io`
4. `foremanctl deploy`
5. Upload manifest, enable and sync repos

### Disconnected Satellite

1. Download Satellite ISO on a connected machine (ISO contains foremanctl RPMs + container image archives)
2. Transfer ISO to disconnected host
3. Mount ISO, configure local repos, install foremanctl
4. Load container images from ISO
5. `foremanctl deploy`
6. Disable subscription connection
7. Upload manifest, configure content source (ISS)

### Capsule (any parent)

1. Register capsule host to the Satellite
2. Install foremanctl from Satellite's repos
3. On Satellite: generate certificate bundle for capsule
4. Transfer cert bundle + infrastructure images to capsule
5. Load images on capsule
6. `foremanctl deploy-proxy`
7. On Satellite: assign lifecycle environments, sync content to capsule

### Key differences from RPM-based model

- **New artifact**: container image archives (in ISO, or exported from Satellite for capsules)
- **New concern**: getting images to disconnected hosts (replaces "getting RPMs to disconnected hosts")
- **Same pattern**: Satellite is always the distribution hub for capsules
- **Fewer distinct flows**: only 3 (connected Satellite, disconnected Satellite, capsule) -- capsule flow is the same regardless of parent connectivity

## ISS Handles Container Images Natively

Tested on a live Satellite: the existing ISS export/import mechanism (`hammer content-export` / `hammer content-import`) works with container image content type (`docker`).

### Export (on upstream/connected Satellite)
```
hammer product create --name "Container Test" --organization "My_Org"
hammer repository create --name "alpine" --product "Container Test" \
  --organization "My_Org" --content-type docker \
  --url "https://registry.hub.docker.com" \
  --docker-upstream-name "library/alpine" --include-tags "latest"
hammer repository synchronize --name "alpine" --product "Container Test" --organization "My_Org"
hammer content-view create --name "Container Export CV" --organization "My_Org"
hammer content-view add-repository --name "Container Export CV" \
  --organization "My_Org" --product "Container Test" --repository "alpine"
hammer content-view publish --name "Container Export CV" --organization "My_Org"
hammer content-export complete version --content-view "Container Export CV" \
  --version "1.0" --organization "My_Org"
```

Produces a directory under `/var/lib/pulp/exports/` with:
- One tar file with all container manifests and blobs
- A `toc.json` (table of contents)
- A `metadata.json` describing product, repo, and content view structure

### Import (on downstream/disconnected Satellite)
```
hammer organization configure-cdn --name "Downstream_Org" --type export_sync
# Copy export files to /var/lib/pulp/imports/<dir>/, chown to pulp:pulp
hammer content-import version --organization "Downstream_Org" \
  --path /var/lib/pulp/imports/<dir>/
```

The import auto-creates: product, repository, content view, content view version, and all container manifests/tags. No manual setup needed on the downstream side.

### Implication

This means Satellite's existing content management can potentially be used to distribute the infrastructure images themselves (the container images that make up Satellite/Capsule services). A dedicated product (e.g., "Satellite Infrastructure Images") could be synced, exported, and imported through the same ISS mechanisms as any other content.

## Open Questions

1. **Single artifact for capsule provisioning?** Should the certificate bundle and capsule image archive be combined into one tarball, or kept separate?
2. **Image subset for capsules.** The capsule flavor (`foreman-proxy-content`) defines the feature set and therefore which images are needed. The export should use the same flavor to determine the image list.
3. **Capsule image updates.** When infrastructure images are updated on the Satellite (new ISO or registry pull), how are updates propagated to existing capsules? Connected capsules could re-pull; disconnected capsules need another export/transfer cycle.
4. **How foremanctl internally pulls/loads images is an implementation detail.** The user-facing workflow described here is agnostic to whether foremanctl uses `podman pull`, `podman load`, `skopeo copy`, or any other mechanism.
