---
name: katello-architecture
description: Katello codebase architecture and code flow patterns
---

# Katello Architecture

## Code Flow: API Request → Action → Pulp
1. Request hits controller (inherits Katello::Api::V2::ApiController)
2. Controller finds/authorizes resource via before_action
3. Controller calls sync_task or async_task to trigger a Dynflow action
4. Dynflow action interacts with Pulp 3 API
5. Action monitors Pulp task to completion
6. RABL template renders response

## Key Model Domains
- Content Views: ContentView, ContentViewVersion, ContentViewEnvironment
- Repositories: Repository, RootRepository, Product
- Environments: KTEnvironment (lifecycle environments)
- Host Content: Host::ContentFacet
- Errata: Erratum, ErratumPackage, ErratumCve

## Conventions
- New API endpoints: app/controllers/katello/api/v2/
- New UI: React + PatternFly (webpack/), NOT AngularJS
- Background jobs: Dynflow actions in app/lib/actions/katello/
- Permissions: lib/katello/permissions/
- API docs: Apipie annotations on controller methods

## Gotchas
(Add entries as discovered)
