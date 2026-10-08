---
path: helpdesk/email-ingestion
nav_order: 50
---
# Email Ingestion

Helpdesk turns inbound email into tickets and ticket comments. An **inbound
email-parsing provider** (Postmark) receives the mail, parses the MIME and
`POST`s clean JSON to a helpdesk webhook. This page covers the pipeline,
customer resolution, threading, the Postmark adapter, operator setup, the
security posture, and how to add another provider. For outbound mail, see
[Notifications](notifications.md). For the request and response shapes, see
[Wire Protocol](protocol.md).

**The helpdesk never speaks IMAP or SMTP and holds no mailbox credentials.**
The provider owns the mail plumbing (MIME parsing, attachment extraction, spam
scoring, DKIM/SPF verification, quoted-reply stripping). The helpdesk owns a
stateless HTTP handler and holds only a webhook secret. Ingestion is
**text-only**: attachments are dropped (see [§10](#10-limits)).

The code is in three places: `internal/inbound/email.go` (the
provider-neutral core), `internal/inbound/postmark.go` (the adapter) and
`internal/customers/hooks.go` (the domain guard). Migration `1823000000` adds
the schema.

---

## 1. Pipeline

```
                         (customers keep emailing the pretty address)
  requester  ──►  support@example.com
                        │  Google Workspace auto-forward
                        ▼
                 MX: in.example.com  ──►  Postmark (receive + parse MIME)
                        │  HTTPS POST (clean JSON)
                        ▼
   POST /api/helpdesk/inbound/email/{provider}      ← thin adapter (auth + map)
                        │  NormalizedInbound
                        ▼
                 IngestEmail(app, msg)              ← provider-agnostic core
                        │
          ┌─────────────┴──────────────┐
          ▼                            ▼
  reply token → ticket?          no match / no token
          │                            │
   status == closed? ──► new ticket    └─► resolve customer → CreateTicket
          else                              (source = "email")
          ▼
   create ticket_comment (public)
   → existing tickets hook auto-reopens
     a resolved ticket, clears awaiting_requester
```

There is no background worker. Each message is request in, DB write, response
out, like the `POST /api/helpdesk/inbound/{token}` webhook.

All logic lives in a provider-neutral core. Each provider is a thin adapter
that maps its wire format to one internal struct, `NormalizedInbound`. Nothing
in the core knows Postmark exists (see [§9](#9-swapping-providers)).

---

## 2. The Core

### `NormalizedInbound`

The one struct every adapter produces. It is post-parse and text-only, with
quoted history already stripped, so the core never touches MIME or
attachments.

```go
type NormalizedInbound struct {
    MessageID  string            // provider's RFC Message-ID; idempotency key
    From       Addr              // sender (email + display name)
    Subject    string
    Body       string            // best available plain text: provider's stripped
                                 // reply if present, else full text/plain
    ReplyToken string            // optional override; "" ⇒ the core parses the
                                 // [#N] subject token itself (a plus-hash reply
                                 // address is a documented future upgrade — see
                                 // Limits)
    Headers    map[string]string // lower-cased keys; for the loop guard
    DKIMPass   bool              // provider verdict — LOGGED, not enforced (v1)
    SpamFlag   bool              // provider spam verdict
}
```

### `IngestEmail`

`IngestEmail(app core.App, msg NormalizedInbound) (Result, error)` makes the
whole decision and is testable without HTTP. The steps run in this order:

1. **Loop and spam guard: drop early.** Ignore the message (ack, log, create
   nothing) when any of these holds:
   - `SpamFlag` is set.
   - `From` is empty, `mailer-daemon@` or `postmaster@`.
   - `Auto-Submitted` is present with any value other than `no`.
   - `Precedence` is `bulk`, `list` or `junk`.

   The helpdesk sends from a neighbouring address, so bounces and
   out-of-office replies arrive. Without this guard, a notification and its
   auto-reply could loop.
2. **DKIM: log only.** `!DKIMPass` logs a warning and processing continues
   (see [§8](#8-security-posture)).
3. **Threading.** Take `ReplyToken`, else parse `[#N]` from the subject. If it
   resolves to a ticket (looked up by `number` alone):
   - **`closed`:** do *not* comment. A closed ticket is final, as on the
     portal, so fall through to step 4 and prefix the body with a
     `Reply to closed ticket #N` breadcrumb. The breadcrumb is added only when
     the sender resolves to that ticket's own customer, so a new ticket never
     names another tenant's ticket.
   - **Otherwise:** if a comment already has `source_message_id ==
     MessageID`, return `duplicate`. Else create a `ticket_comments` row (see
     [§3](#3-replies)).

   An `N` that matches no ticket falls through to step 4 with no breadcrumb.
4. **New ticket.** Resolve the customer ([§4](#4-customer-resolution)),
   normalize into the existing `inbound.Payload` and call `CreateTicket` with
   `source = "email"`:
   - title = subject, or `(no subject)`
   - `RequesterEmail` = sender
   - `DedupeKey` = `MessageID`

   A ticket of that customer that already has `dedupe_key == MessageID` comes
   back as `duplicate`.

The `Result` is `created`, `commented`, `duplicate` or `ignored{reason}`. The
adapter turns it into the HTTP response.

### Idempotency

Providers retry on non-2xx, and each path absorbs its own redelivery. There is
no separate up-front check. Unique indexes are the backstop, as for
`tickets.number` and `tickets.dedupe_key` (the latter unique per customer). An
empty `MessageID` disables both checks.

---

## 3. Replies

### The threading token

The core parses `\[#(\d+)\]` from the subject. Every notification subject
carries `[#{{.Ticket.Number}}]`
([`notifications/defaults.go`](https://github.com/stone-age-io/helpdesk/blob/main/internal/notifications/defaults.go)), and
mail clients keep the subject on reply (`Re: [#42] …`). It needs no outbound
change and no config. If a user deletes the `[#N]` from the subject, the
reply becomes a new ticket.

For a reply to reach the provider at all, the **PocketBase sender address must
be the intake mailbox** (see [§7](#7-operator-setup)).

### The comment

A reply becomes a `ticket_comments` row:

| field               | value                                                              |
|---------------------|--------------------------------------------------------------------|
| `ticket`            | the resolved ticket id                                             |
| `author_user`       | user whose `email` matches `From` **within the ticket's customer** (may be empty) |
| `body`              | `msg.Body`, prefixed with a `From: name <email>` provenance line   |
| `internal`          | `false` when the sender belongs to the ticket's customer, else `true` (below) |
| `source_message_id` | `msg.MessageID` (hidden field, unique index)                       |

`source_message_id` is a hidden text field with a partial unique index on
non-empty values (`idx_ticket_comments_source_msgid`). It is the comment
path's idempotency backstop, like `tickets.dedupe_key`.

The row is written server-side with `app.Save`, which bypasses collection
rules. The existing `OnRecordAfterCreateSuccess("ticket_comments")` hook in
[`internal/tickets/hooks.go`](https://github.com/stone-age-io/helpdesk/blob/main/internal/tickets/hooks.go) does the rest. A
public comment with `author_user` set runs `handleRequesterReply`, which
**reopens a `resolved` ticket** and clears `awaiting_requester`. The reopen is
silent (`notifications.Suppress`) and attributed to that user
(`activity.SetActor`). Email replies need no lifecycle code of their own.

### Who may reply

Ticket numbers are global and sequential, so `[#N]` identifies a ticket but
says nothing about who may write on it. `senderBelongsTo` checks the sender
against the **ticket's** customer, using the same two rungs as new tickets:

- **A registered user of that customer:** a public, attributed comment. The
  hook reopens the ticket and clears `awaiting_requester` as above.
- **An address at that customer's `email_domain`:** a public comment with no
  author. The hook does *not* auto-reopen on the word of someone with no
  account.
- **Anyone else** (another tenant's user, a stranger, the requester writing
  from a personal address, a CC'd vendor): an **internal** comment whose body
  opens with "Held for review", saying the sender is not on this customer's
  account. It never reaches the portal, never reopens, and emails nobody
  (internal notes never send). The event is logged.

Outsider replies are held rather than dropped because some are legitimate.
Staff see them in the timeline, with the real sender in the provenance line,
and can repost them. A guessed `[#N]` cannot put text in front of another
tenant's requesters.

### The body

The adapter prefers the provider's stripped-reply field (Postmark
`StrippedTextReply`), so quoted history is gone with no heuristics. It falls
back to `TextBody`.

---

## 4. Customer Resolution

A single forwarded `support@` address cannot identify the tenant by recipient,
so a new ticket resolves its customer from the sender:

1. `From` matches a `users.email`: that user's `customer`, with `requester`
   set.
2. Else the `From` domain (never a public provider) matches an **active**
   customer's `customers.email_domain`: that customer, with no requester.
3. Else **reject**: ack with `200 ignored` (never `500`) and log. There is no
   default or triage customer. The helpdesk accepts only mail it can
   attribute to a known tenant.

What this means for each kind of customer:

- **A customer with a mapped domain:** any employee at `acme.com` can email in
  cold (rung 2). The requester is unlinked, and staff can link it later.
- **A customer without a domain** (a solo Gmail or Outlook contact): their
  people must exist as registered `users` (rung 1).

::: warning Unregistered senders at a domain-less customer are dropped
A brand-new contact who is not a registered user, at a customer with no
`email_domain`, is dropped and logged, not queued.
:::

Matching is customer-scoped on both paths. A new ticket's requester match is
scoped to the customer, as in the `inbound.go` webhook, and a reply is public
only when its sender belongs to the ticket's customer
([§3](#who-may-reply)). A stray email cannot open a ticket in the wrong
tenant or post into one.

### `customers.email_domain`

- Text, **optional**, **unique when set**. A partial unique index on non-empty
  values (`idx_customers_email_domain`) stops two customers claiming the same
  domain.
- The save hook stores it trimmed and lower-cased.
- Optional because a customer may be a single contact on a shared provider
  (such as a solo operator on `gmail.com`). Such a customer leaves it blank
  and matches only on rung 1.
- **Public-domain guard.** A `customers` save hook (`internal/customers`)
  rejects a shared or free domain with `400`, so no customer can claim
  `gmail.com` and take every Gmail sender. The blocklist is
  `publicEmailDomains` in `email.go`, shared with the resolution ladder:
  `gmail.com`, `googlemail.com`, `outlook.com`, `hotmail.com`, `live.com`,
  `msn.com`, `yahoo.com`, `yahoo.co.uk`, `ymail.com`, `icloud.com`, `me.com`,
  `mac.com`, `aol.com`, `proton.me`, `protonmail.com`, `gmx.com`, `zoho.com`,
  `mail.com`, `fastmail.com`.

`tickets.source` has the value **`email`** beside `portal`, `agent`, `nats`
and `webhook`. The migration changes no collection **rules**: every write is
server-side through `app.Save`, which bypasses them.

---

## 5. The Postmark Adapter

`internal/inbound/postmark.go` is the only Postmark-aware code. It:

1. **Authenticates the webhook.**
   - An optional source-IP allowlist runs first (`inbound.allowed_ips`,
     Postmark's published egress ranges, bare IPs or CIDRs; empty means no
     restriction). A miss returns `403`.
   - Then Basic auth on the webhook URL (Postmark supports `user:pass` in the
     URL). The **password** is compared in constant time against
     `inbound.secret`, and the username is ignored. A miss returns `401` with
     a `WWW-Authenticate` challenge.
2. **Decodes** the Postmark inbound JSON into a local struct.
3. **Maps** it to `NormalizedInbound`:

   | Postmark field                                       | NormalizedInbound       |
   |------------------------------------------------------|-------------------------|
   | `MessageID` \|\| `Message-ID` header                 | `MessageID`             |
   | `FromFull.Email` \|\| `From`; `FromFull.Name`        | `From`                  |
   | `Subject`                                            | `Subject`               |
   | `StrippedTextReply` (if non-blank) \|\| `TextBody`   | `Body`                  |
   | `Headers[]`                                          | `Headers` (lower-cased) |
   | `X-Spam-Status` header starts with `Yes`             | `SpamFlag`              |
   | `Authentication-Results` lacks `dkim=fail`           | `DKIMPass`              |

   `ReplyToken` is left empty, and the core derives it from the subject. DKIM
   defaults to pass, so a provider that omits `Authentication-Results` never
   warns.
4. **Calls `IngestEmail`** and turns the `Result` into an HTTP response.

### Responses

Providers retry on non-2xx, so the status codes are chosen with care:

| Status | When |
| :--- | :--- |
| `200` | Anything handled *or* intentionally dropped: `{status: created\|commented\|duplicate\|ignored, id?, number?, reason?}`. A dropped loop or spam message returns `200 ignored`, so the provider stops retrying. |
| `403` | The caller's IP is not in the allowlist. |
| `401` | Bad or missing secret. |
| `400` | Undecodable body. |
| `500` | A genuine transient server error only, so the provider retries. |

---

## 6. Configuration

The `inbound` block in `config/config.go` uses viper defaults and `HELPDESK_*`
overrides, like `NATSConfig`:

```yaml
inbound:
  secret: "<webhook basic-auth password>"   # empty ⇒ email ingestion disabled
  allowed_ips: []                            # optional provider egress allowlist (IPs or CIDRs)
  # reply_to: "support@example.com"          # parsed but UNWIRED in v1 — see Operator Setup
```

The env overrides are `HELPDESK_INBOUND_SECRET`,
`HELPDESK_INBOUND_ALLOWED_IPS` and `HELPDESK_INBOUND_REPLY_TO`.

- **`secret`** turns the feature on. `InboundConfig.Enabled()` is
  `secret != ""`. Disabled is valid: the app serves without email ingestion,
  as with `NATSConfig.Enabled()`.
- **`allowed_ips`** pins the caller to the provider's egress ranges (see
  [§5](#5-the-postmark-adapter)).
- **`reply_to`** is parsed into `InboundConfig.ReplyTo`, but nothing reads it.
  Setting it does **nothing**.

There is no `reply_domain` (threading uses the subject token) and no
`default_customer` (unmatched senders are rejected).

The route is registered in the `OnServe` block in `cmd/helpdesk/main.go`,
next to `inbound.Register(e)`. `inbound.RegisterEmail(e, cfg.Inbound.Secret,
cfg.Inbound.AllowedIPs)` binds `POST /api/helpdesk/inbound/email/postmark`
and does nothing when the secret is empty. (It checks the secret directly
instead of calling `InboundConfig.Enabled()`; the condition is the same.) The
webhook is plain HTTP, with no lifecycle resources to tear down.

---

## 7. Operator Setup

One-time, outside the helpdesk:

1. Add an inbound subdomain (`in.example.com`) and point its **MX** at
   Postmark.
2. Create a Postmark inbound stream. Set its webhook to
   `https://helpdesk.example.com/api/helpdesk/inbound/email/postmark` with
   Basic auth.
3. In Google Workspace, auto-forward `support@example.com` to the Postmark
   inbound address.
4. Keep SPF and DKIM aligned for the sending domain, so outbound mail (and any
   provider verification) passes.
5. Set the **PocketBase sender address to the intake mailbox**
   (`support@example.com`, the one forwarded to Postmark).

Step 5 is the whole coupling between outbound and inbound mail. PocketBase
configures only the **From / sender address**
(`settings.Meta.SenderAddress`, see
[`notifier.go`](https://github.com/stone-age-io/helpdesk/blob/main/internal/notifications/notifier.go)) and SMTP. It has no
Reply-To setting. With the sender address set to the intake mailbox, replies
return there with no `Reply-To` header, and the `[#N]` in every subject
threads them. No code or template change is needed.

::: note Sending from one address and receiving at another
If an install must send *from* one address and receive replies at another,
`inbound.reply_to` has to be wired first, with one line in
`notifier.deliverEmail`: `msg.Headers["Reply-To"] = cfg.Inbound.ReplyTo`.
Until then, the sender address must be the intake mailbox.
:::

PocketBase's SMTP supports only username and password. If outbound mail goes
*through* Gmail, use Google's IP-authenticated relay or a transactional
provider (such as uSend or SES), not user-auth Gmail.

---

## 8. Security Posture

- **No mail credentials in the helpdesk**, only a webhook secret.
- **The webhook is authenticated** with the secret and an optional IP
  allowlist. Unauthenticated returns `401`, a disallowed IP `403`.
- **DKIM is log-only.** A `dkim=fail` in the provider's
  `Authentication-Results` is logged as a warning in the process log only.
  Nothing is stored on the ticket or comment, SPF is not read, and the
  message is not blocked.
- **Rejecting unmatched senders is the main spam and abuse control.** Mail
  that cannot be attributed to a known tenant is dropped, so the helpdesk is
  not an open funnel. Authors are matched by `From` **within the ticket's
  customer**. An unmatched sender is never attributed and never auto-reopens,
  and an outsider's reply is held as an internal comment.
- **Tenant isolation matches the `inbound.go` webhook.** All matching is
  customer-scoped, so a new ticket cannot land in the wrong tenant. `[#N]` is
  guessable (numbers are sequential), so it selects the ticket but never
  grants the right to write on it publicly. The public-domain guard on
  `email_domain` ([§4](#customersemail_domain)) stops domain mapping leaking
  across tenants.

::: warning A spoofed known sender is still processed
Because DKIM is log-only, a forged `bob@acme.com` with DKIM `fail` can post
a comment or reopen a resolved ticket as "bob". The logged verdict is the
audit trail. If this matters, the upgrade is to skip the auto-reopen on a
*reply* with DKIM `fail` and hold it for staff review, not to hard-block.
:::

---

## 9. Swapping Providers

The seam is `NormalizedInbound` plus `IngestEmail`. A new provider is one
file that maps its format to the struct and calls the core:

- **CloudMailin, Mailgun, SendGrid:** each is a field-mapping adapter like
  Postmark's.
- **SES inbound:** an SES receipt rule writes raw MIME to S3 and triggers a
  Lambda. The Lambda (or a small SES → SNS → helpdesk route) parses the MIME
  (`enmime`) into `NormalizedInbound` and calls the same core. You own more
  infrastructure (Lambda, S3) and the MIME parsing, but the core does not
  change.

A provider that does not strip quoted replies needs another way to cut them.
One option is a delimiter: append `##- reply above this line -##` to outbound
mail and cut there on inbound.

---

## 10. Limits

Email ingestion does not do these:

- **Attachments.** They are dropped, not stored. Most inbound images are
  *inline* signature parts (a logo and social icons, `Content-Disposition:
  inline`, referenced by `cid:` in the HTML), often three or four per email
  and repeated on every reply. Storing Postmark's `Attachments[]` would bury,
  or under the six-files-per-record cap crowd out, the one screenshot that
  matters, and no reliable rule tells them apart. The plain-text part has no
  image references, so there is nothing to filter. Requesters attach files on
  the portal, and staff can point an emailer there.
- **Per-customer inbound addresses.** Every customer uses the shared
  `support@` address and the resolution ladder.
- **Plus-addressed threading.** A `Reply-To: support+{number}@…` header with
  Postmark's `MailboxHash` would route replies even when the subject is
  edited. It would add a header, a config value and a dependency on plus tags
  surviving forwarding, so threading uses the subject token only.
- **Sending as the customer's own domain.**
- **HTML bodies.** Only the plain-text part is stored.
- **Visit or time actions.** Email creates only tickets and comments.

---

## 11. Where to Go Next

- The inbound webhook's request and responses: [Wire Protocol](protocol.md)
- The `inbound` keys and PocketBase sender settings: [Configuration Reference](configuration.md)
- `customers`, `tickets` and `ticket_comments` fields and indexes: [Data Model & Access Rules](data-model.md)
- The outbound mail that replies thread on: [Notifications](notifications.md)
- How work arrives, and how the pieces fit: [Overview](overview.md)
