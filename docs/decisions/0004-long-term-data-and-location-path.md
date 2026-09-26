# ADR 0004: Long-Term Data Carries Codes; Location Comes From Inventory

**Status:** Proposed
**Date:** 2026-09-25

> This ADR follows from [ADR 0003](./0003-human-friendly-codes-and-default-subject.md), which takes location out of the default subject. It decides where long-term trending gets a Thing's location from once the subject no longer carries it. The platform's dashboard widgets are for short-term views and interaction and aren't affected. This is about the Time-Series Database behind [Layer 3](../observability.md).

> The pipeline below uses the tenant's existing tools: nats-auth-manager and rule-router from the `rule-router` repo, and Telegraf. It is written so the demo doubles as a worked example of all three.

---

## Context

Long-term trending lives in a TSDB. The demo uses VictoriaMetrics, fed by Telegraf from NATS and read by Grafana or Perses. The demo Telegraf config tags every reading with `location` by reading subject token 2. After ADR 0003 there is no token 2 to read.

Every obvious replacement fails for a concrete reason:

- **A twin key per Thing, `thing.<code>.location`.** The platform writes only to the system account, not to each organization's account. Keeping the key current would mean the UI and `stone` each chaining an HTTP call and a NATS call on every move, with no recovery when the second call fails, and any other API client would skip it entirely.
- **Tagging readings with location at ingestion.** Most devices don't know where they are, because location is a record someone assigns in the platform. Even where the tag could be computed, it is fixed forever: correcting a wrong location never reaches readings already stored.
- **A lookup inside Telegraf.** `processors.lookup` and `processors.enum` load static mappings at startup. Starlark has no network access. `processors.execd` could poll PocketBase, but it puts a PocketBase credential into Telegraf and makes ingestion depend on the app.
- **A custom inventory endpoint with its own scrape token.** It works, but it's a new route, a new credential type and a new security surface, to deliver data the standard list API already returns.

And one gap sits under all of them: **the location tree has no path.** `locations.parent` is a single relation. "Every Thing under building BD-3" needs recursion, which neither the PocketBase filter syntax nor PromQL has.

---

## Decision

Six rules.

### 1. Readings carry only codes that never change

Telegraf tags each reading with **`kind`** (subject token 0) and **`thing`** (token 1). Both are frozen after ADR 0003. The tag is `kind`, not `thing_type`, because under ADR 0003 rule 6 an application's token 0 is an app identifier. Devices and applications now share one subject shape, so the demo's two-block Telegraf config (which exists only because the location slot made the shapes differ) collapses to one parser.

No location is added at ingestion. A device that knows its own location reports it in its payload, as ordinary data.

### 2. Locations store a path

`locations.path` is computed by the server and holds codes from the root down to the location itself:

```
/KC/                 campus
/KC/BD-3/            building
/KC/BD-3/RM-204/     room
```

- **`/` delimits, and appears at both ends.** Codes can't contain `/`, so a segment is never ambiguous. The leading and trailing slashes make `/BD-3/` match only that code, never `BD-30`.
- **Only the server writes it.** A create/update hook sets `path` to the parent's path plus the location's own code. The update rule refuses `@request.body.path:changed` from clients.
- **Only moving a location under a different parent changes a path.** Codes are frozen (ADR 0002) and never blank (ADR 0003 rule 2), so the hook only has real work to do when `parent` changes. It then rewrites the path of every location underneath in the same transaction, by replacing the old prefix. Compare the prefix with `substr(path, 1, length(:old)) = :old`, **not** `LIKE`: codes may contain `_`, which is a `LIKE` wildcard.
- **The hook refuses cycles.** A new parent whose path starts with the location's own path would make the location its own ancestor.
- **Deleting a parent must recompute its children.** Whatever PocketBase does to the children's `parent` relation when their parent is deleted, their paths must follow. How that interacts with record hooks needs checking during implementation.

A path also helps outside the TSDB. "Everything under BD-3" becomes one PocketBase filter, `location.path ~ '/BD-3/'`. (The same `_` caveat applies: `~` is `LIKE`, so an `_` in a code matches any character. It rarely matters, because both slashes still have to match.)

### 3. Inventory becomes two info series

The standard Prometheus "info metric" pattern: one series per record, value `1`, with metadata carried as labels.

| Series | Labels |
|---|---|
| `stone_thing_info` | `thing`, `name`, `thing_type`, `location`, `location_path` |
| `stone_location_info` | `location`, `name`, `location_type`, `location_path` |

**A label goes on only if you'd group by it, filter by it, or show it in a chart legend.** `name` qualifies above all: after ADR 0003 a code is `CA-9KD-4PX`, and a legend should say "Dock 3 camera". `stone_location_info` gives location names to legends and gives Grafana variables a list of locations of one type.

Out of scope for now:

- **`metadata`.** It's free-form JSON. Flattening it would produce label names nobody controls, invalid characters and nested values, plus a new series every time someone edits it. You also couldn't tell which labels are ours. If a real dashboard needs a metadata field, add an explicit allowlist at that point.
- **Serials and other asset details.** You look these up; you don't chart them.

### 4. The pipeline stays inside the tenant's account

```
nats-auth-manager ──► KV tokens.pocketbase            logs in as a viewer, refreshes the token
rule-router, schedule rule, every minute:
    GET PocketBase list API ──► publishResponse ──► inventory.things
rule-router, router rule on inventory.things:
    forEach item, merge {"info": 1} ──► inventory.thing.<code>
Telegraf nats_consumer on inventory.thing.> ──► VictoriaMetrics  (stone_thing_info)
```

The same pair of rules on the `locations` collection produces `stone_location_info`.

- **A dedicated service user with the `viewer` membership**, one per organization, with its `current_organization` set to that organization. Every list rule scopes reads by it. Its password lives only in nats-auth-manager's environment. The token it stores is readable by anyone who can read the `tokens` bucket, so restrict `$KV.tokens.>` in NATS permissions.
- **A standard API call with one level of `expand`.** Because each location stores its own path, one level is enough. No custom route.
- **The whole inventory is resent every minute.** Nothing is stateful. If Telegraf misses a poll, the next one covers it, and a moved Thing's new location appears within a minute.
- **`forEach` with `merge`, not a templated payload.** Each record is republished as it came, with `info: 1` added. No string templating means a name containing quotes can't break the JSON. The `info` field gives Telegraf a field to write, and VictoriaMetrics names the series `{measurement}_{field}`, which is `stone_thing_info`.

Sketches. These are not tested; the demo is where they get checked.

```yaml
# rule-router: poll, then fan out
- trigger:
    schedule:
      cron: "* * * * *"
  action:
    http:
      url: "${PB_URL}/api/collections/things/records?perPage=500&expand=location,type&fields=code,name,expand.location.code,expand.location.path,expand.type.code"
      method: GET
      headers:
        Authorization: "{@kv.tokens.pocketbase}"
      publishResponse:
        subject: "inventory.things"

- trigger:
    nats:
      subject: "inventory.things"
  action:
    nats:
      forEach: "{items}"
      subject: "inventory.thing.{code}"
      merge: true
      payload: '{"info": 1}'
```

```toml
# Telegraf: one metric per record
[[inputs.nats_consumer]]
  subjects = ["inventory.thing.>"]
  data_format = "json_v2"
  [[inputs.nats_consumer.json_v2]]
    measurement_name = "stone_thing"
    [[inputs.nats_consumer.json_v2.tag]]
      path = "code"
      rename = "thing"
    [[inputs.nats_consumer.json_v2.tag]]
      path = "name"
    [[inputs.nats_consumer.json_v2.tag]]
      path = "expand.type.code"
      rename = "thing_type"
    [[inputs.nats_consumer.json_v2.tag]]
      path = "expand.location.code"
      rename = "location"
    [[inputs.nats_consumer.json_v2.tag]]
      path = "expand.location.path"
      rename = "location_path"
    [[inputs.nats_consumer.json_v2.field]]
      path = "info"
      type = "int"
```

### 5. Dashboards join against current inventory

```
avg by (location) (
  thing_temperature
    * on(thing) group_left(name, location, location_path)
      (stone_thing_info @ end())
)
```

`@ end()` reads the inventory once, at the end of the time range, and applies it to every reading in the range.

- **No reading is lost when a Thing moves.** Only the location it is *attributed* to follows the Thing to where it is now.
- **Corrections apply backwards.** Fix a wrong location and every past reading picks up the right one.
- **Readings from before polling began still join,** because the join doesn't need an info sample at each reading's timestamp.

"Where was it on Tuesday" is deliberately not the default; see [Why not attribute readings to where they were](#why-not-attribute-readings-to-where-they-were).

### 6. Three Grafana patterns, and no `label_replace`

| Want | How |
|---|---|
| Everything under one ancestor | `stone_thing_info{location_path=~".*/$site/.*"}`. PromQL regexes must match the whole value, so the pattern needs `.*` at each end. Codes contain only `A-Z a-z 0-9 _ -`, none of which are special in a regex. |
| One line per location inside it | That filter, plus `avg by (location)`. |
| Buildings side by side | A `$building` variable from `label_values(stone_location_info{location_type="building"}, location)`, and a **repeated panel**, each panel filtering by path. |

Comparing an ancestor level in a *single* query (every building as one series each, in one panel) would need `label_replace` with a depth-fixed regex. We don't ship that. If a real dashboard needs it, the next step is a type-named ancestor label (`loc_building="BD-3"`), not a regex.

---

## Why not attribute readings to where they were

Joining each reading against the inventory *at its own timestamp* would keep history as it happened: readings before a move under the old site, readings after under the new one. It breaks in this pipeline for a mechanical reason.

The info series is **pushed**, not scraped. A scraper writes a staleness marker the moment a series disappears. A pushed series just stops getting samples, and VictoriaMetrics keeps matching it for its lookback window. For a few minutes after a move, both the old-location and new-location series exist for the same `thing`, and `group_left` refuses the join with a duplicate-series error. It does this **for every query whose range covers the move**, not just for those few minutes: a seven-day by-site panel keeps failing for as long as the move is inside its range.

Working around that takes a trick that picks the newest info series for each `thing`. It is clever, it is one more thing to explain, and most dashboards want the current location anyway. A Thing whose past location matters (a trailer) should report its location in its own payload, where it is the reading's own data and not a join.

## Why a stored path and not something cleverer

- **Numbered levels (`l1`, `l2`, `l3`)** are easy to compute, but the names mean nothing, and level 3 is a city in one branch and a room in another.
- **Type-named ancestor labels (`loc_building`)** read well, but they need a custom route or a Starlark script to compute, label names cleaned up from type codes, and a rule for types that repeat in one chain. They stay available as the next step.
- **Chained joins** against a `location_info{location, parent}` series are unreadable after the second join.
- **A path** is one text field, one hook and one transaction on a re-parent. The standard list API returns it, a regex filters on it, and a person can read it.

---

## Limits to know

- **One poll returns a limited number of records.** PocketBase caps `perPage`, and `publishResponse` caps a response at 1 MB, which is a few thousand records. A larger organization needs paging. Until then, a guard rule on `inventory.things` should publish a warning when `totalItems` exceeds `perPage`, so a truncated inventory is visible and not silent.
- **A move takes up to a minute to show.** That's the poll interval.
- **If the platform is down, the join has gaps.** Readings keep arriving, because Telegraf reads them from NATS. Only the inventory stops updating, and the join resumes on the next successful poll.

---

## Implementation order

1. **`locations.path`:** field, update-rule freeze against client writes, a create/update hook with subtree rewrite and cycle refusal, and handling for a deleted parent.
2. **Demo seed:** a `viewer` service user per demo organization.
3. **Demo rules:** poll and fan-out rules for `things` and `locations`, plus the truncation guard, in `demo/rules/northwind`. Add nats-auth-manager config beside them.
4. **Demo Telegraf:** collapse to one reading parser (`kind`, `thing`), and add the two inventory inputs.
5. **Demo dashboards:** one example each of the three patterns in [rule 6](#6-three-grafana-patterns-and-no-label_replace). Confirm that MetricsQL supports `@ end()`, and confirm the series names VictoriaMetrics produces.
6. **Docs:** [Observability](../observability.md) gains the inventory pipeline and the join. [Platform Entities & UI](../platform-ui-entities.md) documents `path`.

---

## Consequences

### Good

- Stored readings are never wrong, because they carry only codes that never change.
- Moving or correcting a location updates every dashboard within a minute, including history.
- No new platform route, credential type or background process. One field and one hook.
- The demo shows nats-auth-manager, the rule-router scheduler, `forEach` and Telegraf working together on a real problem.

### Costs we are accepting

- **Dashboards show where a Thing is now, not where it was.** Past attribution is the device's job or a later decision.
- **Comparing ancestor levels needs a repeated panel,** not a single query.
- **Each organization needs a service user,** plus a password in nats-auth-manager's environment.

### The sharp edge

**The `tokens` bucket holds a live PocketBase token.** It is a viewer's token, so it can read the organization's inventory but not change it. Anyone with read access to `$KV.tokens.>` has that read access too. Scope it in NATS permissions the same way you would scope the credential itself.

---

## What would make us revisit this

- **History as it happened becomes a requirement** for Things that can't report their own location. Then the newest-series filter, or a scrape-based info endpoint with real staleness markers, is worth its cost.
- **Inventory outgrows a single poll.** Then the fan-out needs paging.
- **Single-query comparison of ancestor levels is needed often.** Then add type-named ancestor labels.

---

## Rejected alternatives

- **A location twin key.** See [Context](#context).
- **Tagging readings with location at ingestion.** Devices don't know it, and tags can't be corrected afterwards.
- **A Telegraf lookup, Starlark or `execd`.** Static at startup, no network access, or a credential plus a dependency on the app, respectively.
- **A custom inventory route with a scrape token.** A new credential type to deliver what the list API already returns.
- **Joining at each reading's own timestamp by default.** Fails on duplicate series across any move; see [above](#why-not-attribute-readings-to-where-they-were).
- **Joining inside Grafana (transformations) against PocketBase.** Current location only, like our default, but grouping has to happen after the query, in a transformation, and every panel needs a second datasource.
- **Flattening `metadata` into labels.** Label names nobody controls and a new series on every edit.
