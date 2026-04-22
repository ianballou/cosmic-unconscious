# Foremanctl Migration Design

## Status: Proposal Phase

## Goal
Produce a comprehensive proposal document covering all foreman-maintain functionality:
- **Do we still need it?** (may be obsolete in containerized world)
- **If yes, where is it tracked?** (existing Jira ticket or needs new one)
- **How big is it?** (Story or Epic)

## Existing Efforts
Some commands already have active work:
- **update** — SAT-39697
- **upgrade** — SAT-39696
- **puppet purge** — SAT-40445

This design effort focuses on everything else, with backup/restore likely being the largest areas to define. Health checks need per-check keep/drop/add evaluation.

## Architecture Summary

### foreman-maintain (source — Ruby)
- **Core pattern**: Executable → Check/Procedure/Scenario class hierarchy
- **Definitions**: Declarative Ruby classes in `definitions/` directory (checks, procedures, scenarios, features, reports)
- **Features**: Runtime-detected system capabilities (is Katello installed? Is Puppet present?)
- **Scenarios**: Orchestrated workflows composing checks + procedures in dependency order
- **Runner**: Executes scenarios with interactive prompts, error handling, rollback
- **Config**: `/etc/foreman-maintain/foreman_maintain.yml`

### foremanctl (target — Python/Ansible)
- **Core pattern**: Obsah CLI framework → Ansible playbooks → Ansible roles
- **Commands**: Defined as playbooks in `src/playbooks/<command>/`, exposed via `metadata.obsah.yaml`
- **Features**: Static registry in `src/features.yaml` (plugins, not health features)
- **Checks**: Ansible roles in `src/roles/check_*`, orchestrated by `checks` playbook
- **Config**: Persisted params in `.var/lib/foremanctl/parameters.yaml`
- **Output**: Custom Ansible callback plugin for user-facing output

### Key Architectural Differences
1. **Runtime detection vs static config**: foreman-maintain detects features at runtime; foremanctl uses static feature registry + Ansible facts
2. **Interactive vs declarative**: foreman-maintain has interactive prompts (ask_decision, assumeyes); foremanctl is declarative Ansible runs
3. **Ruby DSL vs Ansible YAML**: Checks in foreman-maintain are Ruby classes with metadata DSL; in foremanctl they're Ansible roles
4. **Monolithic vs composed**: foreman-maintain scenarios are monolithic Ruby; foremanctl composes roles in playbooks

## Design Principles
1. **User-first**: Don't port foreman-maintain commands blindly. Rethink what commands are needed, what each command does, and what the user actually wants to accomplish. Start from the user's perspective, not from the existing implementation.
2. **Ansible-native**: Leverage Ansible's strengths — roles, playbooks, modules, facts, handlers. foreman-maintain had to implement many things from scratch (service management, package locking, file operations, DB queries) that Ansible already has answers for. Use those answers.
3. **Ansible-first, Python as escape hatch**: Write roles and playbooks using Ansible primitives. Only drop to Python (filters, modules, callback plugins) when the Ansible starts to feel too complex or unnatural.
4. **Procedural playbooks**: Use Ansible's natural procedural flow rather than recreating foreman-maintain's class hierarchy (Check → Procedure → Scenario). A playbook with roles *is* a scenario.

## Open Questions
- What commands does the user actually need? (Don't assume 1:1 mapping from foreman-maintain)
- Which foreman-maintain concerns are still relevant in a containerized world vs artifacts of the old model?
- How to handle interactive prompts (e.g., backup confirmation) in the Ansible model?
- How to handle the tag/label filtering system for checks in Ansible?
- What's the upgrade story — does foremanctl need upgrade scenarios or is that handled differently in containers?
- How does maintenance mode work in a containerized world?
