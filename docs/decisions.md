---
path: platform/decisions
nav_order: 210
---
# Decisions

- [ADR 0001: Embed the NATS Server in the Control Plane Binary](decisions/0001-embedded-nats-server.md)
- [ADR 0002: Root the Public Namespace at the Organization Code](decisions/0002-organization-code-namespace.md)
- [ADR 0003: Human-Friendly Codes, Type Prefixes, and a Location-Free Default Subject](decisions/0003-human-friendly-codes-and-default-subject.md)
- [ADR 0004: Long-Term Data Carries Codes; Location Comes From Inventory](decisions/0004-long-term-data-and-location-path.md)

ADRs 0005 to 0007 decide things in the services repository and live there. These are vendored copies.

- [ADR 0005: A Watchdog Service for Message Absence](vendor/services/docs/decisions/0005-watchdog-service.md)
- [ADR 0006: History Services for Metrics and Logs](vendor/services/docs/decisions/0006-history-services.md) (deferred)
- [ADR 0007: creds-keeper, Platform-Managed Credentials for Account Services](vendor/services/docs/decisions/0007-creds-keeper.md)

ADRs 0008 and 0009 are ecosystem-scoped, like ADR 0002, and live here.

- [ADR 0008: One Namespace, Event Shape and Identity for Applications](decisions/0008-application-namespace.md) (accepted, implemented)
- [ADR 0009: Applications Keep Their Own Thing Credentials, Through the Kit](decisions/0009-thing-credentials-in-kit.md) (accepted, implemented in the kit and the services)
