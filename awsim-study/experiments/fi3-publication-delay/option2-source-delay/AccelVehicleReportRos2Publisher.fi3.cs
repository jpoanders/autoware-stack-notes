// Copyright 2025 TIER IV, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// ============================================================================
// FI3 — Publication Delay (option 2: sensor-source delay). FAULT-INJECTION COPY.
//
// This is a modified copy of AWSIM v2.0.1's
//   Assets/Awsim/Scripts/Entity/Vehicle/AccelVehicle/Ros2/AccelVehicleReportRos2Publisher.cs
// (upstream `awsim` @ 9e55528, see src/REPOS.md). It inserts a controllable
// delay + jitter before the *velocity* report is published, leaving the other
// five status reports on their nominal 30 Hz cadence, so the injected delay is
// isolated to rt/vehicle/status/velocity_status (the SEU / FI1 target channel).
//
// The fault is OFF by default (`_fi3Enabled = false`) and is reverted by
// unchecking that box or restoring the upstream file — no rebuild is needed to
// disable it at runtime once the toggle is exposed in the Inspector.
//
// All FI3 additions are marked `// FI3:`. To deploy: drop this into the AWSIM
// Unity project in place of the upstream file, compile in the Editor, and run.
// See README.md in this folder for the build/run procedure and caveats.
// ============================================================================

using System.Collections;   // FI3: coroutine (delayed emission)
using UnityEngine;
using ROS2;
using Awsim.Common;

namespace Awsim.Entity
{
    public class AccelVehicleReportRos2Publisher : MonoBehaviour
    {
        public string ControlModeReportTopic { get => _controlModeReportTopic; }
        public string GearReportTopic { get => _gearReportTopic; }
        public string SteeringReportTopic { get => _steeringReportTopic; }
        public string TurnIndicatorsReportTopic { get => _turnIndicatorsReportTopic; }
        public string HazardLightsReportTopic { get => _hazardLightsReportTopic; }
        public string VelocityReportTopic { get => _velocityReportTopic; }
        public string FrameId { get => _frameId; }
        public int PublishHz { get => _publishHz; }
        public QosSettings QosSettings { get => _qosSettings; }

        [SerializeField] AccelVehicle _vehicle;
        [SerializeField] AccelVehicleControlModeBasedInputter _controlModeBasedInputProvider;

        // Topics.
        [Header("Topic names")]
        [SerializeField] string _controlModeReportTopic = "/vehicle/status/control_mode";
        [SerializeField] string _gearReportTopic = "/vehicle/status/gear_status";
        [SerializeField] string _steeringReportTopic = "/vehicle/status/steering_status";
        [SerializeField] string _turnIndicatorsReportTopic = "/vehicle/status/turn_indicators_status";
        [SerializeField] string _hazardLightsReportTopic = "/vehicle/status/hazard_lights_status";
        [SerializeField] string _velocityReportTopic = "/vehicle/status/velocity_status";

        [Header("Publisher settings")]
        [SerializeField] string _frameId = "base_link";
        [SerializeField] int _publishHz = 30;
        [SerializeField] QosSettings _qosSettings;

        // FI3: ---- Publication-delay fault injection (velocity channel only) ----
        [Header("FI3 — publication delay (fault injection; OFF by default)")]
        [Tooltip("FI3: master switch. When false this behaves exactly like upstream.")]
        [SerializeField] bool _fi3Enabled = false;
        [Tooltip("FI3: mean delay applied before each velocity report is published, in ms. " +
                 "0 = no delay. A value > ~1000/PublishHz stretches the inter-arrival period.")]
        [SerializeField] float _fi3DelayMeanMs = 0f;
        [Tooltip("FI3: uniform +/- jitter added to the mean delay, in ms. 0 = fixed delay. " +
                 "Nonzero produces jittered publication (variable inter-arrival).")]
        [SerializeField] float _fi3DelayJitterMs = 0f;
        [Tooltip("FI3: use unscaled (wall-clock) time for the delay so it is independent of " +
                 "Unity's Time.timeScale. Leave true for a real publication delay.")]
        [SerializeField] bool _fi3UseRealtime = true;
        // FI3: ----------------------------------------------------------------

        // Msgs.
        autoware_vehicle_msgs.msg.ControlModeReport _controlModeReportMsg;
        autoware_vehicle_msgs.msg.GearReport _gearReportMsg;
        autoware_vehicle_msgs.msg.SteeringReport _steeringReportMsg;
        autoware_vehicle_msgs.msg.TurnIndicatorsReport _turnIndicatorsReportMsg;
        autoware_vehicle_msgs.msg.HazardLightsReport _hazardLightsReportMsg;
        autoware_vehicle_msgs.msg.VelocityReport _velocityReportMsg;

        // Publishers.
        IPublisher<autoware_vehicle_msgs.msg.ControlModeReport> _controlModeReportPublisher;
        IPublisher<autoware_vehicle_msgs.msg.GearReport> _gearReportPublisher;
        IPublisher<autoware_vehicle_msgs.msg.SteeringReport> _steeringReportPublisher;
        IPublisher<autoware_vehicle_msgs.msg.TurnIndicatorsReport> _turnIndicatorsReportPublisher;
        IPublisher<autoware_vehicle_msgs.msg.HazardLightsReport> _hazardLightsReportPublisher;
        IPublisher<autoware_vehicle_msgs.msg.VelocityReport> _velocityReportPublisher;



        public void Initialize()
        {
            var qos = _qosSettings.GetQosProfile();

            // Create publishers.
            _controlModeReportPublisher = AwsimRos2Node.CreatePublisher<autoware_vehicle_msgs.msg.ControlModeReport>(_controlModeReportTopic, qos);
            _gearReportPublisher = AwsimRos2Node.CreatePublisher<autoware_vehicle_msgs.msg.GearReport>(_gearReportTopic, qos);
            _steeringReportPublisher = AwsimRos2Node.CreatePublisher<autoware_vehicle_msgs.msg.SteeringReport>(_steeringReportTopic, qos);
            _turnIndicatorsReportPublisher = AwsimRos2Node.CreatePublisher<autoware_vehicle_msgs.msg.TurnIndicatorsReport>(_turnIndicatorsReportTopic, qos);
            _hazardLightsReportPublisher = AwsimRos2Node.CreatePublisher<autoware_vehicle_msgs.msg.HazardLightsReport>(_hazardLightsReportTopic, qos);
            _velocityReportPublisher = AwsimRos2Node.CreatePublisher<autoware_vehicle_msgs.msg.VelocityReport>(_velocityReportTopic, qos);

            // Create msgs.
            _controlModeReportMsg = new autoware_vehicle_msgs.msg.ControlModeReport();
            _gearReportMsg = new autoware_vehicle_msgs.msg.GearReport();
            _steeringReportMsg = new autoware_vehicle_msgs.msg.SteeringReport();
            _turnIndicatorsReportMsg = new autoware_vehicle_msgs.msg.TurnIndicatorsReport();
            _hazardLightsReportMsg = new autoware_vehicle_msgs.msg.HazardLightsReport();
            _velocityReportMsg = new autoware_vehicle_msgs.msg.VelocityReport()
            {
                Header = new std_msgs.msg.Header()
                {
                    Frame_id = _frameId,
                }
            };

            // FI3: warn loudly if the fault is armed, so a delayed run is never mistaken for nominal.
            if (_fi3Enabled && _fi3DelayMeanMs > 0f)
            {
                Debug.LogWarning($"[FI3] Publication-delay fault ARMED on {_velocityReportTopic}: " +
                                 $"mean={_fi3DelayMeanMs} ms, jitter=+/-{_fi3DelayJitterMs} ms, " +
                                 $"realtime={_fi3UseRealtime}. Uncheck _fi3Enabled to disable.");
            }

            // Start publishing.
            InvokeRepeating(nameof(Publish), 0f, 1.0f / _publishHz);
        }

        public void Initialize(string controlModeReportTopic,
                            string gearReportTopic,
                            string steeringReportTopic,
                            string turnIndicatorsReportTopic,
                            string hazardLightsReportTopic,
                            string velocityReportTopic,
                            string frameId,
                            int publishHz,
                            QosSettings qosSettings)
        {
            _controlModeReportTopic = controlModeReportTopic;
            _gearReportTopic = gearReportTopic;
            _steeringReportTopic = steeringReportTopic;
            _turnIndicatorsReportTopic = turnIndicatorsReportTopic;
            _hazardLightsReportTopic = hazardLightsReportTopic;
            _velocityReportTopic = velocityReportTopic;
            _frameId = frameId;
            _publishHz = publishHz;
            _qosSettings = qosSettings;

            Initialize();
        }

        void Publish()
        {
            // Update msgs.
            var controlMode = AccelVehicleRos2MsgConverter.UnityToRos2ControlMode(_controlModeBasedInputProvider.ControlMode);                         // Control mode.
            _controlModeReportMsg.Mode = controlMode;
            _gearReportMsg.Report = AccelVehicleRos2MsgConverter.UnityToRos2Gear(_vehicle.Gear);                                 // Gear.
            _steeringReportMsg.Steering_tire_angle = -1 * _vehicle.SteerTireAngle * Mathf.Deg2Rad;                          // Steering.
            _turnIndicatorsReportMsg.Report = AccelVehicleRos2MsgConverter.UnityToRos2TurnIndicators(_vehicle.TurnIndicators);   // Turn indicators.
            _hazardLightsReportMsg.Report = AccelVehicleRos2MsgConverter.UnityToRos2HazardLights(_vehicle.HazardLights);         // Hazard lights.

            // Update Stamp
            // NOTE: It may be better to set the same time value for all of them. If so, create a new API in AwsimRos2Node?
            AwsimRos2Node.UpdateROSClockTime(_controlModeReportMsg.Stamp);
            AwsimRos2Node.UpdateROSClockTime(_gearReportMsg.Stamp);
            AwsimRos2Node.UpdateROSClockTime(_steeringReportMsg.Stamp);
            AwsimRos2Node.UpdateROSClockTime(_turnIndicatorsReportMsg.Stamp);
            AwsimRos2Node.UpdateROSClockTime(_hazardLightsReportMsg.Stamp);

            // Publish the five status reports on the nominal tick (unaffected by FI3).
            _controlModeReportPublisher.Publish(_controlModeReportMsg);
            _gearReportPublisher.Publish(_gearReportMsg);
            _steeringReportPublisher.Publish(_steeringReportMsg);
            _turnIndicatorsReportPublisher.Publish(_turnIndicatorsReportMsg);
            _hazardLightsReportPublisher.Publish(_hazardLightsReportMsg);

            // FI3: velocity report — emit immediately (nominal) or after an injected delay.
            if (_fi3Enabled && _fi3DelayMeanMs > 0f)
            {
                float jitter = _fi3DelayJitterMs > 0f
                    ? Random.Range(-_fi3DelayJitterMs, _fi3DelayJitterMs)
                    : 0f;
                float delaySec = Mathf.Max(0f, (_fi3DelayMeanMs + jitter) / 1000f);
                StartCoroutine(EmitVelocityReportDelayed(delaySec));
            }
            else
            {
                EmitVelocityReport();
            }
        }

        // FI3: build the current velocity sample, stamp it, and publish it. Runs atomically
        // on the main thread (no yield inside), so concurrent delayed emissions never interleave.
        // The value and header.stamp are taken at *emission* time, so a delayed sample carries a
        // fresh stamp but arrives late — the SEU sees increased inter-arrival / arrival-age, not a
        // back-dated stamp. (For a back-dated variant, snapshot the stamp at tick time instead.)
        void EmitVelocityReport()
        {
            var rosLinearVelocity = Ros2Utility.UnityToRos2Position(_vehicle.LocalVelocity);        // Velocity reports.
            var rosAngularVelocity = Ros2Utility.UnityToRos2Position(_vehicle.AngularVelocity);
            _velocityReportMsg.Longitudinal_velocity = rosLinearVelocity.x;
            _velocityReportMsg.Lateral_velocity = rosLinearVelocity.y;
            _velocityReportMsg.Heading_rate = rosAngularVelocity.z;

            var velocityReportMsgHeader = _velocityReportMsg as MessageWithHeader;
            AwsimRos2Node.UpdateROSTimestamp(ref velocityReportMsgHeader);

            _velocityReportPublisher.Publish(_velocityReportMsg);
        }

        // FI3: wait `delaySec`, then emit. WaitForSecondsRealtime is used when _fi3UseRealtime so the
        // delay is wall-clock and independent of Time.timeScale.
        IEnumerator EmitVelocityReportDelayed(float delaySec)
        {
            if (_fi3UseRealtime)
                yield return new WaitForSecondsRealtime(delaySec);
            else
                yield return new WaitForSeconds(delaySec);

            EmitVelocityReport();
        }

        void OnDestroy()
        {
            AwsimRos2Node.RemovePublisher<autoware_vehicle_msgs.msg.ControlModeReport>(_controlModeReportPublisher);
            AwsimRos2Node.RemovePublisher<autoware_vehicle_msgs.msg.GearReport>(_gearReportPublisher);
            AwsimRos2Node.RemovePublisher<autoware_vehicle_msgs.msg.SteeringReport>(_steeringReportPublisher);
            AwsimRos2Node.RemovePublisher<autoware_vehicle_msgs.msg.TurnIndicatorsReport>(_turnIndicatorsReportPublisher);
            AwsimRos2Node.RemovePublisher<autoware_vehicle_msgs.msg.HazardLightsReport>(_hazardLightsReportPublisher);
            AwsimRos2Node.RemovePublisher<autoware_vehicle_msgs.msg.VelocityReport>(_velocityReportPublisher);
        }
    }
}
