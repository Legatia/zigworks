#!/bin/sh
# The CLI on generated audio (python3 writes the WAV files); no microphone.
# usage: scripts/smoke.sh [path/to/headsound]
set -u

HS=${1:-zig-out/bin/headsound}
case $HS in /* | [A-Za-z]:*) ;; *) HS=$(pwd)/$HS ;; esac

D=$(mktemp -d /tmp/headsound-smoke.XXXXXX)
export TMPDIR=$D
trap 'rm -rf "$D"' EXIT
cd "$D" || exit 1

# Windows (Git Bash on CI): native paths for the binary, python is "python".
WIN=no
case $(uname -s) in MINGW* | MSYS* | CYGWIN*)
    WIN=yes
    TEMP=$(cygpath -w "$D")
    TMP=$TEMP
    export TEMP TMP
    ;;
esac
# (on Windows "python3" may be the Store's placeholder, which runs nothing)
PY=
for p in python3 python; do
    if command -v $p > /dev/null 2>&1 && $p -c "import wave" > /dev/null 2>&1; then PY=$p; break; fi
done
[ -n "$PY" ] || { echo "FAIL: no python" >&2; exit 1; }
MAC=no
[ "$(uname -s)" = Darwin ] && MAC=yes

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# expect <exit code> <text that must appear in stdout+stderr> -- <args...>
expect() {
    want=$1
    text=$2
    shift 3
    out=$("$HS" "$@" 2>&1)
    got=$?
    [ "$got" = "$want" ] || fail "headsound $*: exit $got, want $want; output: $out"
    case $out in *"$text"*) ;; *) fail "headsound $*: output lacks '$text': $out" ;; esac
    echo "ok - headsound $*"
}

# A voice-like test signal: a 140 Hz buzz with a 4 Hz syllable rhythm, then
# quiet, then more; a little background noise throughout.
"$PY" - <<'EOF' || fail "python could not write the test files"
import math, random, struct, wave
random.seed(1)
def write(name, parts, rate=22050):
    out = bytearray()
    t = 0
    for secs, kind in parts:
        start = t
        for _ in range(int(secs * rate)):
            ts = t / rate
            v = 0 if kind == "zero" else (random.random() - 0.5) * 0.002
            if kind == "voice":
                acc = sum(math.sin(2 * math.pi * 140 * h * ts) / h for h in range(1, 8))
                # 20 ms fades, as a voice starts and stops
                into = (t - start) / rate
                edge = min(1.0, into / 0.02, (secs - into) / 0.02)
                v += 0.2 * edge * acc * (0.55 + 0.45 * math.sin(2 * math.pi * 4 * ts))
            elif kind == "noise":
                v += (random.random() - 0.5) * 0.6
            out += struct.pack("<h", max(-32768, min(32767, int(v * 32767))))
            t += 1
    w = wave.open(name, "wb")
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    w.writeframes(bytes(out)); w.close()
write("talk.wav", [(1, "q"), (1.5, "voice"), (2, "q"), (1, "voice"), (1, "q")])

def read(name):
    w = wave.open(name)
    n = w.getnframes()
    v = list(struct.unpack("<%dh" % n, w.readframes(n)))
    return [x / 32768 for x in v], w.getframerate()
def save(name, v, rate):
    w = wave.open(name, "wb")
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    w.writeframes(b"".join(struct.pack("<h", max(-32768, min(32767, int(round(x * 32768))))) for x in v)); w.close()
talk, rate = read("talk.wav")
# clicks: in the voice, in the quiet, in the voice
c = list(talk)
for t, a in [(1.7, 0.3), (3.0, 0.1), (5.0, -0.25)]:
    c[int(t * rate)] += a
save("clicks.wav", c, rate)
# 60 Hz hum (and 120, 180) at -40 dBFS all through
h = [x + 0.01 * (math.sin(2 * math.pi * 60 * i / rate) + 0.5 * math.sin(2 * math.pi * 120 * i / rate)
                 + 0.3 * math.sin(2 * math.pi * 180 * i / rate)) for i, x in enumerate(talk)]
save("hum.wav", h, rate)
write("noise.wav", [(1, "q"), (1, "noise"), (1, "q")])
write("quiet.wav", [(3, "q")], rate=16000)
write("silent.wav", [(3, "zero")], rate=16000)
EOF

expect 0 "speech" -- help
for c in info scan sounds speech voice transcribe cut trim normalize convert declick dehum listen; do
    expect 0 "usage: headsound $c" -- help "$c"
done
expect 0 "headsound 0.1.0" -- version
expect 2 "unknown command" -- frobnicate
expect 2 "which file?" -- info
expect 2 "-o OUT.wav" -- cut talk.wav
expect 2 "ending in .wav" -- cut talk.wav -o out.mp3
expect 2 "doesn't take --rate" -- info talk.wav --rate 8000
expect 4 "no such file" -- info missing.wav
echo "not audio" > fake.wav
expect 4 "" -- info fake.wav

expect 0 "info duration=6.50s rate=22050 channels=1 format=wav/16" -- info talk.wav
expect 0 "true_peak=" -- info talk.wav
expect 0 '"event":"info","duration":6.50' -- info talk.wav --json
expect 0 "total stretches=2" -- speech talk.wav
expect 0 "speech start=0.94s end=2.57s" -- speech talk.wav
expect 1 "total stretches=0" -- speech noise.wav
expect 0 "voice pitch=140Hz" -- voice talk.wav
expect 0 "files count=2 ok=1 nothing_found=1 failed=0" -- speech talk.wav noise.wav
expect 4 "missing.wav: no such file" -- info talk.wav missing.wav
expect 2 "one file at a time" -- scan talk.wav noise.wav --labels l.txt

expect 0 "cut file=cut.wav before=6.50s after=3.76s removed=2.74s pauses_shortened=1" -- cut talk.wav -o cut.wav
expect 0 "longest_pause=0.5" -- speech cut.wav
expect 0 "trim file=trim.wav from=0.89s to=5.62s" -- trim talk.wav -o trim.wav
expect 0 "duration=2.00s" -- trim talk.wav --from 1 --to 3 -o clip.wav
expect 0 "normalize file=n.wav" -- normalize talk.wav --lufs -20 -o n.wav
expect 0 "loudness=-20.0LUFS" -- info n.wav
expect 0 "convert file=c.wav rate=16000 channels=1 bits=24" -- convert talk.wav --rate 16000 --bits 24 -o c.wav
expect 0 "rate=16000 channels=1 format=wav/24" -- info c.wav
expect 1 "no speech found" -- cut quiet.wav -o x.wav
expect 1 "too quiet" -- normalize silent.wav -o x.wav

# scan, markers and the repairs
expect 0 "scan duration=6.50s clipping=0 clicks=0 dropouts=0 hum=0" -- scan talk.wav
expect 0 "click start=1.700s" -- scan clicks.wav
expect 0 "click start=3.000s" -- scan clicks.wav
expect 0 "click start=5.000s" -- scan clicks.wav
expect 0 "clicks=3 dropouts=0 hum=0" -- scan clicks.wav
expect 0 "markers count=3 wav=m.wav labels=l.txt cue=c.cue" -- scan clicks.wav --markers m.wav --labels l.txt --cue c.cue
grep -q "click 2" l.txt || fail "labels lack 'click 2'"
grep -q 'TITLE "click 3"' c.cue || fail "cue sheet lacks 'click 3'"
expect 0 "markers count=3 audition=a.csv edl=r.edl subtitles=s.srt" -- scan clicks.wav --audition a.csv --edl r.edl --fps 25 --subtitles s.srt
grep -q "$(printf 'click 2\t0:03.000\t0:00.000\tdecimal\tCue')" a.csv || fail "Audition list lacks 'click 2' at 3.000"
grep -q "01:00:03:00 01:00:03:01 01:00:03:00 01:00:03:01" r.edl || fail "EDL lacks the click at 3 s"
grep -q "|M:click 2 |D:1" r.edl || fail "EDL lacks the marker 'click 2'"
grep -q "00:00:05,000 --> 00:00:06,000" s.srt || fail "SRT lacks the click at 5 s"
expect 0 "subtitles=s.vtt" -- speech talk.wav --subtitles s.vtt
expect 0 "midi=m.mid" -- speech talk.wav --midi m.mid
head -c 4 m.mid | grep -q MThd || fail "MIDI file lacks its header"
grep -q "Exclude" m.mid && fail "MIDI markers keep GoldWave's [-Exclude-]"
grep -q "speech 2" m.mid || fail "MIDI file lacks 'speech 2'"
head -1 s.vtt | grep -q WEBVTT || fail "VTT lacks its header"
expect 2 "needs the timeline's frame rate" -- scan talk.wav --edl r.edl
# an output that can't be written: named, and no half-written line
out=$("$HS" scan talk.wav --labels "$D/nowhere/l.txt" 2>"$D/err.txt"); got=$?
[ $got = 4 ] || fail "unwritable --labels: exit $got, want 4"
case $out in *markers*) fail "unwritable --labels still printed: $out" ;; esac
grep -q "nowhere/l.txt" "$D/err.txt" || fail "unwritable --labels: the message doesn't name the file: $(cat "$D/err.txt")"
echo "ok - unwritable marker file is named"
printf 'RIFF\044\000\000\000WAVEfmt \020\000\000\000\001\000\001\000\104\254\000\000\210\130\001\000\002\000\020\000data\000\000\000\000' > empty.wav
order=$("$HS" info empty.wav talk.wav 2>&1 | sed -n 2p)
case $order in *"empty.wav: the file has no audio"*) ;; *) fail "the empty file's message is out of order: $order" ;; esac
echo "ok - messages stay with their file"
expect 2 "ending in .srt or .vtt" -- scan talk.wav --subtitles s.txt
expect 0 "duration=6.50s" -- info m.wav
expect 0 "clicks=3" -- scan m.wav
expect 0 "declick file=fixed.wav found=3 repaired=3 skipped=0" -- declick clicks.wav -o fixed.wav
expect 0 "clicks=0" -- scan fixed.wav
expect 1 "no clicks found" -- declick talk.wav -o x.wav
expect 0 "hum start=0.000s end=6.500s freq=60.0Hz" -- scan hum.wav
# (the test voice is a perfectly steady 140 Hz: its 420 and 840 Hz land on
# the hum's 7th and 14th harmonics and count with it)
expect 0 "dehum file=nohum.wav freq=60.0Hz harmonics=" -- dehum hum.wav -o nohum.wav
expect 0 "after=none" -- dehum hum.wav -o nohum.wav
expect 0 "hum=0" -- scan nohum.wav
expect 1 "no hum found" -- dehum talk.wav -o x.wav
expect 0 "dehum file=forced.wav freq=50.0Hz harmonics=8 before=none" -- dehum talk.wav --freq 50 -o forced.wav
expect 0 "markers count=5 wav=split.wav" -- speech talk.wav --markers split.wav
expect 2 "ending in .wav" -- scan talk.wav --markers m.txt
expect 2 "new file" -- declick talk.wav -o talk.wav
expect 2 "50 or 60" -- dehum talk.wav --freq 55 -o x.wav
expect 2 "--lang is a language" -- transcribe talk.wav --lang "en US"
if [ $MAC = yes ]; then
    expect 0 "class label=speech" -- sounds --list
    # Speech recognition asks for permission once, so only on request.
    if [ "${HEADSOUND_SPEECH_TESTS:-}" = 1 ]; then
        say -o words.aiff "Thanks for joining us today. [[slnc 1500]] We cleaned the hum before publishing."
        expect 0 "transcript lines=2" -- transcribe words.aiff --lang en-US --subtitles words.srt
        grep -qi "joining" words.srt || fail "captions lack 'joining'"
        expect 0 "text=" -- listen --input words.aiff --text --lang en-US
    fi
else
    expect 4 "needs macOS" -- sounds talk.wav
    expect 0 "needs macOS so far; scanning without it" -- scan talk.wav --sounds
    expect 4 "speech to text needs macOS" -- transcribe talk.wav
    expect 4 "speech to text needs macOS" -- listen --input talk.wav --text
fi

expect 0 "heard after=0.99s duration=2.00s" -- listen --input talk.wav --timeout 5
expect 0 "listen-" -- listen --input talk.wav
if [ $WIN = no ]; then
    [ "$(stat -c %a "$TMPDIR/headsound" 2>/dev/null || stat -f %Lp "$TMPDIR/headsound")" = 700 ] || fail "recordings folder is not private"
fi
ls "$D/headsound" | grep -q "^listen-" || fail "the recording is not in the recordings folder"
expect 0 "duration=5.00s file=both.wav" -- listen --input talk.wav --silence 3000 -o both.wav
expect 1 "timeout after=3.0s" -- listen --input quiet.wav
echo "smoke: all ok"
