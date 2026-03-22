# Connectivity

Connectivity is the backbone of the Stone-Age.io Platform. We rely on two industry-leading technologies to provide a secure, resilient, and low-latency data plane: **NATS.io** for messaging and **Nebula** for overlay networking.

This document details how these technologies work together to create a secure "Radio Network" that handles communication from the cloud to the extreme edge.

---

## 1. NATS

NATS provides the messaging fabric for the platform. It is designed to be always on and handles everything from simple telemetry to durable data streams. This is just a quick overview of the features, we definitely suggest reading the NATS.io documentation for more information.

### Core Pub/Sub & Subject Namespacing

In NATS, messages are sent to **Subjects**. Subject namespaces are isolabed by NATS account, so you can have the same subject in two Accounts without data overlapping. Stone-Age suggests a hierarchical namespacing pattern to keep data organized within the Account:

`[location].[thing].[property]`
`[prefix].[entity].[subject]`

- **Examples:** `warehouse_chicago.temp_sensor_01.reading`, `things.controllers.io-abc123.data`, 'facilities.alerts.high`
- **Wildcards:** Wildcards are powerful tools for subject tokens. You can subscribe to `warehouse_chicago.>` to see every message from that site, or `*.*.status` to monitor the health of every device in the location. 

Note: Permissions are role-based, subject permissions applied to the user. Permissions can be set by publish/subscribe allow/deny patterns. Deny rules are evaluated after Allow, so combining with wildcard patterns can be used to create complex scenarios.

### JetStream

Core NATS is "fire and forget." To handle historical data or "at-least-once" delivery, we use **JetStream**.

- **Streams:** Capture and store messages published to specific subjects.
- **Consumers:** Allow the platform (or your apps) to read back history. This is how the UI populates charts with historical data when you first open a dashboard.

### The Digital Twin (KV Store)

JetStream offers specialized streams called Key-Value (KV) buckets to manage the live state of every entity. 

- Unlike a database, the KV store is optimized for high-frequency updates.
- Metadata (Name, Serial #) lives in PocketBase. Live State (Current Temp, Online Status) lives in KV.

### Leaf Nodes

For MSPs managing remote customer sites, **Leaf Nodes** are a game changer. A Leaf Node is a fully functional, NATS server or cluster running locally at a customer site that connects back to a central cluster using one-way, outbound communication. They can be deployed on small devices like cellular routers/gateways from Cradlepoint or Peplink for small installations, or can be an entirely separate cluster deployed at the edge for low latency and redundancy.

- **Local Autonomy:** If the internet goes down, the local devices can still talk to each other and store data.
- **Transparent Bridging:** When the connection is restored, the Leaf Nodes automatically syncs data back to your central Stone-Age cluster.

---

## 2. Nebula

Nebula is a scalable overlay networking tool with a focus on performance, simplicity, and security. It allows your devices to talk to each other as if they were on the same local network, even if they are scattered across the globe behind restrictive firewalls. Again, this is just a brief overview. Refer to the official Nebula documentation for an more indepth understanding.

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

The most significant benefit of the Stone-Age connectivity stack is the security of the **Outbound-Only** model.

- **No Open Ports:** Your edge devices (Things) do not need any ports open on their local routers. 
- **No Port Forwarding:** Both NATS and Nebula initiate connections *outbound* to your central infrastructure.
- **Reduced Attack Surface:** Since no ports are listening on the public internet, your devices are invisible to standard port scanners and automated bot attacks.

By combining the cryptographic identity of NATS with the secure tunneling of Nebula, the Stone-Age.io Platform provides a level of security that traditional IoT platforms/protocols simply cannot match.
