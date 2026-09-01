# Configuration Reference

The Stone-Age.io platform binary (`stone-age`) is configured through three sources, evaluated in priority order:

1. **Environment variables** prefixed with `STONE_AGE_` — override everything.
2. **The `--config /path/to/config.yaml` flag** — load a specific config file.
3. **A `config.yaml` discovered automatically** — looked up in `./` first, then `/etc/stone-age/`.
4. **Hardcoded defaults** — used for any key not set above.

The binary runs without a config file at all (defaults are sensible), but most production deployments commit a `config.yaml` to source control and override hostnames or secrets via environment variables.

---

## 1. The `config.yaml` File

```yaml
tenancy:
  organizations_collection: "organizations"
  memberships_collection: "memberships"
  invites_collection: "invites"
  invite_expiry_days: 7
  log_to_console: false

nats:
  account_collection_name: "nats_accounts"
  user_collection_name: "nats_users"
  role_collection_name: "nats_roles"
  operator_name: "stone-age.io"
  server_url: "nats://localhost:4222"       # where THIS PROCESS dials
  websocket_urls: []                        # where a BROWSER dials. Not the same thing.
  encryption_key: ""                        # encrypts account/user seeds at rest
  managed_export_subject: "helpdesk.>"
  log_to_console: false
  default_limits:
    max_connections: 10
    max_subscriptions: 50
    max_payload: 1048576    # 1 MB
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
  encryption_key: ""        # encrypts CA and host private keys at rest

audit:
  collection_name: "audit_logs"
  log_to_console: false
  retention:
    max_age: ""             # Go duration string, e.g. "720h" for 30 days. "" disables.
    max_records: 0          # 0 disables record-count retention.
    interval: "0 2 * * *"   # Cron schedule for the cleanup job.

branding:
  dir: ""     # a host directory of overrides; "" uses the embedded defaults
```

---

## 2. Section Reference

### `tenancy`

Controls the multi-tenancy collections managed by the `pb-tenancy` library.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `organizations_collection` | string | `"organizations"` | Name of the Orgs collection. Override only if migrating from a non-default schema. |
| `memberships_collection` | string | `"memberships"` | Name of the User↔Org link collection. |
| `invites_collection` | string | `"invites"` | Name of the pending-invite collection. |
| `invite_expiry_days` | int | `7` | How long an outstanding invite token remains valid. |
| `log_to_console` | bool | `false` | Verbose tenancy lifecycle logging. |

### `nats`

Controls the `pb-nats` library: NATS account/user/role provisioning, exports/imports management, and the System Account connection.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `account_collection_name` | string | `"nats_accounts"` | NATS Account collection name. |
| `user_collection_name` | string | `"nats_users"` | NATS User collection name. |
| `role_collection_name` | string | `"nats_roles"` | NATS Role collection name. |
| `operator_name` | string | `"stone-age.io"` | The NATS Operator name stamped into the NATS Operator JWT at first run. |
| `server_url` | string | `"nats://localhost:4222"` | Where the Control Plane connects to NATS as a System Account client. **Not** the browser address — see §2.1. |
| `websocket_urls` | string list | `[]` | The WebSocket addresses a **browser** dials, served to the console at runtime by `GET /api/client-config`. See §2.1. |
| `encryption_key` | string | `""` | 32-character key encrypting NATS account and user **seeds** at rest. Empty means plaintext in SQLite. See §2.2. |
| `managed_export_subject` | string | `"helpdesk.>"` | The subject subtree a **managed** organization exports into the provider's hub account. The matching hub-side import remaps it to `<subtree>.<organization code>.>`, so the tenant token is baked into the NATS-Operator-signed account JWT and provenance is unforgeable — which means a managed organization needs a [code](./platform-ui-entities.md#organizations) before its export routes anywhere. Must end in `.>`; the platform refuses to start otherwise. See [ADR 0002](./decisions/0002-organization-code-namespace.md). |
| `log_to_console` | bool | `false` | Verbose NATS-library logging. |
| `default_limits.max_connections` | int | `10` | Default max connections for new Org accounts. |
| `default_limits.max_subscriptions` | int | `50` | Default max subscriptions for new Org accounts. |
| `default_limits.max_payload` | int | `1048576` | Default max payload bytes for new Org accounts (1 MB). |
| `export_collection_name` | string | `"nats_account_exports"` | Account-level Export collection name. See [Connectivity §1](./connectivity.md). |
| `import_collection_name` | string | `"nats_account_imports"` | Account-level Import collection name. |
| `embedded` | bool | `false` | Run a NATS server inside the Control Plane process. Acted on by `serve` only. Equivalent to `--nats`. |
| `embedded_config` | string | `"./nats-config/nats.conf"` | The `nats.conf` that `embedded` loads — the file `nats export` writes. Equivalent to `--nats-config`. |

> **Note:** Account-level limits set here are platform-wide defaults applied to *new* Organizations. Existing Org accounts can be edited individually in the UI without re-deploying.

> **`embedded` does not configure the NATS server.** The `nats.conf` does — ports, JetStream, WebSockets, clustering, TLS. `embedded` only decides whether the Control Plane runs that config itself or leaves it to a separate `nats-server`. The two produce an identical server, which is why moving between them is a config change rather than a migration. See [Operations §2.1](./operations.md#21-where-the-nats-server-runs).
>
> One thing must agree across the two files: the **port**. `server_url` is where the Control Plane dials, and the `port` in `nats.conf` is where the server listens. `--nats` refuses to start when they differ, because nothing in the process could then reach the server it just started.

### 2.1 `server_url` and `websocket_urls` are different addresses

This is the configuration mistake with the least helpful symptom, so it is worth stating plainly.

| | Who dials it | Typical value |
| :--- | :--- | :--- |
| `nats.server_url` | **this process**, to publish account claims | `nats://nats:4222` inside a container |
| `nats.websocket_urls` | **a browser**, to hold a live console session | `wss://bus.example.com:9222` |

Different port, often a different host, and **never derive one from the other** — a Control Plane publishing to `nats://nats:4222` inside a container says nothing about what a browser on someone’s laptop can reach.

`websocket_urls` is served to the console at runtime by `GET /api/client-config` rather than compiled in, deliberately: the console is embedded in the binary, so a build-time constant would mean a frontend rebuild per provider — the same problem `branding.dir` exists to avoid. The endpoint is authenticated; there is no pre-login need for the bus address.

The console resolves the address in three tiers: a per-device override in localStorage, then this key, then a compiled-in `ws://localhost:9222`. Four rules follow from that:

- **The device override replaces this list; the two are never merged.** The NATS client shuffles its server list by default, so a merged list is a pool picked at random rather than a priority order — and the reason a device overrides is to reach its *local leaf node* instead of the hub. Those are different JetStream domains holding different data under the same bucket names, so merging would make *which dataset you are looking at* a coin flip per reconnect.
- **Multiple entries mean one cluster.** Peers, not failover order. Do not list a hub URL and a leaf URL together.
- **There is no JetStream domain setting, on purpose.** The console passes no domain, so `$JS.API` resolves to the JetStream of whichever server was dialed — hub URL gives the hub, leaf URL gives that leaf’s `edge-<code>`. The URL already selects the domain, and a separate knob could only disagree with it, failing as an empty bucket list with no diagnosis.
- **An HTTPS page cannot open `ws://`.** Browsers block it outright, so the settings form rejects a plaintext URL rather than saving one that can never connect.

In an environment variable, separate multiple URLs with **spaces**, not commas — viper splits that value on whitespace, and the platform rejects a comma-joined entry at startup rather than treating it as one malformed URL:

```bash
STONE_AGE_NATS_WEBSOCKET_URLS="wss://a.example.com:9222 wss://b.example.com:9222"
```

### 2.2 The encryption keys

`nats.encryption_key` and `nebula.encryption_key` encrypt the **secret columns** at rest: NATS account and user seeds, and Nebula CA and host private keys. Both default to empty, which means those values sit in the SQLite file in plaintext.

!!! danger "Set these before creating anything real, and back the keys up separately"
    A row written with a key cannot be read back without it. There is no recovery path: losing the key loses every seed and private key it protected, which means re-provisioning every NATS identity and re-issuing every Nebula certificate in every affected organization.

    Equally, turning encryption **on** for a database that already has rows does not retroactively encrypt them, and turning it **off** does not decrypt what is already encrypted. Decide at install time.

Generate 32 characters and keep them somewhere that is not the backup of the database they protect:

```bash
openssl rand -hex 16    # 32 characters
```

!!! warning "This is not the same thing as `--encryptionEnv`"
    PocketBase’s `--encryptionEnv` flag encrypts **app settings** — SMTP passwords, S3 credentials, OAuth2 secrets. It does **not** touch the NATS and Nebula columns above, because those collections belong to this platform rather than to PocketBase.

    A production checklist that ticks `--encryptionEnv` and stops has left every tenant’s CA private key in plaintext. Both are needed, and they are configured in different places: `--encryptionEnv` is a CLI flag, these are `config.yaml` keys.

### `nebula`

Controls the `pb-nebula` library: CA, network, and host certificate management.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `ca_collection_name` | string | `"nebula_ca"` | Certificate Authority collection name. |
| `network_collection_name` | string | `"nebula_networks"` | Per-CA network collection name. |
| `host_collection_name` | string | `"nebula_hosts"` | Host certificate collection name. |
| `log_to_console` | bool | `false` | Verbose Nebula-library logging. |
| `default_ca_validity_years` | int | `10` | Default validity for newly-generated org CAs. |
| `encryption_key` | string | `""` | 32-character key encrypting Nebula **CA and host private keys** at rest. Empty means plaintext in SQLite. See §2.2. |

### `audit`

Controls the `pb-audit` library: audit logging of create, update, delete, and auth events.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `collection_name` | string | `"audit_logs"` | Where audit records are written. |
| `log_to_console` | bool | `false` | Mirror audit events to stdout. |
| `retention.max_age` | string | `""` | Go duration string (e.g. `"720h"` = 30 days). Empty disables age-based pruning. |
| `retention.max_records` | int | `0` | Max records to keep. `0` disables count-based pruning. |
| `retention.interval` | string | `"0 2 * * *"` | Cron expression for the retention sweep job. |

> **Who can read the audit log:** `audit_logs` list and view are `@request.auth.is_operator = true`. Platform Operators and SuperUsers only — **no tenant role, including `owner`, can read it**, and the console's `/audit` route is gated on the same flag to match. A tenant admin cannot self-serve an audit export. The request has to go through a Platform Operator. See [Authorization §5](./authorization.md#5-the-audit-log-is-platform-operator-only).

### `branding`

| Key | Type | Default | Purpose |
|---|---|---|---|
| `dir` | string | `""` | A host directory whose `branding.json`, `logo.svg` and `theme.css` override the embedded defaults, served at `/branding/*`. Empty disables the overlay. |

The point of the overlay is that re-skinning the console needs no frontend rebuild — the console is embedded in the binary, so a compiled-in brand would mean one build per provider. Missing files fall back individually. A starting template ships in `branding.example/` in the repository.

---

## 3. Environment Variable Overrides

Every key in `config.yaml` has an `STONE_AGE_*` environment variable equivalent. The mapping rule is:

- Prefix with `STONE_AGE_`.
- Replace `.` (YAML path separator) with `_`.
- Uppercase the whole thing.

Examples:

```bash
# Override NATS server URL (highest-priority source)
export STONE_AGE_NATS_SERVER_URL="nats://nats.internal:4222"

# Mirror audit events to stdout (useful in development)
export STONE_AGE_AUDIT_LOG_CONSOLE=true

# Bump default limits for new orgs
export STONE_AGE_NATS_DEFAULT_LIMITS_MAX_CONNECTIONS=100
export STONE_AGE_NATS_DEFAULT_LIMITS_MAX_SUBSCRIPTIONS=500

# Tighten the invite window
export STONE_AGE_TENANCY_INVITE_EXPIRY_DAYS=2
```

Environment overrides are the recommended way to inject secrets and per-environment values (dev/staging/prod) without forking the YAML file.

---

## 4. CLI Flags

### Platform flags

| Flag | Default | Purpose |
|---|---|---|
| `--config <path>` | — | Load a specific `config.yaml`. |
| `--nats` | `false` | `serve` only: run a NATS server in this process. Sets `nats.embedded`. |
| `--nats-config <path>` | `./nats-config/nats.conf` | `serve` only: which `nats.conf` `--nats` loads. Sets `nats.embedded_config`. |

`--nats` and `--nats-config` are registered on the root command, so other subcommands accept them, but only `serve` acts on them — the rest open the database directly and have no bus to talk to.

### PocketBase flags

Because the platform binary embeds PocketBase, the standard PocketBase CLI flags are also available — most notably:

- `--dir <path>` — override the data directory (default `./pb_data`).
- `--dev` — enable verbose logging and SQL statement printing.
- `--encryptionEnv <name>` — name of an env var holding a 32-character key used to encrypt app settings at rest.
- `--queryTimeout <seconds>` — default SELECT query timeout.

These apply uniformly to all subcommands (`serve`, `migrate`, `bootstrap`, `nats export`, `superuser upsert`).

---

## 5. Operational Notes

- **Changing `operator_name` after first run is not safe** — the NATS Operator JWT is generated once at first SuperUser creation. Renaming would orphan the existing identity hierarchy.
- **`server_url` is for the Control Plane’s own System Account connection.** The address a browser dials is `websocket_urls`, which is a deployment default here and can be overridden per device in the console’s Settings page. See §2.1 — conflating the two is the configuration mistake with the least helpful symptom.
- **Set the encryption keys at install time.** `nats.encryption_key` and `nebula.encryption_key` cannot be introduced retroactively for rows that already exist, and losing one loses the material it protected. They are also **not** what `--encryptionEnv` covers. See §2.2.
- **Audit retention runs on a schedule, not on every write.** A misconfigured `interval` will just delay cleanup, not break ingestion.
- **The schema is embedded in the binary**, not loaded from disk. Updating the embedded `schema.json` is only half the change: it reaches **freshly-created databases only**. To change the schema — or an API rule — on an existing deployment, the platform needs a new `migrations/schema_update_*.go` file, which runs at startup. This is the most common way a rule fix fails to ship. See [Authorization §7](./authorization.md#7-changing-the-rules) and [Operations §5.1](./operations.md#51-how-upgrades-work).
- **API rules are the platform's only authorization layer.** Nothing in `config.yaml` grants or restricts access; the rules in the embedded schema do all of it. See [Authorization & Roles](./authorization.md).

---

## 6. Where to Go Next

- **Initial setup walkthrough:** [Getting Started](./getting-started.md).
- **Roles, API rules, and the audit-log boundary:** [Authorization & Roles](./authorization.md).
- **What the NATS section provisions:** [Architecture](./architecture.md).
- **Imports / exports cross-account sharing:** [Connectivity](./connectivity.md).
