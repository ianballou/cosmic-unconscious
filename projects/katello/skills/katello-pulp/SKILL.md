---
name: katello-pulp
description: Pulp 3 integration patterns in Katello
---

# Katello ↔ Pulp 3

## Service
- Pulp 3 API: https://localhost:24816
- Manages content storage, syncing, publishing, distribution

## Code Locations
- Pulp 3 API wrappers: app/services/katello/pulp3/
- Pulp 3 content types: app/services/katello/pulp3/repository/
- Smart proxy content: app/lib/actions/katello/capsule_content/

## Key Patterns
- Katello creates Pulp remotes, repositories, and distributions
- Sync triggers a Pulp sync task, Katello polls for completion
- Content view publish creates Pulp repository versions and distributions

## Gotchas
(Add entries as discovered)
