---
path: platform/first-device
nav_order: 54
---
# Connect Your First Device

This guide takes one device from nothing to a message on the bus that you can
see. The example is a temperature probe in a walk-in freezer. At the end, the
probe has an inventory record, a NATS identity, and permission to publish on
its own subjects and nowhere else.

You need an Organization with a running NATS server
([Getting Started §3](./getting-started.md#3-start-the-nats-server)) and an
**Owner or Admin** login in that Organization. The commands use `curl`, `jq`
and the [`nats` CLI](https://github.com/nats-io/natscli). `$TOKEN` is your auth
token and `$ORG_ID` is your active organization, as in
[Getting Started §2](./getting-started.md#checkpoint-a-working-inventory).

---

## 1. Create a Thing Type

The Thing Type gives every probe the same subject layout and code prefix.

```bash
TYPE_ID=$(curl -s -X POST http://localhost:8090/api/collections/thing_types/records \
  -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Temperature Probe","code":"temp-probe","prefix":"TP","organization":"'"$ORG_ID"'"}' \
  | jq -r .id)
```

With no `subject_prefix`, a probe's subjects start with
`temp-probe.<thing code>` ([Thing Types §3](./thing-types.md#default-prefix)).

---

## 2. Create a NATS role for the type

A NATS role is the permission set that goes into the device's signed
credential. An empty list grants nothing, so write the subjects.

```bash
ROLE_ID=$(curl -s -X POST http://localhost:8090/api/collections/nats_roles/records \
  -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"temp-probe","organization":"'"$ORG_ID"'",
       "publish_permissions":["temp-probe.*.>"],
       "subscribe_permissions":["_INBOX.>"]}' \
  | jq -r .id)
```

This role lets a probe publish on every probe's subjects. That is the simple
choice, and one role then serves the whole fleet. To limit each device to its
own subjects, leave the role's publish list empty and put
`temp-probe.<thing code>.>` in the publish permissions of that device's NATS
user. The platform combines the two lists
([Connectivity §1](./connectivity.md#core-pubsub-subject-namespacing)).

---

## 3. Create the Thing and its identity

One request creates the inventory record and mints its NATS identity.

```bash
THING=$(curl -s -X POST http://localhost:8090/api/org/things \
  -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Walk-in freezer probe","type":"'"$TYPE_ID"'",
       "nats":{"mode":"auto","role_id":"'"$ROLE_ID"'"},
       "nebula":{"mode":"none"}}')
CODE=$(echo "$THING" | jq -r .code)
THING_ID=$(echo "$THING" | jq -r .id)
echo "$CODE"
```

The request has no `code`, so the platform generates one under the type's
prefix, such as `TP-D8Y-AU9`. If the hardware already has a code on it, send
that code instead.

The response also has the Thing's login `email` and `password`. **The password
is shown only once.** Record it if the device will sign in to the platform, as
the [Agent](./agent.md) does.

---

## 4. Give the device its credential

Choose the way that fits the device:

| The device | How it gets its credential |
| :--- | :--- |
| Runs the [Agent](./agent.md) | The Agent signs in with the Thing's email and password and fetches the credential. It also keeps the credential current ([The Agent §2](./agent.md#2-provisioning-credential-lifecycle)). |
| Runs your own NATS client | Download the `.creds` file and install it on the device (below). |
| Speaks MQTT | Use a bearer-token identity ([Connectivity §1](./connectivity.md#mqtt-clients)). |

To download the file, read the Thing's NATS user as an Owner or Admin:

```bash
curl -s "http://localhost:8090/api/collections/things/records/$THING_ID?expand=nats_user" \
  -H "Authorization: $TOKEN" | jq -r .expand.nats_user.creds_file > probe.creds
chmod 600 probe.creds
```

The console has the same file under **NATS → Users**, with the **.creds**
button. The file holds the device's private key, so keep it like a password.

---

## 5. Publish a reading

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

The probe cannot subscribe to its own subject, so use your own identity. Your
NATS role needs `temp-probe.>` in its subscribe allow list.

- **In the console:** add a **Console** widget to a dashboard and set its
  subject to `temp-probe.>`
  ([Getting Started §5](./getting-started.md#5-the-hello-world-event)).
- **From a terminal:** subscribe first, then publish again from §5.

    ```bash
    nats --creds ./<your-nats-username>.creds sub "temp-probe.>"
    ```

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

When the probe is removed, clear **Active** on its Thing. This revokes its
credential. You can delete the Thing after that. The server refuses a delete
while the credential is still active
([Authorization §4.2](./authorization.md#42-taking-a-device-out-of-service)).

---

## 9. Where to Go Next

- More devices of the same kind: [Stone CLI](./stone-cli.md#provisioning-a-real-device)
- A device you manage remotely: [The Agent](./agent.md)
- A site that works when its link is down: [Leaf Nodes](./leaf-nodes.md)
- Declare what the probe publishes: [Thing Types](./thing-types.md)
- An alert when the freezer is too warm: [Automation](./automation.md)
- An alert when the probe goes quiet: the [Watchdog](./vendor/services/docs/watchdog.md)
- Long-term history: [Observability](./observability.md)
