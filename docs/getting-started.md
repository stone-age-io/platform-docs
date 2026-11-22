---
path: platform/getting-started
nav_order: 50
---
# Getting Started

This guide starts the platform, adds a Location and a Thing with the
[`stone` CLI](./stone-cli.md), and sends a first message on the bus.

New to the names? The [Glossary](./glossary.md) defines Thing, Account,
subject, JetStream, KV, leaf and the other terms. New to NATS?
[Concepts](./concepts/index.md) explains subjects, request and reply, and
credentials.

---

## 1. Start the platform

Run one container. It seeds itself on first boot and runs the NATS server in
the same process:

```bash
docker run -d --name stone-age \
  -p 8090:8090 -p 4222:4222 -p 9222:9222 \
  -v stone-age-data:/data \
  -e STONE_AGE_BOOTSTRAP_PASSWORD='change-me-8-chars-min' \
  -e STONE_AGE_NATS_WEBSOCKET_URLS='ws://localhost:9222' \
  ghcr.io/stone-age-io/platform:latest
```

Open the console at `http://localhost:8090`. Sign in as `admin@example.com`
with that password. This user is the **Platform Operator**, and its active
organization is your own organization, `Operator`.

- `STONE_AGE_NATS_WEBSOCKET_URLS` is the address that a **browser** uses to
  reach NATS. If other people will use the console, give the host's real name,
  not `localhost`.
- All data is on the `/data` volume: the database, the NATS config, the account
  JWTs and the JetStream store. Back up the whole volume
  ([Operations §3.5](./operations.md#35-the-container)).
- The same email and password also sign in to the admin UI at `/_/` as the
  **SuperUser**. Use it only for infrastructure work.
- [Configuration §3.1](./configuration.md#31-container-variables) lists the
  other container variables, such as the email and the organization names.

For [gateways](./leaf-nodes.md), also publish the leaf node port with
`-p 7422:7422`. Set `STONE_AGE_NATS_LEAF_URL` to the address that edge boxes
dial, such as `nats-leaf://hub.example.com:7422`.

### Without a container

Download `stone-age` for your architecture from the
[Releases page](https://github.com/stone-age-io/platform/releases), and run the
same two commands that the container runs:

```bash
./stone-age init --email admin@example.com --operator-org "Acme MSP"
./stone-age serve --nats
```

`init` asks for a password, or reads `STONE_AGE_BOOTSTRAP_PASSWORD`. It creates
the database, the Platform Operator, your organization, and the NATS server
config in `./nats-config/`. `serve --nats` starts the platform and a NATS server
in one process. [Configuration §4.1](./configuration.md#41-what-init-runs)
gives each step of `init`.

To run the NATS server as a separate process, start
`nats-server -c ./nats-config/nats.conf` and run `serve` without `--nats`.
[Operations §2.1](./operations.md#21-where-the-nats-server-runs) compares the
options.

To build from source, you need Go 1.27.4+ and Node.js 20.19+ or 22.12+:

```bash
git clone https://github.com/stone-age-io/platform.git && cd platform
cd ui && npm install && npm run build && cd ..   # the console, embedded in the binary
go build -o stone-age .                          # build the package, not main.go
```

---

## 2. Connect the `stone` CLI

`stone` is the command-line client. Download it for your platform from its
[Releases page](https://github.com/stone-age-io/stone-cli/releases)
([Stone CLI §2](./stone-cli.md#2-install--build)). Then point it at the
platform and sign in:

```bash
stone context create local --url http://localhost:8090 --nats-url nats://localhost:4222
stone auth login
```

`auth login` asks for your email and password. It prints your active
organization. `--nats-url` lets `stone` use your NATS credential in §5.

---

## 3. Add a Location and a Thing

```bash
stone location create --name HQ --code hq
stone thing provision --name "Lobby Camera" --code cam-lobby --location hq
stone thing ls
```

`thing provision` creates the Thing in your active organization. By default it
gives the Thing no NATS identity and no Nebula certificate, so the Thing is an
inventory record only. It prints a password, which a device needs only if it
signs in as this Thing. You can add identities to the same record later. See
[Inventory-as-Identity](./architecture.md#31-inventory-as-identity).

The console shows the same records. To use the REST API instead, see
[HTTP API](./concepts/http-api.md) and [API Reference](./api-reference.md).

**If you need only an inventory, you can stop here.** You can create
organizations, invite users, build a location tree and place Things on floor
plans and maps. See [Platform Entities](./platform-ui-entities.md).

::: note A demo estate in one command
With the container from §1, run it inside the container. `--dir` names the
database the container serves:

```bash
docker exec stone-age stone-age demo-seed --confirm --dir /data/pb_data
```

From source, it is `./stone-age demo-seed --confirm`.

It fills the database with three tenants, a type
taxonomy, locations on a map, Things, NATS roles and identities, a Nebula
network and edge gateways. It uses the same provisioning hooks as the console,
and you can run it again safely. It writes real signed credentials, so use a
database that you can discard. `--things` makes the fleet larger. It seeds the
same three sites, with the same codes, as the
[access-control](./vendor/access-control/README.md) app
([ADR 0002](./decisions/0002-organization-code-namespace.md)).
:::

---

## 4. Give yourself a NATS identity

To send messages, your membership in the organization needs a NATS identity. In
the console:

1. Under **NATS → Roles**, create a **Role**. Fill in its permissions, because
   [an empty allow list grants nothing](./connectivity.md#core-pubsub--subject-namespacing):
   - **Publishing → Allow Subjects:** `test.>`
   - **Subscribing → Allow Subjects:** `test.>` and `_INBOX.>`. Replies to
     requests arrive on `_INBOX` subjects.
2. Under **NATS → Users**, create a **User** with that role.
3. In **Settings**, choose that user as the **Operational Identity**. This links
   it to your membership.
4. Click **Connect**. The status dot turns green and reads **CONNECTED**. From
   now on the console connects when you sign in.

The console uses the **Server URLs** under **Settings → NATS Connection**. For
a local install, add nothing. A URL that you add replaces the list on this
browser only
([Configuration §2.1](./configuration.md#21-server_url-and-websocket_urls-are-different-addresses)).

::: note Use your own organization for real work
`init` also links the NATS **System User** to the `System` organization. The
System Account is for NATS cluster management and has no JetStream. Give each
tenant its own organization ([Onboard a Tenant](./onboard-a-tenant.md)). Only
an owner or admin can choose which identity a membership uses
([Authorization](./authorization.md)).
:::

---

## 5. Send a message

Write your NATS credential to a local context, then subscribe:

```bash
stone nats sync-context
stone nats sub 'test.>'
```

In a second terminal, publish:

```bash
stone nats pub test.hello '{"msg": "Hello Stone Age", "val": 42}'
```

The message appears in the first terminal. `sync-context` writes the credential
of the identity that you linked in §4. The [`nats` CLI](https://github.com/nats-io/natscli)
can use the same context ([Stone CLI §7](./stone-cli.md#7-per-organization-nats-credentials)).

To see messages in the console, unlock the dashboard and add a **Console**
widget. Set its **NATS Subjects** to `test.>`, because the server refuses a
subscription that is wider than your role. Publish again. A **Publisher**
widget can also send messages from the dashboard ([Dashboards](./dashboards.md)).

---

## 6. Next steps

- Read [Authorization & Roles](./authorization.md) before you invite your team.
  `admin` has full tenant authority, the same as `owner`.
- Follow [Connect Your First Device](./first-device.md) to put one device on
  the bus, and [Onboard a Tenant](./onboard-a-tenant.md) to add a customer.
- Define [Thing Types](./thing-types.md) to declare the subjects of each device.
- Put your config in git. `stone pull` writes every tenant record to YAML that
  you can diff and review ([Stone CLI §5](./stone-cli.md#5-declarative-workspaces-pull--apply)).
- Install the [Agent](./agent.md) on a Linux or Windows machine to collect
  telemetry.
- Add rules, webhooks and scheduled publishes with the rule engine
  ([Automation](./automation.md)). For windowed aggregations, see
  [Stream Processing](./stream-processing.md). For long-term storage, see
  [Observability](./observability.md).
- Read [Platform Layers](./platform-layers.md) for the full model.
