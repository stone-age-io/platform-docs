# Getting Started

## The short version

One container. It seeds itself on first boot and runs the message bus in the same
process:

```bash
docker run -d --name stone-age \
  -p 8090:8090 -p 4222:4222 -p 9222:9222 \
  -v stone-age-data:/data \
  -e STONE_AGE_BOOTSTRAP_PASSWORD='change-me-8-chars-min' \
  -e STONE_AGE_NATS_WEBSOCKET_URLS='ws://localhost:9222' \
  ghcr.io/stone-age-io/platform:latest
```

Console at `http://localhost:8090`, sign in as `admin@example.com` with that
password. Admin panel at `/_/`.

Or from a binary, which is the same five commands the container runs for you:

```bash
./stone-age superuser upsert admin@example.com 'change-me-8-chars-min'
./stone-age migrate up
./stone-age bootstrap --email admin@example.com --org "System" --operator-org "Acme MSP"
./stone-age nats export --output ./nats-config/
./stone-age serve --nats
```

**The order is load-bearing** — `bootstrap` writes fields that `migrate up`
creates, and `nats export` needs what `bootstrap` seeds. §2 explains why, and
what each command actually does.

That is the whole install. Everything below is the same path with the reasoning
attached, plus what to do next.

---

## What this guide covers

The rest of it is in two halves, lining up with the first two
[depths](./index.md#start-where-you-need-to):

| Sections | What you get |
| :--- | :--- |
| **§1–§2** | **Depth 1** — a multi-tenant inventory of Things and Locations, over the REST API with a console on top |
| **§3–§5** | **Depth 2** — the messaging fabric those records get their identities on |

The order is deliberate: the Control Plane's database has to be seeded before it can emit the NATS server config, so §2 necessarily precedes §3. A consequence is that **§2 is exercisable on its own**, and §2 ends with a checkpoint that does exactly that.

**You can also stop after §2** — that's a real deployment for anyone whose problem is "keep an accurate, permissioned record of what we own and where it is," not a crippled trial. Just note that stopping means stopping at *modeling* depth, not trimming the stack: you'd still run a NATS server in a normal deployment — as a separate process, or inside the Control Plane with `serve --nats` — it would simply have nothing on it and no device holding a credential to reach it.

Sections §3 onward add the **Data Plane** (NATS), which is what the rest of the platform — rules, stream processing, long-term storage — builds on. See [Platform Layers](./platform-layers.md) for that model.

---

## 1. Installation

Three ways in, in increasing order of effort.

### Container

```bash
docker run -d --name stone-age \
  -p 8090:8090 -p 4222:4222 -p 9222:9222 \
  -v stone-age-data:/data \
  -e STONE_AGE_BOOTSTRAP_PASSWORD='change-me-8-chars-min' \
  -e STONE_AGE_NATS_WEBSOCKET_URLS='ws://localhost:9222' \
  ghcr.io/stone-age-io/platform:latest
```

The entrypoint runs §2's commands on first boot and then `serve --nats`, so this
covers §1 through §4 in one line. Everything lives on the `/data` volume: the
database, the generated NATS config, the account JWTs and the JetStream store.

`STONE_AGE_NATS_WEBSOCKET_URLS` is the address a **browser** dials, which the
container cannot work out for itself — use the host's real name rather than
`localhost` if anyone else will use it.

### Pre-compiled binary

Download for your architecture from the
[Releases page](https://github.com/stone-age-io/platform/releases). Two binaries
are published per platform: `stone-age` (the Control Plane) and `leaf-sync` (the
[edge agent](./leaf-nodes.md), which belongs on edge hardware rather than here).

### From source

Needs Go 1.26+ and Node.js 20.19+ (or 22.12+ — that is Vite's floor, not ours).

```bash
git clone https://github.com/stone-age-io/platform.git
cd platform

# The console. This writes into pb_public/, which the Go build embeds.
cd ui && npm install && npm run build && cd ..

# The binary. Note the `.` — the package, not just main.go, which would
# leave out bootstrap.go and fail to compile.
go build -o stone-age .
```

About two minutes end to end on a developer laptop, most of it `npm install` and
the Vite build.

---

## 2. Initialize the Control Plane

The Stone-Age.io Platform looks for an optional `config.yaml` in the current directory, or can be configured using environment variables. These configuration options drive the underlying PocketBase libraries. By default, the binary looks for NATS at `nats://localhost:4222` — but nothing in this section requires NATS to be running, and neither does §2's checkpoint.

This step initializes the database, seeds the NATS Operator/System Account/System User, and creates your first human administrator. It is **three commands, and the order is load-bearing** — see the note at the end of this section. None of them need the server to be running — they open the embedded database directly.

### Step 1: Create the SuperUser (and seed initial data)

```bash
./stone-age superuser upsert EMAIL PASS
```

This is the first command you run on a fresh install. It creates a **SuperUser** — a backend service account with full database access regardless of API rules. As a side effect, the binary runs the support libraries' first-time setup (which seeds the NATS Operator, System Account, and System User) and starts audit logging.

### Step 2: Import the schema

```bash
./stone-age migrate up
```

This applies the embedded migrations, which import `schema.json` — the collections **and the API rules that are the platform's only authorization layer** ([Authorization](./authorization.md)). Skipping this step is the classic first-install mistake; the next step depends on the fields it creates.

### Step 3: Bootstrap the first Organization and Operator user

```bash
./stone-age bootstrap --email admin@example.com --org "System" --operator-org "Acme MSP"
```

The `bootstrap` command creates your first **Operator** user (a regular user with `is_operator = true`), creates the `System` Organization, links the pre-existing NATS System Account/User/Role to it, and — via `--operator-org` — creates the platform operator's *own* organization, whose NATS account is the hub for shared operator services. `--org` defaults to `System`; omit `--email`, `--password`, or `--operator-org` and it prompts.

Together with the embedded admin panel, `bootstrap` is the **only** way to grant Operator status. No API rule permits writing `is_operator`, so an Operator cannot be minted over REST — not by an Owner, and not by another Operator.

From here forward, use the **Operator** user to administer the platform from the UI. The SuperUser is best reserved for infrastructure-level management (schema imports, NATS Operator key custody, troubleshooting via the embedded admin UI at `/_/`).

> **Why the order matters.** `bootstrap` writes `is_operator`, `is_system_org`, and `is_operator_org` — fields that don't exist until Step 2 has imported the schema. PocketBase **silently drops** writes to fields that don't exist, so running `bootstrap` before `migrate up` used to "succeed" while producing a platform with no Operator and no error anywhere. The command now refuses to run before the migrations, but the order is still the thing to remember.

### Checkpoint — you have a working inventory

Start the server:

```bash
./stone-age serve
```

Sign in at `http://localhost:8090` as your Operator user. NATS isn't up yet — §3 handles that — and everything below works regardless:

- Create Organizations, and invite users into them with roles.
- Create Locations, Location Types, and Thing Types.
- Create Things, and edit them from desktop or mobile.
- Place Things on a floor plan or a map.
- Drive all of the above over the REST API or the [`stone` CLI](./stone-cli.md).

Create a Location and a Thing over the API to prove it:

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

`"mode":"none"` on both halves is what makes this depth 1: the Thing is created as a pure inventory record with no messaging identity and no mesh certificate. The console's create form offers the same three choices per identity (`auto`, `link`, `none`). You can attach identities later without recreating the record — see [Inventory-as-Identity](./architecture.md#31-inventory-as-identity).

> **The NATS warning in the log is expected here, and it is not an error.**
>
> On startup the Control Plane tries to reach NATS. It can't yet, so it logs *"Publisher will continue operating - connection will be established when NATS becomes available"* and enters **bootstrap mode**: a retry ticker plus a durable work queue.
>
> This exists to break a chicken-and-egg problem, not to make NATS optional. The database must be seeded before `stone-age nats export` can emit a server config, and NATS can't be reached before it's running — so credential work performed in the meantime is written to the `nats_publish_queue` collection instead of being published, and drains on the first run that connects. That's why `bootstrap` in §2 can create Organizations before a server exists: their account claims are queued on disk and land on the cluster the first time the Control Plane reaches NATS.
>
> **Don't read this as a steady state.** Running indefinitely without NATS just grows the queue while the cluster's claims sit stale relative to the database. Harmless while nothing is connected, but it isn't a topology to design around — bring NATS up in §3.

**If an inventory is what you needed, you're done for now.** Skip to [§6 Next Steps](#6-next-steps). Otherwise continue to §3 and give those records identities on the fabric.

---

## 3. Stand Up the NATS Server

Everything above this line is depth 1 — inventory, no messaging. This section starts depth 2: standing up the fabric so the inventory records you just created can hold identities and talk. It also drains anything §2 left queued.

Now that the Control Plane database has been seeded with the NATS Operator and System Account, export the matching server-side config:

```bash
./stone-age nats export --output ./nats-config/
```

The exported directory contains the operator JWT, the operator config, and a ready-to-use `nats.conf`. Paths inside it are absolute, so it works from any working directory, and the JWT and JetStream directories are created on first run.

Now run a server against it. There are two ways, and they use the same config file.

### Option A — inside the Control Plane

```bash
./stone-age serve --nats
```

One process. The Control Plane starts a NATS server from `./nats-config/nats.conf` (override with `--nats-config`) and shuts it down with itself. This is the shortest path to a working bus and it is a legitimate way to run a small deployment — see [Operations §2.1](./operations.md#21-where-the-nats-server-runs) for what you are trading away.

Skip §4's `serve` command if you use this; the server is already running.

### Option B — as its own process

```bash
nats-server -c ./nats-config/nats.conf
```

The normal topology, and the only one that supports clustering or upgrading the Control Plane without interrupting the bus. Use this if you are unsure — it is the default, and Option A is the opt-in.

Either way the running server is identical, because the config is. We won't go deep on running NATS here — their [documentation](https://docs.nats.io) covers production topologies, leaf nodes, clustering, and TLS in depth.

> **WebSockets are required** for the browser UI to connect — browsers cannot speak the NATS TCP protocol. The exported `nats.conf` enables a WebSocket listener on port `9222`; adjust the `websocket { ... }` block for TLS (`wss://`), or pass `--websocket-port` to the export.

---

## 4. Connect the Browser to NATS

If you used **Option A**, the platform is already running and you can skip straight to the UI. Otherwise start it:

```bash
./stone-age serve
```

The UI is available at `http://localhost:8090` (sign in with your Operator user). The embedded admin UI is at `http://localhost:8090/_/` (sign in with your SuperUser).

With NATS now running, the console can hold a live connection to the bus — this is what turns the static inventory from §2 into a live view. Once you're signed in as the Operator, point the browser at NATS:

1. Navigate to **Settings** in the sidebar.
2. Under **NATS Connection**, add your NATS WebSocket URL — usually `ws://localhost:9222` for a local server, or `wss://...` once TLS is in place.
3. **Linked Identity:** the bootstrap step linked the seeded NATS **System User** to the System organization. Assign that user to your membership so the browser has credentials to connect with.
4. Optionally enable **Auto-connect on login**, then click **Connect**.

You should see a green **Status: Connected** indicator.

> **For real workloads, create a new Organization (and its NATS Account/User) rather than reusing the System account.** The System Account is reserved for NATS cluster-management traffic and is not JetStream-enabled, which makes it a poor fit for day-to-day data. Note that **creating an Organization requires an Operator** — `organizations.createRule` admits nothing else, so do this while signed in as the Operator user from Step 3 ([Authorization §3](./authorization.md#3-cross-organization-identities)).

---

## 5. The "Hello World" Event

Let's verify the entire pipeline is working by sending a message and watching it appear in real-time.

### Step A: Open the Live Stream
On the dashboard, add a new Widget and use the Console widget. This is a raw view of all messages the browser is currently seeing on the bus.

### Step B: Publish a Test Message
You can use the `nats` CLI tool or add another widget and use the built-in **Publisher** widget in the Dashboard:

#### Using the NATS CLI
```bash
nats pub test.hello '{"msg": "Hello Stone Age", "val": 42}'
```

Once you've defined Thing Types and their operations, the Publisher widget can also bind to a `Thing + Operation` pair — the subject resolves automatically from the Thing's context and the payload form is driven by the operation's message schema. See [Thing Types](./thing-types.md).

### Step C: The Result
You should see the message appear instantly in the live stream. 

---

## 6. Next Steps

Where you go next depends on where you stopped.

### Useful at any depth

*   **Invite your team:** Before handing out roles, read [Authorization & Roles](./authorization.md) — `admin` carries full tenant authority, identical to `owner`.
*   **Put your config in git:** `stone pull` writes every tenant record to YAML you can diff and review. See [Stone CLI §5](./stone-cli.md#5-declarative-workspaces-pull-apply).
*   **Understand the whole architecture:** Read [Platform Layers](./platform-layers.md) for the full model, and [Overview](./overview.md#what-we-call-things) for what the names mean.

### If you stopped at §2 (inventory)

You have a Control Plane and nothing on the fabric, which is a supported place to be. Consider still running a NATS server alongside it — the queued account claims land as soon as one is reachable, and you avoid a stale cluster the day you do add a device. `nats export` followed by `serve --nats` makes that two commands and no extra process. The natural next moves are inventory-shaped:

*   **Model your sites:** Build out Location Types and the location tree, then place Things on floor plans. See [Platform Entities & UI](./platform-ui-entities.md).
*   **Bulk-load what you own:** Script the REST API or use `stone` to import an existing asset register.
*   **Come back to §3 when you need messaging.** Nothing you built here gets rewritten — the records you created simply gain identities.

### If you completed §5 (inventory + fabric)

You have a Control Plane and Data Plane running. Each addition below is **its own single-binary component** that connects to the same NATS bus — no architectural rework, just another process to run.

*   **Declare contracts:** Define [Thing Types](./thing-types.md) so every participant on your fabric has a declarative contract for its subjects and message shapes.
*   **Deploy an Agent:** Install the [Agent](./agent.md) on a Linux or Windows machine to start collecting telemetry from real infrastructure.
*   **Build a Dashboard:** Click **Dashboard** in the sidebar (the Visualizer view) — unlock the grid and add a **Gauge** or **Chart** widget pointing to your NATS subjects.
*   **Define rules (Layer 1):** Deploy the rule engine — router for NATS-to-NATS logic, gateway for webhooks, scheduler for cron-based publishing. See [Automation](./automation.md).
*   **Add stream processing (Layer 2):** When you need windowed aggregations or stream joins, see [Stream Processing](./stream-processing.md).
*   **Archive history (Layer 3):** Hook up Telegraf and a TSDB for long-term storage. See [Observability](./observability.md).
