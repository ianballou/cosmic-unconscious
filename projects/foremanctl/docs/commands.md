# foreman-maintain → foremanctl: Functionality Proposal

For each piece of foreman-maintain functionality:
1. **Do we still need it?** (Yes / No / Rethink / TBD)
2. **Where is it tracked?** (Jira ticket or "Needs ticket")
3. **How big is it?** (Story / Epic)

---

## Commands

### `upgrade` — Major version upgrade orchestration
- **Need it?** Yes
- **Tracked?** SAT-39696
- **Size**: Epic (already in progress)
- **Note**: Upgrade workflow must stop recurring systemd timers (`foreman-recurring@*.timer`) before upgrading and re-enable after. These replace crond from foreman-maintain's upgrade flow.

### `update` — Minor version update orchestration
- **Need it?** Yes
- **Tracked?** SAT-39697
- **Size**: Epic (already in progress)

### `health` — Health checks
- **Need it?** Yes — checks need individual evaluation (see [checks.md](checks.md))
- **Tracked?** Needs ticket
- **Size**: Epic — ~25 checks carry over, ~8 need rethinking, new container-specific checks needed

### `service` — Start/stop/restart/status/enable/disable/list services
- **Need it?** Yes — users still need service lifecycle management. Implementation shifts to systemd targets and container operations.
- **Tracked?** Needs ticket
- **Size**: Story — Ansible has strong systemd/service primitives, and foremanctl already uses `foreman.target`

### `backup` — Online/offline backup
- **Need it?** Yes — fundamental pre-maintenance safety net. What to back up changes significantly: container volumes, podman secrets, DB dumps (possibly from containerized PostgreSQL), config files, certificates.
- **Tracked?** Needs ticket
- **Size**: Epic — foreman-maintain has ~15 backup procedures. Needs full redesign for container world: what data lives where, how to dump DBs from containers, volume snapshot vs file copy, etc.

### `restore` — Restore from backup
- **Need it?** Yes — paired with backup.
- **Tracked?** Needs ticket
- **Size**: Epic — equally complex as backup in reverse. Must handle DB restoration into containers, config/secret restoration, service orchestration.

### `maintenance-mode` — Block external access during maintenance
- **Need it?** TBD — needs team discussion. In foreman-maintain it blocks port 443 via firewall, stops cron/timers, disables sync plans. Question: is this still the right approach for containerized upgrades, or do container stop/start workflows replace it?
- **Tracked?** Needs ticket (pending decision)
- **Size**: Story (if kept — it's just firewall rules + service/timer management, all Ansible-native)

### `report` — Generate usage/inventory reports
- **Need it?** Yes — useful for support cases, pre-upgrade audits, understanding what's deployed.
- **Tracked?** Needs ticket
- **Size**: Epic — 36 report definitions in foreman-maintain. Each report queries Foreman API or DB. Need to evaluate which reports carry over and whether the query mechanisms change.

### `packages` — RPM locking, install, update
- **Need it?** No — foreman-maintain protected dozens of Foreman RPMs via foreman-protector DNF plugin. foremanctl installs very few host RPMs (podman, httpd, hammer). Users can manage these directly with dnf. Upgrade/update workflows handle keeping the system current.
- **Tracked?** N/A
- **Size**: N/A

### `self-upgrade` — Update the tool itself
- **Need it?** Not yet — in foreman-maintain this updated the tool's own RPM to the latest build within the same version line (despite the misleading name). For foremanctl, this is just `dnf upgrade foremanctl`. Don't build a dedicated command unless foremanctl's self-update requires more steps than a simple RPM update.
- **Tracked?** N/A (revisit if needed)
- **Size**: Story (if ever needed)

### `advanced` — Run individual procedures by label/tag
- **Need it?** Not yet — this is a dev/debug escape hatch. Since foremanctl is Ansible-based, developers can run individual roles/playbooks directly. Don't add unless someone identifies a need beyond raw Ansible calls.
- **Tracked?** N/A (revisit if needed)
- **Size**: Story (if ever needed)

### `plugin purge-puppet` — Remove Puppet feature
- **Need it?** Yes — the capability to remove a feature/plugin should exist.
- **Tracked?** SAT-40445 (already in progress)
- **Size**: Story (already in progress)
- **Note**: Should live under feature management (e.g., `foremanctl deploy --remove-feature puppet`), not a separate `plugin` namespace.

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

| Functionality | Need it? | Tracked? | Size |
|---------------|----------|----------|------|
| upgrade | Yes | SAT-39696 | Epic (in progress) |
| update | Yes | SAT-39697 | Epic (in progress) |
| health checks | Yes | Needs ticket | Epic |
| service mgmt | Yes | Needs ticket | Story |
| backup | Yes | Needs ticket | Epic |
| restore | Yes | Needs ticket | Epic |
| maintenance-mode | TBD | Needs ticket | Story |
| report | Yes | Needs ticket | Epic |
| packages | No | N/A | — |
| self-upgrade | Not yet | N/A | — |
| advanced | Not yet | N/A | — |
| plugin/puppet purge | Yes | SAT-40445 | Story (in progress) |
| feature detection | Yes | (implicit) | Story |
| interactive prompts | TBD | Needs ticket | Story |
