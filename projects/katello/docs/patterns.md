# Katello Code Patterns

Recurring patterns observed across the codebase. Updated via `/capture`.

## Pulp3 publication vs repository_version transition

Python repos (and eventually others) are migrating from `publication`-based distribution
to `repository_version`-based distribution. The transition is controlled by two flags
on `RepositoryType`:

- `pulp3_skip_publication true` — new behavior, distributions point to repository_version
- `pulp3_transitioning_from_publication true` — enables fallback logic for N-1 capsules

When `pulp3_transitioning_from_publication` is set, capsule sync code (`repository_mirror.rb`)
catches 400 errors from old Pulp (which doesn't support `repository_version` on Python
distributions) and retries with `publication` via `publication_href_or_create`.

The `publication_href_or_create` method creates a publication on-demand if none exists,
polls the Pulp task, then extracts the publication href. This is the N-1 compatibility
path — new servers don't create publications normally.

### Content path prefixes

Python repos use `/pypi/` as their content path (not `/pulp/content/`). This is set
via `generic_content_path_prefix '/pypi'` in the repository type definition. The
`/pypi/` path requires Apache proxy configuration from puppet-pulpcore. N-1 proxies
without this config serve Python content via the standard `/pulp/content/` path.

## Pulp task data access pattern

`Katello::Pulp3::Task` wraps Pulp task responses. Key access patterns:

- `task.task_data` — returns `HashWithIndifferentAccess`, supports both string and symbol keys
- `task.to_hash` — returns plain `Hash` with **string keys only** (unsafe for symbol access)
- `task[:key]` — delegates to `task_data`, safe
- `task.poll` — refreshes data from Pulp API via `task_data(true)`

Always use `task_data` or `task[:key]` when extracting data. Never use `to_hash` if
downstream code uses symbol keys.

## Capsule sync flow for generic repos

1. `CapsuleContent::Sync` → `SyncCapsule` determines repos needing sync
2. Per-repo: `Pulp3::CapsuleContent::Sync` calls `backend_service.with_mirror_adapter.sync`
3. Then: `GenerateMetadata` — skips publication creation if `pulp3_skip_publication` is true
4. Then: `RefreshDistribution` calls `refresh_distributions` on the mirror adapter
5. `refresh_distributions` either updates existing or creates new distributions
6. For `pulp3_transitioning_from_publication` repos, if Pulp rejects `repository_version`,
   it retries with `publication` (creating one on-demand if needed)

## Content-type-gated validators

Validators that only apply to certain content types are consistently guarded with
`if: :deb?`, `if: :yum?`, etc., or by checking `content_type` inline. New fields
specific to a content type follow the same pattern — they are not validated as
forbidden on other types, just ignored. This is the established convention across
`RootRepository`, `AlternateContentSource`, and related models.

Example from `RootRepository`:
```ruby
validate :ensure_valid_deb_constraints, if: :deb?
changeable_attributes += %w(deb_releases deb_components deb_architectures) if deb?
```

## ACS type-gated validators use `validates … absence: true, if: :simplified?`

Fields that must be blank for simplified ACS (e.g., `base_url`, `subpaths`,
`upstream_username`, `upstream_password`) are guarded with a top-level
`validates … if: :simplified?, absence: true`. This is the correct pattern for
new fields that should be absent on simplified — not an inline check inside a
custom validator method that might early-return before reaching the check.

## Simplified ACS creates one remote per repository, custom/rhui creates one per ACS

`SmartProxyAlternateContentSource` is looked up with `repository_id` for simplified,
without it for custom/rhui. This affects the `backend_service` call signature and
the Pulp remote options path taken.

## Red Hat repos are immutable; custom repos are user-managed

Red Hat repositories synced from the CDN are read-only — users cannot add, remove,
or modify packages. They are identified by `Provider::REDHAT` type. Custom repos
(synced from third-party URLs or populated via upload) allow full user control.

Scopes: `Repository.redhat` and `Repository.custom` filter by provider type.

## Repository product and content metadata (Candlepin)

Red Hat repos carry rich metadata from the subscription manifest via Candlepin:

- `content_label` — CDN repo identifier (e.g., `rhel-9-for-x86_64-baseos-rpms`)
- `content_url` — CDN path with substitution vars (e.g., `/content/dist/rhel8/$releasever/$basearch/baseos/os`)
- `major` / `minor` — version from manifest substitutions (e.g., `9` / `9.4`)
- `product.name` — Candlepin product name (e.g., `Red Hat Enterprise Linux for x86_64`)
- `product.cp_id` — Candlepin product ID

The `Katello::Candlepin::RepositoryMapper` resolves substitution variables
(`$releasever`, `$basearch`) and constructs the repository from content + product
+ substitutions.

Custom repos have none of this — they are just a URL + name + content type.

## Content Views combine repos, not merge them

Content Views group multiple repositories into a promotable unit. Individual repos
maintain their identity — a CV containing RHEL BaseOS + EPEL + custom RPMs still
has three separate repos. Content View Filters can include/exclude packages, but
the underlying repo boundaries persist. Mixing of content happens at the CV level,
not at the repo level.

## RPM metadata: what's stored where

| Field | `katello_rpms` | `katello_installed_packages` | Pulp (`rpm_vendor`) |
|-------|:-:|:-:|:-:|
| name, version, release, arch, epoch | ✅ | ✅ | ✅ |
| vendor | ❌ | ✅ | ✅ |

Katello's RPM model is lean — no vendor, no packager, no description in the DB.
The `Pulp3::Rpm` service class exposes vendor via `backend_data['rpm_vendor']`
for on-demand access. InstalledPackage (what's on a host) does store vendor.

## Pulp polymorphic response monkey patch pattern

`lib/monkeys/pulp_polymorphic_remote_response.rb` works around a pulpcore schema
bug (https://github.com/pulp/pulpcore/issues/7705) where the generated bindings
declare `*Response` as the return type for update endpoints instead of
`AsyncOperationResponse`. The patch forces `debug_return_type: 'AsyncOperationResponse'`
so 202 task responses deserialize correctly. Removable once pulpcore fixes the schema.

The patch list must include **every** API class whose ViewSet inherits `AsyncUpdateMixin`:
- RemoteViewSet: all `Remotes*Api` classes (RPM, ULN, Ansible×3, Container×2, OSTree, Deb, File, Python)
- RepositoryViewSet: all `Repositories*Api` classes
- DistributionViewSet: all `Distributions*Api` classes
- AlternateContentSourceViewSet: all `Acs*Api` classes
- ExporterViewSet: `ExportersFilesystemApi`, `ExportersPulpApi`

Tests live at `test/lib/monkeys/pulp_polymorphic_remote_response_test.rb` — each test
stubs an HTTP PATCH returning 202 with a task href and asserts the result is an
`AsyncOperationResponse`. When bumping Pulp gem versions, add any new API classes to
both the patch list and the test file.

The monkey patch initializer at `config/initializers/monkeys.rb` loads all monkey patches
at boot time.

## ACS refresh is async (`async_task`), create/update/destroy are sync (`sync_task`)

Refresh returns a 202 with a task object. Create, update, and destroy block until
the Dynflow task completes and return the ACS or a destroy response directly.
