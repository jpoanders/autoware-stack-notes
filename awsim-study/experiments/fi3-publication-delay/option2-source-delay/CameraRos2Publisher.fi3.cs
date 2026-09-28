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
// FI3 — Publication Delay (perception-sensor variant). FAULT-INJECTION COPY.
//
// Modified copy of AWSIM v2.0.1's
//   Assets/Awsim/Scripts/Entity/Sensor/Camera/Ros2/CameraRos2Publisher.cs
// (upstream `awsim` @ 9e55528, see src/REPOS.md). It inserts a controllable
// delay + jitter before the camera image + camera_info are published, so the
// perception input (`/sensing/camera/traffic_light/image_raw`) arrives late —
// stressing the dependent traffic-light-recognition transformer's execution
// time (FI3's "processing overrun" case).
//
// This is a CLEAN C# edit because the camera publishes from C# via
// _imagePublisher.Publish(...). The LiDAR/radar point cloud CANNOT be delayed
// this way — it is published inside the native RGL plugin graph, not from C#
// (see RglLidarPublisher.cs and README.md §"LiDAR/radar").
//
// Fault OFF by default (`_fi3Enabled = false`). All additions marked `// FI3:`.
// ============================================================================

using System.Collections;   // FI3: coroutine (delayed emission)
using ROS2;
using UnityEngine;
using UnityEngine.Rendering;
using Awsim.Common;

namespace Awsim.Entity
{
    /// <summary>
    /// Convert the data output from CameraSensor to Ros2 msg and publish.
    /// Use Compute buffer to convert render texture into a byte array in bgr8 format.
    /// </summary>
    public class CameraRos2Publisher : MonoBehaviour
    {
        /// <summary>
        /// Ros2 topic name of image.
        /// </summary>
        public string ImageTopic { get => _imageTopic; }

        /// <summary>
        /// Ros2 topic name of camera info.
        /// </summary>
        public string CameraInfoTopic { get => _cameraInfoTopic; }

        /// <summary>
        /// Ros2 frame id of image and camra info topics. (using same frame id)
        /// </summary>
        public string FrameId { get => _frameId; }

        /// <summary>
        /// Ros2 quality of service settings of image and camera info. (using same qos)
        /// </summary>
        public QosSettings QosSettings { get => _qosSettings; }

        [SerializeField] string _imageTopic = "/sensing/camera/traffic_light/image_raw";
        [SerializeField] string _cameraInfoTopic = "/sensing/camera/traffic_light/camera_info";
        [SerializeField] string _frameId = "traffic_light_left_camera/camera_link";
        [SerializeField]
        QosSettings _qosSettings = new QosSettings(ReliabilityPolicy.QOS_POLICY_RELIABILITY_BEST_EFFORT,
                                                   DurabilityPolicy.QOS_POLICY_DURABILITY_VOLATILE,
                                                   HistoryPolicy.QOS_POLICY_HISTORY_KEEP_LAST,
                                                   1);

        // FI3: ---- Publication-delay fault injection (this camera's image + info) ----
        [Header("FI3 — publication delay (fault injection; OFF by default)")]
        [Tooltip("FI3: master switch. When false this behaves exactly like upstream.")]
        [SerializeField] bool _fi3Enabled = false;
        [Tooltip("FI3: mean delay applied before each image/camera_info publish, in ms. 0 = none.")]
        [SerializeField] float _fi3DelayMeanMs = 0f;
        [Tooltip("FI3: uniform +/- jitter added to the mean delay, in ms. 0 = fixed delay.")]
        [SerializeField] float _fi3DelayJitterMs = 0f;
        [Tooltip("FI3: wall-clock delay (WaitForSecondsRealtime), independent of Time.timeScale.")]
        [SerializeField] bool _fi3UseRealtime = true;
        // FI3: -----------------------------------------------------------------------

        [SerializeField] CameraSensor _cameraSensor = null;
        [SerializeField] ComputeShader _rosImageShader = null;

        const string _rosImageShaderKernel = "RosImageShaderKernel";
        IPublisher<sensor_msgs.msg.Image> _imagePublisher;
        IPublisher<sensor_msgs.msg.CameraInfo> _cameraInfoPublisher;
        sensor_msgs.msg.Image _imageMsg;
        sensor_msgs.msg.CameraInfo _cameraInfoMsg;
        int _rosImageShaderKernalIdx = 0;
        int _rosImageShaderGroupSizeX = 0;
        ComputeBuffer _computeBuffer = null;
        byte[] _imageDataBuffer = null;

        /// <summary>
        /// Initialize camera sensors's ros2 publisher.
        /// </summary>
        public void Initialize()
        {
            const string _bgr8 = "bgr8";
            const string _plumb_bob = "plumb_bob";

            // Create image msg.
            _imageMsg = new sensor_msgs.msg.Image()
            {
                Header = new std_msgs.msg.Header()
                {
                    Frame_id = _frameId
                },
                Encoding = _bgr8,
                Is_bigendian = 0,
            };

            // Create camera info msg.
            _cameraInfoMsg = new sensor_msgs.msg.CameraInfo()
            {
                Header = new std_msgs.msg.Header()
                {
                    Frame_id = _frameId
                },
                Distortion_model = _plumb_bob,
                Binning_x = 0,
                Binning_y = 0,
                Roi = new sensor_msgs.msg.RegionOfInterest()
                {
                    X_offset = 0,
                    Y_offset = 0,
                    Height = 0,
                    Width = 0,
                    Do_rectify = false,
                }
            };

            var R = new double[]
            {
                1.0, 0.0, 0.0,
                0.0, 1.0, 0.0,
                0.0, 0.0, 1.0
            };

            for (int i = 0; i < R.Length; i++)      // Set the rectification matrix for monocular camera
                _cameraInfoMsg.R[i] = R[i];

            // Create publisher.
            var qos = _qosSettings.GetQosProfile();
            _imagePublisher = AwsimRos2Node.CreatePublisher<sensor_msgs.msg.Image>(_imageTopic, qos);
            _cameraInfoPublisher = AwsimRos2Node.CreatePublisher<sensor_msgs.msg.CameraInfo>(_cameraInfoTopic, qos);

            // Find shader kernel.
            _rosImageShaderKernalIdx = _rosImageShader.FindKernel(_rosImageShaderKernel);

            // FI3: warn loudly if the fault is armed.
            if (_fi3Enabled && _fi3DelayMeanMs > 0f)
            {
                Debug.LogWarning($"[FI3] Publication-delay fault ARMED on {_imageTopic}: " +
                                 $"mean={_fi3DelayMeanMs} ms, jitter=+/-{_fi3DelayJitterMs} ms, " +
                                 $"realtime={_fi3UseRealtime}. Uncheck _fi3Enabled to disable.");
            }

            // Set callbacks.
            _cameraSensor.OnOutput += Publish;
        }

        /// <summary>
        /// Initialize camera sensors's ros2 publisher.
        /// </summary>
        /// <param name="imageTopic">Ros2 topic name of image.</param>
        /// <param name="cameraInfoTopic">Ros2 topic name of camera info.</param>
        /// <param name="frameId">Ros2 frame id of image and camera info topics. (using same frame id)</param>
        /// <param name="qosSettings">Ros2 quality of service settings of image and camera info. (using same qos)</param>
        public void Initialize(string imageTopic, string cameraInfoTopic, string frameId, QosSettings qosSettings)
        {
            _imageTopic = imageTopic;
            _cameraInfoTopic = cameraInfoTopic;
            _frameId = frameId;
            _qosSettings = qosSettings;

            Initialize();
        }

        void Publish(CameraSensor.IReadOnlyOutputData outputData)
        {
            const int bytesPerPixel = 3;
            const string shaderWidth = "_width";
            const string shaderHeight = "_height";
            const string shaderInputTexture = "_InputTexture";
            const string shaderRosImageBuffer = "_RosImageBuffer";

            var cameraParameters = outputData.CameraParameters;
            var renderTexture = outputData.OutputRenderTexture;

            // Match msgs to camera parameter values.
            if (_imageMsg.Width != cameraParameters.Width || _imageMsg.Height != cameraParameters.Height)
            {
                // Update image msg.
                _imageMsg.Width = (uint)cameraParameters.Width;
                _imageMsg.Height = (uint)cameraParameters.Height;
                _imageMsg.Step = (uint)(cameraParameters.Width * 3);
                _imageMsg.Data = new byte[cameraParameters.Height * cameraParameters.Width * 3];

                // Update camera info msg.
                _cameraInfoMsg.Width = (uint)cameraParameters.Width;
                _cameraInfoMsg.Height = (uint)cameraParameters.Height;

                var D = cameraParameters.GetDistortionCoefficients();
                if (!D.Equals(_cameraInfoMsg.D))
                    _cameraInfoMsg.D = cameraParameters.GetDistortionCoefficients();

                var K = cameraParameters.GetCameraMatrix();
                if (!K.Equals(_cameraInfoMsg.K))
                {
                    for (int i = 0; i < K.Length; i++)
                        _cameraInfoMsg.K[i] = K[i];
                }

                var P = cameraParameters.GetProjectionMatrix();
                if (!P.Equals(_cameraInfoMsg.P))
                {
                    for (int i = 0; i < P.Length; i++)
                        _cameraInfoMsg.P[i] = P[i];
                }

                // Configure distortion shader buffers.
                // RosImageShader translates Texture2D to ROS image by encoding two pixels color (bgr8 -> 3 bytes) int one uint32 (4 bytes).
                var rosImageBufferSize = (cameraParameters.Width * cameraParameters.Height * bytesPerPixel) / sizeof(uint);
                if (_computeBuffer == null || _computeBuffer.count != rosImageBufferSize)
                {
                    _computeBuffer = new ComputeBuffer(rosImageBufferSize, sizeof(uint));
                    _imageDataBuffer = new byte[cameraParameters.Width * cameraParameters.Height * bytesPerPixel];
                }

                _rosImageShader.GetKernelThreadGroupSizes(_rosImageShaderKernalIdx, out var rosImageShaderThreadsPerGroupX, out _, out _);
                _rosImageShaderGroupSizeX = (((cameraParameters.Width * cameraParameters.Height) * sizeof(uint)) / ((int)rosImageShaderThreadsPerGroupX * sizeof(uint)));

                _rosImageShader.SetInt(shaderWidth, cameraParameters.Width);
                _rosImageShader.SetInt(shaderHeight, cameraParameters.Height);
            }

            // Apply ros image shader.
            _rosImageShader.SetTexture(_rosImageShaderKernalIdx, shaderInputTexture, renderTexture);
            _rosImageShader.SetBuffer(_rosImageShaderKernalIdx, shaderRosImageBuffer, _computeBuffer);
            _rosImageShader.Dispatch(_rosImageShaderKernalIdx, _rosImageShaderGroupSizeX, 1, 1);

            AsyncGPUReadback.Request(_computeBuffer, OnRequest);

            void OnRequest(AsyncGPUReadbackRequest request)
            {
                if (request.hasError)
                {
                    Debug.LogWarning("AsyncGPUReadback error");
                    return;
                }
                request.GetData<byte>().CopyTo(_imageDataBuffer);

                // TODO: Currently, publishing is not asynchronous because AsyncCPUReadback requests are slow.
                //       Investigate the impact of async publishing.
            }

            _imageMsg.Data = _imageDataBuffer;

            // FI3: emit immediately (nominal) or after an injected publication delay.
            if (_fi3Enabled && _fi3DelayMeanMs > 0f)
            {
                float jitter = _fi3DelayJitterMs > 0f
                    ? Random.Range(-_fi3DelayJitterMs, _fi3DelayJitterMs)
                    : 0f;
                float delaySec = Mathf.Max(0f, (_fi3DelayMeanMs + jitter) / 1000f);
                StartCoroutine(EmitImageDelayed(delaySec));
            }
            else
            {
                EmitImage();
            }
        }

        // FI3: stamp (at emission time) and publish the image + camera_info. The stamp is fresh
        // but the sample arrives late, so the consumer sees increased inter-arrival / arrival-age.
        // NOTE: _imageMsg/_imageDataBuffer are reused buffers; a delay longer than the frame
        // period will emit the most recent frame's pixels. For a strict per-frame snapshot, copy
        // _imageDataBuffer here before publishing (heavier — one image-sized alloc per frame).
        void EmitImage()
        {
            AwsimRos2Node.UpdateROSClockTimes(_imageMsg.Header.Stamp, _cameraInfoMsg.Header.Stamp);
            _imagePublisher.Publish(_imageMsg);
            _cameraInfoPublisher.Publish(_cameraInfoMsg);
        }

        // FI3: wait `delaySec`, then emit.
        IEnumerator EmitImageDelayed(float delaySec)
        {
            if (_fi3UseRealtime)
                yield return new WaitForSecondsRealtime(delaySec);
            else
                yield return new WaitForSeconds(delaySec);

            EmitImage();
        }
    }
}
