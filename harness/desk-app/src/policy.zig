//! What the web view may do: which navigations stay in the window, which go
//! to the system browser, and who gets the microphone. Only harness's own
//! origin, exactly `http://127.0.0.1:PORT`, is the desk.
const std = @import("std");

pub const Frame = enum { main, sub, new_window };
pub const Decision = enum { allow, external, cancel };

/// What happens to a navigation to `url` (as WebKit gives it, absolute) in
/// `frame`, with harness on `port` (null before desk.json is read).
pub fn decide(url: []const u8, port: ?u16, frame: Frame) Decision {
    if (std.mem.eql(u8, url, "about:blank") or std.mem.eql(u8, url, "about:srcdoc")) return .allow;
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return .cancel;
    const scheme = url[0..colon];
    const web = std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https");
    if (std.ascii.eqlIgnoreCase(scheme, "http") and std.mem.startsWith(u8, url[colon..], "://")) {
        const rest = url[colon + 3 ..];
        const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        if (port) |p| if (isAuthority(rest[0..end], p)) return .allow;
    }
    if (frame == .sub) return .cancel;
    if (web or std.ascii.eqlIgnoreCase(scheme, "mailto")) return .external;
    return .cancel;
}

/// `127.0.0.1:PORT` exactly (or `127.0.0.1` alone when PORT is 80).
fn isAuthority(auth: []const u8, port: u16) bool {
    const host = "127.0.0.1";
    if (!std.mem.startsWith(u8, auth, host)) return false;
    const after = auth[host.len..];
    if (after.len == 0) return port == 80;
    if (after[0] != ':' or after.len == 1) return false;
    // digits only: parseInt would also take "+" and "_"
    for (after[1..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    const n = std.fmt.parseInt(u16, after[1..], 10) catch return false;
    return n == port;
}

/// Whether a security origin (scheme, host, port; port 0 for the scheme's
/// default) is harness's own.
pub fn isHarnessOrigin(proto: []const u8, host: []const u8, origin_port: u16, port: ?u16) bool {
    const p = port orelse return false;
    if (!std.ascii.eqlIgnoreCase(proto, "http") or !std.mem.eql(u8, host, "127.0.0.1")) return false;
    return (if (origin_port == 0) 80 else origin_port) == p;
}

pub const MediaKind = enum { mic, camera, both };

/// Whether a page's request for the microphone or camera is granted: the
/// microphone only, and only to the desk page itself (not a framed app).
pub fn media(proto: []const u8, host: []const u8, origin_port: u16, port: ?u16, main_frame: bool, kind: MediaKind) bool {
    return kind == .mic and main_frame and isHarnessOrigin(proto, host, origin_port, port);
}

const t = std.testing;
const P: ?u16 = 41234;

test "only_the_exact_origin_stays" {
    for ([_][]const u8{
        "http://127.0.0.1:41234/desk",
        "http://127.0.0.1:41234",
        "http://127.0.0.1:41234/",
        "http://127.0.0.1:41234?x=1",
        "http://127.0.0.1:41234#top",
        "HTTP://127.0.0.1:41234/desk/apps/notes",
    }) |url| {
        try t.expectEqual(Decision.allow, decide(url, P, .main));
        try t.expectEqual(Decision.allow, decide(url, P, .sub));
        try t.expectEqual(Decision.allow, decide(url, P, .new_window));
    }
    for ([_][]const u8{
        "http://127.0.0.1:41234@example.com/",
        "http://user@127.0.0.1:41234/",
        "http://127.0.0.1:412340/",
        "http://127.0.0.1:4123/",
        "http://127.0.0.1/",
        "https://127.0.0.1:41234/",
        "http://localhost:41234/",
        "http://127.0.0.1.:41234/",
        "http://0x7f.0.0.1:41234/",
        "http://[::1]:41234/",
        "http://127.0.0.1:41234\\@example.com/",
        "http://127.0.0.1:41_234/",
        "http://127.0.0.1:+41234/",
    }) |url| {
        try t.expectEqual(Decision.external, decide(url, P, .main));
        try t.expectEqual(Decision.cancel, decide(url, P, .sub));
    }
    // the default port is written without a number
    try t.expectEqual(Decision.allow, decide("http://127.0.0.1/desk", 80, .main));
    try t.expectEqual(Decision.allow, decide("http://127.0.0.1:80/desk", 80, .main));
    // before desk.json is read nothing is the desk
    try t.expectEqual(Decision.external, decide("http://127.0.0.1:41234/desk", null, .main));
}

test "elsewhere_goes_to_the_browser_from_the_main_frame_only" {
    try t.expectEqual(Decision.external, decide("https://example.com/", P, .main));
    try t.expectEqual(Decision.external, decide("https://example.com/", P, .new_window));
    try t.expectEqual(Decision.cancel, decide("https://example.com/", P, .sub));
    try t.expectEqual(Decision.external, decide("http://example.com/x?y#z", P, .main));
    try t.expectEqual(Decision.external, decide("mailto:someone@example.com", P, .main));
    try t.expectEqual(Decision.cancel, decide("mailto:someone@example.com", P, .sub));
}

test "other_schemes_are_cancelled" {
    for ([_][]const u8{
        "file:///etc/hosts",
        "javascript:alert(1)",
        "data:text/html,hello",
        "blob:http://127.0.0.1:41234/5b1e",
        "ftp://example.com/",
        "harness-desk:start",
        "about:config",
        "",
        "no-scheme",
    }) |url| {
        try t.expectEqual(Decision.cancel, decide(url, P, .main));
        try t.expectEqual(Decision.cancel, decide(url, P, .new_window));
        try t.expectEqual(Decision.cancel, decide(url, P, .sub));
    }
}

test "about_blank_is_allowed" {
    // the built-in pages, and frames written in place
    try t.expectEqual(Decision.allow, decide("about:blank", null, .main));
    try t.expectEqual(Decision.allow, decide("about:blank", P, .sub));
    try t.expectEqual(Decision.allow, decide("about:srcdoc", P, .sub));
}

test "the_microphone_is_for_the_desk_page_only" {
    try t.expect(media("http", "127.0.0.1", 41234, P, true, .mic));
    try t.expect(!media("http", "127.0.0.1", 41234, P, false, .mic)); // a framed app
    try t.expect(!media("http", "127.0.0.1", 41234, P, true, .camera));
    try t.expect(!media("http", "127.0.0.1", 41234, P, true, .both));
    try t.expect(!media("https", "127.0.0.1", 41234, P, true, .mic));
    try t.expect(!media("http", "localhost", 41234, P, true, .mic));
    try t.expect(!media("http", "127.0.0.1", 41235, P, true, .mic));
    try t.expect(!media("http", "127.0.0.1", 41234, null, true, .mic));
    try t.expect(!media("", "", 0, P, true, .mic));
    // a security origin says 0 for the scheme's default port
    try t.expect(media("http", "127.0.0.1", 0, 80, true, .mic));
}
