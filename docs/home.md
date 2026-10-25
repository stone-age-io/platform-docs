---
path: ""
access: public
---
# Stone-Age.io Docs

![](https://docs.stone-age.io/api/files/pbc_1321337024/urd2kzkc487yapc/16_9_scaled_hero_y3ftmippef.png)

Documentation for Stone-Age.io and the tools that run beside it. Pick a section
below, or use search in the sidebar.

| Section | What it covers |
| :--- | :--- |
| **[Concepts](./concepts/index.md)** | The technologies under every section, explained once: messaging, credentials and storage on NATS, message design, the PocketBase HTTP API, and the Nebula overlay. |
| **[Platform](./index.md)** | The Control Plane, the console and the `stone` CLI: tenants, inventory, identities, NATS and Nebula, and how to run it all in production. |
| **[Agent](./vendor/agent/README.md)** | The daemon on each device and site gateway: telemetry, remote commands, credential sync, the Nebula overlay and leaf nodes. |
| **[Rule Router](./vendor/rule-router/README.md)** | The rule engine: NATS routing, HTTP webhooks in and out, and scheduled publishes, all as YAML rules. |
| **[Helpdesk](./vendor/helpdesk/README.md)** | The operator's service desk: support tickets and planned field work, machine-generated tickets over NATS, a requester portal, dispatch and time tracking. |
| **[Access Control](./vendor/access-control/README.md)** | Physical access control on NATS: doors, schedules and access groups decided at the edge, intrusion-lite areas, alarms and notifications, and a phone badge for cardholders and visitors. |

## Start here

- **New to the platform:** [Getting Started](./getting-started.md) runs it in one
  container and seeds a demo.
- **New to NATS:** [Messaging](./concepts/messaging.md), then
  [NATS Security](./concepts/nats-security.md).
- **Installing an agent:** the [Linux](./vendor/agent/docs/linux.md),
  [Windows](./vendor/agent/docs/windows.md) and
  [FreeBSD](./vendor/agent/docs/freebsd.md) guides.
- **Writing your first rule:** [Rule Router core concepts](./vendor/rule-router/docs/01-core-concepts.md).
- **Running the service desk:** the [Helpdesk overview](./vendor/helpdesk/docs/overview.md),
  then its [wire protocol](./vendor/helpdesk/docs/protocol.md) for machine-generated tickets.
- **Controlling doors:** the [Access Control README](./vendor/access-control/README.md),
  then its [central service](./vendor/access-control/docs/accessd.md) and
  [edge controller](./vendor/access-control/docs/controller.md) pages.
- **Going to production:** the [Operations checklist](./operations.md#7-production-checklist).
- **Looking up a term:** [Glossary](./overview.md#glossary).
