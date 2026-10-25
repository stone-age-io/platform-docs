---
path: concepts/message-design
nav_order: 35
---
# Message Design

NATS carries bytes and never reads them. A
[Thing Type](../thing-types.md) describes subjects, not payloads, and nothing in
the platform checks a payload. So the shape of a message is a choice that each
publisher makes.

This page gives the conventions that the Stone-Age.io components follow. Use
them, and a new device or application fits with the Agent, the rule engine,
the helpdesk and access control. Each rule names the component that does it,
so you can see a working example.

---

## 1. Choose the kind of message first

Each message says one of six things. The kind decides the transport.

| Kind | What it says | Transport | Example |
| :--- | :--- | :--- | :--- |
| **Event** | Something happened. | Publish, stored in a stream | An access decision at a door: `acc.hq.door.lobby-main.evt.tap` |
| **Command** | Do this now. | Core NATS publish | A strike pulse: `acc.hq.door.lobby-main.cmd.grant` |
| **Request** | Answer me. | Request and reply | The Agent's health: `agents.gw-99.cmd.health` |
| **State** | This is true now. | A KV key, latest value wins | A reported temperature: key `thing.S01.temp` in `twin` |
| **Liveness** | I am alive. | Core NATS publish, not stored | The Agent's heartbeat: `agents.gw-99.heartbeat` |
| **Intent** | This must be true, also after a restart. | A record write, or a key in `twin_desired` | A setpoint, or an alarm area's arm state |

Three rules follow from the table:

- **A command does not go in KV.** A "reboot now" that stays in a bucket runs
  again at the next start. Send it as a message. See
  [Architecture §4.2](../architecture.md#42-what-belongs-in-twin_desired-and-what-does-not).
- **Intent that must survive a restart is not a command.** Access control sends
  a door's posture override as a command, and a reboot clears it. It writes an
  area's arm state to a record instead, because a reboot must not disarm a
  building. Its protocol says so: there is no `cmd.arm` subject.
- **Keep liveness out of streams.** A stored heartbeat is noise, and an old
  heartbeat replayed after an outage is wrong. Store only the change from
  online to offline. Access control publishes one `evt.state` event for each
  change. The Agent's stream stores `agents.*.telemetry.>`, not `agents.>`, so
  its heartbeats stay out.

---

## 2. Identity in the subject, facts in the payload

The subject says **who** and **what kind**. The payload holds the facts.

- **The server checks subjects, never payloads.** NATS permissions are subject
  patterns ([NATS Security §5](./nats-security.md#5-permissions)). So the
  subject is the only part of a message that the server controls.
- **Read identity from the subject when it matters.** The helpdesk reads the
  tenant from the subject only, and it ignores an organization id in the
  payload. The import that delivers the message writes the organization code
  into the subject, so a customer cannot claim another customer's code.
- **A payload can repeat identity for convenience.** Each Agent payload carries
  `code`, `location` and `ts`, so a stored message makes sense alone. A
  consumer that makes a security decision still reads the subject.
- **Put the verb or kind last.** Access control ends each subject with `.tap`,
  `.cmd.grant` or `.evt.alarm`. The platform's default subject ends with the
  operation suffix. A wildcard on the last token then selects a kind of
  message.
- **Give an application its own tree.** Access control owns `acc.>` and the
  helpdesk owns `helpdesk.>`. A literal first token keeps their streams from
  overlapping other streams in the same account
  ([Persistence §1](./persistence.md#1-streams)).

---

## 3. Refer to things by code

**Ids for storage. Codes for addressing.** This is the rule of
[ADR 0002](../decisions/0002-organization-code-namespace.md).

A PocketBase id belongs to one database. Another application, a restored
backup or a printed label cannot use it. A **code**, such as `TP-4KD-7PX` or
`BLDG-C`, is the same in every system.

- **Use codes in subjects, payloads and KV keys.** The helpdesk takes
  `thing_code` and `location_code` in a ticket event. Access control stores
  codes, not PocketBase ids, in every policy key and value.
- **Codes do not change.** The platform refuses an edit to `things.code` or
  `locations.code`, so a stored code stays correct.
- **A code is one subject token.** It cannot contain `.`, `*`, `>` or a space.
- **Do not put a location in the subject of a thing that moves.** A device that
  knows its position reports it in the payload. Long-term storage adds the
  location from inventory when you query
  ([ADR 0004](../decisions/0004-long-term-data-and-location-path.md)).

---

## 4. Payload format

Use a **JSON object** at the root. The rule engine reads fields by name, such
as `{temp}` or `{device.zone}`, so an object is the easiest shape for every
consumer.

This is an Agent telemetry message, shortened:

```json
{
  "code": "gw-99",
  "location": "hq",
  "cpu_usage_percent": 15.2,
  "memory_free_gb": 8.5,
  "ts": "2026-10-24T14:02:11Z"
}
```

| Convention | Example | Who does it |
| :--- | :--- | :--- |
| **Time as an RFC 3339 string in UTC** | `"ts": "2026-10-24T14:02:11Z"` | The Agent and access control (`ts`), the helpdesk (`occurred_at`) |
| **The unit in the field name** | `cpu_usage_percent`, `memory_free_gb` | The Agent |
| **Numbers as JSON numbers** | `"temp": 21.5`, not `"21.5"` | The Agent |
| **Fixed strings for states and reasons** | `"reason": "deny_schedule_closed"` | Access control |
| **No `null`.** Leave out an empty optional field. | No `assignee` key when nobody is assigned | The helpdesk |
| **Ignore fields that you do not know** | A consumer skips an unknown key | The helpdesk |

- **`ts` is when the thing happened,** as the producer saw it. A device clock
  can be wrong. JetStream also records when it stored each message.
- **A fixed string is a public contract.** Access control's reason codes flow
  into events, dashboards and reports. A renamed value breaks each consumer
  that matches on it.
- **Choose one case style for field names,** and keep it in a family of
  messages. The Agent and the helpdesk use `snake_case`.
- **A rule that writes JSON must quote optional fields.** A missing field
  becomes an empty string, so `"card": {card}` gives invalid JSON. Write
  `"card": "{card}"`.

### Leave out what readers must not see

Each user with subscribe permission on a subject reads every message on it.
Access control's health reply leaves out recent door decisions for this
reason: each decision holds the raw credential value. Do not put a secret, a
credential or personal data in a payload unless every reader may see it.

---

## 5. Version the contract

The helpdesk puts the name and version of its contract in each event:

```json
{
  "schema": "helpdesk.event",
  "version": 1,
  "event_type": "ticket.status_changed",
  "occurred_at": "2026-07-15T14:02:11Z",
  "change": { "field": "status", "from": "open", "to": "in_progress" }
}
```

- **Add a field at any time.** Consumers ignore fields that they do not know
  (§4).
- **Change the version to rename or remove a field, or to change its
  meaning.** Old consumers then know that they cannot read the message.
- **Leave room in the subject.** The helpdesk's intake subject ends in a verb,
  `tickets.create`. The `comment` and `resolve` verbs can come later with no
  change to existing subjects.

---

## 6. Make each consumer safe to run twice

JetStream delivers **at least once** ([Persistence §2](./persistence.md#acknowledgements-and-redelivery)).
Each consumer must handle a second copy of a message. The components use four
methods:

| Method | How it works | Who does it |
| :--- | :--- | :--- |
| **A key from the producer** | The producer sets a stable `dedupe_key`. While a ticket with that key is open, a repeat adds to a count and opens no new ticket. | The helpdesk |
| **A `Nats-Msg-Id` header** | The stream stores each message ID once in its duplicate window. | The helpdesk's outbound events |
| **The stream sequence** | The consumer stores the message's sequence number with the result, under a unique index. It skips a sequence that it already stored. | Access control's audit consumer |
| **A write of the end state** | The consumer writes "disarmed", not "change the arm state". A second write changes nothing. | Access control's disarm consumer |

Prefer messages that state a value ("set to 21") over messages that state a
change ("add 1" or "toggle"). A repeated value is harmless. A repeated change
is a bug.

---

## 7. Handle bad messages

| Problem | What to do | Who does it |
| :--- | :--- | :--- |
| The message is malformed, such as invalid JSON or a missing required field | Log it and acknowledge it. Redelivery cannot repair it. | The helpdesk |
| A dependency failed for a short time, such as the database | Do not acknowledge it, so the server delivers it again. | The helpdesk |
| The message fails each time | Wait longer before each retry, then stop. Access control stops after nine deliveries. The message stays in the stream. | Access control |
| The body is not JSON | Keep the raw text, such as `{"raw": "<body>"}`, so nothing is lost. | Access control |
| Data is missing, such as an unknown credential | Fail safe. Access control denies. | Access control |

::: warning A message that fails each time can block a consumer
If a consumer never acknowledges a bad message and never stops the retries, it
delivers that message again and again. It fills the log and can delay the
messages behind it. Set a maximum number of deliveries on the consumer.
:::

---

## 8. Write the contract down

The platform stores subjects in a Thing Type, but it stores no payload shape.
So write the payload contract in a document, next to the code that publishes
it. The [helpdesk protocol](../vendor/helpdesk/docs/protocol.md) and the
[access control protocol](../vendor/access-control/docs/protocol.md) are
examples. Each one has a table of subject, direction, transport and body.

Before you publish a new kind of message, check these:

- [ ] I chose the kind: event, command, request, state, liveness or intent (§1).
- [ ] The subject holds the identity and ends with the kind or verb (§2).
- [ ] The subject and payload use codes, not database ids (§3).
- [ ] The payload is a JSON object with an RFC 3339 UTC `ts` (§4).
- [ ] The payload holds nothing that a subscriber must not see (§4).
- [ ] The contract has a name and a version, or a plan for one (§5).
- [ ] A second copy of the message does no harm (§6).
- [ ] A malformed message is acknowledged and logged, not retried forever (§7).
- [ ] The contract is written down (§8).

---

## 9. Where to Go Next

- Subjects, wildcards and request and reply: [Messaging](./messaging.md)
- Streams, consumers and KV: [Persistence](./persistence.md)
- The subjects a Thing Type declares: [Thing Types](../thing-types.md)
- Rules that read and write payloads: [Automation](../automation.md)
- Two full contracts: [Helpdesk protocol](../vendor/helpdesk/docs/protocol.md),
  [Access control protocol](../vendor/access-control/docs/protocol.md)
