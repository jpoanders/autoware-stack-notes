#!/usr/bin/env bash
# run_live.sh NAME DUR [FI3_*=...]  — FI3 Stage D2, one case per AWSIM launch.
# Relaunches AWSIM under the shim with the given env, resets Autoware (localize + 60 m route),
# starts fi1's run_case.sh (bag + tap + checker), engages at T_ENGAGE s after launch.
# FI3_START_S counts from AWSIM's first velocity write (~launch), so a mid-drive fault is
# START_S ~= T_ENGAGE + 15. Needs the autoware_core container up with live/*.sh copied to /tmp.
NAME=$1; DUR=$2; shift 2
SHIM=$(cd "$(dirname "$0")" && pwd); LIVE=$SHIM/../../fi1-data-age/live
REPO_AW=$SHIM/../../..
T_ENGAGE=${T_ENGAGE:-150}
SLOG=$SHIM/logs/fi3_${NAME}_shim.log; mkdir -p $SHIM/logs; rm -f $SLOG

pkill -INT -f '^\./AWSIM-Demo-Lightweight\.x86_64'; sleep 5
T0=$(date +%s)
env "$@" FI3_LOG=$SLOG LD_PRELOAD=$SHIM/build/libfi3_delay.so \
  setsid nohup bash $REPO_AW/scripts/launch-awsim.sh >/dev/null 2>&1 </dev/null &
sleep 20
(cd $LIVE && bash reset_aw.sh 60) 2>&1 | tail -2
W=$((T0 + T_ENGAGE - 5 - $(date +%s))); [ $W -gt 0 ] && sleep $W
bash $LIVE/run_case.sh $NAME $DUR --baseline > $SHIM/logs/fi3_${NAME}_case.out 2>&1 & RC=$!
sleep 5
echo "engage at launch+$(( $(date +%s) - T0 ))s"
docker exec -u aw autoware_core bash /tmp/engage.sh | tail -1
wait $RC
grep -vE '^  per-guid' $SHIM/logs/fi3_${NAME}_case.out
grep '^#' $SLOG | head -1
awk '$NF=="sent"{n++; s+=$5; if($5>mx)mx=$5} $NF~/drop/{d++} END{printf "shim: sent=%d dropped=%d mean_delay=%.1fms max=%.1fms\n", n, d, n?s/n:0, mx}' $SLOG
