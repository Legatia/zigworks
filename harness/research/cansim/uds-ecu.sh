#!/bin/bash
# A made-up battery ECU on vcan0: answers UDS requests sent to 0x7E4 on 0x7EC,
# only in frames padded to 8 bytes. Its identifiers are in /opt/cansim/uds/config.json.
# Try it, in two shells:
#   isotprecv -p AA -s 7E4 -d 7EC vcan0
#   echo "22 01 01" | isotpsend -p AA -s 7E4 -d 7EC vcan0
set -eu
C=/opt/cansim
modprobe vcan
ip link show vcan0 >/dev/null 2>&1 || ip link add dev vcan0 type vcan
ip link set up vcan0
cd $C/uds
# -e names the ECU: without it, this build reads an uninitialised name
exec $C/bin/uds-server-simulator -e BMS vcan0
