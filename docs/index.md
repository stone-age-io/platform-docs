# Welcome to the Stone-Age.io Docs

Stone-Age.io is a comprehensive toolkit designed for operators who need to build, manage, and scale distributed event-driven applications without the complexity of traditional cloud-locked platforms.

The Stone-Age.io Platform orchestrates three industry-leading technologies into a unified management experience:

- **Management (PocketBase):** A monolithic backend providing Identity, Inventory, and an embedded UI.
- **Messaging (NATS.io):** A high-performance, multi-tenant "Nervous System" for telemetry and commands.
- **Connectivity (Nebula):** A peer-to-peer mesh VPN that provides secure, encrypted tunnels to the extreme edge.

---

## Key Features

- **Each Component is a Single Binary:** No microservice sprawl. No Docker Compose hell. Each piece — Control Plane, rule engine, Agent, NATS, Nebula — is an independent executable that speaks NATS to its peers.
- **Infrastructure-as-Tenant:** Creating an organization automatically provisions isolated NATS accounts and Nebula CAs.
- **Digital Twins:** Real-time state management using NATS KV buckets — view and control devices with sub-millisecond latency.
- **Outbound-Only Security:** Devices punch through firewalls and NATs; no open ports required.
- **Grug-Brained Automation:** A unified rule engine (router, gateway, and scheduler features) expressing automation as simple YAML rules.
- **Bring Your Own Data:** Resilient NATS-native ingestion into your choice of TSDB (VictoriaMetrics, InfluxDB, etc.).

---

## Planes and Layers

Stone-Age.io isn't a monolithic product — it's a **Control Plane** (management surface) alongside a **Data Plane** (runtime) that is internally composed of four layers around a shared NATS substrate.

> **NATS is the bus. The rule engine is the reflexes. Stream processors are the thinking. Telegraf + TSDB is the memory.**

Each layer does one thing well. Each composes cleanly with the others. You can use just the bottom layer for pure messaging, or stack all four for a complete event-driven architecture. Understanding the model is the single most useful mental aid for working with the platform — it tells you where to solve each problem and when to reach for a different tool.

Start with [Platform Layers](./platform-layers.md) if you want the framing first.

---

## Documentation Journey

Start your journey here to understand how to build your private event-driven architecture:

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

Stone-Age.io is built for the engineer who values transparency and maintainability over cleverness. We prefer clear Go code, reactive Vue components, and straightforward YAML over magic abstractions. We provide the toolkit; you own the network.
