# Operations & Production

This page covers running the Stone-Age.io Platform in production: what state you're protecting, the availability model, backup and recovery, upgrades, and how component versions relate to each other.

The short version: the platform's operational posture follows directly from the [plane split](./platform-layers.md#1-planes-and-layers). The Data Plane gets high availability the NATS-native way — clustering at the hub, [leaf-node autonomy](./leaf-nodes.md) at the edge. The Control Plane gets something simpler and, for its role, better: a small, easily-backed-up SQLite file and a recovery time measured in minutes.

---

## 1. What You're Protecting

Operational state lives in different places, with different owners and different backup stories. Know which is which before designing your routine:

| State | Where it lives | Loss impact | Protected by |
| :--- | :--- | :--- | :--- |
| **Identity hierarchy** — Operator key, NATS Accounts, Nebula CAs, user/Thing credentials | Control Plane (`pb_data`) | **Severe.** The Operator key is the root of the entire chain of trust — losing it orphans every Account and credential it signed. | This page (§3). |
| **Inventory & contracts** — Orgs, Things, Thing Types, Locations, schemas, rules-adjacent config | Control Plane (`pb_data`) | High, but recoverable — re-entry is tedious, not impossible. Also recoverable from a [GitOps workspace](./stone-cli.md#5-declarative-workspaces-pull--apply). | This page (§3), plus `stone pull` workspaces. |
| **Live state** — Digital Twin KV, JetStream streams | NATS servers (JetStream storage) | Low to moderate. Twins repopulate from device heartbeats; stream retention is a buffer, not an archive. | JetStream replicas (`replicas: 3` on clustered NATS), stream mirrors. |
| **Historical telemetry** | Your Layer 3 TSDB | Your call — it's [BYO](./observability.md). | Your TSDB's own backup tooling. |
| **Edge config mirrors** | Leaf node local KV | None. `leaf-sync` reconverges from the Control Plane on its next cycle. | Nothing needed — see [Leaf Nodes](./leaf-nodes.md). |

The takeaway: **`pb_data` is the crown jewels.** It's also a single directory dominated by one SQLite database, which makes protecting it straightforward.

> **Backups contain secrets.** A Control Plane backup includes the Operator key, every org's Nebula CA private key, and credential material. Treat backup artifacts with the same care as the live database: restrict the S3 bucket, encrypt at rest, and don't leave downloaded copies on workstations. Consider `--encryptionEnv` (see [Configuration §4](./configuration.md#4-pocketbase-flags)) to encrypt app settings at rest.

---

## 2. The Availability Model

The platform deliberately puts high availability where it matters and fast recovery where HA would be wasted complexity.

### Data Plane: HA by construction

The runtime path — telemetry, commands, rules, live dashboards — never depends on a single process:

- **NATS clusters horizontally.** Run three or five `nats-server` nodes and the bus survives node loss; JetStream streams and KV buckets with `replicas: 3` survive it durably. This is stock NATS operations — their [docs](https://docs.nats.io) cover it well.
- **Leaf nodes keep sites autonomous.** A WAN or hub outage doesn't stop site-local devices, rules, or stream processors. Traffic buffers and reconverges when connectivity returns. See [Leaf Nodes](./leaf-nodes.md).
- **Rule engines and stream processors are stateless per message** and horizontally scalable; durable state is in replicated KV.

### Control Plane: recovery-oriented, not failover-oriented

The Control Plane is a low-traffic metadata store, and its outage is far less dramatic than it sounds:

| While the Control Plane is down... | Status |
| :--- | :--- |
| Device telemetry, commands, live dashboards' data | ✅ Unaffected — pure Data Plane |
| Layer 1 rules, Layer 2 processors, Layer 3 ingestion | ✅ Unaffected |
| Already-issued NATS/Nebula credentials | ✅ Keep working — auth is verified by the cluster, not by PocketBase |
| Console login, entity management | ❌ Paused |
| Provisioning new Orgs / Things / credentials | ❌ Paused |
| Agent bootstrap and `leaf-sync` config pulls | ⏸️ Paused — both retry; `leaf-sync` is fail-soft and leaves local KV untouched |

Nothing in that bottom half is latency-critical. So instead of running an HA database topology to protect a metadata store, the platform's answer is **aggressive backups plus a short, rehearsed restore path** (§3–4). With scheduled native backups, S3 offsite copies, and filesystem snapshots, realistic time-to-recovery is minutes — which, for a service whose outage pauses provisioning but not production traffic, is the right trade.

---

## 3. Backups

Use the layers together: **native scheduled backups** as the authoritative artifact, **S3** for offsite, **`pb` (pb-cli)** for scripting and rehearsal, and **ZFS snapshots** for instant local rollback.

### 3.1 Native scheduled backups

PocketBase — and therefore the platform binary — ships with backup support built in. A backup is a consistent zip of the entire `pb_data` directory, taken safely while the server runs.

Configure it as the SuperUser in the embedded admin UI (`/_/` → **Settings → Backups**):

- **Schedule** — a cron expression (e.g. `0 2 * * *` for nightly at 02:00).
- **Max kept** — how many backups to retain before the oldest is pruned.
- **Storage** — local disk by default, or an **S3-compatible bucket** (endpoint, bucket, region, credentials). With S3 configured, every scheduled backup lands offsite automatically — no extra tooling.

This alone satisfies the baseline: nightly, consistent, offsite, auto-pruned.

### 3.2 Scripted backups with pb-cli

[`pb-cli`](https://github.com/skeeeon/pb-cli) (`pb`) is a generic PocketBase CLI that drives the same backup API from scripts — useful for pre-upgrade snapshots, extra offsite copies, and restore rehearsal. Backup operations require SuperUser auth.

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

`pb` also moves backups *between* environments (`backup upload` + `backup restore`), which is how you rehearse recovery and stage upgrades against real data — see §5.3.

### 3.3 Filesystem snapshots (ZFS)

We recommend running the Control Plane with `pb_data` on its own **ZFS dataset** with automatic snapshots (sanoid, zfs-auto-snapshot, or your distro's equivalent):

```sh
zfs create tank/stone-age
# point the binary at it: ./stone-age serve --dir /tank/stone-age/pb_data
```

- **Near-zero cost, near-instant rollback.** Frequent snapshots (every 5–15 minutes) cost almost nothing and `zfs rollback` restores the whole directory in seconds — the fastest possible answer to "the upgrade went sideways" or "someone deleted the wrong org."
- **Replication for offsite.** `zfs send | zfs recv` to a second box gives you a warm standby of the data directory with no application awareness needed.
- **One caveat:** a snapshot of a *running* database is crash-consistent, not application-consistent. SQLite in WAL mode recovers cleanly from that in practice, but the **native backup zip remains the authoritative restore artifact** — snapshots are the convenience layer on top, not a replacement.

### 3.4 What this routine does *not* cover

By design, per the table in §1: JetStream/KV contents (protect with replicas and mirrors at the NATS layer), your TSDB (its own tooling), and edge state (self-healing). One more worth keeping: a periodic [`stone pull`](./stone-cli.md#5-declarative-workspaces-pull--apply) workspace in git is a human-readable, diffable record of your tenant configuration — not a substitute for backups (it carries no secrets or identity material), but a fine complement for auditing and selective re-creation.

---

## 4. Recovery

### Restore in place

For "bad change, wind it back" scenarios:

```sh
pb auth --collection _superusers
pb backup list
pb backup restore nightly-20260609   # confirms before acting; the server restarts itself
```

Or equivalently: admin UI → **Settings → Backups** → restore. Or, if the damage is filesystem-level and you're on ZFS: `zfs rollback tank/stone-age@<snapshot>` and restart the service.

### Rebuild from nothing

Total host loss. You need: the platform binary (or the means to build it) and any backup artifact.

1. Stand up the new host; install the `stone-age` binary.
2. Recover `pb_data` — restore the ZFS replica, unzip a native backup into place, or start the binary empty and use `pb backup upload` + `pb backup restore` against it.
3. `./stone-age serve` with your existing `config.yaml` / `STONE_AGE_*` env vars.
4. Re-point DNS / the reverse proxy.

The NATS cluster needs **no changes** — it kept running the whole time, and every credential it validates was signed by keys that are back in place. The restored Control Plane reconnects on the System Account and resumes propagating changes in real time, exactly as described in [Architecture §2](./architecture.md#2-component-topology).

### Verify after any restore

- Console login works (Operator user) and the **NATS Status: Connected** indicator is green.
- Create a throwaway Thing in a test org — confirms the provisioning hooks and the System Account connection end-to-end.
- `leaf-sync` heartbeats reappear on the Leaf Nodes list within a few sync intervals.

**Rehearse this.** A backup you've never restored is a hypothesis, not a backup. The `pb` migration flow in §5.3 doubles as a restore drill — do it on a schedule, not just before upgrades.

---

## 5. Upgrades

### 5.1 How upgrades work

The platform binary embeds its schema and runs **migrations** automatically: replace the binary, restart, and any pending schema migrations apply at startup. Because the UI and schema are compiled into the same artifact, the Control Plane upgrades **atomically** — there is no window where the UI, API, and schema disagree.

The procedure:

1. **Read the release notes.** Pre-1.0, breaking changes can occur; they're called out per release and have so far been minimal.
2. **Back up.** `pb backup create --name "pre-upgrade-vX.Y.Z"` — and/or take a ZFS snapshot. Thirty seconds of discipline that makes step 5 trivial.
3. **Swap the binary** and restart the service. Migrations run; the server comes up.
4. **Verify** — the same checklist as §4.
5. **If it went wrong:** stop the service, put the previous binary back, restore the pre-upgrade backup (or `zfs rollback`), start. Migrations are forward-only — **rollback is always *old binary + restored data*, never the new binary against old data.**

### 5.2 Pre-1.0 expectations

Until 1.0, treat minor versions as potentially breaking and pin what you deploy. In practice breaking changes have been small and migration-handled, but the contract is explicit: **read the notes, back up first.** After 1.0, standard semver discipline applies.

### 5.3 Rehearse on staging with real data

`pb` makes a realistic dress rehearsal cheap:

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

If the upgrade misbehaves, you found out on staging — against your actual schema and data shape, not a toy fixture.

### 5.4 Upgrading the other components

The Control Plane is the only component with a database and migrations. Everything else upgrades by binary swap, in any order, because the interfaces between components are protocols, not shared code (§6):

- **`rule-router`, stream processors, Telegraf** — restart with the new binary; they reconnect to NATS and resume. Stateless per message; durable state is in KV.
- **Agents and `leaf-sync`** — swap and restart; both are designed around reconnection and fail-soft behavior.
- **NATS and Nebula** — stock upstream upgrade procedures; the platform places no constraints beyond theirs (see §6).

---

## 6. Component Version Compatibility

Stone-Age.io is a set of independent binaries, so the compatibility question is really: *what does each component actually depend on?* The answer is deliberately narrow — components couple to **protocols and the collections schema**, never to each other's code.

| Component | Depends on | Compatibility notes |
| :--- | :--- | :--- |
| **Stone Age Console** (embedded UI) | Ships inside the `stone-age` binary | Always in lockstep with the schema by construction. No version skew is possible. |
| **`stone` CLI** | PocketBase REST API + the platform's collections schema; NATS protocol | The REST API is stable upstream PocketBase. The collections schema is the platform's own contract — additive changes don't break the CLI; pre-1.0 breaking schema changes are flagged in release notes. |
| **`leaf-sync`** | PocketBase REST API (its allowlisted collections) + NATS leaf protocol | Mirrors records generically; tolerant of additive schema change. Built from the platform repo, so matching its release to the Control Plane's is the safe default. |
| **Agent** | PocketBase auth API (bootstrap only) + NATS protocol | After bootstrap it's a pure NATS client. |
| **`rule-router`** | NATS subjects + KV only | Knows nothing about PocketBase. Versioned independently. |
| **Stream processors, Telegraf, TSDB, Grafana/Perses** | NATS subjects only | Fully platform-agnostic. The subject contract ([Thing Types](./thing-types.md)) is the only interface. |
| **`nats-server`** | The exported operator/resolver config ([Getting Started §3](./getting-started.md#3-stand-up-the-nats-server)) | Any modern NATS 2.x with JetStream and JWT/operator-mode auth. Follow upstream support guidance. |
| **`nebula`** | Certificates issued by the org CAs | Stock upstream; the platform only mints standard Nebula certs and configs. |

Practical guidance:

- **Upgrade the Control Plane first** when a release touches the schema — clients (`stone`, `leaf-sync`) tolerate additive changes, and the release notes call out anything that isn't.
- **Layer 1–3 components don't care about platform releases at all.** Their contract is the subject namespace, which is yours to keep stable — see [Connectivity](./connectivity.md).
- **Pre-1.0, pin versions** across `stone-age`, `stone`, and `leaf-sync`, and move them together when the notes mention schema changes. Post-1.0, additive-only within a major version is the rule.

---

## 7. Production Checklist

A condensed pre-flight list for taking a deployment to production:

- [ ] **TLS everywhere outward-facing** — HTTPS in front of the Control Plane; `wss://` on the NATS WebSocket listener; TLS on client/leaf ports per the NATS docs.
- [ ] **Backups scheduled** (admin UI cron) **with S3 offsite** configured — and a restore actually rehearsed (§4).
- [ ] **`pb_data` on its own dataset/volume**, ideally ZFS with automatic snapshots (§3.3).
- [ ] **App-settings encryption** enabled via `--encryptionEnv` ([Configuration §4](./configuration.md#4-pocketbase-flags)).
- [ ] **Audit retention** configured deliberately — `audit.retention` defaults keep everything forever ([Configuration §2](./configuration.md#2-section-reference)).
- [ ] **NATS account limits reviewed** — the shipped defaults (`max_connections: 10`, `max_subscriptions: 50`) are conservative; size them for your real per-org fleets ([Configuration §2](./configuration.md#2-section-reference)).
- [ ] **NATS clustered** (3+ nodes) with `replicas: 3` on JetStream streams and KV buckets that matter.
- [ ] **SuperUser reserved** for infrastructure work; day-to-day administration through an Operator user ([Getting Started §2](./getting-started.md#2-initialize-the-control-plane)).
- [ ] **A `stone pull` workspace in git** for reviewable, diffable tenant configuration ([Stone CLI §5](./stone-cli.md#5-declarative-workspaces-pull--apply)).

---

## 8. Where to Go Next

- **First-time setup the checklist assumes:** [Getting Started](./getting-started.md).
- **Config keys referenced above:** [Configuration Reference](./configuration.md).
- **The plane split that shapes this whole page:** [Architecture](./architecture.md) and [Platform Layers](./platform-layers.md).
- **Edge resilience during outages:** [Leaf Nodes](./leaf-nodes.md).
- **The GitOps workspace as a config audit trail:** [Stone CLI](./stone-cli.md).
