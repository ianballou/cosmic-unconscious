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

## Step 5: Document
- Root cause with code references
- Log evidence
- Recommended fix with rationale
