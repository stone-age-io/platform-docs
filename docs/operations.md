---
path: platform/operations
nav_order: 200
---
# Operations & Production

This page covers running Stone-Age.io in production: the state to protect, the
availability model, backup and recovery, upgrades, and component versions.

Operations follow the [plane split](./platform-layers.md#1-planes-and-layers).
The Data Plane gets high availability the NATS way: clustering at the hub and
[leaf-node autonomy](./leaf-nodes.md) at the edge. The Control Plane gets a
small SQLite file that is easy to back up, and a recovery time of minutes.

---

## 1. What You're Protecting

| State | Where it lives | Loss impact | Protected by |
| :--- | :--- | :--- | :--- |
| **Identity hierarchy**: NATS Operator key, NATS Accounts, Nebula CAs, user and Thing credentials | Control Plane (`pb_data`) | **Severe.** The NATS Operator key is the root of the chain of trust. Losing it orphans every Account and credential it signed. | This page (§3). |
| **Inventory and contracts**: Orgs, Things, Thing Types, Locations, schemas, related config | Control Plane (`pb_data`) | High, but you can enter it again, or restore it from a [GitOps workspace](./stone-cli.md#5-declarative-workspaces-pull-apply). | This page (§3), plus `stone pull` workspaces. |
| **Live state**: twin KV, other KV buckets, JetStream streams | NATS servers (JetStream storage) | Depends on the bucket. The reported twin (`twin`) fills again as devices report. The **desired** twin (`twin_desired`) does not: people wrote it, nothing recreates it, and losing it loses every setpoint. Other tenant buckets and their contents are also lost. Stream retention is a buffer, not an archive. | JetStream replicas (`replicas: 3` on clustered NATS), stream mirrors. |
| **Historical telemetry** | Your Layer 3 TSDB | Your choice: it is [your own](./observability.md). | Your TSDB's backup tools. |
| **Edge leaf config** | `nats-leaf.conf` and creds on the edge box | None. Regenerate it with `agent -leaf-config` ([Leaf Nodes](./leaf-nodes.md)). | Nothing needed. |

**`pb_data` is the most important state.** It is one directory: a SQLite
database, and `pb_data/storage`, which holds every uploaded file (Thing and
Location photos, floor plans, organization logos, avatars). Uploads grow with
the inventory and are in every backup. `stone_age_database_size_bytes` counts
only the database, so also watch the directory's disk use
([Health & Metrics §3](./health-metrics.md#3-get-metrics)).

> **Backups contain secrets.** A Control Plane backup has the NATS Operator key, every org's Nebula CA private key, and every issued `.creds` file and Nebula host config in plaintext. At-rest encryption covers the minting keys, not issued credentials ([Configuration §2.2](./configuration.md#22-the-encryption-keys)). Protect backups like the live database: restrict the S3 bucket, encrypt at rest, and do not leave copies on workstations. Use `--encryptionEnv` ([Configuration §4](./configuration.md#pocketbase-flags)) to encrypt app settings at rest.

---

## 2. The Availability Model

### Data Plane: highly available

The runtime path (telemetry, commands, rules, live dashboards) never depends on
one process:

- **NATS clusters horizontally.** With three or five `nats-server` nodes, the
  bus survives the loss of a node. Streams and KV buckets with `replicas: 3`
  keep their data. This is standard NATS operation. See the
  [NATS docs](https://docs.nats.io).
- **Leaf nodes keep sites running.** A WAN or hub outage does not stop
  site-local devices, rules or stream processors. KV buckets that a site syncs
  catch up when the link returns. Other messages published during the outage
  reach the hub only if a stream at the leaf stored them. See
  [Leaf Nodes](./leaf-nodes.md).
- **Rule engines and stream processors scale horizontally**, and their durable
  state is in replicated KV. What they hold in memory, such as rule-router's
  throttle windows, is per instance and lost on restart.

### Control Plane: fast recovery, not failover

The Control Plane is a low-traffic metadata store. An outage affects less than
you might expect:

| While the Control Plane is down... | Status |
| :--- | :--- |
| Device telemetry, commands, live dashboard data | ✅ Not affected (Data Plane only) |
| Layer 1 rules, Layer 2 processors, Layer 3 ingestion | ✅ Not affected |
| NATS and Nebula credentials already issued | ✅ Keep working. The cluster checks them, not PocketBase. |
| Console login, record management | ❌ Paused |
| Provisioning new Orgs, Things and credentials | ❌ Paused |
| Agent bootstrap and credential sync | ⏸️ Paused. The Agent retries, and a provisioned gateway keeps running on the credential and leaf config it has. |

None of the paused work is urgent. So the platform uses **frequent backups and
a short, practiced restore** (§3 and §4), not an HA database. With scheduled
backups, S3 copies and filesystem snapshots, recovery takes minutes, and the
outage pauses provisioning, not production traffic.

### 2.1 Where the NATS server runs

The table above assumes the Control Plane and `nats-server` run as separate
processes. `stone-age serve --nats` runs the NATS server inside the Control
Plane instead, from the same `nats.conf` that `nats export` writes
([Getting Started §3](./getting-started.md#3-start-the-nats-server)).

This is a valid production option, but it changes the first row of that table.
There are three options. You move between them by editing config, with two
exceptions: a server that already holds JetStream data loses it when it first
joins a cluster, and removing the embedded node from a cluster takes several
steps ([§5.5](#55-moving-the-nats-server-out-of-the-control-plane)).

| | What runs | A Control Plane restart costs | Use when |
| :--- | :--- | :--- | :--- |
| **1. Embedded** | One process | A short outage of the whole bus | Small installs, where a short gap during an upgrade is acceptable |
| **2. Embedded + external** | Control Plane and one `nats-server`, clustered | Devices reconnect, the bus stays up | Upgrade gaps start to matter |
| **3. Fully external** | Control Plane and a NATS cluster | Nothing | HA, or scaling the bus separately |

In option 1, **the Data Plane depends on the Control Plane**: restarting
`stone-age` restarts the bus. For this reason `--nats` is off by default.

Option 2 removes that dependency for planned work. With a two-node cluster and
the embedded node stopped:

| | |
| :--- | :--- |
| Core NATS pub/sub, device connections | Keep working |
| JetStream KV reads and writes (R1) | Keep working |
| JetStream **management**: create or delete a stream, consumer or bucket | **Stops** until the node returns |

With two nodes, the RAFT quorum is two, so with one node down the JetStream
meta group has no leader. You cannot create or change streams and buckets. That
is Control Plane work, and the Control Plane is down anyway. Telemetry keeps
flowing.

> **Two nodes is not high availability.** It covers *planned* upgrades only. In option 2, losing the external node is worse than option 1. Real fault tolerance needs three voting nodes (option 3).

> **Devices must know both URLs.** A device with only the embedded node's URL still disconnects when that node restarts.

Two moves are not only additive: a server with data that joins a cluster, and
the embedded node leaving one
([§5.5](#55-moving-the-nats-server-out-of-the-control-plane)). The reasons are in
[ADR 0001](./decisions/0001-embedded-nats-server.md).

---

## 3. Backups

Use these together: **native scheduled backups** as the authoritative copy,
**S3** for offsite, **`pb` (pb-cli)** for scripts and rehearsals, and **ZFS
snapshots** for fast local rollback.

### 3.1 Native scheduled backups

PocketBase, and so the platform binary, has built-in backups. A backup is a
consistent zip of the whole `pb_data` directory, taken safely while the server
runs.

Configure it as the SuperUser in the admin UI (`/_/` → **Settings →
Backups**):

- **Schedule:** a cron expression, for example `0 2 * * *` for 02:00 every
  night.
- **Max kept:** how many backups to keep before the oldest is deleted.
- **Storage:** local disk by default, or an **S3-compatible bucket** (endpoint,
  bucket, region, credentials). With S3, every scheduled backup goes offsite
  automatically.

This gives you nightly, consistent, offsite backups with automatic pruning.

### 3.2 Scripted backups with pb-cli

[`pb-cli`](https://github.com/skeeeon/pb-cli) (`pb`) is a general PocketBase
CLI that uses the same backup API from scripts. Use it for pre-upgrade backups,
extra offsite copies and restore rehearsals. Backup operations need SuperUser
auth.

```sh
# One-time setup
pb context create prod --url https://platform.acme.io
pb auth --collection _superusers

# On-demand, e.g. from cron or a pre-upgrade hook
pb backup create --name "pre-upgrade-$(date +%Y%m%d-%H%M)"

# Pull a copy off the platform host entirely
pb backup download "pre-upgrade-20260610-0900" /mnt/backup-vault/

# Prune: keep the five newest, delete the rest (careful!)
pb backup list --output json \
  | jq -r 'sort_by(.modified) | reverse | .[5:] | .[].key' \
  | xargs -I {} pb backup delete {} --force
```

`pb` also moves backups *between* environments (`backup upload` and
`backup restore`). Use this to rehearse recovery and test upgrades on real data
(§5.3).

### 3.3 Filesystem snapshots (ZFS)

Put `pb_data` on its own **ZFS dataset** with automatic snapshots (sanoid,
zfs-auto-snapshot or your distribution's equivalent):

```sh
zfs create tank/stone-age
# point the binary at it: ./stone-age serve --dir /tank/stone-age/pb_data
```

- **Cheap and fast.** Snapshots every 5 to 15 minutes cost almost nothing, and
  `zfs rollback` restores the directory in seconds, for example after a bad
  upgrade or a deleted org.
- **Offsite replication.** `zfs send | zfs recv` to a second box gives you a warm
  standby of the data directory.
- **Caveat:** a snapshot of a *running* database is crash-consistent, not
  application-consistent. SQLite in WAL mode recovers from that, but the
  **native backup zip is the authoritative restore copy**. Snapshots add to it.

### 3.4 What this routine does *not* cover

As in §1: JetStream and KV contents (use replicas and mirrors), your TSDB (use
its own tools) and edge state (it rebuilds itself). Also keep a regular
[`stone pull`](./stone-cli.md#5-declarative-workspaces-pull-apply) workspace in
git. It is a readable, diffable record of tenant configuration, useful for
audits and selective rebuilds. It is not a backup, because it has no secrets or
identity material.

---

## 4. Recovery

### Restore in place

To undo a bad change:

```sh
pb auth --collection _superusers
pb backup list
pb backup restore nightly-20260609   # confirms before acting; the server restarts itself
```

Or use the admin UI (**Settings → Backups** → restore). For filesystem damage
on ZFS, run `zfs rollback tank/stone-age@<snapshot>` and restart the service.

### Rebuild from nothing

If you lose the host, you need the platform binary (or the means to build it)
and any backup.

1. Prepare the new host.
2. Install the `stone-age` binary on it.
3. Recover `pb_data` in one of these ways:
    - Restore the ZFS replica.
    - Unzip a native backup into place.
    - Start the binary empty, then run `pb backup upload` and `pb backup restore`
      against it.
4. Run `./stone-age serve` with your existing `config.yaml` and `STONE_AGE_*`
   env vars.
5. Point DNS and the reverse proxy at the new host.

The NATS cluster needs **no changes**. It kept running, and the keys that
signed every credential it checks are back in place. The restored Control Plane
reconnects on the System Account and sends changes again, as in
[Architecture §2](./architecture.md#2-component-topology).

### Verify after any restore

- **Run `curl -s localhost:8090/api/ready | jq` first.** It shows whether the
  schema imported, whether an operator exists, whether the NATS server still
  trusts this database's operator, and whether the binary is older than the
  restored `pb_data`. Every warning or failure has the command that fixes it.
  See [Health & Metrics](./health-metrics.md).
- Console login works (Platform Operator user), and **NATS Status: Connected**
  is green.
- Create a throwaway Thing in a test org. This tests the provisioning hooks and
  the System Account connection.
- Gateways are connected again. Ask the hub over a tenant's own NATS connection,
  with the widget in [Leaf Nodes §7](./leaf-nodes.md#7-is-the-gateway-up), or send
  `$SYS.REQ.ACCOUNT.PING.CONNZ` with the `nats` CLI. The answer comes live from
  the hub.

**Practice restores on a schedule.** A backup you have never restored is not
proven. The `pb` flow in §5.3 is also a restore drill.

---

## 5. Upgrades

### 5.1 How upgrades work

The platform binary embeds its schema and runs **migrations** at startup. To
upgrade, replace the binary and restart. The UI and schema are in the same
binary, so the Control Plane upgrades **atomically**: the UI, API and schema
never disagree.

> **Only a migration file changes the schema or API rules of an existing deployment.** The embedded `schema.json` applies when a database is created. An existing `pb_data` keeps its collections and rules until a release ships a `migrations/schema_update_*.go` for the change. This matters most for **authorization** changes, because the API rules are the platform's permission layer. See [Authorization §7](./authorization.md#7-changing-the-rules).

To upgrade:

1. **Read the release notes**, in the platform's
   [CHANGELOG](https://github.com/stone-age-io/platform/blob/main/CHANGELOG.md).
   Before 1.0, a release can have breaking changes. The notes list them.
2. **Back up.** Run `pb backup create --name "pre-upgrade-vX.Y.Z"`, take a ZFS
   snapshot, or both.
3. **Replace the binary.**
4. **Restart the service.** Migrations run, then the server starts.
5. **Verify**, with the checklist in §4.

**If it goes wrong**, roll back in this order:

1. Stop the service.
2. Put the previous binary back.
3. Restore the pre-upgrade backup, or run `zfs rollback`.
4. Start the service.

Migrations only go forward. **A rollback is always the old binary with restored
data, never the new binary with old data.**

### 5.2 Before 1.0

Until 1.0, treat minor versions as possibly breaking, and pin what you deploy.
Read the notes and back up first. After 1.0, standard semver applies.

### 5.3 Rehearse on staging with real data

```sh
# Copy production state to staging
pb context select production && pb auth --collection _superusers
pb backup create --name "rehearsal-source"
pb backup download rehearsal-source ./rehearsal.zip

pb context select staging && pb auth --collection _superusers
pb backup upload ./rehearsal.zip --name "from-prod"
pb backup restore from-prod

# Now run the NEW binary against staging and watch the migrations apply
```

If the upgrade fails, it fails on staging, with your real schema and data.

### 5.4 Upgrading the other components

Only the Control Plane has a database and migrations. You upgrade everything
else by replacing the binary, in any order, because components share protocols,
not code (§6):

- **`rule-router`, stream processors, Telegraf:** restart with the new binary.
  They reconnect to NATS and continue. Durable state is in NATS. In-memory state,
  such as rule-router's throttle windows, is lost on restart.
- **Agents:** replace and restart. They reconnect by design. On a site gateway,
  restarting the agent also restarts the leaf server **if** `nats.server_config`
  is set. Leave it unset, and a separately supervised `nats-server` keeps the bus
  up during the upgrade, which is usually better on a live site.
- **NATS and Nebula:** use the standard upstream upgrade steps. The platform adds
  no limits beyond theirs (§6).

### 5.5 Moving the NATS server out of the Control Plane

This moves you from `serve --nats` to a `nats-server` that runs as its own
process ([§2.1](#21-where-the-nats-server-runs)). Most of it costs nothing. The
NATS Operator JWT, every account and every user credential are in the Control
Plane database and are generated again, not migrated. Devices keep their
credentials.

**JetStream data is the exception.** Streams, consumers and KV buckets, the twin
included, are in the server's store directory.

::: danger A server that joins a cluster deletes the streams it already has
A `nats-server` with no `cluster` block runs JetStream in standalone mode. When
you add a `cluster` block and restart it, the cluster does not know its
existing streams. The server logs `Detected orphaned stream ... will cleanup`
and deletes them, KV buckets included, within about 30 seconds.

You cannot add a node to a server that holds data and keep the data. Use path
A, which adds no node. For a cluster, back up first (path B).
:::

> **If you expect to need a cluster, form it before you create streams and buckets.** A new install that starts as a cluster has nothing to lose, and this section is then only a config edit.

#### Path A: one external server, and no data moves

The embedded server and a `nats-server` process read the same `nats.conf` and
the same store directory. Only the process that runs the file changes.

1. Stop the Control Plane. The bus stops with it.
2. Start `nats-server -c ./nats-config/nats.conf` under your service manager.
   Use a `nats-server` version that is the same as, or newer than, the one in
   your `stone-age` release.
3. Remove `--nats`, or set `nats.embedded: false`. Start the Control Plane.
4. Check that devices reconnect and twins update.

The outage is as long as one Control Plane restart. After this, a Control Plane
restart does not stop the bus.

#### Path B: a cluster, by backup and restore

This path applies to any cluster, including the two-node cluster of option 2
in [§2.1](#21-where-the-nats-server-runs). Streams and buckets with
`replicas: 3` need three or more nodes.
The streams on the embedded server do not survive the change, so back them up
and restore them. Do this in a maintenance window, because a message stored
after the backup is not in the backup.

1. **Back up every stream and KV bucket.** A KV bucket is a stream with the
   prefix `KV_`, so the `twin` bucket is the stream `KV_twin`.

    ```sh
    nats stream backup <stream> ./backup/<stream>
    ```

    A backup reads from inside one account. The Control Plane has no credential
    in an organization's account, so each organization needs an Owner or Admin
    credential for this step.

2. **Stop the Control Plane.**
3. **Start the cluster nodes.** Give every node the exported `nats.conf`, its
   own `server_name`, an empty store directory and a matching `cluster` block.
   Check that `nats server list` shows every node.
4. **Start the Control Plane against the cluster.** Remove `--nats`, or set
   `nats.embedded: false`, and point `nats.server_url` at the cluster.
5. **Restore, then raise the replicas.**

    ```sh
    nats stream restore ./backup/<stream>
    nats stream update <stream> --replicas 3
    ```

6. **Verify before you delete anything.**
    - Check that devices reconnect and twins update.
    - Check that `nats stream report` shows every stream with the expected
      message counts.
    - Remove the old store directory. Do this last, and only when both checks
      pass.

#### Removing the embedded node from a cluster you already run

If you run option 2, the embedded node is a cluster member and can hold stream
replicas. Remove it in this order:

1. **Add the other external nodes first.** The cluster must keep a quorum
   without the embedded node.
2. **Move each stream off the embedded node while every node is up.**
    - Make an external node the stream's leader. Run
      `nats stream cluster step-down <stream>` until `nats stream info` shows
      an external leader.
    - Set the replica count you want. A stream that goes to `replicas: 1` stays
      on its leader.
    - Check that `nats stream info` no longer lists the embedded node.
3. **Stop the embedded server.** Remove `--nats`, or set `nats.embedded: false`,
   point `nats.server_url` at an external node, and restart the Control Plane.
4. **Remove the embedded node from the cluster's peer list.** Use a System
   Account credential:

    ```sh
    nats server cluster peer-remove <embedded server name>
    ```

Two things fail if you change the order:

- **Do not stop the embedded node while a stream has `replicas: 2` on the two
  nodes.** The stream loses its quorum and refuses writes. The JetStream API
  also refuses the change back to `replicas: 1`, because the cluster has no
  leader.
- **Do not leave one clustered node to run alone.** A node with a `cluster`
  block waits for its route after a restart, and JetStream does not start.

> **Rehearse this on a copy first** (§5.3). A matching message count is the proof, not "it looked fine".

---

## 6. Component Version Compatibility

Components depend on **protocols and the collections schema**, never on each
other's code.

| Component | Depends on | Compatibility notes |
| :--- | :--- | :--- |
| **Stone Age Console** (embedded UI) | Ships inside the `stone-age` binary | Always matches the schema. |
| **`stone` CLI** | PocketBase REST API and the platform's collections schema; NATS protocol | The REST API is stable upstream PocketBase. Additive schema changes do not break the CLI. Before 1.0, the release notes flag breaking schema changes. |
| **Agent** | PocketBase auth API (bootstrap only) and NATS protocol | After bootstrap it is a plain NATS client. |
| **`rule-router`** | NATS subjects and KV only | Knows nothing about PocketBase. Versioned separately. |
| **Stream processors, Telegraf, TSDB, Grafana/Perses** | NATS subjects only | Independent of the platform. The subject contract ([Thing Types](./thing-types.md)) is the only interface. |
| **`nats-server`** | The exported NATS Operator and resolver config ([Getting Started §3](./getting-started.md#3-start-the-nats-server)) | Needs JetStream and JWT/operator-mode auth. Some patterns in these docs need a minimum version: 2.11 for a TTL on one KV key, 2.12 for message scheduling ([Automation §3](./automation.md#3-patterns-built-from-existing-parts)). For an external server, use the same version as the one embedded for `serve --nats` ([§6.1](#61-the-versions-these-docs-describe)) or a newer one. |
| **`nebula`** | Certificates from the org CAs | Stock upstream. The platform issues standard Nebula certificates and configs. |

- **Upgrade the Control Plane first** when a release changes the schema. `stone`
  and the Agent tolerate additive changes, and the release notes list any that
  are not additive.
- **Layer 1 to 3 components do not depend on platform releases.** Their contract
  is the subject namespace, which you keep stable. See
  [Connectivity](./connectivity.md).
- **Before 1.0, pin versions** of `stone-age`, `stone` and the Agent, and upgrade
  them together when the notes mention schema changes. The Agent has its own
  repository and version numbers. After 1.0, changes within a major version are
  additive only.

---

### 6.1 The versions these docs describe

The pages in the Platform section describe these versions. A page that depends
on a later version says so.

| Component | Version | Where its own docs are |
| :--- | :--- | :--- |
| Control Plane and console (`stone-age`) | v0.17.0 | This section. [CHANGELOG](https://github.com/stone-age-io/platform/blob/main/CHANGELOG.md) |
| `stone` CLI | v0.6.1 | [Stone CLI](./stone-cli.md) |
| Agent | v0.6.0 | [Agent docs](./vendor/agent/README.md) |
| `rule-router` | v0.23.0 | [Rule Router docs](./vendor/rule-router/README.md) |
| Services | Watchdog v0.1.0. creds-keeper is not in a release yet: the docs describe commit `981453f` on `main`, which has no tag | [Services docs](./vendor/services/README.md) |
| Access Control | v0.2.0 | [Access Control docs](./vendor/access-control/README.md) |
| Helpdesk | no release tag, commit `be4aca2` | [Helpdesk docs](./vendor/helpdesk/README.md) |

Platform v0.17.0 is built on these upstream versions:

| Upstream | Version |
| :--- | :--- |
| PocketBase | v0.41.1 |
| nats-server (embedded with `serve --nats`) | v2.15.2 |
| Nebula | v1.11.0 |
| pb-nats | v0.4.0 |
| pb-nebula | v0.5.0 |
| pb-audit | v0.3.0 |

Each vendored section has a `SOURCE` file in the docs repository with the exact
commit of its copy.

---

## 7. Production Checklist

- [ ] **TLS on everything outward-facing:** HTTPS in front of the Control Plane,
  `wss://` on the NATS WebSocket listener, and TLS on client and leaf ports
  (see the NATS docs).
- [ ] **Backups scheduled** in the admin UI, **with S3 offsite**, and a restore
  actually rehearsed (§4).
- [ ] **Readiness probe connected** to whatever runs the process:
  `GET /api/ready` returns `503` only when something is broken (or before
  the first probe completes, at startup), so a load
  balancer can use it. Point your scraper at `GET /metrics`. Both are
  unauthenticated by default. `metrics.token` protects `/metrics`, and a proxy
  can protect either ([Health & Metrics](./health-metrics.md)).
- [ ] **`pb_data` on its own dataset or volume**, ideally ZFS with automatic
  snapshots (§3.3).
- [ ] **Encryption keys set at install time:** `--encryptionEnv` for app
  settings, and `nats.encryption_key` / `nebula.encryption_key` for the minting
  keys. Neither covers issued credentials, so encrypt disks and backups too
  ([Configuration §2.2](./configuration.md#22-the-encryption-keys)).
- [ ] **Audit retention set:** by default, `audit.retention` keeps everything
  ([Configuration §2](./configuration.md#2-section-reference)). Only Platform
  Operators can read the log. Tenants see who changed what in their `activity`
  feed. Requests for old and new *values* still come to you
  ([Authorization §5](./authorization.md#5-two-histories-the-audit-log-and-the-activity-feed)).
- [ ] **NATS account limits reviewed:** the defaults are 100 connections, 5000
  subscriptions, 5 GiB of JetStream disk and 64 MiB of JetStream memory per
  organization. Size disk to each plan, keep memory small, and set connections
  well above real load. Decide **before** you create tenants, because the limits
  are set at provisioning. After that, only a Platform Operator can edit an
  account's record ([Configuration §2](./configuration.md#2-section-reference)).
- [ ] **Consumers per stream reviewed:** since NATS 2.15, a stream allows at
  most 1000 consumers unless you raise it. Each open KV view in the console and
  each dashboard widget that reads a stream holds one consumer on the hub. For a
  busy organization, set `max_consumers` on the stream or the account, or set
  `default_max_consumers` under `jetstream { limits { ... } }` in `nats.conf`
  ([2.15 upgrade guide](https://docs.nats.io/release-notes/upgrade-to-2.15)).
- [ ] **NATS clustered** (3 or more nodes), with `replicas: 3` on the streams and
  KV buckets that matter.
- [ ] **Credential expiry reviewed:** the NATS Users and Nebula Hosts lists flag
  anything expiring within 30 days. A fleet provisioned at once expires at
  once, and an expired Nebula fleet takes out the path you would use to fix it.
- [ ] **Nebula expiry alerted**, with 30 days for a host and 90 for a CA:
  [Health & Metrics §4](./health-metrics.md#4-certificate-expiry).
- [ ] **A decommissioning procedure agreed:** deactivate a Thing, never delete
  it ([Authorization §4.2](./authorization.md#42-taking-a-device-out-of-service)).
- [ ] **A tenant-suspension procedure agreed:** clearing an organization's
  `active` disconnects the whole tenant from the hub, reversibly
  ([Authorization §3.1](./authorization.md#31-suspending-an-organization)).
- [ ] **SuperUser kept for infrastructure work**, with daily administration done
  as a Platform Operator
  ([Getting Started §2](./getting-started.md#2-initialize-the-control-plane)).
- [ ] **Least-privilege review:** check each org's memberships. `admin` is the
  same as `owner` in every API rule, including every credential collection. Most
  people need `member` ([Authorization](./authorization.md)).
- [ ] **`./scripts/test-authz.sh` passes** on the exact commit you deploy. The API
  rules are the platform's tenancy enforcement, and this suite is the only live
  test of them. If the release changed a rule, check that it also has a migration
  (§5.1).
- [ ] **A `stone pull` workspace in git** for reviewable tenant configuration
  ([Stone CLI §5](./stone-cli.md#5-declarative-workspaces-pull-apply)).

---

## 8. Where to Go Next

- The first-time setup this checklist assumes: [Getting Started](./getting-started.md)
- Config keys: [Configuration Reference](./configuration.md)
- Roles, API rules and the audit log: [Authorization & Roles](./authorization.md)
- The plane split: [Architecture](./architecture.md) and [Platform Layers](./platform-layers.md)
- Edge resilience during outages: [Leaf Nodes](./leaf-nodes.md)
- The GitOps workspace: [Stone CLI](./stone-cli.md)
