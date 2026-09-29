---
path: platform/configuration
nav_order: 190
---
# Configuration Reference

The platform binary (`stone-age`) reads its configuration from these sources,
highest priority first:

1. **Environment variables** prefixed with `STONE_AGE_`. They override
   everything.
2. **The `--config /path/to/config.yaml` flag**, which loads a specific file.
3. **A `config.yaml` found automatically**, in `./` first, then
   `/etc/stone-age/`.
4. **Built-in defaults**, for any key not set above.

The binary runs with no config file. Most production deployments keep a
`config.yaml` in source control and set hostnames and secrets with environment
variables.

---

## 1. The `config.yaml` File

```yaml
tenancy:
  organizations_collection: "organizations"
  memberships_collection: "memberships"
  invites_collection: "invites"
  invite_expiry_days: 7

nats:
  account_collection_name: "nats_accounts"
  user_collection_name: "nats_users"
  role_collection_name: "nats_roles"
  operator_name: "stone-age.io"
  server_url: "nats://localhost:4222"       # where THIS PROCESS dials
  websocket_urls: []                        # where a BROWSER dials. Not the same thing.
  leaf_url: ""                              # where an EDGE box's leaf remote dials. Not the same thing either.
  jetstream_domain: "hub"                   # this hub's own JetStream domain
  encryption_key: ""                        # encrypts the minting keys at rest (§2.2)
  managed_export_subject: "helpdesk.>"
  log_to_console: false
  default_limits:
    max_connections: 100
    max_subscriptions: 5000
    max_payload: 1048576                    # 1 MiB, nats-server's own default
    max_jetstream_disk_storage: 5368709120  # 5 GiB
    max_jetstream_memory_storage: 67108864  # 64 MiB
  export_collection_name: "nats_account_exports"
  import_collection_name: "nats_account_imports"
  embedded: false                             # run NATS inside this process
  embedded_config: "./nats-config/nats.conf"  # the config --nats loads

nebula:
  ca_collection_name: "nebula_ca"
  network_collection_name: "nebula_networks"
  host_collection_name: "nebula_hosts"
  log_to_console: false
  default_ca_validity_years: 10
  encryption_key: ""        # encrypts the CA and host private_key columns at rest

audit:
  collection_name: "audit_logs"
  log_to_console: false
  retention:
    max_age: ""             # Go duration string, e.g. "720h" for 30 days. "" disables.
    max_records: 0          # 0 disables record-count retention.
    interval: "0 2 * * *"   # Cron schedule for the cleanup job.

readiness:
  interval: 15s
  timeout: 5s

metrics:
  enabled: true
  token: ""   # empty = open, the default

branding:
  dir: ""     # a host directory of overrides; "" uses the embedded defaults
```

---

## 2. Section Reference

### `tenancy`

Organizations, memberships and invitations (`hooks/org_membership.go`,
`hooks/invites.go`).

| Key | Type | Default | Purpose |
|---|---|---|---|
| `organizations_collection` | string | `"organizations"` | Name of the Orgs collection. Change it only if you migrate from a non-default schema. |
| `memberships_collection` | string | `"memberships"` | Name of the User-to-Org link collection. |
| `invites_collection` | string | `"invites"` | Name of the pending-invite collection. |
| `invite_expiry_days` | int | `7` | How long an invite token stays valid. |

Invitation email failures go to the application logger.

### `nats`

The `pb-nats` library: NATS account, user and role provisioning, exports and
imports, and the System Account connection.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `account_collection_name` | string | `"nats_accounts"` | NATS Account collection name. |
| `user_collection_name` | string | `"nats_users"` | NATS User collection name. |
| `role_collection_name` | string | `"nats_roles"` | NATS Role collection name. |
| `operator_name` | string | `"stone-age.io"` | The NATS Operator name, written into the NATS Operator JWT on first run. |
| `server_url` | string | `"nats://localhost:4222"` | Where the Control Plane connects to NATS as a System Account client. **Not** the browser address (§2.1). |
| `websocket_urls` | string list | `[]` | The WebSocket addresses a **browser** connects to. `GET /api/client-config` gives them to the console at runtime (§2.1). |
| `leaf_url` | string | `""` | Where an **edge box's** leaf remote connects to this hub, usually port 7422 and often another hostname. [`GET /api/me/leaf-config`](./leaf-nodes.md) gives it to gateways as `hub_leaf_url`. Empty means no edge box can bootstrap. Must start with `nats-leaf://` or `tls://`, or the platform does not start. |
| `jetstream_domain` | string | `"hub"` | This hub's JetStream domain, which an edge uses to address the hub across the link (`$JS.<domain>.API`). Given to gateways as `hub_domain`. Must match `jetstream { domain }` in the hub's `nats.conf`. Agents cache it, so a later change reaches a site only when that site runs `agent -leaf-config` again. |
| `encryption_key` | string | `""` | 32-character key that encrypts the NATS **minting keys** at rest: operator, account and user seeds and private keys, and signing keys. **Not** issued credentials (§2.2). Empty means plaintext in SQLite. |
| `managed_export_subject` | string | `"helpdesk.>"` | The subject subtree a **managed** organization exports into the provider's hub account. The hub-side import remaps it to `<subtree>.<organization code>.>`, so the tenant token is in the account JWT that the NATS Operator signs, and nobody can forge it. So a managed organization needs a [code](./platform-ui-entities.md#organizations) before its export goes anywhere. Must end in `.>`, or the platform does not start. See [ADR 0002](./decisions/0002-organization-code-namespace.md). |
| `log_to_console` | bool | `false` | Verbose NATS-library logging. |
| `default_limits.max_connections` | int | `100` | Max connections for new Org accounts. Set it with headroom (see below). |
| `default_limits.max_subscriptions` | int | `5000` | Max subscriptions for new Org accounts. |
| `default_limits.max_payload` | int | `1048576` | Max payload bytes for new Org accounts (1 MiB, nats-server's own default). |
| `default_limits.max_jetstream_disk_storage` | int | `5368709120` | JetStream file storage for new Org accounts (5 GiB). This is what a plan sells. |
| `default_limits.max_jetstream_memory_storage` | int | `67108864` | JetStream memory storage for new Org accounts (64 MiB). A safety limit: keep it small and the same for all plans. |
| `export_collection_name` | string | `"nats_account_exports"` | Account export collection name. See [Connectivity §1](./connectivity.md). |
| `import_collection_name` | string | `"nats_account_imports"` | Account import collection name. |
| `embedded` | bool | `false` | Run a NATS server inside the Control Plane process. Only `serve` uses it. Same as `--nats`. |
| `embedded_config` | string | `"./nats-config/nats.conf"` | The `nats.conf` that `embedded` loads, which `nats export` writes. Same as `--nats-config`. |

> **The limits go into each new organization's signed account JWT, at provisioning only.** A change here does not reach an existing account. To change one, edit its `nats_accounts` record. Only a Platform Operator can, because the limits are what the tenant bought.
>
> **`-1` means unlimited. `0` on either JetStream field turns off JetStream for the account**, and with it the [digital twin](./thing-types.md), which is two KV buckets. Never use `0` for "no limit".
>
> **The two storage limits do different jobs.** Disk is what a plan sells. Memory is shared: a memory-backed stream uses RAM that every other tenant on the box needs, so a breach affects other accounts too. **Connections and subscriptions need headroom.** A breach means a device cannot connect or a subscription fails quietly, so set them well above expected load and alert as you get close. Clients behind an edge leaf node do **not** count toward `max_connections`: the hub sees one leaf connection per site. The count is browsers, the `stone` CLI, services and devices that connect to the hub directly.

> **`embedded` does not configure the NATS server.** The `nats.conf` does: ports, JetStream, WebSockets, clustering, TLS. `embedded` only decides whether the Control Plane runs that config or a separate `nats-server` does. Both give the same server, so moving between them is a config change, not a migration. See [Operations §2.1](./operations.md#21-where-the-nats-server-runs).
>
> The **port** must agree across the two files. `server_url` is where the Control Plane connects, and `port` in `nats.conf` is where the server listens. `--nats` refuses to start when they differ, because the process could not reach the server it started.

### 2.1 `server_url` and `websocket_urls` are different addresses

Mixing these up gives the least helpful symptom of any configuration mistake.

| | Who connects to it | Typical value |
| :--- | :--- | :--- |
| `nats.server_url` | **this process**, to publish account claims | `nats://nats:4222` inside a container |
| `nats.websocket_urls` | **a browser**, for a live console session | `wss://bus.example.com:9222` |

They have different ports and often different hosts. **Never compute one from
the other.** A Control Plane that publishes to `nats://nats:4222` inside a
container tells you nothing about what a browser on a laptop can reach.

`GET /api/client-config` gives `websocket_urls` to the console at runtime. The
console is embedded in the binary, so a build-time value would mean one frontend
build per provider (the same reason `branding.dir` exists). The endpoint needs
auth, because nothing needs the bus address before login.

The console picks the address in this order: a per-device override in
localStorage, then this key, then the built-in `ws://localhost:9222`.

- **The device override replaces this list. The two are never merged.** The
  NATS client shuffles its server list, so a merged list is a random pool, not a
  priority order. A device overrides the list to reach its *local leaf node*
  instead of the hub. The two are different JetStream domains with different
  data under the same bucket names, so a merged list would show a random dataset
  after each reconnect.
- **Several entries mean one cluster.** They are peers, not a failover order. Do
  not list a hub URL and a leaf URL together.
- **There is no JetStream domain setting.** The console passes no domain, so
  `$JS.API` goes to the JetStream of the server it connected to: the hub URL
  gives the hub, and a leaf URL gives that leaf's domain (its Thing's code). A
  separate setting could only disagree with the URL, and would fail as an empty
  bucket list with no explanation.
- **An HTTPS page cannot open `ws://`.** Browsers block it, so the settings form
  rejects a plaintext URL.

In an environment variable, separate URLs with **spaces**, not commas. viper
splits the value on whitespace, and the platform rejects a comma-joined entry at
startup:

```bash
STONE_AGE_NATS_WEBSOCKET_URLS="wss://a.example.com:9222 wss://b.example.com:9222"
```

### 2.2 The encryption keys

`nats.encryption_key` and `nebula.encryption_key` encrypt the **secret columns**
at rest: NATS operator, account and user seeds and private keys, account
signing keys, and the Nebula CA and host `private_key` columns. Both default to
empty, which means these values are plaintext in the SQLite file.

::: warning What these keys do not cover: issued credentials
The keys protect the material that **mints** identities. They do not and cannot
protect credentials already issued:

- `nats_users.creds_file` contains the user seed, and the browser reads it from
  the API to open its NATS connection.
- `nebula_hosts.config_yaml` contains the host key inline, because Nebula needs
  it there.

So if someone steals the database but not the key, they cannot mint new
identities, but they have **every credential already issued**. Protect against
that with disk encryption, encrypted backups and host access control. When
encryption is on, the readiness check says *"minting keys; issued credentials are
plaintext by construction"*. The platform repository's `SECURITY.md` explains
what a stolen database does and does not give an attacker.
:::

::: danger Set these before you create real data, and back up the keys separately
A row written with a key cannot be read without that key. There is no recovery.
If you lose a key, you lose every seed and private key it protected, and you
must provision every NATS identity and reissue every Nebula certificate again
in every affected organization. Set the keys with
`STONE_AGE_NATS_ENCRYPTION_KEY` and `STONE_AGE_NEBULA_ENCRYPTION_KEY`, not in
`config.yaml`.

Turning encryption **on** does not encrypt existing rows, and turning it **off**
does not decrypt them. Decide at install time.
:::

Generate 32 characters, and store them somewhere other than the backup of the
database they protect:

```bash
openssl rand -hex 16    # 32 characters
```

::: warning This is not `--encryptionEnv`
PocketBase's `--encryptionEnv` flag encrypts **app settings**: SMTP passwords,
S3 credentials, OAuth2 secrets. It does **not** encrypt the NATS and Nebula
columns above, which belong to this platform, not PocketBase.

You need both. `--encryptionEnv` is a CLI flag. These are `config.yaml` keys. A
checklist that stops at `--encryptionEnv` leaves every tenant's CA private key
in plaintext.
:::

### `nebula`

The `pb-nebula` library: CA, network and host certificate management.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `ca_collection_name` | string | `"nebula_ca"` | Certificate Authority collection name. |
| `network_collection_name` | string | `"nebula_networks"` | Per-CA network collection name. |
| `host_collection_name` | string | `"nebula_hosts"` | Host certificate collection name. |
| `log_to_console` | bool | `false` | Verbose Nebula-library logging. |
| `default_ca_validity_years` | int | `10` | Default validity for new org CAs. |
| `encryption_key` | string | `""` | 32-character key that encrypts the Nebula **CA and host `private_key` columns** at rest. Empty means plaintext in SQLite. The generated `config_yaml` still contains the host key in plaintext (§2.2). |

### `audit`

The `pb-audit` library: logs create, update, delete and auth events.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `collection_name` | string | `"audit_logs"` | Where audit records go. |
| `log_to_console` | bool | `false` | Also write audit events to stdout. `audit.log_console` also works. |
| `retention.max_age` | string | `""` | Go duration string (for example `"720h"` = 30 days). Empty turns off age-based pruning. |
| `retention.max_records` | int | `0` | Max records to keep. `0` turns off count-based pruning. |
| `retention.interval` | string | `"0 2 * * *"` | Cron expression for the retention job. |

> **What the audit log holds:** every create, update, delete and auth event records `changed_fields`, the *names* of the changed fields. It keeps old and new *values* only for an allowlist of collections (`auditSnapshotCollections` in the platform's `main.go`: organizations, memberships, users, the inventory and type collections, NATS roles, Nebula networks and email templates). Collections with credentials (NATS users and accounts, Nebula hosts and CAs, invites, exports and imports) record field names only.
>
> **Who can read it:** `audit_logs` list and view are `@request.auth.is_operator = true`. Only Platform Operators and SuperUsers can read it. **No tenant role, `owner` included, can**, and the console's `/audit` route uses the same check. A tenant admin must ask a Platform Operator for an audit export. A tenant can read its own `activity` feed (actor, action, record, time, no values), which is a separate collection with no retention setting here. See [Authorization §5](./authorization.md#5-two-histories-the-audit-log-and-the-activity-feed).

### `branding`

| Key | Type | Default | Purpose |
|---|---|---|---|
| `dir` | string | `""` | A host directory whose `branding.json`, `logo.svg` and `theme.css` override the embedded defaults, served at `/branding/*`. Empty turns off the overlay. |

With the overlay, you can re-skin the console with no frontend rebuild. Each
missing file falls back to its default. A starting template is in
`branding.example/` in the repository.

**This is the operator's brand, and an Organization's logo does not replace
it.** The sidebar mark and the login screen always use `branding`. The sidebar
brand is also the link to `/`, and it must not change when a user switches
organization. A tenant's logo shows in the **org switcher**. The
[QR label](./platform-ui-entities.md#codes-and-qr-labels) shows neither. A label
belongs to one organization, so it has that organization's code and the
record's code and name.

### `readiness`

The background prober behind `GET /api/ready`.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `interval` | string | `"15s"` | How often the checks run. The endpoint returns the last result, so this is also the maximum age of an answer. |
| `timeout` | string | `"5s"` | Deadline for one full probe. Checks run at the same time, so this limits the slowest one, not their total. |

The endpoint is always on, and no key turns it off. To restrict it, use a proxy.

### `metrics`

The Prometheus exposition at `GET /metrics`.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `enabled` | bool | `true` | Register the route. |
| `token` | string | `""` | Shared secret. Empty means **open**, the default. |

`token` works as `Authorization: Bearer <token>` or HTTP Basic with any
username. No metric has a per-organization label. See
[Health & Metrics](./health-metrics.md) for the checks, metric names and alert
expressions.

### `observability` (the Agent, not this file)

The edge agent's own `/ready` and `/metrics`. These keys go in the **Agent's**
`config.yaml`, not the Control Plane's. **On by default, on loopback.**

| Key | Type | Default | Purpose |
|---|---|---|---|
| `addr` | string | `"127.0.0.1:9100"` | Listen address. Empty means no listener. The checks still run and log. |
| `metrics_token` | string | `""` | Like `metrics.token` above. Set it before you move `addr` off loopback. |
| `interval` | string | `"15s"` | Probe interval. |

This is **not** a gateway setting. Every Agent serves these endpoints, because
`cmd.health` goes over NATS, and NATS is the link that fails. **9100 is
node_exporter's default port** on Linux and FreeBSD, so on a box that runs both,
move one. Windows is not affected (`windows_exporter` uses 9182). See
[Health & Metrics §5](./health-metrics.md#5-the-edge-agent) and
[Leaf Nodes](./leaf-nodes.md).

---

## 3. Environment Variable Overrides

Every key in `config.yaml` has a `STONE_AGE_*` environment variable. To get the
name:

- Add the prefix `STONE_AGE_`.
- Replace each `.` in the YAML path with `_`.
- Make it all uppercase.

Examples:

```bash
# Override NATS server URL (highest-priority source)
export STONE_AGE_NATS_SERVER_URL="nats://nats.internal:4222"

# Mirror audit events to stdout (useful in development)
export STONE_AGE_AUDIT_LOG_TO_CONSOLE=true

# Give new orgs a bigger JetStream disk allowance (10 GiB)
export STONE_AGE_NATS_DEFAULT_LIMITS_MAX_JETSTREAM_DISK_STORAGE=10737418240

# Keep the encryption keys out of config.yaml
export STONE_AGE_NATS_ENCRYPTION_KEY="$(cat /run/secrets/nats_key)"

# Tighten the invite window
export STONE_AGE_TENANCY_INVITE_EXPIRY_DAYS=2
```

Use environment variables for secrets and per-environment values (dev, staging,
prod), so you keep one YAML file.

---

## 4. CLI Flags

### Platform flags

| Flag | Default | Purpose |
|---|---|---|
| `--config <path>` | none | Load a specific `config.yaml`. |
| `--nats` | `false` | `serve` only: run a NATS server in this process. Sets `nats.embedded`. |
| `--nats-config <path>` | `./nats-config/nats.conf` | `serve` only: the `nats.conf` that `--nats` loads. Sets `nats.embedded_config`. |

`--nats` and `--nats-config` are on the root command, so every subcommand accepts
them, but only `serve` uses them. The other subcommands open the database
directly and have no bus.

### PocketBase flags

The binary embeds PocketBase, so the standard PocketBase flags also work. The
most useful:

- `--dir <path>`: the data directory (default `./pb_data`).
- `--dev`: verbose logging and SQL statement printing.
- `--encryptionEnv <name>`: the name of an env var with a 32-character key that
  encrypts app settings at rest.
- `--queryTimeout <seconds>`: default SELECT query timeout.

They apply to all subcommands (`serve`, `migrate`, `bootstrap`, `nats export`,
`superuser upsert`).

---

## 5. Operational Notes

- **Do not change `operator_name` after the first run.** The NATS Operator JWT
  is generated once, when the first SuperUser is created. A rename would orphan
  the existing identity hierarchy.
- **`server_url` is for the Control Plane's own System Account connection.** The
  browser's address is `websocket_urls`, a deployment default that the console's
  Settings page can override per device (§2.1).
- **Set the encryption keys at install time.** They cannot apply to existing
  rows, and losing one loses what it protected. They are **not** what
  `--encryptionEnv` covers (§2.2).
- **Audit retention runs on a schedule, not on every write.** A wrong
  `interval` only delays cleanup.
- **The schema is embedded in the binary.** A change to the embedded
  `schema.json` reaches **new databases only**. To change the schema or an API
  rule on an existing deployment, add a new `migrations/schema_update_*.go` file,
  which runs at startup. This is the most common way a rule fix fails to ship.
  See [Authorization §7](./authorization.md#7-changing-the-rules) and
  [Operations §5.1](./operations.md#51-how-upgrades-work).
- **API rules are the platform's authorization.** Nothing in `config.yaml`
  grants or limits access. The rules in the embedded schema do all of it, with
  one hook that refuses a relation into another organization. See
  [Authorization & Roles](./authorization.md).

---

## 6. Where to Go Next

- Initial setup: [Getting Started](./getting-started.md)
- Roles, API rules and the audit log: [Authorization & Roles](./authorization.md)
- What the NATS section provisions: [Architecture](./architecture.md)
- Cross-account imports and exports: [Connectivity](./connectivity.md)
