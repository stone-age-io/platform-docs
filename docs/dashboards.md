---
path: platform/dashboards
nav_order: 70
---
# Dashboards & Widgets

The Visualizer is the console's dashboard view: a grid of widgets that show and
control live data. It is the screen for people who do not administer the
platform, such as a technician who watches a site, or an unattended display in
a control room.

All of it runs over **the browser's own NATS connection**. There is no
server-side rendering and no database polling. When a value changes on the bus,
the widget updates. A widget can see and do only what the viewer's NATS
credential permits. That permission is set per identity in
[Connectivity](./connectivity.md) and does not depend on the console role.

---

## 1. Where a dashboard lives

Dashboards are **not** PocketBase records. Each one is a JSON document, stored
in one of two places, which are the two tabs of the dashboard sidebar:

| Storage | Where | Who sees it |
| :--- | :--- | :--- |
| **Local** | the browser's `localStorage` | that browser only |
| **Shared** | a key in the `dashboards` KV bucket | anyone whose credential can read the bucket |

Local is the default and needs no setup. It holds up to 25 dashboards, and the
console warns you as you get close.

Shared dashboards give a team one view, or give an unattended screen its layout
without building it on that screen.

- **The bucket must already exist.** The console opens `dashboards` but never
  creates it. Create it once per organization, in the console's KV view or with
  the [`stone` CLI](./stone-cli.md).
- **NATS permissions control access, not API rules.** A credential that can
  write the bucket can edit or delete every shared dashboard in it. Give an
  appliance login a read-only NATS role so it cannot change the layout.
- **Key names can contain dots**, which the sidebar shows as folders
  (`site-a.lobby`).
- **Two editors cannot overwrite each other.** When someone else saves a newer
  version, an **Update** button replaces **Save**. A save based on an old
  version is refused with a conflict.

From the sidebar you can create, rename, duplicate and delete a dashboard, copy
a local one to shared storage, and set the one a browser opens at startup. To
move dashboards between browsers or deployments, export and import them as a
JSON file.

---

## 2. Building a dashboard

A dashboard is **locked** (view only) or **unlocked** (edit). Unlock it with the
padlock in the toolbar, then:

- **+ Widget** opens the palette.
- Drag a widget by its header to move it, and drag its corner to resize it.
- Each widget's header has **Configure**, **Duplicate**, **Delete** and **Full
  screen**.
- The column selector sets the grid width: 12 columns by default; 4, 6, 8, 10,
  16 or 20; or *Auto*.

Changes are not saved until you press **Save** (or `S`). The browser warns you
before you leave with unsaved changes. **Refresh** (`R`) drops every widget's
data and subscribes again.

The **debug panel** (the bug icon) shows the NATS connection, the active
subscriptions and each widget's buffer. Press `?` for the full list of keyboard
shortcuts.

| Key | Action |
| :--- | :--- |
| `S` | Save |
| `N` | Add a widget |
| `R` | Refresh data |
| `L` / `U` | Lock / unlock |
| `V` | Show or hide variables |
| `B` | Dashboard sidebar |
| `K` | Kiosk mode (§7) |
| `Esc` | Close a dialog, leave full screen or kiosk mode |

---

## 3. Data sources

A widget that shows data reads from one of two sources:

| Source | What it does | Use it for |
| :--- | :--- | :--- |
| **Subject** | A live subscription. By default you see only messages published after the widget loads. With **Use JetStream (History)**, it first replays from the stream that covers the subject. Deliver policies: *All*, *Last*, *Last Per Subject*, *New* or *By Time Window* (`10m`, `1h30m`). | Telemetry, logs and events. Turn on history for a chart that must not start empty. |
| **KV key** | A KV key, watched for updates. | Current state, such as a setpoint, a status or a twin value. |

The widget type decides the source:

- **Subject only:** Text, Stat, Gauge, Chart, Stream Table and Console. Chart,
  Stream Table and Console take several subjects.
- **KV only:** KV and KV Table.
- **Either:** Status and Markdown. Markdown can also have no source.
- **Their own:** Map and Floor Plan take a source per marker (§4). Controls
  publish or write; Switch and Slider can also read their state back.

Three things to know:

- **A plain subject widget is empty until the next message.** If a subject
  publishes every ten minutes, a new dashboard looks broken for up to ten
  minutes. When the current value matters, turn on JetStream history with
  *Last* or *Last Per Subject*, or use a KV source.
- **JetStream history and KV both need JetStream** on the account, and a stream
  must already cover the subject for history to replay. The `$SYS` account has
  no JetStream, which is one reason not to run real work on it
  ([Getting Started](./getting-started.md)).
- **A wildcard subject also matches system traffic.** On a subject that starts
  with a wildcard (`>`), turn on *Hide system subjects* to drop `$…` and
  `_INBOX` messages.

Widgets that keep history (Chart, Stat, Stream Table, Console) hold the last *N*
messages, and you set *N* per widget. The buffer is in the browser and has no
age limit; to drop old points by time, use the Chart's time window (§4).

**Each message gets a timestamp.** Charts and tables take the first of:

1. A **Timestamp Path** into the payload (epoch seconds, ms, µs or ns, or ISO
   8601).
2. For a replayed message, the time JetStream stored it.
3. The time the browser received it.

Set the path when the device has its own clock. Without it, an hour of
replayed history shows up at "now".

---

## 4. The widget types

There are eighteen widget types, in the same four groups as the palette.

### Data display

| Widget | What it shows |
| :--- | :--- |
| **Text** | The latest value, with a format string, font size, and threshold rules that change its colour (`>`, `>=`, `<`, `<=`, `==`, `!=`). |
| **Stat** | A KPI: a number with a unit or format string, a trend arrow and a sparkline. *Rising is bad* turns the arrow red for values such as a freezer temperature. |
| **Gauge** | A value against a min and max, as an arc or a horizontal bar (a tank, a battery), with coloured zones. |
| **Status** | Maps values to labels and colours. It shows *stale* when nothing arrives within a timeout. In KV mode, staleness counts from when the entry was written. |
| **Chart** | Line, bar or **state timeline** on a real time axis. See below. |
| **KV** | One KV entry, raw or as parsed JSON, with threshold rules. |
| **KV Table** | A KV bucket as a live table, one row per key under a pattern (`thing.>`), with the columns you choose. |
| **Stream Table** | Messages as a live table, one row per message, with columns taken by JSONPath. |

A **Chart** draws one or more series. Each series has a label, a JSONPath into
the payload, and an optional exact-subject filter. Use the filter when several
devices publish the same shape (`{"running": true}`) on different subjects,
because the path alone cannot tell them apart. The y-axis fits the data unless
you fix its min and max.

A chart's **time window** (`30m`, `1h30m`) drops points off the left edge and
keeps the axis moving when nothing arrives. With JetStream history on *By Time
Window*, the same value sets the replay window. With no window, the chart shows
the last *N* messages, and it tells you when the buffer, not the window, limits
what you see.

The **state timeline** draws one row per series and joins equal values into one
coloured segment. Use it for "was the pump running, and when". Threshold rules
give a value a colour and a label. A value that no rule matches gets a colour
computed from the value, so it stays the same across reloads.

### Controls

| Widget | What it does |
| :--- | :--- |
| **Button** | Publishes a fixed payload to a subject, or sends a request and shows the reply, with a timeout. |
| **Button Pad** | A fixed grid of buttons (up to 8 × 8), each with its own label, subject, payload and colour. An empty position is a gap. It keeps its shape on a phone (§6), so use it for a remote control, a D-pad or a camera's pan and tilt. Its buttons only publish. |
| **Switch** | A toggle. In KV mode it reads and writes one key. In core mode it publishes on and off payloads and can watch a state subject. It can ask for confirmation. |
| **Slider** | A range control, with the same KV and core modes as Switch. In core mode it publishes on release. It can ask for confirmation. |
| **Publisher** | A message composer with history. For a Thing with a [Thing Type](./thing-types.md), it binds to a Thing and an operation; the subject then comes from the Thing and is read-only. |

A control's subject and payload can use [variables](#5-variables). In KV mode,
Switch and Slider write the key directly, so a credential that can write the
bucket can change the value.

### Layout

| Widget | What it shows |
| :--- | :--- |
| **Markdown** | Text and images, such as runbook links, a legend or a note about the screen. It can read a subject or a KV key, and `{{field.path}}` shows a value from the latest payload. The output is sanitised, so a payload cannot inject script. |
| **Map** | Live markers on a vector basemap. Up to 50 markers you place by hand, each fixed or moved live from a subject (lat/lon by JSONPath), with up to 10 popup items each: KV values, text from a subject, publish buttons and switches. Optional **dynamic markers** come from a KV bucket, one per key under a pattern (`vehicles.>`), up to 500. Clustering and fit-to-markers are optional. |
| **Floor Plan** | A Location's floor plan, with its Things on it and their live state. You place Things on the plan on the [Location detail view](./platform-ui-entities.md); the widget stores no positions. Each *binding* gives one Thing Type a state source (a subject suffix, or a KV key template such as `thing.{thing}.state`), a colour per value, and the rows its panel shows. |
| **Console** | A raw live log of every message on the widget's subscription. Add it first when nothing seems to arrive. |

### Tools

| Widget | What it does |
| :--- | :--- |
| **Scanner** | Scans a QR code with the device camera, then looks it up in KV or PocketBase, checks it against rules, and can publish the result. [Platform labels](./platform-ui-entities.md#codes-and-qr-labels) hold a bare Location or Thing code, and `{value}` in a key template or filter takes it, so `code = "{value}"` finds a printed label. The scanner never opens the decoded text as a link. |

---

## 5. Variables

A dashboard can have variables, shown as inputs above the grid (`V`): free
text, or a select with fixed options. A widget's subject, KV key, payload or
query can use one as `{{name}}`:

```
sensors.{{device_id}}.temp
```

When you change the value, every widget that uses it resolves again, so one
dashboard covers a whole fleet. An unknown name stays as the literal text
`{{device_id}}`, so a typo is visible. **One exception:** a Markdown widget's
KV key does not resolve variables.

Variables are saved in the dashboard, so a shared dashboard includes them. Each
viewer's *current selections* are their own.

---

## 6. On a phone

Below about 768 px wide, the grid becomes a two-column list. Widgets appear in
the desktop layout's reading order, top to bottom and then left to right.
Small widgets (Text, Stat, Gauge, Status, KV, Button, Switch) share a row in
pairs; the rest take a whole row.

- **A locked dashboard hides the headers of small controls and values** to save
  room. Charts, gauges, tables, maps, Button Pads and other widgets that need a
  title keep theirs, and the dense ones (tables, maps, floor plans, Markdown, Console, Scanner) add
  an *expand* button that opens the widget full screen.
- **Separate widgets lose their arrangement.** Three buttons side by side on a
  desktop become a pair and a single. When the shape matters, use a **Button
  Pad**, which draws the same grid at any width.
- **Arrange widgets on a wider screen.** On a phone you can add, configure and
  delete widgets, but not move or resize them.

---

## 7. Kiosk mode and unattended screens

**Kiosk mode** (`K`) hides the toolbar and fills the screen with the grid.
`Esc` or `K` leaves it. In any mode, a banner says when the NATS connection is
down, so a wall display that has stopped updating says so.

For a screen nobody operates, use the
[`dashboard` role](./authorization.md#1-the-five-tenant-roles): an appliance
login that sees only the Visualizer and its own settings page. For that role
the Visualizer runs in **restricted mode**: no kiosk mode, debug panel or
column selector. It can still add any widget type, because its NATS
credential, not the widget list, is what limits it.

To set up the screen:

1. **Lock the dashboard**, so a touch cannot move widgets.
2. **Set it as the startup dashboard**, so a reboot opens the right view. This
   is saved in **that browser**, not on the login, so set it on the screen
   itself. Without one, the browser reopens the dashboard it showed last.
3. **Give the login its own NATS identity with a read-only role.** The console
   role limits *screens*. What the browser can do on the bus comes only from
   the linked `nats_users` role. A wall display must not hold a credential that
   can publish to `cmd.>`.
4. **Check for WebGL** if the dashboard has a Map. Its basemap draws on a WebGL
   canvas and shows nothing without it.

---

## 8. Live State is not a widget

The twin browser on a Thing or Location detail view is separate from the
Visualizer. It shows the KV keys under `thing.<code>` or `location.<code>`, with
reported and desired values side by side. See
[Platform Entities & UI](./platform-ui-entities.md#the-digital-twin) and
[Architecture §4](./architecture.md#4-the-digital-twin-concept-live-state).

A KV or KV Table widget can read the same buckets, but it shows one bucket. The
twin view compares reported and desired values and shows where they differ.

---

## 9. Where to Go Next

- What a widget can see: [Connectivity](./connectivity.md) (NATS roles and permissions)
- Subject contracts for the Publisher: [Thing Types](./thing-types.md)
- The live-state model: [Architecture §4](./architecture.md#4-the-digital-twin-concept-live-state)
- Actions from values: [Automation](./automation.md)
