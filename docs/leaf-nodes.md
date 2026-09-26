# Leaf Nodes

A site that runs its own local NATS server keeps working when the WAN does not. The transport underneath is a stock NATS leaf node ([Connectivity §1](./connectivity.md#leaf-nodes)) — it dials the hub outbound and gives the site local autonomy during an outage.

**The platform models that site as a Thing.** Not a special record type, not a separate collection: an ordinary Thing whose [Agent](./agent.md) happens to have its leaf-node capabilities turned on. One inventory, one identity model, one set of API rules.

> ## "Leaf node" means two related things — keep them straight
>    | Term | What it is |
>    | :--- | :--- |
>    | **NATS leaf node** | The stock `nats-server` running at the site in leaf mode, dialing the hub outbound. A Layer 0 transport primitive — see [Connectivity](./connectivity.md#leaf-nodes). |
>    | **A gateway** | The *platform's* model of such a site: an ordinary **Thing**, with one NATS identity and optionally a Nebula host. Nothing in the schema marks it as a gateway — see §1. This page is about how one gets configured and how you tell whether it is up. |
>    | **The [Agent](./agent.md)** | The binary on the box. It manages the device *and*, when configured to, bootstraps and hosts the leaf node. One agent, not two. |

---

## 1. There is no gateway flag

This is the design decision the rest of the page follows from, so it is worth stating plainly: **nothing on the platform marks a Thing as a gateway.**

A `leaf_nodes` collection used to exist — "a special Thing" with its own `domain` column, its own sync allowlist, and its own screens. It was removed, for three separate reasons that happened to arrive together:

- **A marker no code consulted is a marker that drifts.** Nothing in the platform branched on it: the config route serves any authenticated Thing (§3), and the agent stands up a leaf because *its own* config says to, not because a record said so.
- **The `domain` column was a second copy of the code.** It could drift from the code it was derived from, and when it did, the symptom was a site that silently stopped appearing rather than an error.
- **Nothing consumed the mirrored config.** The old agent copied an organization's `things`, `locations` and type collections into the edge's local KV so devices could read them offline — but no rule, no firmware and no tool ever read those rows. It was the reason an edge identity needed read grants spread across the inventory, and it bought nothing.

**Nor does a Thing Type say "gateway".** This is worth stating separately, because the opposite was written down here and a console feature was built on the strength of it (§7). A `thing_types` record carries `name`, `description`, `code`, `subject_prefix`, `operations` and `metadata_schema` — and no gateway flag. An organization naming one of its types "Gateway" is a convention *it* chose; the platform cannot read that name and conclude anything. So there is no field to gate on, no field to filter a list by, and no field that tells a screen which Things ought to have a leaf node attached.

What is left is one route. Everything an agent needs to stand up a leaf server comes from `GET /api/me/leaf-config`, and **that route gates on nothing** — see §3.

---

## 2. Why the edge pulls, rather than the hub pushing

The Control Plane is the **NATS Operator** and only ever touches the **SYSTEM account**. It deliberately has no presence inside any tenant's account data plane (see [Architecture §2](./architecture.md#key-properties-of-this-topology)), so it *cannot* push anything into an organization's buckets, and it cannot read anything out of them either.

So the site pulls, authenticated as itself. Live data — digital twin state, telemetry — replicates separately via cross-domain JetStream mirror and relay, configured by the account's own users. That split is what §5 and §6 are about.

---

## 3. `GET /api/me/leaf-config`

Bound to the `things` collection, taking **no record id**: the target is the caller's own authenticated record, exactly like `POST /api/me/nats-creds/rotate`. It returns ten named fields:

| Field | What it is |
| :--- | :--- |
| `code` | The Thing's code |
| `domain` | The leaf's JetStream domain — **the same string as `code`** |
| `creds` | This Thing's own NATS credential |
| `account_jwt`, `account_pub` | The organization's NATS account |
| `operator_jwt` | The NATS Operator |
| `sys_account_jwt`, `sys_account_pub` | The `$SYS` account (see §4) |
| `hub_leaf_url` | Where the leaf remote dials the hub |
| `hub_domain` | The hub's own JetStream domain |

**There is deliberately no marker, flag or capability check on it.** Everything served is either public trust material — the Operator, account and `$SYS` account JWTs, which every server in the network validates anyway — or the caller's own credential, which it must already hold in order to connect at all. A Thing that will never run a leaf node can call this route and learns nothing it could not already read. A gate would have been a permission over data that is not secret, and it would have needed a marker field to gate on.

What is *not* served: account **seeds**, signing keys, and any `$SYS` **user** credential. The `nats_system_operator` collection stays superuser-only, and a gateway reads nothing in any `nats_*` or `nebula_*` collection beyond its own linked NATS identity and Nebula host — and no inventory collection at all, not even the other Things in its organization. The blast radius of a leaked edge credential is those ten values plus that Thing's own access — a fixed list, not a consequence of how those collections' rules later evolve.

### The domain is the code, computed and never stored

The platform derives `domain` from `code` at request time. The agent writes it into **both** `server_name` and `jetstream { domain }` in the generated config, and a site-status widget matches a leaf's reported `server_name` back to a Thing's `code` to name the site it found (§7) — so those two must not diverge, and the surest way to guarantee that is to have only one of them.

There is no `edge-` prefix and no organization segment in it either. JetStream is already scoped to the account, so the account *is* the namespace; a prefix would be decoration that every consumer then has to strip.

---

## 4. Two directives that are not optional

A generated `nats-leaf.conf` has to satisfy NATS operator-mode validation, and **no string assertion can check that**. Both of the following were missing for months, so the generator produced a file `nats-server` refused to load — invisible, because the only tests were substring checks over the output.

1. **Every leaf remote needs an `account` key** naming the local account.
2. **`resolver_preload` needs the `$SYS` account JWT**, not just the organization's. The Operator JWT names a system account, and `resolver: MEMORY` has nowhere to fetch it — so without it the server dies with `error resolving system account: account missing`, *before JetStream ever starts*.

!!! note "Preloading the `$SYS` **account** JWT grants nothing"
    It is public trust material, like the Operator JWT beside it. Connecting *as* `$SYS` requires a `$SYS` **user** credential, which the platform never serves to anything. Those are different objects, and it is worth being precise about which one is which, because the first looks alarming and is not.

The generator lives in the Agent, not the platform (`internal/edge/leafconf.go` in the agent repository), and it now runs its own output through the real `nats-server` config parser in a test (`TestBuildLeafConfIsAcceptedByNATSServer`). The platform's side of the contract is the ten field names, which it pins separately. Keep that shape if you touch either — substring checks cannot express "and the server accepts it".

---

## 5. Deploy flow

1. In the console, create the site's **Thing** — any Thing Type your organization uses for sites; nothing on the platform needs to know it is a gateway (§1). Copy the login email and password from the success dialog — the password is shown once.
2. Install the [Agent](./agent.md) on the edge box and configure the platform block:

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

    Two startup checks catch people here. `tasks.service_check` is on by default and the config is refused if it lists no services — turn it off, as above, or list the site's services. And `commands.scripts_directory` defaults to `/opt/agent/scripts`, which must exist; the install steps in [The Agent §1](./agent.md#getting-the-binary) create it.

3. `agent -leaf-config` → writes `nats-leaf.conf` (0644) and the creds (0600) beside each other.
4. Start the leaf, either way:
    - **Two processes (default):** `nats-server -c /etc/agent/nats-leaf.conf` under systemd or Docker. The bus then survives an agent restart, which is what you want when upgrading the agent on a live site.
    - **One process:** set `nats.server_config` to that path and the agent hosts the server itself. `nats.urls` must name the port the config listens on; startup refuses the pair if they disagree.
5. `agent -service install && agent -service start`.
6. Point any site-local [rule engine](./automation.md) at the same creds file.

!!! note "Bootstrapping and running cannot be one invocation"
    `-leaf-config` is a one-shot for a structural reason, not a stylistic one. A separately supervised `nats-server` needs its config file to exist *before* it starts — which is before the agent has anything to connect to.

---

## 6. Offline autonomy and KV bucket sync

Once the leaf is up, the rest of the layered platform runs at the edge without the hub: a [rule engine](./automation.md) keeps evaluating site-local reflexes, a [stream processor](./stream-processing.md) keeps producing aggregates, and devices keep publishing to the local leaf, where local subscribers keep receiving.

**What the leaf does not do is store and forward on its own.** A core NATS message published while the uplink is down reaches the site's subscribers and nobody at the hub, ever — interest re-propagates when the link returns, but nothing replays what was missed. The only data that crosses back is data something *stored*: a declared KV bucket the Agent relays (below), or a JetStream stream at the leaf that a hub-side stream sources from. The Agent creates neither kind of stream for you; a site that must not lose telemetry through an outage needs that stream declared deliberately.

The `sync:` block keeps **KV buckets** in step across the link, so the site keeps deciding locally through a WAN outage. Two directions, two mechanisms, a list each:

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

`sync.twin: true` is the preset for the digital twin, and it expands to exactly the two buckets this section has always described:

| Bucket | Written by | Flows | Mechanism |
| :--- | :--- | :--- | :--- |
| `twin` | the device, at the edge | edge → hub | relay |
| `twin_desired` | people and rules, at the hub | hub → edge | JetStream **mirror** |

Everything below holds for the twin, and now also for any bucket a site declares.

**One writer per bucket is the whole safety property.** A single bucket written from both ends does not pick a loser on a conflict — it *oscillates*: two concurrent values for one key swap across the link, then swap back, each write generating the next event. Measured at roughly 170,000 writes to a single key in 300 ms before the buckets were split. Encoding the owner in the key (`thing.S01.state.temp`) buys the same safety but taxes every key in firmware, rule configs and widgets, and a mistyped segment silently never syncs.

That used to be *structural* — two buckets, opposite directions, nothing else expressible. With a list it is one typo away, so the agent **refuses to start** when a bucket appears in both directions, and names it.

Desired state is a **mirror** because it has exactly one origin, and the edge never writes it — so reads are served locally from last-known values, which is precisely what you want when the link is down. Reported state needs the **relay** because aggregating N sites natively would need N sources all named `KV_twin`, which the client library cannot express; the alternative is a differently-named bucket at every site, which pushes the problem into every rule that reads one.

Off by default, because it moves data-plane traffic and an upgrade must not silently start doing that.

### 6.1 Three things to know before you declare a bucket

- **`keys:` is a KV key pattern in both directions** — `line-a.>`, never `$KV.recipes.line-a.>`. The agent builds the `$KV.<bucket>.` prefix itself for a mirror's subject filter, so a `$KV.` you write is rejected rather than silently doubled.

- **A mirror's filter cannot be narrowed later.** `nats-server` rejects any change to a mirror block on an existing stream, so changing `keys:` on a mirror means deleting and recreating that bucket *at every site*. Scope it before you roll it out; the agent reports a mismatch rather than pretending it can repair one.

- **Only the two preset buckets get created at the hub.** The agent creates the local side of any declared bucket and the hub side of none but `twin` and `twin_desired`. A typo that makes a stray local bucket is one site's problem; one that makes a stray hub bucket is everyone's, with whatever retention that site guessed. For any other bucket the hub side must already exist — and the Control Plane cannot make it either, holding the NATS Operator and no credential inside an organization's account ([Health & Metrics §1](./health-metrics.md#1-why-this-exists-at-all)). Something holding a *user* credential has to: the console, or `stone kv bucket create`.

A declared bucket whose hub side is missing is reported, not created: `agent_edge_sync_up{bucket,direction}` goes to `0` and the agent's `sync` readiness check warns. It **warns** rather than fails, because an islanded edge with a backlog is the design working — `agent_edge_relay_pending{bucket}` is the depth to watch.

!!! note "`hub_domain` is cached, so moving it is not a change the console can push"
    Edge sync needs the hub's JetStream domain, and the agent caches it in its platform session file rather than re-reading it. A deployment that moves its hub's JetStream domain does not reach running agents until each one re-runs `agent -leaf-config` — which is defensible, since such a move invalidates every generated `nats-leaf.conf` anyway, but it is not a console action.

---

## 7. Is the site up?

Ask NATS. There is no field to read and no screen that answers it for you — you build the question as a [dashboard widget](./dashboards.md).

There is **no heartbeat and no status field**, and there used to be both. A `leaf_status` KV bucket carried a beat per site and the console rendered it as online/offline. It was removed because a heartbeat travels over the very link whose failure it is meant to report: a missing beat cannot distinguish "edge box down" from "WAN down" from "agent crashed" — three different call-outs behind one red dot. And the Control Plane could never have read one anyway (§2).

The hub, on the other hand, always knows which leaf connections it is holding. So ask it, over the browser's own in-account NATS connection. A **Button** or **Publisher** widget doing request/reply against

```
$SYS.REQ.ACCOUNT.PING.CONNZ
```

with `{}` as the payload returns the account's current connection list. Entries with `kind: "Leafnode"` are matched by `name` — the leaf's `server_name`, which is the Thing's `code` (§3) — so a site is identifiable, not merely countable.

**Each account carries its own `$SYS` subject space.** `$SYS.REQ.ACCOUNT.PING.*` is scoped to the caller's own account and answers for that organization and no other; the operator-wide `$SYS.REQ.SERVER.PING.*` endpoints, which would span every tenant, are not reachable from a tenant credential. The server enforces both halves, and the platform pins them in a test against a real hub with a real leaf attached.

!!! warning "Do not put `$SYS` in a publish deny list"
    The widget needs `$SYS.REQ.ACCOUNT.PING.>` in its NATS Role's **publish allow** list. The `console-readonly` role the demo seed creates carries it; nothing seeds that role in an ordinary deployment, so a role you author yourself needs the entry added. Do not add a deny beside it. In NATS a publish DENY beats a publish ALLOW, so a role carrying `$SYS.>` in its deny list cannot reach the account-scoped endpoints no matter what its allow list says — and if the request ever times out for one organization and not another, this is almost certainly why. The symptom is a bare timeout, because the real reason arrives asynchronously on the connection's error handler and never on the request itself.

    **Narrowing the deny to `$SYS.REQ.SERVER.>` is not a fix either**, only a quieter one. It looks like it restricts the operator-wide endpoints, but those are served *inside the `$SYS` account*, and an account is a closed subject namespace — a tenant credential publishing `$SYS.REQ.SERVER.PING.LEAFZ` reaches no responder with or without a deny. The account boundary already enforces it, so the platform ships no `$SYS` deny at all, and pins both halves against a real server.

### Why this is a recipe and not a screen

A connectivity badge on every Thing's detail view was built, and then removed. It failed on §1: nothing marks which Things are gateways, so it could not be gated. It rendered on every device, which meant it had to state "no leaf node attached" in neutral colour about a temperature probe that would never have one — and to do that it polled the whole account's connection list every 15 seconds, for every viewer, whether or not anyone was asking.

A widget asks once, when someone wants to know. It also generalises for free: the same widget aimed at `SUBSZ` or `JSZ` answers a different question without waiting on a platform release.

### Per-site health, in detail

CONNZ answers one question — is this site's leaf attached to the hub. For the rest — is JetStream filling the disk, how many devices are actually attached, is the uplink down — the agent serves `/ready` and `/metrics` **on the box**, behind `observability.addr`. That is where per-site health can actually be measured, and it keeps answering with the WAN down, which is exactly when you want it. See [Health & Metrics](./health-metrics.md).

**An islanded site warns; it does not fail.** `hub_uplink` is a warning and still answers 200. Local NATS keeps working and devices keep running — that autonomy is the entire reason a leaf node exists, so reporting it as unready would invert the design.

---

## 8. Security model

- **The edge box is the trust boundary.** Tenant isolation is the NATS *account* boundary, which a site cannot cross. One NATS identity per gateway, shared by the leaf remote, the rule engine, and the agent.
- The site holds **public trust material** (Operator JWT, account JWT, `$SYS` account JWT) plus its own user's creds. It **cannot mint new account users**.
- **Taking a site out of service is `active` on its Thing**, Owner/Admin only. Clearing it does four things at once: the agent can no longer authenticate, the session token it already holds is invalidated immediately, the site's NATS credential is suspended (revoked, with nothing reissued), and its Nebula host is deactivated, which blocklists the certificate across the CA once peer configs are redeployed. So the config pull, the leaf remote connection and the overlay all stop. It sets `active`, never `revoke` — revoke would hand back a working replacement.

    Reactivating issues a **new** NATS credential; the previous `.creds` stays revoked permanently. Getting it onto the box takes a platform session, and that died with the deactivation — so if the password was removed from the service environment, set a new one first (see [The Agent §2.2](./agent.md#22-removing-the-password)). The Agent's credential sync on its next start then writes the new creds to the same file the leaf config points at; restart the leaf server (or the agent, if it hosts it) so the leaf remote reconnects with them. Re-running `agent -leaf-config` does the same write and also needs that session. See [Authorization §4.2](./authorization.md#42-taking-a-device-out-of-service).
- **Deactivate, do not delete.** Revoking a Nebula certificate requires the certificate to still be in the database so its fingerprint can be published; deleting the record leaves it trusted until it expires.
- The Thing's PocketBase password can be reset by an org Admin/Owner on the Thing's **edit form** (the Authentication card, where they type a new one), gated by the collection's `manageRule` — a scoped, audited record action rather than a superuser-only operation.
- Narrowing a site's blast radius is a record edit: reassign its NATS Role or add per-user permission overrides. Both are **Owner/Admin** actions, since they write to `nats_users` and `nats_roles`.

!!! warning "`active` and an attached leaf answer different questions"
    A CONNZ reply (§7) reports whether the site **is** currently attached to the hub. `active` governs whether it **may** be. A deactivated site missing from that list is the expected outcome, not a fault to chase — and an *active* site missing from it is the one worth investigating.

---

## 9. Where to Go Next

- **The leaf node transport primitive:** [Connectivity §1 — Leaf Nodes](./connectivity.md#leaf-nodes).
- **The agent that does all of this:** [The Agent](./agent.md).
- **The contract graph a site's devices publish against:** [Thing Types](./thing-types.md).
- **Site-local rules during outages:** [Automation](./automation.md).
- **What an edge identity may read, and who may manage it:** [Authorization & Roles](./authorization.md).
- **`leaf-config` beside every other platform route:** [API Reference](./api-reference.md).
- **Per-site health endpoints:** [Health & Metrics](./health-metrics.md).
- **How the planes fit together:** [Architecture](./architecture.md) and [Platform Layers](./platform-layers.md).
