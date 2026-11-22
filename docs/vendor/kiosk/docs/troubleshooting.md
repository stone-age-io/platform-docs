---
path: kiosk/troubleshooting
nav_order: 110
---
# Troubleshooting

This page lists common errors and their fixes. For build and test loops, see
[Development](development.md). For deployment, backups and NATS failures, see
[Operations](operations.md).

---

## 1. The Root Page Returns "The requested resource wasn't found"

`localhost:8090` returns this body:

```json
{"message":"The requested resource wasn't found."}
```

The binary has no SPA page to serve. Its embedded bundle came from an
incomplete `internal/ui/dist/`. A missing or empty `dist/` does not get this
far: `go build` stops with an embed error. Build the SPA first, then the
binary:

```bash
npm run build --prefix ui      # fills internal/ui/dist/
go build ./cmd/kiosk           # //go:embed takes the new dist/
```

---

## 2. A Scan Does Nothing During Development

The `useScan` composable listens for `keydown` and dispatches on Enter. It
does nothing while one of these elements has focus:

- an `<input>`
- a `<textarea>`
- a `<select>`
- a contenteditable element

Click the page body, outside any input. Then type the badge or item code and
press Enter.

---

## 3. The Bootstrap Admin Credentials Did Not Print

The migration runs **once**. If `_migrations` in your `pb_data/` already
records it, the seed has already run. Do one of these:

- Reset the existing admin's password in the superuser UI at `/_/`.
- Delete `pb_data/` and start again.

::: warning Deleting `pb_data/` removes all data
It wipes all data of the kiosk node, not only the admin.
:::

---

## 4. A Commit Returns 500

Read the binary's stdout. On any error, the commit function rolls back the
database transaction and returns the wrapped error. Examples are an invalid
item ID, or a serialized item with a quantity above 1. The cart stays as it
was, so the worker can try again.

---

## 5. A Punch Returns 409

The body's `error` field is `already_clocked_in`, `not_clocked_in` or
`open_checkouts`. These are expected conflicts, not errors. The SPA branches
on the machine-readable `error` field.

- **`already_clocked_in` or `not_clocked_in`.** The merged state already
  disagrees with the requested direction. Often the worker punched at another
  kiosk node, and this kiosk node's replica is newer. The panel refreshes so
  that the button matches.
- **`open_checkouts`.** `block_clock_out_with_open_checkouts` is on, and the
  worker still holds tools. In managed mode the check covers the whole fleet:
  tools out at any kiosk node, each tagged with the building to return it to.
  So the timeclock terminal blocks too. The body lists the tools. The worker
  can check again after a return, or select **clock out anyway** to
  acknowledge and continue. An admin punch with `force=true` overrides it.

If the check seems *not* to fire when it should, remember that the replica is
eventually consistent and fail-open. A new checkout, or an outage of the
controller or KV, can leave it permissive for a short time. It corrects
itself at the next projection.

---

## 6. A Worker Cannot Sign In to the Timeclock Terminal

Check these causes in order:

1. **Wrong binary.** Worker sign-in exists only on `cmd/timeclock`. A
   migration that only that binary runs enables it. A normal `cmd/kiosk`
   never lets workers sign in.
2. **`active=false`.** The `AuthRule` is `active = true`. A deactivated worker
   cannot get a session, and `requireWorker` rejects a token that is still
   valid.
3. **No email on the record.** SSO matches by email, and password reset sends
   an email. Both need the worker's email.
4. **OAuth2 says "this account is not provisioned for time clock access".**
   The match-only guard rejected an IdP account whose email has no
   provisioned worker. Provision the worker first, with the matching email. In
   managed mode, do it on the controller. Standalone, do it locally.
5. **The password reset email never arrives.** Provisioning sets a random
   password, so workers must use "Forgot password". That needs SMTP in the
   superuser UI (Settings → Mail).

---

## 7. Tests Fail with `find items: sql: no rows in result set`

The migrations did not run before the test seeded its fixtures. The test
helper in `internal/commit/commit_test.go` calls `app.Bootstrap()`, then
applies the migrations with `core.NewMigrationsRunner`. Follow the same
pattern in a new test against PocketBase. The `Automigrate` of `migratecmd`
hooks `OnServe`, not `OnBootstrap`, so it does not run in a test that starts
no server.
