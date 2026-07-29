# Patterns & Conventions

## foremanctl: Adding a new CLI command
1. Create playbook at `src/playbooks/<command-name>/<command-name>.yaml`
2. Create metadata at `src/playbooks/<command-name>/metadata.obsah.yaml` (help text, variables/params)
3. Playbook runs against `hosts: quadlet` (or `localhost` depending on context)
4. Include roles via `roles:` or `tasks:` in the playbook
5. Obsah auto-discovers playbooks and exposes them as CLI subcommands

## foremanctl: Adding a new check
1. Create role at `src/roles/check_<name>/tasks/main.yaml`
2. Add the role name to the loop in `src/roles/checks/tasks/main.yml`
3. The checks framework catches failures via rescue block and reports at end
4. Check roles should use `ansible.builtin.fail` with descriptive `msg:` on failure

## foremanctl: Adding a new feature
1. Add entry to `src/features.yaml` with description and component mappings
2. If smart proxy plugin: add settings template at `src/roles/foreman_proxy/templates/settings.d/<plugin_name>.yml.j2`
3. If additional setup needed: add tasks at `src/roles/foreman_proxy/tasks/feature/<plugin_name>.yaml`
4. Deploy with `--add-feature=<name>`

## Obsah CLI framework
- Obsah wraps Ansible playbooks as CLI commands
- `metadata.obsah.yaml` defines command help text and CLI parameters (variables)
- Parameters are passed as Ansible extra vars to playbooks
- Parameters can be persisted across runs (foremanctl has OBSAH_PERSIST_PARAMS=true)
- The `foremanctl` script sets env vars (OBSAH_NAME, OBSAH_DATA, etc.) then execs obsah

## foreman-maintain: Definition structure (reference only — don't port blindly)
- Checks: Ruby classes inheriting `ForemanMaintain::Check`, implement `run` method, use `assert` for pass/fail
- Procedures: Ruby classes inheriting `ForemanMaintain::Procedure`, implement `run` method for actions
- Scenarios: Ruby classes inheriting `ForemanMaintain::Scenario`, implement `compose` to add steps in dependency order
- Features: Ruby classes inheriting `ForemanMaintain::Feature`, detected at runtime, provide service lists and config file paths
- Reports: Ruby classes for generating usage/inventory reports
- All use metadata DSL: `metadata { label :foo; tags :bar; for_feature :baz; ... }`
- Many of these abstractions exist because Ruby needed them — Ansible roles/playbooks/facts replace most of them naturally

## Ansible variable layering: role defaults as public interface

Role defaults (`defaults/main.yaml`) are the user-facing public interface for a role.
Internal deployment wiring lives in `vars_files` loaded at the play level (e.g. `src/vars/database.yml`).

The pattern for bridging these layers:

1. Define role-namespaced variables in `defaults/main.yaml` that reference the internal layer:
   ```yaml
   # src/roles/foreman_proxy/defaults/main.yaml
   foreman_proxy_container_gateway_db_host: "{{ container_gateway_database_host }}"
   foreman_proxy_container_gateway_db_port: "{{ container_gateway_database_port }}"
   ```

2. Compose higher-level values from the role's own variables:
   ```yaml
   foreman_proxy_container_gateway_db_connection_string: >-
     postgresql://{{ foreman_proxy_container_gateway_db_user }}:...
   ```

3. Templates reference only role-namespaced variables.

Why this works with Ansible precedence:
- User overrides in inventory beat role defaults, so the Jinja reference is never evaluated.
- If no override, the role default resolves the internal variable from `vars_files` at runtime.
- `vars_files` (play level) is higher precedence than inventory, so internal variables can't
  be casually overridden -- but that's fine because users interact through the role defaults.

Existing examples:
- `foreman_proxy_container_gateway_db_*` variables wrapping `container_gateway_database_*` from `database.yml`
- All services (foreman, candlepin, pulp, container_gateway) follow this layered pattern for database config

## Shared CLI parameter includes (`_database_connection`, `_database_mode`)

Per-service database CLI parameters (name, user, password) live in
`src/playbooks/_database_connection/metadata.obsah.yaml`. This is an included metadata
file, not a standalone command. Playbooks include it via their `include:` list (directly
or through flavor includes like `_flavors/katello`).

When adding database config for a new service, add its variables here alongside the
existing foreman/candlepin/pulp entries to maintain consistency.

Note: `deploy --help` currently does not show database options due to a pre-existing
issue with obsah nested include resolution. The options do work correctly via `checks --help`
and when passed directly.

## Design approach for porting
- Start from "what does the user need to do?" not "what does foreman-maintain have?"
- A foreman-maintain Scenario ≈ an Ansible playbook composing roles
- A foreman-maintain Check ≈ an Ansible role that asserts something (fail on bad state)
- A foreman-maintain Procedure ≈ an Ansible role that does something (change state)
- A foreman-maintain Feature ≈ Ansible facts + vars + the features.yaml registry
- Don't create Python classes to mimic the Ruby class hierarchy — use Ansible's natural structure
- Do NOT port foreman-maintain checks by translating Ruby to Ansible. Understand the intent of the check, then write a fresh Ansible role following foremanctl's existing conventions. None of the existing foremanctl checks were ported from foreman-maintain — they were all written independently.
