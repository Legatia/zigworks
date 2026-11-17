# headsound

Audio checks and repairs as one line of text per answer, for AI agents and
for anyone editing audio. headsound measures a recording (loudness, loudness
range, true peak, clipping, background level), finds what an editor would fix
and where (clicks, clipping, dropouts, mains hum, "p" pops, harsh s, DC
offset, phase), says what is heard when (speech, music, laughter... on the
Mac), finds the speech, transcribes it on the Mac, describes the voice, repairs clicks and hum, edits
files, and marks everything it finds for the editor you use: cue points that GoldWave,
Audition, Sound Forge, WaveLab and Reaper show, an Audacity label track, an
Audition marker list, DaVinci Resolve timeline markers, or subtitles.

On the Mac it also listens to the microphone until you stop talking and
hands back what you said as a file, and as text if you ask.

macOS 14 or later (Apple Silicon), Linux (x86_64, arm64) and Windows
(x86_64). Reads WAV everywhere, and on macOS everything Core Audio reads
(m4a/AAC, MP3, ALAC, FLAC, AIFF, CAF). Writes WAV. The microphone, the
sound classifier and speech to text are macOS only so far. Zig standard library, libc and, on
the Mac, AudioToolbox, AVFoundation, SoundAnalysis and Speech; one binary. Nothing is
sent anywhere.

## Using it from an agent

Put headsound on PATH and add one line to the agent's instructions (for Claude Code, `CLAUDE.md`):

```
For audio files and the microphone use the headsound CLI: `headsound info|scan|sounds|speech|voice|transcribe FILE...` to measure or transcribe, `headsound declick|dehum|cut|trim|normalize|convert FILE -o OUT.wav` to repair and edit, `headsound listen [--text]` to record one spoken answer; `headsound help` has the details.
```

## Quick start

Real output, on an 8.7 s spoken recording with two clicks, a pop and 50 Hz
hum added:

```
$ headsound scan interview.wav
hum start=0.000s end=8.659s freq=50.0Hz harmonics=2 level=-45.9dBFS
click start=2.200s end=2.200s level=-13.8dBFS
pop start=4.000s end=4.050s level=-15.6dBFS over=30.0dB
click start=5.500s end=5.500s level=-9.7dBFS
scan duration=8.66s clipping=0 clicks=2 dropouts=0 hum=1 hum_freq=50.0Hz pops=1 ess=0 dc=0 phase=0 loudness=-17.1LUFS lra=1.6LU true_peak=-1.7dBTP

$ headsound scan interview.wav --markers interview-marked.wav --cue interview.cue
...
markers count=4 wav=interview-marked.wav cue=interview.cue

$ headsound declick interview.wav -o step1.wav
declick file=step1.wav found=2 repaired=2 skipped=0 longest=0.1ms

$ headsound dehum step1.wav -o clean.wav
dehum file=clean.wav freq=50.0Hz harmonics=2 before=-45.9dBFS after=none

$ headsound info clean.wav
info duration=8.66s rate=44100 channels=1 format=wav/16 loudness=-17.1LUFS lra=1.6LU peak=-1.7dBFS true_peak=-1.7dBTP clipped=0 background=-49dBFS speech=8.33s

$ headsound sounds mix.wav --min-confidence 0.8     (speech, then piano chords; macOS)
sound label=speech start=0.00s end=4.00s confidence=0.97
sound label=music start=3.50s end=10.00s confidence=0.90
sound label=piano start=3.50s end=9.50s confidence=0.89
...

$ headsound listen --input talk.wav -o first.wav     (the microphone works the same way)
heard after=0.99s duration=3.55s file=first.wav
```

Every command takes `--json` for one JSON object per line instead. `info`,
`scan`, `sounds`, `speech`, `voice` and `transcribe` take several files
(`headsound scan *.wav`): each file's lines follow a `file path=...` line,
and a last line counts them (`files count=12 ok=11 nothing_found=0
failed=1`). A file that can't be read is reported and the rest still run.

## In GoldWave and other editors

`scan`, `sounds`, `speech` and `transcribe` mark what they find, in as many
of these as you ask for at once:

- `--markers OUT.wav` writes a copy of the file with a cue point at each
  finding ("click 1", "hum 50 Hz", "pop (plosive) 1"...), ranges with their
  length. A WAV input is copied byte for byte and only gains the new cue
  points (the cue points, labels and notes already in it are kept as they
  were); any other input is written as WAV first. Open the copy and the cue points are there: GoldWave's Cue Points
  tool, Audition's Markers, Sound Forge and WaveLab's markers, and Reaper
  when it imports markers with the media.
- `--cue OUT.cue` writes a cue sheet for GoldWave's Cue Points > Import (a
  cue sheet holds 99 points, to 1/75 s).
- `--labels OUT.txt` writes an Audacity label track (File > Import > Labels).
- `--audition OUT.csv` writes an Audition marker list (Markers panel >
  Import Markers). It marks an MP3 or FLAC in place, without a WAV copy.
- `--edl OUT.edl --fps N` writes DaVinci Resolve timeline markers (Timelines >
  Import > Timeline Markers from EDL), for audio on a video timeline. `N` is
  the timeline's frame rate (23.976, 24, 25, 29.97, 30, 48, 50, 59.94 or 60;
  non-drop frame). The markers count from the timeline's start, Resolve's
  01:00:00:00 unless `--edl-start HH:MM:SS:FF` says otherwise, so place the
  audio at the start of the timeline. An EDL holds 999 markers; past that the
  `markers` line says how many it kept (`edl_kept=`).
- `--midi OUT.mid` writes a MIDI file with a marker at each finding, at 120
  bpm, the default tempo of Pro Tools, Logic and Cubase, so the times hold
  without the tempo map. Pro Tools: File > Import > MIDI, into a session
  without markers (it imports them only then). Logic: File > Import > MIDI
  File. Cubase and Nuendo: turn on Import Markers in the MIDI File
  preferences. MIDI markers are points, so ranges keep their start only.
- `--subtitles OUT.srt` or `OUT.vtt` writes each finding as a caption, which
  Premiere, Resolve, Final Cut and YouTube import. Points show for a second.

`headsound speech FILE --markers OUT.wav` marks each stretch of speech
"speech N" and each pause "pause [-Exclude-]". GoldWave's Split File then
writes the speech as separate files and leaves the pauses out. The other
formats mark each stretch as a range.

## Commands

| Command | What it does |
|---|---|
| `info FILE` | Duration, rate, channels, format, integrated loudness (LUFS, ITU-R BS.1770-4), loudness range (LU, EBU Tech 3342), sample peak, true peak (dBTP, 4x oversampled), clipped stretches, background level, seconds of speech |
| `scan FILE` | One line per problem in time order, then a summary: clipping, clicks, dropouts, hum, pops, harsh s, DC offset, phase. `--sounds` adds what is heard (macOS) |
| `sounds FILE` | What is heard when, from Apple's on-device classifier (about 300 kinds); stretches may overlap. `--min-confidence N` (default 0.5); `sounds --list` prints every kind |
| `speech FILE` | Start and end of each stretch of speech, then a total. `--min-pause MS` (default 300) sets the shortest pause that splits two stretches |
| `transcribe FILE` | What is said, one line per phrase with its start and end, then a total; `--words` adds each word with its confidence, `--lang en-GB` picks the language (default: yours). With `--subtitles` it writes captions. macOS |
| `voice FILE` | Median pitch and its 10th–90th percentile range, seconds spoken, pauses, longest pause, syllables per second |
| `declick FILE -o OUT` | Rebuilds each click `scan` reports from the sound on both sides; every other sample is left as it was (bit for bit in 16- and 24-bit WAV) |
| `dehum FILE -o OUT` | Removes the hum `scan` reports with notch filters (1 Hz wide), forwards and backwards; `--freq 50\|60` removes it even when none was found |
| `cut FILE -o OUT` | Shortens pauses longer than `--pause MS` (default 500) to that length, and silence at the ends to half of it; 5 ms fades at the joins |
| `trim FILE -o OUT` | `--from S --to S` keeps a span; without them cuts the silence at both ends, keeping `--pad MS` (default 100) |
| `normalize FILE -o OUT` | Gain to `--lufs N` (default -16) unless the peak would pass `--peak DB` (default -1); then stops there and prints `limited_by_peak`. No compression |
| `convert FILE -o OUT` | `--rate HZ` (windowed-sinc resampler), `--mono`, `--bits 16\|24` |
| `listen` | Waits for speech (`--timeout S`, default 30), records until `--silence MS` (default 800) of quiet or `--max S` (default 30), writes 16 kHz mono WAV to `-o OUT` or a private folder under `$TMPDIR/headsound`. `--text` adds what was said. `--input FILE` listens to a recording instead |

Exit codes: 0 ok, 1 nothing found (no speech, clicks or hum; nothing is
written) or timeout, 2 usage error, 3 permission missing, 4 failed
(unreadable file, no microphone).

## How it works

- **Clicks** are bursts that a short-term linear predictor (order 16, fitted
  to each 2048 samples) can't explain: 6 robust standard deviations over the
  local error level, at most 4 ms long. Not counted: a burst that starts
  something much louder (a drum hit, a "t" after a pause), one in noise (a
  cymbal, hiss), and one with others of the same size every few milliseconds
  around it (the pulses that drive a voice). **declick** replaces each one
  by least-squares autoregressive interpolation (order 32) from up to 1024
  samples on each side.
- **Clipping** is 3 or more equal samples in a row near the file's peak (so
  also clipping that was turned down afterwards), arriving steeply (a slow
  wave's crest repeats a 16-bit value too), and samples over full scale,
  which is how clipping shows in decoded lossy files.
- **Dropouts** are 2 ms or more of one value near zero in every channel with
  sound on both sides; silence in a pause is not one.
- **Hum** is steady peaks at 50 or 60 Hz (±0.6 Hz) and their harmonics, at
  least 10 dB over their neighbourhood in 2-second spectra at 4 kHz, with the
  fundamental, 2nd or 3rd harmonic among them. **dehum** puts a notch on each
  harmonic found and runs the filters forwards and backwards (no time shift),
  starting from a mirrored second so the ends don't ring.
- **Pops** are 10 to 150 ms where the band below 80 Hz jumps 15 dB over its
  usual level in the speech and makes up most of the sound.
- **Harsh s** is 30 to 400 ms where the band above 5 kHz is 3 dB or more over
  the voice's usual level within 1.5 s (needs 22.05 kHz or more).
- **DC offset** is measured in the quietest quarter of the file, where a real
  offset still shows and a lopsided voice doesn't; **phase** is stereo
  correlation below -0.5 over 400 ms steps with sound on both sides.
- **Speech** is found at 16 kHz mono: a 100–3800 Hz band-pass, the level of
  20 ms frames every 10 ms against the background level (the 10th percentile),
  with hysteresis (on 12 dB above the background, off 6 dB above, 150 ms of
  hang). A loud stretch only counts if at least 15% of it is voiced, so noise,
  hiss and clicks don't. Music with a clear pitch can count as speech.
- **Pitch** is YIN (de Cheveigné & Kawahara) between 60 and 500 Hz, with a
  check against the common octave-down mistake.
- **Pace** counts loudness peaks in voiced frames. It is an estimate: within
  about 10% at ordinary speaking rates (4 to 5 syllables a second), too high
  for slow speech and too low for very fast speech.
- **Loudness** follows BS.1770-4: K-weighting derived for any sample rate (it
  reproduces the standard's 48 kHz coefficients), 400 ms blocks with 75%
  overlap, gates at -70 LUFS and 10 LU below. Loudness range follows EBU Tech
  3342 (3 s windows, gates at -70 LUFS and 20 LU below, 10th to 95th
  percentile). The tests include EBU Tech 3341 cases 1 and 3 and Tech 3342
  cases 1 to 4.
- **Sounds** come from Apple's built-in classifier (SoundAnalysis) over 1 s
  windows overlapping by half; a class's windows above the confidence join
  into stretches.
- **Speech to text** is Apple's speech recogniser (Speech framework) with
  on-device recognition required, so the audio never leaves the Mac; a
  language without an on-device model is refused rather than sent to a
  server. The speech detector cuts the recording into pieces of at most 30 s
  in its pauses, and the words are grouped into lines at pauses of 0.7 s,
  sentence ends, 84 characters or 7 seconds.
- **listen** uses the speech detector on the live signal: speech has started
  after five voiced frames above the threshold, and ended after `--silence` of
  quiet. The file starts 300 ms before the speech and ends 150 ms after it.

## Permissions

`listen` records through an AudioQueue at 16 kHz. macOS grants the microphone
to the app headsound runs in (Terminal, iTerm, your editor), and asks the
first time. If it was turned off, headsound says where to turn it on and exits
with code 3; it never records silence and calls that a result. Speech to
text (`transcribe`, `listen --text`) needs Speech Recognition permission for
the same app, asked for the same way, and checked before `listen` starts. Recordings in
the private folder (mode 0700) are deleted after a day.

## Limits

- In AAC, MP3 and Opus files only clicks above -40 dBFS count (the codec's own
  artifacts in quiet parts look like small clicks), and the codec smears small
  clicks so some are missed. Check the original WAV when you have it.
- Hum harmonics that sit under a voice's own steady harmonics aren't found,
  so aren't removed. A perfectly steady tone at a multiple of 60 Hz (a test
  tone, a synth) counts with the hum.
- `declick` doesn't repair crackle longer than about 4 ms, clicks inside a
  pop, a harsh s, clipping or a dropout, or clicks in the first or last 12 ms
  of a file.
- Speech to text has the on-device model's accuracy, which is below the best
  server recognisers, and leaves out filler words like "um", so `cut` removes
  pauses, not fillers. Off the Mac, use your own recogniser (`convert --rate
  16000 --mono` is the format most want).
- The Audition, Resolve, MIDI and subtitle files follow files those programs
  export (Resolve's from several published samples); they have not been
  opened in Audition, Resolve, Pro Tools, Logic or Premiere yet (the MIDI
  file was read back with Apple's MusicSequence). Resolve may drop accented
  letters in marker names.
- On Linux and Windows only WAV is read, and there is no microphone, sound
  classifier or speech to text (record with `arecord`, Sound Recorder or your editor, then use
  the file commands).

## Building

Zig 0.15.1:

```sh
zig build -Doptimize=ReleaseFast                            # zig-out/bin/headsound
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu # headsound.exe
zig build test                                               # unit tests, then the CLI on generated audio
```

The smoke tests (`scripts/smoke.sh`) generate their WAV files with python3.

## License

MIT
