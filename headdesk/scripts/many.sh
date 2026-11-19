#!/bin/sh
# How many desktops fit on this machine: starts N of them, each with the
# test client (or the program given), and measures what they cost.
#
# usage: many.sh N [headdesk] [headdesk-testclient] [-- program args...]
#
# Prints: the time to start them all, the memory of a desktop's process and
# of its app (resident, from /proc), the CPU all of them use while nothing
# happens, and the time for a picture of, and a click on, every one.
# HEADDESK_MANY_SIZE sets the desktops' size (default 1280x800).
set -u
N=${1:-20}
HD=${2:-zig-out/bin/headdesk}
TC=${3:-zig-out/bin/headdesk-testclient}
case $HD in /*) ;; *) HD=$PWD/$HD ;; esac
case $TC in /*) ;; *) TC=$PWD/$TC ;; esac
shift 3 2>/dev/null || shift $#
[ "${1:-}" = "--" ] && shift
SIZE=${HEADDESK_MANY_SIZE:-1280x800}

WORK=$(mktemp -d /tmp/hd-many.XXXXXX)
export HEADDESK_DIR=$WORK/d
cleanup() {
    i=1
    while [ "$i" -le "$N" ]; do
        "$HD" kill "m$i" >/dev/null 2>&1 &
        i=$((i + 1))
    done
    wait
    rm -rf "$WORK"
}
trap cleanup EXIT

now_ms() { date +%s%3N; }

# resident kilobytes of the processes whose pids are given
rss_kb() {
    total=0
    for pid in "$@"; do
        kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null)
        total=$((total + ${kb:-0}))
    done
    echo "$total"
}

# clock ticks of CPU time used so far by the processes whose pids are given
cpu_ticks() {
    total=0
    for pid in "$@"; do
        t=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null)
        total=$((total + ${t:-0}))
    done
    echo "$total"
}

t0=$(now_ms)
desks=""
i=1
while [ "$i" -le "$N" ]; do
    if [ $# -gt 0 ]; then
        started=$("$HD" start "m$i" --size "$SIZE" -- "$@") || exit 1
    else
        started=$("$HD" start "m$i" --size "$SIZE" -- "$TC" "window $i") || exit 1
    fi
    # "started m1 pid=123 size=1280x800": the third word
    set_pid=${started#* pid=}
    desks="$desks ${set_pid%% *}"
    i=$((i + 1))
done
i=1
while [ "$i" -le "$N" ]; do
    "$HD" wait "m$i" --windows 1 --idle 100 --timeout 60000 >/dev/null
    i=$((i + 1))
done
t1=$(now_ms)

apps=""
i=1
while [ "$i" -le "$N" ]; do
    # "app pid=124 running ..."
    line=$("$HD" status "m$i" | grep '^app pid=' | head -1)
    app_pid=${line#app pid=}
    apps="$apps ${app_pid%% *}"
    i=$((i + 1))
done

desk_kb=$(rss_kb $desks)
app_kb=$(rss_kb $apps)
ticks=$(getconf CLK_TCK)
c0=$(cpu_ticks $desks)
sleep 5
c1=$(cpu_ticks $desks)

t2=$(now_ms)
i=1
while [ "$i" -le "$N" ]; do
    "$HD" shot "m$i" "$WORK/shot.png" >/dev/null
    i=$((i + 1))
done
t3=$(now_ms)
i=1
while [ "$i" -le "$N" ]; do
    "$HD" click "m$i" 50 40 >/dev/null
    i=$((i + 1))
done
i=1
while [ "$i" -le "$N" ]; do
    "$HD" wait "m$i" --idle 100 --timeout 10000 >/dev/null
    i=$((i + 1))
done
t4=$(now_ms)

echo "desktops=$N size=$SIZE"
echo "start_all_ms=$((t1 - t0)) per_desktop_ms=$(((t1 - t0) / N))"
echo "desktop_process_kb=$((desk_kb / N)) app_process_kb=$((app_kb / N)) all_mb=$(((desk_kb + app_kb) / 1024))"
echo "idle_cpu=$(awk "BEGIN { printf \"%.2f\", ($c1 - $c0) * 100 / $ticks / 5 }")% of one core, all $N desktops together, over 5 s"
echo "shot_each_ms=$(((t3 - t2) / N)) click_and_settle_all_ms=$((t4 - t3))"
