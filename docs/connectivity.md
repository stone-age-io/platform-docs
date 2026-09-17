# Connectivity

Connectivity is the backbone of the Stone-Age.io Platform — **Layer 0** of the Data Plane. We rely on two industry-leading technologies to provide a secure, resilient, and low-latency substrate: **NATS.io** for messaging and **Nebula** for overlay networking.

This document details how these technologies work together to create a secure "Radio Network" that handles communication from the cloud to the extreme edge. For the broader architectural picture of how Layer 0 composes with higher tiers (declarative event logic, stream processing, long-term storage), see [Platform Layers](./platform-layers.md).

---

## 1. NATS

NATS provides the messaging fabric for the platform. It is designed to be always on and handles everything from simple telemetry to durable data streams. This is just a quick overview of the features — we definitely suggest reading the NATS.io documentation for more information.

### Core Pub/Sub & Subject Namespacing

In NATS, messages are sent to **Subjects**. Subject namespaces are isolated by NATS account, so you can have the same subject in two Accounts without data overlapping. Stone-Age.io's canonical namespacing pattern is **family-first** and Thing-Type-aware:

```
{thing_type_code}.{location}.{thing}.{operation_suffix}
```

- **Examples:** `temp_sensor.warehouse-a.sensor-01.reading`, `camera.warehouse-a.cam-042.motion`, `gateway.chicago.gw-99.heartbeat`.
- **Where the segments come from:** `{location}` and `{thing}` are the codes on the Location and Thing records; `{thing_type_code}` (or a custom prefix) and the operation suffix come from the Thing Type contract. See [Thing Types](./thing-types.md) for the full subject template model.
- **Wildcards:** Wildcards match subject tokens. Subscribe to `camera.>` to see every camera event across every site, or `camera.warehouse-a.*.motion` to see every camera's motion events at one site. Family-first is deliberate: it lets a single JetStream stream capture one kind of Thing (`camera.>`) without wildcards mid-filter, which keeps stream design clean as your deployment grows.

**Subject discipline is the contract between layers.** Rules, stream processors, and observability consumers all identify their inputs and outputs by subject. Thing Types make this contract declarative — picking a clean prefix once on a Thing Type means every instance of that kind follows the same shape.

Note: subject permissions are attached to the NATS user, usually through a reusable **NATS Role** (`nats_roles`) with optional per-user overrides. Permissions are expressed as publish/subscribe allow/deny patterns; deny rules are evaluated after allow, so combining them with wildcards can express fairly complex scenarios.

> **A "NATS role" is not a membership role.** `nats_roles` records are data-plane permission sets applied to NATS users; the five **membership** roles (`owner`, `admin`, `member`, `viewer`, `dashboard`) govern who may read or write platform records. Authoring `nats_roles` is Owner/Admin only — for **reads** as well as writes — because a role's publish and subscribe permission fields are copied **verbatim** into the user JWT the platform signs. Write access to them is therefore equivalent to granting NATS permissions. See [Authorization](./authorization.md).

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

How the platform models such a site — as an ordinary **Thing**, whose Agent bootstraps and optionally hosts the leaf server — is covered in [Leaf Nodes](./leaf-nodes.md).

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

Both views — **including their lists** — are Owner/Admin only. A member, viewer or dashboard holder querying `nats_account_exports` or `nats_account_imports` receives an empty result, not a filtered one.

**Platform-managed records are read-only.** Flagging an Organization `managed`
provisions a pair of these records automatically — a `helpdesk-events` export on
the tenant's Account, and a matching import on the operator hub Account. Both
show a **Managed** badge and offer **View** instead of Edit or Delete.

That is not a permission — an Owner has write access to the collection — it is
the console declining to offer an edit that would not last. The platform
reconciles `subject`, `type`, `description` (and the import's source `account`
and `local subject`) every time the Organization record is saved, so a change
made here is overwritten with no error and no warning. Deleting one does not
retire it either: the next save recreates it. **To remove the pair, clear
`managed` on the Organization,** which deletes both sides together.

The two records land on different screens: the export lives on the tenant's own
Account, so a managed tenant's Owner sees it under their Exports; the import
lives on the operator hub Account, so only someone in the operator Organization
sees it under Imports.

**When to reach for it:**

- A **shared "system events" Account** that publishes to many tenants — each tenant Account adds an import to receive the feed.
- A **service-bureau pattern** — one Account hosts a request/reply service (geocoding, billing-rate lookups, OCR) and other Accounts import the service subject.
- **Cross-tenant collaboration** between two specific orgs that need to exchange a narrow set of subjects without merging Accounts.

Imports/exports are the right tool when you want **cryptographically separated tenants that occasionally share a subject**. If you want full shared traffic, the answer is one Account — not many Accounts wired together with imports and exports.

---

## 2. Nebula

Nebula is an overlay networking tool. It lets your devices talk to each other as if they were on the same local network, even when they sit on different continents behind restrictive firewalls. Again, this is just a brief overview. Refer to the official Nebula documentation for a more in-depth understanding.

> **Who can manage this:** `nebula_networks` and `nebula_hosts` are Owner/Admin only, for **reads** as well as writes — a host's `config_yaml` embeds its private key, so every role below admin gets an empty list. The exceptions are row-scoped: a Thing may read the Nebula host assigned to it, and a host may read its own record. The org's `nebula_ca` record is readable by any role but writable only by a Platform Operator. Rolling the CA is not a record edit at all: it is a three-step route, `POST /api/org/nebula-ca/rotate`, and an **Owner/Admin** one — the wait in the middle of a rotation belongs to whoever operates the devices. See [Authorization §4.3](./authorization.md#43-rolling-a-nebula-ca).

### Mesh VPN Fundamentals

Nebula creates a **Peer-to-Peer (P2P)** network. Once a connection is established between two devices, traffic flows directly between them. This reduces latency and eliminates the bottleneck of a traditional VPN concentrator.

### Lighthouses & Discovery

Because edge devices are often behind NAT (Network Address Translation), they don't have static IPs.

-  **The Lighthouse:** A server with a static IP that acts as a directory. 
- **Discovery:** When *Host A* wants to talk to *Host B*, it asks the Lighthouse for the current real-world IP of *Host B*. The two hosts then "punch a hole" through their respective firewalls to talk directly.

Mark one with `is_lighthouse` on its Nebula Host record, and give it a **`public_host_port`** (`1.2.3.4:4242`) — the publicly reachable address peers read from their own static host map.

### Relays

In some extreme environments (like strictly monitored corporate networks), hole-punching fails.

- **The Relay:** when a direct connection can't be established, Nebula forwards that traffic through a host marked `is_relay`. Connectivity survives network conditions that defeat hole-punching.

A relay is **designated, not discovered** — nothing happens until some host in the network carries `is_relay`. Two properties are worth knowing:

- **A relay needs a `public_host_port` too.** Without one the host listens on an ephemeral port while every peer has already been handed its overlay IP as a usable path — so the path is advertised and then does not work. The console requires the field as soon as you tick either box, for this reason.
- **Relaying is config-only.** A relay's certificate is no different from any other host's, so turning it on and off is a config change that needs no re-issue. Contrast `unsafe_networks` below, which is the opposite case.

**Lighthouse and relay are independent**, and a host can be both — the host list badges them separately because they answer different questions: a lighthouse tells peers *where* someone is, a relay carries the packets when they still can't get there.

### Reaching subnets that are not on the mesh

A Nebula host can act as a **gateway** into the ordinary network behind it — a site's camera VLAN, a building's BMS segment — so mesh members reach those addresses without running Nebula on every device there.

This takes two fields, and the thing to internalise is that **they live on different hosts and neither one implies the other:**

| Field | Set it on | What it means |
| :--- | :--- | :--- |
| `unsafe_networks` | the **gateway** — the host with a foot in both networks | "I will route to these subnets." One CIDR per line. |
| `unsafe_routes` | **every host that wants to reach them** | `{ route, via }` pairs, where `via` is the gateway's *overlay* IP. |

Configure only the first and the gateway is willing to route while nobody sends it anything. Configure only the second and peers aim traffic at a gateway that refuses it. No peer derives another host's routes, and nothing warns you about the half you skipped.

!!! warning "`unsafe_networks` is signed into the certificate — editing it is inert until the host picks up a new one"
    Nebula authorizes routing on the **certificate**, not on config. A gateway whose certificate omits a prefix silently refuses to route it and **drops the packet before any firewall rule runs** — so the rule you are staring at is not the one failing, and no amount of correcting it helps.

    Saving `unsafe_networks` therefore re-issues the gateway's certificate, and the change does nothing until that host has fetched it. `is_relay` is the opposite case: config-only, effective on the next config pull. `unsafe_routes`, on the consumer side, is also plain config.

### Per-host tuning

Three optional overrides. All are config-only, and all inherit a default when left empty:

- **`preferred_ranges`** — **underlay** prefixes this host should favour when a peer advertises several addresses, typically the LAN it sits on, so two machines in one rack talk over private addresses instead of routing out and back. Entries must be in canonical masked form (`172.16.0.0/24`, not `172.16.0.5/24`).
- **`mtu`** — defaults to 1300. Lower it on a path that fragments.
- **`tun_device`** — the interface name; defaults to `nebula1`.

!!! note "`preferred_ranges` is the one place IPv6 is accepted"
    The platform is IPv4-only, but that is a constraint on the *overlay*. These are underlay prefixes, and Nebula ranks an IPv6 preferred range at the very top of its address priority list — refusing them would rule out the case the feature is best at.

    It is also validated on write rather than trusted, because Nebula's own failure mode here is silent: it logs a warning, skips the malformed entry, and forms the tunnel anyway over the public path. The only symptom of a typo is traffic quietly taking the slow route, so rejecting it at the point of entry is the only place it is visible.

### Host-Based Firewalls

Nebula security is **Identity-Based**, not IP-based. 

- Firewall rules are defined in YAML and enforced by the Nebula binary on each host.
- You can define **Groups** (e.g., `sensors`, `gateways`, `admins`). 
-  **Example Rule:** "Allow the `admins` group to SSH into the `gateways` group, but deny `sensors` from talking to anything except the `gateways`."

!!! note "Group membership is on the certificate, so changing it costs a re-issue"
    Exactly four host fields are signed into the certificate — **`hostname`, `overlay_ip`, `groups` and `unsafe_networks`** — and a change to any of them is inert until the host holds a new one. Moving a host between firewall groups is therefore the same class of edit as changing its routing, not a config tweak: peers keep applying the old group's rules until the new certificate is in place. Everything else about a host, firewall *rules* included, renders into `config_yaml` and takes effect on the next pull.

    You do not have to wait for the expiry cycle: re-issuing is a per-host action (`renew`) that takes effect immediately.

---

## 3. The "Outbound-Only" Advantage

The most significant benefit of the Stone-Age.io connectivity stack is the security of the **Outbound-Only** model.

- **No Open Ports:** Your edge devices (Things) do not need any ports open on their local routers. 
- **No Port Forwarding:** Both NATS and Nebula initiate connections *outbound* to your central infrastructure.
- **Reduced Attack Surface:** Since no ports are listening on the public internet, your devices are invisible to standard port scanners and automated bot attacks.

Combining the cryptographic identity of NATS with the tunnelling of Nebula means a device presents signed material at both layers, and a compromised device is revoked at both — without a shared secret, a VPN concentrator, or an inbound port on the site.

---

## 4. Where to Go Next

- **Layer 1 (declarative event logic):** [Automation](./automation.md).
- **Layer 2 (stream processing):** [Stream Processing](./stream-processing.md).
- **Layer 3 (long-term storage):** [Observability](./observability.md).
- **Who may author roles, hosts, and account wiring:** [Authorization & Roles](./authorization.md).
- **Rotating the CA, and auditing host certificates whose mask no longer matches their network:** [Stone CLI — Nebula operations](./stone-cli.md#nebula-operations-that-are-not-record-writes).
- **The edge integration story:** [The Agent](./agent.md).
- **Modeling & syncing a site:** [Leaf Nodes](./leaf-nodes.md).
- **The layer model in full:** [Platform Layers](./platform-layers.md).
