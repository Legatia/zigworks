"""openpilot rlog (as in commaCarSegments) to a candump log that canplayer replays.

usage: rlog2candump.py SCHEMA_DIR PYLIB_DIR RLOG_ZST OUT_LOG

SCHEMA_DIR holds opendbc's rlog.capnp, car.capnp and include/c++.capnp;
PYLIB_DIR holds pycapnp. Bus N in the log becomes interface canN. Frames
openpilot sent itself (src 128 and up) are left out. Prints a summary.
"""
import sys

schema, pylib, src, dst = sys.argv[1:5]
sys.path.insert(0, pylib)
import capnp  # noqa: E402
import zstandard  # noqa: E402

capnp.remove_import_hook()
log = capnp.load(f"{schema}/rlog.capnp", imports=[schema])
with open(src, "rb") as f:
    raw = zstandard.ZstdDecompressor().stream_reader(f, read_across_frames=True).read()

frames = fd = skipped = 0
first = last = None
per_bus = {}
with open(dst, "w") as out:
    for ev in log.Event.read_multiple_bytes(raw):
        try:
            if ev.which() != "can":
                continue
        except Exception:  # a union member the small schema does not name
            skipped += 1
            continue
        t = ev.logMonoTime / 1e9
        for m in ev.can:
            if m.src >= 128:
                continue
            d = bytes(m.dat)
            ident = f"{m.address:08X}" if m.address > 0x7FF else f"{m.address:03X}"
            sep = "##0" if len(d) > 8 else "#"
            out.write(f"({t:.6f}) can{m.src} {ident}{sep}{d.hex().upper()}\n")
            frames += 1
            fd += len(d) > 8
            ids = per_bus.setdefault(m.src, {})
            ids[m.address] = ids.get(m.address, 0) + 1
            first = t if first is None else first
            last = t

span = (last - first) if frames else 0
print(f"{src.rsplit('/', 1)[-1]}: {frames} frames over {span:.1f} s ({frames / span if span else 0:.0f}/s), "
      f"{fd} CAN FD frames, {skipped} events not in the small schema")
for bus in sorted(per_bus):
    ids = per_bus[bus]
    print(f"  bus {bus}: {sum(ids.values())} frames, {len(ids)} ids")
