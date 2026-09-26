# Dashboards & Widgets

The Visualizer is the console's dashboard surface: a resizable grid of widgets, each bound to a NATS subject (optionally replayed from JetStream) or a KV key. It is the screen you put in front of someone who does not administer the platform — a technician watching a site, or an unattended display in a control room.

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

A data-bound widget reads from one of two places. Choosing the right one is most of getting a dashboard to behave.

| Source | What it does | Reach for it when |
| :--- | :--- | :--- |
| **Subject** | A live subscription. By default fire-and-forget: you see messages published from the moment the widget mounts. Tick **Use JetStream (History)** and it replays from the stream covering the subject first, with a deliver policy: *All*, *Last*, *Last Per Subject*, *New*, or *By Time Window* (`10m`, `1h30m`). | Telemetry, logs, anything where "now" is what matters — with history ticked, a chart that should not start empty. |
| **KV key** | A KV key, watched for updates. | Current state rather than a stream of events: a setpoint, a status, a twin value. |

Which widgets take which is fixed by the type, not chosen freely:

- **Subject only:** Text, Chart, Stat, Gauge, Console, Stream Table. Chart, Console and Stream Table take several subjects at once.
- **KV only:** KV, KV Table.
- **Either:** Status and Markdown switch between a subject and a KV key; Markdown can also be bound to nothing at all.
- **Controls** carry their own targets: Switch and Slider run in a KV mode (read and write one key) or a core mode (publish, and watch a state subject); Button and Publisher publish.

Two consequences worth internalizing:

- **A plain subject widget is empty until the next message arrives.** On a subject that publishes every ten minutes, a freshly loaded dashboard looks broken for ten minutes. Tick JetStream history with *Last* or *Last Per Subject*, or use a KV source, when the current value matters more than the event.
- **JetStream history and KV both need JetStream**, which the account must be entitled to — and a stream must already cover the subject for history to replay anything. The `$SYS` account is not JetStream-enabled, which is one of the reasons [Getting Started](./getting-started.md) tells you not to run real workloads on it.

Widgets that buffer (charts, tables, the console, stat) keep the last *N* messages — a count, set per widget. There is no age limit on the buffer; aging messages out by time is the Chart's own window (§3). The buffer is per widget and lives in the browser; nothing is persisted.

**Every message is stamped with a time on arrival**, and charts and tables use it rather than the moment the browser happened to render. In order: a **Timestamp Path** you set, pointing into the payload (epoch seconds, ms, µs or ns, or ISO 8601); otherwise the time JetStream stored it, for a replayed message; otherwise the time the browser received it. Set the path whenever the device carries its own clock — a replay of an hour of history otherwise stacks up at "just now".

---

## 3. The widget types

Sixteen of them. The grid defaults to 12 columns — each dashboard can switch to 4, 6, 8, 10, 16 or 20, or *Auto* — and each type has a sensible default size.

### Display

| Widget | What it shows |
| :--- | :--- |
| **Text** | The latest value, formatted. Supports threshold rules that recolour it by comparison (`>`, `>=`, `<`, `<=`, `==`, `!=`). |
| **Stat** | A KPI number with a trend indicator and a mini sparkline. |
| **Gauge** | A circular meter against a min/max range. |
| **Status** | State mapping plus a watchdog: maps values to labels and colours, and can go stale when nothing arrives within a timeout. Reads a subject or a KV key; in KV mode the JSONPath applies and staleness counts from when the entry was written. |
| **Chart** | Line, bar, or **State Timeline**, over a real time axis, rendered with ECharts. See below. |

**Charts** draw *N* series from one widget. Each series has a label, a JSONPath into the full payload, and an optional exact-subject filter — the filter is what separates devices that all publish the same shape (`{"running": true}`) on different subjects, where the path alone cannot tell them apart. A **time window** (`30m`, `1h30m`) ages points off the left edge and keeps the axis sliding while nothing arrives; with JetStream history on *By Time Window*, the same value is the replay window, so the two cannot disagree. Leave it empty and the chart shows the last *N* messages. The buffer still caps memory under a window, and the chart says so when it is the buffer, not the window, that is bounding what you see.

The **State Timeline** draws one row per series and merges consecutive equal values into a coloured segment — the shape for "was the pump running, and when". Threshold rules give a matching value its colour and a display label; a value no rule matches gets a colour derived from the value itself, so it is stable across reloads.

### Tables and records

| Widget | What it shows |
| :--- | :--- |
| **KV** | A single KV entry, raw or as parsed JSON, with thresholds. |
| **KV Table** | A whole KV bucket as a live table, with configurable columns. |
| **Stream Table** | A live message stream rendered as a table — one row per message, columns extracted by JSON path. |

### Controls

| Widget | What it does |
| :--- | :--- |
| **Button** | Publishes a fixed payload to a subject. Can do a request/reply with a timeout instead of a plain publish. |
| **Switch** | A toggle, backed either by a KV key or by publish-and-watch-a-subject. Optionally asks for confirmation first. |
| **Slider** | A range control. In core mode it publishes on change (optionally watching a state subject); in KV mode it writes a key. Optionally asks for confirmation first. |
| **Publisher** | An ad-hoc message composer with history. If the target is a Thing with a [Thing Type](./thing-types.md), it binds to a `Thing + Operation` pair: the subject resolves from the Thing's context and renders read-only. The payload stays free text. |
| **Scanner** | Scans a QR code with the device camera and looks up or publishes against the result. The [labels the platform prints](./platform-ui-entities.md#codes-and-qr-labels) carry a bare Location or Thing code, which is what the `{value}` placeholder in a KV key template or PocketBase filter expects — so `code = "{value}"` resolves a printed label with no extra configuration. The decoded string is never treated as a destination. |

### Context

| Widget | What it shows |
| :--- | :--- |
| **Map** | Geographic placement over a vector basemap, with live markers. Up to 50 hand-placed markers, each either fixed or positioned live from a subject (lat/lon by JSONPath), carrying up to 10 items: KV values, text from a subject, publish buttons and switches. Optionally, **dynamic markers** from a KV bucket — one marker per key under a pattern (`vehicles.>`), lat/lon/label by JSONPath, with popup fields — capped at 500. Clustering and fit-to-markers are opt-in. Floor plans are not a widget: they live on the Location detail view. |
| **Console** | A raw live log of every message the widget's subscription sees. The first thing to add when debugging "why is nothing arriving". |
| **Markdown** | Text and images — runbook links, a legend, a note about what the screen is for — optionally bound to a subject or a KV key, so `{{value}}` or `{{field.path}}` renders the latest payload inline. The output is sanitised, so a payload cannot inject script. |

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

The Visualizer also runs in a **restricted mode** for that role: kiosk mode, the debug panel, keyboard shortcuts and the grid-size selector are off, and it can add only ten widget types — Button, Switch, Slider, Publisher, KV, KV Table, Text, Status, Stat and Scanner. Chart, Gauge, Map, Console, Markdown and Stream Table are not offered. A dashboard built by someone else that already contains them still renders; the restriction is on what the appliance login can add.

Three things to get right for an unattended screen:

1. **Set a startup dashboard** with *Set as Startup* on the dashboard's menu in the sidebar list, so a reboot lands on the right view rather than the last one someone happened to open. It is remembered in **that browser's** local storage, not on the login — set it on the screen itself.
2. **Give it its own NATS identity with a read-only role.** The console role restricts *screens*; what the browser can do on the bus is entirely the linked `nats_users` role. A wall display should not hold a credential that can publish to `cmd.>`.
3. **Check it can do WebGL** if any dashboard has a Map. The basemap is a vector style drawn on a WebGL canvas; on a display without it the basemap does not draw.

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
