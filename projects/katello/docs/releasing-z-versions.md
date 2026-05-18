# Releasing Katello Z-Versions (foreman-packaging)

How to bump Katello from X.Y.Z to X.Y.(Z+1) in foreman-packaging.
Example: 4.20.0 → 4.20.1, modeled after the 4.19.0.1 → 4.19.1 bump.

## Prerequisites

- The new gem (e.g. `katello-4.20.1.gem`) must be pushed to rubygems.org first.
- You need the foreman-packaging repo with `upstream` remote pointing to
  `theforeman/foreman-packaging` and git-annex initialized.

## Branch base

All branches are based off `upstream/rpm/<foreman_version>` (e.g. `upstream/rpm/3.18`
for Katello 4.20.x). The Foreman version tracks Katello — check the existing
`foreman_min_version` / `foreman_max_version` in the rubygem-katello spec.

## Three packages to update

Each gets its own branch → its own PR against `rpm/<foreman_version>`.

### 1. rubygem-katello

**Branch name convention:** `katello-<new_version>-rubygem-katello`

**Files changed:**
- `packages/katello/rubygem-katello/rubygem-katello.spec`
  - `%global mainver` → new version
  - `%global release` → reset to `1`
  - Add changelog entry at top of `%changelog`
- `packages/katello/rubygem-katello/katello-<old>.gem` → **remove** (`git rm`)
- `packages/katello/rubygem-katello/katello-<new>.gem` → **add** via `git annex add`

**Gem workflow:**
```bash
# Download from rubygems
gem fetch katello -v 4.20.1
# Move into place
mv katello-4.20.1.gem packages/katello/rubygem-katello/
# Annex it (NOT regular git add)
git annex add packages/katello/rubygem-katello/katello-4.20.1.gem
# Remove old gem
git rm packages/katello/rubygem-katello/katello-4.20.0.gem
```

### 2. katello

**Branch name convention:** `katello-<new_version>-katello`

**Files changed:**
- `packages/katello/katello/katello.spec`
  - `Version:` → new version
  - `%global release` stays `1` (it's usually already 1 for a version bump)
  - Add changelog entry at top of `%changelog`

### 3. katello-repos

**Branch name convention:** `katello-<new_version>-katello-repos`

**Files changed:**
- `packages/katello/katello-repos/katello-repos.spec`
  - `Version:` → new version
  - `%global release` → reset to `1` (may have been bumped for intermediate changes)
  - Add changelog entry at top of `%changelog`

## Changelog entry format

```
* <Day> <Mon> <DD> <YYYY> <Full Name> <<email>> - <version>-<release>
- Release <package-name> <version>
```

Example:
```
* Mon May 18 2026 Ian Ballou <ianballou67@gmail.com> - 4.20.1-1
- Release rubygem-katello 4.20.1
```

Generate the date with: `date '+%a %b %d %Y'`

## Commit message convention

One commit per branch. Message format: `Release <package-name> <version>`

Examples:
- `Release rubygem-katello 4.20.1`
- `Release katello 4.20.1`
- `Release katello-repos 4.20.1`

## Reference commits

To see how previous bumps were done:
```bash
git log --oneline --all --grep="Release 4.19.1"
git show <commit_hash>
```

The 4.19.1 bump commit (`573b05373`) is a good reference — it combined all three
packages in a single commit, but separate PRs (one branch per package) is also fine.

## Post-branch workflow

After creating the branches:
1. Inspect diffs: `git diff upstream/rpm/3.18..<branch_name>`
2. Push: `git push origin <branch_name>`
3. Open PRs against `rpm/<foreman_version>` in theforeman/foreman-packaging
