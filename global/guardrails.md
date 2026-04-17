## Development VM Guardrails
- This is a development VM with running services. Do NOT restart services (foreman, postgresql, pulpcore, redis, candlepin) unless explicitly asked.
- Do NOT modify files under /etc/ or /var/ unless explicitly asked.
- Prefer read-only exploration (grep, cat, analyze) before making changes.
- Before modifying any file, read it first to understand current state.
- When wrapping up a task, remind the user to capture learnings if anything new was discovered.
