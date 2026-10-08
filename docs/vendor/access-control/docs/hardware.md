---
path: access-control/hardware
nav_order: 40
---
# Hardware & Readers

This page covers how an `access-controller` drives physical doors: the relays
it energizes, the door inputs it reads, and the readers that deliver
credentials. The authorization decision is a pure function that runs centrally
and at the edge (`internal/policy`), and is not covered here. For the config
keys that select hardware, see [Configuration Reference](configuration.md).
The design rationale for the driver layer is in the repo's `CLAUDE.md`.

---

## 1. Supported Boards

| Board | Model string | Transport | Relays | Inputs | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| KinCony Server-Mini (Pi CM4) | `kincony-server-mini` | native GPIO char device | 8 | 8 | pin map verified; polarity bench-item |
| KinCony Pi5R8 (Pi CM5) | `kincony-pi5r8` | MCP23017 over I2C | 8 | 8 | topology from KinCony flow; polarity + 2nd expander bench-items |

Both run on Linux edge hardware only. Each supports three reader options: a
simulated NATS reader (the default), a real OSDP reader on the board's RS485
bus, or both at once (see [§6](#6-readers)).

---

## 2. The I/O Model

### Logical indices, not physical lines

A portal record carries **logical** 1-based indices (`lockRelay`, `dpsInput`,
`rexInput`) plus the `controller` that drives it. Aux points carry the same
(`relay_index` / `input_index`, see [§5](#5-auxiliary-io-and-the-fire-input)).
The controller resolves those indices to physical lines through the
**profile** (`internal/drivers/hardware`) named by its local
`controller.model`.

So rewiring a door to a different relay, or swapping the box for a spare, is a
policy edit. The controller's local config is just its identity
(`controller.code`) and hardware selection (`controller.driver` /
`controller.model`). Logical index *N* maps to the board's labelled **OUT*N***
/ **IN*N***.

::: warning Keep the two `model` values in step
The console uses the `controllers` record's `model` (through
`GET /api/models`) to draw the controller I/O map and bound the index
pickers. Nothing checks it against the box's `controller.model`.
:::

### Transport comes from the model

`controller.driver: mock` (the default) drives no I/O.
`controller.driver: gpio` means "real hardware", and the `model`'s
`Profile.Transport()` then selects the backend: native GPIO
(`internal/drivers/gpio`) or MCP23017 I2C (`internal/drivers/i2c`). Neither the
binary nor the config differs per board.

### Polarity

Polarity is encoded per line in the profile, not in config:

- **Relays are active-high.** A logical "energize" drives the line or latch
  high (relay ON). The line boots and returns to low (de-energized), except a
  maglock's lock relay, which `lock_type` inverts (below).
- **Inputs are active-low with pull-up.** The isolated input asserts by pulling
  to GND, and an open contact reads inactive. The driver enables a pull-up and
  treats the low state as "active" (GPIO `AsActiveLow`; MCP23017 `IPOL`).

### Wiring sense

On top of the board polarity, each portal and aux record says how *this* site
is wired. The backend XORs it into the line's active-low (`drivers.PortalIO`),
so a contact wired the other way is a field edit, not a rewire:

| Field | Values (default first) | Effect |
| :--- | :--- | :--- |
| `portals.dps_contact` | `nc` · `no` | Door-position contact. `nc` = closed when the door is shut; `no` inverts. |
| `portals.rex_contact` | `no` · `nc` | Request-to-exit contact. `no` = closed when pressed; `nc` inverts. |
| `aux_input.contact` | `no` · `nc` | Aux input contact; `nc` inverts. |
| `portals.lock_type` | `strike` · `maglock` | `strike` is fail-secure (energize to unlock). `maglock` is fail-safe (energize to **lock**), so it inverts the lock relay: it idles energized and drops for a grant. |
| `portals.rex_unlock` | off · on | Off: REX only opens the authorized-open window (egress is mechanical). On: a REX press also pulses the lock for the portal's `pulse_seconds`. |

Changing any of these (or an index) re-arms the portal's lines with the new
polarity. Aux outputs take no `lock_type`, so they are always driven
energize-to-activate.

### Fail-safe behaviour

- Each lock relay starts in its idle (locked) state when armed, and returns to
  it on disarm and on graceful shutdown (`Close`). For a strike that is
  de-energized; for a maglock, energized. Egress stays hardware-owned.
- A killed process runs no cleanup (the MCP23017's output latch keeps its last
  value). The next boot drives every line it arms back to idle before using
  it.
- An unknown `controller.model` stops the controller at boot.
- A lock relay index that is unset (`0`) or not on the board is rejected, and
  so is an undefined input index. An input index of `0` means "not wired" and
  is skipped.
- A portal whose hardware or reader fails to arm is left fully unarmed (no
  lock, no reader) and retried on the next policy change.
- An I2C input read error keeps the last known state.
- A pulse defaults to **5 s** when neither the portal nor the command sets one.

### Door monitoring

DPS (door-position) and REX inputs feed the controller's per-door state
machine (`internal/controller/runtime.go`):

- A grant or REX press opens a **10 s** authorized-open window. A door-open
  inside it is normal passage and starts the held-open (DOTL) timer from the
  portal's `held_open_seconds`, where `0` disables held-open. A door-open
  outside the window raises `forced`. If the portal is a member of an armed
  area, it also raises that area's `intrusion`.
- `held` fires once per open episode, and `held_clear` when the door closes.
- `no_entry` (a grant whose window passed with no door-open) is reported
  10 to 20 s late, on the hold-eval tick. It fires only where an open is
  observable: the portal has a `dps_input` **and** the box runs a real driver.
  Under `driver: mock` there are no door inputs, so it never fires.
- Door state reads *unknown* until the first DPS edge. GPIO inputs get a 5 ms
  kernel debounce; I2C inputs are polled every ~50 ms.

The held-open threshold, wiring sense, and relay and input indices ride the
**portal record** in policy, never the pure decision.

---

## 3. KinCony Server-Mini (CM4)

Model string `kincony-server-mini`. Native GPIO: 8 relays and 8 isolated
inputs wired directly to the CM4's Broadcom GPIO, driven over the Linux GPIO
character device through `go-gpiocdev` (**no cgo**). The chip is `gpiochip0`
(the BCM2711 bank), and line offset = BCM number.

Relays (logical → BCM):

| Logical | Label | BCM | | Logical | Label | BCM |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| relay 1 | OUT1 | 5 | | relay 5 | OUT5 | 6 |
| relay 2 | OUT2 | 22 | | relay 6 | OUT6 | 13 |
| relay 3 | OUT3 | 17 | | relay 7 | OUT7 | 19 |
| relay 4 | OUT4 | 4 | | relay 8 | OUT8 | 26 |

Inputs (logical → BCM):

| Logical | Label | BCM | | Logical | Label | BCM |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| input 1 | IN1 | 18 | | input 5 | IN5 | 12 |
| input 2 | IN2 | 23 | | input 6 | IN6 | 16 |
| input 3 | IN3 | 24 | | input 7 | IN7 | 20 |
| input 4 | IN4 | 25 | | input 8 | IN8 | 21 |

The pin map is **verified against KinCony's published CM4 pin definition**.
Relay and input **polarity** follows the board's wiring convention; confirm it
on the bench before production.

Other peripherals the board breaks out:

- **RS485** on BCM 14/15 (`TXD0`/`RXD0`), exposed as `/dev/ttyAMA0`. This is
  the OSDP reader bus for this model.
- **I2C-1** on BCM 2/3.
- A 433 MHz receiver on BCM 27.

---

## 4. KinCony Pi5R8 (CM5)

Model string `kincony-pi5r8`. All 16 relay and input lines hang off a **single
MCP23017 I2C expander at `0x20` on bus 1 (`/dev/i2c-1`)**. The CM5's native
GPIO is not used for door I/O. The bus is driven by the pure-Go **periph.io**
stack (no cgo).

The MCP23017 has no host-side edge delivery unless its INT line is wired to a
GPIO, so inputs are read by **polling** (~50 ms): one goroutine samples the
input ports and emits an event on each change.

The MCP23017's two 8-bit ports split the I/O, with inputs on Port A and relays
on Port B:

| Logical | Label | MCP23017 pin | Port |
| :--- | :--- | :--- | :--- |
| input 1–8 | IN1–IN8 | 0–7 | A (pull-up, active-low) |
| relay 1–8 | OUT1–OUT8 | 8–15 | B (active-high) |

So relay *N* = pin `7+N` and input *N* = pin `N-1`. Relays that share Port B's
output latch are written through a cached shadow register, so driving one
relay never disturbs the others.

The topology (chip, address, bus, port split) comes from KinCony's reference
Node-RED flow. Two items to confirm on the bench:

- Relay **polarity** (assumed active-high).
- A **second MCP23017 at `0x22`** that appears in the flow but is wired to
  nothing. It is likely an expansion variant; only `0x20` is modelled.

Other devices on the same bus (the driver claims only `0x20`): an ADS1115 ADC
at `0x48` and an SSD1306 OLED at `0x3C`. Serial ports:

- **RS485** on `/dev/ttyAMA2` (CM5 UART2, GPIO 4/5). This is the OSDP reader
  bus for this model.
- **RS232** on `/dev/ttyAMA0`.

---

## 5. Auxiliary I/O and the Fire Input

The relays and inputs a portal does not use are available as standalone
points. They are bound to a controller in policy like portals, and armed by
the controller's `AuxManager`:

- **`aux_output`**: a relay (`relay_index`) driven by `cmd.output` on
  `acc.{location}.auxout.{code}.cmd.output`, with `on` / `off` (standing
  state) or `pulse` (seconds from the command, else the record's
  `pulse_seconds`, else 5 s).
- **`aux_input`**: an input (`input_index`, `contact`) whose edges arrive on
  the same input stream as DPS and REX. Its `point_type` decides what an edge
  means:
  - `monitor` (the default) is observe-only.
  - `intrusion` raises its area's `intrusion` alarm on an active edge while
    the area is armed.
  - `tamper_24h` raises it whatever the arm-state.
  - `fire` is the location's fire-alarm interface.

### The fire input

Fire is an aux input, not a driver. There is no fire-specific interface or
board line. Wire the fire panel's dry contact to any free input and create an
`aux_input` with `point_type: fire`.

The owning controller publishes `acc.{location}.evt.fire` on **both** edges,
and every controller at that location applies it. While it is asserted, door
and intrusion alarms are suppressed, but only if the location sets
`fai_suppress`. `held_clear` is never suppressed. Software never unlocks for
fire: the panel's relay drops maglock power directly.

::: note Aux inputs report edges only
Like DPS, a point is assumed inactive when armed. A contact that is already
asserted when the box boots (a fire panel already in alarm, an open zone) is
not reported until it clears and asserts again.
:::

---

## 6. Readers

`controller.reader` picks how credentials arrive, independent of the lock and
door driver (the strike and DPS/REX stay on GPIO/I2C either way). Each tap
event carries a `source` (`nats` / `osdp`), so a physical read can be told
apart from a NATS-published tap in the audit trail.

| Mode | Credentials come from |
| :--- | :--- |
| `nats` (default) | Simulated taps on NATS. No reader hardware. |
| `osdp` | A real OSDP reader on the model's RS485 bus. |
| `both` | NATS for every portal, plus OSDP for the portals with a physical reader. |

### `nats`

Simulated taps are published to `acc.{location}.{type}.{thing}.tap` (see
[Wire Protocol](protocol.md)). Drive it with `nats pub` for development and
integration.

### `osdp`

The controller is the ACU/CP and polls a real OSDP reader on the model's
RS485 bus at 9600 baud (`/dev/ttyAMA2` on the Pi5R8, `/dev/ttyAMA0` on the
Server-Mini).

- All readers on the bus share the one port. Each portal's reader sits at its
  `reader_address` (OSDP PD address `0`–`126`, default 0).
- Two portals claiming one address, or a portal with `reader_address: -1`,
  fail to arm under this mode, so that portal is not driven at all.
- A card from an address no portal claims is dropped.
- The engine is pure Go, no cgo (`internal/drivers/osdp`), and mirrors
  libosdp's CP design. A reader goes offline after 8 failed exchanges and is
  re-initialized 10 s later.

::: note v1 is clear-text
OSDP Secure Channel (SCBK/AES) is a planned fast-follow. See the
secure-channel bench item below.
:::

### `both`

NATS serves **every** portal, and OSDP serves the portals with a physical
reader. `reader_address >= 0` puts the portal's reader on the bus at that
address. `-1` makes the portal NATS-only, and it never touches the bus. Taps
from both readers feed one stream (`internal/controller/multireader.go`). Use
this when some of a box's portals have a physical reader and some do not.

### OSDP bench items

- **RS485 direction.** v1 assumes the board's auto-direction transceiver. If a
  board needs explicit DE/RE toggling, add the `TIOCSRS485` ioctl at port open
  (`internal/drivers/osdp/transport_linux.go`).
- **Credential format.** A card read maps to the lowercase hex of the raw card
  bytes. Decimal and Wiegand decoding depend on the reader's bit order, and
  are deferred until confirmed against a physical reader.
- **Secure channel.** Many readers ship secure-channel-required; v1 bring-up
  may need the reader in clear-text or install mode.

---

## 7. Adding a Board

The driver layer is data-first. A new board that uses an **existing
transport** is just a new `Profile`:

1. Add a `Profile` to `internal/drivers/hardware` (`profile.go`): the `relays`
   and `inputs` maps, each line a `LineSpec` (`gpioRelay`/`gpioInput` for
   native GPIO, `i2cLine` for an expander), plus `serial` (the RS485
   `SerialPort`) if the board can host an OSDP reader. Keep logical index
   *N* = OUT*N* / IN*N*.
2. Widen the `controllers.model` select with a new additive migration in
   `pbmigrations`, and add the model to
   [Configuration Reference](configuration.md).
3. Add it to the UI's model list: the `ControllerModel` union
   (`ui/src/types/pocketbase.ts`), `MODELS` in `ControllerFormView.vue`, and
   the transport label in `reports/WiringReport.vue`. Then rebuild the
   embedded UI. The I/O map and index pickers need nothing: they read
   `GET /api/models`, which is built from the compiled-in profiles.
4. Nothing else is needed for an existing transport. `Profile.Transport()`
   routes the new model to the matching backend.

A board on a **new transport or expander chip** also needs a backend that
implements `controller.PortalHardware` + `controller.AuxHardware` +
`drivers.DoorInput` + `Close()` (the GPIO and I2C packages are the two worked
examples). It also needs a `hardware.Backend` value and a case in the backend
selection in `cmd/access-controller/main.go`.

---

## 8. Bench Checklist

Before you trust a board in production, confirm on the bench:

- **Relay polarity.** Energizing a logical relay closes the strike circuit
  (both boards assume active-high). For a maglock portal
  (`lock_type: maglock`), confirm the idle state holds the door locked and a
  grant drops it.
- **Input polarity and contact sense.** With the default `dps_contact: nc`, a
  shut door reads "closed". A REX press reads active with `rex_contact: no`.
  If the site is wired the other way, set the field; do not rewire.
- **Fire input.** Asserting the panel contact publishes `evt.fire` for the
  location (and suppresses alarms if `fai_suppress` is set). Clearing it
  publishes the clear.
- **Pi5R8 only.** Whether the `0x22` second expander exists and carries any
  I/O, and whether the ~50 ms poll latency is acceptable for REX and forced
  detection.
- **OSDP.** The RS485 direction, credential format and secure-channel items in
  [§6](#osdp-bench-items).

The console's **Reports → Wiring / As-Built** sheet lists every portal and aux
point's binding, contact sense, and lock type, grouped by location. It is the
commissioning record to check the bench against.

---

## 9. Where to Go Next

- The config keys that select a driver, model and reader: [Configuration Reference](configuration.md)
- Tap, command and fire subjects and payloads: [Wire Protocol](protocol.md)
- Who may edit portals, controllers and aux points: [Operators & Authorization](operators.md)
- The system overview: [Access Control](../README.md)
