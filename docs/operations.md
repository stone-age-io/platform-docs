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
| Agent bootstrap and credential sync | ⏸️ Paused. The Agent retries, and a provisioned site keeps running on the credential and leaf config it has. |

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
There are three options, and you move between them by editing config:

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

Moving from option 2 to option 3 is the one step that is not only additive
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
- Sites are connected again. Ask the hub over a tenant's own NATS connection,
  with the widget in [Leaf Nodes §7](./leaf-nodes.md#7-is-the-site-up), or send
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

1. **Read the release notes.** Before 1.0, a release can have breaking changes.
   The notes list them.
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

This moves you from `serve --nats` to a standalone `nats-server`
([§2.1](#21-where-the-nats-server-runs)). Most of it costs nothing. The NATS
Operator JWT, every account and every user credential are in the Control Plane
database and are generated again, not migrated. Devices keep their credentials.

**JetStream data is the exception.** Streams, consumers and the KV buckets with
twin state are in the embedded server's store directory. An R1 stream on the
embedded node is lost with that node. Plan for it before you start.

> **If you expect to leave embedded mode, do not put JetStream on the embedded node.** Add the external node early and keep `jetstream: {}` out of the embedded config. Then this section is only a config edit.

Otherwise, replicate before you drain:

1. **Add the external node.**
    - Give both NATS configs a matching `cluster` block, with the same `name` in
      both, and point each one's routes at the other.
    - Restart both servers.
    - Check the route: `nats server list` must show two servers in the cluster.

2. **Raise replicas on everything you want to keep.** Nothing is safe to drain
   until it is replicated.
    - Set `replicas: 2` on every stream on the embedded node:
      `nats stream update <name> --replicas 2`.
    - Set `replicas: 2` on every KV bucket on the embedded node.
    - Check that each shows the new peer as **current**, not catching up:
      `nats kv status <bucket>`.

3. **Drain the embedded node.** This moves JetStream leadership off it in a
   controlled way.
    - Step down its raft leadership: `nats server raft step-down`.

4. **Stop the embedded server.**
    - Remove `--nats`, or set `nats.embedded: false`.
    - Point `nats.server_url` at the external node.
    - Restart the Control Plane.

5. **Set replicas back to the value you want.** One remaining node cannot hold
   `replicas: 2`. Do one of these:
    - Set the replica count back to `1` on every stream and bucket you changed in
      step 2.
    - Add the third node now, then set the replica count to `3`.

6. **Verify before you delete anything.**
    - Check that devices reconnect and twins update.
    - Check that `nats stream report` shows every stream with the expected
      message counts.
    - Remove the old store directory. Do this last, and only when both checks
      pass.

> **Rehearse this on a copy first** (§5.3). Steps 2 and 3 lose data if the peer was not really current. A matching message count is the proof, not "it looked fine".

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
| **`nats-server`** | The exported NATS Operator and resolver config ([Getting Started §3](./getting-started.md#3-start-the-nats-server)) | Any modern NATS 2.x with JetStream and JWT/operator-mode auth. Follow upstream support guidance. |
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

## 7. Production Checklist

- [ ] **TLS on everything outward-facing:** HTTPS in front of the Control Plane,
  `wss://` on the NATS WebSocket listener, and TLS on client and leaf ports
  (see the NATS docs).
- [ ] **Backups scheduled** in the admin UI, **with S3 offsite**, and a restore
  actually rehearsed (§4).
- [ ] **Readiness probe connected** to whatever runs the process:
  `GET /api/ready` returns `503` only when something is broken, so a load
  balancer can use it. Point your scraper at `GET /metrics`. Both are
  unauthenticated by default. `metrics.token` protects `/metrics`, and a proxy
  can protect either ([Health & Metrics](./health-metrics.md)).
- [ ] **`pb_data` on its own dataset or volume**, ideally ZFS with automatic
  snapshots (§3.3).
- [ ] **App-settings encryption** with `--encryptionEnv`
  ([Configuration §4](./configuration.md#pocketbase-flags)). This covers SMTP,
  S3 and OAuth2 secrets only.
- [ ] **Column encryption set separately:** `nats.encryption_key` and
  `nebula.encryption_key` encrypt the NATS and Nebula minting keys. They are
  empty by default, cannot encrypt existing rows, and a lost key loses what it
  protected. Neither covers **issued** credentials (`creds_file`,
  `config_yaml`), so use disk encryption and encrypted backups too
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
  anything that expires within 30 days or has expired. Nebula host certificates
  always expire (`validity_years`). NATS user JWTs expire only if an expiry was
  set. A fleet is usually provisioned at once, so its credentials expire together
  and fail silently. Reissue before the date. **Nebula expiry is worse**, because
  Nebula is the out-of-band path: an expired fleet removes the route you would
  use to fix it.
- [ ] **Nebula expiry alerted:** `GET /api/ready` has a `nebula_cert_expiry`
  check, which warns and never fails. `GET /metrics` has
  `stone_age_certificate_expiry_seconds{kind}` as an absolute Unix timestamp.
  Alert relative to now, with 90 days for a CA and 30 for a host:

    ```
    stone_age_certificate_expiry_seconds{kind="nebula_host"} - time() < 30 * 86400
    stone_age_certificate_expiry_seconds{kind="nebula_ca"}   - time() < 90 * 86400
    ```

    Set the CA alert in particular, because every host certificate chains to it.
    See [Health & Metrics §4](./health-metrics.md#4-certificate-expiry).
- [ ] **A decommissioning procedure agreed:** clearing `active` on a Thing cuts a
  device off, gateways included. It refuses new logins, ends every session,
  suspends the NATS identity, and blocklists the Nebula host as peers get their
  next config. Reactivating issues a **new** `.creds` for the device
  ([Authorization §4.2](./authorization.md#42-taking-a-device-out-of-service)).
  **Deactivate, never delete:** a delete does not touch either identity.
- [ ] **A tenant-suspension procedure agreed:** clearing `active` on an
  **organization** withdraws its NATS account, so every device, agent and
  browser in the tenant disconnects, including after restarts. Only a Platform
  Operator can do it, and it is **reversible**: no credential changes, so setting
  the flag again reconnects everything. It does not change Nebula, lock the
  console or end sessions. The operator and system organizations refuse it
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
