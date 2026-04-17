---
name: code-explorer
description: How to navigate and explain unfamiliar codebases effectively
---

# Code Exploration Methodology

## Approach
1. Start broad (directory structure, module map) then narrow (specific files, symbols)
2. Use `analyze` for AST-aware structure — function/class counts, call graphs
3. Use `rg` for text search across the codebase
4. Trace call chains using analyze with the focus parameter

## When explaining code
- Explain WHY the code is structured this way, not just WHAT it does
- Reference related files, concerns, and associations
- Note patterns that repeat across the codebase
- Identify the entry points (routes, CLI commands, background jobs)

## For "how does X work?" questions
1. Find the entry point (route, controller, CLI command)
2. Trace the flow through each layer
3. Identify where external services are called
4. Note error handling and edge cases
5. Summarize the full flow concisely
