---
path: platform/leaf-nodes
nav_order: 140
---
# Leaf Nodes

A site with its own local NATS server keeps working when the WAN fails. The
transport is a stock NATS leaf node ([Connectivity §1](./connectivity.md#leaf-nodes)).
It connects outbound to the hub and keeps the site running during an outage.

**The box that runs the leaf is a gateway, and the platform models it as an
ordinary Thing.** Its [Agent](./agent.md) has its leaf-node capabilities turned
on. There is no special record type or collection, so gateways use the same
inventory, identity model and API rules as everything else.

> ## Four related terms
>    | Term | What it is |
>    | :--- | :--- |
>    | **A site** | The place: a Location, not a Thing. A site can have several gateways, or none when its devices reach the platform through a vendor's cloud. See the [Glossary](./glossary.md). |
>    | **NATS leaf node** | The stock `nats-server` in leaf mode on the gateway, connected outbound to the hub. A Layer 0 transport. See [Connectivity](./connectivity.md#leaf-nodes). |
>    | **A gateway** | The *platform's* model of the box that runs the leaf: an ordinary **Thing**, with one NATS identity and optionally a Nebula host. Nothing in the schema marks it as a gateway (§1). This page covers how you configure one and how you check that it is up. |
>    | **The [Agent](./agent.md)** | The binary on the box. It manages the device and, if configured, bootstraps and hosts the leaf node. |

---

## 1. There is no gateway flag

**Nothing on the platform marks a Thing as a gateway.** The rest of this page
follows from that.

- **No code would read a flag.** The config route serves any authenticated
  Thing (§3). The agent starts a leaf because *its own* config says to, not
  because a record says so. A flag that nothing reads drifts from reality.
- **The domain is not stored.** A leaf's JetStream domain is the Thing's code,
  computed on each request (§3), so it cannot disagree with the code.
- **The hub does not copy inventory to the edge.** An edge identity needs no
  read access to the inventory, and has none.

**A Thing Type does not say "gateway" either.** A `thing_types` record has
`name`, `description`, `code`, `prefix`, `subject_prefix`, `operations` and
`metadata_schema`, and no gateway flag. An organization can name one of its
types "Gateway", but the platform does not read that name. There is no field to
check, to filter a list by, or to tell a screen which Things should have a leaf
node.

An agent gets everything it needs to start a leaf server from one route,
`GET /api/me/leaf-config`, and **that route checks nothing** beyond sign-in
(§3).

---

## 2. Why the edge pulls, rather than the hub pushing

The Control Plane is the **NATS Operator** and uses only the **SYSTEM
account**. It has no access inside any tenant's account (see
[Architecture §2](./architecture.md#key-properties-of-this-topology)). So it
*cannot* push anything into an organization's buckets, and it cannot read from
them.

So the gateway pulls its config, signed in as itself. Live data (twin state,
telemetry) goes through JetStream mirrors and relays across domains, set up by
the account's own users (§5 and §6).

---

## 3. `GET /api/me/leaf-config`

Bound to the `things` collection, with **no record id**. It targets the
caller's own record, like `POST /api/me/nats-creds/rotate`. It returns ten named
fields:

| Field | What it is |
| :--- | :--- |
| `code` | The Thing's code |
| `domain` | The leaf's JetStream domain, **the same string as `code`** |
| `creds` | This Thing's own NATS credential |
| `account_jwt`, `account_pub` | The organization's NATS account |
| `operator_jwt` | The NATS Operator |
| `sys_account_jwt`, `sys_account_pub` | The `$SYS` account (see §4) |
| `hub_leaf_url` | Where the leaf remote connects to the hub |
| `hub_domain` | The hub's own JetStream domain |

The two hub fields come from `nats.leaf_url` and `nats.jetstream_domain`
([Configuration §2](./configuration.md#2-section-reference)). If either is
empty, the route answers `503` and names the setting, because that hub is not
set up for gateways (§5).

**There is no flag or capability check on it.** Everything it returns is public
trust material or the caller's own credential. Every server in the network
already validates the Operator, account and `$SYS` account JWTs, and the caller
must already hold its credential to connect. A Thing that never runs a leaf node
learns nothing new from this route. A check here would protect data that is not
secret, and it would need a flag to check.

The route does *not* return account **seeds**, signing keys or any `$SYS`
**user** credential. Only superusers can read `nats_system_operator`. A gateway
can read only its own linked NATS identity and Nebula host from `nats_*` and
`nebula_*`, and no inventory collection, not even other Things in its
organization. A leaked edge credential exposes those ten values plus that
Thing's own access, whatever the collection rules become later.

### The domain is the code, computed and never stored

The platform computes `domain` from `code` on each request. The agent writes it
into **both** `server_name` and `jetstream { domain }` in the generated config.
A status widget matches a leaf's `server_name` to a Thing's `code` to name the
gateway (§7). So the two must always match, and the simplest way is to have
only one of them.

There is no `edge-` prefix and no organization token in it. JetStream is already
scoped to the account, so a prefix would only be something for every consumer to
remove.

---

## 4. Two required directives

The Agent generates `nats-leaf.conf` from the ten fields above. Operator mode
requires two directives in it: an `account` key on every leaf remote, and the
`$SYS` account JWT in `resolver_preload`. That is why the route serves the
`$SYS` **account** JWT. It is public trust material and grants nothing. To
connect *as* `$SYS` you need a `$SYS` **user** credential, and the platform
never serves one. See [Agent: leaf node §2](./vendor/agent/docs/leaf-node.md#2-two-directives-that-are-not-optional)
for the error each one prevents and the test that checks the generated file.

The platform tests its side of the contract, the ten field names, separately.
Keep both tests if you change either side.

---

## 5. Deploy flow

The hub is set up once, for every gateway:

- **A leaf node listener and a JetStream domain.** `nats export` writes
  `leafnodes { port: 7422 }`, and `domain` inside `jetstream { }` from
  `nats.jetstream_domain`. Without the domain, every mirror from the hub fails,
  because the agent addresses the hub's JetStream as `$JS.<domain>.API`. A
  `nats.conf` exported by platform v0.10.0 or earlier has neither, and the
  export does not rewrite an existing file. Add both by hand (`domain: hub`
  inside `jetstream { }`, or your `nats.jetstream_domain`) and restart the
  server. Adding the domain keeps existing streams and buckets.
- **The address edge boxes dial.** Set `nats.leaf_url`
  (`STONE_AGE_NATS_LEAF_URL`), for example `nats-leaf://hub.acme.io:7422`, and
  open port 7422 to the gateways. In the container, publish it with
  `-p 7422:7422`.

Then, for each gateway:

1. In the console, create the gateway's **Thing**, with any Thing Type your
   organization uses for gateways (§1). Set its Location to the site it serves,
   if it serves one. Copy the login email and password from the success dialog.
   The password is shown only once.
2. Install the [Agent](./agent.md) on the edge box and configure the platform
   block:

    ```yaml
    code: "s01"
    platform:
      url: "https://platform.acme.io"
      identity: "s01@acme.thing.local"   # <code>@<org code>.thing.local
      password_env: "AGENT_PLATFORM_PASSWORD"
    nats:
      urls: ["nats://127.0.0.1:4222"]
      auth:
        type: "platform"
        creds_file: "/etc/agent/device.creds"
    tasks:
      service_check:
        enabled: false       # on by default, and refused with no services listed
    sync:
      twin: true             # optional, see §6
    observability:
      addr: "127.0.0.1:9100" # optional, see §7
    ```

    Two startup checks often fail here. `tasks.service_check` is on by default,
    and the Agent refuses a config that lists no services. Turn it off, as
    above, or list the gateway's services. `commands.scripts_directory` defaults to
    `/opt/agent/scripts`, which must exist. The install steps in
    [The Agent §1](./agent.md#getting-the-binary) create it.

3. Run `agent -leaf-config` once, on its own. It writes `nats-leaf.conf` and
   the creds in the same directory, and the leaf needs write access to that
   directory.
4. Start the leaf, either as its own `nats-server -c /etc/agent/nats-leaf.conf`
   under systemd or Docker (the default, so the bus stays up when the agent
   restarts), or hosted by the agent with `nats.server_config`.
5. Run `agent -service install && agent -service start`.
6. Point any site-local [rule engine](./automation.md) at the same creds file.

**After that, the running Agent keeps the leaf config current.** Every
`platform.leaf_refresh_interval` (`5m` by default), it checks
`GET /api/me/account-jwt`. If the account JWT changed, it fetches
`GET /api/me/leaf-config` again, rewrites `nats-leaf.conf` and reloads the leaf.
A separately supervised leaf on Windows does not reload, so restart it.
`cmd.leaf_refresh` runs a refresh at once. This refresh is how a revocation
reaches the site (§8.1).

The two ways of running the leaf, the reload on each OS, and the file layout
are in [Agent: leaf node §3](./vendor/agent/docs/leaf-node.md#3-running-the-server).

---

## 6. Offline autonomy and KV bucket sync

With the leaf running, the higher layers work at the edge without the hub. A
[rule engine](./automation.md) keeps running site-local rules, a
[stream processor](./stream-processing.md) keeps producing aggregates, and
devices keep publishing to the local leaf for local subscribers.

**The leaf does not store and forward by itself.** A core NATS message
published while the uplink is down reaches the site's subscribers and never
reaches the hub. Interest propagates again when the link returns, but nothing
replays missed messages. Only *stored* data crosses back: a declared KV bucket
that the Agent relays (below), or a JetStream stream at the leaf that a
hub-side stream sources from. The Agent does not create these streams. If a site
must not lose telemetry during an outage, declare that stream yourself.

The `sync:` block keeps **KV buckets** in step across the link, so the site can
decide locally during a WAN outage. There is one list for each direction:

```yaml
sync:
  twin: true                 # preset: twin_desired down, twin up
  mirrors:                   # hub → edge, maintained by the server
    - bucket: recipes
      keys: "line-a.>"
  relays:                    # edge → hub, pumped by the agent
    - bucket: events
      keys: "site.S01.>"
```

`sync.twin: true` is the preset for the digital twin. It expands to these two
buckets:

| Bucket | Written by | Flows | Mechanism |
| :--- | :--- | :--- | :--- |
| `twin` | the device, at the edge | edge to hub | relay |
| `twin_desired` | people and rules, at the hub | hub to edge | JetStream **mirror** |

Sync is off by default, because it adds Data Plane traffic, and an upgrade must
not start that silently.

### 6.1 Three things to know before you declare a bucket

- **Each bucket has one writer.** If both ends write one bucket, two values for
  one key swap across the link without end. The agent refuses to start if a
  bucket appears in both directions.
- **You cannot narrow a mirror's `keys:` later.** `nats-server` rejects the
  change, so you would delete and recreate the bucket on every gateway. Scope it
  before rollout.
- **For any bucket but the two presets, the hub side must already exist.** The
  agent creates only the local side. The Control Plane cannot create it either,
  because it holds the NATS Operator and no credential inside an organization's
  account ([Health & Metrics §1](./health-metrics.md#1-why-this-exists-at-all)).
  Create it with a *user* credential: the console, or `stone kv bucket create`.
  Until it exists, the agent's `sync` readiness check warns.

Why desired state is a mirror and reported state a relay, the relay's retry
and delete handling, and the sync metrics are in
[Agent: leaf node §4](./vendor/agent/docs/leaf-node.md#4-kv-sync).

::: note `hub_domain` is cached
Edge sync needs the hub's JetStream domain. The agent caches it in its platform
session file. If you change the hub's JetStream domain, each running agent must
run `agent -leaf-config` again. That change also invalidates every generated
`nats-leaf.conf`, so the console cannot push it.
:::

---

## 7. Is the gateway up?

Ask NATS. No field or screen answers this for you. Build the question as a
[dashboard widget](./dashboards.md).

The platform keeps **no status field** for a gateway and does not watch its
heartbeat. The Agent does publish one (`{prefix}.{code}.heartbeat`, see
[Agent](./agent.md)), and the [Watchdog](./vendor/services/docs/watchdog.md)
service can alert when it stops. A heartbeat travels over the same link whose
failure it reports, though, so a missing beat cannot tell "edge box down" from
"WAN down" from "agent crashed". The Control Plane also cannot read tenant data
(§2).

The hub always knows which leaf connections it holds, so ask the hub, over the
browser's own NATS connection in the account. Use a **Button** or **Publisher**
widget to send a request to

```
$SYS.REQ.ACCOUNT.PING.CONNZ
```

with `{}` as the payload. It returns the account's current connection list.
Match entries with `kind: "Leafnode"` by `name`, which is the leaf's
`server_name` and so the Thing's `code` (§3). You can then name each gateway.

**Each account has its own `$SYS` subject space.** `$SYS.REQ.ACCOUNT.PING.*` is
scoped to the caller's account and answers for that organization only. A tenant
credential cannot reach the operator-wide `$SYS.REQ.SERVER.PING.*` endpoints,
which would cover every tenant. The server enforces both, and a platform test
checks both against a real hub with a real leaf.

::: warning Do not put `$SYS` in a publish deny list
The widget's NATS role needs `$SYS.REQ.ACCOUNT.PING.>` in its **publish allow**
list. The `console-readonly` role from the demo seed has it. In a normal
deployment, add it to the role you write yourself.

Do not add a deny next to it. In NATS, a publish DENY wins over a publish ALLOW.
A role with `$SYS.>` in its deny list cannot reach the account-scoped endpoints,
whatever its allow list says. If the request times out for one organization and
not another, this is the likely cause. You see only a timeout, because the real
error arrives on the connection's error handler, not on the request.

**Narrowing the deny to `$SYS.REQ.SERVER.>` does not help either.** The
operator-wide endpoints are served *inside the `$SYS` account*, and an account
is a closed subject namespace. A tenant credential that publishes
`$SYS.REQ.SERVER.PING.LEAFZ` reaches no responder, with or without a deny. The
account boundary already blocks it, so the platform ships no `$SYS` deny.
:::

### Why this is a widget and not a screen

No field marks which Things are gateways (§1), so a status badge on every
Thing's detail view could not tell which Things to show it for. It would show on
every device, including a temperature probe that never has a leaf node, and it
would poll the account's whole connection list for every viewer.

A widget asks only when someone wants to know. The same widget can also ask
`SUBSZ` or `JSZ` for other answers, with no platform change.

### Which Agents are running

CONNZ tells you that a gateway's leaf is connected. To find the Agents themselves,
use service discovery: `$SRV.PING.stone-agent` gets an answer from every Agent
in the organization ([The Agent §3E](./agent.md#e-service-discovery)).

An Agent behind a leaf answers a request from the hub only if **two**
credentials allow `$SRV.>` on subscribe: the Agent's own, and the leaf's uplink
credential. The leaf connection filters `$SRV` like any other subject. On a
gateway that runs its own leaf, both are the same Thing's credential, and the
demo seed's `gateway` role allows `$SRV.>`. It does not allow the default
`agents.>` prefix, so see [The Agent §3](./agent.md#3-capabilities) for
the heartbeat and command subjects. A platform test checks this against a real
hub with a real leaf.

### Per-gateway health, in detail

CONNZ tells you whether the gateway's leaf is connected to the hub. For the rest
(is JetStream filling the disk, how many devices are connected, is the uplink
down), the agent serves `/ready` and `/metrics` **on the box**, at
`observability.addr`. These keep answering when the WAN is down, which is when
you need them. See [Health & Metrics](./health-metrics.md).

**A cut-off gateway warns. It does not fail.** `hub_uplink` is a warning, and the
endpoint still returns 200. Local NATS and devices keep working, which is the
reason a leaf node exists.

---

## 8. Security model

- **The edge box is the trust boundary.** Tenant isolation is the NATS
  *account* boundary, which a gateway cannot cross. Each gateway has one NATS
  identity, shared by the leaf remote, the rule engine and the agent.
- The gateway holds **public trust material** (Operator JWT, account JWT, `$SYS`
  account JWT) and its own user's creds. It **cannot create account users**.
- **To take a gateway out of service, clear `active` on its Thing** (Owner/Admin
  only). A gateway is a Thing, so the four effects in
  [Authorization §4.2](./authorization.md#42-taking-a-device-out-of-service)
  apply to it.

  For a gateway, the config pull, the leaf remote connection and the overlay
  all stop. Local traffic on the site continues, because the leaf checks
  credentials against its own copy of the account JWT (§8.1), which the Agent
  can no longer refresh.

  To bring a gateway back, reactivate its Thing (see
  [The Agent §2.1](./agent.md#21-removing-the-password) if you removed its
  password). At its next start the Agent writes the new creds to the file the
  leaf config uses; then restart the leaf server, or the agent if it hosts the
  leaf, so the leaf remote reconnects.
- **Deactivate, do not delete.** To revoke a Nebula certificate, the platform
  publishes its fingerprint, so the certificate must still be in the database. A
  deleted record stays trusted until the certificate expires.
- An org Admin or Owner can reset the Thing's PocketBase password on its **edit
  form** (Authentication card). The collection's `manageRule` allows this. It is
  a scoped, audited record action, not a superuser task.
- To reduce what a gateway can reach, edit its records: assign another NATS role, or
  add per-user permission overrides. Only **Owners and Admins** can, because
  these write to `nats_users` and `nats_roles`.

::: warning `active` and a connected leaf answer different questions
A CONNZ reply (§7) says whether the gateway **is** connected to the hub.
`active` says whether it **may** be. A deactivated gateway missing from the list
is expected. An *active* gateway missing from the list needs investigation.
:::

### 8.1 What reaches a site, and when

The hub and a site's leaf node do not apply these changes at the same time.

| Action | At the hub | Devices behind a gateway |
| :--- | :--- | :--- |
| Revoke or suspend a NATS identity, including by deactivating a Thing | At once | At the next leaf refresh: at most `platform.leaf_refresh_interval` (5 minutes by default), or at once with `cmd.leaf_refresh` |
| Deactivate the gateway's own Thing | At once: the hub refuses the leaf's uplink | The site is cut off from the hub. Local traffic continues. |
| Suspend the organization | At once: every hub connection drops, including the gateway's uplink | Not applied. Local devices keep working on the site's leaf. |
| Blocklist a Nebula host | — | As each peer pulls its config (`nebula.sync_interval`) |
| End a Thing's platform session | At once | At once |

The leaf runs `resolver: MEMORY`, so it checks each credential against its own
copy of the account JWT (§4). A revocation reaches the leaf only when the Agent
refreshes that copy (§5). On Windows, a separately supervised leaf loads the new
copy only when you restart it. A suspension never reaches the leaf, because
`GET /api/me/leaf-config` serves the account JWT whether or not the organization
is active. The Agent's `leaf_preload` readiness check warns when the leaf's
loaded account JWT differs from the latest one.

---

## 9. Where to Go Next

- The leaf node transport: [Connectivity §1](./connectivity.md#leaf-nodes)
- The agent: [The Agent](./agent.md)
- Subjects that a site's devices publish on: [Thing Types](./thing-types.md)
- Site-local rules during outages: [Automation](./automation.md)
- What an edge identity can read, and who manages it: [Authorization & Roles](./authorization.md)
- `leaf-config` with every other platform route: [API Reference](./api-reference.md)
- Per-gateway health endpoints: [Health & Metrics](./health-metrics.md)
- How the planes fit together: [Architecture](./architecture.md) and [Platform Layers](./platform-layers.md)
