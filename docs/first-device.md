---
path: platform/first-device
nav_order: 54
---
# Connect Your First Device

This guide takes one device from nothing to a message on the bus that you can
see. The example is a temperature probe in a walk-in freezer. At the end, the
probe has an inventory record, a NATS identity, and permission to publish on
its own subjects and nowhere else.

You need a running platform and a `stone` CLI that is signed in as an **Owner
or Admin** of the organization ([Getting Started §2](./getting-started.md#2-connect-the-stone-cli)).
The device side uses the [`nats` CLI](https://github.com/nats-io/natscli),
because it publishes with the probe's credential, not with yours. One step uses
`jq`.

---

## 1. Create a Thing Type

The Thing Type gives every probe the same subject layout and code prefix.

```bash
stone thing-type create --name "Temperature Probe" --code temp-probe --prefix TP
```

With no `subject_prefix`, a probe's subjects start with
`temp-probe.<thing code>` ([Thing Types §3](./thing-types.md#default-prefix)).

---

## 2. Create a NATS role for the type

A NATS role is the permission set that goes into the device's signed
credential. An empty list grants nothing, so write the subjects.

```bash
stone nats-role create --name temp-probe \
  --publish-permissions '["temp-probe.*.>"]' \
  --subscribe-permissions '["_INBOX.>"]'
```

This role lets a probe publish on every probe's subjects. That is the simple
choice, and one role then serves the whole fleet. To limit each device to its
own subjects, leave the role's publish list empty and put
`temp-probe.<thing code>.>` in the publish permissions of that device's NATS
user. The platform combines the two lists
([Connectivity §1](./connectivity.md#core-pubsub-subject-namespacing)).

---

## 3. Create the Thing and its identity

One command creates the inventory record and mints its NATS identity, in one
server-side transaction:

```bash
stone thing provision --name "Walk-in freezer probe" --type temp-probe \
  --nats-mode auto --nats-role temp-probe
```

The command has no `--code`, so the platform generates one under the type's
prefix, such as `TP-D8Y-AU9`. If the hardware already has a code on it, pass
that code with `--code`. Keep the code for the next steps:

```bash
CODE=TP-D8Y-AU9   # the code that provision printed
```

The command also prints the Thing's login email and password. **The password is
shown only once.** Record it if the device will sign in to the platform, as the
[Agent](./agent.md) does.

For a device that runs the Agent, you can add `--nats-device-key`. The device
then makes its own private key, the platform holds only the public half, and
there is no `.creds` file to download in §4. In the console this is the **Key
held by device** checkbox. See
[The Agent §2.3](./agent.md#23-device-held-keys).

---

## 4. Give the device its credential

Choose the way that fits the device:

| The device | How it gets its credential |
| :--- | :--- |
| Runs the [Agent](./agent.md) | The Agent signs in with the Thing's email and password and fetches the credential. It also keeps the credential current ([The Agent §2](./agent.md#2-provisioning-credential-lifecycle)). |
| Runs your own NATS client | Download the `.creds` file and install it on the device (below). |
| Speaks MQTT | Use a bearer-token identity ([Connectivity §1](./connectivity.md#mqtt-clients)). |

The Thing's NATS username is its code. To download the file, read that NATS
user as an Owner or Admin:

```bash
stone nats-user get "$CODE" --fields creds_file -o json | jq -r .creds_file > probe.creds
chmod 600 probe.creds
```

The console has the same file under **NATS → Users**, with the **.creds**
button. The file holds the device's private key, so keep it like a password.

---

## 5. Publish a reading

Publish as the probe, with its file:

```bash
nats --creds ./probe.creds pub "temp-probe.$CODE.temperature" \
  '{"celsius":-18.2,"ts":"2026-11-11T01:00:00Z"}'
```

The server accepts it. A publish outside the role fails, which shows that the
credential carries the permissions:

```bash
nats --creds ./probe.creds pub other.subject x
# nats: error: nats: permissions violation: Permissions Violation for Publish to "other.subject"
```

For the shape of the payload, see
[Message Design](./concepts/message-design.md).

---

## 6. See the reading

The probe cannot subscribe to its own subject, so use your own identity. Add
`temp-probe.>` to the subscribe allow list of your own NATS role, in the console
or with `stone`. `--subscribe-permissions` replaces the whole list, so give
every subject:

```bash
stone nats-role update <your-role> \
  --subscribe-permissions '["test.>", "temp-probe.>", "_INBOX.>"]'
```

A role change signs a new credential for each user with that role. Write
yours again, then subscribe, and publish again from §5:

```bash
stone nats sync-context
stone nats sub 'temp-probe.>'
```

In the console, add a **Console** widget with the subject `temp-probe.>`
([Getting Started §5](./getting-started.md#5-send-a-message)).

Core NATS stores nothing. A subscriber sees only the readings published while
it is connected.

---

## 7. Keep the readings

To read history, put a JetStream stream over the subjects. In the console, an
Owner or Admin creates one under **NATS → Streams** with the subject
`temp-probe.>`. From a terminal:

```bash
stone js stream create TEMP_PROBE --subject 'temp-probe.>' --max-age 720h --storage file
```

A **Chart** widget with **Use JetStream (History)** then shows the stored
readings when you open the dashboard ([Dashboards §3](./dashboards.md#3-data-sources)).

---

## 8. Take the device out of service

When the probe is removed, deactivate its Thing. This revokes its credential.
You can delete the Thing after that:

```bash
stone thing update "$CODE" --active=false
stone thing delete "$CODE"
```

The server refuses a delete while the credential is still active
([Authorization §4.2](./authorization.md#42-taking-a-device-out-of-service)).
In the console, clear **Active** on the Thing.

---

## 9. Where to Go Next

- More devices of the same kind: [Stone CLI](./stone-cli.md#provisioning-a-real-device)
- A device you manage remotely: [The Agent](./agent.md)
- A site that works when its link is down: [Leaf Nodes](./leaf-nodes.md)
- Declare what the probe publishes: [Thing Types](./thing-types.md)
- An alert when the freezer is too warm: [Automation](./automation.md)
- An alert when the probe goes quiet: the [Watchdog](./vendor/services/docs/watchdog.md)
- Long-term history: [Observability](./observability.md)
