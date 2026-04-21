# Gotchas & Surprises

## foremanctl "features" ≠ foreman-maintain "features"
- foremanctl features = plugins/components to install (katello, REX, etc.)
- foreman-maintain features = runtime-detected system capabilities used by checks/procedures
- Don't confuse these — they serve completely different purposes

## check_subuid_subgid and certificate_checks roles exist but aren't wired into the checks playbook
- They exist as roles in src/roles/ but aren't in the loop in src/roles/checks/tasks/main.yml
- May be run separately or may be WIP

## obsah auto-discovers playbooks
- Any `src/playbooks/<name>/<name>.yaml` automatically becomes a CLI command
- Prefixed with `_` (like `_tuning`, `_flavor_features`) are included/internal, not exposed as commands

## foreman-maintain definitions/ vs lib/
- `definitions/` = concrete checks, procedures, scenarios (the "what")
- `lib/foreman_maintain/` = framework classes and utilities (the "how")
- When porting, you care about definitions/ for feature inventory, lib/ for understanding the patterns
