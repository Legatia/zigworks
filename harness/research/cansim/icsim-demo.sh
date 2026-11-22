#!/bin/bash
# ICSim's dashboard and its controls on vcan0, on your display (WSLg on Windows 11).
# In the controls window: Up accelerates, Left and Right are the indicators,
# Left Shift locks, Right Shift unlocks, A, B, X and Y are the doors.
# Watch the frames with: candump vcan0
set -eu
C=/opt/cansim
modprobe vcan
ip link show vcan0 >/dev/null 2>&1 || ip link add dev vcan0 type vcan
ip link set up vcan0
cd $C/icsim
$C/bin/icsim vcan0 &
trap 'kill $! 2>/dev/null' EXIT
$C/bin/controls vcan0
