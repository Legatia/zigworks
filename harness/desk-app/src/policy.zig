//! What the web view may do: which navigations stay in the window, which go
//! to the system browser, and who gets the microphone. Only harness's own
//! origin, exactly `http://127.0.0.1:PORT`, is the desk.
const std = @import("std");

pub const Frame = enum { main, sub, new_window };
pub const Decision = enum { allow, external, cancel };

/// Who asked for a navigation. `click`: the person's own click on a link
/// (a script's navigation, or window.open, is none). `app`: the app is
/// loading a built-in page of its own (`Doc.appLoads`).
pub const By = struct { click: bool = false, app: bool = false };

/// What happens to a navigation to `url` (as WebKit gives it, absolute) in
/// `frame`, with harness on `port` (null before desk.json is read). Only a
/// click opens the system browser; a page can't blank the window.
pub fn decide(url: []const u8, port: ?u16, frame: Frame, by: By) Decision {
    if (std.mem.eql(u8, url, "about:blank")) return if (frame == .sub or (frame == .main and by.app)) .allow else .cancel;
    if (std.mem.eql(u8, url, "about:srcdoc")) return if (frame == .sub) .allow else .cancel;
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return .cancel;
    const scheme = url[0..colon];
    const web = std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https");
    if (std.ascii.eqlIgnoreCase(scheme, "http") and std.mem.startsWith(u8, url[colon..], "://")) {
        const rest = url[colon + 3 ..];
        const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        if (port) |p| if (isAuthority(rest[0..end], p)) return .allow;
    }
    if (frame == .sub or !by.click) return .cancel;
    if (web or std.ascii.eqlIgnoreCase(scheme, "mailto")) return .external;
    return .cancel;
}

/// The main frame's document, as far as the app can know it: the built-in
/// pages load as `about:blank`, which says nothing about whose page it is.
pub const Doc = struct {
    /// Built-in pages asked for whose load hasn't finished.
    pending: u8 = 0,
    /// The built-in page is the document shown: its messages are the app's
    /// own buttons.
    builtin: bool = false,

    /// The app asked for a built-in page.
    pub fn showing(d: *Doc) void {
        d.pending +|= 1;
        d.builtin = false;
    }

    /// The app asked for the desk page.
    pub fn loading(d: *Doc) void {
        d.pending = 0;
        d.builtin = false;
    }

    /// The main frame finished loading `url`.
    pub fn finished(d: *Doc, url: []const u8) void {
        if (d.pending == 0 or !std.mem.eql(u8, url, "about:blank")) return;
        d.pending -= 1;
        d.builtin = true;
    }

    /// Whether an `about:blank` in the main frame is the app's own.
    pub fn appLoads(d: *const Doc) bool {
        return d.pending > 0;
    }
};

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
const clicked: By = .{ .click = true };
const unasked: By = .{};

test "only_the_exact_origin_stays" {
    for ([_][]const u8{
        "http://127.0.0.1:41234/desk",
        "http://127.0.0.1:41234",
        "http://127.0.0.1:41234/",
        "http://127.0.0.1:41234?x=1",
        "http://127.0.0.1:41234#top",
        "HTTP://127.0.0.1:41234/desk/apps/notes",
    }) |url| {
        try t.expectEqual(Decision.allow, decide(url, P, .main, clicked));
        try t.expectEqual(Decision.allow, decide(url, P, .sub, clicked));
        try t.expectEqual(Decision.allow, decide(url, P, .new_window, clicked));
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
        try t.expectEqual(Decision.external, decide(url, P, .main, clicked));
        try t.expectEqual(Decision.cancel, decide(url, P, .sub, clicked));
    }
    // the default port is written without a number
    try t.expectEqual(Decision.allow, decide("http://127.0.0.1/desk", 80, .main, clicked));
    try t.expectEqual(Decision.allow, decide("http://127.0.0.1:80/desk", 80, .main, clicked));
    // before desk.json is read nothing is the desk
    try t.expectEqual(Decision.external, decide("http://127.0.0.1:41234/desk", null, .main, clicked));
}

test "elsewhere_goes_to_the_browser_from_the_main_frame_only" {
    try t.expectEqual(Decision.external, decide("https://example.com/", P, .main, clicked));
    try t.expectEqual(Decision.external, decide("https://example.com/", P, .new_window, clicked));
    try t.expectEqual(Decision.cancel, decide("https://example.com/", P, .sub, clicked));
    try t.expectEqual(Decision.external, decide("http://example.com/x?y#z", P, .main, clicked));
    try t.expectEqual(Decision.external, decide("mailto:someone@example.com", P, .main, clicked));
    try t.expectEqual(Decision.cancel, decide("mailto:someone@example.com", P, .sub, clicked));
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
        try t.expectEqual(Decision.cancel, decide(url, P, .main, clicked));
        try t.expectEqual(Decision.cancel, decide(url, P, .new_window, clicked));
        try t.expectEqual(Decision.cancel, decide(url, P, .sub, clicked));
    }
}

test "about_blank_is_for_frames_and_the_apps_own_pages" {
    // frames written in place
    try t.expectEqual(Decision.allow, decide("about:blank", P, .sub, unasked));
    try t.expectEqual(Decision.allow, decide("about:srcdoc", P, .sub, unasked));
    // the built-in pages, which the app itself loads
    try t.expectEqual(Decision.allow, decide("about:blank", null, .main, .{ .app = true }));
    try t.expectEqual(Decision.allow, decide("about:blank", P, .main, .{ .app = true }));
    // a page can't blank the window, with a click or without
    try t.expectEqual(Decision.cancel, decide("about:blank", P, .main, unasked));
    try t.expectEqual(Decision.cancel, decide("about:blank", P, .main, clicked));
    try t.expectEqual(Decision.cancel, decide("about:blank", P, .new_window, clicked));
    try t.expectEqual(Decision.cancel, decide("about:srcdoc", P, .main, .{ .app = true }));
}

test "the_browser_opens_only_on_a_click" {
    // a script's own navigation, or window.open, opens nothing outside
    try t.expectEqual(Decision.cancel, decide("https://example.com/", P, .main, unasked));
    try t.expectEqual(Decision.cancel, decide("https://example.com/", P, .new_window, unasked));
    try t.expectEqual(Decision.cancel, decide("mailto:someone@example.com", P, .main, unasked));
    try t.expectEqual(Decision.cancel, decide("http://127.0.0.1:41234@example.com/", P, .main, unasked));
    try t.expectEqual(Decision.cancel, decide("https://example.com/", P, .main, .{ .app = true }));
    // the desk's own address needs none
    try t.expectEqual(Decision.allow, decide("http://127.0.0.1:41234/desk", P, .main, unasked));
    try t.expectEqual(Decision.allow, decide("http://127.0.0.1:41234/desk", P, .new_window, unasked));
    try t.expectEqual(Decision.allow, decide("http://127.0.0.1:41234/a/notes/", P, .sub, unasked));
}

test "the_built_in_page_is_known_by_its_load" {
    var d: Doc = .{};
    try t.expect(!d.builtin and !d.appLoads());
    // asked for: its about:blank may load, and it isn't the document yet
    d.showing();
    try t.expect(d.appLoads() and !d.builtin);
    // another page finishing meanwhile changes nothing
    d.finished("http://127.0.0.1:41234/desk");
    try t.expect(d.appLoads() and !d.builtin);
    d.finished("about:blank");
    try t.expect(d.builtin and !d.appLoads());
    // two asked for at once, the first finishing before the second starts
    d.showing();
    d.showing();
    d.finished("about:blank");
    try t.expect(d.appLoads());
    d.finished("about:blank");
    try t.expect(d.builtin and !d.appLoads());
    // the desk loading: the built-in page is gone, and nothing of it is owed
    d.showing();
    d.loading();
    try t.expect(!d.builtin and !d.appLoads());
    d.finished("about:blank");
    try t.expect(!d.builtin);
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
