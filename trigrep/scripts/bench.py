import subprocess, sys, time, os, statistics
# bench.py DIR PATTERN...: median wall time of 5 runs for rg, trigrep, trigrep --trust-index
d = sys.argv[1]; TG = os.environ.get("TRIGREP") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "zig-out", "bin", "trigrep")
def t(cmd):
    xs = []
    for _ in range(5):
        s = time.perf_counter(); subprocess.run(cmd, cwd=d, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); xs.append(time.perf_counter() - s)
    return statistics.median(xs) * 1000
print(f"{'pattern':28} {'rg ms':>8} {'trigrep':>8} {'trusted':>8}")
for p in sys.argv[2:]:
    a = t(["rg", "-n", "-e", p, "."]); b = t([TG, "-e", p, "."]); c = t([TG, "--trust-index", "-e", p, "."])
    print(f"{p[:28]:28} {a:8.1f} {b:8.1f} {c:8.1f}   x{a/b:.1f} / x{a/c:.0f}")
