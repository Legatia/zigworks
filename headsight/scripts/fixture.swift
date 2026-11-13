// A window with timed changes for scripts/live.sh and the evaluation.
// usage: fixture [--done S] [--count] [--side S] [--toast S] [--title T]
//   --done S   "Exporting..." becomes "Export Done: 42 files" after S seconds
//   --count    the counter shows random numbers for 3 s, then settles at 7310
//   --side S   another line, "Plan: Pro", appears after S seconds
//   --toast S  "Saved to Downloads" shows bottom right for 3 s after S seconds
//   --minimize S  the window minimises itself after S seconds
// Quit it by ending the process.
import AppKit

var opts: [String: String] = [:]
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    if a == "--count" { opts["count"] = "1" } else if a.hasPrefix("--") { opts[String(a.dropFirst(2))] = it.next() ?? "" }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let win = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1000, height: 640), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
win.title = opts["title"] ?? "headsight fixture"
// Float above other windows: macOS stops redrawing windows that are fully covered.
win.level = .floating
win.backgroundColor = .white

func label(_ s: String, _ y: CGFloat, _ color: NSColor = .black) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: 44)
    l.textColor = color
    l.frame = NSRect(x: 60, y: y, width: 880, height: 60)
    win.contentView!.addSubview(l)
    return l
}
let status = label("Exporting...", 520)
let count = label("Counter: 0", 420)
let side = label("", 320, .systemRed)
let toast = NSTextField(labelWithString: "Saved to Downloads")
toast.font = .systemFont(ofSize: 32)
toast.textColor = .white
toast.drawsBackground = true
toast.backgroundColor = .darkGray
toast.frame = NSRect(x: 560, y: 40, width: 380, height: 50)
toast.isHidden = true
win.contentView!.addSubview(toast)

func after(_ key: String, _ f: @escaping () -> Void) {
    if let s = opts[key], let t = Double(s) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
}
after("done") { status.stringValue = "Export Done: 42 files" }
after("minimize") { win.miniaturize(nil) }
after("side") { side.stringValue = "Plan: Pro" }
after("toast") {
    toast.isHidden = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { toast.isHidden = true }
}
if opts["count"] != nil {
    let t0 = Date()
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
        if Date().timeIntervalSince(t0) >= 3 { count.stringValue = "Counter: 7310"; t.invalidate() }
        else { count.stringValue = "Counter: \(Int.random(in: 0...9999))" }
    }
}
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
signal(SIGTERM) { _ in exit(0) }
app.run()
