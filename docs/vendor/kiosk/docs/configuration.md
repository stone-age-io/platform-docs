---
path: kiosk/configuration
nav_order: 70
---
# Configuration Reference

The three binaries share one config schema
([`internal/config/config.go`](https://github.com/stone-age-io/kiosk/blob/main/internal/config/config.go)). This page lists
every key, its type, its default and what it does. For the subjects and
buckets these keys name, see [Wire Protocol](protocol.md). For day-to-day tasks,
see [Operations](operations.md).

Start from the annotated example configs, then use the tables here to find
a default:

- [`kiosk.yaml.example`](https://github.com/stone-age-io/kiosk/blob/main/kiosk.yaml.example): a kiosk node.
- [`controller.yaml.example`](https://github.com/stone-age-io/kiosk/blob/main/controller.yaml.example): the controller.
- [`timeclock.yaml.example`](https://github.com/stone-age-io/kiosk/blob/main/timeclock.yaml.example): the timeclock terminal.

---

## 1. How Config Loads

Each binary reads one YAML file from its working directory:

| Binary | Built from | Default file |
| :--- | :--- | :--- |
| `kiosk-app` | `cmd/kiosk` | `kiosk.yaml` |
| `kiosk-controller` | `cmd/controller` | `controller.yaml` |
| `kiosk-timeclock` | `cmd/timeclock` | `timeclock.yaml` |

- **`KIOSK_CONFIG` overrides the path.** Set it to an explicit file, for
  example `KIOSK_CONFIG=/etc/kiosk/kiosk.yaml`.
- **The file must exist.** A file that cannot be read or parsed stops the
  binary at startup.
- **The controller has no `kiosk:` block.** It is the central aggregator, not
  a kiosk node, so it needs no `kiosk.code`.
- **Durations are Go duration strings**, such as `"5m"`, `"30s"` or `"72h"`.

---

## 2. Environment Variable Overrides

Most keys have an environment override. Take the dotted key, add the prefix
`KIOSK_`, uppercase it, and replace dots with underscores. For example,
`nats.credentials_file` is `KIOSK_NATS_CREDENTIALS_FILE`. An env var wins over
the file.

```bash
KIOSK_KIOSK_CODE=KC-YARD-03
KIOSK_KIOSK_LOCATION_CODE=YARD
KIOSK_SERVER_PORT=8091
KIOSK_RETURNS_ALLOW_CROSS_USER=false
KIOSK_BRANDING_LOGO_PATH=/etc/kiosk/yard-03.svg
KIOSK_BRANDING_TAGLINE="Yard 03 Crib"
KIOSK_BRANDING_PRIMARY_COLOR="#1d4ed8"
KIOSK_BRANDING_CUSTOM_CSS_PATH=/etc/kiosk/yard-03-theme.css
KIOSK_NATS_ENABLED=true
KIOSK_NATS_URL=nats://central.example.com:4222
KIOSK_NATS_SUBJECT_PREFIX=kiosk
KIOSK_NATS_STREAM_NAME=KIOSK_EVENTS
KIOSK_NATS_CREDENTIALS_FILE=/etc/kiosk/nats.creds
KIOSK_CONTROLLER_ENABLED=true
KIOSK_CONTROLLER_CATALOG_BUCKET=KIOSK_CATALOG
KIOSK_RFID_ENABLED=true
KIOSK_RFID_READ_WINDOW=3s
KIOSK_TIMECLOCK_ENABLED=true
KIOSK_TIMECLOCK_REQUIRE_CLOCK_IN_FOR_CHECKOUT=true
KIOSK_TIMECLOCK_BLOCK_CLOCK_OUT_WITH_OPEN_CHECKOUTS=true
KIOSK_TIMECLOCK_TIMECLOCK_ONLY=true
KIOSK_TIMECLOCK_VIRTUAL=true       # kiosk-timeclock only
```

::: note Some keys are YAML-only
The per-reader RFID fields (`mode`, `host`, `port`, `enclosure_id`, `zone`,
`antennas`) live in the `rfid.readers` map. No flat env var reaches into a map
entry. Only `rfid.enabled` and `rfid.read_window` have overrides. The
`location.*` keys have no overrides either.
:::

Other env vars:

| Variable | Purpose |
| :--- | :--- |
| `KIOSK_CONFIG` | Path to the YAML file. Default `kiosk.yaml`, `controller.yaml` or `timeclock.yaml`, by binary. |
| `KIOSK_QUIET_BOOTSTRAP` | If set, the binary does not print the bootstrap admin credentials. The tests use it. |
| `KIOSK_ROLE` | `cmd/controller` sets it to `controller` before config validation, which removes the `kiosk.code` requirement. Operators do not set it. |

A typical deployment keeps one `kiosk.yaml` with shared defaults in config
management. Each host sets its own values as env vars in its service
definition.

---

## 3. Identity, Server and Session

| Key | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `kiosk.code` | string | required | The stable identity of the kiosk node. Every transaction carries it. Not used on the controller. |
| `kiosk.location_code` | string | required | Site or yard identifier. Not used on the controller. |
| `server.port` | int | `8090` | HTTP port. `controller.yaml.example` sets `8091`. |
| `server.bind` | string | `"127.0.0.1"` | Bind address. Keep localhost on a kiosk node, because the touchscreen is the only client. |
| `session.idle_timeout` | duration | `5m` | How long an in-memory cart lives with no activity. A zero or negative value counts as unset, because it would expire every cart the instant it was created. |
| `session.cart_grace_period` | duration | `30s` | How long the SPA shows the success screen after a commit. |
| `scanning.user_qr_prefix` | string | `""` | Optional. A scan that starts with this prefix resolves as a user only. The example config sets `"U:"`. |
| `scanning.item_barcode_prefix` | string | `""` | Optional. The same rule for items. |

---

## 4. Returns

| Key | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `returns.allow_cross_user` | bool | `true` | Lets a foreman return another worker's tool through the "Return on behalf of…" dialog. Same group only. |
| `returns.allow_uncorrelated` | bool | `true` | Accepts the return of an item that is not checked out. |

An omitted key means `true`. Only an explicit `false` turns a scenario off.

### Returns policy

The commit hook enforces the `returns.*` flags. With a flag set to `false`, the
matching transaction fails and rolls back. The cart stays intact, so the
worker can fix it and retry.

Two role rules always apply at commit time, whatever the flags say:

- **Cross-user return.** The active worker returns a tool checked out to a
  different worker. The active worker must be a `foreman` whose `group`
  matches the group of the original checkout user. Both groups must be
  non-empty. The commit rejects an ungrouped foreman, or a foreman in a
  different group. The admin handles that case.
- **Uncorrelated return.** No open checkout matches the return. The active
  worker must be a `foreman`, and the group does not matter. This is a
  janitorial action.

`allow_cross_user: false` rejects every cross-user return before the foreman
check runs.

A cross-user return is an **explicit** action. When a worker scans a tool that
another worker has out, the action defaults to `checkout`:

- For a quantity-tracked tool, the natural reading is "give me one too".
- For a serialized tool, the resolver routes to `return` only when the cart
  user owns the open checkout.

A foreman starts a cross-user return through the "Return on behalf of…"
dialog. It lists the workers in the foreman's group who have items out, and it
accepts a serialized scan as a one-step shortcut. The dialog is the only client
surface that fills `original_checkout_user_id` on a cart line. The regular
`/cart/add` endpoint never does. The [API Reference](api.md) has the endpoint
signatures.

---

## 5. NATS

| Key | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `nats.enabled` | bool | `false` | Publishes every event to NATS as well as to the log. Must be `true` on the controller. |
| `nats.url` | string | `""` | Broker URL. The example configs set `nats://localhost:4222`. |
| `nats.subject_prefix` | string | `"kiosk"` | The first token of every subject. Empty uses the default. Change it only when another application on a shared cluster owns `kiosk.>`. |
| `nats.stream_name` | string | `"KIOSK_EVENTS"` | The JetStream stream the controller binds and consumes. Empty uses the default. Controller only: a kiosk node publishes to subjects and ignores it. |
| `nats.token` | string | `""` | Bearer token. |
| `nats.username` | string | `""` | Basic auth, with `password`. |
| `nats.password` | string | `""` | Basic auth, with `username`. |
| `nats.credentials_file` | string | `""` | JWT `.creds` file, for example from NGS or JetStream Cloud, or the one the platform writes ([§5.1](#51-credentials-from-the-platform)). |
| `nats.nkey_seed_file` | string | `""` | ed25519 NKey seed file. |
| `nats.tls_ca_file` | string | `""` | Custom CA. |
| `nats.tls_cert_file` | string | `""` | Client certificate. |
| `nats.tls_key_file` | string | `""` | Client key. |
| `nats.tls_insecure` | bool | `false` | Skips certificate verification. Development only. |
| `nats.code` | string | `""` | The Thing code for NATS service discovery (ADR 0008 in `platform-docs`). A kiosk node falls back to `kiosk.code`. Set it on the controller, where empty skips discovery registration. |

Subjects have the form `kiosk.{code}.evt.transaction.complete`, where `kiosk`
is `nats.subject_prefix`. The [Wire Protocol](protocol.md) lists every subject.

The main job of a kiosk node is its local ledger, so NATS is best-effort about
**reachability**. A server that is unreachable at startup does not stop the
boot. The connection buffers and dials in the background. All `nats.go` auth
modes work. Set the one your server expects, or leave them all blank for
anonymous access.

A **structural** config error is different, and stops the binary at startup:

- `nats.enabled` is `true` and `nats.url` is empty or malformed.
- `nats.credentials_file` or `nats.nkey_seed_file` is set but cannot be
  loaded.

The binary stops rather than connect without authentication. Blank auth fields
are valid. A broken file is an operator error.

::: note Every binary must use the same `subject_prefix`
The controller binds its stream to `{prefix}.*.evt.>`. Each kiosk node, the
timeclock terminal and the controller must agree on the prefix.
:::

### 5.1 Credentials from the platform

Set `platform.url` and the binary keeps `nats.credentials_file` current
itself, as its own Thing on the platform (ADR 0009 in `platform-docs`). It
signs in with the kit's `credskeeper`, writes the creds file, and rewrites it
after a Regenerate or a Revoke. The open connection moves to the new file on
its next reconnect, without a restart. Each kiosk node, timeclock terminal and
controller is its own Thing, with its own identity.

| Key | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `platform.url` | string | `""` | The platform's base URL. Empty starts nothing, and `nats.credentials_file` is a file you provide. |
| `platform.identity` | string | `""` | This binary's Thing login email, printed once when the Thing is provisioned. |
| `platform.password` | string | `""` | The Thing's password. Needed only until the first sync has saved a session. Set it as `KIOSK_PLATFORM_PASSWORD`, not in the file, and remove it after the first start. |
| `platform.session_file` | string | `""` | Defaults to `platform-session.json` beside the creds file. |
| `platform.sync_interval` | duration | `5m` | How often the platform is asked for a change. A failed sync is retried after 30s. |
| `platform.allow_insecure` | bool | `false` | Lets `platform.url` be `http://`. Development only: the first sync sends the password and receives a private key. |

To set it up, apply [`contract/`](https://github.com/stone-age-io/kiosk/blob/main/contract) with
`stone apply --template contract/`, provision a Thing for the binary on its
Thing Type and NATS role (`stone thing provision ... --nats-mode auto
--nats-role <role id>`), set `platform.url`, `platform.identity` and
`nats.credentials_file`, and start once with `KIOSK_PLATFORM_PASSWORD`. The
binary creates the directory (0700) and writes the creds file and a session
beside it before it connects.

What to know:

- **The files go outside the PocketBase data directory** (`pb_data`,
  `pb_data_timeclock` or `pb_data_controller`, or `--dir`), such as
  `pb_creds/`. PocketBase backups archive the whole data directory, and a
  restored copy would give a second host this binary's identity. The binary
  refuses a path inside it.
- **The platform's creds file is the credential.** `nats.token`,
  `nats.username` and `nats.nkey_seed_file` must be empty, and
  `nats.enabled` must be `true`.
- **Only `serve` runs it.** `migrate` and `demo-seed` never wait on the
  platform.
- **A first start waits up to 30s for its first file.** Past that, a kiosk node
  or a timeclock serves without NATS until a restart, with `credentials`
  failing on `/api/ready`. The controller, which needs NATS, exits. A
  restart that finds a file connects at once, even while the platform is
  down.
- **`/api/ready` gains `credentials` and `platform`.** `platform` warns
  when the last sync failed and never fails, since the file already held
  still works.
- **If a host is compromised, deactivate its Thing first. A Revoke alone is
  not enough.** The binary holds the Thing's platform session, so a Revoke
  hands the new credential to whoever copied it. Deactivate the Thing, set a
  new password, reactivate it, Revoke, and start once with the new password
  ([creds-keeper §7](https://github.com/stone-age-io/services/blob/main/docs/creds-keeper.md#7-a-compromised-host)).

---

## 6. Controller Opt-In

| Key | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `controller.enabled` | bool | `false` | Puts the kiosk node under central management. It watches the catalog KV bucket and projects each update into its local tables. |
| `controller.catalog_bucket` | string | `"KIOSK_CATALOG"` | The catalog KV bucket, holding the items, users and groups families ([Wire Protocol](protocol.md#kv-buckets)). Empty uses the default. The controller and every managed node must agree. |

When `controller.enabled` is `true`, the admin SPA on the kiosk node hides Add,
Edit and Delete on items and workers. It shows a "Catalog managed by
controller" banner. Catalog changes arrive over JetStream KV instead. Stock
adjustments stay available at each kiosk node.

This mode needs `nats.enabled: true`, pointed at the same broker the
controller publishes to. On the controller, the three bucket names are the
buckets it publishes to. Each managed kiosk node must use the same names. See
[Central Controller](controller.md).

---

## 7. RFID

| Key | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `rfid.enabled` | bool | `false` | Dials each configured reader at startup. Off, the binary behaves as if no reader is on the network. |
| `rfid.read_window` | duration | `3s` | One inventory cycle, shared across readers. At most `3.5s` when any reader is `enclosure_diff`. |
| `rfid.readers` | map | `{}` | Reader id to one physical reader. A node can host several, such as a counter and enclosure cabinets. A single-reader node declares one entry, and reader selection is implicit. |
| `rfid.allow_mock` | bool | `false` | Permits a reader with a `tag_file`, the demo's mock reader. **Demo only.** Without it a `tag_file` is a config error, so a production config cannot get a reader that invents inventory by a typo. |

Each entry in `rfid.readers`:

| Field | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `mode` | string | required | `counter_scan` or `enclosure_diff`. |
| `host` | string | required | Reader IP address or hostname. Not used with `tag_file`. |
| `port` | int | required | LLRP port. The standard port is `5084`. Not used with `tag_file`. |
| `tag_file` | string | `""` | Makes this a mock reader: each read returns the EPCs listed in the file, one per line, with `#` comments. Needs `rfid.allow_mock`. `mode` still decides the workflow. The Northwind demo uses it ([demo/rules](https://github.com/stone-age-io/kiosk/blob/main/demo/rules/README.md)). |
| `enclosure_id` | string | `""` | The access-controlled cabinet id. Required when `mode` is `enclosure_diff`. |
| `zone` | string | `""` | Optional location label. A read here also stamps each observed unit's advisory "last seen" at this zone. Empty means no location stamping. |
| `antennas` | list | `[]` | Active reader ports and their TX power, each `{id: 1, tx_power_dbm: 25.0}`. Each `id` is 1 or more, and unique. Empty uses the reader's own baseline. |

```yaml
rfid:
  enabled: true
  read_window: "3s"
  readers:
    front-counter:
      mode: "counter_scan"
      host: "10.0.0.50"
      port: 5084
      zone: "Main Crib"
      antennas: []
    cabinet-a:
      mode: "enclosure_diff"
      host: "10.0.0.51"
      port: 5084
      enclosure_id: "cabinet-a"
```

The two modes are two LLRP-driven inventory flows:

- **`counter_scan`.** The operator presses an "RFID scan" button on
  `CheckoutView`. The kiosk node runs one inventory cycle. It adds each
  matched EPC to the cart through the same path that `cart/add` uses.
- **`enclosure_diff`.** NATS drives it, so it needs `nats.enabled: true`. An
  access-control system publishes `cart.start` at the door. A camera or
  occupancy system publishes `read.trigger` when the worker steps out. The
  kiosk node compares the observed EPCs with the expected-present state, and
  creates checkout and return lines.

The `read_window` cap is `config.MaxEnclosureReadWindow`. An `enclosure_diff`
read runs inside the controller's NATS command-reply window of about 5 s. A
longer read window pushes the reply past it, and the caller then sees the
kiosk node as offline. `counter_scan` is HTTP-driven and has no cap.

A reader that does not connect at startup logs a warning. The binary keeps
running, as it does when NATS is unreachable. The RFID endpoints return `503`
until the connection is made.

The identity payload served to the SPA carries `rfid_enabled` and `rfid_mode`,
so the frontend shows only the controls that apply. A reader's `zone` gives
location data from custody activity, with no separate location reader. Location
gateways are external publishers (§8). The full design is in [RFID](rfid.md).

---

## 8. Location

The `location.*` block tunes the L4 report that compares custody with location.
The report is **observability only**. It never enforces anything.

| Key | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `location.stale_after` | duration | `0` (off) | Flags a checked-out unit that no gateway has seen for this long ("possibly lost"). `0` or omitted turns the flag off. The example configs set `72h`. |
| `location.custody_zones` | string list | `[]` | Zone labels that count as "still in storage", such as a cabinet or counter. A checked-out unit last seen in one is flagged "not taken". |

On a kiosk node, an empty `custody_zones` list defaults to the zones of the
node's RFID readers, so you usually do not set it. The controller has no reader
zones. Set the list there to enable the "not taken" flag. The stale and
unaccounted flags work without it.

Sightings arrive from **external gateways** that publish to NATS. They are
configured and operated outside the platform, not in this file. See
[Location & Sightings](https://github.com/stone-age-io/kiosk/blob/main/docs/location-sightings-plan.md).

---

## 9. Timeclock

The `timeclock.*` block adds an append-only clock-in and clock-out ledger,
`time_punches`. It follows the same rules as the tool ledger:

- Nothing edits or deletes a punch.
- A correction is a new punch with a reason.
- "Who's clocked in" comes from each worker's latest punch. In managed mode it
  is merged with the fleet replica.

Every key defaults to `false`, so an omitted block leaves a deployment as it
was.

| Key | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `timeclock.enabled` | bool | `false` | Enables the whole feature: the endpoints, the "Time clock" button on the splash screen, event publishing, and the punch-state watcher in managed mode. Off, the endpoints return `404`. |
| `timeclock.require_clock_in_for_checkout` | bool | `false` | The commit rejects a cart with checkout or consume lines when the cart user is not clocked in. |
| `timeclock.block_clock_out_with_open_checkouts` | bool | `false` | Rejects a clock-out while the worker holds open checkouts. |
| `timeclock.timeclock_only` | bool | `false` | Makes the device a dedicated punch station. Requires `timeclock.enabled`. |
| `timeclock.virtual` | bool | `false` | Marks the timeclock terminal (`kiosk-timeclock`). Leave it `false` in `kiosk.yaml`. |

**`require_clock_in_for_checkout`.** Returns are always allowed. A worker can
return a tool whatever the punch state. The checkout screen offers a
one-tap "clock in now?" instead of a dead end.

**`block_clock_out_with_open_checkouts`.** In **managed mode** the check is
**fleet-wide**. It merges this node's local checkouts with the controller's
per-user replica of open checkouts. A tool out at kiosk node A then blocks a
clock-out at node B, or on the timeclock terminal. The worker sees which
building to return each tool to.

- The check is eventually consistent and **fail-open**. When the replica is
  stale or the controller is unreachable, the clock-out is allowed. The
  worker is not stranded.
- **Standalone**, with no controller, the check is local only.
- An admin bypasses it with `force=true`, for the worker who "drove home with
  a tool".
- A worker or foreman can "clock out anyway". This acknowledges the open
  tools, and the punch records it.

**`timeclock_only`.** The SPA replaces the checkout splash with a persistent
punch panel. Badge scans go straight to it. There are no carts and no
checkout. A punch-only station writes no local `open_checkouts`. In managed
mode, `block_clock_out_with_open_checkouts` still blocks on the fleet replica.
Standalone, it does nothing.

**Managed mode** means `controller.enabled: true` with NATS. Punches flow to
the controller. The controller sends each worker's clocked-in state back to
every kiosk node through the `punch` family of the `KIOSK_STATE` bucket. A worker can clock in at
one kiosk node and clock out at another. A standalone kiosk node keeps a
local-only ledger.

There is no payroll math anywhere. The raw-punch CSV export is the payroll
contract.

### Timeclock terminal (`timeclock.yaml`)

The **timeclock terminal** is a separate binary, `kiosk-timeclock`, built from
`cmd/timeclock`. It serves a public self-service punch page. Each worker signs
in and clocks in or out from a phone, with no badge scanner.

- It reads `timeclock.yaml`. `KIOSK_CONFIG` overrides the path.
- It uses its own data directory, `pb_data_timeclock/`.
- It requires `timeclock.enabled: true` and `timeclock.virtual: true`.

It supports the **same three operating modes** as a kiosk node. The `nats` and
`controller` blocks select the mode:

| Mode | `nats.enabled` | `controller.enabled` | Workers from | Clocked-in state |
| :--- | :--- | :--- | :--- | :--- |
| standalone | `false` | `false` | local (admin SPA, superuser, CSV) | local ledger |
| standalone + NATS | `true` | `false` | local | local, and punches publish events |
| controller-managed | `true` | `true` | catalog sync | fleet-wide through `KIOSK_STATE` |

Use managed mode for a public terminal in front of a fleet. Provisioning stays
central on the controller. A worker who clocked in at a physical kiosk node
can clock out from a phone.

Workers authenticate against the `users` collection with OAuth2 SSO, a
password, or both. A migration that only `cmd/timeclock` runs enables auth
for that collection. Start from `timeclock.yaml.example`.
[Operations §9](operations.md#9-timeclock-terminal) covers the deploy-time
hardening: TLS, OAuth2 provider secrets, SMTP for password reset, and a
firewall for the superuser UI.

---

## 10. Branding

| Key | Type | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `branding.logo_path` | string | `""` | An image file, PNG or SVG, served at `GET /branding/logo`. The example config uses `./branding/logo.svg`. |
| `branding.tagline` | string | `""` | Text under the logo on the idle screen. The example config uses `"Tool & Consumable Checkout"`. |
| `branding.primary_color` | string | `""` | A CSS color for primary actions, for example `"#059669"`. Empty uses the built-in default. |
| `branding.custom_css_path` | string | `""` | A `.css` file served at `GET /branding/custom.css`. See [Custom CSS overrides](#custom-css-overrides). |

`logo_path`, `tagline` and `primary_color` cover the common case. The
`branding/logo.svg` in the repo is a generic example: a Lucide wrench and a
"TOOL CRIB" wordmark. To replace it, point `branding.logo_path` at your own PNG
or SVG and restart. Leave a key empty, or omit the block, for the unbranded
defaults.

For anything else, point `branding.custom_css_path` at a `.css` file. This
covers an accent for secondary actions, a surface tint or a typography change.
The kiosk node and the controller serve the file at `GET /branding/custom.css`.
The SPA adds a `<link rel="stylesheet">` for it **after** Tailwind, so your
rules win the cascade at equal specificity.

A starter file is at `branding/theme.css.example`. Copy it to
`branding/theme.css`, or to any path, and edit it. It shows the recommended
path, which changes variables only. A commented-out section shows the fragile
path, which targets utility classes.

### Custom CSS overrides

Tailwind 4 emits every color utility as a `var(--color-<name>)` reference. When
you override the variable, the change reaches every `bg-*`, `text-*`,
`border-*` and `divide-*` utility. It also reaches their `/40`, `/50` and `/70`
alpha variants, through `color-mix()`. You do not name any utility class. The
variables are the stable surface. The class names are not.

The SPA declares two slots of its own:

```css
:root {
  /* Primary action color (commit button, "New X" buttons, focus rings) */
  --color-brand-primary: #6d28d9;
  --color-brand-primary-hover: #7c3aed;
}
```

You can address the full Tailwind palette in the same way. The surface tones
of the SPA come from `slate`. The color accents are:

- `emerald`: active and success.
- `red`: destructive.
- `amber`: warning.
- `sky`: the managed pill.
- `indigo`: the controller chip.

To change the whole surface palette:

```css
:root {
  --color-slate-950: #100b21;  /* page background */
  --color-slate-900: #1a1530;  /* cards, dialogs */
  --color-slate-800: #2d2348;  /* buttons, table headers */
  /* ...and so on for slate-700, -600, ..., -100 */
}
```

For a light skin, **invert** the slate scale. `slate-950`, the page
background, becomes the lightest tone. `slate-100`, the primary text, becomes
near-black. The existing utilities then give dark text on a light background,
with no code change.

You can also target Tailwind utility classes for what the color variables do
not cover, such as border radius, spacing and animations. That works, but it
is **fragile**. Class names change as the UI changes, and we do not treat them
as a public API. If you override the same class on many selectors, open an
issue. We can then think about a variable for it.

The file has a 5-minute `Cache-Control`, so refresh the page after you edit
it. The SPA adds the `<link>` only when the identity payload reports the file
as present. To return to the defaults, remove `custom_css_path` and restart
the binary.

---

## 11. What Gets Rejected

The binary refuses to start in these cases:

- The config file cannot be read or parsed.
- `kiosk.code` or `kiosk.location_code` is empty. The controller is exempt.
- `nats.enabled` is `true` and `nats.url` is empty or malformed.
- `nats.credentials_file` or `nats.nkey_seed_file` is set but cannot be loaded.
- `platform.url` is set while `nats.enabled` is not `true`, without
  `nats.credentials_file`, or beside another NATS auth method; or
  `platform.sync_interval` is negative.
- `platform.url` is set and the creds file or session file is inside the
  PocketBase data directory, or the `platform` block is invalid (an
  `http://` URL without `allow_insecure`, no identity).
- On the controller, `nats.enabled` is not `true`.
- `rfid.enabled` is `true` and `rfid.readers` has no entry.
- A reader has no `mode`, `host` or `port`, or its `mode` is not
  `counter_scan` or `enclosure_diff`.
- An `enclosure_diff` reader has no `enclosure_id`.
- An antenna `id` is less than 1, or appears twice on one reader.
- `rfid.read_window` is more than `3.5s` and any reader is `enclosure_diff`.
- `timeclock.timeclock_only` or `timeclock.virtual` is `true` and
  `timeclock.enabled` is not.

These do not stop a kiosk node: a NATS broker that is unreachable, and an RFID
reader that does not connect.

---

## 12. Where to Go Next

- Subjects, commands and payloads: [Wire Protocol](protocol.md)
- Deploy a kiosk node, make backups and recover: [Operations](operations.md)
- The central controller and managed mode: [Central Controller](controller.md)
- Readers, modes and the trust boundary: [RFID](rfid.md)
- Templates, recipients and digests: [Notifications](notifications.md)
- HTTP endpoints: [API Reference](api.md)
