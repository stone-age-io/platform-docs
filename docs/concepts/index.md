---
path: concepts
nav_order: 5
access: public
---
# Concepts

These pages explain the technologies that every Stone-Age.io section depends
on. Each page explains one idea, shows how the platform uses it, and names the
mistake that people make most often. Then it links to the upstream
documentation for the full detail.

Read a page when a term in another section is new to you. You do not have to
read the pages in order, or before you start.

| Page | What it covers | Useful before |
| :--- | :--- | :--- |
| **[Messaging](./messaging.md)** | Publish and subscribe, subjects and wildcards, queue groups, request and reply, and what core NATS does not store. A table for readers who know MQTT. | [Connectivity](../connectivity.md), [Rule Router](../vendor/rule-router/README.md), [Access Control](../vendor/access-control/README.md) |
| **[NATS Security](./nats-security.md)** | Key pairs, JWTs, the trust chain from NATS Operator to Account to User, permissions, and revocation. | [Architecture §5](../architecture.md#5-the-chain-of-trust), [Authorization](../authorization.md), [The Agent](../agent.md) |
| **[Persistence](./persistence.md)** | JetStream streams, consumers and KV buckets, and how stored data crosses a leaf link. | [Leaf Nodes](../leaf-nodes.md), [Automation](../automation.md), [Observability](../observability.md) |
| **[Message Design](./message-design.md)** | How to shape subjects and payloads so they fit the platform's components: kinds of message, codes, JSON conventions, versions, duplicates and bad messages. | [Thing Types](../thing-types.md), [Automation](../automation.md), [Helpdesk protocol](../vendor/helpdesk/docs/protocol.md) |
| **[HTTP API](./http-api.md)** | PocketBase collections, records, tokens and API rules, and the SQLite database under them. | [API Reference](../api-reference.md), [Authorization](../authorization.md), [Operations](../operations.md) |
| **[Overlay Network](./overlay.md)** | Nebula: overlay addresses, certificates, lighthouses and relays, firewall groups, and revocation. | [Connectivity §2](../connectivity.md#2-nebula), [The Agent](../agent.md) |

---

## What belongs here

A Concepts page covers a technology or a pattern that also applies outside
Stone-Age.io, such as NATS, JWTs, PocketBase or Nebula. A name that exists only
in the platform, such as Thing, twin, org code or gateway, belongs in the
[Glossary](../overview.md#glossary).
