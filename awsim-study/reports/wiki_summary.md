# AWSIM / Autoware / Cyclone DDS — Fault-Injection Study Summary

This is a source-code study of how the communication
stack of an autonomous-driving simulation — AWSIM + Autoware Core over Eclipse Cyclone DDS — can be
configured, shut down, injected into, replayed against, prioritized, and silently disabled. It exists to
feed the design of a SEU: a device meant to sit on a real vehicle network
and detect or block exactly these faults.

---

## The system under study

Autoware Core runs in a Docker container with host networking (`--net host`); AWSIM (Unity, Shinjuku
map) runs natively on the same host. The two talk over loopback (`lo`), Cyclone DDS domain 0, with
multicast on `lo` carrying discovery. `RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` is forced on both sides —
no other DDS vendor is relevant anywhere in this study. Two client bindings sit on the same Cyclone core:
Autoware's `rclcpp` C++ nodes and AWSIM's `ros2cs` (ROS-for-Unity) nodes; both were read from source, so
findings apply to both unless noted.

Load-bearing settings, stated once:

| Setting | Value | Why it matters |
|---|---|---|
| Domain | 0 | Only same-domain processes discover each other |
| Participant index | none | Ports are ephemeral, not fixed |
| Multicast on `lo` | enabled | Required for discovery; disabling it crashes every node |
| Max message size | 65500 B | Fragmentation limit relevant to malformed-packet attacks |
| Write History Cache high-water mark (`WhcHigh`) | 500 kB | The back-pressure watermark that throttles flooding |

Two vehicle-controlling topics ground every finding, both published `transient_local`:
`/system/operation_mode/state` (`mode: 2` = AUTONOMOUS) and `/control/command/gear_cmd` (`command: 2` =
DRIVE).

**Attacker model.** A process outside the simulation joining domain 0 on `lo`, via either an ordinary ROS
2 node or a hand-forged RTPS speaker. Because the container uses host networking, any host process can
join with no network isolation to cross — an artifact of this simulation's co-location, not of the real
deployment. On a real vehicle network the equivalent attacker is a compromised ECU on automotive Ethernet
or CAN, which must still reach the discovery group and satisfy the same protocol/QoS invariants; those
invariants, not the ease of reaching them, are what carries over.

---

## How the stack works, in brief

A publish call descends five library boundaries before a byte leaves the interface: `rclcpp` → `rcl` →
`rmw` → `rmw_cyclonedds` → Cyclone core → RTPS wire. The vendor split begins exactly at
`rmw_publish → dds_write`. Three facts from this path recur everywhere:

- **Serialization is Cyclone-only.** The message becomes CDR bytes for the first time inside Cyclone
  (`ddsi_serdata_from_sample`); every layer above just forwards the native struct.
- **Sequence numbers are per-writer and monotonic**, assigned as `seq = ++wr->seq` at the same point the
  sample is inserted into the writer's **Write History Cache (WHC)**. The WHC is what a reliable writer
  retransmits from on NACK, and — for `transient_local` topics — what it replays to a reader that joins
  late. `WhcHigh` (500 kB of unacknowledged data) is the flow-control ceiling on that cache.
- **AWSIM shares this exact path below the language binding.** `ros2cs` is a C# binding over the same
  host ROS 2 / Cyclone libraries `rclcpp` uses, so serialization, sequencing, and WHC behavior are
  identical for both client surfaces.

**Matching has three independent gates, all checked at discovery time, before any data is sent** — a
mismatch is a non-connection, not a message dropped later: topic name (mangled with an `rt/` prefix),
type name (plus a type hash, if the build enables type discovery — unverified which way this build was
built), and QoS compatibility under the **Requested/Offered (RxO)** rule: for each policy, the reader's
*requested* value must be satisfiable by the writer's *offered* value. **Durability is the load-bearing
policy**: Cyclone orders `VOLATILE(0) < TRANSIENT_LOCAL(1)`, so a `transient_local` reader never connects
to a volatile-only writer. Both anchor topics' readers request `transient_local`, so this is the one gate
every injector must clear.

**Discovery** is two-stage multicast over `lo`: SPDP announces participants (30 s interval), then SEDP
announces each endpoint together with its topic, type, and full QoS — meaning an injector's durability
offer is visible on the wire before it ever sends data. Discovery multicast runs on port 7400 (domain 0);
disabling multicast on `lo` alone crashes every node in the container, which is the basis of the
physical-layer kill described below.

---

## Findings

### 1. Configuration and shutdown

Configuration splits into three reachability tiers: **launch-time** (domain id, Cyclone XML, node/init
options — fixed, never served over the network), **endpoint** (per-endpoint QoS — announced via SEDP,
readable but not settable by a peer), and **runtime-served** (ROS parameters and, for managed nodes,
lifecycle transitions — exposed as network services).

There are **four distinct shutdown mechanisms**, and only one of them is even *potentially*
network-reachable:

| Mechanism | Blast radius | Reachable from domain 0? |
|---|---|---|
| `rclcpp::shutdown()` | whole process | No — in-process only |
| Node destruction | one node | No — in-process only |
| Lifecycle `change_state` service | one managed node | In principle, yes — no durability barrier on the service's QoS |
| Signal / hard kill | whole process | No — host access only |

**The lifecycle lever doesn't apply here.** Reading the actual node sources: none of the command-topic
owners (`VehicleCmdGate`, `MrmHandler`, `RawVehicleCommandConverterNode`, `MissionPlanner`) are
`LifecycleNode`s — all are plain `rclcpp::Node` components. A full sweep of the checkout finds no
`LifecycleNode` subclass anywhere in Autoware Core or Universe. So the *only* clean, network-reachable
shutdown mechanism simply does not exist for this deployment, in either direction: the SEU cannot cleanly
quarantine a compromised command node over the network, and an attacker cannot cleanly silence a
legitimate one either — both are pushed toward the forged protocol withdrawal described in §5.

### 2. Injecting data from outside the simulation

Two carriers can make a legitimate node accept an outside process's message.

**Carrier A — an ordinary ROS 2 node.** Trivial: configure the same Cyclone settings, and the injector is
discovered as a fully legitimate participant reusing the real publish path with a genuine GUID and
correct CDR. The only thing it must get right is QoS — specifically, **offering `transient_local`**. Get
that wrong (the ROS 2 default is `VOLATILE`) and the result is a **dropped injection**: the writer's
`publish()` still reports success, the sample lands only in the injector's own WHC, discovery shows a
writer whose durability the reader's RxO check rejects, and the reader's callback never fires. The
attacker sees success; the vehicle sees nothing — and a content-only monitor would miss this entirely,
since no sample ever crosses the wire.

**Carrier B — hand-forged raw RTPS, no ROS 2.** The deployment-realistic threat, since a compromised ECU
need not run ROS 2 at all. It requires two forgeries: a discovery forgery (SPDP + SEDP announcing a
matching writer that offers `transient_local`) and a data forgery (a valid GUID, a fresh sequence number,
and hand-built CDR framing matching Cyclone's XCDR1 encoding). Feasible in principle, but substantially
harder than Carrier A — the difficulty concentrates in reproducing a byte-accurate discovery handshake,
not in the data payload itself. Whether a given hand-built sequence is actually accepted by this specific
build is unverified without a live capture.

### 3. Replay and over-publication

**Faithful replay — capturing and re-sending the exact original packets — is blocked.** Cyclone's
per-remote-writer reorder buffer (keyed on writer GUID) already advanced its `next_seq` past those numbers
during the original live delivery; a replayed packet under the same GUID and sequence number arrives
below that watermark and is discarded as too-old before it ever reaches the reader cache. A reliable
reader also refuses any data from a writer it hasn't yet seen a HEARTBEAT from, compounding the
requirement.

**Content reuse is achievable, just not faithful.** Re-publishing the *captured value* from an ROS 2
injector's own writer gets a fresh GUID and a sequence number restarting at 1 — Cyclone treats it as an
ordinary new sample and delivers it normally. Nothing in DDS compares payload content, so this is
indistinguishable from a legitimate first-time publish except for the GUID.

**The forced pivot is over-publication**, which **self-throttles**: once a reliable writer's
unacknowledged data exceeds `WhcHigh` (500 kB), Cyclone blocks the writer's *own* subsequent `publish()`
calls until the cache drains or a timeout aborts them — so a flood caps its own rate. Deadline is the
wrong instrument to catch this: it fires on too *few* samples, not too many, and the command readers leave
deadline and lifespan unset entirely.

**No de-duplication exists anywhere in this path — DDS or application.** Reading the actual subscriber
callbacks: `VehicleCmdGate`'s operation-mode handler and `MrmHandler`'s gear-command handler both act on
every received value unconditionally, with no timestamp, counter, or equality check. AWSIM's vehicle
input behaves identically. A replayed or repeated command is therefore obeyed as if it were fresh — this
is not a gap the SEU can delegate to the application; it must detect replay and repetition itself.

### 4. QoS-based message prioritization

**The two policies that would actually let one writer take precedence — transport priority and
ownership/ownership-strength — are absent from the ROS 2 middleware QoS struct entirely.** No `rclcpp`
call, by an injector or a legitimate node, can set either one; the ceiling is set at the vendor-neutral
`rmw` layer, not by Cyclone.

Cyclone *does* implement both internally — including working exclusive-ownership arbitration, contrary to
a common assumption that Cyclone lacks it — but neither is usable through ROS:

- **Transport priority** only feeds one live mechanism (gating synchronous delivery on the receive side),
  and that mechanism is inert at the default threshold of 0. The feature that would actually route
  high-priority traffic differently (network channels / DSCP marking) is compiled out of standard builds.
- **Ownership arbitration** only arms if the *reader* requests exclusive ownership. Reading the actual
  subscriptions confirms neither Autoware's nor AWSIM's readers on the anchor topics ever do — both stay
  at the default SHARED, so every matched writer's samples are accepted, newest-write-wins.

Net effect: the SEU cannot get privileged delivery through ROS QoS, but neither can an attacker — and an
attacker who did reach Cyclone's C API to force exclusive ownership would fail the RxO ownership match
against a SHARED reader and deliver nothing, a self-defeating move that is also loudly visible at
discovery time (every legitimate endpoint here carries priority 0 and SHARED ownership).

### 5. Disabling an element without a clean shutdown

**Protocol level — the sharpest tool, and the clearest detection target.** An endpoint withdrawal is
nothing more than a keyed DATA packet carrying a dispose/unregister status flag and the victim's GUID. On
receipt, Cyclone deletes the matching proxy writer by GUID alone — **with no check that the withdrawal's
source is authorized to speak for that endpoint**, unlike the equivalent "alive" registration path, which
does verify the owning participant. A participant-level withdrawal (which kills the whole proxy
participant and everything it owns) is nominally gated by a deletion-allowed check, but on a build without
DDS Security that check is a stub that always returns true, and even the DDS-Security-enabled
implementation's own code comment admits it never verifies the GUID-prefix match for an unauthenticated
participant — so either way, an attacker who was never authenticated can walk through it. The prerequisite
is cheap: be discovered, and learn the victim's GUID by passively observing its own announcements. The
concrete mitigation is DDS Security (authentication), which is what makes this guard actually guard
something.

**Physical level — one command on the shared link.** Because both sides live on the loopback interface,
disabling multicast on `lo` (or dropping UDP/7400, or taking `lo` down entirely) kills discovery for every
node in the container at once. This needs host access, not a domain-0 capability — so it is not an
attacker's network-reachable lever in the deployment sense, but it maps directly onto the SEU's strongest
real-world position: on an actual vehicle bus, an inline device sitting on the physical link can drop or
rate-limit a single compromised source's frames authoritatively, a capability the deployment threat model
gives the *defender*, not the attacker.

**Application level.** No new mechanism — it's the same clean levers from §1 (which do not reach the
command nodes) and the injection attack from §2, reframed as "disabling," noted only to keep the
categories distinct.

---

## SEU implications

- **No clean, network-reachable shutdown exists for the command-topic nodes in this deployment**, in
  either direction — neither the SEU nor an attacker can invoke it. Both are forced toward the protocol
  withdrawal below.
- **Carrier-A injection is loud and specific**: a new, un-allowlisted participant GUID plus a fixed,
  predictable `transient_local` QoS fingerprint. A dropped injection (wrong durability) is a quieter but
  still real signature — a reconnaissance attempt visible in SEDP even though no sample ever crosses,
  which a content-only monitor would miss.
- **Carrier-B (forged RTPS) is the deployment-realistic threat.** Its detection surface is the set of
  protocol invariants a forger must fake but a real endpoint never thinks about: GUID consistency, an
  offered `transient_local` on a "writer" with no prior history, monotonic sequence numbers, exact CDR
  framing.
- **Replay and flooding are rate/identity anomalies, not content anomalies**: watch for known content
  under a foreign or newly-appeared GUID, for an already-seen (GUID, sequence) pair, and for
  per-(topic, writer) rate spikes. Deadline is the wrong tool. Application-level de-duplication does not
  exist and cannot be relied on — the SEU must treat every repeated or replayed accepted command as
  potentially hostile.
- **Priority/ownership attacks are self-defeating and loud** — don't build SEU privilege on QoS fields the
  ROS layer can't even carry, and expect any real attempt at dominance to fail its own RxO match while
  announcing itself.
- **The protocol withdrawal is the attacker's cheapest tool and the SEU's clearest signature**: a
  dispose/unregister whose source participant doesn't match the endpoint or participant it is disposing —
  exactly the check the code's own comment admits is missing, and exactly what DDS Security would close.
- **The physical link is the SEU's home turf**: authoritative, per-source, inline. On the real bus the
  roles invert cleanly — the attacker's easiest layer is the protocol; the SEU's strongest layer is the
  physical link. Detect at the protocol layer; enforce at the physical layer.

---

## What's settled vs. still open

Resolved directly from source in this study: none of the command-topic owner nodes are
lifecycle-managed, and none exist anywhere in Autoware Core/Universe; the application performs no
command-value de-duplication; the command readers leave deadline and lifespan unset and never touch
ownership; AWSIM's readers request the same `transient_local` durability as Autoware's.

Still open, because settling them needs a running system or a packet capture that this study could not
perform: whether this build was compiled with type-discovery hashing or with DDS Security; whether a
hand-forged RTPS sequence (Carrier B) is actually accepted end-to-end; whether a production vehicle build
enables network channels/DSCP; and the exact timing of a port-7400 drop or discovery-multicast flood
against a live instance.
