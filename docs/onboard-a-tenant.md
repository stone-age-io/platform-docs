---
path: platform/onboard-a-tenant
nav_order: 52
---
# Onboard a Tenant

This guide takes a provider from "a new customer signed" to "the customer's
administrator can sign in to their own Organization". It uses the REST API, so
you can script it. The console and the [`stone` CLI](./stone-cli.md) do the
same work through the same rules.

You need a running platform ([Getting Started](./getting-started.md)) and a
**Platform Operator** login. Only a Platform Operator can create an
Organization ([Authorization §3](./authorization.md#3-cross-organization-identities)).

---

## 1. Decide two things first

**Who is the owner.** The owner must be a user that already exists. An
invitation cannot create an owner. The usual choice for a provider is to stay
the owner and invite the customer's administrator as `admin`. `admin` and
`owner` have the same authority in every API rule.

**The account limits.** A new Organization gets the limits in
`nats.default_limits` at this moment, and a later change to the config does not
reach it. Check them before you create the Organization
([Configuration §2](./configuration.md#2-section-reference)).

---

## 2. Sign in as the Platform Operator

These commands use `jq` to read the JSON responses.

```bash
printf 'Password: '; read -rs PASS; echo
AUTH=$(curl -s -X POST http://localhost:8090/api/collections/users/auth-with-password \
  -H 'Content-Type: application/json' \
  -d '{"identity":"admin@example.com","password":"'"$PASS"'"}')
TOKEN=$(echo "$AUTH" | jq -r .token)
MY_ID=$(echo "$AUTH" | jq -r .record.id)
```

---

## 3. Create the Organization

```bash
ORG_ID=$(curl -s -X POST http://localhost:8090/api/collections/organizations/records \
  -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Northwind Foods","code":"northwind","owner":"'"$MY_ID"'"}' \
  | jq -r .id)
```

- **`code`** is the tenant's name in subjects, device emails and printed
  labels. It is globally unique and you cannot change it later. If you leave it
  out, the platform makes one from the name
  ([ADR 0002](./decisions/0002-organization-code-namespace.md)).
- **`owner`** is a `users` id. Here it is your own.
- **`active`** defaults to `true` when you leave it out. Send `false` only to
  create the tenant suspended ([Authorization §3.1](./authorization.md#31-suspending-an-organization)).

In the same operation, the platform does four things:

1. It provisions the Organization's **NATS account**.
2. It provisions the Organization's **Nebula CA**.
3. It creates an `owner` **Membership** for the owner.
4. It makes the new Organization the owner's **active organization**
   (`users.current_organization`).

After step 4, every org-scoped request you make applies to the new tenant. To
go back to your own organization, set `current_organization` on your user
record, use the console's org switcher, or run `stone org switch <code>`.

---

## 4. Check what a new Organization has

```bash
curl -s "http://localhost:8090/api/collections/nats_accounts/records?filter=organization='$ORG_ID'" \
  -H "Authorization: $TOKEN" | jq '.items[] | {name, active}'
```

The account must show `"active": true`.

A new Organization has **no NATS roles and no NATS users**. Nobody in it can
connect to the bus until an Owner or Admin creates a role with permissions and
a user with that role. An empty allow list grants nothing
([Connectivity §1](./connectivity.md#core-pubsub-subject-namespacing)).

---

## 5. Invite the customer's administrator

```bash
curl -s -X POST http://localhost:8090/api/collections/invites/records \
  -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"email":"dana@northwind.example","organization":"'"$ORG_ID"'","role":"admin"}'
```

The platform sends an email with a link to the console route `/accept-invite`.
The invitee opens the link, creates their account, and joins the Organization
with the role in the invitation.

- **Mail must work.** Configure SMTP as the SuperUser in the admin UI (`/_/`).
  A failed invitation email goes to the application log only.
- **A person can register only with an invited address.** The platform accepts
  a new account from a caller who is not signed in only when a pending
  invitation has the same email address.
- **The invitation expires** after `tenancy.invite_expiry_days`, 7 by default.
- **An invitation can offer `admin`, `member`, `viewer` or `dashboard`**, not
  `owner`.

To make the customer the owner later, a Platform Operator edits the
Organization's owner. The new owner gets an `owner` Membership. The previous
owner keeps the Membership they had.

---

## 6. Give your own staff access

The Platform Operator flag gives no access to a tenant's data. A person reads a
tenant's inventory only through a **Membership** in that Organization
([Authorization §3](./authorization.md#3-cross-organization-identities)).

Invite each of your technicians into the tenant in the same way as in §5. A
Platform Operator can invite a user into any Organization. Most staff need
`member`, which manages inventory. Give `admin` only to staff who must manage
credentials, because `admin` can read every credential in the tenant.

A user with several Memberships changes tenant with the console's org switcher
or `stone org switch <code>`.

---

## 7. Put people on the bus

Each person who uses dashboards or live data needs a NATS identity in this
Organization, linked to their Membership. An Owner or Admin does this in the
console:

1. **NATS → Roles:** create a role and fill in its permissions.
2. **NATS → Users:** create a user with that role.
3. Link the user to the person's Membership. Only an Owner or Admin can choose
   which identity a Membership uses.

[Getting Started §4](./getting-started.md#4-connect-the-browser-to-nats) has
these steps in detail.

---

## 8. Checklist

- [ ] The Organization has the code you want, and `active` is `true`.
- [ ] Its NATS account shows `active: true`.
- [ ] The customer's administrator accepted the invitation.
- [ ] Each of your staff who works on this tenant has a Membership with the
      lowest role that does the job.
- [ ] At least one NATS role and one NATS user exist, and the user is linked to
      a Membership.
- [ ] If the tenant uses the provider's helpdesk, the `managed` flag is set
      ([Connectivity §1](./connectivity.md#cross-account-subject-sharing-imports-exports)).

---

## 9. Where to Go Next

- Put the tenant's first device on the bus: [Connect Your First Device](./first-device.md)
- The tenant's inventory: [Platform Entities](./platform-ui-entities.md)
- What each role can do: [Authorization & Roles](./authorization.md)
- Many tenants from one workspace: [Stone CLI](./stone-cli.md)
- Suspending and deleting a tenant: [Authorization §3.1](./authorization.md#31-suspending-an-organization)
