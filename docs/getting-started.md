# Getting Started

The Stone-Age.io Platform is designed to get you from a blank terminal to a live, multi-tenant IoT dashboard in under five minutes. (OK maybe not that fast, but it's pretty fast!) Each component is a single binary — the simplest deployment is the platform UI and a single NATS server. You don't need to manage a fleet of containers, complex Docker Compose setups, or a Kubernetes cluster just to get off the ground.

This guide stands up the **Control Plane** (PocketBase) and the core of the **Data Plane** (NATS) — the foundation the rest of the platform builds on. Once that's live, you can add the higher layers (rules, stream processing, long-term storage) as needed. See [Platform Layers](./platform-layers.md) for the full model.

---

## 1. Installation

You can download the latest pre-compiled binary for your architecture from our [Releases page](https://github.com/stone-age-io/platform/releases), or build it from source if you have Go 1.25+ and Node.js 20+ installed.

### Building from Source
```bash
# Clone the repository
git clone https://github.com/stone-age-io/platform.git
cd platform

# Build the UI
cd ui && npm install && npm run build && cd ..

# Build the Go binary
go build -o stone-age main.go
```

---

## 2. Initialize the Control Plane

The Stone-Age.io Platform looks for an optional `config.yaml` in the current directory, or can be configured using environment variables. These configuration options drive the underlying PocketBase libraries. By default, the binary expects NATS to be available at `nats://localhost:4222`.

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

---

## 3. Stand Up the NATS Server

Now that the Control Plane database has been seeded with the NATS Operator and System Account, export the matching server-side config and start NATS:

```bash
./stone-age nats export --output ./nats-config/
nats-server -c ./nats-config/nats.conf
```

The exported directory contains the operator JWT, operator config, and a ready-to-use `nats-server` config. We won't go deep on running NATS here — their [documentation](https://docs.nats.io) covers production topologies, leaf nodes, clustering, and TLS in depth.

> **WebSockets are required** for the browser UI to connect. The exported `nats.conf` enables a WebSocket listener on port `9222` by default — adjust the `websocket { ... }` block if you need TLS (`wss://`) or a different port.

---

## 4. Run the Control Plane and Connect the Browser

Start the platform server:

```bash
./stone-age serve
```

The UI is available at `http://localhost:8090` (sign in with your Operator user). The embedded admin UI is at `http://localhost:8090/_/` (sign in with your SuperUser).

Once you're signed in as the Operator, point the browser at NATS:

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

Congratulations! You have a fully functional Control Plane and Data Plane running — the foundation of the platform is live.

From here, you can grow into the higher layers as your needs demand. Each addition below is **its own single-binary component** that connects to the same NATS bus you just set up — no architectural rework required, just another process to run.

*   **Deploy an Agent:** Install the [Agent](./agent.md) on a Linux or Windows machine to start collecting telemetry from real infrastructure.
*   **Build a Dashboard:** Click **Dashboard** in the sidebar (the Visualizer view) — unlock the grid and add a **Gauge** or **Chart** widget pointing to your NATS subjects.
*   **Declare contracts:** Define [Thing Types](./thing-types.md) so every participant on your fabric has a declarative contract for its subjects and message shapes.
*   **Define rules (Layer 1):** Deploy the rule engine — router for NATS-to-NATS logic, gateway for webhooks, scheduler for cron-based publishing. See [Automation](./automation.md).
*   **Add stream processing (Layer 2):** When you need windowed aggregations or stream joins, see [Stream Processing](./stream-processing.md).
*   **Archive history (Layer 3):** Hook up Telegraf and a TSDB for long-term storage. See [Observability](./observability.md).
*   **Invite your team:** Before handing out roles, read [Authorization & Roles](./authorization.md) — `admin` carries full tenant authority, identical to `owner`.
*   **Understand the whole architecture:** Read [Platform Layers](./platform-layers.md) for the full model.
