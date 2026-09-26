# Observability

Observability is **Layer 3** of the Stone-Age.io platform — the tier that answers questions about the past. While the substrate (Layer 0) handles live state, the rule engine (Layer 1) handles reflexes, and stream processors (Layer 2) handle real-time analytical computation, Layer 3 is the historical record. It's what lets you ask "what happened last Tuesday" or "how has this trended over the last month."

For the complete layer model and graduation criteria, see [Platform Layers](./platform-layers.md).

One of the core tenets of Stone-Age.io is the **"Bring Your Own" (BYO)** philosophy for long-term data storage. We focus on providing an excellent substrate and live-path experience, while leaving historical storage to industry-leading time-series databases that are optimized for exactly that job.

---

## 1. The "Bring Your Own" Philosophy

Traditional IoT platforms often bundle a time-series database directly into their core binary. This inevitably leads to architectural bloat, poor performance, and difficult maintenance.

**Stone-Age.io takes a different approach:**

- **Layers 0–2 (live path):** Focus on **present state** and **reflexive behavior**. They answer: *"What is happening right now? What should I do about it?"*
- **Layer 3 (BYO):** Focuses on **history and trends**. Answers: *"What happened last Tuesday? How has this changed over time?"*

Because all layers communicate through NATS subjects, Layer 3 is a **pure consumer**. It can fail, be taken offline for maintenance, or be entirely replaced — none of which affects the operational path of Layers 0–2.

> **This page is about your TELEMETRY, not about the platform's own health.** Layer 3
> answers "what did my devices report last Tuesday". The question "is my Control
> Plane in a state where it can do its job, and is that edge site still syncing"
> is answered by the binaries themselves, on `GET /api/ready` and `GET /metrics`
> — unauthenticated, no NATS connection needed, and scraped by the same
> Prometheus-compatible stack described below. See
> [Health & Metrics](./health-metrics.md).

> **The audit log is a different thing entirely.** Layer 3 is the history of your *telemetry*. The history of *administrative changes* — who created a Thing, who rotated a credential — lives in the Control Plane, in **two** collections: `audit_logs`, the forensic trail — the names of the fields every change touched, plus full before/after values for an allowlist of collections that deliberately excludes everything credential-bearing — restricted to **Platform Operators** (no tenant role, not even `owner`, can query it); and `activity`, an org-scoped feed of actor, action and record that every role can read and that carries no values at all. Audit retention is configured under `audit.retention` in `config.yaml` ([Configuration §2](./configuration.md#2-section-reference)); the boundary between the two is described in [Authorization §5](./authorization.md#5-two-histories-the-audit-log-and-the-activity-feed). Either way, don't plan to satisfy a compliance request for an admin-change trail out of your TSDB.

---

## 2. The Suggested Stack 

If you do not have an existing observability stack, we recommend the following based on speed, simplicity, and efficiency. Each component below is its own single-binary process — you deploy them alongside your NATS cluster and they connect as NATS clients.

> **A reference deployment is on the roadmap.** We're planning to publish a "Stone-Age Reference Stack" — an opinionated Docker Compose (and/or systemd unit file) bundle that provisions the Control Plane, NATS, Nebula Lighthouse, rule-router, Telegraf, VictoriaMetrics, and Grafana with preconfigured dashboards, so teams who don't want to make architectural decisions on day one can get a complete working stack in one command. Until then, the sections below describe the pieces you'd assemble yourself.

### A. Telegraf 

**Telegraf** is a lightweight agent used for collecting and reporting metrics. In our ecosystem, it acts as the bridge between NATS and your database.

- **NATS Consumer:** Telegraf subscribes to your NATS subjects (e.g., `telemetry.>`) as an ordinary NATS client, authenticated with a `.creds` file like any other. One organization's account is one tenant, so it is one Telegraf process per organization.
- **Parsing:** It converts NATS JSON payloads into metrics.
- **Output:** It pushes those metrics to your storage engine.

### B. VictoriaMetrics 

**VictoriaMetrics** is a time-series database that is fully compatible with the Prometheus API.

- **Operationally simple:** Like Stone-Age.io, VictoriaMetrics ships as a single binary and runs comfortably on modest hardware.
- **Retention:** Use it to store months or years of historical data.
- **Vmalert:** This component allows you to execute "recording rules" or "alerting rules" against historical data (e.g., *"Alert if the average temperature over the last 24 hours is 10% higher than the previous week"*).

### C. Perses.dev 

While the Stone-Age.io Platform Dashboard is perfect for operational control, **Perses** (or Grafana) is ideal for historical analysis.

- **Standardized:** Perses is an open-standard dashboard engine.
- **Deep Dives:** Use it to build long-term trend reports, heatmaps, and complex comparative charts from VictoriaMetrics.

---

## 3. Data Flow Architecture

A typical production pipeline follows this path:

1.  **Agent / Device:** Collects local metrics (CPU, Temp, etc.) and publishes to NATS.
2.  **NATS Cluster:** Routes the data to real-time UI widgets, and into a JetStream stream where one covers the subject.
3.  **Telegraf:** Subscribes to the subjects and parses each message into metrics.
4.  **VictoriaMetrics:** Receives data from Telegraf as InfluxDB line protocol.
5.  **Perses/Grafana:** Queries VictoriaMetrics to render historical graphs.

**What survives what:**

- **The TSDB goes down.** Telegraf keeps collecting and holds a bounded buffer of metrics in memory (`metric_buffer_limit`), flushing it when the database returns. Past that limit the oldest are dropped, so a long outage leaves a gap.
- **Telegraf goes down.** A plain subscription like the example below misses whatever was published meanwhile — core NATS holds nothing for a subscriber that is not there. If a gap-free history matters, put a JetStream stream over those subjects and ingest from the stream rather than from the live subject, so the stream's retention is what covers the outage. Telegraf's `nats_consumer` plugin has JetStream options for this; check its documentation for your version before relying on them.
- **Either way, the live path — dashboards, alerts, Layer 1 rules — is completely unaffected.**

<center>
```mermaid
flowchart LR
    Source["<b>Edge Device</b>"] 
    
    subgraph Platform ["Layers 0-2 (Live Path)"]
        Bus{"<b>NATS JetStream</b>"}
        UI["<b>Console UI</b><br/>Live Widgets"]
        KV[("<b>NATS KV</b><br/>Digital Twin")]
    end

    subgraph BYO ["Layer 3 — BYO Observability"]
        Telegraf["<b>Telegraf</b><br/>Consumer"]
        TSDB[("<b>VictoriaMetrics</b><br/>History")]
        Grafana["<b>Grafana/Perses</b><br/>Analysis"]
    end

    %% Flow
    Source --> Bus
    
    %% Hot Path
    Bus --> UI
    Bus --> KV
    
    %% Cold Path
    Bus --> Telegraf
    Telegraf --> TSDB
    TSDB --> Grafana

    class Bus,UI,KV platform;
    class Telegraf,TSDB,Grafana byo;
    
    %% Hot Path Styling (Red)
    linkStyle 1 stroke:#ef4444,stroke-width:2px;
    linkStyle 2 stroke:#ef4444,stroke-width:2px;
    
    %% Cold Path Styling (Blue)
    linkStyle 3 stroke:#3b82f6,stroke-width:2px;
    linkStyle 4 stroke:#3b82f6,stroke-width:2px;
    linkStyle 5 stroke:#3b82f6,stroke-width:2px;
```
</center>

---

## 4. Example Telegraf Configuration

To begin ingesting data from the Data Plane, configure Telegraf with a NATS input and a VictoriaMetrics output:

```toml
[[inputs.nats_consumer]]
  ## NATS Servers to connect to
  servers = ["nats://nats.acme.io:4222"]

  ## The server runs in operator mode, so Telegraf needs a credential.
  ## Create a NATS user for it in the organization and download its .creds.
  ## It only subscribes, so give it a role with no publish rights.
  credentials = "/etc/telegraf/acme-telegraf.creds"

  ## Subjects to consume. One input is one NATS connection, and connections
  ## count against the organization's account limit, so list every reading
  ## subject here rather than adding a second input.
  subjects = ["temp-probe.*.temperature", "temp-probe.*.battery"]

  ## Only matters if you run more than one Telegraf against this account:
  ## instances sharing a queue group split the load instead of duplicating it.
  ## It does not make the subscription durable.
  queue_group = "telegraf-acme"

  ## Data format to expect from your Things/Agents
  data_format = "json"

## The Thing's code, out of the subject. On the default layout,
## {thing_type_code}.{thing}.{operation}, it is the second token.
[[processors.regex]]
  [[processors.regex.tags]]
    key = "subject"
    pattern = '^[^.]+\.(?P<thing>[^.]+)\.'

[[outputs.http]]
  ## VictoriaMetrics accepts InfluxDB line protocol and turns
  ## `measurement,tags field=value` into `measurement_field{tags}`.
  url = "http://victoria-metrics:8428/influx/write"
  data_format = "influx"
  tagexclude = ["subject"]
```

`outputs.http` rather than `outputs.influxdb` is deliberate: the InfluxDB output appends a `db=` parameter to every write, and VictoriaMetrics turns it into a constant `db` label on every series. The platform repository carries a fuller, working example in `demo/telegraf/`.

**Readings carry `thing` and nothing about where it is.** A code never changes, and a location does. A `location` tag written at ingestion is fixed forever, so a moved Thing's history stays where it was, and correcting a wrong location never reaches the readings already stored. Location comes from the inventory instead, joined at query time. See the next section.

---

## 5. Where Things Are: Joining Against the Inventory

Long-term charts want a legend that says "Dock 3 camera", not `CA-9KD-4PX`, and they want to group by site. Both live in the platform, not in the reading. [ADR 0004](decisions/0004-long-term-data-and-location-path.md) gets them into the TSDB as two **info series**, one series per record, value `1`, with the record's details as labels:

| Series | Labels |
|---|---|
| `stone_thing_info` | `thing`, `name`, `thing_type`, `location`, `location_path` |
| `stone_location_info` | `location`, `name`, `location_type`, `location_path` |

`location_path` is the Location's [path](platform-ui-entities.md#2-locations): its code and every ancestor's, from the root down, like `/KC/BD-3/RM-204/`.

### The pipeline

It runs inside the tenant's own account, with tools the tenant already runs. There is no platform route and no new kind of credential:

```
nats-auth-manager ──► KV tokens.pocketbase           signs in as a viewer, keeps the token fresh
rule-router, every minute:
    GET the standard list API ──► inventory.things, inventory.locations
rule-router, on each: forEach item, merge {"info": 1}
    ──► inventory.thing.<code>, inventory.location.<code>
Telegraf ──► VictoriaMetrics                           stone_thing_info, stone_location_info
```

- **A viewer service login, one per organization.** Every list rule scopes by its current organization, so the poll needs no filter, and the token it holds can read the inventory and change nothing.
- **The whole inventory goes out every minute.** Nothing is stateful. A missed poll is covered by the next, and a moved Thing shows its new location within a minute.
- **The platform repository has a working copy** in `demo/inventory/`, with its own README.

### The join

```
avg by (location) (
  thing_celsius
    * on(org, thing) group_left(name, location, location_path)
      (stone_thing_info @ end())
)
```

Join on `(org, thing)`, because a code is unique only inside its organization. `@ end()` reads the inventory once, at the end of the range, and applies it to every reading in the range:

- **No reading is lost when a Thing moves.** Only the place it is attributed to follows the Thing to where it is now.
- **Corrections apply backwards.** Fix a wrong location and every past reading picks up the right one.

"Where was it on Tuesday" is deliberately not the default. A Thing whose past location matters, like a trailer, should report its location in its own payload, where it is the reading's data and not a join.

| Want | How |
|---|---|
| Everything under one place | `stone_thing_info{location_path=~".*/KC/.*"}` in the join. PromQL regexes match the whole value, hence `.*` at each end. |
| One line per location inside it | The same, inside `avg by (location)`. |
| Buildings side by side | A variable from `label_values(stone_location_info{location_type="building"}, location)` and a repeated panel, each filtering by path. |

### Limits to know

- **A move takes up to a minute to show.** That's the poll interval.
- **For a few minutes after a move, a panel whose range ends now can fail** with a duplicate-series error: until the old info series goes stale, two of them match the Thing. It clears without anyone doing anything.
- **One poll returns at most 1000 records** (PocketBase's page ceiling). The demo's guard rule publishes on `inventory.truncated` when an organization has more; past that, the feed needs paging.
- **The token bucket holds a live PocketBase token.** Anything in the account that can read KV can use it, which is why the login must be a viewer. A subject deny does not fully close this for a role holding `$JS.API.>`, which can source the bucket into a stream of its own.

---

## 6. Closing the Loop — Alerts From Historical Analysis

Layer 3 isn't just a read-only archive. Historical alerts (via vmalert or Grafana alerting) can publish *back* into NATS — typically by POSTing to the rule engine's Gateway feature — where Layer 1 rules pick them up and route them like any other event.

This completes the loop:

1.  Events flow out from devices (Layer 0) through Layer 1 rules and Layer 2 stream processors to Telegraf and into VictoriaMetrics (Layer 3).
2.  Vmalert or Grafana evaluates alerting rules against historical data.
3.  Alert notifications are POSTed to the rule engine's Gateway feature.
4.  A Layer 1 rule translates the inbound webhook into a NATS event on a well-defined subject.
5.  Existing alert-routing rules (Slack, PagerDuty, etc.) handle the event just like any other alert.

Your alerting pipeline — short-term and long-term — converges on the same subject contracts. You don't maintain two separate notification systems.

---

## 7. Summary

By decoupling observability from the core platform, Stone-Age.io stays:

1.  **Fast:** The core binary is not bogged down by heavy disk I/O.
2.  **Flexible:** You can switch from VictoriaMetrics to InfluxDB, Snowflake, or SQL without changing any code in Layers 0–2. The subject contracts stay stable; only the Layer 3 consumer changes.
3.  **Scalable:** You can scale your storage independently of your Control Plane as your device count grows.
4.  **Resilient:** Layer 3 failures never affect Layers 0–2. The operational pipeline keeps running; only historical recency lags until the TSDB returns.

For the layer model in full, see [Platform Layers](./platform-layers.md). For the Layer 1 alerting patterns that hand off to Layer 3, see [Automation](./automation.md). For the platform's own readiness checks and process metrics — a second `scrape_config` for the same stack, not a second system — see [Health & Metrics](./health-metrics.md).
