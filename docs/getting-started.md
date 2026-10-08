---
path: platform/getting-started
nav_order: 50
---
# Getting Started

## The short version

Run one container. It seeds itself on first boot and runs the message bus in
the same process:

```bash
docker run -d --name stone-age \
  -p 8090:8090 -p 4222:4222 -p 9222:9222 \
  -v stone-age-data:/data \
  -e STONE_AGE_BOOTSTRAP_PASSWORD='change-me-8-chars-min' \
  -e STONE_AGE_NATS_WEBSOCKET_URLS='ws://localhost:9222' \
  ghcr.io/stone-age-io/platform:latest
```

Open the console at `http://localhost:8090` and sign in as `admin@example.com`
with that password. The admin panel is at `/_/`.

From a binary, run the same five commands the container runs:

```bash
./stone-age superuser upsert admin@example.com 'change-me-8-chars-min'
./stone-age migrate up
./stone-age bootstrap --email admin@example.com --org "System" --operator-org "Acme MSP"
./stone-age nats export --output ./nats-config/
./stone-age serve --nats
```

**Run them in this order.** `bootstrap` writes fields that `migrate up`
creates, and `nats export` needs the data that `bootstrap` seeds. §2 explains
each command.

---

## What this guide covers

| Sections | What you get |
| :--- | :--- |
| **§1 to §2** | **[Depth 1](./index.md#start-where-you-need-to)**: a multi-tenant inventory of Things and Locations, over the REST API, with the console |
| **§3 to §5** | **Depth 2**: the messaging fabric where those records get their identities |

The Control Plane database must be seeded before it can generate the NATS
server config, so §2 comes before §3. You can use §2 on its own, and it ends
with a checkpoint.

You can stop after §2 if you only need a permissioned record of what you own
and where it is. A normal deployment still runs a NATS server, separately or
with `serve --nats`. It simply has nothing on it yet.

---

## 1. Installation

### Container

```bash
docker run -d --name stone-age \
  -p 8090:8090 -p 4222:4222 -p 9222:9222 \
  -v stone-age-data:/data \
  -e STONE_AGE_BOOTSTRAP_PASSWORD='change-me-8-chars-min' \
  -e STONE_AGE_NATS_WEBSOCKET_URLS='ws://localhost:9222' \
  ghcr.io/stone-age-io/platform:latest
```

On first boot, the entrypoint runs the §2 commands and then `serve --nats`, so
this one command covers §1 to §4. All data is on the `/data` volume: the
database, the NATS config, the account JWTs and the JetStream store.

`STONE_AGE_NATS_WEBSOCKET_URLS` is the address a **browser** connects to. The
container cannot find it for itself. If other people will use the console,
give the host's real name, not `localhost`.

| Variable | Default | Purpose |
| :--- | :--- | :--- |
| `STONE_AGE_BOOTSTRAP_PASSWORD` | none (**required on first boot**) | Password for the SuperUser and the Platform Operator user. If it is missing, the container stops and says why. |
| `STONE_AGE_BOOTSTRAP_EMAIL` | `admin@example.com` | Email for both accounts. |
| `STONE_AGE_BOOTSTRAP_ORG` | `System` | Name of the `$SYS` organization. |
| `STONE_AGE_BOOTSTRAP_OPERATOR_ORG` | `Operator` | Name of your own organization. Its NATS account is the hub for shared services. |
| `STONE_AGE_DATA_DIR` | `/data` | Where the database and NATS config are inside the container. |
| `STONE_AGE_HTTP_PORT` | `8090` | The HTTP listen port. |

The container seeds only when `nats-config/nats.conf` is missing from the data
directory. A restart never seeds again, and your edits to `nats.conf` stay. All
other `STONE_AGE_*` settings from [Configuration](./configuration.md) also work.
The image has a Docker `HEALTHCHECK` on `GET /api/ready`
([Health & Metrics](./health-metrics.md)).

### Pre-compiled binary

Download `stone-age`, the Control Plane, for your architecture from the
[Releases page](https://github.com/stone-age-io/platform/releases). The
[Agent](./agent.md) for edge hardware has
[its own repository](https://github.com/stone-age-io/agent) and releases.

### From source

You need Go 1.26+ and Node.js 20.19+ or 22.12+ (Vite's minimum).

```bash
git clone https://github.com/stone-age-io/platform.git
cd platform

# The console. This writes into pb_public/, which the Go build embeds.
cd ui && npm install && npm run build && cd ..

# The binary. Build the package (`.`), not main.go alone, which would
# leave out bootstrap.go and fail to compile.
go build -o stone-age .
```

---

## 2. Initialize the Control Plane

The binary reads an optional `config.yaml` from the current directory, and
environment variables. By default it looks for NATS at `nats://localhost:4222`,
but nothing in this section needs NATS.

This step creates the database, seeds the NATS Operator, System Account and
System User, and creates your first administrator. It takes three commands, in
order. None of them needs the server to run. They open the database directly.

### Step 1: Create the SuperUser (and seed initial data)

```bash
./stone-age superuser upsert EMAIL PASS
```

This creates a **SuperUser**, a service account with full database access that
ignores API rules. The first run also seeds the NATS Operator, System Account
and System User, and starts audit logging.

### Step 2: Import the schema

```bash
./stone-age migrate up
```

This applies the embedded migrations, which import `schema.json`: the
collections and **the API rules that make up the platform's authorization**
([Authorization](./authorization.md)). Step 3 needs the fields this step
creates.

### Step 3: Bootstrap the first Organization and Platform Operator user

```bash
./stone-age bootstrap --email admin@example.com --org "System" --operator-org "Acme MSP"
```

`bootstrap` does four things:

1. Creates your first **Platform Operator** user (a user with
   `is_operator = true`).
2. Creates the `System` Organization. `--org` defaults to `System`.
3. Links the seeded NATS System Account, User and Role to it.
4. Creates the provider's own organization (`--operator-org`). Its NATS account
   is the hub for shared provider services.

If you omit `--email` or `--operator-org`, the command prompts. If you omit
`--password`, it reads `STONE_AGE_BOOTSTRAP_PASSWORD` and prompts only if that
is also unset. Do not use `--password`, because it goes into your shell history
and the process list.

`bootstrap` and the admin panel are the **only** ways to make a Platform
Operator. No API rule allows a write to `is_operator`, on create or update, so
no REST caller can grant it.

After `bootstrap`, the new user's active organization is the operator
organization. Do your daily work there. The System organization is for
cluster-level NATS operations.

From now on, administer the platform as the **Platform Operator** user. Keep the
SuperUser for infrastructure work: schema imports, NATS Operator key custody,
and troubleshooting in the admin UI at `/_/`.

> **Why the order matters.** `bootstrap` writes `is_operator`, `is_system_org` and `is_operator_org`. These fields exist only after Step 2. PocketBase silently drops writes to fields that do not exist, so `bootstrap` refuses to run before the migrations.

### Checkpoint: a working inventory

Start the server:

```bash
./stone-age serve
```

Sign in at `http://localhost:8090` as your Platform Operator user. NATS is not
running yet, and all of these work without it:

- Create Organizations and invite users into them with roles.
- Create Locations, Location Types and Thing Types.
- Create and edit Things from desktop or mobile.
- Place Things on a floor plan or a map.
- Do all of this over the REST API or the [`stone` CLI](./stone-cli.md).

Create a Location and a Thing over the API:

```bash
curl -s -X POST http://localhost:8090/api/collections/locations/records \
  -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"HQ","code":"hq","organization":"'"$ORG_ID"'"}'
```

```bash
curl -s -X POST http://localhost:8090/api/org/things \
  -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Lobby Camera","code":"cam-lobby","location":"'"$LOC_ID"'",
       "nats":{"mode":"none"},"nebula":{"mode":"none"}}'
```

With `"mode":"none"` on both identities, the Thing is an inventory record with
no messaging identity and no mesh certificate. The console's create form has
the same three choices (`auto`, `link`, `none`). You can attach identities later
to the same record. See [Inventory-as-Identity](./architecture.md#31-inventory-as-identity).

> **The NATS warning in the log is expected.**
>
> At startup the Control Plane cannot reach NATS. It logs *"Publisher will continue operating - connection will be established when NATS becomes available"* and enters **bootstrap mode**, with a retry timer and a durable work queue.
>
> The database must be seeded before `stone-age nats export` can create a server config, and NATS is not reachable before it runs. Until then, credential work goes into the `nats_publish_queue` collection. The queue drains on the first run that connects. This is how `bootstrap` can create Organizations before a server exists.
>
> Do not run like this for long. The queue grows, and the cluster's claims fall behind the database. Start NATS in §3.

### Or seed a demo estate in one command

To get a populated platform to look at, run:

```bash
./stone-age demo-seed --confirm
```

It creates three tenants, a type taxonomy, locations on a real map, things
(devices, gateways, applications and unattended screens), NATS roles and signed
identities, a Nebula network with a lighthouse, and edge sites.

It runs **in-process, through the same provisioning hooks** as the console and
the API, so the result is the same as records you create by hand. Creating an
organization mints its NATS account and Nebula CA. Creating an edge site mints
the leaf node's NATS user. It needs no running NATS server, because account
claims wait in `nats_publish_queue`.

You can run it again safely. It finds or creates every record by its
per-organization `code`, so it does not duplicate anything. `--things` raises
the fleet size on a later run.

`--confirm` is required and is the only safety check. The command is in the
production binary and writes real signed credentials. Use a throwaway database.

It seeds the same three sites, with the same codes, as the
[access-control](./vendor/access-control/README.md) app.
If you run both, a door in one and a Thing in the other are the same door. See
[ADR 0002](./decisions/0002-organization-code-namespace.md).

**If you only need an inventory, stop here** and go to [§6 Next Steps](#6-next-steps).

---

## 3. Start the NATS Server

This section starts depth 2. It gives your inventory records identities on the
bus, and it drains anything §2 queued.

Export the server config that matches the seeded NATS Operator and System
Account:

```bash
./stone-age nats export --output ./nats-config/
```

The directory holds the NATS Operator JWT, the operator config and a
`nats.conf`. Its paths are absolute, so it works from any directory. The JWT
and JetStream directories are created on first run.

Run a server with it in one of two ways. Both use the same config file.

### Option A: inside the Control Plane

```bash
./stone-age serve --nats
```

One process. The Control Plane starts a NATS server from
`./nats-config/nats.conf` (change it with `--nats-config`) and stops it on
shutdown. Restarting `stone-age` also restarts the bus. See
[Operations §2.1](./operations.md#21-where-the-nats-server-runs) for the
trade-offs.

If you use this option, skip the `serve` command in §4.

### Option B: as its own process

```bash
nats-server -c ./nats-config/nats.conf
```

The bus keeps running while the Control Plane restarts. `serve` without
`--nats` expects a server like this. You can also cluster the embedded server
with an external `nats-server` for planned upgrades. Full high availability
needs three or more external nodes. [Operations §2.1](./operations.md#21-where-the-nats-server-runs)
describes the three options and how to move between them.

For production topologies, leaf nodes, clustering and TLS, see the
[NATS documentation](https://docs.nats.io).

> **The browser needs WebSockets**, because it cannot use the NATS TCP protocol. The exported `nats.conf` enables a WebSocket listener on port `9222`. For TLS (`wss://`), edit the `websocket { ... }` block, or pass `--websocket-port` to the export.

---

## 4. Connect the Browser to NATS

If you used **Option A**, the platform is already running. If not, start it:

```bash
./stone-age serve
```

The console is at `http://localhost:8090` (sign in as the Platform Operator).
The admin UI is at `http://localhost:8090/_/` (sign in as the SuperUser).

The browser connects **as the NATS identity linked to your membership in the
active organization**. It needs an address and an identity.

1. **The address.** Go to **Settings**. Under **NATS Connection**, the
   **Server URLs** list shows the deployment's addresses: `nats.websocket_urls`
   if set, or the default `ws://localhost:9222`. For a local install, add
   nothing. A URL you add here **replaces** the list, on this browser only. Use
   it to point one device at a local leaf node
   ([Configuration §2.1](./configuration.md#21-server_url-and-websocket_urls-are-different-addresses)).
2. **The identity.** Your operator organization has a NATS account but no
   identity in it yet. Under **NATS**, create a **Role** (the permission
   template), then a **User** with that role. In **Settings**, choose that user
   as the **Operational Identity**.
3. Optionally, turn on **Auto-connect on login**. Click **Connect**.

The status shows a green **Status: Connected**.

> **Use your own organization for real work, not the System account.** `bootstrap` links the NATS **System User** to the System organization. You can use it to test the connection, but the System Account is for NATS cluster management and has no JetStream. Give each new tenant its own organization. Only a Platform Operator can create an Organization ([Authorization §3](./authorization.md#3-cross-organization-identities)).
>
> Only an owner or admin can choose which identity a membership uses. Other roles can keep or clear their own link, but cannot point it at another identity. The browser reads that identity's credential, so a free choice would let a user read any credential ([Authorization](./authorization.md)).

---

## 5. The "Hello World" Event

Send a message and watch it arrive.

1. On the dashboard, add a **Console** widget. It shows every message the
   browser receives on the bus.
2. Publish a test message with the `nats` CLI, or with a **Publisher** widget:

   ```bash
   nats pub test.hello '{"msg": "Hello Stone Age", "val": 42}'
   ```

3. The message appears in the Console widget.

When you have Thing Types with operations, the Publisher widget can bind to a
Thing and an operation. The subject then comes from the Thing, and the payload
is free text. See [Thing Types](./thing-types.md).

---

## 6. Next Steps

### At any depth

- Read [Authorization & Roles](./authorization.md) before you invite your team.
  `admin` has full tenant authority, the same as `owner`.
- Put your config in git. `stone pull` writes every tenant record to YAML that
  you can diff and review. See [Stone CLI §5](./stone-cli.md#5-declarative-workspaces-pull-apply).
- Read [Platform Layers](./platform-layers.md) for the full model, and
  [What We Call Things](./overview.md#what-we-call-things) for the names.

### If you stopped at §2 (inventory)

Consider running a NATS server anyway. The queued account claims apply as soon
as it is reachable, and the cluster is current on the day you add a device.
`nats export` and then `serve --nats` is two commands and no extra process.

- Build Location Types and the location tree, then place Things on floor plans.
  See [Platform Entities & UI](./platform-ui-entities.md).
- Import an existing asset register with the REST API or `stone`.
- Go to §3 when you need messaging. Your records stay the same and gain
  identities.

### If you completed §5 (inventory and fabric)

Each addition is a separate binary on the same NATS bus.

- Define [Thing Types](./thing-types.md) to declare each participant's subjects.
- Install the [Agent](./agent.md) on a Linux or Windows machine to collect
  telemetry.
- Open **Dashboard**, unlock the grid, and add a **Gauge** or **Chart** widget
  on your NATS subjects.
- Deploy the rule engine: router for NATS-to-NATS logic, gateway for webhooks,
  scheduler for cron publishes. See [Automation](./automation.md).
- For windowed aggregations or stream joins, see [Stream Processing](./stream-processing.md).
- For long-term storage, add Telegraf and a TSDB. See [Observability](./observability.md).
