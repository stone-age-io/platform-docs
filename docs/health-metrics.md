---
path: platform/health-metrics
nav_order: 180
---
# Health & Metrics

Every Stone-Age.io binary reports on **itself**, with no login and no NATS
connection:

- `GET /api/ready`: a readiness report in JSON, `200` or `503`.
- `GET /metrics`: a Prometheus exposition.

[Observability](./observability.md) covers the history of your *telemetry*.
This page covers the *processes*: can the Control Plane do its job, and is the
edge agent still syncing?

---

## 1. Why This Exists At All

PocketBase already serves `/api/health`, which tells you the HTTP server is
listening. But the server also listens during every serious failure of this
platform. A Control Plane can return `200` while:

- the NATS server does not trust its operator, so every account claim is
  rejected and no organization's account reaches the bus, while the console
  looks normal;
- `bootstrap` ran before `migrate up`, so the tenancy flags were dropped and
  the install has no Platform Operator;
- `nats.websocket_urls` is not set, so the console works on the server and for
  nobody else;
- a Nebula CA expired, and every host in the mesh stopped with it.

A liveness probe detects none of these. So these checks look for **things that
are silently wrong**, not for whether the process is up.

> **Liveness and readiness have different consequences.** A liveness failure should restart the process. A readiness failure should stop *sending it traffic*. If one endpoint did both, every short NATS outage would cause a container restart loop, which fixes nothing and takes the console down. So readiness is `/api/ready`, separate from `/api/health`.

### The rule that shapes the list

**A process checks only what it can see itself.**

The Control Plane holds the NATS operator and the `$SYS` account, and **no user
credential inside any organization's account**. So it cannot read an org's
`twin` KV or anything a site reports. The console can, because the browser
connects as the signed-in user. That is also how a tenant checks whether a
site's leaf node is connected: a dashboard widget asks the bus over that
connection ([Leaf Nodes §7](./leaf-nodes.md#7-is-the-site-up)). The Agent can,
because it runs inside the account.

Do not give the platform a credential in a tenant's account to add a check.
That would make the credential issuer a participant in every tenant's bus,
which breaks the boundary the NATS design depends on. So the Control Plane has
**no** per-site liveness check. It is on the edge instead ([§5](#5-the-edge-agent)).

---

## 2. `GET /api/ready`

Unauthenticated, with one body for everyone. Its callers are container
orchestrators, load balancers and uptime checkers, and none has a PocketBase
session. To restrict it, use a reverse proxy.

```
$ curl -s http://localhost:8090/api/ready | jq
```

```json
{
  "ready": false,
  "state": "fail",
  "version": "v0.8.0",
  "uptime": "3m12s",
  "took": "14ms",
  "checked": "2026-09-07T05:37:18Z",
  "checks": [
    {
      "name": "bootstrap",
      "state": "fail",
      "detail": "no user has is_operator set",
      "fix": "Run: ./stone-age bootstrap --email <you> --org \"System\" --operator-org \"<your company>\"  (after `migrate up`)",
      "took": "10ms"
    },
    {
      "name": "database",
      "state": "ok",
      "detail": "responding",
      "took": "11ms"
    },
    {
      "name": "encryption_at_rest",
      "state": "warn",
      "detail": "disabled: NATS seeds and Nebula private keys are stored in plaintext",
      "fix": "Set nats.encryption_key and nebula.encryption_key to exactly 32 characters (via STONE_AGE_*_ENCRYPTION_KEY). Back the keys up — losing one loses the encrypted records.",
      "took": "0s"
    },
    {
      "name": "nebula_cert_expiry",
      "state": "skipped",
      "detail": "no Nebula certificates issued",
      "took": "10ms"
    }
  ]
}
```

Checks are sorted by name, so you can diff two probes.

**`fix` tells you what to do.** The reader has often just deployed the binary
and does not yet know the bootstrap order. `fix` gives them the command.

### The four states

| State | Ready? | HTTP | Means |
|---|:-:|:-:|---|
| `ok` | yes | 200 | Checked, nothing to report. |
| `warn` | **yes** | **200** | Running but misconfigured. It works now, but a person should fix it. |
| `fail` | no | 503 | Stop sending this process traffic. |
| `skipped` | yes | 200 | The check did not apply, or could not run. |

**`warn` returns 200 on purpose.** A probe can only restart or remove the
process, and neither fixes "you have not set an encryption key". It would take a
working deployment offline. It would also refuse the standard development
deployment, which is validly in this state.

**`skipped` ranks *below* `ok`.** It means there is no answer. The top-level
`state` is the worst state of all checks, computed from the results, not
starting from `ok`. So an all-skipped report does not look healthy.

`ready` is `false` only if a check **failed**. `state` tells a caller "ready,
but look at this" apart from "ready, nothing to report".

### Control Plane checks

| Check | Fails when | Notes |
|---|---|---|
| `database` | SQLite does not answer `SELECT 1` | `pb_data/` is not writable, or another running instance holds it. |
| `schema` | `schema.json` was never imported | Catches a build whose `//go:embed` did not work: the libraries' collections exist, none of the platform's fields do, and the migrations table says everything ran. |
| `schema_version` | the database has migrations **this binary does not know** | A *downgrade*. See below. |
| `bootstrap` | no user has `is_operator`, or no org has `is_system_org` | Nobody can create an organization. |
| `nats_operator` | no NATS operator record, or it has no JWT | Nothing can sign an account or user JWT. |
| `nats_reachable` | nothing listens on `nats.server_url` | Warns if JetStream is disabled. |
| `nats_trust` | the server **rejects this database's `$SYS` credential** | See below. |
| `nebula_cert_expiry` | never, warns only | Certificates the platform signed. See [§4](#4-certificate-expiry). |
| `nats_websocket_urls` | never, warns only | Empty means the console uses `ws://localhost:9222`. |
| `encryption_at_rest` | never, warns only | `nats.encryption_key` or `nebula.encryption_key` is unset. When both are set, it says `ok` and what that covers: the minting keys, not issued credentials ([Configuration §2.2](./configuration.md#22-the-encryption-keys)). |

**`nats_trust`** connects to `nats.server_url` with the `$SYS` credential from
the database. A server whose `nats.conf` has an *old operator JWT* rejects it.
Otherwise you would not see this failure: every account claim is refused, no
organization's account reaches the bus, devices cannot connect, and every
console screen looks correct.

Reachability is a **separate** check, because "nothing is listening" and
"listening but does not trust us" have different fixes.

**`schema_version` looks for a downgrade, not pending migrations.** `serve`
runs every migration before it listens, so migrations are never pending when a
probe can run. The check looks for the database being *ahead* of the binary.
Migrations do not roll back, so an older binary on newer `pb_data` runs against
columns and rules it does not know, with unpredictable results.

**`nats_reachable` uses `nats.server_url`, not the browser's address.**
`server_url` is the TCP address the Control Plane connects to. `websocket_urls`
is the address a *browser* connects to, on another port and often another host.
Never compute one from the other. See
[Configuration §2.1](./configuration.md#21-server_url-and-websocket_urls-are-different-addresses).

### The prober caches; the endpoint never runs checks

A background prober runs the checks every `readiness.interval`, and the endpoint
returns the last result. This keeps the endpoint safe to probe:

- Checks on each request would open a NATS connection on every probe.
- A slow check would make the endpoint slow, which looks *unready* and kills a
  healthy container.

The response has `Cache-Control: no-store`, and `checked` shows the age of the
answer. Before the first probe completes, you get a `503` with
`"readiness has not been probed yet"`, which differs from a failing check.

If a check panics, the prober catches it and reports a failure. A diagnostic
must not crash the process it checks.

---

## 3. `GET /metrics`

Prometheus text format, from the standard client library. It is open by
default. Set `metrics.token` to require a credential, or `metrics.enabled: false`
to remove the route.

> **`/api/ready` is always on.** Only `/metrics` follows `metrics.enabled`. Readiness is a contract with your orchestrator, so you cannot disable it.

### Authentication

`/metrics` does **not** use PocketBase auth. PocketBase tokens are JWTs that
expire, and scrapers cannot refresh them.

`metrics.token` works in two forms, which cover every common scraper:

```
Authorization: Bearer <token>          # Prometheus bearer_token
Authorization: Basic <any>:<token>     # basic_auth — the username is ignored
```

A `401` has `WWW-Authenticate: Basic realm="metrics"`, so a browser shows a
prompt and a misconfigured scrape fails clearly.

### Readiness, as metrics

The checks are exported as a **state set**: one series per check per state, with
`1` on the current state:

```
stone_age_ready 0
stone_age_check_state{name="database",state="ok"} 1
stone_age_check_state{name="database",state="fail"} 0
stone_age_check_state{name="database",state="warn"} 0
stone_age_check_state{name="database",state="skipped"} 0
stone_age_check_timestamp_seconds 1.7573e+09
stone_age_build_info{version="v0.8.0"} 1
```

A number for "ok/warn/fail/skipped" would need decoding in every query, and a new
state would change the meaning of stored data. A state set avoids both.

**Alert when `stone_age_check_timestamp_seconds` goes stale.** That means the
prober itself is stuck. No other series shows this, because they all keep their
last values.

### Platform metrics

| Metric | Type | Labels | What it is |
|---|---|---|---|
| `stone_age_records` | gauge | `collection` | Rows in a platform collection. |
| `stone_age_inactive_records` | gauge | `collection` | Things with `active = false`: decommissioned devices, gateways included. Counts `things` only. |
| `stone_age_nats_users_revoked` | gauge | | Users whose key is on their account's revocation list. |
| `stone_age_database_size_bytes` | gauge | | `data.db` plus its WAL and shared-memory files. **Not** uploaded files, which are in `pb_data/storage`. |
| `stone_age_certificates` | gauge | `kind` | Nebula certificates in service. |
| `stone_age_certificates_expired` | gauge | `kind` | Certificates already expired. |
| `stone_age_certificates_expiring` | gauge | `kind` | Certificates expiring within the warning window: 30 days for `nebula_host`, 90 for `nebula_ca`. |
| `stone_age_certificate_expiry_seconds` | gauge | `kind` | **Unix timestamp** of the soonest expiry of that kind. |
| `stone_age_http_requests_total` | counter | `route`, `method`, `status` | Requests served. |
| `stone_age_http_request_duration_seconds` | histogram | `route`, `method` | Request latency. |
| `stone_age_collector_errors` | gauge | | Collectors that failed **during this scrape**. |

`stone_age_nats_*` series appear only when the bus runs in-process with
`serve --nats` (below).

Before you build a dashboard on these:

**`stone_age_records{collection="things"}` counts configured devices.** It does
not measure availability, and an alert on it never fires. Per-site liveness is
in `agent_*` on the edge box ([§5](#5-the-edge-agent)). Whether a site's leaf
node is *connected* comes from asking the hub over a tenant's own NATS
connection ([Leaf Nodes §7](./leaf-nodes.md#7-is-the-site-up)).

**`stone_age_database_size_bytes` is the database only.** Uploaded files
(photos, floor plans, logos) are in `pb_data/storage` and in every backup, but no
series here measures them. Watch that directory with your host's disk metrics.

**No metric has a per-organization label.** `/metrics` is open by default, so a
tenant label would put a customer name next to an inventory count. For the same
reason, `stone_age_certificate*` reports the *soonest expiry per kind*, not one
series per certificate. A per-host series would need an identifying label.

**A collector that fails emits nothing, not zero.** Zero is a valid value, such
as "no Nebula hosts configured". Zero on failure would give a wrong answer, and
an alert on `== 0` would fire for the wrong reason. When the database collector
fails, `stone_age_collector_errors` is non-zero. The certificate collector does
not raise that counter. Its series are just absent, so pair any certificate alert
with `absent(stone_age_certificates)` if a gap matters to you.

### The `route` label is a pattern, never a path

Request paths have record ids (`/api/collections/things/records/abc123def456789`).
A path label would create a new series for each record, which on this platform
is one series per device per method. The label is the *matched route pattern*,
or `other`.

`status` is a class (`2xx`, `4xx`, `5xx`, or `unknown` for the rare request
that ends with neither a status nor an error), not an exact code. PocketBase
returns `404` when an update rule rejects and `400` on a denied create, so a
count of 404s would mix authorization, traffic and missing records. An alert
needs the class. The [audit log](./authorization.md#5-two-histories-the-audit-log-and-the-activity-feed)
has the details.

### Embedded NATS series

With `serve --nats`, the in-process bus exports its own counters:
`stone_age_nats_embedded_up`, `_connections`, `_cluster_routes`,
`_leafnode_connections`, `_slow_consumers_total`, `_msgs_total{direction}`,
`_bytes_total{direction}`, `_jetstream_bytes{tier}`.

With an **external** NATS server, these series are absent, not zero, so a quiet
bus and a missing one look different. Scrape an external server with
`prometheus-nats-exporter`, which reads its monitoring port and reports much
more.

> `stone_age_nats_leafnode_connections` counts leaf sessions **across every account**. It is a capacity number, not a per-tenant availability signal. A tenant checks its own sites with `$SYS.REQ.ACCOUNT.PING.CONNZ`, which is scoped to its account. See [Leaf Nodes §7](./leaf-nodes.md#7-is-the-site-up).

---

## 4. Certificate Expiry

Nebula certificate expiry is the **one** expiring credential the Control Plane
can check itself. Every other one is in a tenant's NATS account or on an edge
box. The Control Plane signed the Nebula certificates and stores them, with
their expiry, in its own database.

A Nebula certificate fails silently, on a date nobody watches, and all at once.
A CA with a ten-year validity expires long after everyone forgot it, and every
host in the mesh stops with it, including the path you would use to fix it.

**Alert relative to `time()`, and give the CA a longer horizon:**

```promql
stone_age_certificate_expiry_seconds{kind="nebula_host"} - time() < 30 * 86400
stone_age_certificate_expiry_seconds{kind="nebula_ca"}   - time() < 90 * 86400
```

The gauge is an absolute timestamp so that this works. A "days remaining" gauge
is out of date as soon as it is stored. With the horizon in the alert, you can
change the threshold in one place.

`kind` is `nebula_ca` or `nebula_host`. **The CA gets 90 days, not 30.** Every
host certificate chains to it. You can reissue a host certificate at once, but a
CA needs a staged *rotation* with a wait in the middle, which does not fit well
in 30 days. `stone_age_certificates_expiring`, the readiness check and the
console all use 30 days for a host and 90 for a CA. Host counts include only
`active = true` rows, so a decommissioned device's expired certificate pages
nobody.

The check **warns and never fails**. A readiness failure means "stop sending
this node traffic", and an expired *device* certificate is no reason to take
the console out of a load balancer.

> The check and the metrics use the same database scan, so they always agree. The console shows the same dates per record on the NATS Users and Nebula Hosts lists. See the credential-expiry items in [Operations §7](./operations.md#7-production-checklist).

---

## 5. The Edge Agent

The [Agent](./agent.md) serves the same two endpoints from its own registry,
under the `agent` namespace. **You see per-site health in detail here.** The
Control Plane cannot see it ([§1](#1-why-this-exists-at-all)). The Agent keeps
answering when the WAN is down. `cmd.health` goes over NATS, the link that
fails, so you most need a local answer from the box that has gone quiet.

It is **on by default, on loopback**: `observability.addr` defaults to
`127.0.0.1:9100`. Set it empty to serve neither endpoint:

```yaml
observability:
  addr: "127.0.0.1:9100"    # the default; "" = no listener at all
  metrics_token: ""         # set this before moving addr off loopback
  interval: 15s
```

The paths are `/ready` and `/metrics`, with no `/api` prefix. With an empty
`addr`, the checks still run and log. A bind failure is logged, not fatal, so
the agent keeps working if the monitoring port cannot bind.

::: warning 9100 is also node_exporter's port
On Linux and FreeBSD, the default port conflicts with `node_exporter` if you run
one on the same box. Move one of them. A bind failure is only logged, so the
symptom is a scrape target that never comes up, not a crash. `windows_exporter`
uses 9182, so Windows is not affected.
:::

Every Agent has these checks, gateway or not:

| Check | State when it trips | Notes |
|---|---|---|
| `nats` | **fail** | The agent's own NATS connection is down. This is the only check whose failure means the agent is not doing its job. |
| `jetstream` | **warn** | JetStream is not usable on the connected server, so telemetry goes nowhere. Heartbeats and commands still work. |
| `nats_permissions` | **warn** | The server refused a subject that the agent's credential does not allow, since the agent last connected. The detail quotes the server's message. Everything else still works. Add the subject to the agent's NATS role. |
| `task_metrics` | **warn** | More than half the system-metrics collections failed. Skipped when metrics are disabled. |
| `nebula` | **warn** | The overlay is enabled but not running, is using its cached config, or has no tunnels. Skipped when the overlay is off. |
| `platform_sync` | **warn** | No recent successful credential sync with the platform. The session token expires after seven days without one. Skipped when the agent does not get its credentials from the platform. |

A gateway (an Agent that runs a leaf) has three more:

| Check | State when it trips | Notes |
|---|---|---|
| `nats_local` | **fail** | The agent is not connected to the local leaf, the bus that this site's devices use. |
| `hub_uplink` | **warn** | No outbound leaf connection to the hub. The site is *cut off*. |
| `sync` | **warn** | A declared KV bucket is not syncing, or a relay has a backlog ([Leaf Nodes §6](./leaf-nodes.md#6-offline-autonomy-and-kv-bucket-sync)). |

These three exist only where there is a leaf.

**A cut-off edge warns. It does not fail.** Local NATS still works and devices
keep running, which is why a leaf node exists. A `503` would make an
orchestrator restart a site that is working correctly. `sync` warns for the same
reason: a relay backlog on a cut-off site is expected.

Metrics: every Agent exports `agent_ready`, `_check_state`,
`_check_timestamp_seconds` and `_build_info`. A gateway adds
`agent_edge_nats_connected`, `agent_edge_nats_connections`,
`agent_edge_hub_uplink_connected` and `agent_edge_jetstream_bytes`.

**Watch `agent_edge_sync_up{bucket,direction}` when you declare buckets by
hand.** It has one series per declared bucket per direction. A skipped entry
would otherwise look like a healthy agent. The usual cause is a mirror whose
hub-side bucket was never created. `agent_edge_relay_pending{bucket}` is the
backlog depth. If it rises while `hub_uplink` warns, an outage is draining
normally. If it rises while the uplink is fine, investigate.

The server-derived rows come from the leaf's own **loopback** monitoring port,
so the edge reads its own server with no `$SYS` user credential. If that port
is unreachable, the rows are **left out**, not reported as zero. Zero would say
"a cut-off site with no devices", which is a much stronger claim than "not
scraped". In the check registry, `skipped` also ranks *below* `ok`, so an
all-skipped report does not look healthy. See [Leaf Nodes](./leaf-nodes.md).

---

## 6. Scraping It

```yaml
scrape_configs:
  - job_name: stone-age-control-plane
    static_configs:
      - targets: ["control-plane:8090"]
    # only if metrics.token is set
    authorization:
      credentials: "<metrics.token>"

  - job_name: stone-age-edge
    static_configs:
      - targets: ["site-01:9101", "site-02:9101"]
```

The edge targets use **9101**, not the default 9100. This avoids
`node_exporter`, and a scrapeable target means `addr` is already off loopback.
Set `metrics_token` when you do that. These endpoints have no per-organization
labels, but they show a named device's health, and `/metrics` is open when the
token is empty.

The default `metrics_path` is `/metrics`, where both binaries serve. Use the same
stack as for [Layer 3](./observability.md). VictoriaMetrics speaks the
Prometheus API, so this is a second `scrape_config`, not a second system.

Suggested alerts:

| Alert | Expression |
|---|---|
| Not ready | `stone_age_ready == 0` |
| A specific check failing | `stone_age_check_state{state="fail"} == 1` |
| Prober stuck | `time() - stone_age_check_timestamp_seconds > 120` |
| Host certificate expiring | `stone_age_certificate_expiry_seconds{kind="nebula_host"} - time() < 30 * 86400` |
| CA expiring | `stone_age_certificate_expiry_seconds{kind="nebula_ca"} - time() < 90 * 86400` |
| Database growth | `predict_linear(stone_age_database_size_bytes[6h], 7 * 86400) > <your disk>` |
| Edge prober stuck | `time() - agent_check_timestamp_seconds > 120` |
| Site cut off | `agent_edge_hub_uplink_connected == 0` |
| Site bus down | `agent_edge_nats_connected == 0` |

A **warning** raises no alert here, and `stone_age_ready` stays `1`. Warnings are
for a person who reads `/api/ready` after a deploy, or for a dashboard panel,
not for a pager.

---

## 7. Configuration

| Key | Default | Purpose |
|---|---|---|
| `readiness.interval` | `15s` | How often the background prober runs the checks. |
| `readiness.timeout` | `5s` | Deadline for one full probe. |
| `metrics.enabled` | `true` | Register `GET /metrics`. |
| `metrics.token` | `""` | Shared secret. Empty means open. |

Edge agent: `observability.addr` (empty means disabled),
`observability.metrics_token`, `observability.interval`.

Each has a `STONE_AGE_` environment override, such as
`STONE_AGE_METRICS_TOKEN` or `STONE_AGE_READINESS_INTERVAL`. See
[Configuration §3](./configuration.md#3-environment-variable-overrides).

---

## 8. Where to Go Next

- Telemetry history: [Observability](./observability.md)
- The production checklist: [Operations §7](./operations.md#7-production-checklist)
