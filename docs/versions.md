---
path: platform/versions
nav_order: 25
---
# Versions

These docs describe the versions in this page. A page that depends on a later
version says so.

| Component | Version | Where its own docs are |
| :--- | :--- | :--- |
| Control Plane and console (`stone-age`) | v0.20.0 | The Platform section. [CHANGELOG](https://github.com/stone-age-io/platform/blob/main/CHANGELOG.md) |
| `stone` CLI | v0.9.0 | [Stone CLI](./stone-cli.md) |
| Agent | v0.8.0 | [Agent docs](./vendor/agent/README.md) |
| `rule-router` | v0.23.1 | [Rule Router docs](./vendor/rule-router/README.md) |
| Services (Watchdog and creds-keeper) | v0.2.0 | [Services docs](./vendor/services/README.md) |
| Access Control | v0.2.0 | [Access Control docs](./vendor/access-control/README.md) |
| Helpdesk | v0.1.0 | [Helpdesk docs](./vendor/helpdesk/README.md). [CHANGELOG](https://github.com/stone-age-io/helpdesk/blob/main/CHANGELOG.md) |

Platform v0.20.0 is built on these upstream versions:

| Upstream | Version |
| :--- | :--- |
| PocketBase | v0.41.1 |
| nats-server (embedded with `serve --nats`) | v2.15.2 |
| Nebula | v1.11.0 |
| pb-nats | v0.4.1 |
| pb-nebula | v0.6.0 |
| pb-audit | v0.3.0 |

Each vendored section has a `SOURCE` file in the docs repository with the exact
commit of its copy.

How these components depend on each other, and the order to upgrade them, is in
[Operations §6](./operations.md#6-component-version-compatibility).
