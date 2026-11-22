---
path: platform/building-an-app
nav_order: 165
---
# Building an Application on the Platform

An **application** here is a program that does its work on a tenant's NATS
bus: the [helpdesk](./vendor/helpdesk/README.md),
[access control](./vendor/access-control/README.md), the kiosk, the
[services](./vendor/services/README.md). It usually has a PocketBase of its own
for its records and a console of its own for its staff. It never reads the
platform's database, and the platform never calls it.

This page lists what such an application does so that it fits the platform and
the other applications. Each section is short and links to the page that owns
the topic. The decisions behind it are
[ADR 0002](./decisions/0002-organization-code-namespace.md),
[ADR 0003](./decisions/0003-human-friendly-codes-and-default-subject.md),
[ADR 0007](./vendor/services/docs/decisions/0007-creds-keeper.md) and
[ADR 0008](./decisions/0008-application-namespace.md).

::: note Not every application follows this page yet
ADR 0008 is accepted, and the applications are being brought in line with it.
Where one still differs, ADR 0008 lists the change.
:::

---

## 1. Each process is a Thing

Every running process of the application (each instance, each edge box) has a
**Thing** of its own in the organization it serves, with a Thing Type that
names the program.

1. **Create the Thing Type, the NATS role and the Thing**, as for any device:
   [Your First Device §1 to §3](./first-device.md#1-create-a-thing-type). The
   role grants the subjects the program uses, and nothing else. The Thing Type
   and the role come from the application's contract folder (§9); only the
   Thing is made by hand.
2. **Run creds-keeper beside the process.** It signs in as the Thing and keeps
   the creds file current, so Regenerate, Revoke and deactivation in the
   console reach the process
   ([creds-keeper](./vendor/services/docs/creds-keeper.md)). The application
   doesn't contain a platform client: [ADR 0007](./vendor/services/docs/decisions/0007-creds-keeper.md)
   explains why.
3. **Connect so that a new file is picked up.** In nats.go that means
   `UserCredentials(path)`, `MaxReconnects(-1)` and `IgnoreAuthErrorAbort()`.
   Without the last one, the client stops trying after two refused connects,
   and a Revoke followed by a fresh file leaves it disconnected.

A creds file copied by hand is fine for development.

---

## 2. Address by code

**Ids for storage. Codes for addressing.** A PocketBase id belongs to one
database. A code is the same in the platform, in every application and on a
printed label.

- **Codes go in subjects, payloads and KV keys.** Relations inside your own
  database stay PocketBase ids.
- **A person's lookup ignores case. A machine's doesn't.** A scanner or a
  search box matches `door-1` to `DOOR-1` and then uses the stored spelling.
  Subjects and permissions use the stored spelling exactly
  ([ADR 0003 rule 3](./decisions/0003-human-friendly-codes-and-default-subject.md#3-codes-keep-their-case-uniqueness-and-human-lookups-ignore-it)).
- **A QR payload is the bare code**, with no host and no organization
  ([Platform Entities §5](./platform-ui-entities.md#5-codes-and-qr-labels)).
- **At the hub, read the organization from the subject**, never from the
  payload. The managed-org import writes it there, and a tenant can't forge it
  ([ADR 0002](./decisions/0002-organization-code-namespace.md)).

---

## 3. Name subjects with one grammar

```
{app}.{scope}.{channel}.{rest}
```

- **`{app}`** is your application's literal token. It keeps your streams apart
  from every other stream in the account.
- **`{scope}`** is a fixed number of code tokens, the same for every subject
  your application uses. Usually it is the instance's Thing code. Access
  control uses the location code, because a door controller's
  permissions are scoped to a site.
- **`{channel}`** is `evt`, `cmd`, `heartbeat` or `telemetry`
  ([Message Design §2](./concepts/message-design.md#2-identity-in-the-subject-facts-in-the-payload)).
- **`{rest}`** is yours, and ends with the verb.

A stream then captures one channel in one filter, such as `kiosk.*.evt.>`, and
two of your streams can't overlap. Write the scope length and every subject in
your protocol document ([Message Design §8](./concepts/message-design.md#8-write-the-contract-down)).

If the operator runs your application for many organizations, the managed-org
import delivers `{app}.{scope}…` from each customer account as
`{app}.{org}.{scope}…` in the hub account.

---

## 4. Register a NATS micro service

Each process registers a [micro service](./concepts/messaging.md#4-request-and-reply), so
`nats micro ls` finds it and `$SRV.PING`, `$SRV.INFO` and `$SRV.STATS` answer.
Put the process's **Thing code in the service metadata as `code`**. That is
the key the console uses to show a running service on its Thing.

---

## 5. Choose a stream, a bucket or neither

| You have | Use | Rule |
|---|---|---|
| Something that happened | A stream, on the `evt` channel | Set `Nats-Msg-Id` on every publish ([Message Design §6](./concepts/message-design.md#6-make-each-consumer-safe-to-run-twice)) |
| Something true now | A KV key, latest value wins | One writer per key ([Persistence §3](./concepts/persistence.md#3-kv-buckets)) |
| Do this now, or answer me | Core NATS on `cmd`, request and reply when you need an answer | Never in KV, never in a stream |
| I am alive | Core NATS on `heartbeat` | Never stored. Store only the change from online to offline, as an event. |

Every payload is a JSON object with an RFC 3339 UTC `ts`
([Message Design §4](./concepts/message-design.md#4-payload-format)).

---

## 6. Join inventory by code

The platform owns Things and Locations. If your application needs them, keep a
copy loaded by an operator's **export then seed**, and join it to the platform
by `(organization, code)`
([ADR 0008 rule 5](./decisions/0008-application-namespace.md#5-inventory-is-joined-by-code)).

- **Keep the platform's shape** for the fields you copy, so the seed is a
  one-to-one map. The helpdesk's `things`, `locations` and type collections
  are the example.
- **Put your own fields in your own collections**, joined by code: a portal's
  schedule, a kiosk's catalog.
- **A row with no code is legal.** It is something the platform doesn't know
  about, such as gear an operator services that was never onboarded. It just
  can't be joined.

There is no live sync. The platform publishes nothing on a tenant's bus
([Architecture §2](./architecture.md#2-component-topology)).

---

## 7. Build read models from streams

A **read model** is a table your application builds from events. Kiosk's
controller builds a fleet ledger from every kiosk's transactions. Access
control's [accessd](./vendor/access-control/docs/accessd.md) builds its audit
log from controller events.

- **Use a durable consumer**, so a restart continues where it stopped.
- **Make the write idempotent.** Upsert on a key the producer set (kiosk uses
  `source_line_id`) or store the stream sequence under a unique index (access
  control). A second delivery then changes nothing.
- **Acknowledge after the write**, not before.
- **Set a maximum number of deliveries**, so one bad message can't block the
  rest ([Message Design §7](./concepts/message-design.md#7-handle-bad-messages)).

The opposite direction works too. Access control mirrors its policy records
into a KV bucket, one key per record, and its edge controllers watch the bucket
into memory. That is how an edge box keeps working while it is offline.

---

## 8. Serve the process contract

Every process serves the same two endpoints as the Control Plane:

- **`GET /api/ready`**: a JSON report of named checks, each `ok`, `warn`,
  `fail` or `skipped`, with `503` only when a check failed. Every non-`ok`
  result says how to fix it.
- **`GET /metrics`**: Prometheus metrics, optionally behind a token sent as
  Basic or Bearer.

The format is the one in [Health & Metrics §2](./health-metrics.md#2-get-apiready).
A check must be answerable by the process that runs it.

---

## 9. Ship a contract folder

Everything an organization needs on the platform to run the application goes
in a `contract/` folder in its repository: the Thing Types, their operations,
and a NATS role per kind of process. It is a `stone` template, so onboarding
an organization is one command, run as an owner or admin of it:

```bash
stone org switch acme
stone apply --template contract/
```

Running it again moves an organization to a newer contract and leaves
anything that matches alone. It never deletes.
[stone CLI §5](./stone-cli.md#templates-one-folder-for-many-organizations)
has the file format.

- **One role per kind of process**, granting what that process uses: an edge
  controller reads the policy bucket and does not write it. A role is shared by
  every Thing of its kind, so a subject uses `*` where the location or the
  Thing would go.
- **A Thing Type with no operations is fine** for a central process whose
  subjects all belong to other Thing Types. The role says what it may do.
- **Keep the folder next to the code that defines the subjects**, and change
  both in one commit.

The four applications each have one: access control, kiosk, helpdesk and
services (watchdog).

---

## 10. Where to Go Next

- Subjects, payloads, duplicates and bad messages: [Message Design](./concepts/message-design.md)
- The decisions this page follows: [ADR 0008](./decisions/0008-application-namespace.md)
- A device from start to finish: [Your First Device](./first-device.md)
- Two complete contracts: [Helpdesk protocol](./vendor/helpdesk/docs/protocol.md),
  [Access control protocol](./vendor/access-control/docs/protocol.md)
