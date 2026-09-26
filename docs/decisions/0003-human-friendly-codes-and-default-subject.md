# ADR 0003: Human-Friendly Codes, Type Prefixes, and a Location-Free Default Subject

**Status:** Accepted — implemented in the platform, except `stone` (step 7). Step 6's move of the demo to bare application identifiers was dropped.
**Date:** 2026-09-25 (implemented 2026-09-25)

> The Decision below is the design as it was argued. See [As implemented](#as-implemented) for what shipped, the one part that was dropped, and why.

> This ADR builds on [ADR 0002](./0002-organization-code-namespace.md) and does not revisit it: ids for storage, codes for addressing, and a code is frozen once set. It changes how Thing and Location codes are *made*, how they are compared, and what the platform's default subject contains. What the Time-Series Database does without a location in the subject is [ADR 0004](./0004-long-term-data-and-location-path.md).

> The code format borrows from BEC Systems' [Human-Friendly Industrial Device IDs](https://bec-systems.com/2563/human-friendly-industrial-device-ids/): short, random, chunked, from an alphabet with the look-alike characters removed. The type prefix is our addition. The article's IDs carry no meaning, and we keep that for everything after the prefix.

---

## Context

A Thing or Location code is the string a technician reads aloud, types into a scanner's manual field, and finds printed on a label. It is also a NATS subject token and the join key every sibling app resolves by. The rules today:

- **Optional, and installer-supplied.** ADR 0002 rule 2 says a code is "slugified from `name` otherwise", but only organizations actually get one derived. A Thing or Location saved without a code stays blank. That means it gets no label, and `{thing}` falls back to the record id in subjects.
- **Frozen once set.** `@request.body.code:changed = false` on all four code-scoped collections.
- **Unique per organization, case-sensitively.** `CREATE UNIQUE INDEX idx_things_org_code ON things (organization, code) WHERE code != ''`, and the same on `locations`, `thing_types` and `location_types`. None of them folds case.

Four problems follow.

**Hand-typed codes are sequential, and sequential codes fail quietly.** Installers number things: `CAM-041`, `CAM-042`. Neighbours on a wall look alike, and a one-character typo lands on a *real* record. The scanner then opens the wrong camera, and nothing looks wrong.

**Two codes can differ only by case.** `cam-1` and `CAM-1` are both legal, both unique and both valid subject tokens. They give two identities, two subject namespaces and two sets of permissions that a person reading one aloud cannot tell apart.

**The default subject puts location in it, and our own docs warn against that.** An empty `subject_prefix` resolves to `{thing_type_code}.{location}.{thing}`. [Thing Types](../thing-types.md#two-constraints-worth-knowing-before-you-design-a-prefix) already says to put `{location}` in a prefix "only for things that do not move". So the default is the one layout we tell people to avoid for anything that moves: a relocated camera starts publishing under new subjects, and its history is split across two sites. The Agent already leaves location out (`agents.gw-99.heartbeat`), and the docs currently call it "the exception".

**A record's type can change, and its subject is built from its type.** `things.type` and `locations.type` are ordinary editable relations. Retyping a Thing moves every subject it publishes under.

Nothing is in production yet. The only consumers of the current default are the demo seed (`internal/demoseed`), the demo rules (`demo/rules/northwind`) and the demo Telegraf config (`demo/telegraf`). This is the cheapest this change will ever be.

---

## Decision

Six rules.

### 1. Types carry an optional prefix

`thing_types.prefix` and `location_types.prefix`:

- **Optional.** Blank is legal, the same as codes. The generator in rule 2 adapts to a blank prefix; it never fails because of one.
- **`^[A-Z]{1,4}$`.** Uppercase letters only. With no digits, the boundary between prefix and random part is always visible: `CA-9KD-4PX` reads as "type, then noise".
- **Unique within the organization, across both collections.** Thing prefixes and Location prefixes are separate sets. A partial unique index `(organization, prefix) WHERE prefix != ''` covers each collection, and a create/update hook refuses a prefix already used by the *other* collection in the same organization. An index cannot look across two tables.
- **Editable.** Nothing downstream reads a prefix. It is copied into a code when the code is generated, and a frozen code keeps whatever it was given. Changing `CA` to `CAM` affects future codes only, and the fleet is mixed from then on. That is allowed, and anyone who wants a uniform fleet should decide the prefix before creating devices.

The prefix is **not** `thing_types.code`. That code is subject token 0 (`ip_camera`), frozen, and meant to be read in a subject. Shortening it to `CA` would make every subject unreadable to save two characters on a label.

### 2. Codes are generated on the server when left blank

**Format:** `PFX-XXX-XXX`, or `XXX-XXX` when the type has no prefix or the record has no type.

- **Alphabet:** 30 symbols. `A–Z` and `0–9` without `0 O 1 I 2 Z`, which leaves 23 letters and 7 digits.
- **Each chunk holds at least one letter and one digit.** This keeps a chunk recognisably a code and means a chunk can never spell a three-letter word. That leaves 14,490 valid chunks and about 210 million codes per prefix per organization.
- **Random, from `crypto/rand`.** Not sequential.
- **Uppercase.** Generated codes are always uppercase. Stored codes keep the case they were entered in (rule 3).

**Where it runs:** one Go implementation in a create hook on `things` and `locations`. When `code` is blank, the hook generates one, checks it against **both** collections in the organization, and retries on a collision. Checking both means a generated code never clashes with a Thing or Location code, with or without a prefix. Its errors must be `apis.NewBadRequestError`, for the reason ADR 0002's [As implemented](./0002-organization-code-namespace.md#as-implemented) gives: a plain error reaches the client as a bare "Failed to create record."

**Installer-supplied codes still work unchanged.** `DOOR-1`, stencilled on the hardware, is still the right code for that door. The validator pattern `^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$` does not change. The generator is the default, not a rule every code must follow.

**Locations prefer an installer code.** `RM-204` is on the door, and a location code sits in the middle of subjects and paths where a human reads it. Location generation exists so that no Location is ever left without a code ([ADR 0004](./0004-long-term-data-and-location-path.md) needs every Location to have one), not because random is better for sites.

**This removes blank codes for Things and Locations.** This amends ADR 0002 rule 2 for these two collections: presence is now guaranteed by the hook, the same technique `organizations.code` uses, not by `required` in the schema. The unique indexes stay partial, which is harmless.

**Clients get codes from the server, not their own generator.** `GET /api/codes/suggest?kind=thing|location&type=<type id>&count=<n>`, available to the roles that can create the record (owner, admin, member), returns up to 500 codes that are not in use when they are returned. Suggestions are **not reserved**: in a space of about 210 million per prefix, a clash between suggesting and creating is negligible, and if one happens the unique index refuses the create and the client asks again. The UI form uses the endpoint to pre-fill the code field. `stone code suggest --type ip_camera -n 50` uses it to pre-print a pallet's labels before the devices are registered. *(Amended: the endpoint shipped and was then removed. See [As implemented](#as-implemented).)*

### 3. Codes keep their case; uniqueness and human lookups ignore it

- **Stored as entered.** Subjects, permissions and twin keys use the stored string, character for character. NATS stays case-sensitive, and nothing about that changes.
- **Unique ignoring case.** Rebuild the four indexes as `(organization, code COLLATE NOCASE) WHERE code != ''`. SQLite's `NOCASE` folds only ASCII, which is all the code pattern allows.
- **Human lookups ignore case; machine paths don't.** The Scanner widget, the label manual-entry field and `stone`'s code-based lookups match regardless of case (for example with PocketBase's `:lower` modifier) and then use the stored spelling. Subject resolution and permissions stay exact.

Organization codes are already lowercase-only (ADR 0002 rule 1) and are unaffected.

### 4. A record's type is frozen once set

Add to the update rules:

- `things`: `(type = "" || @request.body.type:changed = false)`
- `locations`: `(type = "" || @request.body.type:changed = false)`

A blank type can be set once. A set type can't be changed. Together with the frozen code, this means a prefix can never contradict the record, and a Thing's default subject depends only on values that can't change.

**A wrong type is fixed by deleting and recreating the record.** The type is chosen at creation, and that is when mistakes are caught. Two notes:

- **The recreated record should get a new code.** A deleted record's code is free again as far as the partial index is concerned. Reusing it gives the new record the old one's subjects, twin keys and stored history. A generated code avoids this by default. Typing the old code back by hand is the case to warn about.
- **Deleting and recreating is only cheap before the device is set up.** Once a NATS user, a Nebula host or a printed label exists, recreating means reissuing each of them. That is acceptable for correcting a mistake.

### 5. The default subject is `{thing_type_code}.{thing}`

An empty `subject_prefix` resolves to `{thing_type_code}.{thing}`, and the operation suffix follows as before: `ip_camera.CA-9KD-4PX.motion`.

- **Uniqueness never needed the location.** Thing codes are unique within the organization, and the organization is the NATS account.
- **Location stays available, as an explicit choice.** `{location}` remains a supported template variable. A Thing Type for fixed equipment (the freezers at `KC-DC1`, a building's air handlers) can still set `subject_prefix: freezer.{location}.{thing}`, and the docs describe that as a deliberate choice for things that don't move.
- **Location as data.** A device that knows where it is (a trailer with GPS) reports that in its payload under its message schema. For everything else, location is joined downstream from inventory, as described in [ADR 0004](./0004-long-term-data-and-location-path.md).
- **The Agent is no longer an exception.** `agents.{code}` is now the same shape as every other subject.

### 6. Subject layout past the default is guidance, not policy

The docs suggest one layout and say plainly that the account owner decides:

> Token 0 is a **kind**: a Thing Type code, `agents`, or an application identifier. Token 1 is the **code** of the thing or instance. Everything after that belongs to the kind. Applications use a bare `{app-identifier}.…`, the same shape as Thing Types.

The platform enforces only two things: how an empty prefix resolves, and the character rules that make a code a safe token. An application identifier and a Thing Type code share token 0. The same organization admin controls both, so a clash would be self-inflicted and visible to them, and we don't police it. The demo's `app.{kind}.{thing}.{operation}` becomes `{kind}.{thing}.{operation}` (`wms.…`, `rules.…`). *(Amended: the demo keeps `app.`. A bare `kiosk.{thing}` would have put the kiosk controller inside the kiosk nodes' own tree. See [As implemented](#as-implemented). The rule itself stands: both shapes are guidance.)*

---

## Why random, and why no check digit

A check digit catches typos by making most mistyped strings invalid. **A sparse random space does the same thing for free.** An organization with a thousand cameras uses about 0.0005% of the 210 million codes under `CA`, so almost every mistyped code matches nothing, and the scanner says "not found" and not "here is some other camera". Sequential codes are the opposite: every typo near the sequence lands on a real record.

A check digit would add a rule to explain, a character to read aloud, and a validation path installer-typed codes would have to skip. Randomness gives most of the benefit at none of the cost.

## Why ignore case in uniqueness when NATS doesn't

NATS being case-sensitive is the reason, not an objection. Because `camera.cam-1` and `camera.CAM-1` are different subjects, two records whose codes differ only by case would get two working namespaces that nobody can tell apart by ear. Each works on its own, so nothing ever errors. Ignoring case in uniqueness stops the second record from existing. It doesn't change any subject, because the stored spelling is the only spelling.

The stricter alternative, uppercasing every code on save, was rejected: it drops the deliberate mixed-case rule in [What a code may contain](../thing-types.md#what-a-code-may-contain) to fix a problem that the index already fixes.

## Why one generator on the server

`ui/src/utils/subjectResolver.ts` carried a header comment claiming it mirrored a Go package that was never written. Two generators, one in Go and one in TypeScript, would drift the same way, and a code is frozen and printed, so drift here is permanent. One implementation behind a hook means the UI, `stone`, the API and any future client produce the same codes, and only the server can check a code against existing records.

---

## Implementation order

1. **Case-insensitive unique indexes** on `things`, `locations`, `thing_types`, `location_types`. There is no data to sweep.
2. **`prefix` on both type collections:** field, pattern validator, partial unique index, and the cross-collection hook.
3. **Generator:** a Go package, create hooks on `things` and `locations`, and `GET /api/codes/suggest`. *(Amended: removed after it shipped.)*
4. **Type freeze** in the `things` and `locations` update rules.
5. **Default subject:** `DEFAULT_PREFIX` in `subjectResolver.ts` and its spec, the help text in `ThingTypeFormView.vue`, and a check of `PublisherWidget.vue`.
6. **Demo:** `internal/demoseed` (contract, inventory, tests), `demo/rules/northwind`, `demo/telegraf`. Keep `{location}` on the fixed-equipment types so the demo shows both layouts. Move apps from `app.{kind}` to bare `{kind}`. *(Amended: not done; see [As implemented](#as-implemented).)*
7. **`stone`:** code-based lookups ignore case; add `stone code suggest`. *(Amended: dropped with the endpoint.)*
8. **Docs:** `thing-types.md`, `connectivity.md`, `platform-ui-entities.md`, `stone-cli.md`, and the Agent note in `connectivity.md`, which stops being an exception.

---

## Consequences

### Good

- Every Thing and Location has a code, so every one can have a label and a stable subject token.
- A mistyped code almost always gives "not found", never a confident wrong record.
- Moving a Thing changes nothing about its subjects or its NATS permissions.
- A code, its prefix and its subject can never contradict the record.
- One subject shape for devices, the Agent and applications.

### Costs we are accepting

- **No site-scoped subject patterns by default.** `camera.chi-w-a.>` used to mean "every camera at Chicago" in one pattern, for subscriptions, streams and **NATS permissions**. The first two can filter on data instead. Permissions can't, because NATS authorizes on subjects and never looks at payloads. A deployment that needs a site-local identity limited to one site's devices opts into `{location}` for those types.
- **Generated codes mean nothing to a person.** `CA-9KD-4PX` says "camera" and nothing else. Dashboards and legends need the record's name next to the code, and [ADR 0004](./0004-long-term-data-and-location-path.md) carries it.
- **Retyping means delete and recreate**, with reissued credentials once the device is set up.

### The sharp edge

**A Thing Type's own `subject_prefix` is still editable.** Freezing `things.type` fixes which template a Thing uses, but not what the template says. Editing a Thing Type's prefix moves the subjects of every instance at once. That is out of scope here and worth deciding before there is production data behind it.

---

## What would make us revisit this

- **Site-scoped NATS permissions turn out to be common, not rare.** If most deployments opt back into `{location}`, the default is wrong for them and should say so.
- **An organization outgrows a prefix's code space.** At about 210 million codes per prefix this is theoretical; the fix would be the article's eight-character format.
- **Retyping turns out to be routine.** If delete-and-recreate becomes a weekly chore, a type change needs a supported path that reissues everything derived from the type.

---

## Rejected alternatives

- **Encoding location in a Thing code** (`WHA-CAM-042`). Things move, and a code is frozen and printed. It buys nothing in NATS either: a wildcard matches whole tokens, so `camera.WHA-*.>` is a literal string, not a pattern.
- **Using `thing_types.code` as the prefix.** That code is subject token 0 and meant to be read there.
- **A check digit.** Sparsity does the job; see [Why random](#why-random-and-why-no-check-digit).
- **Sequential generated codes.** Every typo becomes a real record.
- **Client-side generators.** Two implementations drift, and only the server can check for collisions.
- **Uppercasing every code on save.** It reverses the deliberate mixed-case rule to fix a problem the index already fixes.
- **Requiring a prefix.** A blank prefix costs nothing; the generator produces `XXX-XXX`.
- **A location twin key maintained by the platform.** The platform writes only to the system account, so keeping a per-organization KV key current would mean every client chaining an HTTP call and a NATS call on every move, with no recovery when the second fails. See [ADR 0004](./0004-long-term-data-and-location-path.md).
- **A reserved `app.` root for applications.** It protects against a clash that only the organization's own admin can cause, and it costs every application a token.

---

## As implemented

Shipped in the platform as one change: `hooks/codes.go`, `migrations/schema_update_type_prefixes.go`, the `things` and `locations` update rules, `ui/src/utils/subjectResolver.ts`, and the forms. `scripts/test-authz.sh` section 24 covers the rules against a live server.

**The suggest endpoint was removed.** `GET /api/codes/suggest` shipped with this change and was taken out before any release. Its only use was having a code in hand before the record existed, to write on a device or pre-print labels. Both are covered without it: a blank code is generated at save, and the Things list prints labels for every record in the current filter once they exist. What it cost was a route, an authorization surface to test, and a button on the Thing form. With it gone there is no way to get a generated code ahead of its record, and nothing needs one. `stone code suggest` is dropped with it.

**The demo keeps its `app.` root.** Rule 6 had the demo move from `app.{kind}.{thing}` to a bare `{kind}.{thing}`. For the kiosk controller that means `app.kiosk.{thing}` becoming `kiosk.{thing}`, which is the kiosk nodes' own tree:

- The kiosk stream binds `kiosk.*.event.>`, and the Thing Type screen would render the controller's subjects as if it were one more kiosk node.
- A role granting kiosk nodes `kiosk.*.>` would match the controller's code too.

Nothing in rule 6 required the move. It says subject layout past the default is guidance, and a grouped `app.{app}.…` root is as valid as a bare identifier. The demo shows the grouped shape; [Thing Types](../thing-types.md#subject-layout-past-the-default-is-guidance) describes both. The rejected alternative below still holds as platform policy: the platform reserves no `app.` token. Every demo type already sets an explicit prefix, so the new default subject changed none of them.

**Operation suffixes already accepted variables.** Consumers join a prefix and a suffix before resolving, so `{thing}`, `{location}`, `{org}` and `{thing_type_code}` resolve in a suffix exactly as in a prefix. That was true before this ADR and documented nowhere; [Thing Types §3](../thing-types.md#reserved-variables) now says so. An application tree such as `acc.{location}.door.{thing}` with suffixes like `cmd.grant` therefore needs nothing new.

**The Thing form's email preview used the organization's name.** It slugified the name, the same mistake `orgSlugFor` made before ADR 0002. It now shows the organization code, which is what the route uses.

**Two small additions.** The Scanner widget's filter accepts `{value:lower}`, so `code:lower = "{value:lower}"` finds a code typed in the wrong case. The Thing Type form's subject-prefix help printed `{'{org}'}` literally, a JSX habit in a Vue template, and now prints `{org}`.

**The migration runs before `schema_update_unique_org_code` on a fresh database**, because PocketBase orders migrations by file name. It is harmless: both re-import the same `schema.json`.

**Existing blank codes are not backfilled.** A code is frozen the moment it exists, so a migration generating codes for old records would be choosing permanent identifiers on nobody's behalf. The migration logs how many Things and Locations have none.

**Not done: `stone` (step 7).** `thing provision` still requires `--code`, neither type entity has a `--prefix` flag, and code lookups still match case exactly. (`stone code suggest` is no longer part of it.) A `thing create` or `location create` without `--code` already gets a generated code, because that goes through the record API and the create hook.
