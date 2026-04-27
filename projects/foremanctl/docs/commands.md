# foreman-maintain → foremanctl: Functionality Proposal

The following commands exist today in foreman-maintain. The recommendations below prescribe which to keep, and how to track implementation of each.

---

## Commands

### `upgrade` — Major version upgrade orchestration
- **Need it?** Yes
- **Tracked?** SAT-39696
- **Size**: Epic (already in progress)
- **Note**: In progress.

### `update` — Minor version update orchestration
- **Need it?** Yes
- **Tracked?** SAT-39697
- **Size**: Epic (already in progress)

### `health` — Health checks
- **Need it?** Yes — checks need individual evaluation (see [checks.md](checks.md))
- **Tracked?** Needs ticket
- **Size**: Story within a small Epic combined with service
- **Note**: New `foremanctl health` command for runtime health checks.

### `service` — Start/stop/restart/status/enable/disable/list services
- **Need it?** Yes — users still need service lifecycle management. Implementation shifts to systemd targets and container operations.
- **Tracked?** Needs ticket
- **Size**: Story within a small Epic combined with health

### `backup` — Online/offline backup
- **Need it?** Yes — fundamental pre-maintenance safety net. What to back up may change significantly.
- **Tracked?** Needs ticket
- **Size**: Epic (combined with restore)

### `restore` — Restore from backup
- **Need it?** Yes — paired with backup.
- **Tracked?** Needs ticket
- **Size**: Epic (combined with backup) — to be implemented in the backup epic.

### `maintenance-mode` — Block external access during maintenance
- **Need it?** Yes — blocks port 443 via firewall, stops timers, disables sync plans.
- **Tracked?** Needs ticket
- **Size**: Story (within upgrade Epic)

### `report` — Generate usage/inventory reports
- **Need it?** Yes — useful for support cases, pre-upgrade audits, understanding what's deployed.
- **Tracked?** Needs ticket
- **Size**: Epic — 36 report definitions in foreman-maintain. Each report queries Foreman API or DB. Need to evaluate which reports carry over and whether the query mechanisms change.

### `packages` — RPM locking, install, update
- **Need it?** No — very few host RPMs in containerized model. Can users just manage RPMs with dnf? Or do we still need gating with dnf filtering?
- **Tracked?** N/A
- **Size**: N/A

### `self-upgrade` — Update the tool itself
- **Need it?** No — for foremanctl this is just `dnf upgrade foremanctl`. Does this need a separate command?
- **Tracked?** N/A
- **Size**: N/A

### `advanced` — Run individual procedures by label/tag
- **Need it?** No — developers can run Ansible roles/playbooks directly. Don't build unless a need (e.g. support?) is identified.
- **Tracked?** N/A
- **Size**: N/A

### `plugin purge-puppet` — Remove Puppet feature
- **Need it?** Reworked — rework is in-progress. `plugin` can likely go away, but removing Puppet is to-be-determined.
- **Tracked?** SAT-40445 (already in progress)
- **Size**: Story (within the Puppet epic)

---

## Orchestration

foreman-maintain scenarios run a number of tasks sequentially. If one task is failing, users have the ability to skip it via `--whitelist`. With foremanctl, this functionality may be missed. If it is, we can consider implementing skips via Ansible `--skip-tags`.

---

## Cross-cutting Concerns

### Feature detection
- **foreman-maintain**: Runtime Ruby class introspection detects what's installed (is Katello present? is Puppet installed? local or external DB?)
- **foremanctl**: Static `features.yaml` registry + Ansible facts
- **Need it?** Yes — checks and procedures need to know what's deployed to run conditionally
- **Tracked?** Implicit in each command's implementation
- **Size**: Story — Ansible facts + features.yaml should cover most cases

### Interactive prompts / confirmations
- **foreman-maintain**: Has `--assumeyes`, confirmation dialogs, decision prompts via Clamp/HighLine
- **foremanctl**: Ansible is non-interactive by default
- **Need it?** TBD — some operations (destructive backup, restore) benefit from confirmation. Need to decide on approach: CLI flag? Ansible `pause` module? Obsah-level parameter?
- **Tracked?** Needs ticket (design decision)
- **Size**: Story

### Error handling / rollback
- **foreman-maintain**: Runner tracks step success/failure, offers next steps, supports whitelisting failed checks
- **foremanctl**: Ansible has `block/rescue/always`, `--force-handlers`, and the callback plugin for output
- **Need it?** Yes — complex workflows (upgrade, backup) need graceful failure handling
- **Tracked?** Implicit in each Epic
- **Size**: Part of each Epic's implementation

---

## Summary

| Functionality | Recommendation | Tracked? | Size |
|---------------|---------------|----------|------|
| upgrade | Keep | SAT-39696 | Epic (in progress) |
| update | Keep | SAT-39697 | Epic (in progress) |
| health checks | Keep | Needs ticket | Story within a small Epic combined with service |
| service mgmt | Keep | Needs ticket | Story within a small Epic combined with health |
| backup | Keep | Needs ticket | Epic (combined with restore) |
| restore | Keep | Needs ticket | Epic (combined with backup) |
| maintenance-mode | Keep | Needs ticket | Story (within upgrade Epic) |
| report | Keep | Needs ticket | Epic |
| packages | Drop | N/A | -- |
| self-upgrade | Drop | N/A | -- |
| advanced | Drop | N/A | -- |
| plugin/puppet purge | Reworked | SAT-40445 | Story (within Puppet epic) |
| feature detection | Keep | (implicit) | Story |
| interactive prompts | TBD | Needs ticket | Story |
