# Minimal overlay of autoware_vehicle_msgs/msg/VelocityReport.
# Wire-faithful to the real Autoware type (name-only discovery), so a node built
# against this overlay interoperates with real AWSIM/Autoware endpoints.
std_msgs/Header header
float32 longitudinal_velocity
float32 lateral_velocity
float32 heading_rate
