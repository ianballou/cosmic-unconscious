# VCR Testing in Katello

How Katello's Pulp3 orchestration tests record and replay HTTP interactions.

## Overview

Orchestration tests (in `test/actions/pulp3/orchestration/`) run Dynflow actions
that make real HTTP calls to Pulp. VCR intercepts these calls and records them as
YAML cassettes. On subsequent runs (CI, local dev without Pulp), the cassettes
are replayed without hitting the network.

The VCR configuration lives in `test/support/vcr.rb`. The shared test module is
`test/support/pulp3_support.rb` (provides `Katello::Pulp3Support`).

## Key Files

| File | Purpose |
|------|---------|
| `test/support/vcr.rb` | VCR configuration, cassette naming, request matchers |
| `test/support/pulp3_support.rb` | `Pulp3Support` concern (includes `VCR::TestCase`) |
| `test/fixtures/vcr_cassettes/` | Recorded YAML cassettes |

## How Tests Include VCR

Tests that hit Pulp include `Katello::Pulp3Support`, which auto-includes
`VCR::TestCase`. The `VCR::TestCase` concern prepends a `run` method that wraps
each test method in a VCR cassette automatically.

```ruby
class MyPulpTest < ActiveSupport::TestCase
  include Katello::Pulp3Support
  # Each test method gets its own cassette automatically
end
```

Some tests also use explicit `VCR.use_cassette(cassette_name + '_suffix', ...)` blocks
for sub-sections with different match options (e.g., binary uploads that skip body matching).

## Cassette Naming Convention

The auto-generated cassette name is derived from the test class and method:

```
{class_path}/{self_class}/{test_name}.yml
```

Example: `Actions::Pulp3::FileUploadTest#test_upload` becomes:
`actions/pulp3/file_upload/upload.yml`

## Record Modes

Controlled by the `mode` environment variable:

| Mode | Behavior |
|------|----------|
| (unset or `none`) | Replay only. Unmatched requests raise `VCR::Errors::UnhandledHTTPRequestError`. This is the CI default. |
| `all` | Delete existing cassettes and re-record everything against a live Pulp server. |
| `new_episodes` | Keep existing interactions, record any new unmatched requests. |
| `once` | Record if cassette doesn't exist, replay if it does. |

## Request Matching

Default matchers (in order): `[:method, :path, :params, :body_json]`

- `body_json` — custom matcher that parses JSON bodies for comparison (falls back to string comparison on parse errors)
- `params` — custom matcher that compares URI query strings
- Binary upload cassettes typically use `[:method, :path, :params]` (skip body matching)

## Re-recording Cassettes

When VCR errors appear (typically `UnhandledHTTPRequestError`), the cassettes are
stale and need re-recording against a live Pulp server.

### Using ktest (on a dev VM with Pulp running)

```bash
# Re-record specific test files
mode=all ktest test/actions/pulp3/orchestration/file_upload_test.rb \
               test/actions/pulp3/orchestration/apt_update_test.rb \
               test/actions/pulp3/orchestration/yum_update_test.rb

# Re-record a single test file
mode=all ktest test/actions/pulp3/orchestration/yum_update_test.rb
```

### Using bundle exec directly (from the foreman directory)

```bash
cd ../foreman
mode=all bundle exec ruby -Itest ../katello/test/actions/pulp3/orchestration/file_upload_test.rb
```

### Prerequisites for re-recording

- Pulp must be running and accessible (the tests make real HTTP calls)
- Test repos must be importable: `mode=all` automatically copies
  `test/fixtures/test_repos/` to `/var/lib/pulp/sync_imports/` (see `configure_vcr`)
- Candlepin content guard cert must exist at `test/fixtures/certs/content_guard.crt`

## Pending Task Filtering

The VCR config includes a `before_record` hook (`ignore_pending_tasks`) that
discards task-polling responses where the task state is not in
`Katello::Pulp3::Task::FINISHED_STATES`. This prevents cassettes from containing
intermediate polling responses, keeping them deterministic.

## Common VCR Errors and Fixes

### `UnhandledHTTPRequestError` on task GET

```
GET https://hostname/pulp/api/v3/tasks/UUID/
```

The task UUID in the cassette doesn't match because the test ran against a
different Pulp instance. **Fix:** re-record with `mode=all`.

### Cassette has unplayed interactions

```
The cassette contains N HTTP interactions that have not been played back.
```

The test flow changed (fewer API calls than before) or request matching is too
strict. **Fix:** re-record with `mode=all`. If the test is non-deterministic,
consider relaxing `match_requests_on`.

### Teardown failures

If the error occurs in `teardown` (common pattern), it means the test itself
passed but the cleanup Dynflow actions (delete repo, orphan cleanup) make API
calls not in the cassette. The teardown runs inside the same VCR cassette as
the test. **Fix:** re-record with `mode=all`.

## Checking VCR Mode in Tests

```ruby
VCR.live?  # => true when mode != :none (i.e., recording is active)
```

Some tests use this to skip assertions that only make sense against live Pulp.
