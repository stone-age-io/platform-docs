---
path: access-control/hardware
nav_order: 40
---
# stone-access hardware integration

How an `access-controller` drives physical doors. The authorization **decision**
is a pure function that runs centrally and at the edge (`internal/policy`); this
page is only about the **edge box's I/O** — the relays it energizes and the door
inputs it reads. For the config keys that select hardware see
[`configuration.md`](configuration.md); for *why* the driver layer is shaped this
way see `CLAUDE.md`.

## At a glance

| Board | Model string | Transport | Relays | Inputs | Status |
|---|---|---|---|---|---|
| KinCony Server-Mini (Pi CM4) | `kincony-server-mini` | native GPIO char device | 8 | 8 | pin map verified; polarity bench-item |
| KinCony Pi5R8 (Pi CM5) | `kincony-pi5r8` | MCP23017 over I2C | 8 | 8 | topology from KinCony flow; polarity + 2nd expander bench-items |

Both run on Linux edge hardware only. Each supports three **reader** options — a
simulated NATS reader (default), a real OSDP reader on the board's RS485 bus, or
both at once (see [below](#readers-nats-osdp-or-both)).

## The model

**Logical, not physical, in policy.** A portal record carries *logical* 1-based
indices — `lockRelay`, `dpsInput`, `rexInput` — plus the `controller` that drives
it; aux points carry the same (`relay_index` / `input_index`, see
[Auxiliary I/O](#auxiliary-io-and-the-fire-input)). The controller resolves those
indices to physical lines through the **profile** (`internal/drivers/hardware`)
named by its local `controller.model`. So rewiring a door to a different relay, or
swapping the box for a spare, is a policy edit — the controller's local config is
just its identity (`controller.code`) and hardware selection (`controller.driver` /
`controller.model`). Logical index *N* maps to the board's labelled **OUT*N*** /
**IN*N***. The `controllers` record's `model` is what the console uses (via
`GET /api/models`) to draw the controller I/O map and bound the index pickers;
nothing checks it against the box's `controller.model`, so keep the two in step.

**Transport is chosen by the model, not config.** `controller.driver: mock`
(default) drives no I/O. `controller.driver: gpio` means "real hardware"; the
`model`'s `Profile.Transport()` then selects the backend — native GPIO
(`internal/drivers/gpio`) or MCP23017 I2C (`internal/drivers/i2c`). Neither the
binary nor the config differs per board.

**Polarity** is encoded per line in the profile, not in config:

- **Relays — active-high.** A logical "energize" drives the line/latch high
  (relay ON). The line boots and returns to low (de-energized), except a
  maglock's lock relay, which `lock_type` inverts (below).
- **Inputs — active-low with pull-up.** The isolated input asserts by pulling to
  GND; an open contact reads inactive. The driver enables a pull-up and treats
  the low state as "active" (GPIO `AsActiveLow`; MCP23017 `IPOL`).

**Wiring sense is per install, in policy.** On top of the board polarity, each
portal/aux record says how *this* site is wired, and the backend XORs it into the
line's active-low (`drivers.PortalIO`) — so a contact wired the other way is a
field edit, not a rewire:

| Field | Values (default first) | Effect |
|---|---|---|
| `portals.dps_contact` | `nc` · `no` | door-position contact; `nc` = closed when the door is shut. `no` inverts. |
| `portals.rex_contact` | `no` · `nc` | request-to-exit contact; `no` = closed when pressed. `nc` inverts. |
| `aux_input.contact` | `no` · `nc` | aux input contact; `nc` inverts. |
| `portals.lock_type` | `strike` · `maglock` | `strike` is fail-secure (energize to unlock). `maglock` is fail-safe (energize to **lock**), so it inverts the lock relay: it idles energized and drops for a grant. |
| `portals.rex_unlock` | off · on | off: REX only opens the authorized-open window (egress is mechanical). On: a REX press also pulses the lock for the portal's `pulse_seconds`. |

Changing any of these (or an index) re-arms the portal's lines with the new
polarity. Aux outputs take no `lock_type`, so they are always driven
energize-to-activate.

**Fail-safe everywhere.** Each lock relay starts in its idle (locked) state when
armed and goes back to it on disarm and on graceful shutdown (`Close`). For a
strike that is de-energized, and for a maglock energized. Egress stays
hardware-owned. A killed process runs no cleanup (the MCP23017's output latch
keeps its last value), but the next boot drives every line it arms back to idle
before using it. An unknown `controller.model` stops the controller at boot. A
lock relay index that is unset (`0`) or not on the board is rejected, and so is
an undefined input index; an input index of `0` means "not wired" and is skipped.
A portal whose hardware or reader fails to arm is left fully unarmed (no lock, no
reader) and retried on the next policy change. An I2C input read error keeps the
last known state. A pulse defaults to **5 s** when neither the portal nor the
command sets one.

**Door monitoring.** DPS (door-position) and REX inputs feed the controller's
per-door state machine (`internal/controller/runtime.go`):

- A grant or REX press opens a **10 s** authorized-open window. A door-open inside
  it is normal passage and starts the held-open (DOTL) timer from the portal's
  `held_open_seconds`, where `0` disables held-open. A door-open outside the
  window raises `forced`, and if the portal is a member of an armed area it also
  raises that area's `intrusion`.
- `held` fires once per open episode, and `held_clear` when the door closes.
- `no_entry` (a grant whose window passed with no door-open) is reported 10–20 s
  late on the hold-eval tick. It only fires where an open is observable: the
  portal has a `dps_input` **and** the box runs a real driver. Under
  `driver: mock` there are no door inputs, so it never fires.
- Door state reads *unknown* until the first DPS edge. GPIO inputs get a 5 ms
  kernel debounce; I2C inputs are polled every ~50 ms.

The held-open threshold, wiring sense, and relay/input indices ride the **portal
record** in policy, never the pure decision.

## KinCony Server-Mini (CM4) — `kincony-server-mini`

Native GPIO: 8 relays and 8 isolated inputs wired directly to the CM4's
Broadcom GPIO. Driven over the Linux GPIO character device via `go-gpiocdev`
(**no cgo**). The chip is `gpiochip0` (the BCM2711 bank); line offset = BCM
number.

Relays (logical → BCM):

| Logical | Label | BCM | | Logical | Label | BCM |
|---|---|---|---|---|---|---|
| relay 1 | OUT1 | 5 | | relay 5 | OUT5 | 6 |
| relay 2 | OUT2 | 22 | | relay 6 | OUT6 | 13 |
| relay 3 | OUT3 | 17 | | relay 7 | OUT7 | 19 |
| relay 4 | OUT4 | 4 | | relay 8 | OUT8 | 26 |

Inputs (logical → BCM):

| Logical | Label | BCM | | Logical | Label | BCM |
|---|---|---|---|---|---|---|
| input 1 | IN1 | 18 | | input 5 | IN5 | 12 |
| input 2 | IN2 | 23 | | input 6 | IN6 | 16 |
| input 3 | IN3 | 24 | | input 7 | IN7 | 20 |
| input 4 | IN4 | 25 | | input 8 | IN8 | 21 |

The pin map is **verified against KinCony's published CM4 pin definition**. Relay
and input **polarity** follows the board's wiring convention — confirm on the
bench before production.

Other peripherals the board breaks out: **RS485** on BCM 14/15 (`TXD0`/`RXD0`),
exposed as `/dev/ttyAMA0` — the OSDP reader bus for this model; **I2C-1** on BCM
2/3; a 433 MHz receiver on BCM 27.

## KinCony Pi5R8 (CM5) — `kincony-pi5r8`

All 16 relay/input lines hang off a **single MCP23017 I2C expander at `0x20` on
bus 1 (`/dev/i2c-1`)** — the CM5's native GPIO is not used for door I/O. The bus
is driven by the pure-Go **periph.io** stack (no cgo). The MCP23017 has no
host-side edge delivery without wiring its INT line to a GPIO, so inputs are read
by **polling** (~50 ms): a single goroutine samples the input ports and emits an
event on each change.

The MCP23017's two 8-bit ports split the I/O — inputs on Port A, relays on Port B:

| Logical | Label | MCP23017 pin | Port |
|---|---|---|---|
| input 1–8 | IN1–IN8 | 0–7 | A (pull-up, active-low) |
| relay 1–8 | OUT1–OUT8 | 8–15 | B (active-high) |

So relay *N* = pin `7+N` and input *N* = pin `N-1`. Relays sharing Port B's output
latch are written through a cached shadow register, so driving one relay never
disturbs the others.

The topology (chip, address, bus, port split) is taken from KinCony's reference
Node-RED flow. Two items to confirm on the bench: relay **polarity** (assumed
active-high), and a **second MCP23017 at `0x22`** that appears in the flow but is
wired to nothing — likely an expansion variant; only `0x20` is modelled.

Other devices on the same bus (the driver claims only `0x20`): an ADS1115 ADC at
`0x48`, an SSD1306 OLED at `0x3C`. Serial: **RS485** on `/dev/ttyAMA2` (CM5 UART2,
GPIO 4/5) — the OSDP reader bus for this model; **RS232** on `/dev/ttyAMA0`.

## Auxiliary I/O and the fire input

The relays and inputs a portal doesn't use are available as standalone points,
bound to a controller in policy like portals and armed by the controller's
`AuxManager`:

- **`aux_output`** — a relay (`relay_index`) driven by `cmd.output` on
  `acc.{location}.auxout.{code}.cmd.output` with `on` / `off` (standing state) or
  `pulse` (seconds from the command, else the record's `pulse_seconds`, else 5 s).
- **`aux_input`** — an input (`input_index`, `contact`) whose edges arrive on the
  same input stream as DPS/REX. Its `point_type` decides what an edge means:
  `monitor` (the default) is observe-only; `intrusion` raises its area's
  `intrusion` alarm on an active edge while the area is armed; `tamper_24h`
  raises it whatever the arm-state; `fire` is the location's fire-alarm interface.

**Fire is an aux input, not a driver.** There is no fire-specific interface or
board line any more. Wire the fire panel's dry contact to any free input and
create an `aux_input` with `point_type: fire`. The owning controller publishes
`acc.{location}.evt.fire` on **both** edges, and every controller at that location
applies it. While it is asserted, door and intrusion alarms are suppressed, but
only if the location sets `fai_suppress`; `held_clear` is never suppressed.
Software never unlocks for fire: the panel's relay drops maglock power directly.

Aux inputs, like DPS, report **edges only**: a point is assumed inactive when
armed, so a contact that is already asserted when the box boots (a fire panel
already in alarm, an open zone) is not reported until it clears and asserts
again.

## Readers: NATS, OSDP, or both

`controller.reader` picks how credentials arrive, independent of the lock/door
driver (the strike and DPS/REX stay on GPIO/I2C either way). Each tap event
carries a `source` (`nats` / `osdp`), so a physical read can be told apart from a
NATS-published tap in the audit trail.

- **`nats`** (default) — simulated taps published to
  `acc.{location}.{type}.{thing}.tap` (see [`protocol.md`](protocol.md)); drive it
  with `nats pub` for dev and integration. No reader hardware.
- **`osdp`** — a real OSDP reader (the controller is the ACU/CP) polled on the
  model's RS485 bus at 9600 baud (`/dev/ttyAMA2` on the Pi5R8, `/dev/ttyAMA0` on
  the Server-Mini). All readers on the bus share the one port; each portal's reader
  sits at its `reader_address` (OSDP PD address `0`–`126`, default 0). Two portals
  claiming one address, or a portal with `reader_address: -1`, fail to arm under
  this mode, so that portal is not driven at all. A card from an address no portal
  claims is dropped. Pure-Go, no cgo (`internal/drivers/osdp`, mirroring libosdp's
  CP design; a reader goes offline after 8 failed exchanges and is re-initialized
  10 s later). **v1 is clear-text;** OSDP Secure Channel (SCBK/AES) is a planned
  fast-follow.
- **`both`** — NATS for **every** portal plus OSDP for the portals with a physical
  reader. `reader_address >= 0` puts the portal's reader on the bus at that
  address; `-1` makes it NATS-only, and it never touches the bus. Taps from both
  readers feed one stream (`internal/controller/multireader.go`). Use this when
  some of a box's portals have a physical reader and some don't.

**Bench items for OSDP:** (a) **RS485 direction** — v1 assumes the board's
auto-direction transceiver; if a board needs explicit DE/RE toggling, add the
`TIOCSRS485` ioctl at port open (`internal/drivers/osdp/transport_linux.go`).
(b) **Credential format** — a card read maps to the lowercase hex of the raw card
bytes; decimal/Wiegand decoding depends on the reader's bit order and is deferred
until confirmed against a physical reader. (c) Many readers ship
**secure-channel-required**; v1 bring-up may need the reader in clear-text / install
mode.

## Adding a board

The driver layer is data-first: a new board that uses an **existing transport** is
just a new `Profile`.

1. Add a `Profile` to `internal/drivers/hardware` (`profile.go`): the `relays` and
   `inputs` maps, each line a `LineSpec` — `gpioRelay`/`gpioInput` for native GPIO,
   `i2cLine` for an expander — plus `serial` (the RS485 `SerialPort`) if the board
   can host an OSDP reader. Keep logical index *N* = OUT*N* / IN*N*.
2. Widen the `controllers.model` select with a new additive migration in
   `pbmigrations`, and add the model to [`configuration.md`](configuration.md).
3. Add it to the UI's model list: the `ControllerModel` union
   (`ui/src/types/pocketbase.ts`), `MODELS` in `ControllerFormView.vue`, and the
   transport label in `reports/WiringReport.vue`, then rebuild the embedded UI.
   The I/O map and index pickers need nothing: they read `GET /api/models`, which
   is built from the compiled-in profiles.
4. That's it for an existing transport — `Profile.Transport()` routes the new model
   to the matching backend automatically.

A board on a **new transport or expander chip** also needs a backend implementing
`controller.PortalHardware` + `controller.AuxHardware` + `drivers.DoorInput` +
`Close()` (the GPIO and I2C packages are the two worked examples), plus a
`hardware.Backend` value and a case in the backend selection in
`cmd/access-controller/main.go`.

## Bench checklist

Before trusting a board in production, confirm on the bench:

- **Relay polarity** — energizing a logical relay actually closes the strike
  circuit (both boards assume active-high). For a maglock portal
  (`lock_type: maglock`), confirm the idle state holds the door locked and a grant
  drops it.
- **Input polarity / contact sense** — with the default `dps_contact: nc`, a shut
  door reads "closed"; a REX press reads active with `rex_contact: no`. If the
  site is wired the other way, set the field and don't rewire.
- **Fire input** — asserting the panel contact publishes `evt.fire` for the
  location (and suppresses alarms if `fai_suppress` is set); clearing it publishes
  the clear.
- **Pi5R8 only** — whether the `0x22` second expander exists and carries any I/O,
  and that the ~50 ms poll latency is acceptable for REX/forced detection.

The console's **Reports → Wiring / As-Built** sheet lists every portal and aux
point's binding, contact sense, and lock type, grouped by location. It is the
commissioning record to check the bench against.
