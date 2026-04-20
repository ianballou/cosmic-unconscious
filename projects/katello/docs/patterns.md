# Katello Code Patterns

Recurring patterns observed across the codebase. Updated via `/capture`.

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

## ACS refresh is async (`async_task`), create/update/destroy are sync (`sync_task`)

Refresh returns a 202 with a task object. Create, update, and destroy block until
the Dynflow task completes and return the ACS or a destroy response directly.
