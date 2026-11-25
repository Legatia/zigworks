//! The app's own pages, shown while there's no desk to show.
const std = @import("std");

pub const Screen = enum { setup, down, connecting };

/// The page for `screen`, with `note` under it and, on the setup page, the
/// data folder looked in. Both are escaped. Nothing is loaded from anywhere.
pub fn html(a: std.mem.Allocator, screen: Screen, note: []const u8, home: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, head);
    switch (screen) {
        .setup => {
            try out.appendSlice(a, "<h1>Set up harness first: run <code>harness init</code>.</h1>\n<p>Data folder: ");
            try escape(&out, a, home);
            try out.appendSlice(a, "</p>\n");
        },
        .down => try out.appendSlice(a, "<h1>harness isn't running</h1>\n<button id=\"start\" type=\"button\">Start harness</button>\n"),
        .connecting => try out.appendSlice(a, "<h1>Connecting…</h1>\n"),
    }
    if (note.len > 0) {
        try out.appendSlice(a, "<p class=\"note\">");
        try escape(&out, a, note);
        try out.appendSlice(a, "</p>\n");
    }
    try out.appendSlice(a, "</main>\n");
    if (screen == .down) try out.appendSlice(a, start_script);
    try out.appendSlice(a, "</body>\n</html>\n");
    return out.toOwnedSlice(a);
}

fn escape(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '&' => try out.appendSlice(a, "&amp;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\'' => try out.appendSlice(a, "&#39;"),
        else => try out.append(a, ch),
    };
}

const head =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<title>harness</title>
    \\<style>
    \\:root { color-scheme: dark; }
    \\html, body { margin: 0; height: 100%; background: #07070D; color: #E8E9F3;
    \\  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
    \\main { box-sizing: border-box; min-height: 100%; padding: 24px; display: flex; flex-direction: column;
    \\  align-items: center; justify-content: center; gap: 16px; text-align: center; }
    \\h1 { margin: 0; font-size: 22px; font-weight: 600; }
    \\p { margin: 0; color: #9A9CB8; }
    \\code { font: 14px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: #E8E9F3;
    \\  background: #0E0F1A; border: 1px solid #24263A; padding: 2px 6px; }
    \\button { min-height: 44px; min-width: 44px; padding: 0 20px; font: inherit; font-weight: 600;
    \\  color: #07070D; background: #22E5FF; border: 0; border-radius: 2px; cursor: pointer; }
    \\button:focus-visible { outline: 2px solid #E8E9F3; outline-offset: 3px; }
    \\button:disabled { color: #9A9CB8; background: #24263A; cursor: default; }
    \\</style>
    \\</head>
    \\<body>
    \\<main>
    \\
;

/// [Start harness] tells the app through the same bridge the desk uses
/// (WebKit's here and on Linux, WebView2's on Windows).
const start_script =
    \\<script>
    \\(function () {
    \\  var b = document.getElementById("start");
    \\  b.addEventListener("click", function () {
    \\    b.disabled = true;
    \\    b.textContent = "Starting…";
    \\    var w = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.desk;
    \\    if (w) w.postMessage({start: true});
    \\    else if (window.chrome && window.chrome.webview) window.chrome.webview.postMessage({start: true});
    \\    setTimeout(function () { b.disabled = false; b.textContent = "Start harness"; }, 15000);
    \\  });
    \\  b.focus();
    \\})();
    \\</script>
    \\
;

const t = std.testing;

test "screens_say_the_fixed_copy" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const setup = try html(a, .setup, "", "/Users/me/.local/share/harness");
    try t.expect(std.mem.indexOf(u8, setup, "Set up harness first: run <code>harness init</code>.") != null);
    try t.expect(std.mem.indexOf(u8, setup, "/Users/me/.local/share/harness") != null);
    try t.expect(std.mem.indexOf(u8, setup, "<button") == null);

    const down = try html(a, .down, "", "/h");
    try t.expect(std.mem.indexOf(u8, down, "harness isn't running") != null);
    try t.expect(std.mem.indexOf(u8, down, ">Start harness</button>") != null);
    try t.expect(std.mem.indexOf(u8, down, "messageHandlers.desk") != null);
    try t.expect(std.mem.indexOf(u8, down, "{start: true}") != null);

    const conn = try html(a, .connecting, "No answer from harness yet. Trying again.", "/h");
    try t.expect(std.mem.indexOf(u8, conn, "Connecting…") != null);
    try t.expect(std.mem.indexOf(u8, conn, "No answer from harness yet. Trying again.") != null);
    for ([_][]const u8{ setup, down, conn }) |page| {
        try t.expect(std.mem.startsWith(u8, page, "<!doctype html>"));
        try t.expect(std.mem.indexOf(u8, page, "<title>harness</title>") != null);
        // nothing from outside: no address to load anything from
        try t.expect(std.mem.indexOf(u8, page, "http") == null);
    }
}

test "inserted_text_is_escaped" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try html(a, .setup, "<script>alert(1)</script> & \"x\" 'y'", "/Users/<b>me</b>");
    try t.expect(std.mem.indexOf(u8, page, "<script>alert") == null);
    try t.expect(std.mem.indexOf(u8, page, "&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;x&quot; &#39;y&#39;") != null);
    try t.expect(std.mem.indexOf(u8, page, "/Users/&lt;b&gt;me&lt;/b&gt;") != null);
}
