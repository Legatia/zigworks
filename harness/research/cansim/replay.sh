#!/bin/bash
# Replays a recorded log onto the virtual CAN buses vcan0, vcan1 and vcan2
# (bus N of the log goes to vcanN), in real time.
# usage, as root: replay.sh LOG [TIMES]   TIMES: how often, i = forever (default)
set -eu
log=$1
times=${2:-i}
modprobe vcan
for i in 0 1 2; do
  ip link show vcan$i >/dev/null 2>&1 || ip link add dev vcan$i type vcan
  ip link set up vcan$i
done
exec canplayer -I "$log" -l "$times" vcan0=can0 vcan1=can1 vcan2=can2
