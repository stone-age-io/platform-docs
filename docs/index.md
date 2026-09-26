# Stone-Age.io Docs

**Every site you manage, on one screen.**

One console and one automation layer across the equipment your sites already
run: door controllers, cameras, kiosks, sensors, machines, and anything else
that speaks HTTP, MQTT or NATS. Nothing gets ripped out to make room for it.

Underneath that is a control plane for connected operations — one place to
register equipment and the people who use it, one real-time bus to carry what it
reports, and one encrypted network to reach it. The pieces each do one job, so
you adopt what you need today and grow into the rest without rewrites.

---

## Where do you fit?

| | Start here |
| :--- | :--- |
| **Just show me what it does** | [Getting Started](./getting-started.md) — one container, then `demo-seed` for three tenants, a map, floor plans, signed identities and edge sites to click through |
| **I run an integration business** | [Authorization & Roles](./authorization.md) for the tenancy model your customers become, then [Stone CLI](./stone-cli.md) for configuring fifty sites without configuring them fifty times |
| **I run IT or operations for a facility** | [Connectivity](./connectivity.md) for how equipment reaches the bus, then [Observability](./observability.md) for getting the events into the stack you already run |
| **I am evaluating the engineering** | [Architecture](./architecture.md), then [API Reference](./api-reference.md) and the two [ADRs](./decisions/0001-embedded-nats-server.md) |

---

## What it is made of

Three well-known open-source projects, each doing the job it is good at, plus
our own components alongside them. Nothing here is a proprietary protocol you
would have to reverse engineer later, and nothing is a fork you would be stuck
maintaining.

| Part | Job |
| :--- | :--- |
| **PocketBase** | **Management** — identity, inventory, organizations and locations, an embedded SQLite database, a REST API and an admin UI, in one binary. Creating a Thing here mints the credentials it fetches on first boot. |
| **NATS.io** | **Messaging** — pub/sub with native MQTT, JetStream for persistence and replay, key-value buckets holding the live device state the browser subscribes to, and leaf nodes that keep a site running through an internet outage. |
| **Nebula** | **Connectivity** — a peer-to-peer mesh with NAT traversal, identity-based firewall rules and outbound-only connections, so no port opens on an edge network and nothing depends on a customer VPN. |
| **Stone-Age.io** | **Ours** — the console you run the fleet from, [`rule-router`](./automation.md) for declarative YAML automation across NATS, HTTP and cron, and a lightweight [agent](./agent.md) that reports and controls a single device. |

Everything else plugs into the same bus. [Telegraf](./observability.md) ships
JetStream data to whichever time-series database you prefer; [eKuiper or
Benthos](./stream-processing.md) handle windowed aggregations and anomaly
detection and publish results back for the rules to act on. Stone-Age.io stays
small because the heavy jobs stay with the tools built for them.

### What it already speaks

| Protocol | How |
| :--- | :--- |
| **NATS** | Native |
| **MQTT** | Native, via JetStream |
| **HTTP** | Webhooks in and API calls out, through the [rule engine's gateway](./automation.md) |
| **WebSocket** | The browser's own connection to the bus |

### Every piece is one file

Start with the Control Plane binary: run `./stone-age serve` and open your
browser. The database, REST API and console are already inside it. Add NATS,
Nebula, `rule-router` and the agent alongside it as you need them — bare metal,
containers or VMs. The Control Plane ships for Linux, macOS and Windows; the
agent and `rule-router` also ship for FreeBSD.

Self-hosted and hosted accounts run **the same binaries**, so starting on your
own hardware and moving later is not a rebuild. These docs describe the software
either way; anything specific to a hosted account is called out where it applies.

> **A note on names.** "The platform," "the Control Plane," "the console," and "`stone`" mean four different things in these docs and are not interchangeable. Neither are the two Operators: the **NATS Operator** is a signing key, the **Platform Operator** is a person. If a diagram stops making sense, check [What We Call Things](./overview.md#what-we-call-things).

---

## Start Where You Need To

[Where do you fit?](#where-do-you-fit) answers *which page you need*. This is the
other question people arrive with: **how much of it do you have to run?**

Not all of it, and stopping early is not a degraded mode. There are four depths,
and **each one is a legitimate place to stop.** Most deployments sit at depth 2
or 3 indefinitely.

### 1. An inventory

Things, Locations, and the types that classify them, over the PocketBase REST API with a multi-tenant console on top. Records only — no messaging, no mesh, no contracts.

This is not a degraded mode. A Thing can be created with no NATS user and no Nebula host (`mode: "none"` on both halves of `POST /api/org/things`), and a Thing Type with no operations is a pure categorization record that emits no subjects at all. Creating and editing inventory is the `member` role's job; attaching identities to it is a separate, higher-privileged action.

Depth 1 is about what you *model*, not about what you run. A normal deployment still includes a NATS server — it just has nothing on it yet, and no device holds a credential to reach it. The point isn't a smaller stack; it's that you get a working system before you have modeled a single subject, and none of it gets rewritten when you do.

> **You are done here if** you need a shared, permissioned, multi-tenant record of what you own and where it is — asset tracking, site surveys, an equipment register your field techs can edit from a phone.

### 2. A control plane

Turn on the identity half. Creating an Organization provisions an isolated NATS Account and a private Nebula CA; creating a Thing can mint its NATS user and its Nebula host certificate in the same transaction. Tenant boundaries stop being a `WHERE` clause and become cryptographic.

Now the inventory is load-bearing: the record you created in depth 1 *is* the identity your device authenticates as. See [Inventory-as-Identity](./architecture.md#31-inventory-as-identity).

> **You are done here if** you need devices, services, and people to reach each other securely across sites and NAT, and you are happy writing your own consumers against NATS.

### 3. A contract layer

Declare what participants actually say. A **Thing Type** carries a subject prefix, and its **operations** declare a capability (`publish` / `subscribe` / `request` / `reply`) and a subject suffix each. Together they resolve the exact subject any given Thing uses.

This is the step that makes the fabric self-describing: a consumer can resolve, from data alone, which subjects a given device uses and what shape its messages take. See [Thing Types](./thing-types.md).

> **You are done here if** more than one team or vendor writes code against your bus and you need the subject-and-payload contract to be written down rather than tribal.

### 4. Everything that consumes it

The rule engine, the Agent, stream processors, Telegraf and your time-series database. All of them are clients of the same bus, added when you need the capability they provide.

> **You are done here if** you are building an application, not just running infrastructure.

**Each depth is additive.** Nothing you built at depth 1 gets rewritten to reach depth 4 — the inventory record you created on day one is still the same record, it just accumulates identities, contracts, and consumers around it.

---

## Key Features

- **Inventory-as-Identity:** The same record is the asset and the credential. A Thing is a first-class auth record that can hold a NATS user and a Nebula host, so "the camera in the lobby" is one row that is simultaneously an inventory entry, a login, a messaging identity, and a mesh node. There is no separate device registry to keep in sync. See [Architecture §3.1](./architecture.md#31-inventory-as-identity).
- **Infrastructure-as-Tenant:** The same principle one level up. Creating an Organization — a Platform Operator action — provisions an isolated NATS Account and a private Nebula CA, so the management record and the infrastructure it implies are created and destroyed as a unit — and suspending the Organization withdraws its NATS Account, disconnecting every device and browser in the tenant at once, reversibly. Tenant boundaries are enforced cryptographically at the messaging and network layers, not by application-level filters.
- **A contract layer, not just a schema store:** Thing Types declare *where* a kind of participant speaks (a subject prefix), their operations declare *what verbs* it has (`publish` / `subscribe` / `request` / `reply`, each with a subject suffix), Subject grammar is described as data, so a consumer can resolve from the records alone which subjects a device uses. Payload shape is deliberately NOT described: a `message_schemas` collection existed and was dropped, because nothing validated against it. See [Thing Types](./thing-types.md).
- **Role-scoped access, enforced in one place:** Five per-organization roles (`owner`, `admin`, `member`, `viewer`, `dashboard`) plus a Platform Operator flag, enforced by PocketBase API rules on each collection. The one deliberate exception is an invariant rather than a permission: a single hook refuses any relation that points into another Organization's records, which no rule can express. Credentials are protected by row scoping — you can read the identity you authenticate with and no other — and every role can rotate its own. See [Authorization & Roles](./authorization.md).
- **Digital Twins:** Live device state lives in NATS KV buckets and streams to the browser over WebSocket. Dashboards reflect changes in real time without polling the database. At the edge the twin is a preset over general [KV bucket sync](./leaf-nodes.md#6-offline-autonomy-and-kv-bucket-sync), so a site can keep any bucket it declares in step through a WAN outage.
- **A history a tenant can actually read:** An org-scoped activity feed — actor, action, record, timestamp — readable by every role, carrying no record values. It is deliberately separate from the Platform-Operator-only audit log, which records the names of the fields every write changed and keeps full before/after values only for an allowlist of collections that hold no credentials. See [Authorization §5](./authorization.md#5-two-histories-the-audit-log-and-the-activity-feed).
- **One name for a tenant, everywhere:** An Organization's **code** is the ecosystem's single globally unique identifier; everything under it is unique only within that Organization. Ids are for storage, codes are for addressing — so anything that has to survive leaving the database travels by code: a NATS subject, a sibling application's join key, or a QR label printed and stuck on the equipment. Those labels carry the **bare code** and nothing else, which is what keeps a forged sticker from becoming a redirect. See [ADR 0002](./decisions/0002-organization-code-namespace.md).
- **Outbound-only security:** Devices and Agents initiate connections outward to NATS and Nebula. No inbound ports are required, so edge nodes stay invisible to the public internet.
- **Declarative automation:** A unified rule engine (router, gateway, and scheduler features) expresses NATS routing, webhook ingestion and egress, and cron-driven publishes as YAML rules.
- **Bring your own storage:** Long-term telemetry is consumed from NATS by the time-series database of your choice — VictoriaMetrics, InfluxDB, Prometheus, Postgres, or anything else Telegraf can target.

---

## Planes and Layers

Stone-Age.io isn't a monolithic product — it's a **Control Plane** (management surface) alongside a **Data Plane** (runtime) that is internally composed of four layers around a shared NATS substrate.

> **NATS is the bus. The rule engine is the reflexes. Stream processors are the thinking. Telegraf + TSDB is the memory.**

Each layer does one thing well, and each composes cleanly with the others. Understanding the model is the single most useful mental aid for working with the platform.

**This is a different question from the one above.** The four depths answer *"how much of this do I have to adopt?"* The four layers answer *"where does this particular problem belong?"* They are orthogonal, and it is worth keeping them apart:

| | Question it answers | Where the Control Plane sits |
|---|---|---|
| **Depths (1–4)** | How much do I adopt on day one? | Depth 1 — it is the shallow end |
| **Layers (0–3)** | Which component should solve this? | Alongside the layers, in none of them |

Note in particular that Layer 0 — NATS, JetStream, KV, Nebula — is *not* the cheapest starting point. Depth 1 is, and it is pure Control Plane. The layer model has no rung for "inventory only," which is why both models exist.

Start with [Platform Layers](./platform-layers.md) if you want the runtime framing first.

---

## Every Page

The [table at the top](#where-do-you-fit) is the short way in. This is everything,
roughly concept to deployment — the order is a reasonable read-through rather
than a prerequisite chain, and any page is a fine place to enter:

1.  **[Overview](./overview.md)** — Understand the vision and the problems we solve.
2.  **[Platform Layers](./platform-layers.md)** — The conceptual model: how the platform is structured as composable tiers.
3.  **[Architecture](./architecture.md)** — Learn how the Control Plane and Data Plane work together.
4.  **[Getting Started](./getting-started.md)** — Go from zero to a live dashboard in five minutes.
5.  **[Platform UI and Entities](./platform-ui-entities.md)** — Explore Organizations, Locations, and Things.
6.  **[Dashboards & Widgets](./dashboards.md)** — The Visualizer: sixteen widget types, subscription and KV data sources (with optional JetStream history), and dashboard variables.
7.  **[Authorization & Roles](./authorization.md)** — Who can do what: the five roles, the capability matrix, and the credential model.
8.  **[API Reference](./api-reference.md)** — The ten endpoints the platform adds on top of PocketBase REST, and why each one is a route rather than an API rule.
9.  **[Stone CLI](./stone-cli.md)** — Drive the same entities, NATS, and a GitOps workspace from the terminal with the `stone` client.
10. **[Thing Types](./thing-types.md)** — The contract layer: how participants on the fabric declare what they publish, subscribe to, request, and reply to.
11. **[Connectivity](./connectivity.md)** — Dive deep into NATS and Nebula configurations (Layer 0).
12. **[The Edge (Agent)](./agent.md)** — Provision and manage lightweight executors on remote hosts.
13. **[Leaf Nodes](./leaf-nodes.md)** — Run a site's own NATS server: how a gateway Thing bootstraps its leaf config, and how you tell whether it is attached.
14. **[Automation](./automation.md)** — Build intelligent routing, scheduled publishing, and stateful alarms with the rule engine (Layer 1).
15. **[Stream Processing](./stream-processing.md)** — Windowed aggregations, joins, and anomaly detection (Layer 2).
16. **[Observability](./observability.md)** — Long-term data storage and historical analysis (Layer 3).
17. **[Health & Metrics](./health-metrics.md)** — `/api/ready` and `/metrics` on the Control Plane and the Agent: what each check means and what to alert on.
18. **[Configuration Reference](./configuration.md)** — `config.yaml` keys, `STONE_AGE_*` environment variables, and operational notes.
19. **[Operations & Production](./operations.md)** — backups, recovery, upgrades, version compatibility, and the production checklist.

---

## Philosophy

> "Complexity is the enemy of reliability."

Stone-Age.io is built for engineers who value transparency and maintainability over cleverness. We prefer clear Go code, reactive Vue components, and straightforward YAML over magic abstractions. We provide the toolkit; you own the network.
