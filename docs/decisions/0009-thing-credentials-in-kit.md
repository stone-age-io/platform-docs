---
path: platform/decisions/0009-thing-credentials-in-kit
nav_order: 90
---
# ADR 0009: Applications Keep Their Own Thing Credentials, Through the Kit

**Status:** Proposed
**Date:** 2026-11-21, revised 2026-11-22 after review

> This ADR is ecosystem-scoped, like [ADR 0008](./0008-application-namespace.md). It decides how our own applications (the helpdesk, access control, kiosk and the services) get their NATS credential from the platform. It moves creds-keeper's package into [`stone-age-io/kit`](https://github.com/stone-age-io/kit), lets an application run it inside its own process, and adds device-held NATS keys to it.
>
> It supersedes part of [ADR 0007](../vendor/services/docs/decisions/0007-creds-keeper.md) and part of ADR 0008 rule 4. [What this changes in other documents](#what-this-changes-in-other-documents) lists each part. The credential lifecycle that ADR 0007 decided does not change.

---

## Context

ADR 0007 gave every account service a companion program, creds-keeper, that
signs in as the service's Thing and keeps its creds file current. ADR 0008
rule 4 extended that to every application process. Both rejected a platform
client inside each program, for two reasons:

- **It would cover only our own programs.** Telegraf, rule-router and eKuiper
  cannot link Go code, and they are half of what an account runs.
- **Every program would gain an HTTP client, a sync loop and credential
  swapping,** and the platform's credential lifecycle would have several
  implementations.

ADR 0007 §10 also kept the Agent's implementation separate from
creds-keeper's, because sharing a module meant a new repository for a few
hundred lines.

Three things changed after those decisions:

1. **The kit exists.** `stone-age-io/kit` was tagged `v0.1.0` on 2026-11-21.
   It is the shared repository that §10 did not want to create, and its rule
   for admission is "copied in three places or more, and it implements a
   contract". Every application (helpdesk, accessd, the access controllers,
   the kiosk node and controller, the watchdog) would run the credential
   lifecycle, so it qualifies.
2. **creds-keeper's package is already a library.** `credskeeper` exports
   `ConfigFromEnv`, `New`, `Run`, `RegisterChecks` and `NewMetrics`.
   Running it inside an application is a goroutine and a dozen lines in `main`,
   not a new HTTP client and sync loop in each program. The second objection
   above no longer describes the cost.
3. **The platform has device-held keys** (platform feature 15c). A NATS
   identity made with `device_key` has no `creds_file` on the platform: the
   platform signs a JWT for a public key the device enrolled, and the device
   builds its creds from its own seed. creds-keeper cannot serve such a Thing
   today. An operator can already create one.

The first objection still holds: third-party programs cannot link the kit.
The creds-keeper binary stays for them.

---

## Decision

### 1. creds-keeper's package moves to the kit

`github.com/stone-age-io/services/credskeeper` moves, with its tests, to
`github.com/stone-age-io/kit/credskeeper`, in the kit's root module.

- **The name stays.** It says what the package does.
- **It stays out of `pbx`.** It is `net/http` against the platform's routes,
  not the PocketBase SDK, and the watchdog must not get PocketBase in its
  `go.mod`.
- **No new dependency.** Today it needs `kit/health` and Prometheus. The
  device-key code (§4) adds `nkeys` and `nats-io/jwt`. The kit's root module
  already requires all four.
- **The contract it implements is the platform's credential routes,** and the
  files it writes. The kit admits a package when "it implements a contract they
  must agree on", so the contract gets a test: a platform e2e test runs the
  kit's keeper against the real routes, in both key modes, as `healthtest` does
  for `/api/ready`. A route change then breaks a test in the platform, not an
  application in the field.
- **No change to the lifecycle.** Sign in once, renew the session with
  `auth-refresh`, probe `updated`, download only on a change. The session file,
  the creds file, the readiness checks and the metrics are the ones ADR 0007
  describes, as implemented.

### 2. Our applications run it in their own process

An application whose own configuration names a platform URL runs the keeper
as a goroutine:

```go
if cfg.Platform.URL != "" {
    k, err := credskeeper.New(credskeeper.Config{
        URL:         cfg.Platform.URL,
        Identity:    cfg.Platform.Identity,
        Password:    cfg.Platform.Password, // only for the first start
        CredsFile:   cfg.NATS.CredsFile,    // the path the app connects with
        SessionFile: filepath.Join(cfg.Platform.Dir, "platform-session.json"),
    }, log, credskeeper.NewMetrics(prometheus.DefaultRegisterer))
    if err != nil { return err }
    k.RegisterChecks(&reg)
    go k.Run(ctx)
    if err := k.WaitForCreds(ctx); err != nil { return err }
}
nc, err := natsx.Connect(natsx.Options{Creds: cfg.NATS.CredsFile, ...}) // as today
```

- **The creds file stays the interface.** The keeper writes it, and
  `natsx.Connect` reads it with `UserCredentials(path)` on every connect, as
  ADR 0007 §4 describes. Nothing hands credentials over in memory.
- **The application fills `Config` from its own configuration.** The helpdesk,
  access control and the kiosk read YAML with prefixed environment overrides,
  not bare environment variables. `CredsFile` is the path the application
  already connects with, so there is one source for it. If the keeper wrote one
  path and the application read another, it would connect with a stale file
  while every check stayed green. `ConfigFromEnv` stays, as the binary's
  adapter (§3). `New` now returns an error. It does the checks that only
  `ConfigFromEnv` does today: https only unless insecure is allowed, and a
  session file that is not the creds file. It also fills the same defaults,
  a 5m sync interval and mode `0600`. An application leaves the mode at `0600`,
  because no second user shares the file.
- **Without a platform URL, nothing starts.** The application connects with
  whatever creds file it was given. That is the development path, and it is
  the same connect call.
- **The application waits for its first credential.** `natsx.Connect` fails at
  once when the creds file does not exist, even with `RetryOnFailedConnect`,
  because nats.go reads the file before it dials. Readiness reports a missing
  file, but in one process nothing waits on readiness. So the keeper gains
  `WaitForCreds(ctx)`, which returns when the creds file exists and is
  readable, or when `ctx` ends. It takes the place of the sidecar's
  `service_healthy` gate. `credentials` still fails until the file exists,
  and `platform` still warns and never fails.
- **The files need a writable directory, and it is not `pb_data/`.** The
  session file must persist, so that the password can leave the configuration
  after the first run. The creds file must persist, so that a restart during a
  platform outage still connects. PocketBase's backups, local and S3, archive
  all of `pb_data/`. A credential directory inside it would put the session
  token, the creds file and a device-held seed in every backup. A restored
  backup would also give a second host the same identity. A PocketBase
  application keeps them in a sibling directory, such as `pb_creds/`, on the
  same volume. The watchdog keeps them on the volume it already mounts for its
  creds file.

### 3. The creds-keeper binary stays, for programs that are not ours

`services/cmd/creds-keeper` imports the kit package and keeps its current
configuration, image and release. It is the adapter for Telegraf, rule-router,
eKuiper and anything else that reads a creds file. Our own applications do not
run it.

### 4. Device-held NATS keys

The keeper serves a NATS identity made with `device_key`. The mode comes from
the identity record, not from configuration.

| | Platform-held key | Device-held key |
|---|---|---|
| The platform has | the seed and `creds_file` | the public key and a signed `jwt` |
| The keeper | writes `creds_file` | builds the creds from `jwt` and the local seed |
| The seed lives | on the platform | beside the creds file, `.nk`, always `0600` |

The code is ported from the Agent's `internal/platform/devicekeys.go`, with
its rules:

- **If the platform has no key for me, make a new one.** Never send again a
  key the platform dropped. An empty `public_key` means the identity has not
  enrolled yet, or an owner or admin revoked the key.
- **Write the seed first, then enroll** with `POST /api/me/keys`. A crash in
  between leaves a seed nobody enrolled, and the next sync makes another.
- **Stop on a key this host did not make.** An owner or admin pasted it, or
  the seed was lost. The keeper does not generate over it. Readiness reports
  it, and `fix` says to revoke the NATS key on the Thing.

**Platform-held stays the default for applications.** With a device-held key,
the seed exists only on that host. A container recreated without its volume
loses it, and recovery needs an owner or admin to revoke the key. With a
platform-held key the keeper downloads it again. Choose device-held when the
platform must never hold the key, and keep the volume.

### 5. What does not move

- **Nebula keys and the leaf node config.** Only the Agent runs Nebula or a
  leaf node. ADR 0007 left Nebula for services out of scope, and no
  application joins the overlay.
- **The Agent.** Its client runs on the fleet today, on Windows as well as
  Linux, with a 24h sync, its own configuration, the code check and
  `cmd.rotate_creds`. Moving it removes a copy and adds the riskiest change in
  this decision. It keeps its own implementation for now.

### 6. A compromised application is deactivated, not revoked

The application process now holds its Thing's platform session (Costs, first
bullet). Anyone who takes over the process takes the session too. That makes a
Revoke useless against them:

- **Platform-held key:** a Revoke issues a working replacement. Whoever holds
  the session downloads it at their next sync, as the keeper does.
- **Device-held key:** a Revoke empties `public_key`. Whoever holds the session
  can enroll a key of their own with `POST /api/me/keys` before the real keeper
  does. The real keeper then stops on "a key this host did not make."

Deactivating the Thing does work. `hooks/active_flag.go` refreshes its
`tokenKey`, which kills every outstanding session, and it revokes the NATS
identity without issuing anything back. Recovery, in order:

1. Deactivate the Thing.
2. An owner or admin sets a new password. The old one may have sat in the
   process's configuration.
3. Reactivate the Thing, then Revoke its NATS key, so the key pair changes as
   well as the JWT.
4. Start the application once with the new password.

creds-keeper's documentation and the readiness `fix` text say this. Its
documentation now says "Revoke" for a leaked creds file and "deactivate" for a
compromised host.

---

## Consequences

### Good

- **One fewer process per application instance,** and no shared volume, fixed
  gid or file mode set up between two containers.
- **One implementation for every application,** instead of creds-keeper's plus
  one per program that would otherwise grow its own.
- **creds-keeper serves every Thing an operator can make,** including one with
  a device-held NATS key.
- **An operator can keep the platform from ever holding an application's
  private key.**

### Costs we are accepting

- **The application process holds its Thing's platform session, and that is
  not a small widening.** ADR 0007 §3 kept the session in a separate process,
  so a takeover of the application did not reach it. The creds file grants
  NATS. The session grants the platform's HTTP API as the Thing: its own record
  and NATS identity, its own Nebula host if one is ever attached (private key
  included), `leaf-config`, the rotate route and `POST /api/me/keys`. Above
  all, it outlives a Revoke in both key modes. §6 says what to do instead. On
  a first start the platform password is in the process's configuration too.
  We accept this to drop the sidecar, and §6 is the price.
- **Two implementations remain,** the kit's and the Agent's. A change to the
  platform's credential routes is made in both, as ADR 0007 already accepted.
  §1's contract test catches it on the kit's side.
- **A keeper fix is a kit release.** It means a kit tag, then a version bump in
  the services, the helpdesk, access control and the kiosk. A sidecar fix was
  one image.
- **A device-held key ties a Thing to one volume.** §4 makes it a choice, not a
  default.
- **Every application needs a persistent directory** for its session and creds,
  kept out of its backups (§2).
- **A fresh volume during a platform outage keeps the application from
  starting.** `WaitForCreds` blocks until the first credential arrives. With
  a sidecar the application was also held at `service_healthy`, so nothing
  changes but where the wait happens. A volume that already has a creds file
  starts as before.

---

## Verification before this is accepted

ADR 0007's "As implemented" lists a run against a live platform as not yet
verified. This decision makes the package the path for every application, so
that run comes first:

- The watchdog, with the keeper inside it, against a live platform: a first
  start with the password, a restart without it, a Regenerate and a Revoke.
- The same with a device-held NATS key: enrollment, a Revoke that empties the
  key and a new enrollment, and a deleted seed stopping with the `fix` text.
- A crash between writing the seed and enrolling it, run rather than asserted:
  the next start makes a new seed and enrolls it.
- A first start on an empty volume: the application waits in `WaitForCreds`
  and connects when the creds file lands, and does not exit.
- §6 end to end: a second client holding the same session enrolls first after
  a Revoke, and the recovery steps lock it out.
- A PocketBase application's backup holds no file from its credential
  directory.
- ADR 0007 §8: the Thing type, role and Thing each instance needs.

---

## What this changes in other documents

| Document | Part | Change |
|---|---|---|
| ADR 0007 | §10, and the alternatives "Build a platform client into each service" and "A shared Go module" | Superseded for our own programs by §1 and §2. The Agent stays separate (§5). |
| ADR 0007 | Out of scope: Nebula for services | Unchanged. |
| ADR 0008 | Rule 4, first bullet: "through creds-keeper … not a platform client built into the application" | An application runs the kit's keeper in its own process. |
| ADR 0008 | Costs: "One more process per application instance" | Removed. |
| ADR 0008 | Rejected alternative: "A platform client built into each application" | Superseded by this ADR. |
| kit README | "What is not here": a platform client | The keeper is here. The Agent's Nebula and leaf node code is not. |
| services README | "never needs a platform credential" | The watchdog signs in as its Thing. |
| services `docs/creds-keeper.md` | Regenerate and Revoke | Adds §6: Revoke for a leaked creds file, deactivate for a compromised host. |
| `platform/plans/app-kit.md` | Decision C | As ADR 0008 rule 4, amended. "Not a dependency of the Agent" still holds. |

These edits follow when this ADR is accepted.

---

## What would make us revisit this

- **A change to the platform's credential routes has to be made twice and
  hurts.** That is the reason to move the Agent onto the kit's package, with
  its Nebula and leaf node code.
- **An application joins the Nebula overlay.** Device-held Nebula keys then
  have a second user, and they join the package.
- **Running in process causes a problem the sidecar did not have.** The
  binary is still built, so an application can go back to it with no code
  change but configuration.

---

## Rejected alternatives

- **Keep the sidecar for our own applications.** It works and needs no change.
  Each instance then carries a second container, a shared volume with a fixed
  gid, a file mode tuned between two users and a health gate, to run what is
  a goroutine in the application. What the sidecar does buy is isolation: a
  takeover of the application does not reach the platform session. We give
  that up, and §6 is how an operator recovers without it. A deployment that
  wants the isolation back can still run the binary (§3).
- **Hand credentials to nats.go from memory** (`nats.UserJWT` callbacks and
  `ForceReconnect`). It looks faster after a Revoke, but it is not: the
  server already drops a revoked connection, and the client reconnects as soon
  as a new credential exists. The wait is for the next sync, which this does
  not shorten. It would add an interface and change `natsx` for nothing.
- **A Thing-session layer with credential sync on top,** shaped for the
  Agent's Nebula, leaf node and rotate code. That designs for a caller that is
  not moving. §5 and the revisit list say when it would.
- **Seed the package from the Agent's client instead of creds-keeper's.** The
  Agent's client is proven on the fleet, but creds-keeper's package is the
  one with the API an application needs. Its gap is a live run, and the
  verification above closes it. Only the device-key code, which creds-keeper
  does not have, comes from the Agent.
- **Device-held Nebula keys and the leaf node config in the first version,**
  to complete the lifecycle. Nobody but the Agent would call them, so they
  would be maintained without being run.
- **Move the watchdog to its own repository.** Nothing in this decision needs
  it. The services repository keeps the watchdog and the creds-keeper binary,
  with one image build and one release tag.
