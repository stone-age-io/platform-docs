# Welcome to the Stone-Age.io Docs

Stone-Age.io is a toolkit for building, managing, and scaling distributed event-driven applications on infrastructure you control. It pairs an opinionated control plane with proven open-source primitives so the operational story stays understandable as the system grows.

The platform brings three projects together under a single management surface:

- **Management — PocketBase:** A self-contained backend that handles identity, inventory, and the embedded UI.
- **Messaging — NATS.io:** A high-performance, multi-tenant fabric for telemetry, commands, and live state.
- **Connectivity — Nebula:** A peer-to-peer mesh VPN that delivers encrypted tunnels all the way to the edge.

---

## Key Features

- **Single-binary components:** The Control Plane, rule engine, Agent, NATS, and Nebula each ship as a self-contained executable with no runtime dependencies. They wire themselves together over NATS, so the same architecture works on bare metal, a single VM, containers, or a Kubernetes cluster — whichever fits your operations.
- **Infrastructure-as-Tenant:** Creating an Organization provisions an isolated NATS Account and a private Nebula CA. Tenant boundaries are enforced cryptographically at the messaging and network layers — not by application-level filters.
- **Digital Twins:** Live device state lives in NATS KV buckets and streams to the browser over WebSocket. Dashboards reflect changes in real time without polling the database.
- **Outbound-only security:** Devices and Agents initiate connections outward to NATS and Nebula. No inbound ports are required, so edge nodes stay invisible to the public internet.
- **Declarative automation:** A unified rule engine (router, gateway, and scheduler features) expresses NATS routing, webhook ingestion and egress, and cron-driven publishes as YAML rules.
- **Bring your own storage:** Long-term telemetry is consumed from NATS by the time-series database of your choice — VictoriaMetrics, InfluxDB, Prometheus, Postgres, or anything else Telegraf can target.

---

## Planes and Layers

Stone-Age.io isn't a monolithic product — it's a **Control Plane** (management surface) alongside a **Data Plane** (runtime) that is internally composed of four layers around a shared NATS substrate.

> **NATS is the bus. The rule engine is the reflexes. Stream processors are the thinking. Telegraf + TSDB is the memory.**

Each layer does one thing well. Each composes cleanly with the others. You can use just the bottom layer for pure messaging, or stack all four for a complete event-driven architecture. Understanding the model is the single most useful mental aid for working with the platform — it tells you where to solve each problem and when to reach for a different tool.

Start with [Platform Layers](./platform-layers.md) if you want the framing first.

---

## Documentation Journey

These pages, in order, walk through the platform from concept to deployment:

1.  **[Overview](./overview.md)** — Understand the vision and the problems we solve.
2.  **[Platform Layers](./platform-layers.md)** — The conceptual model: how the platform is structured as composable tiers.
3.  **[Architecture](./architecture.md)** — Learn how the Control Plane and Data Plane work together.
4.  **[Getting Started](./getting-started.md)** — Go from zero to a live dashboard in five minutes.
5.  **[Platform UI and Entities](./platform-ui-entities.md)** — Explore Organizations, Locations, and Things.
6.  **[Thing Types](./thing-types.md)** — The contract layer: how participants on the fabric declare what they publish, subscribe to, request, and reply to.
7.  **[Connectivity](./connectivity.md)** — Dive deep into NATS and Nebula configurations (Layer 0).
8.  **[The Edge (Agent)](./agent.md)** — Provision and manage lightweight executors on remote hosts.
9.  **[Automation](./automation.md)** — Build intelligent routing, scheduled publishing, and stateful alarms with the rule engine (Layer 1).
10. **[Stream Processing](./stream-processing.md)** — Windowed aggregations, joins, and anomaly detection (Layer 2).
11. **[Observability](./observability.md)** — Long-term data storage and historical analysis (Layer 3).
12. **[Configuration Reference](./configuration.md)** — `config.yaml` keys, `STONE_AGE_*` environment variables, and operational notes.

---

## Philosophy

> "Complexity is the enemy of reliability."

Stone-Age.io is built for engineers who value transparency and maintainability over cleverness. We prefer clear Go code, reactive Vue components, and straightforward YAML over magic abstractions. We provide the toolkit; you own the network.
