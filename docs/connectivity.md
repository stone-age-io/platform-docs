# Connectivity

Connectivity is the backbone of the Stone-Age.io Platform — **Layer 0** of the Data Plane. We rely on two industry-leading technologies to provide a secure, resilient, and low-latency substrate: **NATS.io** for messaging and **Nebula** for overlay networking.

This document details how these technologies work together to create a secure "Radio Network" that handles communication from the cloud to the extreme edge. For the broader architectural picture of how Layer 0 composes with higher tiers (declarative event logic, stream processing, long-term storage), see [Platform Layers](./platform-layers.md).

---

## 1. NATS

NATS provides the messaging fabric for the platform. It is designed to be always on and handles everything from simple telemetry to durable data streams. This is just a quick overview of the features — we definitely suggest reading the NATS.io documentation for more information.

### Core Pub/Sub & Subject Namespacing

In NATS, messages are sent to **Subjects**. Subject namespaces are isolated by NATS account, so you can have the same subject in two Accounts without data overlapping. Stone-Age.io's canonical namespacing pattern is location-first and Thing-Type-aware:

```
{location}.{thing_type_code}.{thing}.{operation_suffix}
```

- **Examples:** `warehouse-a.temp_sensor.sensor-01.reading`, `warehouse-a.camera.cam-042.motion`, `chicago.gateway.gw-99.heartbeat`.
- **Where the segments come from:** `{location}` and `{thing}` are the codes on the Location and Thing records; `{thing_type_code}` (or a custom prefix) and the operation suffix come from the Thing Type contract. See [Thing Types](./thing-types.md) for the full subject template model.
- **Wildcards:** Wildcards are powerful tools for subject tokens. You can subscribe to `warehouse-a.>` to see every message from that site, or `warehouse-a.camera.*.motion` to see every camera's motion events at that site.

**Subject discipline is the contract between layers.** Rules, stream processors, and observability consumers all identify their inputs and outputs by subject. Thing Types make this contract declarative — picking a clean prefix once on a Thing Type means every instance of that kind follows the same shape.

Note: Permissions are role-based, with subject permissions applied to the user. Permissions can be set by publish/subscribe allow/deny patterns. Deny rules are evaluated after Allow, so combining with wildcard patterns can be used to create complex scenarios.

### JetStream

Core NATS is "fire and forget." To handle historical data or "at-least-once" delivery, we use **JetStream**.

- **Streams:** Capture and store messages published to specific subjects.
- **Consumers:** Allow the platform (or your apps) to read back history. This is how the UI populates charts with historical data when you first open a dashboard.

JetStream is also what makes the platform resilient to Layer 3 outages — telemetry retained in a JetStream stream catches up to the TSDB when Telegraf reconnects, with no data loss.

### Key-Value Buckets (Live State)

JetStream offers specialized streams called Key-Value (KV) buckets that are optimized for high-frequency updates. They're the substrate primitive behind two distinct platform concerns:

- **The Digital Twin** — per-entity live state (current temperature, online status, set points) that the UI reads/writes over WebSocket. The static side of the same entity (name, serial, location) lives in PocketBase. See [Architecture §4](./architecture.md#4-the-digital-twin-concept-live-state) for the canonical model.
- **Layer 1 rule state** — alarm status, presence keys, debounce windows, rate-limit counters. Rules stay stateless per message; KV holds the durable state. See [Automation §5](./automation.md#5-stateful-patterns-via-kv).

Both concerns share the same buckets, the same access patterns, and the same isolation boundary (the org's NATS Account).

### Leaf Nodes

For MSPs managing remote customer sites, **Leaf Nodes** are a game changer. A Leaf Node is a fully functional NATS server or cluster running locally at a customer site that connects back to a central cluster using one-way, outbound communication. They can be deployed on small devices like cellular routers/gateways from Cradlepoint or Peplink for small installations, or can be an entirely separate cluster deployed at the edge for low latency and redundancy.

- **Local Autonomy:** If the internet goes down, the local devices can still talk to each other and store data.
- **Transparent Bridging:** When the connection is restored, the Leaf Node automatically syncs data back to your central Stone-Age.io cluster.

Leaf nodes enable **edge deployment of higher layers** too. A rule engine instance running alongside a leaf node continues to evaluate rules against locally-mirrored KV state during a WAN outage. A stream processor at the edge keeps producing aggregates. The whole layered architecture works offline at each site, with changes replicating bidirectionally when connectivity returns.

### Cross-Account Subject Sharing (Imports & Exports)

NATS Accounts are isolated by default — subjects in Account A are invisible to Account B. **Imports** and **Exports** are the NATS-native way to punch a controlled hole between two Accounts when you genuinely want shared traffic.

**The protocol model:**

- An **Export** is a declaration on the *source* Account: "I am willing to share this subject (or stream) with other Accounts." Exports come in two flavors:
    - **Stream export** — pub/sub: subscribers in importing accounts see published messages.
    - **Service export** — request/reply: requesters in importing accounts can call the service and receive replies.
- An **Import** is the matching declaration on the *consuming* Account: "I want to subscribe to this exported subject from that Account." The import optionally remaps the subject into the local namespace (e.g., a remote `events.>` becomes local `partner.events.>`).
- Exports can be **public** (any Account may import) or **private** (importing requires a token signed by the exporting Account).

The platform manages both sides as first-class collections (`nats_account_exports`, `nats_account_imports`) so the cluster's account-level wiring is configuration data, not a hand-edited resolver file.

**The UI surface:**

- **Exports** (`/nats/exports`): list, create, edit, and delete exports for the current org's Account. Form fields cover the subject, type (`stream`/`service`), token requirement, response type for services (`Singleton`/`Stream`/`Chunked`), `advertise`, and an optional description.
- **Imports** (`/nats/imports`): list, create, edit, and delete imports. Form fields cover the source Account public key, the remote subject, an optional local subject remap, the activation token (for private exports), type, share, and `allow_trace`.

**When to reach for it:**

- A **shared "system events" Account** that publishes to many tenants — each tenant Account adds an import to receive the feed.
- A **service-bureau pattern** — one Account hosts a request/reply service (geocoding, billing-rate lookups, OCR) and other Accounts import the service subject.
- **Cross-tenant collaboration** between two specific orgs that need to exchange a narrow set of subjects without merging Accounts.

Imports/exports are the right tool when you want **cryptographically separated tenants that occasionally share a subject**. If you want full shared traffic, the answer is one Account — not many Accounts wired together with imports and exports.

---

## 2. Nebula

Nebula is a scalable overlay networking tool with a focus on performance, simplicity, and security. It allows your devices to talk to each other as if they were on the same local network, even if they are scattered across the globe behind restrictive firewalls. Again, this is just a brief overview. Refer to the official Nebula documentation for a more in-depth understanding.

### Mesh VPN Fundamentals

Nebula creates a **Peer-to-Peer (P2P)** network. Once a connection is established between two devices, traffic flows directly between them. This reduces latency and eliminates the bottleneck of a traditional VPN concentrator.

### Lighthouses & Discovery

Because edge devices are often behind NAT (Network Address Translation), they don't have static IPs.

-  **The Lighthouse:** A server with a static IP that acts as a directory. 
- **Discovery:** When *Host A* wants to talk to *Host B*, it asks the Lighthouse for the current real-world IP of *Host B*. The two hosts then "punch a hole" through their respective firewalls to talk directly.

### Relays

In some extreme environments (like strictly monitored corporate networks), hole-punching might fail.

- **The Relay:** If a direct connection can't be made, Nebula will automatically route traffic through a Relay. This ensures that connectivity is maintained even in the most difficult network conditions.

### Host-Based Firewalls

Nebula security is **Identity-Based**, not IP-based. 

- Firewall rules are defined in YAML and enforced by the Nebula binary on each host.
- You can define **Groups** (e.g., `sensors`, `gateways`, `admins`). 
-  **Example Rule:** "Allow the `admins` group to SSH into the `gateways` group, but deny `sensors` from talking to anything except the `gateways`."

---

## 3. The "Outbound-Only" Advantage

The most significant benefit of the Stone-Age.io connectivity stack is the security of the **Outbound-Only** model.

- **No Open Ports:** Your edge devices (Things) do not need any ports open on their local routers. 
- **No Port Forwarding:** Both NATS and Nebula initiate connections *outbound* to your central infrastructure.
- **Reduced Attack Surface:** Since no ports are listening on the public internet, your devices are invisible to standard port scanners and automated bot attacks.

By combining the cryptographic identity of NATS with the secure tunneling of Nebula, the Stone-Age.io Platform provides a level of security that traditional IoT platforms/protocols simply cannot match.

---

## 4. Where to Go Next

- **Layer 1 (declarative event logic):** [Automation](./automation.md).
- **Layer 2 (stream processing):** [Stream Processing](./stream-processing.md).
- **Layer 3 (long-term storage):** [Observability](./observability.md).
- **The edge integration story:** [The Agent](./agent.md).
- **The layer model in full:** [Platform Layers](./platform-layers.md).
