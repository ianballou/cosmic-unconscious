# Command Decisions

What commands does foremanctl need? Starting from user needs, not from foreman-maintain's command list.

## Decided: Drop

### `packages` — DROP
foreman-maintain's `packages` command managed RPM locking (foreman-protector DNF plugin), install, update, lock/unlock, and check-update. This made sense when Foreman installed dozens of RPMs (Ruby, Foreman core, plugins, Pulp, Candlepin, PostgreSQL, etc.) that could break on accidental `dnf update`.

foremanctl installs very few RPMs on the host: podman, httpd, mod_ssl, hammer-cli, python3 deps, bash-completion. The risk surface is dramatically smaller.

**Reasoning:**
- Package locking protected a fragile RPM ecosystem. Containers eliminate that fragility.
- Users who need an RPM (debugging, external tools) can just use `dnf` directly — that's what dnf is for.
- Upgrade/update workflows handle keeping the system current.
- Installing packages via foremanctl adds complexity with no clear user value.
- The foreman-protector DNF plugin has no purpose when there's almost nothing to protect.

## Decided: Keep

### `upgrade` — KEEP
Major version upgrade orchestration. The workflow will look different in a containerized world (pull new images, migrate DBs, restart services vs RPM upgrades + installer runs), but the user need is the same: "take me from version X to version Y safely."

### `update` — KEEP
Minor version update orchestration. Same reasoning as upgrade — the mechanism changes but the user need persists.

### `service` — KEEP
Start/stop/restart/status/enable/disable services. Even with containers, users need to manage service lifecycle. The implementation shifts from systemd unit management to podman/systemd target operations, but the user intent is identical.

### `backup` — KEEP
Create a backup of the deployment. The what-to-backup changes (container volumes, DB dumps, config files, secrets vs RPM-era file paths), but "I need a backup before I do something risky" is fundamental.

### `restore` — KEEP
Restore from a backup. Paired with backup — can't have one without the other.

### `report` — KEEP
Generate usage/inventory reports. Useful for support cases, pre-upgrade audits, and understanding what's deployed. The data sources may shift but the user need remains.

## Under Discussion

_(commands being evaluated)_

### `self-upgrade` — NOT YET
Despite the name in foreman-maintain, this is a self-*update* — it updates the tool's own RPM to the latest build within the same version line, picking up new checks, bugfixes, and procedure changes.

For foremanctl, this is currently just `dnf upgrade foremanctl`. Don't build a dedicated command unless foremanctl's self-update requires more steps than a simple RPM update (e.g., migrations, config changes, cache clearing). If that need arises, add it then.

## Not Yet Evaluated

The following foreman-maintain commands still need evaluation:

### `health` — KEEP
Health checks stay. The individual checks within need separate evaluation — some are irrelevant in a containerized world, some carry over, and there are likely new container-specific checks to add. See [checks.md](checks.md) for per-check evaluation.
### `maintenance-mode` — KEEP (pending discussion)
Blocks external access (port 443 via firewall), stops cron/timers, and disables sync plans — lets the system stay running but prevents external users and background automation from interfering during maintenance. Needs discussion with the team about whether this model still applies to containerized Foreman upgrades or if a different approach is warranted.
### `advanced` — NOT YET
In foreman-maintain, this lets you run individual procedures by label or tag — essentially a dev/debug escape hatch. Since foremanctl is Ansible-based, developers can already run individual roles/playbooks directly with `ansible-playbook`. Don't add this unless someone identifies a need for it beyond raw Ansible calls.
- `plugin` — in foreman-maintain this is just a namespace containing `purge-puppet`. The capability to remove a feature/plugin should exist in foremanctl, but under a better home — likely as part of the existing feature management (e.g., `foremanctl deploy --remove-feature puppet` or similar). Don't recreate the `plugin` namespace.
