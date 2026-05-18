---
title: "SAT-38492: Fix EVR Tilde (~) Handling in Katello"
tags: [katello, rpm, evr, applicability]
status: active
created: 2026-05-15
---

# SAT-38492: Fix EVR Tilde (~) Handling in Katello

## Problem Statement

Satellite incorrectly marks RC/pre-release RPM packages as upgradeable. For example, `dotnet-sdk-8.0-8.0.100~rc.2` is shown as an upgrade target even when `dotnet-sdk-8.0-8.0.100-2` is already installed.

Per the RPM spec, the tilde (`~`) character denotes a **pre-release version** — `8.0.100~rc.2` should sort **before** (older than) `8.0.100`. The caret (`^`) character denotes a **post-release snapshot** — `8.0.100^git1` should sort **after** `8.0.100` but before `8.0.101`.

**References:**
- Jira: [SAT-38492](https://redhat.atlassian.net/browse/SAT-38492)
- Upstream Pulp issue: [pulp_rpm#4124](https://github.com/pulp/pulp_rpm/issues/4124)
- Failed SQL fix attempt: [pulp_rpm#4171](https://github.com/pulp/pulp_rpm/pull/4171) (closed/stale)

## Root Cause Analysis

### How the EVR SQL Extension Works

Katello defines a custom Postgres type `evr_t` and a `rpmver_array()` PL/pgSQL function (in migration `20240924161240_katello_recreate_evr_constructs.rb`). When an RPM is inserted or updated, a trigger calls `evr_trigger()` which converts the `(epoch, version, release)` text fields into the composite `evr_t` type for efficient SQL-level comparison.

The `rpmver_array()` function parses a version string into an array of `evr_array_item` elements `(numeric_value, text_value)`. Postgres natively compares these arrays element-by-element, which gives correct ordering for normal version strings.

### The Bug: Tilde Is Stripped

The critical flaw is in `rpmver_array()`:

```sql
-- Throw out all non-alphanum characters
while one <> '' and not isalphanum(one)
loop
    one := substr(one, 2);
end loop;
```

The `isalphanum()` function only recognizes `[a-zA-Z0-9]`. Tilde (`~`) and caret (`^`) are treated as non-alphanumeric and **silently stripped**. This means:

- `8.0.100~rc.2` is parsed identically to `8.0.100.rc.2`
- The pre-release semantics are completely lost
- The parsed array becomes `[(8,NULL), (0,NULL), (100,NULL), (0,"rc"), (2,NULL)]`
- Since this array is **longer** than `[(8,NULL), (0,NULL), (100,NULL)]` for `8.0.100`, it sorts **after** it — the exact opposite of correct behavior

### Three Broken Comparison Paths in Katello

| # | Path | Where Used | How It Compares | Broken? |
|---|------|-----------|-----------------|---------|
| 1 | **`evr_t` column + SQL operators** (`evr >`, `ORDER BY evr`) | Applicability calculation (`applicable_content_helper.rb:91`), upgrade dropdown (`host_package_presenter.rb:19`), host upgrade logic (`host_managed_extensions.rb:547`) | Postgres array comparison of `evr_array_item[]` | **Yes** — tilde stripped by `rpmver_array()` |
| 2 | **`version_sortable` / `release_sortable` columns** | `Rpm.latest()` method (`rpm.rb:237`), `PackageFilter` (`package_filter.rb`), scoped search EVR compare, `default_sort` | String comparison with `COLLATE "C"` of encoded sortable strings | **Yes** — `sortable_version()` uses `scan(/([A-Za-z]+|\d+)/)` which drops tilde, then the remaining segments sort incorrectly |
| 3 | **`Rpm.latest()` LEFT OUTER JOIN** | Content View publishing, package filtering | Raw SQL comparing `version_sortable`/`release_sortable` with COLLATE "C" | **Yes** — same underlying `version_sortable` problem |

**All three paths fail for tilde (and caret).** The `evr_t` path is the most impactful because it drives applicability calculations — the core "what packages need updating" logic.

## How Pulp Fixed This (Python Side)

Pulp fixed the issue in two commits by Daniel Alley (October 2025):

### Commit 1: `e974e04e` — "Change implementation of Python version sort"
Rewrote `pulp_rpm/app/rpm_version.py` with a correct `_compare_version_strings()` function that:
- Preserves tilde and caret during parsing (they are not stripped as non-alphanumeric)
- Handles tilde as "sorts before everything" — if one string has `~` and the other doesn't, the tilde string loses
- Handles caret as "sorts after end-of-string but before continuation"

### Commit 2: `c7bbe48b` — "Use a correct package EVR sort"
**Stopped using `ORDER BY evr` (the SQL extension) for the `retain_package_versions` feature.** Instead:
- Moved `annotate_with_age()` from a Postgres window function (`ROW_NUMBER() ... ORDER BY evr DESC`) to a Python-side sort using `RpmVersion` objects
- Loads packages into memory, groups by `(name, arch)`, sorts each group with `RpmVersion`, assigns age ranks in Python
- Uses Django's `Case/When` to map the ages back to a queryset annotation

**Key insight:** Pulp did NOT fix the SQL extension. They worked around it by doing the comparison in Python where they could implement the RPM algorithm correctly.

### PR #4171: The Failed SQL Extension Rewrite
Daniel Alley attempted a comprehensive SQL rewrite that:
- Changed `evr_t` to store raw `TEXT` for version/release instead of `evr_array_item[]`
- Added a `pulp_rpmvercmp(a TEXT, b TEXT)` function implementing the full RPM comparison algorithm in PL/pgSQL
- Added explicit comparison operators and a btree operator class

The PR was generated by Claude, received no review engagement, and was closed by the stale bot after ~7 months. The approach was architecturally sound but the implementation was never validated or tested.

## Katello's Impact Surface

### Critical Path: Applicability Calculation
**File:** `app/services/katello/applicability/applicable_content_helper.rb`

```ruby
# Line 91 — THE core comparison that determines if a package is "upgradeable"
katello_rpms.evr > katello_installed_packages.evr
```

This SQL comparison uses the `evr_t` type's native array ordering, which is broken for tilde. This is the primary driver of the reported bug.

### Critical Path: Upgrade Dropdown on Host Packages Page
**File:** `app/presenters/katello/host_package_presenter.rb`

```ruby
# Lines 19-20 — Determines what versions show in the upgrade selector
upgradable_packages_map = ::Katello::Rpm.installable_for_hosts([host])
  .select(:id, :name, :arch, :nvra, :evr)
  .order(evr: :desc)
  .group_by { |i| [i.name, i.arch] }
```

This `ORDER BY evr DESC` also uses the broken `evr_t` comparison.

### Secondary Path: Host Upgrade Package Selection
**File:** `app/models/katello/concerns/host_managed_extensions.rb`

```ruby
# Line 547 — Determines latest available version for upgrade jobs
versionless_upgrades = ::Katello::Rpm.where(name: pkg_name_archs.map(&:first))
  .select(:id, :name, :arch, :evr)
  .order(evr: :desc)
  .group_by { |i| [i.name, i.arch] }
```

### Secondary Path: Rpm.latest()
**File:** `app/models/katello/rpm.rb`

```ruby
# Lines 237-243 — Uses version_sortable, not evr_t, but still broken
'katello_rpms.version_sortable COLLATE "C" < katello_rpms2.version_sortable COLLATE "C"'
```

### Other Paths: Scoped Search, PackageFilter, Default Sort
These use `version_sortable` / `release_sortable` and are also broken, but are lower impact (search results ordering vs. applicability correctness).

## Implementation Options

### Option A: Fix the SQL Extension (Preferred)

Rewrite `rpmver_array()` (or replace the entire comparison mechanism) to correctly handle tilde and caret. This is the most complete fix since it corrects all comparison paths at once.

**Sub-option A1: Rewrite `rpmver_array()` to encode tilde/caret in the array**

Modify the function to not strip tilde/caret, and instead encode them as array elements with special sort values that produce correct ordering. For example, a tilde element could be encoded with a very low numeric value (e.g., `-1`) that sorts before any real segment.

Challenges:
- The current `evr_array_item` type is `(NUMERIC, TEXT)`. Postgres compares arrays element-by-element, NUMERICs first, then TEXT. A tilde segment needs to sort before *both* numeric and alpha segments.
- A numeric value of `-1` with NULL text would sort before `(0, NULL)` (zero/empty numeric), which is correct.
- However, the current array comparison relies on Postgres's native array ordering. Introducing special sentinel values means the semantics depend on careful value choices.

**Sub-option A2: Replace array comparison with `rpmvercmp()` function (PR #4171 approach)**

Store raw version/release text in `evr_t` and use an explicit `rpmvercmp()` PL/pgSQL function for comparison. Define custom operators (`<`, `>`, `=`, etc.) and a btree operator class so `ORDER BY evr` and `evr > evr` work correctly.

This is what PR #4171 attempted. The approach is architecturally the cleanest — it directly implements the RPM comparison algorithm rather than trying to encode it into array sort order. However:
- It requires defining a full operator class (which PR #4171 did)
- It changes the `evr_t` type definition (version/release from `evr_array_item[]` to `TEXT`)
- It requires a data migration to recompute all `evr` columns
- It needs thorough testing (PR #4171 was never tested)

**Sub-option A3: Use the Spacewalk `evr` Postgres extension**

The original `evr` type in Katello came from the [Spacewalk/Uyuni `evr` extension](https://github.com/uyuni-project/uyuni/tree/master/schema/spacewalk/postgres/packages/evr_t). Katello previously used `CREATE EXTENSION evr` before migration `20240924161240` dropped it and replaced it with inline PL/pgSQL. We could investigate whether the upstream Spacewalk extension handles tilde correctly, or if there's a newer version that does.

### Option B: Work Around the SQL Extension (Pulp's Approach)

Do the version comparison in Ruby instead of SQL. This is what Pulp did — they stopped relying on `ORDER BY evr` and instead sort in application code using a correct `RpmVersion` comparator.

**Pros:**
- Proven approach (Pulp shipped this)
- No SQL migration needed
- Easier to test (unit tests in Ruby)
- The comparison algorithm is well-understood (RPM's `rpmvercmp` is documented)

**Cons:**
- The critical applicability query (`evr > installed_evr`) is a SQL `WHERE` clause, not just an `ORDER BY`. Moving this to Ruby would mean loading all candidate packages into memory and filtering in Ruby, which could be a performance problem for hosts with many packages.
- Multiple code paths would need individual fixes
- The `evr_t` column and index would remain broken/misleading — future developers might use it expecting correct behavior

### Option C: Hybrid — Fix SQL Extension + Fix sortable_version

Fix the SQL `rpmver_array()` function (Option A) AND fix the `sortable_version()` Ruby method to handle tilde/caret. This covers all three comparison paths.

## Recommended Approach: Option A2 (SQL Extension Rewrite) + sortable_version Fix

### Rationale

1. **The applicability query MUST stay in SQL.** The `evr > installed_evr` comparison in `applicable_content_helper.rb` is a SQL `WHERE` clause joining `katello_rpms` with `katello_installed_packages`. Moving this to Ruby would require loading all packages for all repos + all installed packages for a host, doing a cross-product comparison, and filtering — a massive performance regression. The SQL extension must be fixed.

2. **PR #4171's architecture was correct.** Storing raw text and using an explicit `rpmvercmp()` function is the right approach. The RPM comparison algorithm has too many special cases (tilde, caret, leading zeros, numeric-vs-alpha precedence) to encode into Postgres's native array sort order.

3. **`sortable_version` is a separate bug.** Even with a fixed `evr_t`, the `Rpm.latest()` method and `PackageFilter` use `version_sortable`, which has its own tilde bug. This should be fixed independently.

## Implementation Plan

### Phase 1: Fix the SQL EVR Extension (Migration)

**Deliverable:** A new Katello migration that rewrites the EVR comparison infrastructure.

1. **Write a `rpmvercmp(a TEXT, b TEXT) RETURNS INT` PL/pgSQL function** implementing the RPM version comparison algorithm. Use PR #4171's implementation as a starting point but validate against RPM's own `rpmvercmp` test cases. The function must handle:
   - Tilde (`~`) — sorts before everything, including end-of-string
   - Caret (`^`) — sorts after end-of-string but before any continuation
   - Numeric segments sort as numbers (strip leading zeros, compare by length then value)
   - Alpha segments sort alphabetically
   - Non-alphanumeric characters (except `~` and `^`) are separators, ignored
   - Numeric segments beat alpha segments

2. **Redefine `evr_t`** to store raw text:
   ```sql
   CREATE TYPE evr_t AS (
     epoch INT,
     version TEXT,
     release TEXT
   );
   ```

3. **Write an `evr_cmp(a evr_t, b evr_t) RETURNS INT` function** that:
   - Compares epochs numerically first
   - Then compares versions via `rpmvercmp(a.version, b.version)`
   - Then compares releases via `rpmvercmp(a.release, b.release)`

4. **Define comparison operators and operator class:**
   - `=`, `<>`, `<`, `<=`, `>`, `>=` operators using `evr_cmp()`
   - A btree operator class `evr_ops` so `ORDER BY evr` and indexes work

5. **Update `evr_trigger()`** to simply store `(epoch, version, release)` as text (no more `rpmver_array()` call).

6. **Migration data step:** Update all existing `evr` values in `katello_rpms` and `katello_installed_packages`.

7. **Drop old functions:** `rpmver_array()`, `evr_array_item` type (after type change), `isalphanum()`, `isdigit()`, `isalpha()`, `empty()` — unless other code depends on them.

### Phase 2: Fix `sortable_version()` in Ruby

**Deliverable:** Update `Katello::Util::Package.sortable_version()` to handle tilde and caret.

1. **Modify `sortable_version()`** to recognize `~` and `^` and encode them as sort-correct prefixes. For example:
   - `~` segments get a prefix that sorts before any numeric or alpha prefix (e.g., `!` which is ASCII 33, before `$` at 36 and digits at 48+)
   - `^` segments get a prefix that sorts after empty (end-of-string) but before normal continuation

2. **Alternatively**, since `sortable_version` is only used in `Rpm.latest()`, `PackageFilter`, and scoped search, consider replacing those to use the fixed `evr_t` comparison instead of `version_sortable`. This would reduce the number of comparison mechanisms.

### Phase 3: Audit and Update Comparison Call Sites

1. **`Rpm.latest()`** — Currently uses `version_sortable COLLATE "C"` comparison. After Phase 1, rewrite to use `evr` comparison:
   ```ruby
   # Replace version_sortable comparison with evr comparison
   'katello_rpms.evr < katello_rpms2.evr'
   ```
   This is simpler AND correct.

2. **`Rpm.default_sort`** — Currently `order(:name).order(:epoch).order(:version_sortable).order(:release_sortable)`. Change to `order(:name).order(:evr)`.

3. **Audit `PackageFilter`** — Determine if it can use `evr` comparison instead of `version_sortable`.

4. **Audit scoped search EVR methods** — `scoped_search_evr_compare` uses `version_sortable`. Consider using `evr` type comparison.

### Phase 4: Testing

1. **SQL-level unit tests:** Write PL/pgSQL tests or Ruby migration tests that verify `rpmvercmp()` returns correct results for:
   - `8.0.100~rc.2` vs `8.0.100` → `8.0.100~rc.2` is OLDER (returns -1)
   - `1.0~beta1` vs `1.0` → `~beta1` is OLDER
   - `1.0^post1` vs `1.0` → `^post1` is NEWER
   - `1.0^post1` vs `1.0.1` → `^post1` is OLDER
   - `1.0~rc1~git1` vs `1.0~rc1` → `~git1` is OLDER
   - Standard version comparisons still work (numeric, alpha, mixed)

2. **Ruby unit tests:** Test `sortable_version()` or whatever replaces it.

3. **Integration tests:**
   - Applicability calculation with tilde versions
   - Host packages page upgrade dropdown with tilde versions
   - Content View publish with `retain_package_versions` and tilde versions

4. **Performance testing:**
   - The new `rpmvercmp()` is a PL/pgSQL function call per comparison vs. native array comparison. Benchmark applicability calculation for a host with many packages.
   - If performance is a concern, consider writing `rpmvercmp()` as a C extension instead of PL/pgSQL.

### Phase 5: Data Migration Considerations

- The migration must handle the type change from `evr_array_item[]` to `TEXT` for the version and release fields within `evr_t`
- All existing EVR values must be recomputed
- Indexes on `evr` must be dropped and recreated with the new operator class
- The migration should be reversible or at least have a clear rollback path
- Consider the migration time for large installations (millions of RPM rows)

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Performance regression from PL/pgSQL function calls | Medium | High | Benchmark before/after; consider C extension if needed |
| Migration failure on large databases | Low | High | Test on a copy of production-scale data; make migration idempotent |
| Breaking existing EVR comparisons during migration | Low | High | Run in a transaction; test rollback |
| Other code depending on `evr_array_item` type | Low | Medium | Grep for all references before dropping |
| `sortable_version` fix introduces new ordering bugs | Low | Medium | Extensive test cases including edge cases |

## Open Questions

1. **Should we resurrect PR #4171 or start fresh?** The PR's `rpmvercmp()` implementation looks correct but was AI-generated and never tested. Starting fresh with the same architecture but human-verified test cases is probably safer.

2. **Is there value in fixing the Pulp-side SQL extension too?** Katello's EVR functions are named differently (`rpmver_array` vs `pulp_rpmver_array`) but are identical code. If Pulp users also hit this, coordinating with Pulp to fix their extension would be beneficial. However, Pulp's Python workaround means they're less affected.

3. **Should `Rpm.latest()` be rewritten to use `evr` instead of `version_sortable`?** This would eliminate the need to fix `sortable_version()` for that code path, but `sortable_version` is also used in `PackageFilter` and scoped search.

4. **Performance budget:** What's the acceptable performance impact on applicability calculation? If `rpmvercmp()` in PL/pgSQL is too slow, a C extension would be faster but adds packaging/deployment complexity.

5. **Backport scope:** The fix version is 6.20.0. Does this need to be backported to 6.18/6.19? The migration complexity makes backporting harder.
