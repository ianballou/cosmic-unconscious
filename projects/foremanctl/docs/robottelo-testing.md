# Testing foremanctl with Robottelo

How to write and run integration tests for foremanctl features using robottelo.

## Location

Tests live in `tests/foreman/installer/` alongside the other foremanctl tests:
- `test_install_foremanctl.py` — installation and deploy tests
- `test_foremanctl_health.py` — health check tests

## Fixture Pattern: Getting a foremanctl Satellite

Use a module-scoped fixture with `Broker(workflow='deploy-foreman')`:

```python
from broker import Broker
from robottelo.hosts import Satellite

@pytest.fixture(scope='module')
def foremanctl_sat():
    with Broker(workflow='deploy-foreman', host_class=Satellite) as sat:
        yield sat
```

This checks out a pre-deployed foremanctl box from Broker. Module scope is appropriate
when all tests use the same satellite and each fixture restores state after itself.

For comparison, `test_install_foremanctl.py` uses `Broker(workflow='deploy-rhel')` and
then calls `sat.install_satellite_foremanctl()` because those tests exercise the
installation itself. Health check tests don't need to install — they need an
already-running system.

## Running Commands

Use `sat.execute()` which returns an object with `.status`, `.stdout`, `.stderr`:

```python
result = foremanctl_sat.execute('foremanctl health', timeout='5m')
assert result.status == 0
assert 'failed=0' in result.stdout
```

The `timeout` parameter accepts human-readable strings like `'5m'`, `'10m'`.

## Database Access

foremanctl uses containerized PostgreSQL. Access via `podman exec`:

```python
PSQL_CMD = 'podman exec postgresql psql -U foreman -d foreman -t -A -c'
result = sat.execute(f'{PSQL_CMD} "SELECT count(*) FROM hosts"')
```

Key flags: `-t` (tuples only, no headers), `-A` (unaligned output, no padding).

**Gotcha**: INSERT/UPDATE/DELETE with `RETURNING` produces multiline output like
`236\nINSERT 0 1`. Use `result.stdout.splitlines()[0].strip()` to get just the
returned value, not `result.stdout.strip()` which captures the status line too.

## API Access

The Satellite object exposes the nailgun API via `sat.api`:

```python
# Create a host
host = foremanctl_sat.api.Host(name='test-host').create()

# Upload facts (creates host if it doesn't exist)
foremanctl_sat.api.Host().upload_facts(
    data={'name': hostname, 'certname': hostname, 'facts': facts_dict}
)

# Search and delete
hosts = foremanctl_sat.api.Host().search(query={'search': f'name={hostname}'})
hosts[0].delete()
```

**Gotcha**: `upload_facts` on a non-existent hostname requires at minimum
`operatingsystem` and `operatingsystemrelease` in the facts dict, or it returns 422.

## Service Management in Fixtures

When a test stops a service, the fixture teardown must wait for it to be fully back,
not just `sleep`. Use `wait_for` from the `wait_for` package:

```python
from wait_for import wait_for

@pytest.fixture
def stopped_redis(self, foremanctl_sat):
    foremanctl_sat.execute('systemctl stop redis.service')
    yield
    foremanctl_sat.execute('systemctl start redis.service')
    wait_for(
        lambda: foremanctl_sat.execute('systemctl is-active redis.service').status == 0,
        timeout=30,
        delay=2,
    )
```

For foreman (which has many dependent services), wait for `hammer ping` instead of
just `systemctl is-active`:

```python
wait_for(
    lambda: foremanctl_sat.execute('hammer ping').status == 0,
    timeout=300,
    delay=10,
    handle_exception=True,
)
```

`handle_exception=True` swallows connection errors during startup. The 300s timeout
matches what satellite-maintain tests use — foreman can take 2-3 minutes to fully start
in containerized mode.

**Gotcha**: `hammer ping --request-timeout 5` may not be available on all foremanctl
builds. Use plain `hammer ping`.

## Module Docstring Convention

All test files need testimony tokens for CI filtering. Match the sibling files:

```python
"""Tests for foremanctl health subcommand checks

:Requirement: Installation

:CaseAutomation: Automated

:CaseComponent: Installation

:Team: Rocket

:CaseImportance: Critical
"""
```

`CaseImportance` is actively parsed by `pytest_plugins/metadata_markers.py` and used
for `--importance` filtering in CI. Don't set it to `High` when the sibling files
all use `Critical`.

## Markers

- `pytest.mark.foremanctl` — registered in `pytest_plugins/markers.py`, use for all
  foremanctl tests
- `pytest.mark.e2e` — for end-to-end happy-path tests
- `pytest.mark.destructive` — don't use for tests that run against a Broker-provisioned
  box via a custom fixture. The `destructive` marker causes `module_target_sat` to
  provision a new satellite via `satellite_factory()`, which is not what you want when
  using your own `foremanctl_sat` fixture

## What Belongs in SQL vs API

Robottelo is integration testing — prefer the API over raw SQL. Rules of thumb:

- **Host creation**: Use `sat.api.Host().create()` or `sat.api.Host().upload_facts()`
- **Fact upload**: Use `host.upload_facts(data={...})`
- **Errored tasks**: SQL is OK — there's no API to directly create a paused+errored
  task. The satellite-maintain tests use `foreman-rake console` (Ruby eval) which is
  equally non-user-facing
- **Duplicate permissions**: SQL is the only option — this is a DB corruption scenario
  with no API path. The existing `test_health.py` for satellite-maintain uses the same
  `psql INSERT` pattern

## foremanctl Health Check Output

`foremanctl health` runs an Ansible playbook. The output is Ansible's standard output:
- Exit code 0: all checks passed (`failed=0` in PLAY RECAP)
- Exit code 2: one or more checks failed (`failed=1` or more in PLAY RECAP)
- Check success messages appear as `msg: All assertions passed`
- Check failure messages appear as `msg: <role-specific failure text>`
- Ansible task names like "Query for duplicate permissions" appear in stdout even when
  the check passes — don't assert on task names, assert on failure message text

## Ansible-Specific Output Gotchas

- The `[DEPRECATION WARNING]` for `db:` alias appears in stderr, not stdout
- Role names (like `check_duplicate_permissions`) appear in task names in stdout even
  on success — don't use them as failure indicators
- The failure report at the end aggregates all check failures into one `msg:` block
