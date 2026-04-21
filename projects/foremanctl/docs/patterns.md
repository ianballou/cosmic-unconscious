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

## Design approach for porting
- Start from "what does the user need to do?" not "what does foreman-maintain have?"
- A foreman-maintain Scenario ≈ an Ansible playbook composing roles
- A foreman-maintain Check ≈ an Ansible role that asserts something (fail on bad state)
- A foreman-maintain Procedure ≈ an Ansible role that does something (change state)
- A foreman-maintain Feature ≈ Ansible facts + vars + the features.yaml registry
- Don't create Python classes to mimic the Ruby class hierarchy — use Ansible's natural structure
