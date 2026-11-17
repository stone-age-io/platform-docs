---
path: platform/onboard-a-tenant
nav_order: 52
---
# Onboard a Tenant

This guide takes a provider from "a new customer signed" to "the customer's
administrator can sign in to their own Organization". It uses the
[`stone` CLI](./stone-cli.md), so you can script it. The console and the REST
API do the same work through the same rules.

You need a running platform and a `stone` CLI that is signed in as a **Platform
Operator** ([Getting Started §2](./getting-started.md#2-connect-the-stone-cli)).
Only a Platform Operator can create an Organization
([Authorization §3](./authorization.md#3-cross-organization-identities)).

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

## 2. Find your user id

The owner of the new Organization is a user id. Your own is the `user_id` line:

```bash
stone auth whoami
```

---

## 3. Create the Organization

```bash
stone organization create --name "Northwind Foods" --code northwind --owner <your user_id>
stone org switch northwind
```

- **`--code`** is the tenant's name in subjects, device emails and printed
  labels. It is globally unique and you cannot change it later. If you leave it
  out, the platform makes one from the name
  ([ADR 0002](./decisions/0002-organization-code-namespace.md)).
- **`--owner`** takes a user id, not an email. Here it is your own.
- **`--active`** defaults to `true`. Pass `--active=false` only to create the
  tenant suspended ([Authorization §3.1](./authorization.md#31-suspending-an-organization)).

In the same operation, the platform does four things:

1. It provisions the Organization's **NATS account**.
2. It provisions the Organization's **Nebula CA**.
3. It creates an `owner` **Membership** for the owner.
4. It makes the new Organization the owner's **active organization**
   (`users.current_organization`).

The server changes your active organization, but `stone` keeps its own copy.
`stone org switch northwind` brings `stone` into line, so every later command
applies to the new tenant. It prints `nats-sync: skipped`, because you have no
NATS identity in Northwind yet. To go back to your own organization, run
`stone org switch <code>`, or use the console's org switcher.

---

## 4. Check what a new Organization has

```bash
stone nats-account ls --fields name,active
```

The account must show `active` as `true`.

A new Organization has **no NATS roles and no NATS users**. Nobody in it can
connect to the bus until an Owner or Admin creates a role with permissions and
a user with that role. An empty allow list grants nothing
([Connectivity §1](./connectivity.md#core-pubsub-subject-namespacing)).

---

## 5. Invite the customer's administrator

```bash
stone invite create --email dana@northwind.example --role admin
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

To make the customer the owner later, a Platform Operator changes the
Organization's owner with `stone organization update northwind --owner <user id>`.
The new owner gets an `owner` Membership. The previous owner keeps the
Membership they had.

---

## 6. Give your own staff access

The Platform Operator flag gives no access to a tenant's data. A person reads a
tenant's inventory only through a **Membership** in that Organization
([Authorization §3](./authorization.md#3-cross-organization-identities)).

Invite each of your technicians into the tenant in the same way as in §5. A
Platform Operator can invite a user into any Organization. Most staff need
`member`, which manages inventory:

```bash
stone invite create --email sam@acme-msp.example --role member
```

Give `admin` only to staff who must manage credentials, because `admin` can
read every credential in the tenant.

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

[Getting Started §4](./getting-started.md#4-give-yourself-a-nats-identity) has
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
