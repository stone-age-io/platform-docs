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
  server_url: "nats://localhost:4222"
  log_to_console: false
  default_limits:
    max_connections: 10
    max_subscriptions: 50
    max_payload: 1048576    # 1 MB
  export_collection_name: "nats_account_exports"
  import_collection_name: "nats_account_imports"

nebula:
  ca_collection_name: "nebula_ca"
  network_collection_name: "nebula_networks"
  host_collection_name: "nebula_hosts"
  log_to_console: false
  default_ca_validity_years: 10

audit:
  collection_name: "audit_logs"
  log_console: false
  retention:
    max_age: ""             # Go duration string, e.g. "720h" for 30 days. "" disables.
    max_records: 0          # 0 disables record-count retention.
    interval: "0 2 * * *"   # Cron schedule for the cleanup job.
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
| `operator_name` | string | `"stone-age.io"` | The NATS Operator name stamped into the Operator JWT at first run. |
| `server_url` | string | `"nats://localhost:4222"` | Where the Control Plane connects to NATS as a System Account client. |
| `log_to_console` | bool | `false` | Verbose NATS-library logging. |
| `default_limits.max_connections` | int | `10` | Default max connections for new Org accounts. |
| `default_limits.max_subscriptions` | int | `50` | Default max subscriptions for new Org accounts. |
| `default_limits.max_payload` | int | `1048576` | Default max payload bytes for new Org accounts (1 MB). |
| `export_collection_name` | string | `"nats_account_exports"` | Account-level Export collection name. See [Connectivity §1](./connectivity.md). |
| `import_collection_name` | string | `"nats_account_imports"` | Account-level Import collection name. |

> **Note:** Account-level limits set here are platform-wide defaults applied to *new* Organizations. Existing Org accounts can be edited individually in the UI without re-deploying.

### `nebula`

Controls the `pb-nebula` library: CA, network, and host certificate management.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `ca_collection_name` | string | `"nebula_ca"` | Certificate Authority collection name. |
| `network_collection_name` | string | `"nebula_networks"` | Per-CA network collection name. |
| `host_collection_name` | string | `"nebula_hosts"` | Host certificate collection name. |
| `log_to_console` | bool | `false` | Verbose Nebula-library logging. |
| `default_ca_validity_years` | int | `10` | Default validity for newly-generated org CAs. |

### `audit`

Controls the `pb-audit` library: comprehensive audit logging of create/update/delete/auth events.

| Key | Type | Default | Purpose |
|---|---|---|---|
| `collection_name` | string | `"audit_logs"` | Where audit records are written. |
| `log_console` | bool | `false` | Mirror audit events to stdout. |
| `retention.max_age` | string | `""` | Go duration string (e.g. `"720h"` = 30 days). Empty disables age-based pruning. |
| `retention.max_records` | int | `0` | Max records to keep. `0` disables count-based pruning. |
| `retention.interval` | string | `"0 2 * * *"` | Cron expression for the retention sweep job. |

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

## 4. PocketBase Flags

Because the platform binary embeds PocketBase, the standard PocketBase CLI flags are also available — most notably:

- `--dir <path>` — override the data directory (default `./pb_data`).
- `--dev` — enable verbose logging and SQL statement printing.
- `--encryptionEnv <name>` — name of an env var holding a 32-character key used to encrypt app settings at rest.
- `--queryTimeout <seconds>` — default SELECT query timeout.

These apply uniformly to all subcommands (`serve`, `bootstrap`, `nats export`, `superuser upsert`).

---

## 5. Operational Notes

- **Changing `operator_name` after first run is not safe** — the Operator JWT is generated once at first SuperUser creation. Renaming would orphan the existing identity hierarchy.
- **`server_url` is for the Control Plane's System Account connection only.** Browser-facing NATS WebSocket URLs are configured per-user in the Settings page, not here.
- **Audit retention runs on a schedule, not on every write.** A misconfigured `interval` will just delay cleanup, not break ingestion.
- **The schema is embedded in the binary**, not loaded from disk. To change schema, rebuild the binary with an updated `schema.json` (see the platform README).

---

## 6. Where to Go Next

- **Initial setup walkthrough:** [Getting Started](./getting-started.md).
- **What the NATS section provisions:** [Architecture](./architecture.md).
- **Imports / exports cross-account sharing:** [Connectivity](./connectivity.md).
