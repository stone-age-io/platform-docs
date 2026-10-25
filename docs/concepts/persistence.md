---
path: concepts/persistence
nav_order: 30
---
# Persistence

Core NATS stores nothing ([Messaging §5](./messaging.md#5-what-core-nats-does-not-do)).
**JetStream** is the persistence layer inside the NATS server. It stores
messages in **streams**, reads them back through **consumers**, and keeps the
latest value for each key in **KV buckets**. This page explains the three, and
how they work across a leaf node. For the full detail, see
[JetStream](https://docs.nats.io/nats-concepts/jetstream) in the NATS
documentation.

---

## 1. Streams

A **stream** stores every message published to the subjects in its filter. The
publisher does not change. A device publishes to `temp_sensor.TP-4KD-7PX.reading`
as usual, and a stream with the filter `temp_sensor.>` stores the message.

Each stored message gets a **sequence number**, which increases by one for each
message in the stream. A consumer uses the sequence number to know where it is.

The main settings of a stream:

| Setting | What it controls | Values |
| :--- | :--- | :--- |
| **Subjects** | Which messages the stream stores | One or more subject patterns |
| **Storage** | Where it keeps the messages | `file` or `memory` |
| **Retention** | When a message can be removed | `limits`, `interest` or `workqueue` (below) |
| **Limits** | How much it keeps | Maximum messages, bytes and age |
| **Discard** | What happens at a limit | `old` removes the oldest message. `new` refuses the new one. |
| **Replicas** | How many servers keep a copy | 1, or 3 in a production cluster |
| **Duplicate window** | How long it remembers message IDs (below) | A duration |

**Retention** decides what removes a message:

| Retention | A message stays until | Use it for |
| :--- | :--- | :--- |
| `limits` | A limit (count, size or age) removes it | History, such as telemetry for dashboards |
| `interest` | Every consumer acknowledges it | Fan-out to a known set of readers |
| `workqueue` | One consumer acknowledges it | Jobs that one worker must do once |

### Publish acknowledgements

A client can publish through the JetStream API. Then the server answers when
the stream stores the message. A plain core NATS publish to the same subject is
also stored, but the publisher gets no confirmation.

To prevent duplicates, a publisher can set a `Nats-Msg-Id` header. The stream
stores a message ID only once inside its duplicate window. A publisher that
sends again after a timeout then cannot store the message twice.

::: warning Two streams in one account cannot store the same subject
JetStream refuses a stream whose subjects overlap the subjects of another
stream in the same account. Plan the subject filters before you create
streams. A [subject layout](./messaging.md#order-tokens-from-general-to-specific)
with the type first makes this easy: one stream for each kind of Thing.
:::

---

## 2. Consumers

A **consumer** reads a stream. It remembers which messages it delivered, and
which ones the client acknowledged. One stream can have many consumers, and
each one reads at its own speed.

| Property | What it means |
| :--- | :--- |
| **Durable** | The consumer has a name. It keeps its position when the client disconnects or restarts. |
| **Ephemeral** | The consumer has no name. The server removes it after the client stops using it. |
| **Pull** | The client asks for messages in batches. The NATS documentation recommends pull consumers for new code. |
| **Push** | The server sends messages to a subject as they arrive. |
| **Deliver policy** | Where it starts: all messages, the last message, only new messages, the last message on each subject, or a sequence number or time. |
| **Filter subject** | It reads only the stored messages on a narrower subject. |

### Acknowledgements and redelivery

With explicit acknowledgement, the client acknowledges each message after it
processes it. If no acknowledgement arrives before the **ack wait** ends, the
server delivers the message again. This gives **at-least-once** delivery.

At least once means "sometimes twice". A client that crashes after it
processes a message, but before it acknowledges it, receives the message again.
Write consumers so that a second copy of a message does no harm.

**In Stone-Age.io:**

- Dashboards read history from streams to fill a chart when you open it.
- Telegraf reads telemetry through a durable consumer. When the TSDB is down,
  the consumer keeps its position, and Telegraf continues from that position
  when it reconnects. See [Observability §3](../observability.md#3-data-flow-architecture).

---

## 3. KV buckets

A **KV bucket** is a stream that JetStream uses as a key-value store. It keeps
the latest value for each key.

- **The bucket is a stream.** A bucket named `twin` is the stream `KV_twin`.
- **A write is a publish.** A put of key `thing.S01.temp` publishes the value
  to `$KV.twin.thing.S01.temp`. A rule can write a key with a normal publish.
- **Keys look like subjects.** They use dot-separated tokens, and a watch can
  use wildcards.

| Operation | What it does |
| :--- | :--- |
| **Get** | Reads the latest value of a key. |
| **Put** | Writes a value. |
| **Create** | Writes a value only if the key does not exist. |
| **Update** | Writes a value only if the key is still at a given revision. Use it to prevent lost updates. |
| **Delete** | Marks the key as deleted. The history stays. |
| **Purge** | Removes the key and its history. |
| **Watch** | Receives each change to the keys that match a pattern, as it happens. |

Each write gets a **revision**, the stream sequence number of that write. A
bucket keeps a set number of values for each key, called its **history**. The
default is 1, and the maximum is 64. A bucket can also have a **TTL**, which
removes a value after a set age.

**In Stone-Age.io:**

- **The digital twin** uses two buckets: `twin` holds the state that devices
  report, and `twin_desired` holds the state that people want. Keys are
  `<kind>.<code>.<prop>`, such as `thing.S01.temp`. The console watches both
  buckets over its NATS WebSocket connection. See
  [Architecture §4](../architecture.md#4-the-digital-twin-concept-live-state).
- **Rules keep state** in KV, such as alarm status and presence keys. See
  [Automation §5](../automation.md#5-stateful-patterns-via-kv).

::: note KV holds live state, not records
A bucket can find keys only by key pattern. It cannot search on a value. Keep
records that you search or join, such as names, serial numbers and locations,
in the Control Plane database ([HTTP API](./http-api.md)). Keep values that
change often, such as a temperature or a switch position, in KV.
:::

---

## 4. Leaf nodes and domains

Each server that runs JetStream belongs to a **JetStream domain**. A leaf node
has its own domain. So a leaf and the hub can each have a bucket named `twin`,
and the two buckets are separate. A client chooses the domain when it uses the
JetStream API. In Stone-Age.io, a leaf's domain is the code of its Thing. See
[Leaf Nodes §3](../leaf-nodes.md#the-domain-is-the-code-computed-and-never-stored).

Stored data crosses between domains in two ways:

| Method | What it does |
| :--- | :--- |
| **Mirror** | A read-only copy of one stream. It follows the original. |
| **Source** | A stream that copies messages from one or more other streams, and can also store its own. |

After an outage, a mirror or a source continues from where it stopped. Core
NATS messages from the outage do not cross.

**In Stone-Age.io:** `twin_desired` is a mirror from the hub to each leaf. The
Agent relays `twin` from each leaf to the hub, because native sourcing cannot
combine many buckets with the same name. See
[Leaf Nodes §6](../leaf-nodes.md#6-offline-autonomy-and-kv-bucket-sync).

::: warning Give each bucket one writer
If the hub and a leaf both write one synced bucket, a conflict has no winner.
The two values swap across the link without end. Each synced bucket must have
one writer: the hub or the edge, never both. The Agent refuses to start if one
bucket syncs in both directions.
:::

---

## 5. Accounts and limits

Streams and buckets belong to an account, as subjects do. Another account
cannot read them unless an export and an import share them
([Messaging §6](./messaging.md#6-accounts-keep-tenants-apart)).

- **The account JWT sets the storage limits.** It sets the total disk and
  memory that the account's streams can use. Stone-Age.io sets these limits
  when it provisions the account.
- **NATS permissions control who can manage streams.** The JetStream API is a
  set of subjects under `$JS.API.>`. A user needs permission on those subjects
  to create, change or read streams and buckets.
- **There is no HTTP API for streams.** The console, the `stone` CLI and the
  `nats` CLI create streams and buckets over a NATS connection. See
  [Platform Entities §5](../platform-ui-entities.md#jetstream-streams-and-kv-buckets).

---

## 6. Where to Go Next

- How messages move before they are stored: [Messaging](./messaging.md)
- Consumers that are safe to run twice: [Message Design §6](./message-design.md#6-make-each-consumer-safe-to-run-twice)
- Who can manage streams and buckets: [NATS Security](./nats-security.md)
- The twin in detail: [Architecture §4](../architecture.md#4-the-digital-twin-concept-live-state)
- Buckets across a leaf link: [Leaf Nodes §6](../leaf-nodes.md#6-offline-autonomy-and-kv-bucket-sync)
- Telemetry into a TSDB: [Observability](../observability.md)
