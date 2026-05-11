# Katello Gotchas

Surprising behaviors and hard-won knowledge. Updated via `/capture`.

## `to_hash` on HashWithIndifferentAccess strips indifferent access

`HashWithIndifferentAccess#to_hash` returns a plain `Hash` with **string keys only**.
Code that accesses the result with symbol keys silently gets `nil`:

```ruby
h = { "created_resources" => ["/pulp/api/v3/publications/..."] }.with_indifferent_access
h[:created_resources]           # => ["/pulp/api/v3/publications/..."]  ✅
h.to_hash[:created_resources]   # => nil  ❌
h.to_hash["created_resources"]  # => ["/pulp/api/v3/publications/..."]  ✅
```

This bit `Katello::Pulp3::Task` — the `publication_href` class method uses symbol
keys (`task[:created_resources]`), which works when callers pass
`HashWithIndifferentAccess` data directly. But `publication_href_or_create` in
`repository_mirror.rb` called `task.to_hash`, stripping indifferent access, causing
`created_resources` to silently return `nil`. The `nil` then crashed at
`href.include?('/publications/')` → `NoMethodError: undefined method 'include?' for nil`.

**Rule:** Never use `to_hash` when the consumer expects symbol-key access. Use
`task_data` (which preserves HWIA) or explicitly call `.with_indifferent_access`
on the result. When writing methods that extract data from hashes, always add
`.compact` before iterating to guard against nil values from upstream.

## ACS: `smart_proxy_ids` and `product_ids` are top-level params, not nested

The ACS controller's `find_smart_proxies` and `find_products` methods read from
top-level `params`, not from `params[:alternate_content_source]`. All other ACS
fields are nested. So when calling the API directly you must send:

```json
{
  "smart_proxy_ids": [1],
  "product_ids": [2],
  "alternate_content_source": { "name": "...", ... }
}
```

## Repositories controller assigns deb_* fields unconditionally regardless of content_type

In `Api::V2::RepositoriesController`, `deb_releases`, `deb_components`, and
`deb_architectures` are permitted params and assigned to the root repo without
any content_type guard:

```ruby
root.deb_releases = repo_params[:deb_releases] if repo_params[:deb_releases]
root.deb_components = repo_params[:deb_components] if repo_params[:deb_components]
root.deb_architectures = repo_params[:deb_architectures] if repo_params[:deb_architectures]
```

Passing these fields to a yum or file repository via the API produces a 201 with
no error. The model's only protection (`ensure_valid_deb_constraints`) is gated
with `if: :deb?` and only checks internal consistency (releases ↔ url), not that
the fields are absent on non-deb types. Pre-existing pattern — not specific to any
one PR.

## deb_* fields on non-deb records are silently ignored (pre-existing pattern)

Passing `deb_releases`, `deb_components`, or `deb_architectures` to a yum or
file repository or ACS does not raise a validation error. The values are either
stored but never returned (ACS) or simply discarded. This is a known pre-existing
pattern — `ensure_valid_deb_constraints` on `RootRepository` and
`deb_fields_xor_subpaths` on `AlternateContentSource` are both gated with
`if: :deb?` or `return if simplified?`, so they never fire for other types.
Not a concern for individual PRs that follow this pattern — it predates them.

## Pulp polymorphic response monkey patch (pulpcore schema bug)

Pulpcore 3.90+ update/partial_update endpoints (via `AsyncUpdateMixin`) return
HTTP 202 `{"task": "..."}` when changes are detected, or HTTP 200 with the resource
when nothing changed. The pulpcore OpenAPI schema generator incorrectly declares
the resource type (e.g. `RpmRpmRemoteResponse`) as the return type instead of
`AsyncOperationResponse`. The 3.85-era bindings had this right; the 3.105+ bindings
regressed. Since `*Response` models have no `task` attribute, the task href from
202 responses is silently dropped during deserialization — Dynflow never tracks it.

**The fix:** `lib/monkeys/pulp_polymorphic_remote_response.rb` forces
`debug_return_type: 'AsyncOperationResponse'` on all update methods. On 202 the
task href deserializes correctly; on 200 (no-op) `task=nil`, which callers handle.

**Upstream bug:** https://github.com/pulp/pulpcore/issues/7705
Remove the monkey patch when pulpcore fixes the schema. No N-1 concerns — the
bindings live on the Katello server, not the capsule, so fixed bindings work
against both 3.85 (always 202) and 3.105 (202 or 200) capsules.

**When bumping Pulp gems:** Every API class whose ViewSet inherits
`AsyncUpdateMixin` must be in the patch list. Don't assume any gem already
returns `AsyncOperationResponse` — verify with:
```ruby
# In .vendor/ruby/3.0.0/gems/pulp_*_client-*/lib/pulp_*_client/api/*.rb
return_type = opts[:debug_return_type] || 'FileFileRemoteResponse'  # ❌ needs patch
return_type = opts[:debug_return_type] || 'AsyncOperationResponse'  # ✅ correct
```

See https://projects.theforeman.org/issues/39305 for the original discovery.

**Backward compatibility confirmed:** Forcing `AsyncOperationResponse` on
file/deb/python remote updates works against pulpcore 3.73 (N-2) and 3.85 (N-1).
Those older versions always return HTTP 202 for PATCH operations (they don't have
`AsyncUpdateMixin`'s 200-when-no-op optimization). The `AsyncOperationResponse`
deserializes correctly from their 202 responses. Tested May 2026 with capsule
syncs of file (250 files), deb (3 packages), and python (158 packages) repos.

## Simplified ACS refresh goes through `simplified_acs_remote_options`, not `remote_options`

In `Pulp3::AlternateContentSource#remote_options`, simplified ACS immediately
returns `simplified_acs_remote_options` when a repository is present. This means
`deb_*` fields, `verify_ssl`, `base_url`, and SSL cert fields are never read for
simplified ACS refreshes. Stale/unexpected data in those columns is inert at runtime.
