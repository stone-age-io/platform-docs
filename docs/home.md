---
path: ""
access: public
---
# Stone-Age.io Docs

Documentation for Stone-Age.io and the tools that run beside it. Pick a section
below, or use search in the sidebar.

| Section | What it covers |
| :--- | :--- |
| **[Platform](./index.md)** | The Control Plane, the console and the `stone` CLI: tenants, inventory, identities, NATS and Nebula, and how to run it all in production. |
| **[Agent](./vendor/agent/README.md)** | The daemon on each device and site gateway: telemetry, remote commands, credential sync, the Nebula overlay and leaf nodes. |
| **[Rule Router](./vendor/rule-router/README.md)** | The rule engine: NATS routing, HTTP webhooks in and out, and scheduled publishes, all as YAML rules. |

## Start here

- **New to the platform:** [Getting Started](./getting-started.md) runs it in one
  container and seeds a demo.
- **Installing an agent:** the [Linux](./vendor/agent/docs/linux.md),
  [Windows](./vendor/agent/docs/windows.md) and
  [FreeBSD](./vendor/agent/docs/freebsd.md) guides.
- **Writing your first rule:** [Rule Router core concepts](./vendor/rule-router/docs/01-core-concepts.md).
- **Going to production:** the [Operations checklist](./operations.md#7-production-checklist).
- **Looking up a term:** [What We Call Things](./overview.md#what-we-call-things).
