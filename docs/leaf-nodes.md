---
path: platform/leaf-nodes
nav_order: 140
---
# Leaf Nodes

A site with its own local NATS server keeps working when the WAN fails. The
transport is a stock NATS leaf node ([Connectivity §1](./connectivity.md#leaf-nodes)).
It connects outbound to the hub and keeps the site running during an outage.

**The platform models the site as an ordinary Thing.** Its
[Agent](./agent.md) has its leaf-node capabilities turned on. There is no
special record type or collection, so sites use the same inventory, identity
model and API rules as everything else.

> ## Three related terms
>    | Term | What it is |
>    | :--- | :--- |
>    | **NATS leaf node** | The stock `nats-server` at the site in leaf mode, connected outbound to the hub. A Layer 0 transport. See [Connectivity](./connectivity.md#leaf-nodes). |
>    | **A gateway** | The *platform's* model of the site: an ordinary **Thing**, with one NATS identity and optionally a Nebula host. Nothing in the schema marks it as a gateway (§1). This page covers how you configure one and how you check that it is up. |
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
`name`, `description`, `code`, `subject_prefix`, `operations` and
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

So the site pulls its config, signed in as itself. Live data (twin state,
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
A site-status widget matches a leaf's `server_name` to a Thing's `code` to name
the site (§7). So the two must always match, and the simplest way is to have
only one of them.

There is no `edge-` prefix and no organization token in it. JetStream is already
scoped to the account, so a prefix would only be something for every consumer to
remove.

---

## 4. Two required directives

A generated `nats-leaf.conf` must pass NATS operator-mode validation:

1. **Every leaf remote needs an `account` key** that names the local account.
2. **`resolver_preload` needs the `$SYS` account JWT**, not only the
   organization's. The Operator JWT names a system account, and
   `resolver: MEMORY` cannot fetch it. Without it the server stops with
   `error resolving system account: account missing`, *before JetStream starts*.

::: note Preloading the `$SYS` **account** JWT grants nothing
It is public trust material, like the Operator JWT. To connect *as* `$SYS`, you
need a `$SYS` **user** credential, and the platform never serves one.
:::

The generator is in the Agent (`internal/edge/leafconf.go` in the agent
repository). A test (`TestBuildLeafConfIsAcceptedByNATSServer`) runs its output
through the real `nats-server` config parser. A substring check cannot prove
that the server accepts a file. The platform tests its side of the contract,
the ten field names, separately. Keep both tests if you change either side.

---

## 5. Deploy flow

1. In the console, create the site's **Thing**, with any Thing Type your
   organization uses for sites (§1). Copy the login email and password from the
   success dialog. The password is shown only once.
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
    above, or list the site's services. `commands.scripts_directory` defaults to
    `/opt/agent/scripts`, which must exist. The install steps in
    [The Agent §1](./agent.md#getting-the-binary) create it.

3. Run `agent -leaf-config`. It writes `nats-leaf.conf` (0644) and the creds
   (0600) in the same directory.
4. Start the leaf in one of two ways:
    - **Two processes (default):** run `nats-server -c /etc/agent/nats-leaf.conf`
      under systemd or Docker. The bus then stays up when the agent restarts,
      which matters when you upgrade the agent on a live site.
    - **One process:** set `nats.server_config` to that path, and the agent
      hosts the server. `nats.urls` must name the port in that config. The agent
      refuses to start if they differ.
5. Run `agent -service install && agent -service start`.
6. Point any site-local [rule engine](./automation.md) at the same creds file.

::: note Bootstrapping and running are two separate commands
A separately supervised `nats-server` needs its config file *before* it starts,
which is before the agent has a server to connect to. So `-leaf-config` runs
once, on its own.
:::

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

The rules below apply to the twin and to every bucket a site declares.

**One writer per bucket is what keeps the data safe.** If both ends write one
bucket, a conflict has no winner. Two values for one key swap across the link,
then swap back, and each write causes the next one, with no end. You could put
the owner in the key (`thing.S01.state.temp`) instead, but then every key in
firmware, rules and widgets needs it, and a mistyped token never syncs, with no
error.

The agent **refuses to start** if a bucket appears in both directions, and
names the bucket.

Desired state is a **mirror** because it has one origin, and the edge never
writes it. The edge reads the last known values locally, which is what you
need when the link is down. Reported state needs a **relay**. To combine N sites
with native sourcing, you would need N sources all named `KV_twin`, which the
client library cannot express. The other choice, a different bucket name at
each site, would push the problem into every rule that reads one.

Sync is off by default, because it adds Data Plane traffic, and an upgrade must
not start that silently.

### 6.1 Three things to know before you declare a bucket

- **`keys:` is a KV key pattern in both directions**: `line-a.>`, never
  `$KV.recipes.line-a.>`. The agent adds the `$KV.<bucket>.` prefix to a
  mirror's subject filter, and rejects a `$KV.` that you write.

- **You cannot narrow a mirror's filter later.** `nats-server` rejects any change
  to a mirror block on an existing stream. To change `keys:` on a mirror, delete
  and recreate that bucket *at every site*. Scope it before rollout. The agent
  reports a mismatch but cannot repair it.

- **The agent creates hub-side buckets only for the two presets.** It creates
  the local side of any declared bucket, but the hub side only of `twin` and
  `twin_desired`. A typo that creates a stray local bucket affects one site. A
  stray hub bucket would affect everyone, with retention one site guessed. For
  any other bucket, the hub side must already exist. The Control Plane cannot
  create it, because it holds the NATS Operator and no credential inside an
  organization's account
  ([Health & Metrics §1](./health-metrics.md#1-why-this-exists-at-all)). A
  holder of a *user* credential must create it: the console, or
  `stone kv bucket create`.

If a declared bucket has no hub side, the agent reports it and does not create
it. `agent_edge_sync_up{bucket,direction}` goes to `0`, and the agent's `sync`
readiness check warns. It **warns**, not fails, because a cut-off edge with a
backlog is working as designed. Watch `agent_edge_relay_pending{bucket}` for the
backlog depth.

::: note `hub_domain` is cached
Edge sync needs the hub's JetStream domain. The agent caches it in its platform
session file. If you change the hub's JetStream domain, each running agent must
run `agent -leaf-config` again. That change also invalidates every generated
`nats-leaf.conf`, so the console cannot push it.
:::

---

## 7. Is the site up?

Ask NATS. No field or screen answers this for you. Build the question as a
[dashboard widget](./dashboards.md).

There is **no heartbeat and no status field** for a site. A heartbeat would
travel over the same link whose failure it reports, so a missing beat could not
tell "edge box down" from "WAN down" from "agent crashed". The Control Plane
also cannot read tenant data (§2).

The hub always knows which leaf connections it holds, so ask the hub, over the
browser's own NATS connection in the account. Use a **Button** or **Publisher**
widget to send a request to

```
$SYS.REQ.ACCOUNT.PING.CONNZ
```

with `{}` as the payload. It returns the account's current connection list.
Match entries with `kind: "Leafnode"` by `name`, which is the leaf's
`server_name` and so the Thing's `code` (§3). You can then name each site.

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

CONNZ tells you that a site's leaf is connected. To find the Agents themselves,
use service discovery: `$SRV.PING.stone-agent` gets an answer from every Agent
in the organization ([The Agent §3E](./agent.md#e-service-discovery)).

An Agent behind a leaf answers a request from the hub only if **two**
credentials allow `$SRV.>` on subscribe: the Agent's own, and the leaf's uplink
credential. The leaf connection filters `$SRV` like any other subject. On a
gateway that runs its own leaf, both are the same Thing's credential, and the
demo seed's `gateway` role allows it. A platform test checks this against a real
hub with a real leaf.

### Per-site health, in detail

CONNZ tells you whether the site's leaf is connected to the hub. For the rest
(is JetStream filling the disk, how many devices are connected, is the uplink
down), the agent serves `/ready` and `/metrics` **on the box**, at
`observability.addr`. These keep answering when the WAN is down, which is when
you need them. See [Health & Metrics](./health-metrics.md).

**A cut-off site warns. It does not fail.** `hub_uplink` is a warning, and the
endpoint still returns 200. Local NATS and devices keep working, which is the
reason a leaf node exists.

---

## 8. Security model

- **The edge box is the trust boundary.** Tenant isolation is the NATS
  *account* boundary, which a site cannot cross. Each gateway has one NATS
  identity, shared by the leaf remote, the rule engine and the agent.
- The site holds **public trust material** (Operator JWT, account JWT, `$SYS`
  account JWT) and its own user's creds. It **cannot create account users**.
- **To take a site out of service, clear `active` on its Thing** (Owner/Admin
  only). This does four things at once:
  1. The agent can no longer sign in.
  2. Its current session token stops working immediately.
  3. The site's NATS credential is suspended (revoked, nothing reissued).
  4. Its Nebula host is deactivated, and the certificate is blocklisted across
     the CA when peer configs are redeployed.

  So the config pull, the leaf remote connection and the overlay all stop. It
  sets `active`, never `revoke`, because revoke returns a working replacement.

  Reactivating issues a **new** NATS credential. The old `.creds` stays revoked.
  The agent needs a platform session to fetch the new one, and deactivation
  ended that session. If you removed the password from the service environment,
  set a new one first (see [The Agent §2.2](./agent.md#22-removing-the-password)).
  At its next start, the Agent writes the new creds to the file the leaf config
  uses. Then restart the leaf server (or the agent, if it hosts the leaf) so the
  leaf remote reconnects. `agent -leaf-config` does the same write and also needs
  the session. See [Authorization §4.2](./authorization.md#42-taking-a-device-out-of-service).
- **Deactivate, do not delete.** To revoke a Nebula certificate, the platform
  publishes its fingerprint, so the certificate must still be in the database. A
  deleted record stays trusted until the certificate expires.
- An org Admin or Owner can reset the Thing's PocketBase password on its **edit
  form** (Authentication card). The collection's `manageRule` allows this. It is
  a scoped, audited record action, not a superuser task.
- To reduce what a site can reach, edit its records: assign another NATS role, or
  add per-user permission overrides. Only **Owners and Admins** can, because
  these write to `nats_users` and `nats_roles`.

::: warning `active` and a connected leaf answer different questions
A CONNZ reply (§7) says whether the site **is** connected to the hub. `active`
says whether it **may** be. A deactivated site missing from the list is
expected. An *active* site missing from the list needs investigation.
:::

---

## 9. Where to Go Next

- The leaf node transport: [Connectivity §1](./connectivity.md#leaf-nodes)
- The agent: [The Agent](./agent.md)
- Subjects that a site's devices publish on: [Thing Types](./thing-types.md)
- Site-local rules during outages: [Automation](./automation.md)
- What an edge identity can read, and who manages it: [Authorization & Roles](./authorization.md)
- `leaf-config` with every other platform route: [API Reference](./api-reference.md)
- Per-site health endpoints: [Health & Metrics](./health-metrics.md)
- How the planes fit together: [Architecture](./architecture.md) and [Platform Layers](./platform-layers.md)
