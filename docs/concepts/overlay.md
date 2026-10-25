---
path: concepts/overlay
nav_order: 50
---
# Overlay Network

Stone-Age.io uses **Nebula** to reach devices on IP, for jobs such as SSH, a
camera's web page or a controller's admin port. Nebula builds an encrypted
network on top of the networks the devices already use. This page explains
overlay addresses, certificates, discovery, firewall groups and revocation. For
the platform's Nebula settings, see [Connectivity §2](../connectivity.md#2-nebula).
For the full detail, see the [Nebula documentation](https://nebula.defined.net/docs/).

---

## 1. Underlay and overlay

| Network | What it is | Example address |
| :--- | :--- | :--- |
| **Underlay** | The real network that carries the packets: a LAN, cellular or the internet. | `203.0.113.7`, `192.168.1.40` |
| **Overlay** | A virtual network on top of the underlay. Each host gets one address that stays the same wherever the host is. | `10.42.0.15` |

Each Nebula host has a virtual network interface, `nebula1` by default. Traffic
to an overlay address goes into that interface. Nebula encrypts it and sends
it as UDP packets over the underlay. After two hosts connect, the packets go
directly between them, with no central VPN server in the path.

In Stone-Age.io, the overlay is IPv4 only.

---

## 2. Certificates

Nebula uses certificates instead of passwords or shared keys.

1. A **Certificate Authority** (CA) is a key pair and a certificate that signs
   itself. It signs the certificates of hosts.
2. Each **host** has its own key pair. Its private key never leaves the host
   config.
3. The CA signs a **host certificate**. The certificate holds the host's public
   key and these facts about the host:

| In the certificate | What it means |
| :--- | :--- |
| Name | The hostname |
| Overlay IP | The host's address on the overlay, with its network |
| Groups | Names for firewall rules, such as `admins` or `sensors` (§4) |
| Unsafe networks | Subnets behind the host that it may route to |
| Validity | The dates between which the certificate is valid |

### The handshake

When two hosts connect, each sends its certificate. Each host checks three
things about the other certificate:

- A CA that this host trusts signed it.
- It is still valid.
- It is not on this host's blocklist (§5).

**Both hosts make the checks.** Then they agree on keys and encrypt the
traffic.

Because the facts are in the certificate, a host cannot claim a group or an
address that the CA did not sign. This also has a cost. A change to the name,
overlay IP, groups or unsafe networks applies only after the host gets a new
certificate.

::: warning A change to groups does nothing until the host has a new certificate
Firewall *rules* are config. Group *membership* is in the certificate. If you
change a host's groups, peers apply the old groups until the host gets a new
certificate and loads it. In Stone-Age.io, use **renew** on the host, then let
it fetch its config. See
[Connectivity §2](../connectivity.md#host-based-firewalls).
:::

**In Stone-Age.io:**

- Each Organization has its own CA. A CA can have one or more networks. Each
  host belongs to one network. Hosts trust only hosts from the same CA.
- The platform makes each key pair and signs each certificate. A host's
  `config_yaml` holds its private key, so only Owners and Admins can read hosts.
- Certificates use Curve25519. A new CA is valid for 10 years by default. A
  host certificate always expires, and it never outlives its CA.

---

## 3. Lighthouses and relays

Most edge devices are behind NAT, with no fixed public address. Nebula uses
two kinds of helper host:

- **Lighthouse:** a host with a fixed public address. Each host tells the
  lighthouse its current underlay address. A host that wants to reach a peer
  asks the lighthouse where the peer is. Then the two hosts send packets to each
  other at the same time, to open a path through both firewalls. This is called
  *hole punching*.
- **Relay:** a host that carries packets for two peers that cannot connect
  directly. Some strict networks block hole punching.

A lighthouse knows *where* a host is. A relay carries *packets*. One host can do
both jobs. See
[Connectivity §2](../connectivity.md#lighthouses-discovery).

Every host connects out to the lighthouse. No device needs an open inbound port
([Connectivity §3](../connectivity.md#3-outbound-only-connections)).

---

## 4. Firewall by group

Each Nebula host has its own firewall. Nebula drops each packet that no rule
allows. A rule can match a port, a protocol, a host, a CIDR or a **group**.

```yaml
firewall:
  outbound:
    - port: any
      proto: any
      host: any
  inbound:
    - port: 22
      proto: tcp
      group: admins
    - port: 443
      proto: tcp
      group: gateways
```

On this host, peers in the `admins` group can use SSH, and peers in the
`gateways` group can reach port 443. The host drops all other inbound packets.

A group rule works because the CA signed the group into the peer's
certificate (§2). The rule trusts the CA, not an IP address. So the rule stays
correct when a peer moves to a new network.

A host can also route to a subnet that is not on the overlay, such as a camera
VLAN. This needs settings on two kinds of host. See
[Connectivity §2](../connectivity.md#reaching-subnets-that-are-not-on-the-mesh).

---

## 5. Revocation and expiry

**Nebula has no certificate revocation list (CRL) service.** Each host has a
**blocklist** in its own config: the fingerprints of certificates that it must
refuse. A revocation applies on each peer when that peer loads its new config.

**In Stone-Age.io:**

- Deactivating a Thing adds its certificate's fingerprint to the blocklist of
  every host under the same CA.
- The Agent reads its config every `nebula.sync_interval`. That interval is the
  longest time a peer can still accept a revoked certificate. See
  [The Agent §2](../agent.md#the-lifecycle-of-a-thing).

**Every certificate expires.** A fleet that you provisioned at the same time
expires at the same time. An expired fleet also loses the overlay path that you
would use to repair it. Reissue certificates before the date. See the
[Operations checklist](../operations.md#7-production-checklist).

::: danger Delete does not revoke
A deleted Thing's Nebula certificate stays trusted, and after the delete it can
no longer go on a blocklist. To take a device out of service, deactivate it.
See [Authorization §4.2](../authorization.md#42-taking-a-device-out-of-service).
:::

### Replacing a CA

Both hosts check certificates in a handshake, and hosts pull their config at
different times. So a CA cannot change in one step. If it did, a host with a
new certificate would meet a host that trusts only the old CA, and both
checks would fail. Stone-Age.io replaces a CA in three steps:

1. Trust the new CA everywhere.
2. Sign every host with the new CA.
3. Remove the old CA.

See [Authorization §4.3](../authorization.md#43-rolling-a-nebula-ca).

---

## 6. Nebula and NATS

A device can use both networks. Each one does a different job:

| | NATS | Nebula |
| :--- | :--- | :--- |
| **Carries** | Messages between applications | IP packets between hosts |
| **Identity** | A user JWT, signed by the account | A certificate, signed by the CA |
| **Access control** | Subject permissions | Firewall rules on groups |
| **Revocation** | The account's revocation list | Each peer's blocklist |
| **Use it for** | Telemetry, events, commands and live state | SSH, web pages, admin ports and protocols that are not NATS |

Revoke a device on both networks. Deactivating a Thing does both
([Authorization §4.2](../authorization.md#42-taking-a-device-out-of-service)).

---

## 7. Where to Go Next

- The platform's Nebula fields and settings: [Connectivity §2](../connectivity.md#2-nebula)
- The other identity on each device: [NATS Security](./nats-security.md)
- Who can read hosts and roll a CA: [Authorization](../authorization.md)
- How the Agent runs Nebula on a device: [The Agent](../agent.md)
- CA rotation and the certificate audit: [Stone CLI](../stone-cli.md#nebula-operations-that-are-not-record-writes)
