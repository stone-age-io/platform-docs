# Dashboards & Widgets

The Visualizer is the console's dashboard surface: a resizable grid of widgets, each bound to a NATS subject, a JetStream consumer, a KV key, or a PocketBase query. It is the screen you put in front of someone who does not administer the platform — an operator watching a site, or an unattended display in a control room.

Everything on it runs over **the browser's own NATS connection**. There is no server-side rendering step and no polling loop against the database: a value changes on the bus, and the widget bound to it updates. That also means a widget can only see what the caller's NATS credential permits, which is set per identity in [Connectivity](./connectivity.md) and is independent of the console role.

---

## 1. Where a dashboard lives

Dashboards are **not** PocketBase records. Each one is a JSON document with two possible homes, chosen per dashboard:

| Storage | Where | Who sees it |
| :--- | :--- | :--- |
| **Local** | the browser's `localStorage` | that browser only |
| **Shared** | a NATS KV bucket, `dashboards` by default | anyone whose credential can read the bucket |

Local is the default and needs nothing configured. Shared dashboards are how a team keeps one canonical view, and how an unattended screen gets its layout without someone building it there: the key name may contain dots, which the console renders as folders (`site-a.lobby`).

Because shared storage is a KV bucket rather than a collection, **access is governed by NATS permissions, not by API rules** — a credential that can write the `dashboards` bucket can edit every shared dashboard in it. Give an appliance login a read-only NATS role if you do not want it saving over the layout.

Local storage holds up to 25 dashboards, and the console warns as you approach that. Dashboards export and import as a single JSON file, which is the practical way to move one between deployments.

---

## 2. Data sources

Every data-bound widget picks one of three source kinds. Choosing the right one is most of getting a dashboard to behave.

| Kind | What it does | Reach for it when |
| :--- | :--- | :--- |
| `subscription` | A live core-NATS subscription. Fire-and-forget: you see messages published from the moment the widget mounts. | Telemetry, logs, anything where "now" is what matters. |
| `consumer` | A JetStream consumer, with a deliver policy (`all`, `last`, `new`, `last_per_subject`, `by_start_time`). | You need history on load — a chart that should not start empty. |
| `kv` | A KV key, watched for updates. | Current state rather than a stream of events: a setpoint, a status, a twin value. |

Two consequences worth internalizing:

- **A `subscription` widget is empty until the next message arrives.** On a subject that publishes every ten minutes, a freshly loaded dashboard looks broken for ten minutes. Use a `consumer` with `deliver_policy: last`, or a `kv` source, when the current value matters more than the event.
- **`consumer` and `kv` both need JetStream**, which the account must be entitled to. The `$SYS` account is not JetStream-enabled, which is one of the reasons [Getting Started](./getting-started.md) tells you not to run real workloads on it.

Widgets that buffer (charts, tables, the console) keep a bounded window — a maximum message count, optionally a maximum age. The buffer is per widget and lives in the browser; nothing is persisted.

---

## 3. The widget types

Seventeen of them. The grid is 12 columns wide, and each type has a sensible default size.

### Display

| Widget | What it shows |
| :--- | :--- |
| **Text** | The latest value, formatted. Supports threshold rules that recolour it by comparison (`>`, `>=`, `<`, `<=`, `==`, `!=`). |
| **Stat** | A KPI number with a trend indicator and a mini sparkline. |
| **Gauge** | A circular meter against a min/max range. |
| **Status** | State mapping plus a watchdog: maps values to labels and colours, and can go stale when nothing arrives within a timeout. |
| **Chart** | Line, bar, pie or gauge chart over time, rendered with ECharts. |

### Tables and records

| Widget | What it shows |
| :--- | :--- |
| **KV** | A single KV entry, raw or as parsed JSON, with thresholds. |
| **KV Table** | A whole KV bucket as a live table, with configurable columns. |
| **Stream Table** | A live message stream rendered as a table — one row per message, columns extracted by JSON path. |
| **PocketBase** | A database query. The one widget that reads the REST API rather than the bus, so it is bounded by API rules rather than NATS permissions. |

### Controls

| Widget | What it does |
| :--- | :--- |
| **Button** | Publishes a fixed payload to a subject. Can do a request/reply with a timeout instead of a plain publish. |
| **Switch** | A toggle, backed either by a KV key or by publish-and-watch-a-subject. Optionally asks for confirmation first. |
| **Slider** | A range control, publishing on change. |
| **Publisher** | An ad-hoc message composer with history. If the target is a Thing with a [Thing Type](./thing-types.md), it binds to a `Thing + Operation` pair: the subject resolves from the Thing's context and the payload becomes a schema-driven form. |
| **Scanner** | Scans a QR code with the device camera and looks up or publishes against the result. The [labels the platform prints](./platform-ui-entities.md#codes-and-qr-labels) carry a bare Location or Thing code, which is what the `{value}` placeholder in a KV key template or PocketBase filter expects — so `code = "{value}"` resolves a printed label with no extra configuration. The decoded string is never treated as a destination. |

### Context

| Widget | What it shows |
| :--- | :--- |
| **Map** | Geographic or floor-plan placement, with live markers. Markers can carry KV values, publish buttons, switches and text. |
| **Console** | A raw live log of every message the widget's subscription sees. The first thing to add when debugging "why is nothing arriving". |
| **Markdown** | Static text and images. Runbook links, a legend, a note about what the screen is for. |

---

## 4. Variables

A dashboard can declare variables, which appear as a bar of inputs above the grid — free text, or a select with fixed options. Any subject, KV key or query in a widget can reference one with `{{name}}`:

```
sensors.{{device_id}}.temp
```

Changing the value in the bar re-resolves every widget that references it, so one dashboard covers a fleet instead of one dashboard per device. An unresolved name is left in place as literal `{{device_id}}` rather than silently becoming an empty subject — so a typo looks like a typo.

Variables are part of the dashboard document, so a shared dashboard carries them, and each viewer's *current selections* are their own.

---

## 5. Editing, locking, and the appliance case

A dashboard is either unlocked (drag, resize, add and configure widgets) or locked (view only). Locking is what makes a dashboard safe to leave on a wall display, and it pairs with the [`dashboard` role](./authorization.md#1-the-five-tenant-roles) — an appliance login that reaches the Visualizer and its own settings page and nothing else.

Two things to get right for an unattended screen:

1. **Set a startup dashboard** in settings, so a reboot lands on the right view rather than the last one someone happened to open.
2. **Give it its own NATS identity with a read-only role.** The console role restricts *screens*; what the browser can do on the bus is entirely the linked `nats_users` role. A wall display should not hold a credential that can publish to `cmd.>`.

---

## 6. Live State is not a widget

The twin browser on a Thing or Location detail view is a different surface from the Visualizer: it shows the KV keys under `thing.<code>` or `location.<code>`, with reported and desired values side by side. See [Platform Entities & UI](./platform-ui-entities.md#the-digital-twin) for how it reads, and [Architecture §4](./architecture.md#4-the-digital-twin-concept-live-state) for the two-bucket model behind it.

You can of course point a KV widget at the same bucket and key. The difference is that the twin view pairs reported against desired and shows the drift; a KV widget shows one bucket.

---

## 7. Where to Go Next

- **What a widget is allowed to see:** [Connectivity](./connectivity.md) — NATS roles and permission fields.
- **Contracts that drive the Publisher's forms:** [Thing Types](./thing-types.md).
- **The live-state model:** [Architecture §4](./architecture.md#4-the-digital-twin-concept-live-state).
- **Turning values into actions instead of pixels:** [Automation](./automation.md).
