# Welcome to the Stone-Age.io Docs

Stone-Age.io is one HTTP API for the things and places you manage — and the same API issues the credentials that let them talk to each other.

At its simplest it is a multi-tenant inventory: Things, Locations, and the types that classify them, over a plain REST API with a console on top. It grows into a control plane from there, because in this platform the act of creating an inventory record is also the act that mints that record's identity on the messaging fabric and the encrypted mesh.

The platform brings three projects together under a single management surface:

- **Management — PocketBase:** A self-contained backend that handles identity, inventory, and the embedded UI.
- **Messaging — NATS.io:** A high-performance, multi-tenant fabric for telemetry, commands, and live state.
- **Connectivity — Nebula:** A peer-to-peer mesh VPN that delivers encrypted tunnels all the way to the edge.

> **A note on names.** "The platform," "the Control Plane," "the console," and "`stone`" mean four different things in these docs and are not interchangeable. If a diagram stops making sense, check [What We Call Things](./overview.md#what-we-call-things).

---

## Start Where You Need To

You do not have to adopt the whole platform to get value from it. There are four depths, and **each one is a legitimate place to stop.** Most deployments sit at depth 2 or 3 indefinitely.

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

Declare what participants actually say. A **Thing Type** carries a subject prefix, its **operations** declare capabilities (`publish` / `subscribe` / `request` / `reply`) and subject suffixes, and **message schemas** version the payloads as JSON Schema.

This is the step that makes the fabric self-describing: a consumer can resolve, from data alone, which subjects a given device uses and what shape its messages take. See [Thing Types](./thing-types.md).

> **You are done here if** more than one team or vendor writes code against your bus and you need the subject-and-payload contract to be written down rather than tribal.

### 4. Everything that consumes it

The rule engine, the Agent, stream processors, Telegraf and your time-series database. All of them are clients of the same bus, added when you need the capability they provide.

> **You are done here if** you are building an application, not just running infrastructure.

**Each depth is additive.** Nothing you built at depth 1 gets rewritten to reach depth 4 — the inventory record you created on day one is still the same record, it just accumulates identities, contracts, and consumers around it.

---

## Key Features

- **Single-binary components:** The Control Plane, rule engine, Agent, NATS, and Nebula each ship as a self-contained executable with no runtime dependencies. They wire themselves together over NATS, so the same architecture works on bare metal, a single VM, containers, or a Kubernetes cluster — whichever fits your operations.
- **Infrastructure-as-Tenant:** Creating an Organization — a platform-Operator action — provisions an isolated NATS Account and a private Nebula CA. Tenant boundaries are enforced cryptographically at the messaging and network layers — not by application-level filters.
- **Inventory-as-Identity:** The same record is the asset and the credential. A Thing is a first-class auth record that can hold a NATS user and a Nebula host, so "the camera in the lobby" is one row that is simultaneously an inventory entry, a login, a messaging identity, and a mesh node. There is no separate device registry to keep in sync. See [Architecture §3.1](./architecture.md#31-inventory-as-identity).
- **A contract layer, not just a schema store:** Thing Types declare *where* a kind of participant speaks (a subject prefix), their operations declare *what verbs* it has (`publish` / `subscribe` / `request` / `reply`, each with a subject suffix), and message schemas declare *what shape* each payload takes (versioned JSON Schema). Subject and payload are described together, so a consumer can resolve from data alone which subjects a device uses and what it will send. See [Thing Types](./thing-types.md).
- **Role-scoped access, enforced in one place:** Five per-organization roles (`owner`, `admin`, `member`, `viewer`, `dashboard`) plus a platform Operator flag, enforced solely by PocketBase API rules on each collection. Credentials are protected by row scoping — you can read the identity you authenticate with and no other — and every role can rotate its own. See [Authorization & Roles](./authorization.md).
- **Digital Twins:** Live device state lives in NATS KV buckets and streams to the browser over WebSocket. Dashboards reflect changes in real time without polling the database.
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

## Documentation Journey

These pages, in order, walk through the platform from concept to deployment:

1.  **[Overview](./overview.md)** — Understand the vision and the problems we solve.
2.  **[Platform Layers](./platform-layers.md)** — The conceptual model: how the platform is structured as composable tiers.
3.  **[Architecture](./architecture.md)** — Learn how the Control Plane and Data Plane work together.
4.  **[Getting Started](./getting-started.md)** — Go from zero to a live dashboard in five minutes.
5.  **[Platform UI and Entities](./platform-ui-entities.md)** — Explore Organizations, Locations, and Things.
6.  **[Dashboards & Widgets](./dashboards.md)** — The Visualizer: seventeen widget types, the three data-source kinds, and dashboard variables.
7.  **[Authorization & Roles](./authorization.md)** — Who can do what: the five roles, the capability matrix, and the credential model.
8.  **[Stone CLI](./stone-cli.md)** — Drive the same entities, NATS, and a GitOps workspace from the terminal with the `stone` client.
9.  **[Thing Types](./thing-types.md)** — The contract layer: how participants on the fabric declare what they publish, subscribe to, request, and reply to.
10. **[Connectivity](./connectivity.md)** — Dive deep into NATS and Nebula configurations (Layer 0).
11. **[The Edge (Agent)](./agent.md)** — Provision and manage lightweight executors on remote hosts.
12. **[Leaf Nodes](./leaf-nodes.md)** — Model a site as a `leaf_nodes` record and mirror its config to the edge with `leaf-sync`.
13. **[Automation](./automation.md)** — Build intelligent routing, scheduled publishing, and stateful alarms with the rule engine (Layer 1).
14. **[Stream Processing](./stream-processing.md)** — Windowed aggregations, joins, and anomaly detection (Layer 2).
15. **[Observability](./observability.md)** — Long-term data storage and historical analysis (Layer 3).
16. **[Configuration Reference](./configuration.md)** — `config.yaml` keys, `STONE_AGE_*` environment variables, and operational notes.
17. **[Operations & Production](./operations.md)** — backups, recovery, upgrades, version compatibility, and the production checklist.

---

## Philosophy

> "Complexity is the enemy of reliability."

Stone-Age.io is built for engineers who value transparency and maintainability over cleverness. We prefer clear Go code, reactive Vue components, and straightforward YAML over magic abstractions. We provide the toolkit; you own the network.
