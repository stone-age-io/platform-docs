---
path: platform/connectivity
nav_order: 120
---
# Connectivity

Connectivity is **Layer 0** of the Data Plane. It uses **NATS.io** for
messaging and **Nebula** for overlay networking. This page describes how the
two carry traffic from the central site to the edge. For how Layer 0 fits with
the higher layers, see [Platform Layers](./platform-layers.md).

---

## 1. NATS

NATS carries all platform messaging, from simple telemetry to durable streams.
This is a short overview. See the [NATS documentation](https://docs.nats.io)
for detail.

### Core Pub/Sub & Subject Namespacing

NATS sends messages to **subjects**. Each NATS account has its own subject
namespace, so two accounts can use the same subject without sharing data. The
default Stone-Age.io pattern puts the Thing Type first:

```
{thing_type_code}.{thing}.{operation_suffix}
```

- **Examples:** `temp_sensor.TP-4KD-7PX.reading`, `camera.CA-9KD-4PX.motion`,
  `door.DOOR-1.opened`.
- **No location by default.** Things move. A subject built from the current
  location would move with the Thing, split its history across two sites, and
  leave its NATS permissions on the old site. A Thing code is already unique in
  the organization, which is the NATS account. See
  [Thing Types](./thing-types.md#two-constraints-worth-knowing-before-you-design-a-prefix)
  and [ADR 0003](./decisions/0003-human-friendly-codes-and-default-subject.md).
- **The Agent uses the same shape.** It is a management daemon, not a device
  with a Thing Type contract. Its subjects are `{subject_prefix}.{code}.…`, so a
  gateway's heartbeat is `agents.gw-99.heartbeat`. See
  [The Agent §3](./agent.md#3-capabilities).
- **Where the tokens come from:** `{thing}` is the Thing's code.
  `{thing_type_code}` (or a custom prefix) and the operation suffix come from the
  Thing Type. See [Thing Types](./thing-types.md).
- **Wildcards** match subject tokens. Subscribe to `camera.>` for every camera
  event, or `camera.*.motion` for every camera's motion events. With the type
  first, one JetStream stream can capture one kind of Thing (`camera.>`) with no
  wildcard in the middle of the filter.
- **You can change the layout.** The platform enforces only what an empty
  prefix resolves to and which characters a code can contain. A Thing Type can
  add `{location}` (`freezer.{location}.{thing}` for equipment that never
  moves), and an application can own its own tree, such as `acc.>` or `kiosk.>`
  in the demo. The account owner decides the rest.

**Subjects are the contract between layers.** Rules, stream processors and
observability consumers name their inputs and outputs by subject. Set a clean
prefix on a Thing Type once, and every Thing of that type follows it.

Subject permissions belong to the NATS user, usually through a reusable **NATS
Role** (`nats_roles`) with optional per-user overrides. Permissions are publish
and subscribe allow and deny patterns. Deny is evaluated after allow, so with
wildcards you can express complex cases.

**An empty allow list grants nothing.** The role's lists and the user's own
lists are combined. If together they allow no subject in one direction, the
signed JWT denies everything in that direction. To allow everything in the
account, write `>` explicitly. Publish and subscribe are separate, so a role
with only subscribe subjects gives a subscribe-only user. Two request/reply
details follow from this:

- A user that **sends** requests needs `_INBOX.>` on subscribe to receive the
  replies. It is not added for you.
- A user that **answers** requests needs either *Response Permissions* on its
  role, or `_INBOX.>` on publish.
- A NATS micro service that should be **discoverable** needs `$SRV.>` on
  subscribe. The Agent is one ([The Agent §3E](./agent.md#e-service-discovery)).

Before pb-nats v0.3.0 an empty list granted *everything* in the account
instead, so roles created earlier may need a second look.

> **A NATS role is not a membership role.** `nats_roles` records are Data Plane permission sets for NATS users. The five **membership** roles (`owner`, `admin`, `member`, `viewer`, `dashboard`) control who can read or write platform records. Only Owners and Admins can read or write `nats_roles`, because the platform copies a role's permission fields **exactly** into the user JWT it signs. See [Authorization](./authorization.md).

### JetStream

Core NATS does not store messages. For history and at-least-once delivery, use
**JetStream**.

- **Streams** store messages published to given subjects.
- **Consumers** read back history. Dashboards use them to fill charts when you
  open them.

JetStream also protects you from Layer 3 outages. Telemetry kept in a stream
reaches the TSDB when Telegraf reconnects, with no data loss, **if Telegraf
reads it through a JetStream consumer that keeps its position**. A plain
subject subscription, with or without a queue group, is core NATS: Telegraf
never sees what was published while it was down.

### Key-Value Buckets (Live State)

KV buckets are JetStream streams built for frequent updates. The platform uses
them for two things:

- **The digital twin:** live state per entity (temperature, online status,
  setpoints) that the console reads and writes over WebSocket. PocketBase holds
  the static data (name, serial, location). See
  [Architecture §4](./architecture.md#4-the-digital-twin-concept-live-state).
- **Layer 1 rule state:** alarm status, presence keys, last-known values. Rules
  keep no state between messages, and KV holds the state. See
  [Automation §5](./automation.md#5-stateful-patterns-via-kv). Debounce and rate
  limiting do not use KV. The rule engine has a per-rule `throttle`, and its
  windows are in each instance's memory, lost on restart. See
  [Automation](./automation.md#throttle-and-debounce-are-built-in).

Both uses share the same buckets and the same isolation boundary, the org's
NATS Account.

### Leaf Nodes

A **leaf node** is a NATS server or cluster at a customer site that connects to
a central cluster with an outbound connection only. For a small site, it can run
on a cellular router or gateway such as Cradlepoint or Peplink. For a large
site, it can be a separate cluster for low latency and redundancy.

- **Local autonomy:** if the internet connection fails, local devices still
  talk to each other, and local JetStream streams and KV buckets keep storing
  data.
- **Reconnection:** when the link returns, subject interest propagates again and
  traffic flows to and from the central cluster. Messages published *during*
  the outage cross only if something stored them: a stream at the leaf that the
  hub sources from, or a KV bucket synced across the link. Plain core NATS
  messages from the outage are not replayed.

Higher layers can also run at the edge. A rule engine next to a leaf node keeps
evaluating rules against local KV during a WAN outage. A stream processor at the
edge keeps producing aggregates. When the link returns, synced KV buckets catch
up in their own direction: hub to edge by mirror, edge to hub by relay.

The platform models a site as an ordinary **Thing**, whose Agent sets up the
leaf server and can host it. See [Leaf Nodes](./leaf-nodes.md).

### Cross-Account Subject Sharing (Imports & Exports)

NATS Accounts are isolated by default. Account B cannot see subjects in
Account A. **Imports** and **exports** are the NATS way to share chosen traffic
between two accounts.

- An **export** is on the *source* account. It offers a subject or stream to
  other accounts, as one of two types:
  - **Stream export** (pub/sub): subscribers in importing accounts receive the
    messages.
  - **Service export** (request/reply): requesters in importing accounts can
    call the service and get replies.
- An **import** is on the *consuming* account. It subscribes to an exported
  subject from another account. It can remap the subject into the local
  namespace, for example remote `events.>` to local `partner.events.>`.
- An export is **public** (any account can import it) or **private** (the
  importer needs a token signed by the exporting account).

The platform stores both sides as collections (`nats_account_exports`,
`nats_account_imports`), so account wiring is data, not a hand-edited resolver
file.

**In the console:**

- **Exports** (`/nats/exports`): list, create, edit and delete exports for the
  current org's account. Fields: subject, type (`stream`/`service`), token
  requirement, response type for services (`Singleton`/`Stream`/`Chunked`),
  `advertise` and an optional description.
- **Imports** (`/nats/imports`): list, create, edit and delete imports. Fields:
  source account public key, remote subject, optional local subject remap,
  activation token (for private exports), type, share and `allow_trace`.

Only Owners and Admins can use both views, **including the lists**. A member,
viewer or dashboard holder gets an empty result, not a filtered one.

**Platform-managed records are read-only.** When an Organization is flagged
`managed`, the platform creates a pair of records: a `helpdesk-events` export on
the tenant's account, and a matching import on the provider's hub account. Both
show a **Managed** badge and offer **View** instead of Edit or Delete.

This is not a permission. An Owner can write to the collection. The console
hides the edit because it would not last. Every save of the Organization record
resets `subject`, `type` and `description`, and the import's source `account`
and `local subject`, with no warning. A deleted record comes back on the next
save. **To remove the pair, clear `managed` on the Organization**, which
deletes both.

The export is on the tenant's own account, so a managed tenant's Owner sees it
under Exports. The import is on the provider's hub account, so only members of
the provider's organization (created by `--operator-org`) see it under Imports.

**Use imports and exports for:**

- A **shared "system events" account** that publishes to many tenants. Each
  tenant account imports the feed.
- A **service bureau**: one account hosts a request/reply service (geocoding,
  billing-rate lookups, OCR), and other accounts import the service subject.
- **Cross-tenant work** between two orgs that exchange a few subjects.

Use them for **separate tenants that share some subjects**. If two parties need
to share all traffic, use one account.

---

## 2. Nebula

Nebula is an overlay network. Devices talk as if they were on one local network,
even on different continents behind strict firewalls. This is a short overview.
See the [Nebula documentation](https://nebula.defined.net/docs/) for detail.

> **Who can manage Nebula:** only Owners and Admins can read or write `nebula_networks` and `nebula_hosts`, because a host's `config_yaml` contains its private key. Every lower role gets an empty list. A Thing can read the Nebula host assigned to it, and a host can read its own record. Any role can read the org's `nebula_ca` record, and only a Platform Operator can write it. Owners and Admins roll the CA through a three-step route, `POST /api/org/nebula-ca/rotate`. See [Authorization §4.3](./authorization.md#43-rolling-a-nebula-ca).

### Mesh VPN Fundamentals

Nebula builds a **peer-to-peer** network. After two devices connect, traffic
goes directly between them, with no VPN concentrator in the path.

### Lighthouses & Discovery

Edge devices are often behind NAT and have no static IP.

- **Lighthouse:** a server with a static IP that acts as a directory.
- **Discovery:** when *Host A* wants to reach *Host B*, it asks the lighthouse
  for *Host B*'s current public address. The two hosts then punch a hole
  through their firewalls and talk directly.

To make a host a lighthouse, set `is_lighthouse` on its Nebula Host record and
give it a **`public_host_port`** (`1.2.3.4:4242`). Peers read that address from
their static host map.

### Relays

On some networks, such as strictly monitored corporate networks, hole punching
fails. Then Nebula sends the traffic through a host marked `is_relay`.

A relay does not appear by itself. You must mark a host `is_relay`.

- **A relay needs a `public_host_port` too.** Without one, the host listens on a
  random port while peers already have it as a path, so the path does not work.
  The console requires the field when you tick either box.
- **Relaying is config only.** A relay's certificate is the same as any host's,
  so you can turn relaying on and off with no re-issue. `unsafe_networks` below
  is the opposite case.

**Lighthouse and relay are separate roles**, and one host can be both. A
lighthouse tells peers *where* a host is. A relay carries packets when peers
cannot reach each other directly. The host list shows a badge for each.

### Reaching subnets that are not on the mesh

A Nebula host can be a **gateway** into the normal network behind it, such as a
site's camera VLAN or a building's BMS segment. Mesh members then reach those
addresses without Nebula on every device.

This takes two fields, **on different hosts, and neither sets the other:**

| Field | Set it on | What it means |
| :--- | :--- | :--- |
| `unsafe_networks` | the **gateway**, the host on both networks | "I will route to these subnets." One CIDR per line. |
| `unsafe_routes` | **every host that must reach them** | `{ route, via }` pairs, where `via` is the gateway's *overlay* IP. |

With only the first, the gateway will route, but nobody sends it traffic. With
only the second, peers send traffic to a gateway that refuses it. No peer
derives another host's routes, and nothing warns you about the missing half.

::: warning `unsafe_networks` is in the certificate, so an edit does nothing until the host has a new one
Nebula authorizes routing by the **certificate**, not the config. A gateway
whose certificate lacks a prefix refuses to route it and **drops the packet
before any firewall rule runs**. The firewall rule you are looking at is not the
one that fails.

So saving `unsafe_networks` reissues the gateway's certificate, and the change
applies only after that host fetches it. `is_relay` is config only and applies
on the next config pull. `unsafe_routes`, on the consumer side, is also plain
config.
:::

### Per-host tuning

Three optional overrides. All are config only, and each has a default:

- **`preferred_ranges`:** **underlay** prefixes this host should prefer when a
  peer has several addresses, usually the host's LAN. Two machines in one rack
  then talk over private addresses. Use the masked form (`172.16.0.0/24`, not
  `172.16.0.5/24`).
- **`mtu`:** default 1300. Lower it on a path that fragments.
- **`tun_device`:** the interface name, default `nebula1`.

::: note `preferred_ranges` is the one place IPv6 is accepted
The platform's overlay is IPv4 only. These are underlay prefixes, and Nebula
ranks an IPv6 preferred range highest, so the platform accepts them.

The platform validates these entries on save. Nebula would log a warning, skip
a bad entry, and use the public path. The only sign of a typo would be slow
traffic.
:::

### Host-Based Firewalls

Nebula security is **based on identity**, not IP address.

- Each host's Nebula binary enforces firewall rules defined in YAML.
- You define **groups**, such as `sensors`, `gateways` and `admins`.
- **Example:** "Allow the `admins` group to SSH into the `gateways` group, and
  let `sensors` talk only to `gateways`."

::: note Group membership is in the certificate, so a change needs a re-issue
Four host fields are signed into the certificate: **`hostname`, `overlay_ip`,
`groups` and `unsafe_networks`**. A change to any of them applies only when the
host has a new certificate. Peers apply the old group's rules until then.
Everything else about a host, firewall *rules* included, goes into
`config_yaml` and applies on the next pull.

You do not have to wait for expiry. `renew` on a host signs a new certificate
at once. It applies when the host fetches its new config, so renew, then
redeploy that host.
:::

---

## 3. Outbound-Only Connections

- **No open ports:** edge devices need no open ports on their local routers.
- **No port forwarding:** NATS and Nebula both connect *outbound* to your
  central infrastructure.
- **Smaller attack surface:** nothing listens on the public internet, so port
  scanners and bots cannot find the devices.

A device presents signed material to both NATS and Nebula, and you revoke a
compromised device in both. No shared secret, VPN concentrator or inbound port
is needed.

---

## 4. Where to Go Next

- Layer 1: [Automation](./automation.md)
- Layer 2: [Stream Processing](./stream-processing.md)
- Layer 3: [Observability](./observability.md)
- Who can manage roles, hosts and account wiring: [Authorization & Roles](./authorization.md)
- CA rotation and the host certificate audit: [Stone CLI](./stone-cli.md#nebula-operations-that-are-not-record-writes)
- The edge: [The Agent](./agent.md)
- Modeling and syncing a site: [Leaf Nodes](./leaf-nodes.md)
- The layer model: [Platform Layers](./platform-layers.md)
