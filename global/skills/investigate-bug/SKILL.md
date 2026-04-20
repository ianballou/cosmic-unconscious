---
name: investigate-bug
description: Systematic approach to investigating software bugs
---

# Bug Investigation Methodology

## Step 1: Parse the Report
- What is the expected behavior?
- What is the actual behavior?
- What are the reproduction steps?
- What environment/version?

## Step 2: Locate the Code
- Identify the component (model, controller, service, action, UI)
- Use `analyze` for structure, `rg` for text search
- Trace from entry point (route/API) to the failure point

## Step 3: Reproduce
- Use the project's REPL/console if available
- Try the exact reproduction steps from the report
- Check logs for errors and stack traces

## Step 4: Diagnose
- Is it a code bug or user error/misconfiguration?
- When was it introduced? (git log, git blame)
- What's the minimal fix vs. proper fix?

### Tracing data across system boundaries
When a fix involves data that crosses repos or subsystems (e.g., Katello
code that feeds a Foreman report template, or Dynflow actions whose data
is read by a rake task), trace the full path:
- What populates the field? Which repo/component writes it?
- What consumes the field? Does the consumer actually use every field
  the producer computes?
- Do the types match? (e.g., string vs uuid, symbol keys vs string keys)
- If a fix changes the producer's output, does the consumer's interface
  (options, parameters, column headers) still make sense?
- Check for "orphaned" options — e.g., a UI dropdown offering a choice
  that the backend silently ignores after a refactor.

## Step 5: Document
- Root cause with code references
- Log evidence
- Recommended fix with rationale
