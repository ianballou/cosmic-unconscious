# Populating Dummy Host Data via Rails Console

How to create fake hosts with content facets for manual testing.

## Why This Is Tricky

Foreman hosts require several associated objects to be valid. You can't just
`Host::Managed.create(name: ...)` — you need organization, location, content
facet with a content view environment, and the right smart proxy. The content
facet itself requires a `content_view_environment_content_facet` join record
linking it to a `ContentViewEnvironment`.

## Minimal Host + Content Facet Recipe

```ruby
# Run from foreman directory: bundle exec rails runner script.rb

org = Organization.find_by(name: 'Default Organization')
loc = Location.find_by(name: 'Default Location')
proxy = SmartProxy.first                          # content source (your local Foreman)
cve = Katello::ContentViewEnvironment.first       # Default Org View + Library

host = ::Host::Managed.new(
  name:            "test-host-001.example.com",
  organization:    org,
  location:        loc,
  managed:         false    # skip PXE/DHCP/DNS orchestration
)
host.save!(validate: false) # bypass full host validations (OS, arch, etc.)

content_facet = Katello::Host::ContentFacet.create!(
  host:              host,
  content_source_id: proxy.id,
  # add whatever columns you need to test:
  bootc_booted_image:  "registry.example.com/rhel9/bootc:9.4",
  bootc_booted_digest: "sha256:aaa111...",
)

# Link content facet to a content view environment (required for scoped_search)
Katello::ContentViewEnvironmentContentFacet.create!(
  content_view_environment_id: cve.id,
  content_facet_id:            content_facet.id
)
```

## Bulk Creation Pattern

```ruby
org   = Organization.find_by(name: 'Default Organization')
loc   = Location.find_by(name: 'Default Location')
proxy = SmartProxy.first
cve   = Katello::ContentViewEnvironment.first

data = [
  { image: "quay.io/fedora/fedora-bootc:41", digest: "sha256:ccc111...", count: 5 },
  { image: "quay.io/fedora/fedora-bootc:41", digest: "sha256:ccc222...", count: 2 },
  { image: "registry.example.com/rhel9/base:9.4", digest: "sha256:aaa111...", count: 3 },
]

data.each do |entry|
  entry[:count].times do |i|
    host = ::Host::Managed.new(
      name: "#{entry[:image].split('/').last.tr(':', '-')}-#{i}-#{SecureRandom.hex(4)}.example.com",
      organization: org, location: loc, managed: false
    )
    host.save!(validate: false)

    cf = Katello::Host::ContentFacet.create!(
      host: host,
      content_source_id: proxy.id,
      bootc_booted_image: entry[:image],
      bootc_booted_digest: entry[:digest],
    )
    Katello::ContentViewEnvironmentContentFacet.create!(
      content_view_environment_id: cve.id, content_facet_id: cf.id
    )
  end
end
```

## Key Objects You Need

| Object | How to find | Notes |
|---|---|---|
| `Organization` | `Organization.find_by(name: 'Default Organization')` | Required on host |
| `Location` | `Location.find_by(name: 'Default Location')` | Required on host |
| `SmartProxy` | `SmartProxy.first` | Content source for the content facet |
| `ContentViewEnvironment` | `Katello::ContentViewEnvironment.first` | Default Org View + Library; needed for scoped_search to work |

## Content Facet Bootc Columns

All are nullable strings on `katello_content_facets`:

- `bootc_booted_image` / `bootc_booted_digest` — currently running image
- `bootc_staged_image` / `bootc_staged_digest` — staged for next boot
- `bootc_rollback_image` / `bootc_rollback_digest` — previous image for rollback
- `bootc_available_image` / `bootc_available_digest` — available update

Digests are validated as `sha256:` format with max 71 chars.

## Gotchas

- **`save!(validate: false)`** — Host validations require OS, architecture, etc.
  For dummy data you don't need those, so bypass validation. The host record is
  still functional for API queries.
- **`managed: false`** — Prevents Foreman from trying to orchestrate DHCP/DNS/TFTP.
- **ContentViewEnvironmentContentFacet** — Without this join record, scoped_search
  queries that filter by content view or lifecycle environment will miss the host.
  The `bootc_host_image_map` method in the controller uses `search_for()` which
  goes through scoped_search, so this linkage matters.
- **Cleanup** — To remove test data:
  ```ruby
  hosts = Host::Managed.where("name LIKE ?", "%-test-%")
  hosts.each { |h| h.content_facet&.destroy; h.destroy }
  ```
