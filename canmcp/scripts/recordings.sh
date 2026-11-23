#!/bin/sh
# canmcp's readings on two real cars' recordings, checked against each other:
# a minute each of a Tesla Model 3 and a Hyundai Ioniq 5, from comma.ai's
# commaCarSegments, as ../harness/research/cansim/setup.sh puts them into
# /opt/cansim (or $CANSIM). Skipped without them. Needs python3.
# Usage: recordings.sh CANMCP
set -u
B=$1
cd "$(dirname "$0")/.." || exit 1
C=${CANSIM:-/opt/cansim}
for f in data/model3.log data/ioniq5.log dbc/tesla_model3_party.dbc dbc/hyundai_canfd.dbc; do
	if [ ! -s "$C/$f" ]; then
		echo "# $C/$f missing (harness/research/cansim/setup.sh): skipped"
		exit 0
	fi
done
if ! command -v python3 >/dev/null; then
	echo "# python3 missing: skipped"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# two speeds from two different ECUs: the drive inverter and the ABS
cat >"$T/tesla.ini" <<EOF
[bus party]
interface = vcan0
log = can0
dbc = $C/dbc/tesla_model3_party.dbc
[reading inverter]
signal = party DI_speed.DI_vehicleSpeed
[reading abs]
signal = party ESP_B.ESP_vehicleSpeed
EOF
sed -e "s|/opt/cansim|$C|" profiles/ioniq5.ini >"$T/ioniq5.ini"
"$B" decode "$T/tesla.ini" "$C/data/model3.log" 1 >"$T/tesla.out" || exit 1
"$B" decode "$T/ioniq5.ini" "$C/data/ioniq5.log" 1 >"$T/ioniq5.out" || exit 1

python3 -I - "$T/tesla.out" "$T/ioniq5.out" <<'EOF'
import re, sys

failed = False
n = 0

def check(name, ok, detail=""):
    global n, failed
    n += 1
    print(("ok" if ok else "not ok") + f" {n} - {name}" + (f" ({detail})" if detail else ""))
    failed = failed or not ok

def rows(path):
    out = []
    for line in open(path):
        m = re.match(r"t=([0-9.]+) (.*)", line)
        if m:
            d = dict(re.findall(r"(\w+)=([^,]+)", m.group(2)))
            d["t"] = float(m.group(1))
            out.append(d)
    return out

def num(v):
    m = re.match(r"-?[0-9.]+", v or "")
    return float(m.group()) if m else None

# Tesla: the inverter's speed is signed (negative in reverse), the ABS's is not
tesla = rows(sys.argv[1])
pairs = [(num(r.get("inverter")), num(r.get("abs"))) for r in tesla]
pairs = [(i, a) for i, a in pairs if i is not None and a is not None]
gap = max((abs(abs(i) - a) for i, a in pairs), default=99)
top = max((a for _, a in pairs), default=0)
check("Tesla: both speeds seen every second", len(pairs) >= 55, f"{len(pairs)} seconds")
check("Tesla: the car drove (above 40 km/h)", top > 40, f"top {top} km/h")
# Two ECUs, each with its own timing and rounding (the ABS's goes in steps
# of 0.5 km/h): a gap of about 2% is normal, a decoding mistake is not
check("Tesla: inverter and ABS agree within 1.5 km/h", gap <= 1.5, f"largest gap {gap:.2f} km/h")

# Ioniq 5: what the driver did, in order
ioniq = rows(sys.argv[2])
def first(pred, after=-1.0):
    return next((r["t"] for r in ioniq if r["t"] > after and pred(r)), None)
opened = first(lambda r: r.get("driver_door") == "Opened")
closed = first(lambda r: r.get("driver_door") == "Closed", opened if opened is not None else 1e9)
belt = first(lambda r: r.get("driver_seatbelt") == "Latched", closed if closed is not None else 1e9)
reverse = first(lambda r: r.get("gear") == "R", belt if belt is not None else 1e9)
check("Ioniq 5: driver's door opened, closed; seatbelt latched; reverse, in that order",
      None not in (opened, closed, belt, reverse), f"at {opened}, {closed}, {belt}, {reverse} s")
spread = 0.0
moving = 0
for r in ioniq:
    w = [num(r.get(k)) for k in ("wheel_speed_fl", "wheel_speed_fr", "wheel_speed_rl", "wheel_speed_rr")]
    if None not in w and min(w) > 1:
        moving += 1
        spread = max(spread, max(w) - min(w))
check("Ioniq 5: the four wheel speeds stay within 1.5 km/h of each other while moving",
      moving >= 10 and spread <= 1.5, f"{moving} seconds moving, largest spread {spread:.2f} km/h")
sys.exit(1 if failed else 0)
EOF
