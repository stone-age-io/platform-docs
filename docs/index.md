# Welcome to the Stone-Age.io Docs

Stone-Age.io is a comprehensive toolkit designed for Managed Service Providers (MSPs) and System Integrators (SIs) who need to build, manage, and scale distributed event-driven applications without the complexity of traditional cloud-locked platforms.

The Stone-Age.io Platform orchestrates three industry-leading technologies into a unified management experience:

- **Management (PocketBase):** A monolithic backend providing Identity, Inventory, and an embedded UI.
- **Messaging (NATS.io):** A high-performance, multi-tenant "Nervous System" for telemetry and commands.
- **Connectivity (Nebula):** A peer-to-peer mesh VPN that provides secure, encrypted tunnels to the extreme edge.

---

## Key Features

- **Single-Binary Deployment:** No microservices. No Docker-compose. Just one executable.
- **Infrastructure-as-Tenant:** Creating an organization automatically provisions isolated NATS accounts and Nebula CAs.
- **Digital Twins:** Real-time state management using NATS KV buckets—view and control devices with sub-millisecond latency.
- **Outbound-Only Security:** Devices punch through firewalls and NATs; no open ports required.
- **Grug-Brained Logic:** Stateless automation using simple YAML rules via our high-performance Rule-Router.
- **Bring Your Own Data:** Resilient NATS-native ingestion into your choice of TSDB (VictoriaMetrics, InfluxDB, etc.).

---

## Documentation Journey

Start your journey here to understand how to build your private event-driven architecture:

1.  **[Overview](./overview.md)** — Understand the vision and the problems we solve.
2.  **[Architecture](./architecture.md)** — Learn how the Control Plane and Data Plane work together.
3.  **[Getting Started](./getting-started.md)** — Go from zero to a live dashboard in five minutes.
4.  **[Platform UI and Entities](./platform-ui-entities.md)** — Explore Organizations, Locations, and Things.
5.  **[Connectivity](./connectivity.md)** — Dive deep into NATS and Nebula configurations.
6.  **[The Edge (Agent)](./agent.md)** — Provision and manage lightweight executors on remote hosts.
7.  **[Automation](./automation.md)** — Build intelligent routing and stateful alarms.
8.  **[Observability](./observability.md)** — Learn our philosophy on long-term data storage.

---

## Philosophy

> "Complexity is the enemy of reliability."

Stone-Age.io is built for the engineer who values transparency and maintainability over cleverness. We prefer clear Go code, reactive Vue components, and straightforward YAML over magic abstractions. We provide the toolkit; you own the network.
