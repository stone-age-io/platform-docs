# Health & Metrics

Every Stone-Age.io binary answers two questions about **itself**, without a login and without a NATS connection:

- `GET /api/ready` — a readiness report in JSON, `200` or `503`.
- `GET /metrics` — a Prometheus exposition.

This is a different subject from [Observability](./observability.md). That page is about the history of your *telemetry* — what your devices reported, stored in a time-series database you bring yourself. This page is about the *processes*: is the Control Plane in a state where it can do its job, and is the edge agent still syncing.

---

## 1. Why This Exists At All

PocketBase already serves `/api/health`, and it is correct as far as it goes: the HTTP server is listening. The trouble is that this is **also true of every interesting failure this platform has.**

A Control Plane serving cheerful `200`s while:

- the NATS server does not trust its operator, so every account claim is rejected, no organization's account ever reaches the bus, and the console looks completely normal;
- `bootstrap` was run before `migrate up`, so every tenancy flag was silently dropped and the install has no Platform Operator — a dead deployment that serves pages;
- `nats.websocket_urls` was never set, so the console works on the server and for nobody else;
- a Nebula CA expired last week and every host in the mesh went with it.

None of that moves a liveness probe. So the checks here are deliberately about **the things that are silently wrong**, not about whether the process is up.

> **Liveness and readiness have different consequences.** Liveness failing should restart the process. Readiness failing should stop *sending it traffic*. Overloading one endpoint with both would mean a container restart loop every time NATS was briefly unreachable — which fixes nothing and takes the console down with it. That is why this is `/api/ready` and not an extension of `/api/health`.

### The rule that shapes the list

**A check must be answerable first-hand by the process running it.**

This is the NATS account boundary restated. The Control Plane holds the NATS operator and the `$SYS` account, and it has **no user credential inside any organization's account** — so it cannot read an org's `twin` KV, and it cannot read anything a site reports about itself. The console can, because a browser connects as the logged-in user — which is also how it answers whether a site's leaf node is attached, by asking the bus over that same connection. The Agent can, because it runs inside the account.

Do not "improve" a check by minting the platform a credential in a tenant's account. That turns a credential issuer into a data-plane participant in every tenant's bus, which is the one boundary the whole NATS design is built around. Per-site liveness is therefore **absent** from the Control Plane's list on purpose, and lives on the edge instead ([§5](#5-the-edge-agent)).

---

## 2. `GET /api/ready`

Unauthenticated, and serves one body to everyone. The callers are container orchestrators, load balancers and uptime checkers, none of which hold a PocketBase session. Closing it off is a reverse proxy's job.

```
$ curl -s http://localhost:8090/api/ready | jq
```

```json
{
  "ready": false,
  "state": "fail",
  "version": "v0.4.0",
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

Checks are sorted by name, so the body diffs cleanly between probes.

**`fix` is the field that earns this endpoint.** These reports are read by someone who has just deployed the binary and does not yet know the bootstrap order. `"operator not seeded"` sends them to a search engine; the line above ends the incident.

### The four states

| State | Ready? | HTTP | Means |
|---|:-:|:-:|---|
| `ok` | yes | 200 | Checked, nothing to say. |
| `warn` | **yes** | **200** | Running but misconfigured. Works today; a human should still fix it. |
| `fail` | no | 503 | Stop sending this process traffic. |
| `skipped` | yes | 200 | This check did not apply, or could not look. |

Two of these surprise people:

**`warn` returns 200 deliberately.** A probe's only lever is to restart or de-register the process, and neither fixes "you have not set an encryption key" — it would just take a working deployment offline over a note. Failing on warnings would also refuse to serve the stock development deployment, which is legitimately in this state.

**`skipped` ranks *below* `ok`, not above it.** It is the absence of an answer, never a better one. The top-level `state` is the worst state across all checks, seeded from the results rather than from `ok` — otherwise an all-skipped report would read as a clean bill of health.

`ready` is `false` if and only if some check **failed**. `state` is there so a caller can tell "ready, but look at this" from "ready, nothing to report".

### Control Plane checks

| Check | Fails when | Notes |
|---|---|---|
| `database` | SQLite will not answer `SELECT 1` | `pb_data/` unwritable, or held by another running instance. |
| `schema` | `schema.json` was never imported | Catches a build whose `//go:embed` did not take: the libraries' collections exist, none of the platform's fields do, and the migrations table says everything ran. |
| `schema_version` | the database has migrations **this binary does not know** | A *downgrade*. See below. |
| `bootstrap` | no user has `is_operator`, or no org has `is_system_org` | A platform nobody can create an organization in. |
| `nats_operator` | no NATS operator record, or it has no JWT | Nothing can sign an account or user JWT. |
| `nats_reachable` | nothing is listening on `nats.server_url` | Warns instead if JetStream is disabled. |
| `nats_trust` | the server there **rejects this database's `$SYS` credential** | The silent killer. See below. |
| `nebula_cert_expiry` | never — warns only | Certificates the platform signed. See [§4](#4-certificate-expiry). |
| `nats_websocket_urls` | never — warns only | Empty means the console falls back to `ws://localhost:9222`. |
| `encryption_at_rest` | never — warns only | `nats.encryption_key` / `nebula.encryption_key` unset. |

Three are worth expanding on.

**`nats_trust` is the check that earns the feature.** It connects to `nats.server_url` using the `$SYS` credential from the database. A server whose `nats.conf` carries a *stale operator JWT* rejects it — and that failure is otherwise invisible: every account claim the platform publishes is refused, no organization's account reaches the bus, devices cannot connect, and every screen in the console renders correctly.

Reachability is a **separate** check on purpose, because "nothing is listening" and "listening but does not trust us" have entirely different fixes.

**`schema_version` looks for a downgrade, not for pending migrations.** `serve` runs all migrations before it listens, so "migrations pending" can never be true by the time anything could probe — and a check that can only ever report `ok` is a green tick that means nothing. *Ahead* is the half `serve` cannot fix: migrations do not roll back, so an older binary pointed at newer `pb_data` keeps running against columns and rules it does not know about, and the symptom is arbitrary.

**`nats_reachable` reads `nats.server_url`, which is not the browser's address.** `server_url` is the TCP address *this process* dials; `websocket_urls` is what a *browser* dials, on a different port and often a different host. Never derive one from the other — see [Configuration §2.1](./configuration.md#21-server_url-and-websocket_urls-are-different-addresses).

### The prober caches; the endpoint never runs checks

A background prober runs the checks every `readiness.interval` and the endpoint serves the last snapshot. This is not an optimisation — it is what keeps the endpoint safe to probe:

- Running checks per request would trigger a NATS dial on every probe.
- A slow check would make the endpoint slow, which reads as *unready*, which kills a perfectly healthy container.

The response carries `Cache-Control: no-store`, and `checked` tells you how old the answer is. Before the first probe completes you get a `503` whose body says `"readiness has not been probed yet"` — deliberately distinguishable from a failing check.

A panicking check is caught and reported as a failure rather than taking the process down. A diagnostic is the last thing that should be able to crash the thing it is diagnosing.

---

## 3. `GET /metrics`

Prometheus text format, from the standard client library. Open by default; set `metrics.token` to require a credential, or `metrics.enabled: false` to remove the route.

> **`/api/ready` is always registered.** Only `/metrics` respects `metrics.enabled` — readiness is a contract with your orchestrator, and a deployment that had quietly disabled it is one nobody could explain later.

### Authentication

`/metrics` deliberately does **not** use PocketBase auth. PocketBase tokens are JWTs that expire and no scraper has a refresh flow, so it would take a custom sidecar to read a standard format.

Instead `metrics.token` is accepted two ways, which between them cover every scraper in use:

```
Authorization: Bearer <token>          # Prometheus bearer_token
Authorization: Basic <any>:<token>     # basic_auth — the username is ignored
```

A `401` carries `WWW-Authenticate: Basic realm="metrics"`, so a browser offers a prompt and a misconfigured scrape fails legibly rather than silently.

### Readiness, as metrics

The checks above are exported as a **state set** — one series per check per state, `1` on the current one:

```
stone_age_ready 0
stone_age_check_state{name="database",state="ok"} 1
stone_age_check_state{name="database",state="fail"} 0
stone_age_check_state{name="database",state="warn"} 0
stone_age_check_state{name="database",state="skipped"} 0
stone_age_check_timestamp_seconds 1.7573e+09
stone_age_build_info{version="v0.4.0"} 1
```

A state set rather than a number, because a numeric encoding of "ok/warn/fail/skipped" makes every query a decoder ring, and adding a state later would silently change the meaning of stored data.

**Alert on `stone_age_check_timestamp_seconds` going stale.** That is the prober itself being wedged — which no other series can tell you, because they would all keep reporting their last known values.

### Platform metrics

| Metric | Type | Labels | What it is |
|---|---|---|---|
| `stone_age_records` | gauge | `collection` | Rows in a platform collection. |
| `stone_age_inactive_records` | gauge | `collection` | Rows with `active = false` — decommissioned devices and leaf nodes. |
| `stone_age_nats_users_revoked` | gauge | | Users whose key is on their account's revocation list. |
| `stone_age_database_size_bytes` | gauge | | `data.db` plus its WAL. The number to alert on for disk growth. |
| `stone_age_certificates` | gauge | `kind` | Nebula certificates in service. |
| `stone_age_certificates_expired` | gauge | `kind` | Expiry already passed. |
| `stone_age_certificates_expiring` | gauge | `kind` | Expiring within the warning window. |
| `stone_age_certificate_expiry_seconds` | gauge | `kind` | **Unix timestamp** of the soonest expiry of that kind. |
| `stone_age_http_requests_total` | counter | `route`, `method`, `status` | Requests served. |
| `stone_age_http_request_duration_seconds` | histogram | `route`, `method` | Request latency. |
| `stone_age_collector_errors` | gauge | | Collectors that failed **during this scrape**. |

Plus `stone_age_nats_*` when — and only when — the bus runs in-process via `serve --nats` (below).

Three things to know before building a dashboard on these:

**`stone_age_records{collection="things"}` counts devices CONFIGURED.** It is not availability, and an alert on it can never fire. Per-site liveness is `agent_*` on the edge box ([§5](#5-the-edge-agent)); whether a site's leaf node is *attached* is answered by the console asking the hub, not by anything here ([Leaf Nodes §7](./leaf-nodes.md#7-is-the-site-up)).

**There are no per-organization labels, anywhere.** `/metrics` is open by default, and with per-org data reduced to row counts a tenant label would be a customer name attached to an inventory count. That is also why `stone_age_certificate*` reports the *soonest per kind* rather than one series per certificate: a per-host series would need an identifying label to be useful, which is a per-tenant device inventory.

**A collector that fails emits nothing rather than zero.** Zero is a legitimate value here — "no Nebula hosts configured" — so reporting it on failure would turn a broken query into a confident wrong answer, and an alert on `== 0` would fire for the wrong reason. The absent series plus a non-zero `stone_age_collector_errors` says what actually happened.

### The `route` label is a pattern, never a path

Request paths carry record ids (`/api/collections/things/records/abc123def456789`). Labelling by path would mint a new time series per record touched — and on a platform whose job is holding per-device rows, that is one series per device per method. The label is the *matched route pattern*, falling back to `other`.

`status` is a class (`2xx`/`4xx`/`5xx`), not an exact code. PocketBase answers `404` when an update rule rejects and `400` on a denied create, so "how many 404s" would be a question about authorization, traffic and genuinely missing records all at once. The class is what an alert wants; the [audit log](./authorization.md#5-the-audit-log-is-platform-operator-only) has the specifics.

### Embedded NATS series

With `serve --nats`, the in-process bus's own counters are exported: `stone_age_nats_embedded_up`, `_connections`, `_cluster_routes`, `_leafnode_connections`, `_slow_consumers_total`, `_msgs_total{direction}`, `_bytes_total{direction}`, `_jetstream_bytes{tier}`.

With an **external** NATS server these series are absent entirely rather than reported as zero — a quiet bus and an absent one should not look alike. Scrape an external server with `prometheus-nats-exporter`, which reads its monitoring port and reports far more than this ever could.

> `stone_age_nats_leafnode_connections` counts leaf sessions **across every account**, so it is a capacity number rather than a per-tenant availability signal. A tenant asks about its own sites through `$SYS.REQ.ACCOUNT.PING.CONNZ`, which is scoped to its account — see [Leaf Nodes §7](./leaf-nodes.md#7-is-the-site-up).

---

## 4. Certificate Expiry

Nebula certificate expiry is the **one** expiring credential the Control Plane can check first-hand, and the exception proves the rule: every other one lives in a tenant's NATS account or on an edge box. Nebula certificates this process signed itself, and stores — expiry included — in its own database.

It matters because a Nebula certificate fails silently, on a schedule nobody is watching, and all at once. A CA minted with a ten-year validity lapses long after everyone who knew about it stopped thinking about it — and it takes every host in the mesh with it, including the out-of-band path you would have used to fix it.

**Alert relative to `time()`, not on a stored countdown:**

```promql
stone_age_certificate_expiry_seconds - time() < 30 * 86400
```

The gauge is an absolute timestamp precisely so this works. A "days remaining" gauge is stale the moment it is stored, and every retained sample drifts further from the truth; writing the horizon into the alert keeps the threshold somewhere you can change it.

`kind` is `nebula_ca` or `nebula_host`. **Put a separate alert on the CA** — every host certificate chains to it. Host certificates count `active = true` rows only, so a decommissioned device's lapsed certificate does not page anyone.

The check **warns and never fails**, for the same reason an islanded edge warns: readiness failing means "stop sending this node traffic", and a lapsed *device* certificate is no reason to pull the console out of a load balancer.

> The check and the metrics share one scan of the database, so a green tick can never sit beside a metric reporting an expiry. The console shows the same dates per record on the NATS Users and Nebula Hosts lists — see the credential-expiry items in [Operations §7](./operations.md#7-production-checklist).

---

## 5. The Edge Agent

The [Agent](./agent.md) serves the same two endpoints from its own registry, under the `agent` namespace. **This is where per-site health is actually visible in detail** — the Control Plane cannot see it, by design ([§1](#1-why-this-exists-at-all)) — and it keeps answering with the WAN down, which is exactly when you want it. `cmd.health` travels over NATS, the link that breaks; the box you most need to ask is the one that has just gone quiet.

It is **on by default, on loopback** — `observability.addr` defaults to `127.0.0.1:9100`. Set it empty to serve neither endpoint:

```yaml
observability:
  addr: "127.0.0.1:9100"    # the default; "" = no listener at all
  metrics_token: ""         # set this before moving addr off loopback
  interval: 15s
```

Paths are `/ready` and `/metrics` — no `/api` prefix, since this is not the PocketBase router. Empty `addr` serves neither, but the checks still run and still log; a bind failure is logged rather than fatal, because a monitoring port that cannot bind must not stop the agent doing its job.

!!! warning "9100 is also node_exporter's port"
    On Linux and FreeBSD the default collides with `node_exporter`, which [§3 of the Agent guide](./agent.md#3-capabilities) offers as an alternative metrics source. On a box running both, move one of them — and since a bind failure is only logged, the symptom is a scrape target that quietly never came up rather than a crash. `windows_exporter` uses 9182, so Windows is unaffected.

| Check | State when it trips | Notes |
|---|---|---|
| `nats_local` | **fail** | The agent is not connected to the local leaf — the bus the devices on this site actually use. |
| `hub_uplink` | **warn** | No outbound leaf connection to the hub: this site is *islanded*. |

**An islanded edge warns, it does not fail.** Local NATS still works and devices keep running — that autonomy is the entire reason a leaf node exists, so returning `503` would invert the design and have an orchestrator restart a site that is working exactly as intended.

Metrics: `agent_edge_nats_connected`, `agent_edge_nats_connections`, `agent_edge_hub_uplink_connected`, `agent_edge_jetstream_bytes` — plus the same `agent_ready` / `_check_state` / `_check_timestamp_seconds` / `_build_info` set.

The server-derived rows come from the leaf's own **loopback** monitoring port, which is how the edge reads its own server without ever holding a `$SYS` user credential. They are **omitted** when that port is unreachable rather than reported as zeros: zero would claim an islanded site with no devices, which is a far louder statement than "not scraped". The same rule governs the check registry, where `skipped` ranks *below* `ok` — a report that is entirely skipped must not read as a clean bill of health. See [Leaf Nodes](./leaf-nodes.md).

!!! note "There is no longer a sync-freshness check"
    Earlier versions of the edge agent mirrored an organization's config collections into local KV, and had `sync_freshness` and `sync_errors` checks over that loop. The mirror was removed — nothing consumed the mirrored rows — and those two checks went with it.

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

The edge targets are on **9101**, not the default 9100, for two reasons: it keeps
clear of `node_exporter`, and a scrapeable target means `addr` has been moved off
loopback anyway. Do that with `metrics_token` set — these endpoints carry no
per-organization labels, but they do carry a named device's health, and
`/metrics` is open when the token is empty.

The default `metrics_path` is `/metrics`, which is where both binaries serve. Point the same stack at these that you use for [Layer 3](./observability.md) — VictoriaMetrics speaks the Prometheus API, so this is a second `scrape_config`, not a second system.

A starting set of alerts:

| Alert | Expression |
|---|---|
| Not ready | `stone_age_ready == 0` |
| A specific check failing | `stone_age_check_state{state="fail"} == 1` |
| Prober wedged | `time() - stone_age_check_timestamp_seconds > 120` |
| Certificate expiring | `stone_age_certificate_expiry_seconds - time() < 30 * 86400` |
| Database growth | `predict_linear(stone_age_database_size_bytes[6h], 7 * 86400) > <your disk>` |
| Edge prober wedged | `time() - agent_check_timestamp_seconds > 120` |
| Site islanded | `agent_edge_hub_uplink_connected == 0` |
| Site bus down | `agent_edge_nats_connected == 0` |

Note that a **warning** raises no alert here, and should not: `stone_age_ready` stays `1`. Warnings are for a human reading `/api/ready` after a deploy, or for a dashboard panel — not for a pager.

---

## 7. Configuration

| Key | Default | Purpose |
|---|---|---|
| `readiness.interval` | `15s` | How often the background prober re-runs the checks. |
| `readiness.timeout` | `5s` | Deadline for one full probe. |
| `metrics.enabled` | `true` | Register `GET /metrics`. |
| `metrics.token` | `""` | Shared secret; empty means open. |

Edge agent: `observability.addr` (empty = disabled), `observability.metrics_token`, `observability.interval`.

All of these take `STONE_AGE_`-prefixed environment overrides — `STONE_AGE_METRICS_TOKEN`, `STONE_AGE_READINESS_INTERVAL`. See [Configuration §3](./configuration.md#3-environment-variable-overrides).

---

## 8. Summary

- `/api/ready` is for **your orchestrator, and for you right after a deploy**. It reports what is *silently* wrong, and every non-OK result carries the command that fixes it.
- `/metrics` is for **your monitoring stack**. Alert on `ready`, on individual check states, on the probe timestamp going stale, and on certificate expiry.
- Both are unauthenticated by default. `/metrics` takes a token; closing either off properly is a proxy's job.
- Only `fail` makes a process unready. `warn` means look, not evacuate.
- Every check is answerable by the process running it. Per-site health lives on the edge, and there are no per-tenant labels — both because of the NATS account boundary, not because they were hard.

For the telemetry-history side of monitoring, see [Observability](./observability.md). For the production checklist these endpoints feed, see [Operations §7](./operations.md#7-production-checklist).
