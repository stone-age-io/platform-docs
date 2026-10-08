---
path: access-control/controller
nav_order: 20
---
# Edge Controller (access-controller)

`access-controller` is the edge binary. One copy runs on each box beside the
doors: it reads cards, decides every tap locally, drives locks and watches door
contacts. This page covers what it runs, how it boots and behaves offline, and
its local status page. For the central side and the table of which binary owns
what, see [Central Service (accessd)](accessd.md). Pin maps, wiring and readers
are in [Hardware & Readers](hardware.md); every config key is in
[Configuration Reference](configuration.md).

---

## 1. What It Is

The controller is one Go binary
([`cmd/access-controller`](https://github.com/stone-age-io/access-control/blob/main/cmd/access-controller/main.go)) with its runtime
in [`internal/controller`](https://github.com/stone-age-io/access-control/blob/main/internal/controller). It talks to the rest of the
system only over NATS.

- **Identity is `controller.code`.** It must match a `controllers` record.
  Local config holds only identity and hardware selection: the code, the
  location, the driver, the model and the reader.
- **Binding is central.** The box drives every portal and aux point whose
  `controller` relation points at its code. Reassigning a door to another box,
  retyping it or rewiring it to another relay is a policy edit, and the box
  follows without a restart.
- **Decisions are local.** It watches the whole `ACC_POLICY` KV bucket into
  in-memory maps and runs the pure `policy.Decide` on every tap. No tap waits
  on the network.
- **It reports upward.** Access events go to JetStream (`ACC_EVENTS`), live
  point state goes to the `ACC_STATUS` KV bucket, and a heartbeat goes to
  accessd over core NATS.

What it never does:

- **Write PocketBase.** It has no database. Runtime posture overrides are
  operational state in memory and are never written back.
- **Own arm-state.** It reads an area's `arm`, `autoArm` and `armOverride`
  from policy and resolves them, but arming, disarming, entry-disarm and the
  one-shot release are record writes that accessd makes. There is no
  `cmd.arm`.
- **Send email or webhooks.** Notifications are accessd's sinks.
- **Create NATS resources.** It binds `ACC_POLICY` read-only and `ACC_STATUS`
  read-write. accessd creates both buckets and the `ACC_EVENTS` stream, so
  accessd must have served at least once.
- **Unlock for fire.** A fire input only suppresses alarm emission. The fire
  panel's relay owns egress.

---

## 2. Install and Run

### Build and flags

```sh
go build ./cmd/access-controller
./access-controller -config config/controller.yaml
```

The binary takes one flag, `-config` (default `config/controller.yaml`). A
missing file is not an error: defaults and `SA_` env vars apply. See
[How Config Loads](configuration.md#1-how-config-loads).

### Minimal config

Start from the annotated [`config/controller.yaml`](https://github.com/stone-age-io/access-control/blob/main/config/controller.yaml).
The keys that make a box itself:

```yaml
nats:
  urls: ["tls://nats.example.com:4222"]
  credsFile: "/etc/access-controller/controller.creds"

controller:
  code: "ctrl-hq-1"              # matches a controllers record
  location: "hq"                 # timezone + command/fire subscription scope
  driver: "gpio"                 # mock (default) | gpio
  model: "kincony-server-mini"   # required for gpio, osdp or both
  reader: "osdp"                 # nats (default) | osdp | both
```

With only defaults (`driver: mock`, `reader: nats`) the box drives no physical
I/O and takes simulated taps over NATS, which is enough to decide taps in
development. `subjects.app`, `policy.bucket` and `status.bucket` must match
accessd. See [Controller](configuration.md#11-controller) for every key.

::: warning An empty `controller.code` drives nothing
The box logs `no controller code configured; no portals will be armed`, arms
no portal or aux point, writes no area shadow and publishes no heartbeat. It
still runs, so the mistake is easy to miss without the status page.
:::

### Devices

`gpio` and the OSDP reader open Linux device files named by the model's
profile ([Supported Boards](hardware.md#1-supported-boards)):

| Model | Locks and inputs | OSDP RS485 bus |
| :--- | :--- | :--- |
| `kincony-server-mini` | `gpiochip0` (GPIO char device) | `/dev/ttyAMA0`, 9600 baud |
| `kincony-pi5r8` | `/dev/i2c-1` (MCP23017 at `0x20`) | `/dev/ttyAMA2`, 9600 baud |

The process must be able to open these. The repo does not ship or document a
service user, group or udev rule, so set access up to suit your image. The
serial transport and both hardware drivers are Linux only.

### What stops it at boot

The controller survives a boot with NATS unreachable (see
[§3](#3-boot-and-offline-behaviour)). It exits at startup only when:

- the config fails to load or validate (see
  [What Gets Rejected](configuration.md#12-what-gets-rejected));
- `controller.model` names no known profile while the driver or reader needs
  one (`unknown controller model`);
- the GPIO or I2C driver fails to initialize;
- the model has no RS485 port, or the serial port fails to open, under
  `reader: osdp` or `both`;
- the NATS options cannot be built (for example an unreadable
  `nats.nkeySeedFile` or TLS key pair);
- a command subscription fails.

### Running as a service

The repo ships **no** unit file or installer. Run the binary under your
service manager with a restart policy, a working directory, and `SA_` env vars
or a config path. The offline cache path defaults to the relative
`./data/policy-cache.json`, so the working directory matters if you enable it.

An example systemd unit, **not shipped with the repo**:

```ini
# /etc/systemd/system/access-controller.service (example only)
[Unit]
Description=stone-access edge controller
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/var/lib/access-controller
ExecStart=/usr/local/bin/access-controller -config /etc/access-controller/controller.yaml
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

`SIGINT` and `SIGTERM` stop it cleanly: the metrics and status servers shut
down (5 s each), the readers and reconcilers stop, the hardware driver returns
each lock relay to idle, and the NATS connection drains. A killed process runs
no cleanup; the next boot drives every line it arms back to idle first. See
[Fail-safe behaviour](hardware.md#fail-safe-behaviour).

---

## 3. Boot and Offline Behaviour

### 3.1 Boot sequence

1. Load config, start the logger and (if enabled) the metrics server.
2. Connect to NATS with **retry-on-failed-connect**. If no server answers, the
   connection comes back in a reconnecting state and keeps retrying in the
   background (`NATS not reachable at startup; retrying in background`).
3. Build the policy store. The `ACC_POLICY` bucket is bound **lazily**, inside
   the watch loop, so construction never touches NATS.
4. If `policy.cache.enabled`, replay the on-disk snapshot into the store (see
   [§3.3](#33-offline-cache)).
5. Open the reader, the hardware backend and the runtime. Everything starts
   **armed for nothing**.
6. Start the status writer (also bound lazily), the three reconcilers, the KV
   watcher, the tap loop, the command subscriptions, the heartbeat and (if
   enabled) the status page.
7. Log `controller started; default-deny until policy syncs`.
8. When the first KV sync completes, log `policy synced; controller live`.
   The reconcilers arm every portal and aux point bound to this code.

Until policy arrives, no portal is armed, so no tap subject is subscribed, no
OSDP address is mapped and no strike is driven. That is **default-deny**: the
box denies by doing nothing, rather than blocking or crashing.

The watcher retries the bind and the watch with backoff from 500 ms, doubling
to a 30 s cap (`policy KV watcher not established (NATS may be unreachable);
will retry`). The status writer keeps the latest shadow per key in memory and
flushes it once its bucket binds.

### 3.2 Sync states

The policy store reports one of three states, shown on the status page:

| State | Meaning |
| :--- | :--- |
| `loading` | No policy yet. The default-deny boot window. |
| `cached` | Booted from the offline cache and no live sync has landed. Deciding on last-known config. |
| `synced` | A live KV sync completed this session. |

`synced` is sticky for the life of the process. A box that synced and then
lost NATS still reports `synced`, so read the NATS connection state alongside
it.

### 3.3 Offline cache

The cache is opt-in (`policy.cache.enabled`). It keeps a write-through,
on-disk copy of the KV keyspace, and on boot replays it through the same path
a live sync uses, so a reboot with NATS down decides on last-known policy
instead of default-deny.

It is fail-secure. A missing, unreadable, corrupt or too-old snapshot
(`policy.cache.maxAge`, default `72h`) loads nothing, and the box boots
`loading` as if the cache were off. Live KV always wins once a sync lands. The
file holds credential values and is written `0600`. The keys, the freshness
rules and the scope are in
[Offline config cache](configuration.md#offline-config-cache).

### 3.4 Reconnect

On every reconnect (and on the first connect after a cold boot that started
disconnected) the controller:

- **re-syncs policy.** It stops the KV watcher, and the watch loop re-creates
  it. `WatchAll` re-delivers every key, the maps refresh, and the reconcilers
  converge again.
- **re-publishes its whole status shadow** to `ACC_STATUS`, since in-flight
  writes may have been lost.

Leave `nats.maxReconnects` at its default `-1` (retry forever). An explicit
`0` means a lost connection is never re-established and the box stays offline
until restarted.

### 3.5 What works with NATS down

| | With NATS down |
| :--- | :--- |
| Tap decisions | **Yes**, on the in-memory graph (or the cached graph after an offline reboot). NATS-published taps cannot arrive, so this applies to OSDP readers. |
| Lock pulses, REX, strike hold | **Yes.** Scheduled posture still flips on the hold-eval tick. |
| Door monitoring (forced, held, `no_entry`, intrusion) | **Yes**, detected locally. Scheduled auto-arm still resolves locally. |
| Events (`evt.tap`, `evt.state`, `evt.alarm`, fire) | **Held in memory.** They are core NATS publishes. The NATS client holds publishes made while disconnected in its in-memory reconnect buffer (natsx leaves the client's default size) and sends them on reconnect. Nothing is written to disk: a restart while offline loses them, and a publish that does not fit is logged and dropped. |
| Heartbeat | Not received. accessd marks the box offline after `accessd.controllerOfflineAfter`. |
| Status shadow | Latest value per key held in memory, re-published on reconnect. No history. |
| Commands (posture, grant, output) | **No.** Core NATS does not store them; a command sent while the box is offline never arrives. Overrides already set stay in force. |
| Policy edits, arm and disarm, entry-disarm | **No.** They arrive with the re-sync on reconnect. |
| Fire suppression | **No.** The owning box publishes `evt.fire` and applies it only when the message comes back through its own subscription, so suppression does not start, even on that box, until NATS returns. |
| Status page | **Yes.** It reads local state only. |

Runtime posture overrides live in memory. They survive a reconnect but not a
restart: a rebooted box reverts to its scheduled or standing posture.

---

## 4. What Runs on the Box

```
reader (nats | osdp | both) ──► tap loop ──► policy.Decide ──► pulse lock
door inputs (DPS / REX / aux) ─┘    │                              │
                                    ├──► evt.tap / evt.alarm ──► ACC_EVENTS
ACC_POLICY watch ──► PolicyStore ───┤
        │                           └──► status shadow ──► ACC_STATUS
        └──► Portal / Aux / Area managers (arm, re-arm, disarm)
```

### Tap loop

The runtime ([`runtime.go`](https://github.com/stone-age-io/access-control/blob/main/internal/controller/runtime.go)) is one event
loop over taps, door inputs and the hold-eval tick. For each tap it:

1. resolves the portal's **effective posture**: a command override, else the
   scheduled `autoPosture` while its `autoSchedule` window is open, else the
   standing posture;
2. calls `policy.Decide` with the portal's location timezone;
3. records the decision for the status page and logs `tap decided`;
4. publishes one `evt.tap` carrying the result and the tap's `source`
   (`nats` or `osdp`);
5. on allow, opens the 10 s authorized-open window and pulses the lock.

Each reader feeds a 64-tap queue. A tap that arrives while the queue is full is
dropped, logged (`tap queue full; dropping tap`) and counted in
`taps_dropped_total`. A dropped tap is a denied entry. The decision rules and
reason codes are in [Decision](protocol.md#10-decision).

### Reconcilers

Three managers keep the box's armed set in step with policy. Each reconciles
once at start and again on every policy change, coalesced so a full re-sync
collapses to one pass, and runs off the watch goroutine.

| Manager | Desired set | On change |
| :--- | :--- | :--- |
| `PortalManager` | Portals whose `controller` is this code and that have a type | Arms the lock relay and DPS/REX inputs, then the reader. Re-arms when the type, `reader_address`, relay or input index, or wiring sense changes. Disarms a portal that leaves. |
| `AuxManager` | `aux_input` and `aux_output` records bound to this code | Arms the line. Re-arms when the index (or an input's contact sense) changes. |
| `AreaManager` | Areas with a member aux input **or** portal on this box | Writes this box's arm shadow `area.{controller}.{code}` with the full participant set (`peers`). Also runs on every hold-eval tick, so a scheduled-arm boundary refreshes with no policy event. It rewrites a shadow only when its state, provenance or peers change, so `updatedAt` is the time of the last change. |

A portal whose hardware or reader fails to arm is left fully unarmed and
retried on the **next policy change**, not on a timer (`failed to arm portal
hardware; will retry on next policy change`). A point whose location differs
from `controller.location` logs a warning, because the box subscribes to
commands and fire only for its own location.

### Door state machine

A per-door monitor over the DPS and REX inputs raises `forced`, `held`,
`held_clear` and `no_entry`, and escalates a forced open on a member of an
armed area to that area's `intrusion`. Aux inputs raise `intrusion` by
`point_type`. Behaviour and timings are in
[Door monitoring](hardware.md#door-monitoring); subjects and suppression rules
are in [Door Monitoring & Alarms](protocol.md#3-door-monitoring-alarms). Under
`driver: mock` there are no door inputs, so door state stays `unknown` and no
door alarm fires.

### Commands and posture overrides

The command handler ([`commands.go`](https://github.com/stone-age-io/access-control/blob/main/internal/controller/commands.go))
subscribes per location over core NATS:

- `acc.{location}.*.*.cmd.posture`: sets a runtime override, or `clear`
  reverts to the effective posture. Each set or clear emits one `evt.state`.
  `until` is ignored with a warning; timed reversion needs an external
  scheduler.
- `acc.{location}.*.*.cmd.grant`: a momentary pulse, logged as an `evt.tap`
  with `allow_command_grant`.
- `acc.{location}.*.*.cmd.output`: `on`, `off` or `pulse` on an aux output.
- `acc.{location}.evt.fire`: sets or clears the location's fire state.

Every controller at a location hears every command there and ignores those for
portals and outputs it does not drive. Payloads are in
[Command Details](protocol.md#command-details).

### Timers

The runtime keeps three timers. Everything else is event-driven.

| Timer | Interval | Purpose |
| :--- | :--- | :--- |
| Held-open (DOTL) | Per door: the portal's `held_open_seconds` (`0` disables) | Started on an authorized open; raises `held` if the door is still open. |
| Heartbeat | `controller.heartbeatInterval`, default `15s` | Publishes liveness, once at start and then every interval. |
| Hold-eval reconcile | `10s`, fixed | Re-applies each strike hold to the effective posture (flips scheduled posture at window boundaries), sweeps expired grants into `no_entry`, and nudges the `AreaManager`. |

Posture commands and portal arming re-apply the hold immediately; the tick is
the fallback for time boundaries. See
[Scheduled Posture & the Strike Hold](protocol.md#6-scheduled-posture-the-strike-hold).

Background loops outside the runtime are infrastructure, not policy: the KV
watch retry backoff, the offline cache's 10-minute freshness stamp (only while
connected), the metrics gauge refresh (`metrics.updateInterval`), the OSDP bus
poll and the I2C input poll (about 50 ms).

### Status shadow

The status writer ([`statuswriter.go`](https://github.com/stone-age-io/access-control/blob/main/internal/controller/statuswriter.go))
is the single writer of this box's keys in `ACC_STATUS`: `portal.{code}`,
`auxin.{code}`, `auxout.{code}` and `area.{controller}.{code}`. The tap and
input paths only update an in-memory map; a separate goroutine puts the
changes to KV, retries a failed put on the next change, and deletes a key when
its point is disarmed. A portal's shadow is written only when its door,
posture, posture source or held flag changes. Value shapes are in
[Status KV](protocol.md#9-status-kv-acc_status).

### Heartbeat

The heartbeat publishes `{"code","location","ts"}` to
`acc.{location}.ctrl.{code}.heartbeat` over core NATS. The subject sits
outside the `.evt` subtree, so `ACC_EVENTS` never stores it. accessd updates
the `controllers` record from it and marks the box offline after
`accessd.controllerOfflineAfter` (default `45s`). No heartbeat is sent when
`controller.code` is empty. See
[Controller heartbeat](protocol.md#controller-heartbeat).

---

## 5. The Local Status Page

The controller can serve a read-only status page for install and field
troubleshooting ([`internal/diag`](https://github.com/stone-age-io/access-control/blob/main/internal/diag)). It shows this box's
live in-memory state: identity, NATS and policy health, the portals it is
bound to with their door and posture state, aux I/O, fire suppression, and
recent decisions and alarms.

### Turning it on

```yaml
diagnostics:
  enabled: true                # default false
  address: "127.0.0.1:2115"    # default; localhost only
```

Env vars: `SA_DIAGNOSTICS_ENABLED`, `SA_DIAGNOSTICS_ADDRESS`. It runs its own
HTTP server, separate from metrics. Reach it over SSH or a tunnel, for example
`ssh -L 2115:127.0.0.1:2115 box` and then `http://localhost:2115/`.

::: warning No authentication
The page has no login. It shows portal codes, locations, reader addresses
and the raw credential value of every recent tap. Keep `address` on
localhost. Do not bind it to a public or shared interface.
:::

The page is strictly read-only. It changes no state and exposes no control
path; all control stays on the NATS command plane.

### Routes

| Route | Returns |
| :--- | :--- |
| `/` | Redirects (302) to `/status`. Any other unknown path is 404. |
| `/status` | A self-contained HTML page: inline CSS and script, no external assets, light and dark. Works on a box with no network. |
| `/status.json` | The same report as indented JSON. |

### What the page shows

**Header.** The controller code (`(no controller code)` if unset), its
location, reader, driver and model, and two badges:

| Badge | Meaning |
| :--- | :--- |
| `policy synced` | State `synced`. |
| `OFFLINE · cached config` | State `cached`: running on the offline snapshot. |
| `DEFAULT-DENY · policy not loaded` | State `loading`. |
| `NATS connected` / `NATS disconnected` | The live connection state. |

**Identity & connectivity.** `controller`, `location`, `subjects.app`,
`reader / driver (model)`, the NATS server URL (or `disconnected`) with the
reconnect count, and process uptime.

**Policy.** One tile per record kind loaded into memory: areas, aux inputs,
aux outputs, bindings, controllers, credentials, groups, holidays, portals,
roles, schedules and users. A zero count is dimmed. When the state is
`cached`, a notice gives the snapshot's time and says changes since then are
not applied.

**Bound portals.** Every portal whose `controller` is this code, sorted by
code. A row is highlighted when the portal is bound but not armed. If none are
bound, a banner says to check `controller.code` and the portal assignments in
accessd.

| Column | Shows |
| :--- | :--- |
| portal, type | The portal code and type. |
| state | `armed`, or `bound, not armed`. |
| posture | The effective posture and, in brackets, its source: `standing`, `scheduled` or `override`. |
| door | `open`, `closed` or `unknown`, plus `auth` while a grant or REX authorized-open window is running. |
| held | `HELD` while a held-open alarm is active. |
| override | The runtime posture override, if any. |
| relay | The logical lock relay index, plus `maglock` for a fail-safe lock. |
| DPS | The logical DPS input and its contact sense (`N.C.` default, `N.O.` when inverted), when wired. |
| REX | The logical REX input and its sense (`N.O.` default, `N.C.` when inverted), plus `unlock` when `rex_unlock` is set. |
| DOTL | `held_open_seconds`. |
| OSDP | The portal's `reader_address`. |

Indices are logical; the profile maps them to physical lines (see
[Hardware & Readers](hardware.md)).

**Fire inputs (alarm suppression).** Shown only while a location's fire input
is active, as `ACTIVE · alarms suppressed`. Suppression also needs the
location's `fai_suppress`, which the page does not show.

**Aux I/O.** Each aux output (`energized` or `off`) and aux input (`active` or
`inactive`) armed on this box, with its location.

**Recent decisions.** The last 50 taps, newest first: time (UTC), portal,
credential value, user id, `ALLOW` or `DENY`, and the reason code. Commanded
grants are not listed here.

**Recent alarms.** The last 50 alarms this box published, newest first: time,
portal and kind (`forced`, `held`, `held_clear`, `no_entry`, `intrusion`). For
`intrusion` the portal column holds the **area** code. An alarm suppressed by
fire is not listed.

**Footer.** The generation time, the Go version, and the build's VCS revision
(first 12 characters, `+dirty` if modified) and time when the binary was built
from a checkout.

The page has no area panel. A box's area arm-state is its `area.*` shadow in
`ACC_STATUS`, shown on the console.

### Refresh

The page refetches `/status` every 5 s and swaps the content in place, so the
scroll position survives. A sticky bar shows `updated Ns ago`, a **Pause** /
**Resume** button and a **Refresh** button that fetches once now. If a fetch
fails, the bar shows `connection lost · retrying` and keeps trying. Without
JavaScript the page shows a note and you reload it by hand.

### JSON shape

`/status.json` returns a fresh report on each request. Field names come from
the Go structs in [`diag.go`](https://github.com/stone-age-io/access-control/blob/main/internal/diag/diag.go) and
[`snapshot.go`](https://github.com/stone-age-io/access-control/blob/main/internal/controller/snapshot.go):

```json
{
  "generatedAt": "2026-10-08T14:02:11Z",
  "identity": {
    "controller": "ctrl-hq-1", "location": "hq", "subjectsApp": "acc",
    "driver": "gpio", "model": "kincony-server-mini", "reader": "osdp",
    "startedAt": "2026-10-08T10:50:07Z", "uptime": "3h12m4s"
  },
  "build": { "goVersion": "go1.26.0", "revision": "2d49ce6…", "time": "2026-10-07T09:12:00Z", "modified": false },
  "nats": { "connected": true, "url": "tls://nats.example.com:4222", "reconnects": 1 },
  "policy": {
    "synced": true, "state": "synced", "syncedAt": "0001-01-01T00:00:00Z",
    "counts": {
      "areas": 1, "auxInputs": 2, "auxOutputs": 1, "bindings": 4, "controllers": 2,
      "credentials": 120, "groups": 6, "holidays": 10, "portals": 4, "roles": 5,
      "schedules": 3, "users": 95
    }
  },
  "portals": [{
    "code": "lobby-main", "type": "door", "location": "hq", "armed": true,
    "posture": "secure", "source": "standing", "door": "closed", "held": false,
    "override": "", "authOpen": false,
    "lockRelay": 1, "dpsInput": 1, "rexInput": 2, "heldOpenSeconds": 30,
    "readerAddress": 0,
    "maglock": false, "dpsInvert": false, "rexInvert": false, "rexUnlock": false
  }],
  "fire": null,
  "auxOutputs": [{ "code": "lobby-gate", "location": "hq", "energized": false, "active": false }],
  "auxInputs": [],
  "decisions": [{
    "at": "2026-10-08T14:01:58Z", "portal": "lobby-main", "cred": "CARD-001",
    "user": "<cardholder id>", "allow": true, "reason": "allow_grant"
  }],
  "alarms": [{ "at": "2026-10-08T13:40:02Z", "portal": "lobby-main", "kind": "held" }]
}
```

Notes for scripts:

- `policy.state` is `synced`, `cached` or `loading`. `policy.synced` is true
  only for `synced`. `syncedAt` is the cache's freshness time and is the zero
  time unless the state is `cached`.
- `portals` and `fire` are `null` when empty. `fire` lists only active
  locations.
- For a portal with `armed: false`, the live fields (`posture`, `source`,
  `door`, `held`, `override`, `authOpen`) are empty or false. The binding
  fields are still filled.
- An aux point carries both `energized` and `active`. `energized` applies to
  outputs and `active` to inputs.
- `decisions` and `alarms` are newest first, at most 50 each.

### Field troubleshooting

| Symptom | Check |
| :--- | :--- |
| `DEFAULT-DENY · policy not loaded` | NATS is unreachable, or the `ACC_POLICY` bucket does not exist yet (accessd has never served). Check the NATS badge and the logs for `policy KV watcher not established`. Check `policy.bucket` matches accessd. |
| `OFFLINE · cached config` | The box rebooted with NATS down and is deciding on the snapshot. Restore NATS; it switches to `synced` on the next sync. |
| `policy synced` but `NATS disconnected` | The box lost NATS after syncing. It keeps deciding; events are held in memory until it reconnects. |
| No portals bound | `controller.code` does not match the code on the portals' `controller` relation, or the controller record is missing. |
| A portal shows `bound, not armed` | Search the logs for `failed to arm portal hardware` or `failed to arm portal reader`. Usual causes: a relay or input index not on the board, a busy GPIO line, an OSDP `reader_address` of `-1` under `reader: osdp`, an address shared with another portal, or a portal with no type. It retries only on the next policy change, so fix the record and save it. |
| Portal is armed but taps never reach the decision list | Under `nats`, publish to the exact `acc.{location}.{type}.{thing}.tap`. Under `osdp`, check `reader_address` against the reader's PD address and the logs for `card read from unmapped PD address`. |
| Every tap denies | Read the reason code. `deny_unknown_credential` means the credential value is not in policy (OSDP reads arrive as lowercase hex). Compare the Policy tiles with what you expect. |
| `door` stays `unknown` | `driver: mock`, no DPS wired (`dpsInput` is 0), or no DPS edge since boot. |
| `door` reads `open` with the door shut | The contact sense is inverted. Set `dps_contact` on the portal; do not rewire. |
| Posture shows `override` | A `cmd.posture` is in force. Send `posture: "clear"` to revert. |
| The door opens with no tap listed | The posture is `unlocked` (the strike is held), a REX with `rex_unlock` pulsed it, or a `cmd.grant` opened it (commanded grants are not listed). |
| Commands or fire are ignored for one portal | The portal's location differs from `controller.location`. Look for `portal location differs from controller location`. |
| Box shows offline in the console but the page looks healthy | Check the NATS badge and that `controller.code` is set. accessd marks a box offline when heartbeats stop. |

---

## 6. Observability

### Metrics

Set `metrics.enabled: true` to serve Prometheus metrics at `metrics.path`
(default `/metrics`) on `metrics.address`. The code default address is `:2113`;
the shipped `config/controller.yaml` enables metrics on `:2114` so both
binaries can share a host. See [Metrics](configuration.md#4-metrics).

The controller exports these ([`internal/metrics`](https://github.com/stone-age-io/access-control/blob/main/internal/metrics/metrics.go)):

| Metric | Type | Labels | Meaning |
| :--- | :--- | :--- | :--- |
| `access_decisions_total` | counter | `allow`, `reason` | Tap decisions by outcome and reason code. |
| `taps_dropped_total` | counter | | Taps dropped because a reader's queue was full. |
| `policy_kv_applies_total` | counter | `op` (`put`, `delete`) | Policy records applied from the watch (and from a cache replay). |
| `policy_kv_watch_state` | gauge | | `1` after a sync; `0` before the first sync and while the watcher is being re-established. |
| `events_published_total` | counter | `kind` (`tap`, `state`, `alarm`, `fire`) | Events handed to NATS. |
| `controller_heartbeats_sent_total` | counter | | Heartbeats published. |
| `nats_connection_status` | gauge | | `1` connected, `0` disconnected. |
| `nats_reconnects_total` | counter | | NATS reconnections. |
| `process_goroutines` | gauge | | Goroutines, refreshed every `metrics.updateInterval`. |
| `process_memory_bytes` | gauge | | Allocated heap bytes, refreshed the same way. |

The binaries share one metrics package. accessd's labelled counters
(`audit_writes_total`, `notify_sends_total`, `webhook_posts_total`,
`disarm_sink_total`, `controller_heartbeats_received_total`) are registered
but never incremented here, so they do not appear. The registry carries no
Go runtime or process collectors beyond the two gauges above.

For alerting on connectivity, use `nats_connection_status`. The watch-state
gauge drops to `0` only when the watcher is being rebuilt, not for the whole
outage.

### Logs

Logs are JSON on stdout by default (`logging.*`). Every line carries
`app: access-controller`, `controller` and `location`, and most carry a
`component`: `natsx`, `policystore`, `policycache`, `statuswriter`, `runtime`,
`portal-manager`, `aux-manager`, `area-manager`, `commands`, `heartbeat`,
`nats-reader`, `osdp-reader`, `osdp-bus`, `multi-reader`, `gpio`, `i2c` or
`diagnostics`. The time key is `timestamp` (ISO 8601). The logger samples:
after the first 100 identical messages in a second, it keeps every 100th.

Lines worth searching for:

| Message | Means |
| :--- | :--- |
| `controller started; default-deny until policy syncs` | Startup finished. |
| `policy synced; controller live` | The first live sync landed. |
| `controller operating on CACHED config until policy syncs (NATS may be unreachable)` | Booted from the offline cache. |
| `policy cache too stale; refusing it (fail-secure default-deny)` | The snapshot was older than `maxAge`. |
| `NATS not reachable at startup; retrying in background` | Cold boot with no server. |
| `tap decided` | One per tap: `portal`, `cred`, `allow`, `reason`, `user`. |
| `failed to arm portal hardware; will retry on next policy change` | A portal stayed unarmed. |
| `portal location differs from controller location` | The portal will not receive commands or fire. |
| `tap queue full; dropping tap` | The tap loop fell behind. |
| `alarm suppressed (fire active)` | A door alarm was not published during fire. |
| `posture 'until' is not enforced by the controller; ignoring` | A posture command carried `until`. |

::: note Credential values reach the logs
`tap decided` logs the raw credential value at `info`, and the offline cache
file stores every credential. Treat the box's logs and its data directory as
sensitive.
:::

---

## 7. What Listens and What Dials Out

| | Direction | Port | When |
| :--- | :--- | :--- | :--- |
| NATS: policy watch, events, status, heartbeat, commands, taps | **outbound** | 4222 (or your hub's) | always |
| OSDP readers | local RS485 | the model's serial port | `reader: osdp` or `both` |
| Status page (`/status`, `/status.json`) | **listens** | `127.0.0.1:2115` | only when `diagnostics.enabled` |
| Prometheus `/metrics` | **listens** | `metrics.address` (`:2114` in the example config, all interfaces) | only when `metrics.enabled` |

Nothing can instruct a controller except over the NATS connection it opened
itself. Neither HTTP listener has authentication. If you move the metrics port
off a trusted network, put it behind a firewall.

A controller's NATS identity needs:

- **Subscribe:** `acc.{location}.*.*.cmd.posture`, `.cmd.grant` and
  `.cmd.output`; `acc.{location}.evt.fire`; and, under `reader: nats` or
  `both`, each armed portal's `.tap` subject.
- **Publish:** `acc.{location}.{type}.{thing}.evt.>` for its portals,
  `acc.{location}.area.{code}.evt.alarm` for its areas,
  `acc.{location}.evt.fire` if it owns a fire input, and
  `acc.{location}.ctrl.{code}.heartbeat`.
- **JetStream KV:** read and watch `ACC_POLICY`; put and delete in
  `ACC_STATUS`.

Use one NATS identity per controller.

---

## 8. Where to Go Next

- The central service and which binary owns what: [Central Service (accessd)](accessd.md)
- Boards, pin maps, wiring sense and OSDP readers: [Hardware & Readers](hardware.md)
- Every config key, default and env var: [Configuration Reference](configuration.md)
- Subjects, KV shapes, reason codes and the audit projection: [Wire Protocol](protocol.md)
- Who may edit controllers, portals and aux points: [Operators & Authorization](operators.md)
- The system overview: [Access Control](../README.md)
