# **STemplate documentation:**

[https://lisha.ufsc.br/AutoX+-+TR+-+Vehicle+Simulators](https://lisha.ufsc.br/AutoX+-+TR+-+Vehicle+Simulators)

# **Autoware Experiments**

### **Researcher responsibilities (José Luis Conradi Hoffmann)**

The researcher will:

* provide the existing C++ implementation of the LSEU;  
* provide the monitoring specifications and timing rules;  
* explain the assumptions and expected LSEU behavior;  
* review and approve the proposed ROS 2/Autoware interface;  
* implement or approve changes to the internal LSEU algorithm;  
* resolve defects in the LSEU monitoring logic.

### **Joint student responsibilities**

The two students will work together and organize their own division of work. They will:

* identify the ROS 2 and Autoware integration points;  
* document how the ROS 2/DDS network and monitored topics will be observed;  
* demonstrate how message timestamps and values will be recorded;  
* prepare message definitions, configuration files, launch files, adapters, and integration wrappers;  
* study the researcher’s C++ LSEU code and specification list;  
* help define the LSEU’s ROS 2 interfaces;  
* integrate the approved LSEU into the experiment;  
* execute pilot and final experiments;  
* collect, validate, process, and report the experiment metrics.

The students will implement **integration code**, such as ROS 2 components, adapters, message definitions, configuration loaders, launch files, tracepoints, and data-recording utilities. 

---

# **Task 1 — Learn the Environment and Document Monitoring and Tracing**

## **Schedule**

Week 1 and 2

## **Description**

Install and learn ROS 2, CycloneDDS, Autoware, rosbag2, and `ros2_tracing`. Run an Autoware example, inspect its communication graph, and produce a short technical document explaining:

1. How the ROS 2 and DDS network will be monitored.  
2. How the monitored topics will be identified.  
3. How every relevant message’s timestamp and value will be recorded.  
4. How the trace will be correlated across the four-node processing chain.  
5. Which measurements will come from ROS messages, ROS 2 tracepoints, CycloneDDS logs, and Linux process files.

This document is a mandatory deliverable and must be approved.

## **Required documentation links**

### **ROS 2**

* ROS 2 Humble documentation:  
  [https://docs.ros.org/en/humble/](https://docs.ros.org/en/humble/)  
* ROS 2 topics tutorial:  
  [https://docs.ros.org/en/humble/Tutorials/Beginner-CLI-Tools/Understanding-ROS2-Topics/Understanding-ROS2-Topics.html](https://docs.ros.org/en/humble/Tutorials/Beginner-CLI-Tools/Understanding-ROS2-Topics/Understanding-ROS2-Topics.html)  
* ROS 2 interface concepts:  
  [https://docs.ros.org/en/humble/How-To-Guides/Topics-Services-Actions.html](https://docs.ros.org/en/humble/How-To-Guides/Topics-Services-Actions.html)  
* Rosbag recording and playback:  
  [https://docs.ros.org/en/humble/Tutorials/Ros2bag/Recording-And-Playing-Back-Data.html](https://docs.ros.org/en/humble/Tutorials/Ros2bag/Recording-And-Playing-Back-Data.html)  
* C++ publisher and subscriber tutorial:  
  [https://docs.ros.org/en/humble/Tutorials/Beginner-Client-Libraries/Writing-A-Simple-Cpp-Publisher-And-Subscriber.html](https://docs.ros.org/en/humble/Tutorials/Beginner-Client-Libraries/Writing-A-Simple-Cpp-Publisher-And-Subscriber.html)

ROS 2 topic statistics can measure message period and message age when enabled on a subscription. These measurements may supplement, but not replace, per-message tracing.

### **ROS 2 tracing**

* `ros2_tracing`:  
  [https://github.com/ros2/ros2\_tracing](https://github.com/ros2/ros2_tracing)  
* LTTng documentation:  
  [https://lttng.org/docs/](https://lttng.org/docs/)

`ros2_tracing` instruments core ROS 2 operations and supports tracing through the `ros2 trace` command or a launch action. On Linux it uses LTTng.

### **CycloneDDS**

* CycloneDDS documentation:  
  [https://cyclonedds.io/docs/](https://cyclonedds.io/docs/)  
* Configuration guide:  
  [https://cyclonedds.io/docs/cyclonedds/latest/config/index.html](https://cyclonedds.io/docs/cyclonedds/latest/config/index.html)  
* Reporting and tracing:  
  [https://cyclonedds.io/docs/cyclonedds/latest/config/reporting-tracing.html](https://cyclonedds.io/docs/cyclonedds/latest/config/reporting-tracing.html)  
* Configuration-file reference:  
  [https://cyclonedds.io/docs/cyclonedds/latest/config/config\_file\_reference.html](https://cyclonedds.io/docs/cyclonedds/latest/config/config_file_reference.html)

CycloneDDS can produce detailed logs covering traffic and internal activity. Its XML configuration can enable tracing categories and direct each process’s output to a separate file.

### **Autoware**

* Autoware documentation:  
  [https://autowarefoundation.github.io/autoware-documentation/main/](https://autowarefoundation.github.io/autoware-documentation/main/)  
* Autoware tutorials:  
  [https://autowarefoundation.github.io/autoware-documentation/main/tutorials/](https://autowarefoundation.github.io/autoware-documentation/main/tutorials/)  
* Example procedure for adding and evaluating a node:  
  [https://autowarefoundation.github.io/autoware-documentation/main/tutorials/others/an-example-procedure-for-adding-and-evaluating-a-new-node/](https://autowarefoundation.github.io/autoware-documentation/main/tutorials/others/an-example-procedure-for-adding-and-evaluating-a-new-node/)

Autoware’s documentation recommends first running the standard system to establish a performance and behavior baseline before evaluating a new node.

## **Steps**

### **Step 1 — Run the base Autoware chain**

Run an approved planning simulation or rosbag-replay configuration.

Record:

* launch commands;  
* active nodes;  
* active components;  
* process IDs;  
* subscribed and published topics;  
* topic types;  
* topic frequencies;  
* runtime QoS information.

Use:

ros2 node list | tee logs/nodes.txt  
ros2 component list | tee logs/components.txt  
ros2 topic list \-t | tee logs/topics.txt

ros2 node info \<node\_name\> \\  
  | tee logs/node\_\<node\_name\>.txt

ros2 topic info \--verbose \<topic\_name\> \\  
  | tee logs/topic\_\<topic\_name\>.txt

ros2 topic hz \<topic\_name\> \\  
  | tee logs/frequency\_\<topic\_name\>.txt

### **Step 2 — Map the monitored message flow**

Create a diagram covering:

/sensing/lidar/pointcloud  
          |  
          v  
/perception/detected\_objects  
          |  
          v  
/perception/tracked\_objects  
          |  
          v  
/planning/trajectory

For every topic, document:

| Field | Required information |
| ----- | ----- |
| Topic name | Fully qualified ROS 2 topic |
| Message type | Exact package and message name |
| Publisher | Node and process |
| Subscriber | Node and process |
| QoS | Reliability, history, depth, deadline and lifespan |
| Header timestamp | Whether the message contains a usable timestamp |
| Correlation field | Field used to associate messages across stages |
| Value fields | Fields that must be retained for analysis |
| Expected frequency | Nominal publication frequency |
| Trace events | Events used to determine publish, arrival and output time |

### **Step 3 — Determine the timestamp sources**

Document the meaning and source of each timestamp:

| Timestamp | Meaning | Candidate source |
| ----- | ----- | ----- |
| `t_source` | Time represented by the sensor data | Message header or source metadata |
| `t_publish` | ROS 2 publication time | ROS 2 tracepoint or custom tracepoint |
| `t_arrival` | Subscription callback start | `ros2_tracing` |
| `t_callback_end` | Callback completion | `ros2_tracing` |
| `t_output` | Downstream publication time | ROS 2 tracepoint |
| `t_observation` | Time the LSEU observes the event | LSEU integration tracepoint |
| `t_verdict` | Time the LSEU publishes a verdict | Verdict message and tracepoint |
| `t_fault` | Actual fault-onset time | Fault-controller tracepoint |

The document must explain:

* which timestamps use message-header time;  
* which timestamps use an operating-system clock;  
* which timestamps are extracted from LTTng;  
* whether timestamps are wall-clock or monotonic;  
* how timestamps from different sources will be aligned;  
* how clock adjustments or discontinuities will be detected;  
* the expected timestamp unit and precision.

### **Step 4 — Determine which message values must be recorded**

For each monitored topic, select the minimum fields needed to:

* identify the message;  
* correlate it with upstream and downstream messages;  
* confirm that the data is valid;  
* distinguish repeated or duplicate samples;  
* reproduce the reported metrics.

The students should not automatically store complete point-cloud values in tabular traces. Large payloads may remain in the rosbag while the trace dataset stores:

* topic name;  
* message type;  
* sequence or correlation identifier;  
* header timestamp;  
* publication timestamp;  
* selected status or summary fields;  
* payload size;  
* content hash when useful.

For smaller messages, selected values may be exported directly.

### **Step 5 — Test command-line message inspection**

Inspect a single message:

ros2 topic echo /perception/tracked\_objects \--once

Display selected fields when supported:

ros2 topic echo \<topic\> \\  
  \--field \<field\_path\>

Record text output:

timeout 10s ros2 topic echo \<topic\> \\  
  \> logs/topic\_values.txt

This is suitable for learning and spot checks. It is not the primary timing-measurement method because terminal output and formatting introduce unnecessary overhead.

### **Step 6 — Record monitored messages with rosbag2**

Create a bag containing:

ros2 bag record \\  
  /sensing/lidar/pointcloud \\  
  /perception/detected\_objects \\  
  /perception/tracked\_objects \\  
  /planning/trajectory \\  
  /monitoring/verdict \\  
  \-o raw\_data/\<run\_id\>/messages

After recording:

ros2 bag info raw\_data/\<run\_id\>/messages \\  
  | tee raw\_data/\<run\_id\>/bag\_info.txt

The documentation must explain:

* selected topics;  
* bag storage format;  
* configured QoS overrides, if any;  
* file naming;  
* start and stop procedure;  
* how incomplete bags are identified;  
* how bag timestamps differ from message-header timestamps;  
* how values will later be extracted.

### **Step 7 — Create a ROS 2 execution trace**

Start a trace interactively:

export ROS\_TRACE\_DIR="$PWD/raw\_data/\<run\_id\>/tracing"  
ros2 trace

For automated trials, create a launch file or script using the `Trace` launch action so tracing begins and ends with the experiment.

At minimum, enable events needed to identify:

* publication;  
* subscription callback start;  
* subscription callback end;  
* node and process identity;  
* executor activity where needed;  
* custom fault events;  
* custom LSEU observation and verdict events.

By default, `ros2 trace` writes a timestamped trace session, and its output directory can be controlled with `ROS_TRACE_DIR`.

### **Step 8 — Configure CycloneDDS diagnostic tracing**

Prepare a diagnostic CycloneDDS configuration, separate from the low-overhead final experiment configuration.

Example structure:

\<CycloneDDS xmlns="https://cdds.io/config"\>  
  \<Domain id="any"\>  
    \<Tracing\>  
      \<Verbosity\>config\</Verbosity\>  
      \<OutputFile\>  
        ${HOME}/dds/log/cdds.log.${CYCLONEDDS\_PID}  
      \</OutputFile\>  
    \</Tracing\>  
  \</Domain\>  
\</CycloneDDS\>

Activate it with:

export CYCLONEDDS\_URI=file://$PWD/config/cyclonedds\_diagnostic.xml

Use CycloneDDS diagnostic tracing to verify:

* loaded configuration;  
* participant and endpoint discovery;  
* transport or network errors;  
* QoS and configuration problems;  
* unexpected communication paths.

CycloneDDS’s `config` verbosity records the interpreted configuration along with warnings and errors, making it useful for configuration verification.

High-volume DDS tracing shall not be enabled during final timing trials unless its overhead has been evaluated and it is explicitly part of every compared condition.

### **Step 9 — Monitor Linux network and process activity**

Record interface counters before and after a run:

ip \-s link \> logs/network\_before.txt

\# Run the experiment

ip \-s link \> logs/network\_after.txt

Record network sockets and processes:

ss \-uapn \> logs/udp\_sockets.txt  
ss \-tapn \> logs/tcp\_sockets.txt

ps \-eo pid,ppid,psr,%cpu,%mem,rss,vsz,cmd \\  
  \> logs/processes.txt

Optionally record interface throughput with available Linux tools:

sar \-n DEV 1 \> logs/network\_rate.txt

or:

pidstat \-u \-r \-p \<PID\_LIST\> 1 \\  
  \> logs/process\_resources.txt

Packet capture may be used only for diagnosis and must avoid capturing unrelated network traffic. When used, document:

* selected interface;  
* capture filter;  
* file permissions;  
* start and stop times;  
* privacy and storage handling;  
* whether DDS shared-memory communication bypasses the selected network interface.

Example restricted capture:

sudo tcpdump \\  
  \-i \<interface\> \\  
  \-s 128 \\  
  \-w raw\_data/\<run\_id\>/dds\_headers.pcap \\  
  '\<approved DDS/RTPS filter\>'

Packet capture is not the primary source of ROS 2 application timestamps or message values.

### **Step 10 — Create a small monitored-message trace prototype**

Create a prototype that exports at least ten correlated messages through the chain.

The output should contain one row per message event:

run\_id  
message\_id  
topic  
node  
event\_type  
source\_timestamp\_ns  
event\_timestamp\_ns  
selected\_value  
payload\_size  
process\_id  
thread\_id

Required event types include:

PUBLISH  
CALLBACK\_START  
CALLBACK\_END  
LSEU\_OBSERVE  
LSEU\_VERDICT  
FAULT\_ONSET

Example output:

run\_id,message\_id,topic,node,event\_type,source\_timestamp\_ns,event\_timestamp\_ns,selected\_value  
TRACE\_TEST\_001,1842,/sensing/lidar/pointcloud,n0,PUBLISH,1000000000,1000124300,points=124800  
TRACE\_TEST\_001,1842,/sensing/lidar/pointcloud,n1,CALLBACK\_START,1000000000,1000912700,points=124800  
TRACE\_TEST\_001,1842,/perception/detected\_objects,n1,PUBLISH,1000000000,1041154300,objects=7

The prototype must show that message identity, timestamp, and selected values can be reconstructed together.

### **Step 11 — Deliver the monitoring and tracing document**

Create:

docs/network\_monitoring\_and\_message\_tracing.md

Target length:

4–8 pages, excluding command output and appendices

Required sections:

1. Purpose and monitoring scope.  
2. Four-node communication diagram.  
3. Topic and message inventory.  
4. Timestamp definitions.  
5. Message-correlation method.  
6. Message-value recording method.  
7. ROS 2 graph-inspection commands.  
8. Rosbag2 recording procedure.  
9. `ros2_tracing` procedure.  
10. CycloneDDS diagnostic-tracing procedure.  
11. Linux process and network-monitoring commands.  
12. Storage format and directory structure.  
13. Trace-overhead considerations.  
14. Data-quality checks.  
15. Known limitations.  
16. Example correlated trace.

## **Definition of done**

Task 1 is complete when:

1. Autoware runs in the approved test configuration.  
2. The four monitored topics are identified.  
3. The publishers and subscribers are documented.  
4. Runtime QoS is recorded.  
5. The timestamp source for every required event is defined.  
6. Required message-value fields are defined.  
7. Rosbag2 records the monitored topics.  
8. `ros2_tracing` records publish and callback events.  
9. CycloneDDS diagnostic logs can be generated.  
10. Linux network and process measurements can be recorded.  
11. At least ten messages are correlated through the chain.  
12. The prototype dataset includes timestamps and selected values.  
13. `network_monitoring_and_message_tracing.md` is delivered.  
14. The researcher approves the document before interface work begins.

## **Business rules**

1. `ros2 topic echo` is for inspection and validation, not primary final-experiment measurement.  
2. Rosbag2 is the durable source for message payloads and values.  
3. ROS 2/LTTng traces are the primary source for callback and publication timing.  
4. CycloneDDS tracing is primarily diagnostic unless explicitly approved for final trials.  
5. High-overhead recording tools must not be enabled in only one comparison condition.  
6. All timestamp sources and clock domains must be documented.  
7. Raw bags, traces, and packet captures must be immutable after archival.  
8. Network captures must use narrow filters and avoid unrelated traffic.  
9. The students work jointly and decide their own internal work division.  
10. Both students are responsible for the document and prototype demonstration.

---

# **Task 2 — Define the LSEU ROS 2/Autoware Interface and Integrate It**

## **Schedule**

Week 3 and 4

## **Description**

Study the researcher-provided C++ LSEU implementation and list of specifications. Jointly define how the existing LSEU code will interact with ROS 2, CycloneDDS, Autoware topics, tracepoints, configuration files, and experiment-control components.

The students will produce an interface specification before implementing adapters or integration code.

## **Inputs supplied by the researcher**

The researcher shall provide:

* C++ LSEU source code;  
* build dependencies;  
* LSEU public classes and methods;  
* configuration parameters;  
* monitored-property specifications;  
* timing parameters;  
* verdict semantics;  
* expected failure reasons;  
* output-suppression requirements;  
* thread-safety assumptions;  
* ownership and lifetime assumptions;  
* expected behavior for missing, late, duplicated, or invalid messages.

## **Steps**

### **Step 1 — Review the C++ code and specification**

The students shall identify:

* public methods;  
* constructors and initialization requirements;  
* input event structure;  
* output verdict structure;  
* time representation;  
* clock assumptions;  
* timer dependencies;  
* required callback ordering;  
* state retained between messages;  
* maximum number of pending evaluations;  
* error and exception behavior;  
* thread-safety requirements;  
* configuration inputs.

Create a question and assumption log:

docs/lseu\_questions\_and\_assumptions.md

Every unresolved interface assumption must be reviewed with the researcher.

### **Step 2 — Define the monitored-event interface**

Specify the structure passed from ROS 2/Autoware adapters to the LSEU.

Example conceptual structure:

struct MonitoredEvent  
{  
  std::string node\_id;  
  std::string topic\_name;  
  std::string message\_id;

  int64\_t source\_timestamp\_ns;  
  int64\_t observation\_timestamp\_ns;

  uint64\_t payload\_size\_bytes;  
  EventType event\_type;

  std::optional\<int64\_t\> lifespan\_ns;  
  std::optional\<MessageSummary\> value\_summary;  
};

The final structure must be based on the actual C++ implementation and researcher specifications.

Define supported event types, such as:

SOURCE\_PUBLISH  
MESSAGE\_ARRIVAL  
CALLBACK\_START  
CALLBACK\_END  
NODE\_OUTPUT  
FAULT\_ONSET  
NODE\_TERMINATION

### **Step 3 — Define message adapters**

For each monitored Autoware topic, specify an adapter that extracts:

* message identifier;  
* source timestamp;  
* selected values;  
* payload or serialized size;  
* applicable lifespan;  
* node and topic identifier;  
* observation time.

Create an adapter table:

| Topic | ROS message type | ID source | Time source | Extracted values | LSEU event |
| ----- | ----- | ----- | ----- | ----- | ----- |
| `/sensing/lidar/pointcloud` | Exact type | To define | Header/source | Point count, dimensions or hash | Source event |
| `/perception/detected_objects` | Exact type | To define | Header/source | Object count and selected status | Detector output |
| `/perception/tracked_objects` | Exact type | To define | Header/source | Track count and selected status | Tracker output |
| `/planning/trajectory` | Exact type | To define | Header/source | Point count and validity status | Planner output |

### **Step 4 — Define the ROS 2 component boundary**

Determine whether the integration will use:

* an LSEU ROS 2 component co-located with each monitored node;  
* an adapter component and plain C++ LSEU library;  
* composition within an existing Autoware component container;  
* another researcher-approved architecture.

Document:

* process boundary;  
* component boundary;  
* DDS-participant implications;  
* callback group;  
* executor;  
* threading;  
* timer ownership;  
* node lifetime;  
* startup and shutdown sequence.

### **Step 5 — Define the verdict message**

Create or approve a ROS 2 message containing at least:

std\_msgs/Header header

string trial\_id  
string evaluation\_id  
string message\_id  
string node\_id  
string monitored\_topic

bool verdict  
uint8 reason\_code

int64 source\_timestamp\_ns  
int64 observation\_timestamp\_ns  
int64 verdict\_timestamp\_ns  
int64 slack\_remaining\_ns

Consider adding:

int64 expected\_window\_start\_ns  
int64 expected\_window\_end\_ns  
int64 actual\_event\_timestamp\_ns  
string lseu\_version

The interface specification must define:

* meaning of each field;  
* units;  
* valid ranges;  
* clock domain;  
* required and optional fields;  
* reason-code enumeration;  
* behavior when a timestamp is unavailable.

### **Step 6 — Define the configuration interface**

Create a versioned configuration format:

node\_id: n2\_lseu  
monitored\_input: /perception/detected\_objects  
monitored\_output: /perception/tracked\_objects

timing:  
  source\_period\_ms: 100  
  source\_lifespan\_ms: 100  
  upstream\_wcet\_ms: 40  
  node\_wcet\_ms: 20  
  planner\_wcet\_ms: 30  
  planner\_deadline\_ms: 100

monitoring:  
  maximum\_pending\_evaluations: 1  
  publish\_true\_verdicts: true  
  publish\_false\_verdicts: true

The configuration file shall expose approved parameters without duplicating or redefining LSEU algorithm logic.

### **Step 7 — Define tracing hooks**

Specify custom tracepoints for:

lseu\_event\_received  
lseu\_evaluation\_created  
lseu\_timer\_armed  
lseu\_timer\_cancelled  
lseu\_timer\_expired  
lseu\_verdict\_created  
lseu\_verdict\_published  
planner\_output\_suppressed

Each tracepoint should include, where applicable:

* trial ID;  
* evaluation ID;  
* message ID;  
* node ID;  
* topic;  
* event timestamp;  
* deadline or window;  
* verdict;  
* reason code;  
* remaining slack.

### **Step 8 — Define error handling**

Specify behavior for:

* missing message header;  
* invalid timestamp;  
* duplicate message identifier;  
* out-of-order event;  
* unsupported message type;  
* missing configuration;  
* timer-creation failure;  
* verdict-publication failure;  
* LSEU exception;  
* shutdown with pending evaluations.

The system must log and trace interface errors without silently changing the monitoring decision.

### **Step 9 — Create the interface specification**

Deliver:

docs/lseu\_ros2\_autoware\_interface.md

Required sections:

1. Scope.  
2. Researcher and student responsibilities.  
3. LSEU C++ API summary.  
4. ROS 2 component architecture.  
5. Monitored-event structure.  
6. Topic adapters.  
7. Timestamp and clock semantics.  
8. Correlation identifiers.  
9. Verdict-message definition.  
10. Configuration schema.  
11. Tracepoints.  
12. Threading and executor model.  
13. Error handling.  
14. Startup and shutdown behavior.  
15. Sequence diagrams.  
16. Acceptance tests.  
17. Open issues and approved assumptions.

### **Step 10 — Review and approve the interface**

Hold an interface-review meeting with the researcher.

Record:

* accepted decisions;  
* requested changes;  
* unresolved risks;  
* interface version;  
* approval date.

No full integration shall begin until the researcher approves the specification.

### **Step 11 — Implement the integration layer**

After approval, the students may create:

* ROS 2 message packages;  
* adapter components;  
* configuration loaders;  
* launch files;  
* composition files;  
* custom tracepoints;  
* fault-controller integration;  
* verdict recorder;  
* output-suppression adapter when required.

The students must use the researcher’s LSEU C++ implementation as the monitoring engine.

### **Step 12 — Run interface acceptance tests**

Test:

1. Component startup.  
2. Configuration loading.  
3. One valid monitored event.  
4. One malformed event.  
5. One duplicate event.  
6. One out-of-order event.  
7. One expected `TRUE` verdict.  
8. One expected `FALSE` verdict supplied by the researcher as a test vector.  
9. Verdict-message field population.  
10. Message and verdict correlation.  
11. Tracepoint generation.  
12. Clean shutdown.  
13. Shutdown with one pending evaluation.  
14. Rosbag recording.  
15. Process and resource recording.

Algorithmic expected results for test vectors must be supplied or approved by the researcher.

## **Definition of done**

Task 2 is complete when:

1. The C++ LSEU API has been reviewed.  
2. All interface assumptions are documented.  
3. The monitored-event structure is defined.  
4. Adapters for the four monitored topics are defined.  
5. Timestamp and clock semantics are documented.  
6. The ROS 2 component architecture is defined.  
7. The verdict-message format is approved.  
8. The configuration schema is approved.  
9. Custom tracepoints are defined.  
10. Error and shutdown behavior is defined.  
11. `lseu_ros2_autoware_interface.md` is approved.  
12. Integration code builds successfully.  
13. Interface acceptance tests pass.  
14. Monitored messages, values, timestamps, and verdicts can be correlated.  
15. A pilot trace demonstrates the full source-to-verdict path.  
16. The researcher authorizes experimental pilots.

## **Business rules**

1. Interface definition must precede implementation.  
2. The monitoring-and-tracing document from Task 1 must be approved first.  
3. The students may implement ROS 2 integration code.  
4. The students shall not independently change LSEU predicates or verdict semantics.  
5. Timing units and clock domains must be explicit in every interface.  
6. All ROS 2 message fields must have documented meaning.  
7. Every verdict must include a correlation identifier.  
8. Missing timestamps must produce explicit interface errors or defined fallback behavior.  
9. Configuration files must be versioned and hashed.  
10. Tracepoints must not contain complete large payloads.  
11. Interface changes after pilot approval require a new interface version.  
12. LSEU source changes must be made or approved by the researcher.  
13. Integration defects and algorithm defects must be classified separately.  
14. Both students are jointly responsible for the interface document and integration.  
15. The researcher’s approval is required before proceeding to final experiments.

---

# **Task 3 — Execute Experiments and Collect Metrics**

## **Schedule**

Weeks 5 and 6

## **Description**

After the interface and integration have been approved, execute the previously defined nominal, F1, F2, F3, monitor-resilience, resource-overhead, and latency experiments.

Task 3 retains the previously defined requirements for:

* 30 valid independent runs per primary fault class and approach;  
* 60-second runs;  
* fault activation at 20 seconds;  
* Linux-based CPU and memory recording;  
* rosbag2 message recording;  
* ROS 2/LTTng tracing;  
* measured fault-onset timestamps;  
* message and verdict correlation;  
* trial validation and replacement;  
* time-to-verdict analysis;  
* planner-output and suppression analysis;  
* monitoring-coverage analysis;  
* CPU and memory overhead;  
* median and 99th-percentile end-to-end latency;  
* CDFs, box plots, tables, and reproducibility artifacts.

Additional Task 3 validity rule:

> A trial is invalid when the monitored message, its selected value, its source timestamp, the relevant callback events, and its associated verdict cannot be correlated using the approved Task 1 and Task 2 procedures.

