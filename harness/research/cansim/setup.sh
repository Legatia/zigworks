#!/bin/bash
# Puts CAN simulators for a desk without a car into /opt/cansim. Run as root,
# in a Linux with Zig 0.17.1 on PATH and Python 3.12 (tested: Ubuntu 24.04
# under WSL 2, x86_64):
#   can-utils                     candump, cansend, canplayer, cangen, isotpsend, isotprecv
#   data/ioniq5.log, model3.log   one minute of real CAN traffic each, from comma.ai's
#                                 commaCarSegments (MIT), as candump logs
#   bin/icsim, bin/controls       ICSim: a dashboard and its controls on CAN (GPL-3.0)
#   bin/uds-server-simulator      a diagnostic ECU (GPL-2.0), set up as a made-up battery
#   dbc/                          opendbc's DBC files (MIT) for the profiles in canmcp/profiles
# Downloads about 15 MB. Running it again fetches only what is missing.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
C=/opt/cansim
M=$(uname -m)
mkdir -p $C/bin $C/debs $C/sdl $C/pylib $C/schema/include $C/dl $C/data $C/src $C/icsim $C/uds $C/dbc
export DEBIAN_FRONTEND=noninteractive

echo "== packages: can-utils, zstandard, the SDL2 runtime"
apt-get install -y -qq --no-install-recommends can-utils python3-zstandard libsdl2-2.0-0 libsdl2-image-2.0-0 >/dev/null

echo "== SDL2 headers (the -dev packages unpacked, not installed: that would pull in 49 MB)"
if [ ! -f $C/sdl/usr/include/SDL2/SDL.h ]; then
  (cd $C/debs && apt-get download -qq libsdl2-dev libsdl2-image-dev 2>/dev/null)
  for d in $C/debs/*.deb; do dpkg -x "$d" $C/sdl; done
fi

echo "== pycapnp, to read openpilot's logs (checked against the sha256 PyPI publishes)"
whl=pycapnp-2.2.4-cp312-cp312-manylinux_2_28_$M.whl
if [ ! -d $C/pylib/capnp ]; then
  read -r url sha < <(curl -fsSL https://pypi.org/pypi/pycapnp/2.2.4/json | python3 -I -c '
import json, sys
for f in json.load(sys.stdin)["urls"]:
    if f["filename"] == "'$whl'":
        print(f["url"], f["digests"]["sha256"])
')
  curl -fsSL -o $C/dl/$whl "$url"
  echo "$sha  $C/dl/$whl" | sha256sum -c --quiet -
  python3 -I -m zipfile -e $C/dl/$whl $C/pylib
fi

echo "== opendbc's small schema for the CAN messages in those logs"
R=https://raw.githubusercontent.com/commaai/opendbc/34b55aec160a8fa0c5733a9b5279be40b5e1d775/opendbc/car
for f in rlog.capnp car.capnp include/c++.capnp; do
  [ -s $C/schema/$f ] || curl -fsSL -o $C/schema/$f $R/$f
done

echo "== opendbc's DBC files: what the bytes on those buses mean (for canmcp)"
D=https://raw.githubusercontent.com/commaai/opendbc/34b55aec160a8fa0c5733a9b5279be40b5e1d775/opendbc/dbc
dbc() { # path in opendbc/dbc, sha256
  f=$(basename "$1")
  [ -s $C/dbc/$f ] || curl -fsSL -o $C/dbc/$f "$D/$1"
  echo "$2  $C/dbc/$f" | sha256sum -c --quiet -
}
dbc tesla_model3_party.dbc efc12ca7d0d9a9b2ee4df039a9f3e2ee22e7e036ec6202af0fce19c486495749
dbc generator/hyundai/hyundai_canfd.dbc 1f1bd5d9a65ba2b92818bbebcf51ff22adc6ca4a59dd7ef780c217dc94223faa
dbc generator/hyundai/_hyundai_canfd_common.dbc f2366b5485208e17ce878f9a4b68e5a3100f45da156bb1fbed20897ae8b87200

echo "== one minute each of a Hyundai Ioniq 5 and a Tesla Model 3"
install -m 755 $here/rlog2candump.py $C/bin/rlog2candump.py
H=https://huggingface.co/datasets/commaai/commaCarSegments/resolve/main/segments
get() { # name segment sha256
  mkdir -p $C/data/$1
  [ -s $C/data/$1/rlog.zst ] || curl -fsSL -o $C/data/$1/rlog.zst "$H/$2/rlog.zst"
  echo "$3  $C/data/$1/rlog.zst" | sha256sum -c --quiet -
  echo "$2" >$C/data/$1/segment
  [ -s $C/data/$1.log ] || python3 -I $C/bin/rlog2candump.py $C/schema $C/pylib $C/data/$1/rlog.zst $C/data/$1.log
}
get ioniq5 2a61a6186e261ee1/00000001--d89309f69d/23 aaa694287d597efdf73cccd1580aaab5599eee9a0489839ae6331838229b1319
get model3 3b747326f67476fc/00000003--be5f7dfd59/10 93e762365ccadae45de75bf920194a1574f6413c2743f65ffa359f917362503b

echo "== ICSim and uds-server-simulator, built with zig cc (no gcc needed)"
fetch() { # url dir commit
  [ -d $C/src/$2 ] || git clone -q "$1" $C/src/$2
  git -C $C/src/$2 checkout -q "$3"
}
fetch https://github.com/zombieCraig/ICSim ICSim 2b3333ef866987d8adc9c15ff15b9b9189edf85b
fetch https://github.com/Honinb0n/uds-server-simulator uds-server-simulator 430602c7854d464036592445127bd03a037f85d0
I="-I$C/sdl/usr/include -I$C/sdl/usr/include/SDL2 -I$C/sdl/usr/include/$M-linux-gnu"
SDL="/usr/lib/$M-linux-gnu/libSDL2-2.0.so.0 /usr/lib/$M-linux-gnu/libSDL2_image-2.0.so.0"
S=$C/src/ICSim
zig cc -O2 -w $I -o $C/bin/icsim $S/icsim.c $S/lib.c $SDL
zig cc -O2 -w $I -o $C/bin/controls $S/controls.c $SDL
cp -r $S/data $C/icsim/
# -O0: its C has undefined behaviour that clang's optimiser turns into wrong
# answers. The int-conversion error (it returns NULL from a char function) is
# a warning, as it is with gcc.
U=$C/src/uds-server-simulator
zig cc -O0 -w -Wno-error=int-conversion -o $C/bin/uds-server-simulator $U/uds-server-simulator.c $U/third/cJSON.c
cp $here/uds-ecu.json $C/uds/config.json
install -m 755 $here/replay.sh $C/bin/replay
install -m 755 $here/icsim-demo.sh $C/bin/icsim-demo
install -m 755 $here/uds-ecu.sh $C/bin/uds-ecu
echo "done; README.md says what to run"
