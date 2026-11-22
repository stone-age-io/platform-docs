---
path: platform/versions
nav_order: 25
---
# Versions

These docs describe the versions in this page. A page that depends on a later
version says so.

| Component | Version | Where its own docs are |
| :--- | :--- | :--- |
| Control Plane and console (`stone-age`) | v0.21.0 | The Platform section. [CHANGELOG](https://github.com/stone-age-io/platform/blob/main/CHANGELOG.md) |
| `stone` CLI | v0.12.0 | [Stone CLI](./stone-cli.md) |
| Agent | v0.11.0 | [Agent docs](./vendor/agent/README.md) |
| `rule-router` | v0.25.0 | [Rule Router docs](./vendor/rule-router/README.md) |
| Services (Watchdog and creds-keeper) | v0.4.0 | [Services docs](./vendor/services/README.md) |
| Access Control | v0.3.0 | [Access Control docs](./vendor/access-control/README.md). [CHANGELOG](https://github.com/stone-age-io/access-control/blob/main/CHANGELOG.md) |
| Helpdesk | v0.2.0 | [Helpdesk docs](./vendor/helpdesk/README.md). [CHANGELOG](https://github.com/stone-age-io/helpdesk/blob/main/CHANGELOG.md) |
| Kiosk | v0.1.1 | [Kiosk docs](./vendor/kiosk/README.md). [CHANGELOG](https://github.com/stone-age-io/kiosk/blob/main/CHANGELOG.md) |
| Application kit (`stone-age-io/kit`) | v0.1.0 | [README](https://github.com/stone-age-io/kit#readme). A Go library the applications build on, not something you run |

Platform v0.21.0 is built on these upstream versions:

| Upstream | Version |
| :--- | :--- |
| PocketBase | v0.41.1 |
| nats-server (embedded with `serve --nats`) | v2.15.2 |
| Nebula | v1.12.0 |
| pb-nats | v0.5.0 |
| pb-nebula | v0.8.0 |
| pb-audit | v0.3.0 |

Each vendored section has a `SOURCE` file in the docs repository with the exact
commit of its copy.

How these components depend on each other, and the order to upgrade them, is in
[Operations §6](./operations.md#6-component-version-compatibility).
