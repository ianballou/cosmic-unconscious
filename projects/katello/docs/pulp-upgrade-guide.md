# Pulp Upgrade Guide for Katello

Katello bumps pulp plugin versions roughly every two releases. This doc captures
the integration analysis for each upgrade so we build institutional memory.

---

## General Upgrade Checklist

Every pulp plugin bump should cover these steps:

1. **Gemspec bounds** -- update `pulp_*_client` version constraints in `katello.gemspec`.
2. **Client API changes** -- diff the old and new client gem for removed/renamed classes and methods.
   ```bash
   # Example: compare API surface between versions
   diff <(grep "def " old_gem/lib/.../api/foo_api.rb | grep -v with_http_info) \
        <(grep "def " new_gem/lib/.../api/foo_api.rb | grep -v with_http_info)
   ```
3. **Monkeypatch audit** -- check `lib/monkeys/pulp_polymorphic_remote_response.rb` for
   references to removed/renamed API classes.
4. **Pulp3 API wrappers** -- review `app/services/katello/pulp3/api/` for calls to
   deprecated endpoints.
5. **Backend service layer** -- review `app/services/katello/pulp3/repository/` for
   type-specific logic tied to the old API.
6. **Actions audit** -- grep `app/lib/actions/` for any logic branching on the
   old plugin behavior.
7. **Model/controller audit** -- grep `app/models/` and `app/controllers/` for
   references to old plugin concepts.
8. **VCR cassettes** -- any tests using VCR will need re-recorded cassettes if
   API shapes changed.
9. **Verify on a live Pulp instance** -- stand up the new Pulp version and
   smoke-test the affected workflows before writing code.

---

## Katello 5.1: pulp_container 2.27 -> 2.29

### What changed upstream

pulp_container 2.29 unifies push repositories into regular container repositories.

**Before (2.27):** Two separate Pulp models and API endpoints:

| Aspect | `ContainerRepository` | `ContainerPushRepository` |
|---|---|---|
| Pulp TYPE | `container` | `container-push` |
| `PUSH_ENABLED` | `False` | `True` |
| Created by | Explicit API call | Auto-created by registry API on `podman push` |
| Deleted by | Explicit API call | Cascade from distribution deletion |
| Has `create`/`delete` | Yes | No |
| Has `sync` | Yes | No |
| Has `remove_image` | No | Yes |
| API class (Ruby) | `RepositoriesContainerApi` | `RepositoriesContainerPushApi` |

**After (2.29):**

- `ContainerPushRepository` model is removed; `ContainerRepository` handles both sync and push.
- `RepositoriesContainerPushApi` endpoint is deprecated/removed.
- Registry push API auto-creates regular `ContainerRepository` objects.
- Regular repos gain `remove_image` and `remove_signatures` actions.
- A Pulp-side data migration converts existing push repos to regular repos.
- Distribution deletion no longer cascade-deletes the repository.

### Katello integration points affected

Ten files contain push-repo-specific logic. Grouped by action required:

#### Must change (code references removed API classes)

| File | Current code | Required change |
|---|---|---|
| `katello.gemspec` | `pulp_container_client >= 2.27.0, < 2.28.0` | Bump to `>= 2.29.0, < 2.30.0` |
| `app/services/katello/pulp3/api/docker.rb` | Uses `RepositoriesContainerPushApi` for `container_push_api`, `container_push_repo_for_name`, `container_push_distribution_for_repository` | Replace with `repositories_api` (`RepositoriesContainerApi`). The `list(name:)` call and response shape are the same. Distribution lookup already uses `distributions_api`. |
| `app/controllers/katello/api/registry/registry_proxies_controller.rb` | `save_pulp_push_repository_href` calls `pulp_api.container_push_repo_for_name(...)` | Update to use the renamed method from the API wrapper above. |
| `lib/monkeys/pulp_polymorphic_remote_response.rb` | Patches `PulpContainerClient::RepositoriesContainerPushApi` | Remove that line -- the class no longer exists. |

#### Should change (logic assumes old cascade-delete behavior)

| File | Current code | Required change |
|---|---|---|
| `app/lib/actions/pulp3/orchestration/repository/delete.rb` | `return if repository.root.is_container_push` (skips repo deletion, relies on distribution cascade) | Remove early return. Regular repos need explicit deletion via `api.repositories_api.delete(href)`. |
| `app/lib/actions/pulp3/content_view/delete_repository_references.rb` | Branches on `is_container_push?` to call `delete_distributions` instead of `delete_repository` | Unify to `delete_repository` for both paths. |

#### Safe as-is (uses Katello DB flags, not Pulp API)

| File | Why it is safe |
|---|---|
| `app/lib/actions/katello/repository/create.rb` | Skips Pulp repo creation for push repos. Still valid if 2.29 auto-creates on push. **Verify against 2.29.** |
| `app/lib/actions/pulp3/orchestration/repository/copy_all_units.rb` | Uses `copy_all: true` for push repos. Functionally correct for regular repos too. |
| `app/lib/actions/katello/repository/metadata_generate.rb` | Skips metadata gen based on `is_container_push` DB flag. |
| `app/lib/actions/katello/environment/publish_container_repositories.rb` | Skips publish based on `is_container_push` DB flag. |

#### Not affected (Katello-only concepts)

These files use the `is_container_push` / `container_push_name` / `container_push_name_format`
columns on `katello_root_repositories`. These are Katello DB columns with no Pulp API
dependency, so they survive the upgrade unchanged:

- `app/models/katello/root_repository.rb`
- `app/models/katello/repository.rb` (`skip_container_name?`)
- `app/models/katello/content_view_repository.rb` (rolling CV logic)
- `app/controllers/katello/api/v2/repositories_controller.rb` (rolling CV queries)
- `app/controllers/katello/api/v2/content_view_repositories_controller.rb` (excludes push repos)
- `app/lib/actions/katello/repository/create_container_push_root.rb` (Katello-level repo creation)
- `db/migrate/20240520142245_add_container_push_props_to_repo.rb`

### Key risk: verify auto-creation behavior

The biggest unknown is whether Pulp 2.29's registry API **still auto-creates** repos
and distributions on first push, or now requires them to be pre-created.

This determines whether:
- The existing `create_container_repo_if_needed` + skipping Pulp repo creation in
  `Repository::Create` is still valid, OR
- Katello must explicitly create the Pulp repo + distribution before the first push.

**Test plan:** Stand up Pulp with pulp_container 2.29 and run `podman push` to a
non-existent path. Check whether the repo and distribution are auto-created.

### How to find all integration points (repeatable)

```bash
# Find every reference to push-specific Pulp concepts
cd /path/to/katello
grep -rn "push.repo\|push_repo\|ContainerPushRepository\|container_push\|push_repository\|RepositoriesContainerPushApi\|container-push\|PUSH_ENABLED" \
  --include="*.rb" app/ lib/ test/
```

---

## Template for Future Upgrades

Copy this section and fill in the details for each new pulp plugin bump.

### Katello X.Y: pulp_PLUGIN A.B -> C.D

**What changed upstream:**
(Summarize the key changes in the pulp plugin.)

**Katello integration points affected:**
(Use the general checklist above. List files, current code, required changes.)

**Key risks / verification needed:**
(What needs to be tested on a live Pulp instance before coding?)

**Resolution:**
(After the work is done, record what was actually changed and any surprises.)
