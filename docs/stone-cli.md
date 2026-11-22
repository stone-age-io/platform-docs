---
path: platform/stone-cli
nav_order: 100
---
# Stone CLI

`stone` is the command-line client for Stone-Age.io. It does from a terminal
what the [Stone Age Console](./console.md) does in a browser:

- Manage tenant records: Things, Locations, Thing Types and operations,
  memberships, NATS users and roles, Nebula hosts.
- Publish and subscribe on NATS.
- Read and write JetStream KV.
- Pull a tenant's configuration into YAML files that you can review, diff and
  apply back from `git` (§5). The console cannot do this.

It is one Go binary with no dependencies. It talks to a **running** Control
Plane (`stone-age`): PocketBase for tenant data, and NATS/JetStream for
messaging and KV. It uses the same auth, collections and tenant boundaries as
the console, so it gives no extra access.

> ### `stone` vs `stone-age`
> | Binary | What it is |
> | :--- | :--- |
> | **`stone`** (this page) | The **client CLI** you run from a laptop or CI runner. It signs in to the Control Plane over HTTPS and talks to NATS. It never opens the database. |
> | **`stone-age`** | The **Control Plane** binary. You run `init` and `serve` on it in [Getting Started](./getting-started.md). It owns the database. |

---

## 1. Where it fits

The console and `stone` are two clients of the same Control Plane and Data
Plane. Both sign in as the same users, follow the same API rules, and work in
the same current Organization.

```mermaid
graph TB
    subgraph Clients["Two front doors"]
        UI["Stone Age Console<br/>(browser — humans)"]
        CLI["stone CLI<br/>(terminal, CI, GitOps)"]
    end

    subgraph Planes["The platform"]
        PB["PocketBase<br/>(Control Plane)<br/>identity • inventory • contracts"]
        NATS["NATS / JetStream<br/>(Data Plane)<br/>messages • KV • streams"]
    end

    UI -->|"REST + WebSocket"| PB
    UI -->|"WebSocket"| NATS
    CLI -->|"REST /api, /api/batch"| PB
    CLI -->|"reuses nats-cli contexts"| NATS

    PB -.->|"provisions per-membership<br/>NATS users"| NATS
```

- **Use the console** for dashboards, the digital twin, floor plans and daily
  administration.
- **Use `stone`** for repeatable work: seed a new org from a template, create
  Things in bulk, put credentials on a headless device, or keep a tenant's
  configuration in version control.

---

## 2. Install & build

Every release has binaries for linux, darwin and windows, on amd64 and arm64:

```sh
VERSION=0.12.0  # the stone version on the Versions page
curl -sSLO https://github.com/stone-age-io/stone-cli/releases/download/v${VERSION}/stone_${VERSION}_linux_amd64.tar.gz
tar xzf stone_${VERSION}_linux_amd64.tar.gz     # unpacks ./stone, LICENSE, README.md, SKILLS.md
./stone --version
```

To build it yourself: `stone` is its own Go module
(`github.com/stone-age-io/stone-cli`, Go 1.25+), versioned separately from the
platform.

```sh
go build -o stone        # local binary
go vet ./...
```

A source build shows `dev` for `--version`. A release build shows the tag.
There is nothing to install on the server.

---

## 3. Contexts, auth, and organizations

Every `stone` command runs in a **context**: a named set of server URL, auth
token, current Organization, optional NATS context and optional workspace path.
Use contexts to point the same binary at `local`, `staging` and `prod`.

State is in a `stone/` directory in the platform's config home:

- Linux: `$XDG_CONFIG_HOME/stone/` (default `~/.config/stone/`)
- macOS: `~/Library/Application Support/stone/`
- Windows: `%LOCALAPPDATA%\stone\`

Files that hold secrets have `0600` permissions. The nats-cli context files
that `stone` writes (§7) go where `nats` looks for them:
`$XDG_CONFIG_HOME/nats/context/` or `~/.config/nats/context/`, on **every**
platform.

```
stone/
├── config.yaml                       # active_context, default output format
├── contexts/
│   └── <name>/context.yaml           # url, auth, current_organization, nats_url, nats_context, workspace
└── creds/
    └── stone-<ctx>-<org>.creds       # per-org NATS creds (see §7); <org> is the org's sanitized name
```

### Context commands

```sh
stone context create local --url http://localhost:8090 \
    --nats-url nats://localhost:4222    # --nats-url is optional; enables per-org NATS sync (§7)
stone context ls                        # '*' marks the active one
stone context use staging               # switch the active context
stone context show                      # inspect the active context (secrets shown as "(set)")
stone context rm old-ctx
```

The first context you create becomes active. Pass `--use` on `create` to make a
later one active.

### Authentication

```sh
stone auth login        # prompts for email + password (password never echoes)
stone auth whoami       # who am I, on which context, in which org, and is my session live
stone auth logout       # clears the token from the context
```

`login` signs in to the `users` collection by default (change it with
`--collection`). It writes the token, email and user id into the context. It
prompts for credentials, so in a pipeline, sign in once on the runner or pass
`--email` and `--password` from a secret store.

::: warning An expired token would look like an empty organization
PocketBase serves a request with a token it does not accept **as a guest**.
Every list rule then returns nothing, with `200` and an empty array. So the CLI
checks the token's `exp` claim before it sends the token. If the token has
expired, the CLI stops and tells you to run `stone auth login`. A token whose
expiry it cannot parse is still sent. `auth whoami` shows a `session:` line
with the token's state.
:::

### Organizations

Almost every resource belongs to an Organization. Use `stone org switch` to
change organization:

```sh
stone org ls                       # CURRENT / CODE / NAME / ID, sorted by code; '*' marks the current one
stone org current                  # the current org: id, code, name
stone org switch warehouse-ops     # by code, name, or 15-char id; code is tried first
```

Organizations are addressed by their **code**, the platform's globally unique
identifier ([ADR 0002](./decisions/0002-organization-code-namespace.md)). A
name also works (`org switch "Warehouse Ops"`), but the code is tried first. An
organization *coded* `acme` wins over another one *named* `acme`.

`auth login`, `auth whoami` and `context show` print the current organization
as `acme (Acme Industries) [r03ixjyfs4fbkp2]`, or only the id when offline.
`context.yaml` stores the id, and `-o json`/`-o yaml` output shows the id.

`org switch` sets `users.current_organization` **on the server**, so the
console and the CLI agree, and caches it locally. After a switch, org-scoped
commands filter `ls` and add `organization` on `create`. If the context has
`--nats-url`, `switch` also writes your per-org NATS credentials (§7).

### Bootstrap order

Four things must be in place before real work. Check them in order and fix
only what is missing:

| Step | Check | Fix |
| :--- | :--- | :--- |
| 1. Context | `stone context ls` | `stone context create <name> --url <server> [--nats-url …]` |
| 2. Auth | `stone auth whoami` | `stone auth login` *(interactive, needs your credentials)* |
| 3. Organization | `stone org current` | `stone org ls`, then `stone org switch <code>` |
| 4. Workspace *(optional, for §5)* | `stone context show`, look at `workspace:` | `stone pull --workspace . --set-workspace` |

---

## 4. Managing entities

The CLI has typed CRUD over the same collections as the console. One table
defines all the commands, so every entity works the same way. Name aliases
also work: `stone thing`, `stone things`, `stone thing_type` and
`stone thing-types` all resolve.

| Entity | Org-scoped | Lookup key | Verbs | Role required |
| :--- | :---: | :--- | :--- | :--- |
| `thing` | yes | `code` | full | read: any · create/update: member+ · delete: owner/admin |
| `location` | yes | `code` | full | read: any · create/update: member+ · delete: owner/admin |
| `location-type` | yes | `code` | full | read: any · write: owner/admin |
| `thing-type` | yes | `code` | full | read: any · write: owner/admin |
| `thing-type-operation` | yes | `name` | full | read: any · write: owner/admin |
| `organization` | no | `code` (then `name`) | full | read: any member, or Platform Operator · create/update/delete: **Platform Operator only** |
| `membership` | no | none (id only) | full | read: your own, or owner/admin of the org · write: owner/admin |
| `invite` | yes | `email` | full | owner/admin (Platform Operator can create) |
| `nats-user` | yes | `nats_username` | full | owner/admin, **including reads** (plus your own one row) |
| `nats-role` | yes | `name` | full | owner/admin, including reads |
| `nats-import` | yes | `name` | full | owner/admin, including reads |
| `nats-export` | yes | `name` | full | owner/admin, including reads |
| `nebula-network` | yes | `name` | full | owner/admin, including reads |
| `nebula-host` | yes | `hostname` | full | owner/admin, including reads |
| `activity` | yes | none (id only) | `ls / get` | read: any · **no writes** |
| `nats-account` | yes | `name` | `ls / get / update / edit` | read: any · **all writes: Platform Operator** · signing keys: owner/admin through a route |
| `nebula-ca` | yes | `name` | `ls / get / update / edit` | read: any · **record writes: Platform Operator** · rotation: owner/admin with `stone nebula ca-rotate` |

"Full" verbs are `ls / get / create / update / delete / edit`. *Any* means any
role in the current organization, `dashboard` included. *member+* means
`member`, `admin` or `owner`.

**`activity`** is the tenant's feed of who changed what. It is read-only
**everywhere**: all three write rules are nil, so nobody can forge or change an
entry through the API. It lists newest first. Use
`--filter 'resource_id="<id>"'` to see who changed one device. `pull` and
`apply` skip it. See [Authorization §5](./authorization.md#5-two-histories-the-audit-log-and-the-activity-feed).

**`nats-account` and `nebula-ca`** are created when you create an
Organization, so you cannot create or delete them by hand. `update` and `edit`
exist for Platform Operators. For every tenant role they return 404.

- Owners and admins manage signing keys with
  `stone nats account-keys add-signing | remove-signing <public-key> | rotate`,
  which calls `POST /api/org/nats-account/keys`
  ([Authorization §4.1](./authorization.md#41-account-signing-keys)).
- Owners and admins roll the Nebula CA with `stone nebula ca-rotate` (below).

Before you script against the CLI, know these three rules:

- On `nats-*` and `nebula-*` entities, a role below admin gets an **empty
  `ls`, not a filtered one**. The one exception is the `nats-user` row linked
  to your own membership.
- On `thing`, only owners and admins can set `nats_user` and `nebula_host`. A
  member can create and edit a Thing, but `--nats-user` and `--nebula-host`
  are rejected.
- On your **own** `membership`, the only write is to the NATS identity link,
  and you can only **keep or clear** it. `nats_users` serves the credential of
  the identity your membership names, so choosing one is owner/admin, like
  changing a role. `--role`, `--user` and `--invited-by` are rejected.

**Invitations:** `stone invite create --email …` issues one.
`stone invite accept <token>` redeems it, with the `?token=` value from the
invitation link, not the invite record's id. Redeeming sets
`current_organization` only if it was blank, so then run `stone org switch`.
The `next:` hint it prints has the organization's code. The switch also writes
the nats-cli context for the new membership.

See [Authorization & Roles](./authorization.md) for the full matrix and the
reason for each limit.

```sh
stone location create --name "HQ" --code hq
stone thing-type create --name "Temp Sensor" --code temp-sensor \
    --subject-prefix "sensor.{thing}"
stone thing-type-operation create --name heartbeat --capability publish \
    --subject-suffix heartbeat
stone thing get warehouse-hvac --fields code,name,location   # read back by natural key
stone thing ls --fields code,name                            # requested fields become the columns
stone nebula-host edit edge-west                             # opens $EDITOR as YAML, sends only the fields you changed
```

**The server generates a code if you leave it out**
([ADR 0003](./decisions/0003-human-friendly-codes-and-default-subject.md)).

- `stone thing create`, `stone location create` or `stone thing provision`
  without `--code` gets a code such as `CA-9KD-4PX` under the type's prefix.
  `provision` prints it. For the others, use `-o yaml` or a later `get`.
- For a device that signs in, use `stone thing provision`, or pass `--code` to
  `thing create`. Typed `thing create` also needs `--email`, and the email
  contains the code, which you do not know before the server generates it.
- A code you pass is stored as you typed it.
- Set a type's prefix with `--prefix` on `thing-type` or `location-type` (1 to 4
  capitals). A Thing Type and a Location Type in one organization cannot share a
  prefix.
- A code, and a Thing's or Location's `--type`, are frozen once set. An update
  that changes the type returns 404. To fix a wrong type, delete and recreate.

### Provisioning a real device

`thing create` writes only an inventory record. For a device that must connect,
use `thing provision`. It calls [`POST /api/org/things`](./api-reference.md),
which creates the Thing, its NATS identity and its Nebula host in **one
server-side transaction**. A failure leaves no orphaned credential or overlay
IP.

```sh
stone thing provision --code gw-01 --name "Gateway 01" \
    --type gateway --location hq \
    --nats-mode auto \
    --nebula-mode auto --nebula-network main --nebula-ip 10.128.0.42
```

`--nats-mode` and `--nebula-mode` each take one of:

- `none` (default).
- `auto`: mint one. NATS uses the org's default role unless `--nats-role` names
  another. Nebula needs `--nebula-network` and `--nebula-ip`, because the route
  does not allocate an address.
- `link`: attach an existing one with `--nats-user` or `--nebula-host`.

`--name` is required. `--code` is optional. Only owners and admins can attach
identities. A member can provision with both modes at `none`. The organization
comes from your active context.

**Device-held keys** (stone 0.11.0, platform v0.21.0). Add `--nats-device-key`
and `--nebula-device-key` to an `auto` mode, and the device makes its own key
pairs. The platform holds only the public halves, and issues no credential until
the device's Agent enrolls its keys. For a device with no Agent, pass the public
keys at provision (`--nats-public-key` from `nk -gen user -pubout`,
`--nebula-public-key @host.pub` from `nebula-cert keygen`), or later:

```sh
stone nats-user update device-01 --public-key UDXU4R…
stone nebula-host update gw-01 --public-key @host.pub
```

The choice is made at provision and cannot be changed. A key can be set only
while the identity has none. See
[NATS Security §4](./concepts/nats-security.md#device-held-keys).

### Lookup by id or natural key

`get`, `update`, `delete` and `edit` take a 15-char PocketBase id or the
entity's **natural key** from the table above (`code`, `name`, `hostname` and
so on). Relation flags take the same values (from stone 0.9.0):
`--location hq` and `--location <id>` both work.

- Key lookups are scoped to the current Organization and match exactly, except
  that a **code ignores case**: `stone thing get ca-9kd-4px` finds
  `CA-9KD-4PX`. Code uniqueness also ignores case, so this cannot match two
  records.
- If several records match, the command fails and lists their ids. If none
  match, it fails with `no <entity> with <key> "<arg>"`.
- An entity with a second key (`organization`: `code`, then `name`) tries each
  key in order.
- `membership` takes an id only. So do the relation flags that point at a user:
  `--owner`, `--user` and `--invited-by`.

### Field types

| Type | Flag form | Notes |
| :--- | :--- | :--- |
| string / int / bool | `--name foo` · `--validity-years 5` · `--active=false` | to set a bool false, use `=` (see below) |
| select | `--capability publish` | checked against a whitelist |
| multiselect | comma-separated, checked against a whitelist | supported, but no entity uses one yet |
| relation | `--type temp-sensor` · `--type abc123def456ghi` | the target's natural key or its id, looked up as above |
| relation list | `--operations heartbeat,reboot` | comma-separated or repeated flag; each value is looked up |
| JSON | `--metadata '{"k":"v"}'` · `--metadata @file.json` · `--metadata -` | inline, file or stdin |

### Auth collections

`thing`, `nats-user` and `nebula-host` are PocketBase **auth collections**. When
you set a non-empty `password`, the CLI also sets `passwordConfirm` and
`emailVisibility` for you, on typed CRUD, `apply` and `edit`.

For headless provisioning, let the CLI create the password:

```sh
stone thing create --email reader-01@acme.thing.local --code reader-01 \
    --type card-reader --random-password -o json 2> reader-01.pw
```

Typed CRUD writes the collection directly, so you supply the email. Use the
same `<thing code>@<organization code>.thing.local` form that
[`POST /api/org/things`](./api-reference.md) mints, so the Agent's
`platform.identity` follows one rule.

`--random-password` makes a 32-character URL-safe password and prints it
**once to stderr**, so stdout stays clean for `jq`. Use exactly one of
`--password` or `--random-password` on `create`.

### Decommissioning from the CLI

A `thing` has an `active` flag, so a script can take a device out of service.
A site gateway is an ordinary Thing, so this also applies to it.

```sh
stone thing update reader-01 --active=false        # decommission
stone thing update reader-01 --active=true         # return to service
```

::: warning `--active=false` is not a status label
It is the same as the console's Deactivate button. It ends the device's
sessions, suspends its NATS identity and blocklists its Nebula certificate.
Reactivating issues a *new* `.creds` file, so give the device the new file.
Owner/Admin only.
[Authorization §4.2](./authorization.md#42-taking-a-device-out-of-service) has
the four effects and when each one applies.

This matters most for `apply`. `pull` writes `active` into the workspace YAML,
so a file with `active: false` decommissions real hardware on the next `apply`.
:::

Use the `=` in `--active=false`. A bare boolean flag means *true*, so
`--active false` treats `false` as a second argument and fails with
`accepts 1 arg(s), received 2`.

### Nebula operations that are not record writes

CA rotation is not a record edit, so it is under `stone nebula`:

```sh
stone nebula ca-rotate prepare      # mint the incoming CA, publish it as additional trust
stone nebula ca-rotate commit       # switch issuance to it, re-sign every active host
stone nebula ca-rotate finish       # drop the outgoing CA
```

**`ca-rotate` has three steps, and you must wait between them.**
[Authorization §4.3](./authorization.md#43-rolling-a-nebula-ca) explains why.

- `prepare` changes no issuance and is fully reversible. Wait here until every
  host has fetched.
- You can run `commit` again. It re-signs only the hosts still on the old CA,
  which is how you finish a partial sweep.
- `finish` is refused while any active host still has a certificate from the
  old CA. The error names the host.

Owner/Admin of the active organization only. It takes no id: the CA comes from
your active org. You cannot renew a CA, only rotate it, so start months before
it expires. `stone nebula-ca ls` shows the date. See
[Authorization §4.3](./authorization.md#43-rolling-a-nebula-ca).

**A network's `cidr_range` is fixed once the network exists.** Host
certificates carry it, and changing it would re-sign none of them, so every host
would stop reaching its peers. The platform refuses the update. Create a new
network instead.

---

## 5. Declarative workspaces (pull / apply)

Keep a tenant's whole configuration as YAML files in a `git` repo:

```sh
mkdir my-workspace && cd my-workspace && git init
stone pull --workspace . --set-workspace   # writes <collection>/<key>.yaml, one file per record
# …edit files, commit for review…
stone apply --dry-run             # shows what apply would create and update
stone apply                       # sends the changes back to the server
```

**`pull`** writes one YAML file per record into `<workspace>/<collection>/`.

- Each file is named by the record's natural key (then `name`, then id, with a
  suffix if two collide). Organization files are named by code (`acme.yaml`).
- Org-scoped collections are filtered to the current Organization, and so are
  your Memberships.
- It writes `organizations/`, `nats_accounts/` and `nebula_ca/` only for a
  Platform Operator, because only a Platform Operator can update them. For
  anyone else it skips them and says so.
- It removes server-managed fields (`collectionId`, `collectionName`,
  `created`, `expand`), and the credential and server-generated fields below.
  It prints what it left out, per collection.
- It keeps each record's `updated` time. `apply` uses it to find a file that
  is older than the record on the server.
- It skips the `activity` feed.

**`apply`** reads the workspace (or only the paths you pass), groups records
into batches of up to 50, and sends each batch to PocketBase's `/api/batch`
endpoint. It compares each record that has an `id` with the server, and
PATCHes only the fields that are different. It does not send a record that has
no differences. It POSTs records without an `id`. After each create or update,
it writes the new `id` and `updated` **back into the file**, and this removes
the comments in that file.

- **A file older than the record is refused.** If someone changed the record
  after your pull, the server's `updated` is different from the file's. Then
  `apply` lists those files and sends **nothing**. Commit your edits, `pull`
  again, put your changes back from `git diff`, and apply again. `--force`
  sends the files anyway and overwrites the change on the server. A file with
  no `updated` (written by hand, or pulled by `stone` before 0.8.0) is not
  checked. Pull again to start the check.
- **One organization at a time.** `pull` never clears a workspace, so a second
  organization pulled into the same directory puts its files next to the
  first. If a file belongs to an organization that is not the current one,
  `apply` stops before it sends anything. Use one workspace per organization,
  or pass `--any-org`.
- **Not all-or-nothing.** The platform leaves batch requests off by default,
  and when a batch is refused or one of its records fails, `apply` re-sends that
  batch one record at a time so it can name the record that failed. Records
  before a failure stay applied. Fix the file and run `apply` again.
- **Safe to repeat.** A second run finds no differences and sends nothing.
  File names do not matter: `apply` uses only the `id` field in each file.
  A file in a directory that is not a collection (`thing/` instead of
  `things/`) gets a `skip` line.
- **A workspace pulled by an older `stone` can hold records you cannot
  update:** `organizations/`, `nats_accounts/`, `nebula_ca/` and Memberships in
  other organizations. `apply` fails on each of them. Delete those files, or
  pass only the paths you manage, for example `stone apply things/ locations/`.
- **No deletes.** `apply` leaves alone any server record that has no local file.
  To delete, use `stone <type> delete <id|key>` or the console. A
  whole-workspace `apply` lists those records as `no file` lines, for each
  collection that has a directory in the workspace, so one created in the
  console since your pull is not invisible (from stone 0.10.0).
- **Drift checks.** `stone apply --dry-run --exit-code` exits 2 when apply would
  create or update something, 0 when the workspace and the server agree, and 1
  on an error. Run it on a schedule to catch an edit made in the console.
  `no file` records do not count.
- **Reviewable.** In `git` you get diff, history, blame and PR review of your
  configuration.

### Credentials are not pulled

`pull` never writes fields that PocketBase marks hidden, such as every
`private_key` and `seed`. It also leaves out these fields, which the API does
return to an owner or admin:

| Field | Why it is a credential |
| :--- | :--- |
| `nats_users.creds_file` | It **is** the credential: a user JWT and an nkey seed. |
| `nebula_hosts.config_yaml` | It has the host's Nebula private key inline. |
| `invites.token` | A bearer token that redeems into a membership. |

`pull` also leaves out the server-generated certificates, JWTs and action
triggers next to them. `apply` sends each key that is different from the
server, so a pulled certificate would overwrite the one the server rotated to
since.

**`pull` leaves out a Nebula host's `revoked_certificates` and
`retired_certificates`.** The platform builds every peer's blocklist from these
lists. If `apply` sent back an old copy, the next config regeneration would
remove each revocation made since the pull. `stone` before 0.7.1 pulled them:
delete both keys from each file under `nebula_hosts/` in an older workspace.

**`pull` writes `device_key` and leaves out `public_key`**, on both `nats_users`
and `nebula_hosts` (from stone 0.11.0). A public key is device state: a device
enrolls its own key wherever the workspace is applied.

**`pull` leaves out every `active` flag the platform acts on**: `things`,
`nats_users`, `nebula_hosts`, `nats_accounts` and `organizations`. The platform
acts on a change of the flag, so a pulled `active: true` applied after an admin
set `false` would undo the decision. A decommissioned device would come back
with working credentials. Before stone 0.7.0, `pull` wrote `things.active`,
`nebula_hosts.active` and `organizations.active`: delete the `active:` line
from those files in an older workspace.

The filter is on `pull` only. A `revoke: true` or `active: false` you write by
hand still applies.

::: danger Workspaces pulled with `stone` before 0.4.0 contain credentials
Those values are in the workspace and in its git history. Treat them as
disclosed, and replace them:

1. `stone nats-user update <username> --revoke`. This issues a new key pair and
   revokes the old one. Do not use `--regenerate`, which signs the **same** seed
   again and leaves the leaked file working.
2. `stone nebula-host update <hostname> --renew`, which mints a new key pair.
3. Delete every invitation whose token was written out.
:::

### What this is, and what it is not

`stone apply` is a **one-way, additive upsert**. It pushes the workspace to the
server and stops. It is not a reconciliation loop like Flux or Argo CD.

| | `stone pull` / `apply` | A full GitOps reconciler |
| :--- | :--- | :--- |
| Creates and updates from files | ✅ | ✅ |
| All-or-nothing apply | ❌ Records before a failure stay applied | Varies |
| Deletes server records missing from git | ❌ **Never** | ✅ (pruning) |
| Detects drift when someone edits in the console | ⚠️ When you run `apply --dry-run --exit-code`, and at `apply`, which refuses a file older than its record | ✅ Continuously |
| Runs unattended in a control loop | ❌ You run it | ✅ |

- **The workspace is not the source of truth.** It is a snapshot from the last
  `pull`, plus your edits. A Thing someone created in the console this morning
  is not in your workspace until you pull again.
- **A refused file means someone changed the record.** If people share a
  workspace, `pull` before `apply`, as you would `git pull` before a push.
  `--force` makes the last `apply` win.
- **Deletion is manual.** Removing a file does nothing. This protects you from a
  stray `rm -rf`, but git history does not show the current server state.

Do not build a process that expects convergence. For the same reason,
[Operations §3](./operations.md#3-backups) treats a workspace as an audit and
rebuild aid, **not** a backup.

### Templates: one folder for many organizations

A workspace belongs to one organization, because its files carry that
organization's ids. A **template** is a folder that applies to whichever
organization is current, so the same folder sets up each one. Each
application ships one as its `contract/` folder
([Building an Application §9](./building-an-app.md#9-ship-a-contract-folder)).

```bash
stone org switch acme
stone apply --template contract/ --dry-run
stone apply --template contract/
```

A template file is a pulled file without what ties it to one organization:

```yaml
# contract/thing_types/access-door.yaml
code: access-door
name: Access-Controlled Door
subject_prefix: acc.{location}
operations:          # operation names, not ids
  - publish_door_decision
  - subscribe_door_grant
```

- **It holds definitions only:** `thing_types/`, `thing_type_operations/`,
  `nats_roles/` and `location_types/`. A file anywhere else is an error.
- **Records are found by key:** a Thing Type or Location Type by `code`
  (ignoring case), an operation or a role by `name`. A file with `id`,
  `updated`, `created` or `organization` is refused.
- **Relations hold keys**, resolved in the current organization. Operations are
  created before the Thing Type that names them.
- **Existing records get the fields that differ, missing ones are created.**
  There is no stale check: the template is the contract, and applying a newer
  one moves the organization to it.
- **Nothing is written back and nothing is deleted.**
- `--dry-run --exit-code` exits 2 when an organization differs from the
  template, so the same drift check works.

From stone 0.12.0.

---

## 6. NATS, JetStream, and KV

`stone` uses your existing `nats` CLI contexts (through orbit.go's
`natscontext`), so JetStream domains work and the two tools stay in step.

```sh
# Messaging
stone nats pub demo.hello 'world'
stone nats pub demo.hello @msg.json --js      # JetStream publish, prints the ack
stone nats sub 'demo.>'
stone nats req demo.echo 'ping' --timeout 5s

# KV data plane. Twin keys are <kind>.<code>.<prop>.
stone kv get twin thing.S01.temp                     # reported state, written by the device
stone kv put twin_desired thing.S01.setpoint '21'    # desired state
stone kv put twin_desired thing.S01.config @./config.json
stone kv del twin_desired thing.S01.setpoint
stone kv ls twin
stone kv watch twin

# KV bucket lifecycle
stone kv bucket ls
stone kv bucket create recipes --history 5 --ttl 720h
stone kv bucket info recipes
stone kv bucket delete recipes

# JetStream streams
stone js stream ls
stone js stream create CAMERA --subject 'camera.>' --max-age 24h --storage file
stone js stream create CAMERA --config stream.yaml     # advanced config; keys as the server names them
stone js stream info CAMERA
stone js stream view CAMERA --last 20                  # newest first (alias: tail)
stone js stream purge CAMERA
stone js stream delete CAMERA
```

Do not write the `twin` bucket by hand. The device is its one writer
([Architecture §4.1](./architecture.md#41-two-buckets-one-writer-each)).

The console's digital twin and KV Dashboard use the same buckets and streams,
and so do the rule engine and stream processors. See
[Platform Entities](./console.md#4-jetstream-streams-and-kv-buckets)
and [Automation](./automation.md).

> **`stone` does not manage JetStream consumers.** Use the `nats` CLI for that.

### JetStream config in a workspace

From stone 0.10.0, `stone js pull` and `stone js apply` do for streams and KV
buckets what `pull` and `apply` (§5) do for records, in the same workspace:

```sh
stone js pull                          # → jetstream/streams/<stream>.yaml, jetstream/kv/<bucket>.yaml
stone js apply --dry-run               # which files would create or update, and which fields
stone js apply
stone js pull --domain GW-KC-01        # one gateway's leaf → jetstream/domains/GW-KC-01/
stone js apply --domain GW-KC-01
```

- **Configuration only.** No messages and no consumers. To back up a stream's
  data, use the `nats` CLI with the context `stone` writes:
  `nats --context stone-<ctx>-<org> stream backup <stream> <dir>`, and keep the
  backup out of the workspace.
- **A file is the whole config.** A field you delete goes back to the server's
  default on the next apply. Values the server fills in are left out of pulled
  files, and durations read `24h`.
- **A KV bucket is a bucket file** (`history`, `ttl`, …), not its `KV_`
  stream. Object stores are skipped.
- **Stale files are refused.** Each file keeps a `config_hash`. If the stream
  changed on the server, or was deleted, since the pull, `js apply` sends
  nothing. `--force` overrides.
- **No deletes.** As with records, a stream with no file is left alone and
  listed as `no file`.
- **`--domain <code>`** reaches a gateway's leaf through the hub. The gateway's
  NATS role must allow it, and a role change reaches a connected gateway only
  after it reconnects
  ([Leaf Nodes §6.2](./leaf-nodes.md#62-reaching-a-gateways-jetstream-from-the-hub)).

---

## 7. Per-organization NATS credentials

In Stone-Age.io, NATS credentials are **per membership**. A user has a separate
NATS identity in each Organization, stored as the membership's
[Linked NATS Identity](./platform-ui-entities.md#1-organizations--memberships).
`stone` keeps your local `nats` CLI on the credential for your current org.

When the context has `nats_url`, `stone org switch <org>` and
`stone nats sync-context` do this:

1. Find your `memberships` record for that org.
2. Read the linked `nats_users` record's `creds_file`.
3. Write `stone/creds/stone-<ctx>-<org>.creds` in the config home (§3) and a
   matching `stone-<ctx>-<org>.json` in nats-cli's context directory. `<org>`
   is the organization's **name**, sanitized, not its code.
4. Set the context's `nats_context` to the new context.

```sh
stone org switch warehouse-ops --set-nats-default     # also makes it the nats-cli default
stone nats sync-context                               # write the files again after a key rotation
```

Run `sync-context` after a credential rotation. To re-issue *another*
identity's credential, run `stone nats-user update <id> --regenerate`. This
needs owner or admin. Other roles get a 404. To rotate **your own** credential,
use the dedicated route. Every role can use it, and it takes no id:

```sh
stone nats creds rotate      # rotate my own credential (any role, incl. dashboard)
stone nats sync-context      # then write the local creds file again
```

`creds rotate` returns `403` while your identity is suspended. A rotation mints
a credential issued after the revocation cutoff, so it would end the
suspension.

Three operations change a NATS identity's credential. Only one takes it out of
service:

| Operation | What it does | Use it when |
| :--- | :--- | :--- |
| `--regenerate` | Signs a new JWT for the **same** key. Copies of the old file keep working. | A JWT field changed, or a device lost its file. |
| `--revoke` | Makes a new key pair and puts the **old** public key on the account's revocation list. Every copy of the old file is rejected permanently: at the hub at once, and on a site's leaf node at its next refresh ([Leaf Nodes §8.1](./leaf-nodes.md#81-what-reaches-a-site-and-when)). The record gets a working replacement and **stays active**. | Credentials leaked. Give the new file to the real holder. |
| `active` to `false` | Revokes the key and issues **nothing**. Setting it back to `true` issues a new credential. The old one stays revoked. | The identity must stop connecting. |

```sh
stone nats-user update device-01 --revoke        # leaked: kill every copy, issue a replacement
stone thing update reader-01 --active=false      # a device: suspend through the Thing (§4)
stone nats-user update svc-01 --active=false     # an identity with no Thing (owner/admin)
```

::: note Suspend a device through its Thing
For a device, suspend the **Thing**. Its `active` flag suspends the linked NATS
identity, its sessions and its Nebula host. While the Thing is deactivated, the
server refuses a change to `active` on its NATS user. Use
`stone nats-user update <username> --active=false` only for an identity with no
Thing. `pull` leaves out `active` on
`things` and `nats_users`, so a pulled workspace cannot change it.
:::

See [Authorization §4](./authorization.md#4-the-row-scoped-credential-model).

`org switch` always succeeds, even if the credential step cannot run. It then
prints `nats-sync: skipped — <reason>`, which is information, not an error.
`stone nats sync-context` has no other job, so for it the same reasons are an
**error**: `nothing to sync — <reason>`, with a non-zero exit.

| Reason | Meaning |
| :--- | :--- |
| `no NATS URL on this stone context` | The context has no `nats_url`. Create the context again or pass `--nats-url` to the next `org switch`. |
| `no membership found for this user+org` | You are a Platform Operator in an org where you are not a member. NATS credentials are per membership. |
| `membership has no linked nats_user` | Your membership in this org has no NATS identity. An owner or admin must link one. |
| `(--no-nats)` | You passed the flag. |

One case is a failure, not a skip: a membership linked to an identity whose key
its device holds (`device_key`) prints `nats-sync: FAILED — this NATS identity's
key is held by its device`. The platform has no seed or creds file to hand out.
Link an identity whose key the platform holds.

Add `--verbose` to either command to print the user, membership and NATS user
ids on stderr. See [Connectivity](./connectivity.md) for how these credentials
fit the NATS account model.

---

## 8. Output & scripting

Every command takes these flags:

- **`--output` / `-o`**: `table` (for people, can change between versions),
  `json` or `yaml`. Use `-o json` when a script reads the output.
- **`--context <name>`**: use another context for one command, for example in
  CI that touches several environments.
- **`--nats-context <name>`**: the nats-cli context to connect with, instead of
  the stone context's `nats_context`.
- **`--debug`**: log HTTP requests and responses to stderr (bodies up to 4 KB).

Every entity `ls` also takes:

- **`--filter <expr>`**: a PocketBase filter, combined with the organization
  filter by AND.
- **`--sort <expr>`**: a PocketBase sort, for example `-updated`.
- **`--fields a,b,c`**: server-side projection. The table columns follow it.
- **`--limit <n>`**: fetch one page, not every match. It goes into the query,
  so use it to get the newest ten of 40,000 Things.

Structured output goes to **stdout**. Messages and generated passwords go to
**stderr**. So `stone thing create … --random-password -o json | jq .id` works.

### Relations print as codes for a human and ids for a script

In `table` output and `get`'s key/value output, relation columns such as TYPE
and LOCATION show the target's natural key, the same key that `get`, `update`
and `delete` accept. PocketBase returns the related record in the same query,
so this costs no extra request.

**`json` and `yaml` show relation ids.** They are the scripting interface: a
pipeline that reads `type` gets an id. You can pass the code from a table to a
relation flag, so you seldom need to find an id. `edit` and `pull` also use raw ids. `edit` PATCHes what you save straight
back, and `apply` relies on the ids in the workspace.

An **unset** relation shows an empty cell, and so does one you cannot read.
PocketBase hides another user's email, so on `membership ls` an owner sees a
colleague's *name* in the USER column.

---

## 9. Driving `stone` with Claude

Two files in the stone-cli repo describe the CLI for AI assistants:

| File | Audience | What it is |
| :--- | :--- | :--- |
| **`.claude/skills/stone/SKILL.md`** | Claude Code | An [Agent Skill](https://docs.claude.com/en/docs/claude-code/skills). Claude Code loads it automatically when a request matches, such as "create a thing", "switch org", "pull the workspace" or any `stone` command. You can install it into any project or your user config. |
| **`SKILLS.md`** | People and other tools | The same content without Claude-specific instructions: bootstrap order, entity table, NATS sync and limits. |

The skill tells the assistant to:

- Check context, auth, org and workspace in order (§3), and fix only what is
  missing.
- Use `-o json` for any output it reads, never the table.
- Pass natural keys that it has seen, or look up ids, and never guess them.
- Expect `apply` to be idempotent and to **never delete**.
- Treat `nats-sync: skipped — …` as information.

> **The assistant cannot sign in for you.** `stone auth login` prompts for credentials, and the skill tells the assistant to ask you to sign in yourself. The assistant then has the same per-organization scope and API rules as you.

When command shapes change, update both files.

---

## 10. Limitations

- `apply` never deletes server records that have no local file.
- No JetStream **consumer** management. Use the `nats` CLI.
- `nats-account` and `nebula-ca` are read-only for every tenant role. Only a
  Platform Operator can update them. Owners and admins manage signing keys with
  `stone nats account-keys`, not `stone nats-account update`.
- `auth login` prompts unless you pass both `--email` and `--password`.
- There is no CLI upload for file fields: a Thing's and a Location's `photo`, a
  Location's `floorplan`, an Organization's `logo` and a user's `avatar`. Set
  them in the console. All are **protected**, so reading one needs a file token,
  not the auth token ([Platform Entities](./console.md#7-photos-and-file-fields)).
- **The CLI's flags are written by hand**, so a `stone` release can lag a
  platform release. Its tests check every flag against a copy of the
  platform's schema that `scripts/vendor-schema.sh` takes from a live server,
  and fail on a platform field the CLI neither exposes nor explains. Each
  release's notes name the platform release it was checked against. If a field
  is in the console but has no flag, set it with `stone <type> edit`, with
  `apply`, or in the console. This lag is part of the stability contract
  ([Stability §2](./stability.md#configuration-and-commands)).

---

## 11. Where to Go Next

- Start a server for `stone`: [Getting Started](./getting-started.md)
- The records the CLI manages: [Platform Entities](./platform-ui-entities.md)
- What your role can change: [Authorization & Roles](./authorization.md)
- The HTTP routes behind non-record commands: [API Reference](./api-reference.md)
- Thing Types and operations: [Thing Types](./thing-types.md)
- How per-membership NATS credentials fit the account model: [Connectivity](./connectivity.md)
- Declarative configuration at a site: [Leaf Nodes](./leaf-nodes.md)
- Server config keys and `STONE_AGE_*` variables: [Configuration Reference](./configuration.md)
