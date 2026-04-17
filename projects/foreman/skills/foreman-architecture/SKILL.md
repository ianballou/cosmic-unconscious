---
name: foreman-architecture
description: Foreman codebase architecture and plugin system
---

# Foreman Architecture

## Plugin System
- Plugins are Rails Engines registered in bundler.d/
- Katello: bundler.d/katello.local.rb
- Plugins extend models via concerns and facets
- Host facets: app/models/host/ — plugins add facets for their domain

## Core Domains
- Hosts: Host::Managed, Host::Base — central model
- Smart Proxies: SmartProxy — remote execution, content, DHCP, DNS, etc.
- RBAC: Permission, Role, Filter — used by all plugins including Katello
- Compute Resources: VM provisioning integrations
- Config Management: Puppet, Ansible (via plugins)

## Code Flow: API Request
1. Request hits app/controllers/api/v2/
2. Authorized via RBAC (before_action :find_resource, :authorize)
3. Rendered via RABL views or jbuilder

## Key for Katello Developers
- Foreman's RBAC system is what Katello's permissions build on
- Host::Managed is extended by Katello via ContentFacet
- Smart proxy infrastructure is how Katello manages capsule content

## Gotchas
(Add entries as discovered)
