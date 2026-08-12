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

## EVR SQL extension silently strips tilde (~) and caret (^)

The `rpmver_array()` PL/pgSQL function (defined in migration
`20240924161240_katello_recreate_evr_constructs.rb`) strips all non-alphanumeric
characters before parsing version strings into `evr_array_item[]` arrays:

```sql
-- Throw out all non-alphanum characters
while one <> '' and not isalphanum(one)
loop
    one := substr(one, 2);
end loop;
```

`isalphanum()` only recognizes `[a-zA-Z0-9]`. Tilde and caret are stripped, so
`8.0.100~rc.2` is parsed identically to `8.0.100.rc.2`. Since the parsed array
is longer, it sorts AFTER `8.0.100` — the exact opposite of correct RPM behavior.

Per the RPM spec:
- `~` means **pre-release** — `8.0.100~rc.2` sorts BEFORE `8.0.100`
- `^` means **post-release snapshot** — `8.0.100^git1` sorts AFTER `8.0.100` but BEFORE `8.0.101`

This affects **all three EVR comparison paths** in Katello:
1. `evr_t` column (applicability calculation, upgrade dropdown)
2. `version_sortable` strings (`Rpm.latest()`, `PackageFilter`, scoped search)
3. `Rpm.latest()` LEFT OUTER JOIN (uses `version_sortable` under the hood)

The `sortable_version()` Ruby method (`Katello::Util::Package`) also strips tilde
because it uses `scan(/([A-Za-z]+|\d+)/)` which drops non-alphanumeric characters.

**Tracked in:** SAT-38492. See `plans/SAT_38492_EVR_TILDE_FIX.md` for the fix plan.

**Upstream context:** Pulp hit the same bug (pulp_rpm#4124) and worked around it by
moving version comparison from SQL to Python (commits `e974e04e`, `c7bbe48b` by
Daniel Alley). They did NOT fix their SQL extension. PR #4171 attempted a full SQL
rewrite but was abandoned.

## ML-DSA-65 (PQC) certificates are incompatible with TLS 1.2

All TLS 1.2 cipher suites require RSA or ECDSA key exchange/signing. ML-DSA-65
certificates cannot participate in TLS 1.2 handshakes at all -- the handshake
fails regardless of cipher configuration. On PQC-only machines, only TLS 1.3
works (TLS 1.3 uses signature algorithms negotiated separately from cipher suites).
This means TLS 1.2-specific code paths (e.g. `SSL_CTX_set_cipher_list` with
`PROFILE=SYSTEM`) cannot be verified end-to-end on PQC test machines.

## Simplified ACS refresh goes through `simplified_acs_remote_options`, not `remote_options`

In `Pulp3::AlternateContentSource#remote_options`, simplified ACS immediately
returns `simplified_acs_remote_options` when a repository is present. This means
`deb_*` fields, `verify_ssl`, `base_url`, and SSL cert fields are never read for
simplified ACS refreshes. Stale/unexpected data in those columns is inert at runtime.
