---
path: platform/stability
nav_order: 205
---
# Stability and the 1.0 Contract

This page lists the parts of the platform that other software depends on. These
are the surfaces that 1.0 will keep stable. Use the list to decide what your
own scripts, devices and applications can safely depend on.

::: warning The platform is before 1.0
Until 1.0, a minor version can change any surface on this page. The platform's
[CHANGELOG](https://github.com/stone-age-io/platform/blob/main/CHANGELOG.md)
lists each breaking change. Pin the versions you deploy
([Operations §5.2](./operations.md#52-before-10)).
:::

---

## 1. What "stable" means

After 1.0, the platform follows semantic versioning:

- **A minor or patch release only adds.** It can add a route, a field, a
  config key, a metric or a command. It does not remove or rename one, and it
  does not change what an existing one means.
- **A major release can remove or change a surface.** The CHANGELOG says how to
  migrate.
- **A security fix can break a surface in any release.** The CHANGELOG says so
  at the top of that release.

A client must ignore fields that it does not know. A new field in a response,
a record or a payload is an addition, not a break.

---

## 2. The stable surfaces

### HTTP API

| Surface | What is stable | Reference |
| :--- | :--- | :--- |
| The eleven platform routes | The path, the method, who can call it, the request fields and the response fields | [API Reference §1](./api-reference.md#1-the-whole-surface) |
| `GET /api/me/leaf-config` | The ten field names. The Agent reads them by name. | [Leaf Nodes §3](./leaf-nodes.md#3-get-apimeleaf-config) |
| `GET /api/ready` | The response fields, the four states, the check names, and `503` only on `fail` | [Health & Metrics §2](./health-metrics.md#2-get-apiready) |
| `GET /metrics` | The metric names, types and labels | [Health & Metrics §3](./health-metrics.md#3-get-metrics) |
| The record API | The collection names and field names that the Agent, `stone` and sibling apps read. The record API itself is PocketBase's. | [HTTP API](./concepts/http-api.md) |
| The device sign-in path | `things` auth with a password, `auth-refresh`, the `nats_user` relation with its `creds_file` and `updated` fields, and the `nebula_host` relation the Agent reads its Nebula config from | [The Agent §2](./agent.md#2-provisioning-credential-lifecycle) |
| MQTT bearer tokens | `nats_users.bearer_token`, and that the user JWT is accepted as the MQTT password when it is set | [Connectivity §1](./connectivity.md#mqtt-clients) |

### Authorization

| Surface | What is stable | Reference |
| :--- | :--- | :--- |
| The five membership roles | The role names, and the capability matrix as a lower limit: a release does not remove a capability from a role, except as a security fix | [Authorization §2](./authorization.md#2-capability-matrix) |
| The Platform Operator flag | `users.is_operator`, and that no API call can grant it | [Authorization §3](./authorization.md#3-cross-organization-identities) |
| Row-scoped credentials | A caller reads only its own linked NATS identity, and a Thing only its own identities | [Authorization §4](./authorization.md#4-the-row-scoped-credential-model) |

### Names and identifiers

| Surface | What is stable | Reference |
| :--- | :--- | :--- |
| Codes | The character rules, uniqueness that ignores case, and that a code and a type do not change once set | [Thing Types §3](./thing-types.md#what-a-code-may-contain) |
| Generated codes | The `PFX-XXX-XXX` shape and its alphabet | [Thing Types §3](./thing-types.md#generated-codes) |
| The default subject | `{thing_type_code}.{thing}.{operation_suffix}`, and the four template variables | [Thing Types §3](./thing-types.md#3-subject-templates-and-resolution) |
| A Thing's login email | `<thing code>@<organization code>.thing.local` | [API Reference §4](./api-reference.md#post-apiorgthings) |
| The twin | The bucket names `twin` and `twin_desired`, the key shape `<kind>.<code>.<prop>`, and one writing side for each bucket | [Architecture §4](./architecture.md#4-the-digital-twin-concept-live-state) |
| A leaf's JetStream domain | The gateway Thing's code | [Leaf Nodes §3](./leaf-nodes.md#the-domain-is-the-code-computed-and-never-stored) |
| A QR label's payload | The bare code | [Platform Entities §5](./platform-ui-entities.md#codes-and-qr-labels) |
| A Location's `path` | Codes from the root down, with `/` between them and at both ends | [Platform Entities §2](./platform-ui-entities.md#2-locations) |
| Platform subjects in a tenant's account | The managed export subtree and the inventory events subtree, each as configured | [Connectivity §1](./connectivity.md#cross-account-subject-sharing-imports-exports) |
| Inventory events | The `<kind>.<action>` tokens (`thing` or `location`; `created`, `updated` or `deleted`), the payload's field names and the `changed` list, and that the events are core NATS and not stored | [Connectivity §1](./connectivity.md#cross-account-subject-sharing-imports-exports) |

### Configuration and commands

| Surface | What is stable | Reference |
| :--- | :--- | :--- |
| `config.yaml` keys and `STONE_AGE_*` variables | The key names, their meaning and their defaults | [Configuration](./configuration.md) |
| `stone-age` commands | `init`, `serve`, `migrate up`, `bootstrap`, `superuser upsert`, `nats export`, and their flags | [Getting Started §2](./getting-started.md#2-initialize-the-control-plane) |
| The exported `nats.conf` | That a stock `nats-server` accepts it, and that the embedded server reads the same file | [ADR 0001](./decisions/0001-embedded-nats-server.md) |
| `stone` commands | The command names, the flags, the exit status, and the `-o json` and `-o yaml` output | [Stone CLI](./stone-cli.md) |
| The `stone` workspace | One YAML file for each record, and that `apply` never deletes | [Stone CLI §5](./stone-cli.md#5-declarative-workspaces-pull-apply) |

### The Agent

The Agent has its own repository and version numbers. Its stable surfaces are:

| Surface | What is stable | Reference |
| :--- | :--- | :--- |
| Subjects | `{prefix}.{code}.heartbeat`, `.telemetry.*` and `.cmd.*` | [The Agent §3](./agent.md#3-capabilities) |
| Payload fields | `code`, `location` and `ts` on the heartbeat and on every telemetry payload | [The Agent §3](./agent.md#3-capabilities) |
| Error replies | The `Nats-Service-Error` header, `400` for a refused request and `500` for failed work | [The Agent §3E](./agent.md#e-service-discovery) |
| CLI flags | `-config`, `-leaf-config`, `-version`, and `-service` with `install`, `uninstall`, `start`, `stop` and `restart` | [The Agent §1](./agent.md#getting-the-binary) |
| The generated leaf config | The file name `nats-leaf.conf`, beside the creds file, and that a stock `nats-server -c` runs it | [Leaf Nodes §5](./leaf-nodes.md#5-deploy-flow) |
| Commands | The command names, the request fields and the reply fields | [Agent docs](./vendor/agent/README.md) |
| The micro service name | `stone-agent` | [The Agent §3E](./agent.md#e-service-discovery) |
| `config.yaml` keys | The key names, their meaning and their defaults | [Agent docs](./vendor/agent/README.md) |
| `/ready` and `/metrics` | The check names and the metric names | [Health & Metrics §5](./health-metrics.md#5-the-edge-agent) |

---

## 3. What is not part of the contract

Do not build on these. They can change in any release.

- **The console.** Screen layout, routes, labels, widget configuration and the
  dashboard JSON format.
- **`table` output from `stone`.** It is for people. Scripts read `-o json`.
- **Log lines and error message text.** Depend on the HTTP status and the
  response fields, not on the words.
- **The database file.** Table layout, the migrations and the hook code. Read
  and write through the API.
- **The admin UI at `/_/`.** It is PocketBase's own.
- **`demo-seed`.** The tenants, codes, roles and subjects it creates.
- **Collections that are not for clients:** `nats_publish_queue`,
  `nats_system_operator` and `audit_logs`' internal fields.
- **Reference applications.** `rule-router`, the Helpdesk, Access Control and
  the services each have their own versions and their own contracts.

Upstream behavior is also outside this contract. NATS, Nebula and PocketBase
each have their own compatibility rules, and
[Operations §6.1](./operations.md#61-the-versions-these-docs-describe) lists
the versions the platform is built on.

---

## 4. Known gaps before 1.0

These surfaces are not yet in the state that the contract needs:

- **`stone`'s field list is maintained by hand**, so it can fall behind the
  platform's schema ([Stone CLI §10](./stone-cli.md#10-limitations)).
- **An update that a rule refuses returns `404`, not `403`.** This is
  PocketBase behavior, and clients must not read `404` as "no such record"
  ([Authorization §7](./authorization.md#7-changing-the-rules)).
- **Step 3 of ADR 0001, config reload, is not built.** A change to `nats.conf`
  under `serve --nats` needs a Control Plane restart
  ([ADR 0001](./decisions/0001-embedded-nats-server.md#as-implemented)).

---

## 5. Where to Go Next

- The versions these docs describe: [Operations §6.1](./operations.md#61-the-versions-these-docs-describe)
- How to upgrade: [Operations §5](./operations.md#5-upgrades)
- Why the surfaces have this shape: [Decisions](./decisions.md)
