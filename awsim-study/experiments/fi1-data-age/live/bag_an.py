# summarize an FI1 live bag: what Autoware did with the velocity channel
import sys, math, rosbag2_py
from rclpy.serialization import deserialize_message
from rosidl_runtime_py.utilities import get_message
r = rosbag2_py.SequentialReader()
r.open(rosbag2_py.StorageOptions(uri=sys.argv[1], storage_id='sqlite3'), rosbag2_py.ConverterOptions('cdr','cdr'))
types = {t.name: get_message(t.type) for t in r.get_all_topics_and_types()}
S = {k: [] for k in ('conv','ks_v','ks_xy','nvtl','init','ctl')}
while r.has_next():
    topic, data, t = r.read_next(); m = deserialize_message(data, types[topic]); t /= 1e9
    if topic.endswith('twist_with_covariance'): S['conv'].append((t, m.twist.twist.linear.x))
    elif topic == '/localization/kinematic_state':
        S['ks_v'].append((t, m.twist.twist.linear.x)); S['ks_xy'].append((t, m.pose.pose.position.x, m.pose.pose.position.y))
    elif topic.endswith('likelihood'): S['nvtl'].append((t, m.data))
    elif topic.endswith('initialization_state'): S['init'].append((t, m.state))
    elif topic.endswith('control_cmd'): S['ctl'].append((t, m.longitudinal.velocity, m.longitudinal.acceleration))
def rng(xs): return f"[{min(xs):.2f}..{max(xs):.2f}]" if xs else "n/a"
print(f"  converter twist.x  {rng([v for _,v in S['conv']])} (n={len(S['conv'])})")
print(f"  EKF velocity       {rng([v for _,v in S['ks_v']])}")
if S['ks_xy']:
    (_,x0,y0),(_,x1,y1) = S['ks_xy'][0], S['ks_xy'][-1]
    print(f"  EKF pose moved     {math.hypot(x1-x0,y1-y0):.2f} m over bag")
n = [v for _,v in S['nvtl']]
print(f"  NVTL               start={n[0]:.2f} min={min(n):.2f} end={n[-1]:.2f}" if n else "  NVTL n/a")
print(f"  init_state seen    {sorted({s for _,s in S['init']})}")
print(f"  control_cmd v/a    v{rng([c[1] for c in S['ctl']])} a{rng([c[2] for c in S['ctl']])}")
