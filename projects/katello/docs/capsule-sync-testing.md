# Capsule Sync Testing on Smart Proxy VMs

How to test capsule syncs across different Pulpcore versions, inspect Dynflow task
tracking, and verify Pulp API calls on smart proxy VMs.

## Forklift Box Names

| Box | Pulpcore | Use |
|---|---|---|
| `centos9-stream-katello-nightly` | Current (e.g. 3.105) | Katello server |
| `centos9-stream-foreman-proxy-nightly` | Current | Proxy — same version |
| `centos9-stream-foreman-proxy-4.20-n1` | N-1 (e.g. 3.85) | Proxy — previous release |
| `centos9-stream-foreman-proxy-4.20-n2` | N-2 (e.g. 3.73) | Proxy — two releases back |

These versions shift with each Katello release. Check `rpm -q pulpcore`
on each proxy to confirm the actual version.

## Quick Setup: Repos, CVs, and Capsule Sync

```bash
# Create products & repos for each content type
hammer product create --organization-id 1 --name "File Test"
hammer repository create --organization-id 1 --product "File Test" \
  --name "File Repo" --content-type file \
  --url "https://fixtures.pulpproject.org/file-many/"

hammer product create --organization-id 1 --name "Deb Test"
hammer repository create --organization-id 1 --product "Deb Test" \
  --name "Deb Repo" --content-type deb \
  --url "https://fixtures.pulpproject.org/debian/" \
  --deb-releases ragnarok --deb-components main --deb-architectures amd64

hammer product create --organization-id 1 --name "Python Test"
hammer repository create --organization-id 1 --product "Python Test" \
  --name "Python Repo" --content-type python \
  --url "https://fixtures.pulpproject.org/python-pypi/" \
  --python-package-includes '["shelf-reader"]'

# Sync repos
hammer repository synchronize --organization-id 1 --product "File Test" --name "File Repo"
hammer repository synchronize --organization-id 1 --product "Deb Test" --name "Deb Repo"
hammer repository synchronize --organization-id 1 --product "Python Test" --name "Python Repo"

# Create content views, add repos, publish, promote
hammer content-view create --organization-id 1 --name "File CV"
hammer content-view add-repository --organization-id 1 --name "File CV" \
  --product "File Test" --repository "File Repo"
hammer content-view publish --organization-id 1 --name "File CV"
hammer content-view version promote --organization-id 1 --content-view "File CV" \
  --to-lifecycle-environment Dev

# Repeat for Deb CV, Python CV...

# Assign lifecycle environment to proxy
hammer capsule content add-lifecycle-environment --id <proxy_id> \
  --organization-id 1 --lifecycle-environment Dev

# Trigger capsule sync
hammer capsule content synchronize --id <proxy_id>
```

## Checking Pulpcore Version on a Proxy

```bash
ssh proxy "rpm -q pulpcore"
```

Or via the Pulp API:
```bash
ssh proxy "curl -s -k --cert /etc/pki/katello/certs/pulp-client.crt \
  --key /etc/pki/katello/private/pulp-client.key \
  https://localhost/pulp/api/v3/status/ | python3 -m json.tool | grep version"
```

## Verifying Pulp Task Tracking in Dynflow

The critical question: are Pulp tasks (returned as task hrefs in 202 responses)
actually recorded in Dynflow action output? Use Rails console on the Katello server:

```ruby
# Find the capsule sync task
task = ForemanTasks::Task.find("TASK_UUID")
ep = task.execution_plan

# Walk all actions and check pulp_tasks in their output
ep.actions.each do |action|
  pulp_tasks = action.output.dig(:pulp_tasks) || action.output.dig("pulp_tasks")
  next unless pulp_tasks
  puts "#{action.class.name} | state=#{action.run_step&.state} | pulp_tasks=#{pulp_tasks.length}"
  pulp_tasks.each { |pt| puts "  task_href=#{pt['task']}" }
end
```

### What to look for

| Action | Expected pulp_tasks |
|---|---|
| `Pulp3::Orchestration::Repository::RefreshRepos` | 1 per remote that changed (PATCH returned 202) |
| `Pulp3::CapsuleContent::Sync` | 1 per repo sync |
| `Pulp3::CapsuleContent::GenerateMetadata` | 1 per publication created (0 if `pulp3_skip_publication`) |
| `Pulp3::CapsuleContent::RefreshDistribution` | 1 per distribution update/create (0 if no changes) |

If `pulp_tasks` is 0 for a Sync or RefreshDistribution that should have done work,
the response deserialization is broken (likely the monkey patch issue).

## Checking Pulp API Calls on a Proxy

The most direct way to see what HTTP calls hit the proxy's Pulp API:

```bash
# All PATCH/PUT/POST calls (mutations)
ssh proxy "sudo journalctl -u pulpcore-api --since '10 minutes ago' --no-pager | \
  grep -E 'PATCH|PUT|POST'"
```

### Key response codes to watch for

| Code | Meaning |
|---|---|
| **200** | No-op (no changes detected) — `AsyncOperationResponse.task` will be `nil` |
| **202** | Task dispatched — response has `{"task": "/pulp/api/v3/tasks/..."}` |
| **400** | Bad request — often means the Pulp version doesn't support a field (e.g. `repository_version` on old Python distributions) |
| **404** | Resource not found — remote/repo/distribution was deleted or never created |

### The Python distribution 400 → retry pattern

On N-1 and N-2 capsules, Python distributions don't support `repository_version`.
The code sends a PATCH with `repository_version`, gets a 400, then retries with
`publication` (creating one on-demand if needed). This shows up as:

```
PATCH /pulp/api/v3/distributions/python/pypi/UUID/ HTTP/1.1" 400
POST /pulp/api/v3/publications/python/pypi/ HTTP/1.1" 202      # create publication
PATCH /pulp/api/v3/distributions/python/pypi/UUID/ HTTP/1.1" 202  # retry with publication
```

This is **expected** behavior for `pulp3_transitioning_from_publication` repos.

## Verifying Content on a Proxy

Check content counts via Pulp API on the proxy:

```bash
# List repositories and their latest version content summary
ssh proxy "curl -s -k --cert /etc/pki/katello/certs/pulp-client.crt \
  --key /etc/pki/katello/private/pulp-client.key \
  'https://localhost/pulp/api/v3/repositories/file/file/?fields=name,latest_version_href' | \
  python3 -m json.tool"

# Get content counts from a specific version
ssh proxy "curl -s -k --cert /etc/pki/katello/certs/pulp-client.crt \
  --key /etc/pki/katello/private/pulp-client.key \
  'https://localhost/pulp/api/v3/repositories/file/file/UUID/versions/1/' | \
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get(\"content_summary\",{}), indent=2))'"
```

Or use hammer from the Katello server:
```bash
hammer capsule content info --id <proxy_id>
```

## Forcing Real Updates (Not No-ops)

If content is already synced, capsule syncs become no-ops — no PATCH calls, no
task tracking to verify. To force actual changes:

### Option 1: Delete mirror repos on the proxy
```bash
# Delete all Pulp repos on the proxy (nuclear option)
ssh proxy "curl -s -k --cert /etc/pki/katello/certs/pulp-client.crt \
  --key /etc/pki/katello/private/pulp-client.key \
  'https://localhost/pulp/api/v3/repositories/file/file/' | \
  python3 -c 'import json,sys; [print(r[\"pulp_href\"]) for r in json.load(sys.stdin)[\"results\"]]'" | \
while read href; do
  ssh proxy "curl -s -k -X DELETE --cert /etc/pki/katello/certs/pulp-client.crt \
    --key /etc/pki/katello/private/pulp-client.key \
    'https://localhost${href}'"
done
```

### Option 2: Remove and re-add lifecycle environment
```bash
hammer capsule content remove-lifecycle-environment --id <proxy_id> \
  --organization-id 1 --lifecycle-environment Dev
hammer capsule content add-lifecycle-environment --id <proxy_id> \
  --organization-id 1 --lifecycle-environment Dev
hammer capsule content synchronize --id <proxy_id>
```

### Option 3: Publish a new CV version and promote
This changes the repository version, forcing distribution updates:
```bash
hammer content-view publish --organization-id 1 --name "File CV"
hammer content-view version promote --organization-id 1 --content-view "File CV" \
  --to-lifecycle-environment Dev
hammer capsule content synchronize --id <proxy_id>
```

## Async Update Handling: Pulpcore Version Differences

| Pulpcore | Behavior for PATCH on remotes/repos/distributions |
|---|---|
| 3.73 (N-2) | Always returns 202 with task href (no `AsyncUpdateMixin`, old behavior) |
| 3.85 (N-1) | Always returns 202 with task href (same old behavior) |
| 3.90+ | Returns 202 when changes detected, 200 when no-op (`AsyncUpdateMixin`) |
| 3.105+ | Same as 3.90+ but OpenAPI schema regression — bindings declare wrong return type |

The monkey patch in `lib/monkeys/pulp_polymorphic_remote_response.rb` fixes the
3.105+ schema regression. It's **backward compatible** with 3.73 and 3.85 because:
- Those versions always return 202, and `AsyncOperationResponse` deserializes correctly
- The `task=nil` guard in callers (`response.respond_to?(:task) && response.task.present?`)
  handles the 200 no-op case (which only occurs on 3.90+)

## Production Log Inspection

```bash
# Mark position before test
ssh katello "sudo wc -l /var/log/foreman/production.log"
# ... run test ...
# Check for errors after line N
ssh katello "sudo tail -n +N /var/log/foreman/production.log | grep -i 'error\|exception\|fail'"
```

## Common Failure Modes

| Symptom | Cause | Fix |
|---|---|---|
| Capsule sync succeeds but Pulp tasks show 0 | Response deserialization drops task href | Check monkey patch covers the API class |
| `NoMethodError: undefined method 'task' for #<FileFileRemoteResponse>` | API class not in monkey patch list | Add to `pulp_polymorphic_remote_response.rb` |
| Python distribution PATCH → 400 → no retry | `pulp3_transitioning_from_publication` not set | Check `lib/katello/repository_types/python.rb` |
| Duplicate name constraint on proxy | Orphaned repos from prior failed syncs | Delete orphaned repos via Pulp API on proxy |
| Capsule sync "warning" result | One sub-task failed but others succeeded | Check sub-task details in Dynflow |
