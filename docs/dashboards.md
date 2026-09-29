---
path: platform/dashboards
nav_order: 70
---
# Dashboards & Widgets

The Visualizer is the console's dashboard view: a resizable grid of widgets.
Each widget reads a NATS subject (optionally replayed from JetStream) or a KV
key. It is the screen for people who do not administer the platform, such as a
technician who watches a site, or an unattended display in a control room.

All of it runs over **the browser's own NATS connection**. There is no
server-side rendering and no database polling. When a value changes on the bus,
the widget updates. A widget can see only what the viewer's NATS credential
permits. That permission is set per identity in [Connectivity](./connectivity.md)
and does not depend on the console role.

---

## 1. Where a dashboard lives

Dashboards are **not** PocketBase records. Each one is a JSON document, stored
in one of two places:

| Storage | Where | Who sees it |
| :--- | :--- | :--- |
| **Local** | the browser's `localStorage` | that browser only |
| **Shared** | a NATS KV bucket, `dashboards` by default | anyone whose credential can read the bucket |

Local is the default and needs no configuration. Use shared dashboards to give
a team one view, or to give an unattended screen its layout without building it
on that screen. Key names can contain dots, which the console shows as folders
(`site-a.lobby`).

Shared storage is a KV bucket, so **NATS permissions control access, not API
rules**. A credential that can write the `dashboards` bucket can edit every
shared dashboard in it. Give an appliance login a read-only NATS role so it
cannot overwrite the layout.

Local storage holds up to 25 dashboards, and the console warns you as you get
close. To move a dashboard between deployments, export and import it as a JSON
file.

---

## 2. Data sources

A data-bound widget reads from one of two sources.

| Source | What it does | Use it for |
| :--- | :--- | :--- |
| **Subject** | A live subscription. By default you see only messages published after the widget loads. With **Use JetStream (History)**, it first replays from the stream that covers the subject. Deliver policies: *All*, *Last*, *Last Per Subject*, *New* or *By Time Window* (`10m`, `1h30m`). | Telemetry, logs and events. Turn on history for a chart that must not start empty. |
| **KV key** | A KV key, watched for updates. | Current state, such as a setpoint, a status or a twin value. |

The widget type decides the source:

- **Subject only:** Text, Chart, Stat, Gauge, Console, Stream Table. Chart,
  Console and Stream Table take several subjects.
- **KV only:** KV, KV Table.
- **Either:** Status and Markdown. Markdown can also have no source.
- **Controls** have their own targets. Switch and Slider have a KV mode (read and
  write one key) and a core mode (publish, and watch a state subject). Button
  and Publisher publish.

Two things to know:

- **A plain subject widget is empty until the next message.** If a subject
  publishes every ten minutes, a new dashboard looks broken for up to ten
  minutes. When the current value matters, turn on JetStream history with
  *Last* or *Last Per Subject*, or use a KV source.
- **JetStream history and KV both need JetStream** on the account, and a stream
  must already cover the subject for history to replay. The `$SYS` account has
  no JetStream, which is one reason not to run real work on it
  ([Getting Started](./getting-started.md)).

Buffering widgets (charts, tables, console, stat) keep the last *N* messages.
You set *N* per widget. The buffer has no age limit. To drop old points by time,
use the Chart's time window (§3). The buffer is in the browser, and nothing is
saved.

**Each message gets a timestamp on arrival.** Charts and tables use it, in this
order:

1. A **Timestamp Path** you set into the payload (epoch seconds, ms, µs or ns,
   or ISO 8601).
2. For a replayed message, the time JetStream stored it.
3. The time the browser received it.

Set the path when the device has its own clock. If you do not, an hour of
replayed history shows up at "now".

---

## 3. The widget types

There are sixteen widget types. The grid has 12 columns by default. Each
dashboard can change to 4, 6, 8, 10, 16 or 20 columns, or *Auto*. Each type has
a default size.

### Display

| Widget | What it shows |
| :--- | :--- |
| **Text** | The latest value, formatted. Threshold rules change its colour by comparison (`>`, `>=`, `<`, `<=`, `==`, `!=`). |
| **Stat** | A KPI number with a trend indicator and a small sparkline. |
| **Gauge** | A circular meter with a min/max range. |
| **Status** | Maps values to labels and colours. It shows stale when nothing arrives within a timeout. It reads a subject or a KV key. In KV mode the JSONPath applies, and staleness counts from when the entry was written. |
| **Chart** | Line, bar or **State Timeline** on a real time axis, drawn with ECharts. See below. |

A **Chart** draws *N* series. Each series has a label, a JSONPath into the
payload, and an optional exact-subject filter. Use the filter when several
devices publish the same shape (`{"running": true}`) on different subjects,
because the path alone cannot tell them apart.

A **time window** (`30m`, `1h30m`) drops points off the left edge and keeps the
axis moving when nothing arrives. With JetStream history on *By Time Window*,
the same value sets the replay window. With no window, the chart shows the last
*N* messages. The buffer still limits memory, and the chart tells you when the
buffer, not the window, limits what you see.

The **State Timeline** draws one row per series and joins consecutive equal
values into one coloured segment. Use it for "was the pump running, and when".
Threshold rules give a matching value a colour and a label. A value that no rule
matches gets a colour computed from the value, so it stays the same across
reloads.

### Tables and records

| Widget | What it shows |
| :--- | :--- |
| **KV** | One KV entry, raw or as parsed JSON, with thresholds. |
| **KV Table** | A whole KV bucket as a live table, with columns you choose. |
| **Stream Table** | A live message stream as a table, one row per message, with columns taken by JSON path. |

### Controls

| Widget | What it does |
| :--- | :--- |
| **Button** | Publishes a fixed payload to a subject, or sends a request and waits for a reply with a timeout. |
| **Switch** | A toggle, backed by a KV key or by publishing and watching a subject. It can ask for confirmation. |
| **Slider** | A range control. In core mode it publishes on change and can watch a state subject. In KV mode it writes a key. It can ask for confirmation. |
| **Publisher** | A message composer with history. For a Thing with a [Thing Type](./thing-types.md), it binds to a Thing and an operation. The subject then resolves from the Thing and is read-only. The payload is free text. |
| **Scanner** | Scans a QR code with the device camera, then looks up or publishes with the result. [Platform labels](./platform-ui-entities.md#codes-and-qr-labels) hold a bare Location or Thing code. The `{value}` placeholder in a KV key template or PocketBase filter takes that code, so `code = "{value}"` finds a printed label with no extra setup. The scanner never opens the decoded string as a destination. |

### Context

| Widget | What it shows |
| :--- | :--- |
| **Map** | Live markers on a vector basemap. Up to 50 markers you place by hand, each fixed or moved live from a subject (lat/lon by JSONPath), with up to 10 items each: KV values, text from a subject, publish buttons and switches. Optional **dynamic markers** from a KV bucket, one per key under a pattern (`vehicles.>`), with lat/lon/label by JSONPath and popup fields, up to 500. Clustering and fit-to-markers are optional. Floor plans are on the Location detail view, not in a widget. |
| **Console** | A raw live log of every message the widget's subscription receives. Add it first when nothing seems to arrive. |
| **Markdown** | Text and images, such as runbook links, a legend or a note about the screen. It can read a subject or KV key, and `{{value}}` or `{{field.path}}` shows the latest payload inline. The output is sanitised, so a payload cannot inject script. |

---

## 4. Variables

A dashboard can have variables, which appear as inputs above the grid: free
text, or a select with fixed options. Any subject, KV key or query in a widget
can use one as `{{name}}`:

```
sensors.{{device_id}}.temp
```

When you change the value, every widget that uses it resolves again, so one
dashboard covers a whole fleet. An unknown name stays as the literal text
`{{device_id}}`, not an empty subject, so a typo is visible.

Variables are saved in the dashboard, so a shared dashboard includes them. Each
viewer's *current selections* are their own.

---

## 5. Editing, locking, and the appliance case

A dashboard is unlocked (drag, resize, add and configure widgets) or locked
(view only). Lock a dashboard before you leave it on a wall display. Use it
with the [`dashboard` role](./authorization.md#1-the-five-tenant-roles), an
appliance login that sees only the Visualizer and its own settings page.

For that role, the Visualizer runs in **restricted mode**. Kiosk mode, the debug
panel, keyboard shortcuts and the grid-size selector are off. The role can add
only ten widget types: Button, Switch, Slider, Publisher, KV, KV Table, Text,
Status, Stat and Scanner. It cannot add Chart, Gauge, Map, Console, Markdown or
Stream Table. A dashboard that already has them still shows them.

For an unattended screen:

1. **Set a startup dashboard** with *Set as Startup* in the dashboard's menu in
   the sidebar list, so a reboot opens the right view. The setting is saved in
   **that browser's** local storage, not on the login, so set it on the screen
   itself.
2. **Give it its own NATS identity with a read-only role.** The console role
   limits *screens*. What the browser can do on the bus comes only from the
   linked `nats_users` role. A wall display must not hold a credential that can
   publish to `cmd.>`.
3. **Check for WebGL** if a dashboard has a Map. The basemap draws on a WebGL
   canvas and does not appear without it.

---

## 6. Live State is not a widget

The twin browser on a Thing or Location detail view is separate from the
Visualizer. It shows the KV keys under `thing.<code>` or `location.<code>`, with
reported and desired values side by side. See
[Platform Entities & UI](./platform-ui-entities.md#the-digital-twin) and
[Architecture §4](./architecture.md#4-the-digital-twin-concept-live-state).

A KV widget can read the same bucket and key, but it shows one bucket. The twin
view compares reported and desired values and shows where they differ.

---

## 7. Where to Go Next

- What a widget can see: [Connectivity](./connectivity.md) (NATS roles and permissions)
- Subject contracts for the Publisher: [Thing Types](./thing-types.md)
- The live-state model: [Architecture §4](./architecture.md#4-the-digital-twin-concept-live-state)
- Actions from values: [Automation](./automation.md)
