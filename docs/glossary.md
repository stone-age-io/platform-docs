---
path: platform/glossary
nav_order: 20
---
# Glossary

The docs use these fourteen names with exact meanings. Do not interchange them.

| Name | What it means | What it is *not* |
| :--- | :--- | :--- |
| **Stone-Age.io** (or "the platform") | The whole system: every component, plane and layer. | Not a single binary or component. |
| **Control Plane** | The management component, the `stone-age` binary. Identity, inventory, provisioning and the API. | Not the whole platform, and not the UI. |
| **Stone Age Console** (or "the console") | The Vue web UI inside the Control Plane binary. | Not the security boundary. It shows what the API rules already permit. |
| **`stone`** | The client CLI you run from a laptop or CI runner. | Not the server. See [Stone CLI](./stone-cli.md). |
| **Data Plane** | The runtime: NATS, JetStream, KV and Nebula, in [four layers](./platform-layers.md). | Not run by the Control Plane. The Control Plane provisions it, and then it runs on its own. |
| **NATS Operator** | The root key and JWT of the NATS trust chain. The Control Plane holds it and signs each organization's NATS Account with it. Config key: `operator_name`. | Not a person. Nobody signs in as the NATS Operator. |
| **Platform Operator** | A user account with `is_operator = true`. Creates and edits Organizations, invites users into any org, reads the audit log. | Not a tenant role. It is a flag on the user, separate from any Membership. |
| **the provider** | Whoever runs this deployment for its tenants: an MSP, an integrator or an internal IT group. | Not a database record. The provider's own organization is the one `--operator-org` creates. |
| **operator organization** | The provider's own Organization, which `--operator-org` creates (`is_operator_org`). The first Platform Operator works in it. | Not the NATS Operator, and not a tenant you can suspend or delete. |
| **System organization** | The Organization that `bootstrap` links to the NATS System Account (`is_system_org`). Use it for cluster-level NATS work only. It has no JetStream. | Not a place for daily work, devices or dashboards. |
| **hub account** | The operator organization's NATS Account. Shared provider services run in it, and a managed organization's export arrives in it. | Not "the hub", which is the central NATS server or cluster that leaf nodes connect to. |
| **managed organization** | An Organization with the `managed` flag. The platform exports its `nats.managed_export_subject` subtree into the hub account, with the organization's code in the subject. | Not a different level of isolation. Only that one subtree crosses the account boundary. |
| **site** | A physical place you manage: a building, a campus, a store or a colo cage. It is a [Location](./platform-ui-entities.md#2-locations), at the level the map draws one pin for. Its devices can reach the platform through a gateway, through a vendor's cloud or directly. It is the same site whichever way they connect. | Not a Thing, a gateway or a leaf node. A campus with three gateways is one site. A VPS or a cloud network is not a site. |
| **gateway** (site gateway) | A Thing whose Agent runs a leaf node, so the devices behind it keep working when the link to the hub fails. Usually a box at a site. It can also be a VPS or a VM in a cloud network. | Not a site, and not a record type. Nothing in the schema marks a Thing as a gateway ([Leaf Nodes §1](./leaf-nodes.md#1-there-is-no-gateway-flag)). |

"The platform does X" means the whole system. "The Control Plane does X" means
that binary.

A site is a place and a gateway is a box. "A site's leaf node" or "a site's
Agent" means the one on that site's gateway. A site can have several gateways,
or none.

"Operator" always has a qualifier: **NATS Operator** for the key, **Platform
Operator** for the person. Bare "operator" appears only in identifiers you type
or configure, such as `is_operator`, `operator_name`, `--operator-org` and
`operator_jwt`.

These terms come from NATS or the data model. The docs use them without
explanation. For the NATS terms, [Concepts](./concepts/index.md) explains how
each one works.

| Term | What it means | More |
| :--- | :--- | :--- |
| **Thing** | A record for anything that produces or consumes data, or an asset you want to track. It is an auth record, and it can carry the device's NATS and Nebula identities. | [Platform Entities §3](./platform-ui-entities.md#3-things) |
| **Account** (NATS Account) | The tenant boundary on the bus. Each Organization has one, signed by the NATS Operator. Another account cannot see its subjects, streams or buckets unless an export and an import share them. | [Architecture §3](./architecture.md#3-multi-tenancy-infrastructure-isolation) |
| **subject** | The dot-separated name a NATS message is published to, such as `camera.CA-9KD-4PX.motion`. Subscribers match subjects with wildcards: `*` matches one token, `>` matches all remaining tokens. NATS permissions are lists of subjects. | [Connectivity §1](./connectivity.md#core-pubsub-subject-namespacing) |
| **JetStream** | The NATS persistence layer. A **stream** stores the messages on chosen subjects, so consumers can read history. Core NATS stores nothing. | [Connectivity §1](./connectivity.md#jetstream) |
| **KV** (key-value bucket) | A JetStream stream used as a key-value store. It keeps the latest value for each key. The twin is in KV. | [Connectivity §1](./connectivity.md#key-value-buckets-live-state) |
| **leaf** (leaf node) | A NATS server that connects out to the central cluster, usually at a site. Local devices keep working when the link is down. It runs on a gateway. | [Leaf Nodes](./leaf-nodes.md) |
| **domain** (JetStream domain) | The name that separates the JetStream data on one server from another's, so a leaf and the hub can each have a bucket with the same name. A leaf's domain is its Thing's code. | [Leaf Nodes §3](./leaf-nodes.md#the-domain-is-the-code-computed-and-never-stored) |
| **twin** (reported / desired) | The live state of a Thing or Location, in two KV buckets with one writer each. `twin` holds **reported** state, written by the device. `twin_desired` holds **desired** state, written at the hub by people and rules. The platform delivers a desired value but does not apply it. | [Architecture §4](./architecture.md#4-the-digital-twin-concept-live-state) |
