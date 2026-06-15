# Pulp Domains in Katello — Effort Analysis

## What Are Pulp Domains?

Pulp domains are an opt-in multi-tenancy feature (`DOMAIN_ENABLED = True` in Pulp settings).
Each domain is an isolated namespace with its own storage backend. All existing objects live
under the `default` domain when first enabled.

**Status**: Still in tech preview as of 2026-06 (pulp/pulpcore#7261 tracks removing that label).

**Plugin compatibility**: All plugins Katello uses are `domain_compatible = True`:
- pulpcore (incl. pulp_file, pulp_certguard) ✅
- pulp_rpm ✅
- pulp_deb ✅
- pulp_container ✅
- pulp_ansible ✅
- pulp_python ✅

## How Domains Change URLs

### API URLs

| Without domains | With domains |
|----------------|-------------|
| `/pulp/api/v3/...` | `/pulp/{domain_name}/api/v3/...` |

The `{pulp_domain}` slug is extracted by `DomainMiddleware` and sets a context variable.
If omitted, falls back to `default`.

Source: `pulpcore/middleware.py`, `pulpcore/app/find_url.py`

### Content URLs

| Without domains | With domains |
|----------------|-------------|
| `/pulp/content/{base_path}/...` | `/pulp/content/{domain_name}/{base_path}/...` |

The content app (aiohttp) registers routes with `{pulp_domain}` in the path:

```python
# pulpcore/content/__init__.py
path_prefix = settings.CONTENT_PATH_PREFIX  # "/pulp/content/"
if settings.DOMAIN_ENABLED:
    path_prefix = path_prefix + "{pulp_domain}/"
```

The domain is extracted via `validate_domain()` in `pulpcore/content/authentication.py`:

```python
domain_name = request.match_info.get("pulp_domain", "default")
```

### Distribution Content URL Field

When distributions report their `base_url` in API responses:

```python
# pulpcore/app/serializers/fields.py
url = urljoin(origin, prefix + "/")
if settings.DOMAIN_ENABLED:
    url = urljoin(url, value.pulp_domain.name + "/")
return urljoin(url, base_path + "/")
```

So a distribution that was at `https://server/pulp/content/Org/Library/custom/prod/repo/`
becomes `https://server/pulp/content/default/Org/Library/custom/prod/repo/`.

### Key Insight: CONTENT_ORIGIN Is Global, Not Per-Domain

There is no per-domain content origin or custom hostname. `CONTENT_ORIGIN` is a single
global setting. All domains share the same base hostname; only the path differs.

**This means domains do NOT introduce separate base URLs for distributed content.**
The content routing difference is purely a path segment insertion.

## Impact on Apache Rules

### Current Apache Configuration (puppet-pulpcore)

The Apache config uses `<Location>` blocks with `ProxyPass` to route to Pulp's unix sockets:

```puppet
# puppet-pulpcore/manifests/apache.pp
$content_path = '/pulp/content'
$content_url = "unix://${pulpcore::content_socket_path}|http://pulpcore-content${content_path}"

$content_directory = {
  'path'       => $content_path,      # <Location /pulp/content>
  'provider'   => 'location',
  'proxy_pass' => [{ 'url' => $content_url }],
}

$api_path = '/pulp/api/v3'
$api_url = "unix://${pulpcore::api_socket_path}|http://pulpcore-api${api_path}"

$api_directory = {
  'path'       => $api_path,          # <Location /pulp/api/v3>
  'provider'   => 'location',
  'proxy_pass' => [{ 'url' => $api_url }],
}
```

### Why Apache Rules Do NOT Need Changing for Content

**The `<Location /pulp/content>` directive matches all sub-paths** — including
`/pulp/content/default/Org/...`. Apache's `<Location>` is prefix-matching by default.
So the existing ProxyPass rule already forwards domain-prefixed content URLs to the
Pulp content app correctly.

The content app itself handles parsing `{pulp_domain}` from the path — Apache
just needs to forward everything under `/pulp/content/` to the content socket, which it
already does.

### API Path Change IS a Problem

The API path changes from `/pulp/api/v3/` to `/pulp/{domain}/api/v3/`. The current
Apache `<Location /pulp/api/v3>` would NOT match `/pulp/default/api/v3/`.

**Two approaches:**
1. Change the Location to `<Location /pulp/>` and let Pulp's own URL routing handle dispatch
2. Add a `<LocationMatch>` pattern like `<LocationMatch "^/pulp/[^/]+/api/v3">`

In practice, Katello would likely only use the `default` domain, so a third option is:
3. Add `<Location /pulp/default/api/v3>` alongside the existing one

### Container and Ansible Paths

- **Container**: `/pulp/container/` — proxied via `puppet-pulpcore/manifests/plugin/container.pp`.
  Would need similar investigation for domain-prefixed paths.
- **Ansible Galaxy**: `/pulp_ansible/galaxy/` — proxied via `puppet-pulpcore/manifests/plugin/ansible.pp`.
  This path is outside `/pulp/` so may not be affected, but needs verification.

## Scope of Katello Code Changes

### 1. Hardcoded `/pulp/content/` Paths (Medium Effort)

These all need updating to insert the domain name:

| File | What |
|------|------|
| `app/models/katello/repository.rb:489` | `full_path()` — builds content URL for clients |
| `app/services/katello/pulp3/repository/yum.rb:88` | Content URL for yum repos |
| `app/services/katello/pulp3/repository/generic.rb:34` | Generic content path prefix |
| `app/helpers/katello/katello_urls_helper.rb:69` | URL helper |
| `app/models/katello/host/content_facet.rb:211` | Path prefix matching |

### 2. Hardcoded `/pulp/api/v3/` Paths (Medium Effort)

Direct href construction that would need domain prefix:

| File | What |
|------|------|
| `app/services/katello/pulp3/content.rb:31` | Upload href construction |
| `app/lib/actions/pulp3/orchestration/repository/import_upload.rb:42` | Upload href |
| `app/lib/actions/pulp3/orchestration/repository/import_repository_upload.rb:11` | Upload href |
| `app/services/katello/pulp3/api/yum.rb:37-39` | Remote href validation |
| `app/models/katello/concerns/smart_proxy_extensions.rb:486` | `pulp3_url` default path |

### 3. Pulp API Client Configuration (Low-Medium Effort)

The auto-generated Ruby clients (e.g., `PulpcoreClient`) get their API path from the
OpenAPI spec. When generated against a domain-enabled Pulp, the spec includes `{pulp_domain}`
as a path parameter marked with `x-isDomain: true`. The generated client should handle
this if configured properly.

Katello's `pulp3_configuration` method (in `smart_proxy_extensions.rb`) sets `config.host`
but does not currently set a domain/base-path override. This would need updating.

### 4. Smart Proxy Plugin (Low Effort)

`smart_proxy_pulp` exposes `content_app_url` (currently `http://pulpcore.example.com/pulp/content`).
This would need to include the domain segment, or stay the same if only using `default`.

### 5. Puppet/Installer Changes (Medium Effort)

- `puppet-pulpcore`: Add `DOMAIN_ENABLED` setting to `settings.py.erb`
- `puppet-pulpcore`: Update Apache `<Location>` for API path
- `foreman-installer`: Add parameter to enable/disable domains
- Smart proxy settings: Potentially update `content_app_url` format

### 6. Test Updates (High Effort)

VCR cassettes, API fixtures, and URL assertions throughout Katello's test suite
reference `/pulp/api/v3/` and `/pulp/content/` paths. These would all need updating.

## Effort Estimate

| Category | Effort | Risk |
|----------|--------|------|
| **Apache/proxy rules** | Low | Low — content paths "just work", API path needs one Location change |
| **Katello hardcoded paths** | Medium | Medium — ~10 files, but each needs careful domain injection |
| **Pulp API client config** | Low-Medium | Medium — depends on generated client domain support |
| **Puppet/installer** | Medium | Low — straightforward config additions |
| **Smart proxy** | Low | Low |
| **Tests** | High | Low risk but high volume of mechanical changes |
| **Total** | **Medium-Large** | **Medium overall** |

## Answering the Key Concern: Apache Rules & Content URLs

**The good news: domains do NOT create different base URLs for content.** There is no
per-domain `CONTENT_ORIGIN`. All domains share the same hostname. The only change is an
extra path segment (`/pulp/content/{domain}/...` instead of `/pulp/content/...`).

**Apache's existing `<Location /pulp/content>` already matches the domain-prefixed path**
because `<Location>` is prefix-matching. The content app handles the domain extraction
internally. So **the Apache content rules would not need to change at all**.

The **only Apache rule that breaks** is the API path: `/pulp/api/v3` → `/pulp/{domain}/api/v3`.
This requires either:
- A `<LocationMatch>` regex pattern, or
- Just adding `<Location /pulp/default/api/v3>` if only the default domain is used

## Strategic Recommendation

If Katello only needs the `default` domain (i.e., enabling domains as a Pulp setting for
forward compatibility, without actually creating multiple domains), the effort is **small**:

1. Set `DOMAIN_ENABLED = True` in settings
2. Fix the API path in Apache config
3. Update ~10 hardcoded path references to include `default/`
4. Update test fixtures

If Katello wants to **actually use multiple domains** (e.g., per-organization storage
backends), the effort is **medium-large** and requires a design phase for:
- Which Katello concept maps to a Pulp domain (Organization? Content View?)
- How to manage domain lifecycle
- How to handle cross-domain operations (export/import, CV promotion)

## Sources

- `pulpcore/app/models/domain.py` — Domain model definition
- `pulpcore/content/__init__.py` — Content app URL registration
- `pulpcore/content/handler.py` — Content request handling with domain filtering
- `pulpcore/content/authentication.py` — Domain extraction from URL
- `pulpcore/middleware.py` — DomainMiddleware for API requests
- `pulpcore/app/find_url.py` — API URL construction with domain slug
- `pulpcore/app/settings.py` — DOMAIN_ENABLED default, CONTENT_PATH_PREFIX
- `pulpcore/app/serializers/fields.py` — Distribution URL construction
- `puppet-pulpcore/manifests/apache.pp` — Apache proxy configuration
- `puppet-pulpcore/manifests/plugin/container.pp` — Container path proxying
- `katello/app/models/katello/repository.rb` — `full_path()` content URL construction
- `katello/app/models/katello/concerns/smart_proxy_extensions.rb` — Pulp API config
- `pulp/pulpcore#7261` — Tracking issue to remove domains from tech preview
