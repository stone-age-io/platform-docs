---
path: kiosk/contract
nav_order: 140
title: The Kiosk Contract
---
# The kiosk contract

What an organization needs on the platform to run kiosks: the Thing Types,
their operations and the NATS roles. It is a `stone` template, so onboarding
an organization is one command, run as an owner or admin of it:

```sh
stone org switch <org>
stone apply --template contract/ --dry-run
stone apply --template contract/
```

Applying it again updates an organization to this version and changes
nothing that already matches. It never deletes, and it leaves alone anything
it does not name. See `stone apply --help` (TEMPLATES).

| Thing Type | Process | NATS role |
|---|---|---|
| `tool-kiosk` | each kiosk node (`cmd/kiosk`) | `kiosk-node` |
| `timeclock-terminal` | each timeclock terminal (`cmd/timeclock`) | `kiosk-timeclock` |
| `kiosk-controller` | the controller (`cmd/controller`) | `kiosk-controller` |

Give each process's NATS user the role in its row. The role is shared by every
Thing of that kind, so its subjects use `*` for the kiosk code; pb-nats has no
per-Thing subject. Only the controller writes a bucket: nodes and terminals
read the catalogue and state.

Keep this folder in step with `internal/events/subjects.go` and the bucket
names in the controller. The platform's demo seed carries the same Thing
Types (`platform/internal/demoseed/contract.go`).
