# Getting Started

The Stone-Age.io Platform is designed to get you from a blank terminal to a live, multi-tenant IoT dashboard in under five minutes. (ok maybe not that fast, but it's pretty fast!) Each component is a single binary, the simplest deployment is the platform UI and a single NATS server. You don't need to manage a fleet of containers, complex Docker Compose, or Kubernetes cluster just to get off the ground.

---


## 1. Installation

You can download the latest pre-compiled binary for your architecture from our [Releases page](https://github.com/stone-age-io/platform/releases), or build it from source if you have Go 1.23+ installed.

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

## 2. First Run: The Control Plane

The Stone-Age.io Platform looks for an optional `config.yaml` in the current directory, or can be configured using environment variables. These configuration options allow you to dictate the underlying Pocketbase libraries. By default, it expects NATS to be available at `nats://localhost:4222`.

### Create your SuperUser and Initial Data

Before we start running the application, let's create a SuperUser which has access to ALL data in the control plane, regardless of API Rules and we'll also seed our initial data. 

```bash
./stone-age superuser upsert EMAIL PASS
```

By creating your SuperUser or on initial run of the server, you have populated all initial data and schema information. Schema is imported from the embedded file in the binary, support libraries have done their initial run to populate NATS Operator/System Account/System User, and begin audit logging. You can now use the binary to export your NATS configuration files for deploying your NATS server(s)

```bash
./stone-age nats export --output ./nats-config/
```

Finally, we'll use the built-in `bootstrap` command to create your first Pocketbase Operator User, create your first Organization, and take ownership of the NATS System Account and System User into this organization.

```bash
./stone-age bootstrap
```

As a note, it is suggested from here forward to use this Pocketbase Operator User to manage the system. SuperUsers should be thought of as a backend service account for management of the underlying infrastructure and Pocketbase Operator Users, while your Pocketbase Operator User is used to administer the platfrom from the UI.

### Start the Platform Server
```bash
./stone-age serve
```

Now you can open your browser and access the UI at `http://localost:8090` using your Pocketbase Operator User or you can access the embedded SuperUser UI at `http://localhost:8090/_` using your SuperUser credentials.

---

## 3. The NATS Bridge: Data Plane Setup

We're not going to go into too much depth about how to run NATS since we think their [documentation](https://docs.nats.io) already does a great job. If you exported the config earlier, just run the server with `nats-server -c /path/to/nats.conf`

Now that the Control Plane and Data Plane are running, we need to tell your browser how to talk to the Data Plane (NATS).

1.  Navigate to **Settings** in the sidebar.
2.  Under **NATS Connection**, add your NATS WebSocket URL. 
    *   *Note: If NATS is local, this is usually `ws://localhost:9222` or `wss://...`.*
3.  **Linked Identity:** Since the platform automatically provisioned a NATS System Account and System User when you created your Organization, you can assign the **System User** to your membership.
4.  Optionally set **Auto-connect on login** and then click **Connect**. 

You should see a green indicator: **Status: Connected**.

Note: At this point you probably want to create a new organization/NATS Account/NATS User for actual use. You can use the System Account, but it's really meant for built-in NATS server/cluster operations, and management, not actual data. The System Account also isn't JetStream enabled which is another reason not to use it for day-to-day data.

---

## 4. The "Hello World" Event

Let's verify the entire pipeline is working by sending a message and watching it appear in real-time.

### Step A: Open the Live Stream
On the dashboard, add a new Widget and use the Console widget. This is a raw view of all messages the browser is currently seeing on the bus.

### Step B: Publish a Test Message
You can use the `nats` CLI tool or add another widget and use the built-in **Publisher** widget in the Dashboard:


#### Using the NATS CLI
```bash
nats pub test.hello '{"msg": "Hello Stone Age", "val": 42}'
```

### Step C: The Result
You should see the message appear instantly in the live stream. 

---

## 5. Next Steps

Congratulations! You have a fully functional Control and Data plane running.

*   **Deploy an Agent:** Install the Agent on a Linux or Windows machine to start collecting telemetry.
*   **Build a Dashboard:** Navigate to the **Visualizer**, unlock the grid, and add a **Gauge** or **Chart** widget pointing to your NATS subjects.
*   **Define a Rule:** Open the **Rule-Router** and create your first automation logic to route data based on its content.
