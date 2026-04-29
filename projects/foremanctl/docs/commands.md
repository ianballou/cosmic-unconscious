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
- **Tracked?** SAT-44798
- **Size**: Story under SAT-40932
- **Note**: New `foremanctl health` command for runtime health checks.

### `service` — Start/stop/restart/status/enable/disable/list services
- **Need it?** No — with `foreman.target`, this becomes less necessary to have. Introduce only as necessary.
- **Tracked?** N/A
- **Size**: N/A

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
- **Tracked?** SAT-44796
- **Size**: Story under SAT-40932. Depends on SAT-39696 (upgrade), SAT-39697 (update).

### `report` — Generate usage/inventory reports
- **Need it?** Move — SatStats reporting should ideally move to another tool since it's unrelated to configuring Foreman. This way it could remain Ruby too.
- **Tracked?** Needs ticket
- **Size**: Epic

### `packages` — RPM locking, install, update
- **Need it?** No — very few host RPMs in containerized model. Can users just manage RPMs with dnf? Or do we still need gating with dnf filtering?
- **Tracked?** N/A
- **Size**: N/A

### `self-upgrade` — Update the tool itself
- **Need it?** Rethink — enables newer maintenance repository and updates foreman-maintain today. The upgrade process will define if this is still necessary.
- **Tracked?** SAT-44795
- **Size**: Task under SAT-40932

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

| Functionality | Recommendation | Tracked? | Size | Notes |
|---------------|---------------|----------|------|-------|
| upgrade | Keep | SAT-39696 | Epic (in progress) | In progress. |
| update | Keep | SAT-39697 | Epic (in progress) | In progress. |
| health | Keep | SAT-44798 | Story under SAT-40932 | New `foremanctl health` command for runtime health checks. |
| service | Drop | N/A | -- | With foreman.target, this becomes less necessary. Introduce only as necessary. |
| backup | Keep | Needs ticket | Epic (combined with restore) | Largest untracked area. What to back up may change significantly. |
| restore | Keep | Needs ticket | Epic (combined with backup) | To be implemented in the backup epic. |
| maintenance-mode | Keep | SAT-44796 | Story under SAT-40932 | Blocks port 443, stops timers, disables sync plans. Depends on SAT-39696, SAT-39697. |
| report | Move | Needs ticket | Epic | SatStats reporting should ideally move to another tool since it's unrelated to configuring Foreman. |
| packages | Drop | N/A | -- | Very few host RPMs in containerized model. |
| self-upgrade | Rethink | SAT-44795 | Task under SAT-40932 | Enables newer maintenance repository and updates foreman-maintain today. The upgrade process will define if this is still necessary. |
| advanced | Drop | N/A | -- | Developers can run Ansible roles/playbooks directly. Don't build unless a need is identified. |
| plugin/puppet purge | Reworked | SAT-40445 | Story (within Puppet epic) | Rework is in-progress. `plugin` can likely go away, but removing Puppet is TBD. |
| feature detection | Keep | (implicit) | Story | |
| interactive prompts | TBD | Needs ticket | Story | |
