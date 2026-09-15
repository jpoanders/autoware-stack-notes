# Task 2 — Data Injection from a Third-Party Element Outside the Simulation

> **Read the [shared foundation](foundation.md) first.** This report reuses the foundation's layer
> map (§2), publish path to the wire (§3), delivery-matching rules — topic-name mangling (§4.1),
> type matching (§4.2), and the QoS Requested/Offered rule including the `transient_local` durability
> gate (§4.3) — and discovery/ports/GUID model (§5) **by reference**, and does not re-derive them.
> Source-class tags are the foundation's: `[repo]` = a file in this checkout (cited `path:line`);
> Cyclone DDS core is in-checkout, so it too is `[repo]`; `[spec]` = OMG DDS / DDSI-RTPS; `[UNVERIFIED]`
> = would require running the sim or a packet capture; `setup-guide §N` = the authoritative runtime
> record. Terms (rcl, rmw, SEDP, GUID, RxO, CDR, WHC, …) are defined in the foundation glossary (§6).

---

## 1. Objective, scope, and exclusions

**Objective.** Determine, from source, **every viable way a process outside the simulation can publish
messages that legitimate Autoware Core nodes accept**, and compare those paths by realism and
detectability. "Accept" is the load-bearing word: it is not enough to emit bytes on `lo`; the bytes
must survive discovery, topic-name matching, type matching, and — the gate that silently defeats the
naive attempt — QoS compatibility, so that a real Autoware subscriber's callback runs with the
injected value.

**Worked target.** Throughout, the injected message is a real vehicle-controlling command:
`/system/operation_mode/state` (`autoware_adapi_v1_msgs/msg/OperationModeState`) and
`/control/command/gear_cmd` (`autoware_vehicle_msgs/msg/GearCommand`), both published with
`transient_local` durability (setup-guide §8; foundation §4.3). Injecting well-formed values on these
topics is the meaningful attack: an accepted `GearCommand{command: 2}` (DRIVE) or
`OperationModeState{mode: 2}` (AUTONOMOUS) changes what the vehicle does (foundation §0 recon confirms
the enum constants `DRIVE = 2` and `AUTONOMOUS = 2` are present in-checkout). Noise on an arbitrary
topic is out of scope by the study's own framing (the-new-investigation-layer point 4).

**Two paths, both traced against that target:**
- **PATH A — an external rclcpp node** on the host, Cyclone-configured, publishing on the topic (§4).
- **PATH B — hand-forged RTPS** DATA submessages on `lo`, with no ROS 2 / rclcpp at all (§5).

**In scope.** The full acceptance chain for each path down to the wire, a minimal injector sketch for
Path A, the enumeration of what Path B must reproduce, and **at least one trace of a *dropped*
injection** (§4.3) — a volatile-only writer that never matches the `transient_local` reader.

**Excluded (and where it lives).** *Replay* and *over-publication* (re-sending captured traffic, or
flooding N copies) are **Task 3**, which reuses this report's injector. *Silencing* a legitimate
writer by forging an SEDP dispose, exploiting liveliness/deadline, or a link-layer kill is **Task 4**.
*QoS as a prioritization or ownership-dominance lever* is **Task 5**. This report establishes only how
an outsider gets a *single accepted publish* onto a command topic; the other tasks build on it.

---

## 2. Foundation reuse and new territory

**Reused by reference (not re-derived):**

| From foundation | Used here for |
|---|---|
| §2 layer map; §3 publish path (`publish → rcl_publish → rmw_publish → dds_write → … → nn_xpack_send`) | Path A's descent to the wire; the single point (§3 step 6) where CDR bytes first exist, which Path B must reproduce by hand |
| §4.1 topic-name mangling (`rt` prefix → `rt/control/command/gear_cmd`) | What DDS topic name *both* paths must create to match the Autoware reader |
| §4.2 type matching (DDS type name `autoware_vehicle_msgs::msg::dds_::GearCommand_`; the type-hash `[UNVERIFIED]`) | What type name/id both paths must present |
| **§4.3 QoS RxO rule and the `transient_local` durability gate** | The rule the injector's writer must satisfy; the dropped-injection trace (§4.3 here) |
| §5 discovery (SPDP/SEDP on `lo` multicast, domain 0, ports 7400/7401, builtin entity ids, GUID model) | Why discovery is automatic for Path A; what Path B must forge; the foreign-GUID / late-joiner signatures |

**New territory opened for this task (files first opened here):**
`src/rclcpp/rclcpp/include/rclcpp/qos.hpp` (the rclcpp QoS setters an injector calls, esp.
`transient_local()`); `src/rmw_cyclonedds/rmw_cyclonedds_cpp/src/serdata.cpp` (the CDR
serialization the forged path must reproduce: `sertype_serialize_into`, the XCDR1 representation
flag, the no-keys assumption). The `GearCommand.msg` field layout (`stamp` + `command`) is read to
sketch the CDR body.

---

## 3. Mechanism overview — the acceptance chain both paths must clear

**Orientation.** The naive model of injection is "send a UDP packet to the right port and the
subscriber gets it." That is false here in two independent ways, and both paths must clear the same
four gates before a subscriber's callback ever runs. The gates are the foundation's, assembled here
into the attacker's checklist:

```mermaid
flowchart TD
  I["Outside process joins Cyclone domain 0 on lo"] --> D
  D["GATE 0 — DISCOVERY (foundation §5)\nSPDP: announce a participant on lo:7400 multicast\nSEDP: announce a writer for the topic + its QoS"] --> N
  N["GATE 1 — TOPIC NAME (foundation §4.1)\nDDS name must be rt/control/command/gear_cmd, not /control/command/gear_cmd"] --> T
  T["GATE 2 — TYPE (foundation §4.2)\ntype name autoware_vehicle_msgs::msg::dds_::GearCommand_\n(+ type hash if DDS_HAS_TYPE_DISCOVERY)"] --> Q
  Q["GATE 3 — QoS RxO (foundation §4.3)\nwriter must OFFER durability >= reader's transient_local request\nelse qos_match_mask_p returns false — NO MATCH"] --> A
  A["Reader accepts sample → Autoware callback runs with injected value"]
```
*What to notice:* the gates are checked at discovery time, in Cyclone's `qos_match_mask_p`
(`src/cyclonedds/src/core/ddsi/src/q_qosmatch.c:158-267`) `[repo]`, **before any data sample is
delivered** — so a mismatch is a *non-match*, not a late drop (foundation §4.3). Path A gets Gate 0
and most of Gates 1–2 for free from the rclcpp/rmw stack and must only get Gate 3 right; Path B must
construct all four by hand. That difference is the whole realism/detectability comparison.

---

## 4. PATH A — external rclcpp node (DEEP)

**Motivation.** The cheapest injector is an ordinary ROS 2 Humble C++ program run on the host. Because
the Autoware container is `--net host` and both sides are pinned to Cyclone DDS on domain 0 bound to
`lo` with multicast (setup-guide §0, §4, §6a), a third rclcpp process that sets the *same*
`RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` and `CYCLONEDDS_URI` is, from DDS's point of view, just
another legitimate participant. It is discovered automatically within one SPDP period (foundation §5,
`spdp_interval` default 30 s at `q_ddsi_discovery.c`/`defconfig.c:36`) `[repo]`. **The one thing the
attacker must get right is the QoS**, and getting it wrong is the dropped-injection trace of §4.3.

**Mental model.** Path A reuses the *entire* legitimate publish path (foundation §3): the injector's
`publisher->publish(msg)` descends `rclcpp → rcl → rmw → dds_write → write_sample_eot → nn_xpack_send`
exactly as an Autoware node's would, producing a genuine RTPS DATA submessage with correct CDR, a
correct type, the mangled topic name, and a real per-writer sequence number. Nothing is forged; the
injector *is* a real DDS writer. Its only "attack" quality is that it is not part of the sim and it
asserts a value the vehicle should not obey.

### 4.1 The minimal injector, and the one QoS line that matters

A faithful injector for `/system/operation_mode/state` is about a dozen lines. The security-relevant
content is entirely in the QoS:

```cpp
// Run with: RMW_IMPLEMENTATION=rmw_cyclonedds_cpp CYCLONEDDS_URI=file://$HOME/cyclonedds.xml
#include "rclcpp/rclcpp.hpp"
#include "autoware_adapi_v1_msgs/msg/operation_mode_state.hpp"

int main(int argc, char ** argv) {
  rclcpp::init(argc, argv);
  auto node = std::make_shared<rclcpp::Node>("not_the_sim");

  // THE load-bearing line: offer transient_local, or the reader never matches (§4.3).
  rclcpp::QoS qos = rclcpp::QoS(rclcpp::KeepLast(1)).reliable().transient_local();

  auto pub = node->create_publisher<autoware_adapi_v1_msgs::msg::OperationModeState>(
      "/system/operation_mode/state", qos);

  autoware_adapi_v1_msgs::msg::OperationModeState m;
  m.mode = 2;  // AUTONOMOUS
  m.is_autoware_control_enabled = true;
  m.is_autonomous_mode_available = true;
  pub->publish(m);          // descends the foundation §3 path to a real RTPS DATA on lo
  rclcpp::spin_some(node);  // let discovery + delivery complete
}
```

**Every dependency, cited.**
1. **`rclcpp::init` / `Node`** join Cyclone domain 0 on `lo` because the process inherits the same
   `CYCLONEDDS_URI` (setup-guide §6a); no code chooses the interface — the Cyclone XML does.
2. **`rclcpp::QoS(...).reliable().transient_local()`** sets the offered durability. `transient_local()`
   sets `DurabilityPolicy::TransientLocal` (`src/rclcpp/rclcpp/include/rclcpp/qos.hpp:198-200`,
   enum at `:50-56`) `[repo]`. **Without this call the QoS defaults to VOLATILE** — the documented
   default profile is Reliable + Volatile (`qos.hpp:115-119`) `[repo]` — which is the dropped case
   (§4.3).
3. **`create_publisher(...)`** maps that QoS through the Cyclone binding's `create_readwrite_qos`,
   which translates `TRANSIENT_LOCAL` to `dds_qset_durability(qos, DDS_DURABILITY_TRANSIENT_LOCAL)`
   and additionally sets the durability-service QoS so the WHC retains history for late joiners
   (foundation §4.3; `src/rmw_cyclonedds/rmw_cyclonedds_cpp/src/rmw_node.cpp:2057-2068`) `[repo]`. It
   also mangles the topic name to `rt/system/operation_mode/state` (foundation §4.1) and builds the
   DDS type name `autoware_adapi_v1_msgs::msg::dds_::OperationModeState_` (foundation §4.2).
4. **`publish(m)`** runs the foundation §3 chain verbatim; the identifier check at
   `rmw_node.cpp:1825-1834` passes because this process really is Cyclone (foundation §3 step 4)
   `[repo]`.

**No forgery anywhere.** The injector's writer GUID is a genuine, locally generated GUID (foundation
§5); its sequence numbers start at 1 and increment (foundation §3 step 7, `++wr->seq`); its CDR is
produced by the same serializer as Autoware's. This is why Path A is trivially *effective* and,
paradoxically, why it is also trivially *detectable* — see §6.

### 4.2 Why acceptance follows once QoS is right

With durability offered as `transient_local`, the RxO comparison the reader runs (foundation §4.3)
evaluates, for durability, `rd.durability.kind (1) > wr.durability.kind (1)` → **false** → the policy
does not veto the match (`src/cyclonedds/src/core/ddsi/src/q_qosmatch.c:167`) `[repo]`. Reliability
matches (both RELIABLE: `rd(1) > wr(1)` false, `q_qosmatch.c:163`) `[repo]`; the mangled topic name is
byte-equal (`strcmp(...topic_name...) != 0` is false, `q_qosmatch.c:160`) `[repo]`; the type name (or
hash) agrees (§4.2 foundation, `q_qosmatch.c:216-267`) `[repo]`. All gates pass, the endpoints match,
and the injected sample is delivered to the Autoware subscriber's callback. Because the command topics
are `transient_local`, the injector's WHC even resends the value to the reader **if the injector joins
before the reader** — the durability-service QoS wired at `rmw_node.cpp:2057-2068` is what makes a
late-*reader* still receive the outsider's command (foundation §3 gotcha) `[repo]`.

### 4.3 The dropped injection — a volatile writer against a `transient_local` reader (required trace)

This is the trace the study demands: an injection that is *emitted* but never *accepted*. It is the
default outcome of the sketch above with the `transient_local()` call removed.

**Setup.** The injector calls `create_publisher("/system/operation_mode/state", rclcpp::QoS(1))` —
depth 1, and the default profile's Reliable + **Volatile** durability (`qos.hpp:115-119`) `[repo]`. It
then calls `publish(m)`.

**Trace (each step cited).**
1. `create_readwrite_qos` still runs, but for VOLATILE it calls `dds_qset_durability(qos,
   DDS_DURABILITY_VOLATILE)` and does **not** attach a durability-service QoS (foundation §4.3; the
   binding always sets *some* durability, so "unset" is impossible — `rmw_node.cpp:2052-2074`)
   `[repo]`. The writer's offered durability kind is therefore `DDS_DURABILITY_VOLATILE == 0`
   (`src/cyclonedds/src/core/ddsc/include/dds/ddsc/dds_public_qosdefs.h:77`) `[repo]`.
2. The writer is created and **announced via SEDP** carrying that VOLATILE durability in its QoS plist
   (foundation §5: SEDP carries exactly the QoS `qos_match_mask_p` later compares). So the wrong
   durability is visible on the wire before any data sample is sent.
3. The Autoware reader requested `transient_local`, i.e. `durability.kind == DDS_DURABILITY_TRANSIENT_
   LOCAL == 1` (`dds_public_qosdefs.h:78`) `[repo]`, proven by the guide's
   `ros2 topic pub ... --qos-durability transient_local` (setup-guide §8).
4. On discovery, Cyclone evaluates `qos_match_mask_p`. Both sides declared durability present, so it is
   compared (`mask &= rd_qos->present & wr_qos->present`, `q_qosmatch.c:158`) `[repo]`. The durability
   test `rd.durability.kind (1) > wr.durability.kind (0)` is **true**, so the function sets `*reason =
   DDS_DURABILITY_QOS_POLICY_ID` and returns **`false`** (`q_qosmatch.c:167-169`) `[repo]`.
5. `false` means the endpoints **never match**. No reader-writer link is formed; the reader's
   `on_data` is never invoked for this writer.
6. Crucially, `publish(m)` on the injector side still **succeeds** — `dds_write` returns `>= 0` and
   `rmw_publish` returns OK (foundation §3 step 4, `rmw_node.cpp:1834`) `[repo]`. The sample is written
   into the injector's own WHC and, with no matched reader, goes nowhere. **The attacker sees success
   and the vehicle sees nothing.**

**Why this is the defining subtlety.** The failure is silent on the sender's side and produces *no
delivered-then-rejected sample* — there is nothing for a naive content filter to catch, because the
sample never crosses. The only network trace is the SEDP announcement of a writer whose durability
does not satisfy the reader (foundation §5). An injector author who does not know the RxO rule will
conclude "my publish worked, why doesn't the car move?" — the question the foundation's §4.3 exists to
answer. `[INFERRED: from foundation §4.3 applied to the default-QoS writer; a live run or capture would
confirm the reader never fires — [UNVERIFIED: would require running the sim].]`

---

## 5. PATH B — direct RTPS on the wire, no rclcpp (DEEP)

**Motivation.** Path A matters for the *simulation*; Path B matters for the **deployment threat model
the SEU actually defends**. On a real vehicular network the hostile element is a compromised ECU that
may not run ROS 2 at all — it speaks whatever the bus speaks. The faithful analogue here is a process
that forges **RTPS** (the DDS wire protocol; foundation glossary) directly onto `lo`, reproducing by
hand everything the rclcpp/rmw/Cyclone stack did for Path A. Enumerating *what it must reproduce* is
the deliverable; it is also, precisely, the list of invariants the SEU can check.

**Mental model.** Cyclone does not accept "a DATA packet." It accepts a DATA submessage **from a writer
GUID it has already discovered and matched** for the reader's topic, type, and QoS. So Path B is really
two forgeries: a **discovery forgery** (make Cyclone believe a matching writer exists) and a **data
forgery** (a well-formed DATA submessage carrying valid CDR under that writer's GUID and a fresh
sequence number). Skip the first and the second is dropped as coming from an unknown writer.

### 5.1 What Path B must reproduce — the enumeration

| # | Requirement | What it means concretely | Source class |
|---|---|---|---|
| 1 | **Domain 0, `lo`, ports** | Send SPDP/metatraffic to the multicast group on **7400**, user data on **7401**; unicast is ephemeral because `ParticipantIndex=none` (foundation §5, ports from `defconfig.c:37-42` / `ddsi_portmapping.c:29-61`) | `[repo]` (ports) |
| 2 | **SPDP participant announcement** | Emit a participant with a 12-byte GUID prefix + the builtin SPDP writer entity id `0x100c2`, advertising metatraffic/default locators, so peers create a proxy participant (foundation §5, `q_rtps.h:41`) | `[repo]` id / `[spec]` framing |
| 3 | **SEDP endpoint announcement** | Emit a publications-writer record (builtin id `0x3c2`, `SEDP_KIND_WRITER`) declaring: topic name `rt/system/operation_mode/state`, type name `autoware_adapi_v1_msgs::msg::dds_::OperationModeState_`, and a QoS plist that **offers durability `transient_local`** (foundation §4.1, §4.2, §5; `q_ddsi_discovery.c:58-62`) | `[repo]` ids / `[spec]` plist layout |
| 4 | **Type agreement** | Present a type name matching §4.2; **if the container's Cyclone defines `DDS_HAS_TYPE_DISCOVERY`, also a matching type hash / TypeInformation** — otherwise a name `strcmp` suffices (foundation §4.2, `q_qosmatch.c:216-267`) | `[repo]` + `[UNVERIFIED]` build flag |
| 5 | **QoS on the wire** | The SEDP QoS must pass every RxO check of foundation §4.3, durability foremost; a forged VOLATILE offer reproduces the §4.3 dropped case at the protocol level | `[repo]` (rule) |
| 6 | **CDR framing of the payload** | A DATA submessage whose `serializedPayload` is a 4-byte encapsulation header (`CDR_LE`, options `0x0000`) followed by the message body in XCDR1 (§5.2) | `[spec]` header + `[repo]` XCDR1 |
| 7 | **A valid writer GUID + fresh sequence number** | The DATA must cite the *same* writer GUID announced in step 3 and a sequence number the reader has not seen; sequence numbers are per-writer monotonic (foundation §3 step 7) | `[repo]` (seq model) / `[spec]` (DATA header) |

Items 1–3 and 7's GUID are the **discovery forgery**; items 4–6 and 7's sequence number are the **data
forgery**. Only the port numbers, entity ids, the QoS rule, the XCDR1 flag, and the sequence-number
model are `[repo]` findings; the byte-level layout of SPDP/SEDP plists and the DATA submessage header
is the **RTPS wire contract `[spec]`** — this checkout contains the Cyclone *behaviour* that consumes
those bytes, not a normative statement of their layout.

### 5.2 The CDR the forger must produce for `GearCommand`

The one place Path A got serialization for free (foundation §3 step 6, `ddsi_serdata_from_sample`),
Path B must hand-build. Cyclone serializes ROS messages as **XCDR1**: the sertype advertises
`st->allowed_data_representation = DDS_DATA_REPRESENTATION_FLAG_XCDR1`
(`src/rmw_cyclonedds/rmw_cyclonedds_cpp/src/serdata.cpp:703`) `[repo]`, and the body is written by
`sertype_serialize_into` → `cdr_writer->serialize` with **no key handling** ("ROS 2 doesn't support
keys … only data is handled", `serdata.cpp:590,605-628`) `[repo]`. For `GearCommand` — fields
`builtin_interfaces/Time stamp` (int32 `sec`, uint32 `nanosec`) then `uint8 command`
(`autoware_vehicle_msgs/msg/GearCommand.msg`, last two lines) `[repo]` — the serialized payload is:

```
serializedPayload (inside the RTPS DATA submessage):
  +0  00 01        representation_id  = CDR_LE (little-endian plain CDR)   [spec]
  +2  00 00        representation_opts = 0                                 [spec]
  --- CDR body (XCDR1, aligned) ---                                        [repo: XCDR1 flag]
  +4  ss ss ss ss  int32  stamp.sec
  +8  nn nn nn nn  uint32 stamp.nanosec
  +12 02           uint8  command = 2 (DRIVE)                              [repo: DRIVE=2]
```

The 4-byte encapsulation header is the RTPS `[spec]` contract; the field order, types, and alignment
are dictated by the `.msg` and the XCDR1 rule `[repo]`. `OperationModeState` is the same shape with a
different body. Getting one byte of alignment or the endianness flag wrong makes Cyclone misparse the
sample — a fragility the SEU can exploit, and a reason Path B is *harder*, not merely lower-level, than
Path A.

### 5.3 Feasibility verdict

Path B is **feasible in principle but substantially harder than Path A**, and the difficulty is
concentrated in the discovery forgery (items 1–3), not the data forgery. Reproducing a byte-accurate
SPDP/SEDP handshake that Cyclone's discovery accepts — correct builtin entity ids, a well-formed QoS
plist, and (possibly) a matching type hash — is where an off-the-shelf forger fails. `[UNVERIFIED:
whether a hand-built SPDP/SEDP + DATA sequence is accepted by this specific Cyclone build, and whether
a type hash is required, would be settled only by a packet capture against the running container.]`
The value of enumerating it is not that it is easy; it is that **each item is an invariant the real
sim never violates**, so each is a detection surface (§6).

---

## 6. SEU implications

**The two paths have opposite detectability profiles, and the loopback co-location distorts both — so
the SEU must reason about the deployment bus, not the sim.**

- **Path A is maximally effective and maximally detectable.** The injector is a *real* participant, so
  it announces itself: a **new participant GUID prefix that belongs to neither sim participant** (AWSIM
  or the Autoware container) appears in SPDP on `lo:7400`, and a **new writer on a command topic**
  appears in SEDP (foundation §5). The SEU's cleanest signal is the *identity* one: on the deployment
  network the set of legitimate participants and their GUIDs is knowable, and a command writer for
  `rt/control/command/gear_cmd` or `rt/system/operation_mode/state` whose GUID is not on the allowlist
  is, by itself, the attack. A **late-joining participant on domain 0** (foundation §5, one SPDP period
  after start) is a secondary temporal signal. Notably, the injector had to **offer `transient_local`**
  to succeed (§4.2), so even its QoS is fixed and predictable — the SEU knows exactly what a working
  command injector's SEDP record looks like.

- **The dropped-injection case (§4.3) is a distinct, quieter signature.** A writer that announces
  VOLATILE durability on a `transient_local` command topic never matches and delivers nothing — but its
  *SEDP announcement still appears*. The SEU can flag "a foreign writer on a command topic whose QoS
  does not satisfy the reader" as a **failed or reconnaissance injection**, visible even though no
  sample crossed. That is a detection opportunity a content-inspection-only monitor would miss entirely,
  because there is no delivered payload to inspect.

- **Path B is the deployment-realistic threat and the harder detection problem.** A forger that
  reproduces a legitimate-looking GUID, topic, type, and QoS (§5.1) is trying to look like the sim, so
  identity alone may not separate it. Here the SEU's surface is the **set of invariants Path B must
  reproduce but a real endpoint never has to think about**: a GUID prefix reused or malformed relative
  to the participant's advertised locators, SEDP QoS that is *exactly* `transient_local` but attached to
  a writer that never sent history, DATA sequence numbers that do not advance monotonically from a
  discovered writer, or CDR whose encapsulation/alignment deviates from the XCDR1 the real stack emits
  (§5.2). Each is a positive check the SEU can run at the RTPS layer.

- **The realism caveat frames all of the above.** On this sim, *both* paths are trivial because the
  container is `--net host` and everything shares one Cyclone domain on `lo` with multicast — there is
  no network boundary to cross (foundation §5 realism caveat; the-new-investigation-layer point 3). That
  ease is a **co-location artifact**, not a property of the deployment network. On a real automotive
  Ethernet/CAN bus, the attacker (a compromised ECU) still has to reach the discovery multicast group
  and match the topic/type/QoS — the *mechanics* of both paths transfer intact, but the *trivial ease*
  does not. The SEU should therefore treat the **identity and QoS invariants** (foreign GUID, the
  mandatory `transient_local` offer, monotonic per-writer sequence numbers) as its portable detection
  surface, because those are dictated by Cyclone's matching and delivery rules (foundation §4–§5) and
  hold on the deployment bus regardless of how the attacker reached it. Path A's ease is what the sim
  demonstrates; Path B is what the SEU is ultimately built to catch.

---

## 7. Appendix — files opened, tags, confidence

**Files opened for this task (all `[repo]`):**
- `src/rclcpp/rclcpp/include/rclcpp/qos.hpp` (QoS setters; `transient_local()`; default profile)
- `src/rmw_cyclonedds/rmw_cyclonedds_cpp/src/serdata.cpp` (XCDR1 flag; `sertype_serialize_into`; no-keys)
- `src/autoware_msgs/autoware_vehicle_msgs/msg/GearCommand.msg` (field layout for the CDR sketch)

Reused by reference (opened in the foundation, not re-opened here): `q_qosmatch.c`,
`rmw_node.cpp`, `dds_public_qosdefs.h`, `q_ddsi_discovery.c`, `q_rtps.h`, `defconfig.c`,
`ddsi_portmapping.c`, `dds_write.c` — all cited via the foundation sections noted inline.

**`[INFERRED]` / `[UNVERIFIED]` findings and what would settle them:**

| Tag | Claim | What would settle it |
|---|---|---|
| `[UNVERIFIED]` | Whether Path B needs a matching **type hash** or only a type name — depends on `DDS_HAS_TYPE_DISCOVERY` in the container's Cyclone build (foundation §4.2, carried forward) | Inspect the built Cyclone library, or a wire capture showing TypeInformation in SEDP |
| `[UNVERIFIED]` | Whether a hand-built SPDP/SEDP + DATA sequence is accepted by this Cyclone build (Path B feasibility, §5.3) | A packet capture / bench against the running container |
| `[UNVERIFIED]` | That the §4.3 dropped writer's `publish()` succeeds locally while the reader never fires | Running the sim with a VOLATILE injector and observing no callback |
| `[INFERRED]` | The default-QoS injector offers VOLATILE (from `qos.hpp:115-119` default profile + `create_readwrite_qos` always setting a durability) | Confirmed by reading both; a capture of the SEDP QoS would corroborate |

**Per-section confidence:**

| Section | Confidence | Reason |
|---|---|---|
| §3 Acceptance chain | HIGH | Every gate is a foundation `[repo]` finding assembled, not a new inference. |
| §4 Path A (rclcpp injector) | HIGH | QoS API, the `transient_local()` setter, the default-VOLATILE default, and the RxO consequence are all in-checkout `[repo]`; the publish path is the foundation's HIGH-confidence chain. |
| §4.3 Dropped injection | HIGH | The non-match is read directly from `q_qosmatch.c:167` + the durability enum ordering; only the *observed* "publish succeeds, callback never fires" runtime symptom is `[UNVERIFIED]`. |
| §5 Path B (forged RTPS) | MEDIUM | The *requirements* (ports, entity ids, QoS rule, XCDR1 flag, sequence model) are `[repo]`; the *byte layout* of SPDP/SEDP/DATA is `[spec]`, and end-to-end acceptance is `[UNVERIFIED]`. |
| §6 SEU implications | HIGH | Drawn from the mechanism (identity/QoS/sequence invariants) and the foundation realism caveat, not generic security commentary. |

<!-- REPORT-COMPLETE -->
