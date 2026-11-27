//! The app's own pages, shown while there's no desk to show.
const std = @import("std");

const setup = @import("setup.zig");

pub const Screen = enum { setup, down, connecting };

/// The "Set up" screen's state: before harness was ever set up (`first`),
/// or opened from "Provider and key…" (`change`).
pub const Mode = enum { first, change };

pub const View = struct {
    mode: Mode = .first,
    form: setup.Form = .{},
    /// Its steps are running: Continue waits.
    busy: bool = false,
    /// "Provider and key": whether the private model is the screen's to
    /// edit (setup.privateOwned); when it isn't, `private_in_use`
    /// (`[model] private_model` as config.ini has it) is shown as it is.
    private_owned: bool = true,
    private_in_use: []const u8 = "",
};

/// The page for `screen`, with `note` under it; the setup page shows
/// `view`'s form and the data folder. Text is escaped. Nothing is loaded
/// from anywhere.
pub fn html(a: std.mem.Allocator, screen: Screen, note: []const u8, home: []const u8, view: View) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, head);
    switch (screen) {
        .setup => return setupPage(a, &out, note, home, view),
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

/// "Set up" (or "Provider and key"): Provider, Model, Address (omnigate and
/// Other), Format (Other), [Continue]. The key isn't asked for here: the
/// app asks for it in a field of its own, outside the page. "Provider and
/// key" also has the private model: a server that takes no key.
fn setupPage(a: std.mem.Allocator, out: *std.ArrayList(u8), note: []const u8, home: []const u8, view: View) ![]u8 {
    const f = view.form;
    const e = setup.entry(f.provider);
    try out.appendSlice(a, if (view.mode == .first) "<h1>Set up</h1>\n" else "<h1>Provider and key</h1>\n");
    try out.appendSlice(a, "<form id=\"setup\" autocomplete=\"off\">\n<div class=\"row\"><label for=\"provider\">Provider</label><select id=\"provider\">");
    for (setup.entries) |x| {
        try out.print(a, "<option value=\"{t}\"{s}>", .{ x.id, if (x.id == f.provider) " selected" else "" });
        try escape(out, a, x.label);
        try out.appendSlice(a, "</option>");
    }
    try out.appendSlice(a, "</select></div>\n<div class=\"row\"><label for=\"model\">Model</label><input id=\"model\" value=\"");
    try escape(out, a, f.model);
    try out.appendSlice(a, "\" spellcheck=\"false\" required></div>\n");
    try out.print(a, "<div class=\"row\" id=\"address-row\"{s}>", .{if (e.address) "" else " hidden"});
    try out.appendSlice(a, "<label for=\"url\">Address</label><input id=\"url\" value=\"");
    try escape(out, a, f.url);
    try out.appendSlice(a, "\" spellcheck=\"false\" inputmode=\"url\">" ++
        "<button class=\"i\" id=\"i-address\" type=\"button\" aria-label=\"About Address\" aria-expanded=\"false\">i</button></div>\n" ++
        "<div class=\"bubble\" id=\"bubble-address\" hidden>Where the provider answers: the part before <code>/messages</code> or " ++
        "<code>/chat/completions</code>, like <code>https://gateway.example.com/v1</code>. For omnigate, its own address. " ++
        "A server of your own that takes no key: leave the key empty.</div>\n");
    // a risk to see before Continue: shown on the page, not behind the "i"
    try out.print(a, "<p class=\"warn\" id=\"warn-address\"{s}>" ++
        "http:// is not encrypted: what goes to this address, the key included, can be read on the network.</p>\n", .{
        if (e.address and setup.plainRemote(f.url)) "" else " hidden",
    });
    try out.print(a, "<div class=\"row\" id=\"api-row\"{s}>", .{if (f.provider == .other) "" else " hidden"});
    try out.print(a, "<label for=\"api\">Format</label><select id=\"api\"><option value=\"openai\"{s}>OpenAI Chat Completions</option>" ++
        "<option value=\"anthropic\"{s}>Anthropic Messages</option></select></div>\n", .{
        if (f.api == .openai) " selected" else "",
        if (f.api == .anthropic) " selected" else "",
    });
    if (view.mode == .change) {
        try out.print(a, "<div class=\"row check\"><input id=\"replace\" type=\"checkbox\"{s}><label for=\"replace\">Replace the key</label></div>\n", .{if (f.replace) " checked" else ""});
        try privateRows(a, out, view);
    }
    try out.appendSlice(a, "<p class=\"note\" id=\"note\" role=\"alert\">");
    try escape(out, a, note);
    try out.appendSlice(a, "</p>\n<div class=\"buttons\">");
    if (view.mode == .change) try out.appendSlice(a, "<button id=\"cancel\" class=\"plain\" type=\"button\">Cancel</button>");
    try out.appendSlice(a, if (view.busy) "<button id=\"continue\" type=\"submit\" disabled>Working…</button>" else "<button id=\"continue\" type=\"submit\">Continue</button>");
    try out.appendSlice(a, "</div>\n</form>\n<p class=\"home\">Data folder: ");
    try escape(out, a, home);
    try out.appendSlice(a, "</p>\n</main>\n<script>\nvar models = {");
    for (setup.entries, 0..) |x, i| {
        // fixed strings of ours: no quote or backslash in them
        try out.print(a, "{s}\"{t}\":\"{s}\"", .{ if (i > 0) "," else "", x.id, x.model });
    }
    try out.appendSlice(a, "};\nvar addressed = {");
    for (setup.entries, 0..) |x, i| try out.print(a, "{s}\"{t}\":{}", .{ if (i > 0) "," else "", x.id, x.address });
    try out.appendSlice(a, "};\n");
    try out.appendSlice(a, setup_script);
    try out.appendSlice(a, "</script>\n</body>\n</html>\n");
    return out.toOwnedSlice(a);
}

/// "Private model": the model of a server of one's own that answers private
/// conversations. What it is sits behind the "i"; what crosses the network
/// unencrypted is said on the page. One that config.ini set another way is
/// shown and not edited.
fn privateRows(a: std.mem.Allocator, out: *std.ArrayList(u8), view: View) !void {
    const f = view.form;
    try out.appendSlice(a, "<div class=\"group\"><h2 id=\"private-title\">Private model</h2>" ++
        "<button class=\"i\" id=\"i-private\" type=\"button\" aria-label=\"About Private model\" aria-expanded=\"false\">i</button></div>\n" ++
        "<div class=\"bubble wide\" id=\"bubble-private\" hidden>Answers the conversations set to private with <code>/private on</code>; " ++
        "no other model is sent them. A server of your own that takes no key, like Ollama at <code>http://127.0.0.1:11434/v1</code>. " ++
        "With no model here, private conversations go to the model above. A provider that takes a key is set in config.ini.</div>\n");
    if (!view.private_owned) {
        try out.appendSlice(a, "<p class=\"fixed\">");
        if (view.private_in_use.len > 0) {
            try out.appendSlice(a, "<code>");
            try escape(out, a, view.private_in_use);
            try out.appendSlice(a, "</code> Set in config.ini.</p>\n");
        } else try out.appendSlice(a, "None. Set in config.ini.</p>\n");
        return;
    }
    try out.appendSlice(a, "<div class=\"row\"><label for=\"pmodel\">Model</label><input id=\"pmodel\" value=\"");
    try escape(out, a, f.private_model);
    try out.appendSlice(a, "\" placeholder=\"None\" spellcheck=\"false\" aria-describedby=\"private-title\"></div>\n" ++
        "<div class=\"row\"><label for=\"purl\">Address</label><input id=\"purl\" value=\"");
    try escape(out, a, f.private_url);
    try out.appendSlice(a, "\" spellcheck=\"false\" inputmode=\"url\" aria-describedby=\"private-title\"></div>\n");
    // a risk to see before Continue: on the page
    try out.print(a, "<p class=\"warn\" id=\"warn-private\"{s}>" ++
        "http:// is not encrypted: what is said in a private conversation can be read on the network on its way to this address.</p>\n", .{
        if (std.mem.trim(u8, f.private_model, " \t\r\n").len > 0 and setup.plainRemote(f.private_url)) "" else " hidden",
    });
    try out.print(a, "<div class=\"row\"><label for=\"papi\">Format</label><select id=\"papi\"><option value=\"openai\"{s}>OpenAI Chat Completions</option>" ++
        "<option value=\"anthropic\"{s}>Anthropic Messages</option></select></div>\n", .{
        if (f.private_api == .openai) " selected" else "",
        if (f.private_api == .anthropic) " selected" else "",
    });
}

/// The form's own behaviour: the provider switches the model to its usual
/// one (unless one was typed since the last switch) and the rows shown;
/// Continue posts the form to the app, which runs the steps and shows the
/// page again.
const setup_script =
    \\function post(m) {
    \\  var w = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.harness;
    \\  if (w) w.postMessage(m);
    \\  else if (window.chrome && window.chrome.webview) window.chrome.webview.postMessage(m);
    \\}
    \\// setup.plainRemote's rule: http:// and not this computer
    \\function plainRemote(u) {
    \\  u = u.trim();
    \\  if (u.indexOf("http://") !== 0) return false;
    \\  var h = u.slice(7).split(/[\/?#]/)[0];
    \\  h = h.slice(h.lastIndexOf("@") + 1);
    \\  if (h.charAt(0) === "[") { var j = h.indexOf("]"); h = j < 0 ? h : h.slice(0, j + 1); }
    \\  else h = h.split(":")[0];
    \\  if (h === "") return false;
    \\  var l = h.toLowerCase();
    \\  if (l === "localhost" || /\.localhost$/.test(l) || h === "[::1]") return false;
    \\  return !/^127\.\d+\.\d+\.\d+$/.test(h);
    \\}
    \\(function () {
    \\  var $ = function (id) { return document.getElementById(id); };
    \\  var provider = $("provider"), model = $("model"), url = $("url"), api = $("api");
    \\  var typed = false;
    \\  function warn() { $("warn-address").hidden = !(addressed[provider.value] && plainRemote(url.value)); }
    \\  url.addEventListener("input", warn);
    \\  model.addEventListener("input", function () { typed = true; });
    \\  provider.addEventListener("change", function () {
    \\    var p = provider.value;
    \\    if (!typed || model.value.trim() === "") model.value = models[p];
    \\    typed = false;
    \\    $("address-row").hidden = !addressed[p];
    \\    $("api-row").hidden = p !== "other";
    \\    if (!addressed[p]) { $("bubble-address").hidden = true; $("i-address").setAttribute("aria-expanded", "false"); }
    \\    warn();
    \\  });
    \\  function info(name) {
    \\    var i = $("i-" + name), b = $("bubble-" + name);
    \\    if (i) i.addEventListener("click", function () {
    \\      b.hidden = !b.hidden;
    \\      i.setAttribute("aria-expanded", b.hidden ? "false" : "true");
    \\    });
    \\  }
    \\  info("address");
    \\  info("private");
    \\  var pmodel = $("pmodel"), purl = $("purl"), papi = $("papi");
    \\  function pwarn() { $("warn-private").hidden = !(pmodel.value.trim() !== "" && plainRemote(purl.value)); }
    \\  if (purl) {
    \\    purl.addEventListener("input", pwarn);
    \\    pmodel.addEventListener("input", pwarn);
    \\  }
    \\  var cancel = $("cancel");
    \\  if (cancel) cancel.addEventListener("click", function () { post({cancel: true}); });
    \\  $("setup").addEventListener("submit", function (ev) {
    \\    ev.preventDefault();
    \\    var b = $("continue");
    \\    if (b.disabled) return;
    \\    b.disabled = true;
    \\    b.textContent = "Working…";
    \\    var replace = $("replace");
    \\    post({setup: {provider: provider.value, model: model.value, url: url.value, api: api.value, replace: !!(replace && replace.checked),
    \\      private_model: pmodel ? pmodel.value : "", private_url: purl ? purl.value : "", private_api: papi ? papi.value : "openai"}});
    \\  });
    \\  if (!model.value) model.focus(); else $("continue").focus();
    \\})();
    \\
;

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
    \\form { width: 100%; max-width: 440px; display: flex; flex-direction: column; gap: 12px; text-align: left; }
    \\.row { display: grid; grid-template-columns: 88px 1fr auto; align-items: center; gap: 10px; }
    \\.row[hidden], .bubble[hidden], .warn[hidden] { display: none; }
    \\.warn { margin: 0 0 0 98px; font-size: 13px; color: #FFB454; }
    \\.row.check { grid-template-columns: 88px auto 1fr; }
    \\.row.check input { grid-column: 2; }
    \\label { color: #9A9CB8; }
    \\input, select { box-sizing: border-box; min-height: 36px; width: 100%; font: inherit; color: #E8E9F3;
    \\  background: #0E0F1A; border: 1px solid #24263A; border-radius: 2px; padding: 0 10px; }
    \\input[type=checkbox] { width: 18px; min-height: 18px; accent-color: #22E5FF; }
    \\input:focus-visible, select:focus-visible { outline: 2px solid #22E5FF; outline-offset: 1px; }
    \\button.i { min-height: 24px; min-width: 24px; width: 24px; padding: 0; border-radius: 50%; font-size: 13px;
    \\  color: #9A9CB8; background: transparent; border: 1px solid #24263A; }
    \\button.plain { color: #E8E9F3; background: transparent; border: 1px solid #24263A; }
    \\.bubble { margin-left: 98px; padding: 10px 12px; font-size: 13px; color: #E8E9F3; background: #0E0F1A; border: 1px solid #24263A; }
    \\.buttons { display: flex; justify-content: flex-end; gap: 10px; }
    \\.note:empty { display: none; }
    \\form .note { color: #FF5C7A; }
    \\.home { font-size: 13px; }
    \\.group { display: flex; align-items: center; gap: 10px; margin-top: 8px; padding-top: 14px; border-top: 1px solid #24263A; }
    \\h2 { margin: 0; font-size: 15px; font-weight: 600; }
    \\.bubble.wide { margin-left: 0; }
    \\.fixed { font-size: 13px; }
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
    \\    var w = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.harness;
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
    const down = try html(a, .down, "", "/h", .{});
    try t.expect(std.mem.indexOf(u8, down, "harness isn't running") != null);
    try t.expect(std.mem.indexOf(u8, down, ">Start harness</button>") != null);
    try t.expect(std.mem.indexOf(u8, down, "messageHandlers.harness") != null);
    try t.expect(std.mem.indexOf(u8, down, "{start: true}") != null);

    const conn = try html(a, .connecting, "No answer from harness yet. Trying again.", "/h", .{});
    try t.expect(std.mem.indexOf(u8, conn, "Connecting…") != null);
    try t.expect(std.mem.indexOf(u8, conn, "No answer from harness yet. Trying again.") != null);
    const set = try html(a, .setup, "", "/Users/me/.local/share/harness", .{});
    for ([_][]const u8{ set, down, conn }) |page| {
        try t.expect(std.mem.startsWith(u8, page, "<!doctype html>"));
        try t.expect(std.mem.indexOf(u8, page, "<title>harness</title>") != null);
        // nothing from outside: no address to load anything from
        try t.expect(std.mem.indexOf(u8, page, "src=\"http") == null);
        try t.expect(std.mem.indexOf(u8, page, "href=\"http") == null);
    }
}

fn has(page: []const u8, text: []const u8) bool {
    return std.mem.indexOf(u8, page, text) != null;
}

test "a_plain_address_elsewhere_is_said_on_the_page" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = "http:// is not encrypted: what goes to this address, the key included, can be read on the network.";
    const far = try html(a, .setup, "", "/h", .{ .form = .{ .provider = .other, .model = "m", .url = "http://192.168.1.20:8080/v1" } });
    try t.expect(has(far, "<p class=\"warn\" id=\"warn-address\">" ++ line ++ "</p>"));
    // not for this computer, not for https, and not while the Address row is hidden
    const here = try html(a, .setup, "", "/h", .{ .form = .{ .provider = .other, .model = "m", .url = "http://127.0.0.1:9/v1" } });
    try t.expect(has(here, "<p class=\"warn\" id=\"warn-address\" hidden>" ++ line ++ "</p>"));
    const tls = try html(a, .setup, "", "/h", .{ .form = .{ .provider = .omnigate, .model = "m", .url = "https://gate.example.com" } });
    try t.expect(has(tls, "<p class=\"warn\" id=\"warn-address\" hidden>"));
    const none = try html(a, .setup, "", "/h", .{ .form = .{ .provider = .anthropic, .model = "m", .url = "http://192.168.1.20:8080/v1" } });
    try t.expect(has(none, "<p class=\"warn\" id=\"warn-address\" hidden>"));
    // the page keeps it right as the address is typed
    try t.expect(has(far, "function plainRemote(u)"));
    try t.expect(has(far, "url.addEventListener(\"input\", warn)"));
}

test "setup_page_has_the_fields_and_labels" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try html(a, .setup, "", "/Users/me/.local/share/harness", .{ .form = .{ .provider = .anthropic, .model = "claude-opus-4-8" } });
    try t.expect(has(page, "<h1>Set up</h1>"));
    for ([_][]const u8{ "Anthropic", "OpenAI", "OpenRouter", "opencode", "omnigate", "Other" }) |label| {
        try t.expect(has(page, try std.fmt.allocPrint(a, ">{s}</option>", .{label})));
    }
    try t.expect(has(page, "<option value=\"anthropic\" selected>Anthropic</option>"));
    try t.expect(has(page, ">Provider<"));
    try t.expect(has(page, ">Model<"));
    try t.expect(has(page, "id=\"model\" value=\"claude-opus-4-8\""));
    try t.expect(has(page, ">Address<"));
    try t.expect(has(page, ">Format<"));
    try t.expect(has(page, ">Continue</button>"));
    // Address and Format are hidden for Anthropic
    try t.expect(has(page, "<div class=\"row\" id=\"address-row\" hidden>"));
    try t.expect(has(page, "<div class=\"row\" id=\"api-row\" hidden>"));
    // the usual models come along for the page's own provider switch
    try t.expect(has(page, "\"openai\":\"gpt-5\""));
    try t.expect(has(page, "\"omnigate\":\"claude-sonnet\""));
    // where it sets up
    try t.expect(has(page, "/Users/me/.local/share/harness"));
    // the key is never asked for here, and nothing on the first setup to cancel or replace
    try t.expect(!has(page, "password"));
    try t.expect(!has(page, "Replace the key"));
    try t.expect(!has(page, ">Cancel<"));
    // it posts the form through the bridge
    try t.expect(has(page, "messageHandlers.harness"));
    try t.expect(has(page, "{setup: "));

    const other = try html(a, .setup, "", "/h", .{ .form = .{ .provider = .other, .model = "m", .url = "http://127.0.0.1:8080/v1", .api = .anthropic } });
    try t.expect(has(other, "<div class=\"row\" id=\"address-row\">"));
    try t.expect(has(other, "<div class=\"row\" id=\"api-row\">"));
    try t.expect(has(other, "<option value=\"anthropic\" selected>Anthropic Messages</option>"));
    try t.expect(has(other, "id=\"url\" value=\"http://127.0.0.1:8080/v1\""));
    const og = try html(a, .setup, "", "/h", .{ .form = .{ .provider = .omnigate, .model = "claude-sonnet" } });
    try t.expect(has(og, "<div class=\"row\" id=\"address-row\">"));
    try t.expect(has(og, "<div class=\"row\" id=\"api-row\" hidden>"));

    // "Provider and key…": its own title, Cancel, and the key replaced only when chosen
    const change = try html(a, .setup, "", "/h", .{ .mode = .change, .form = .{ .provider = .openai, .model = "gpt-5" } });
    try t.expect(has(change, "<h1>Provider and key</h1>"));
    try t.expect(has(change, ">Cancel</button>"));
    try t.expect(has(change, "Replace the key"));
    try t.expect(has(change, "id=\"replace\" type=\"checkbox\">"));
    const ticked = try html(a, .setup, "", "/h", .{ .mode = .change, .form = .{ .provider = .openai, .model = "gpt-5", .replace = true } });
    try t.expect(has(ticked, "id=\"replace\" type=\"checkbox\" checked>"));
}

test "provider_and_key_has_the_private_model" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try html(a, .setup, "", "/h", .{ .mode = .change, .form = .{ .provider = .anthropic, .model = "m", .private_model = "llama3.1:8b", .private_url = "http://127.0.0.1:11434/v1", .private_api = .anthropic } });
    try t.expect(has(page, "<h2 id=\"private-title\">Private model"));
    try t.expect(has(page, "<label for=\"pmodel\">Model</label><input id=\"pmodel\" value=\"llama3.1:8b\""));
    try t.expect(has(page, "<label for=\"purl\">Address</label><input id=\"purl\" value=\"http://127.0.0.1:11434/v1\""));
    try t.expect(has(page, "<label for=\"papi\">Format</label><select id=\"papi\"><option value=\"openai\">OpenAI Chat Completions</option><option value=\"anthropic\" selected>Anthropic Messages</option>"));
    // what it is: behind the "i"
    try t.expect(has(page, "<button class=\"i\" id=\"i-private\" type=\"button\" aria-label=\"About Private model\" aria-expanded=\"false\">i</button>"));
    try t.expect(has(page, "<div class=\"bubble wide\" id=\"bubble-private\" hidden>"));
    try t.expect(has(page, "<code>/private on</code>"));
    // it goes with the form
    try t.expect(has(page, "private_model: pmodel ? pmodel.value : \"\""));
    try t.expect(has(page, "private_url: purl ? purl.value : \"\""));
    try t.expect(has(page, "private_api: papi ? papi.value : \"openai\""));
    // this computer: no warning shown
    const line = "http:// is not encrypted: what is said in a private conversation can be read on the network on its way to this address.";
    try t.expect(has(page, "<p class=\"warn\" id=\"warn-private\" hidden>" ++ line ++ "</p>"));
    const far = try html(a, .setup, "", "/h", .{ .mode = .change, .form = .{ .model = "m", .private_model = "x", .private_url = "http://192.168.1.20:11434/v1" } });
    try t.expect(has(far, "<p class=\"warn\" id=\"warn-private\">" ++ line ++ "</p>"));
    try t.expect(has(far, "purl.addEventListener(\"input\", pwarn)"));
    // not at the first setup
    const first = try html(a, .setup, "", "/h", .{ .form = .{ .model = "m" } });
    try t.expect(!has(first, "id=\"pmodel\""));
    try t.expect(!has(first, "<h2"));
}

test "a_private_model_of_config_inis_own_is_shown_and_not_edited" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try html(a, .setup, "", "/h", .{ .mode = .change, .form = .{ .model = "m" }, .private_owned = false, .private_in_use = "openrouter:x/<y>" });
    try t.expect(has(page, "<h2 id=\"private-title\">Private model"));
    try t.expect(has(page, "<p class=\"fixed\"><code>openrouter:x/&lt;y&gt;</code> Set in config.ini.</p>"));
    try t.expect(!has(page, "id=\"pmodel\""));
    try t.expect(!has(page, "id=\"purl\""));
    // none set, and [provider local] is config.ini's
    const none = try html(a, .setup, "", "/h", .{ .mode = .change, .form = .{ .model = "m" }, .private_owned = false });
    try t.expect(has(none, "<p class=\"fixed\">None. Set in config.ini.</p>"));
}

test "form_values_are_escaped" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try html(a, .setup, "<b>no</b>", "/h", .{ .form = .{ .provider = .other, .model = "\"><script>x</script>", .url = "https://a.example/?a=1&b='2'" } });
    try t.expect(!has(page, "<script>x</script>"));
    try t.expect(has(page, "value=\"&quot;&gt;&lt;script&gt;x&lt;/script&gt;\""));
    try t.expect(has(page, "value=\"https://a.example/?a=1&amp;b=&#39;2&#39;\""));
    try t.expect(has(page, "&lt;b&gt;no&lt;/b&gt;"));
}

test "busy_disables_continue" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try html(a, .setup, "", "/h", .{ .busy = true, .form = .{ .model = "m" } });
    try t.expect(has(page, "<button id=\"continue\" type=\"submit\" disabled>Working…</button>"));
    const idle = try html(a, .setup, "Model is empty.", "/h", .{ .form = .{} });
    try t.expect(has(idle, "<button id=\"continue\" type=\"submit\">Continue</button>"));
    // the failing step's line, where it can be read
    try t.expect(has(idle, "<p class=\"note\" id=\"note\" role=\"alert\">Model is empty.</p>"));
}

test "the_i_button_opens_a_bubble" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try html(a, .setup, "", "/h", .{ .form = .{ .provider = .other } });
    try t.expect(has(page, "<button class=\"i\" id=\"i-address\" type=\"button\" aria-label=\"About Address\" aria-expanded=\"false\">i</button>"));
    try t.expect(has(page, "<div class=\"bubble\" id=\"bubble-address\" hidden>"));
    try t.expect(has(page, "A server of your own that takes no key: leave the key empty."));
}

test "inserted_text_is_escaped" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page = try html(a, .connecting, "<script>alert(1)</script> & \"x\" 'y'", "/Users/<b>me</b>", .{});
    try t.expect(std.mem.indexOf(u8, page, "<script>alert") == null);
    try t.expect(std.mem.indexOf(u8, page, "&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;x&quot; &#39;y&#39;") != null);
    const set = try html(a, .setup, "", "/Users/<b>me</b>", .{});
    try t.expect(std.mem.indexOf(u8, set, "/Users/&lt;b&gt;me&lt;/b&gt;") != null);
}

test "a_new_provider_brings_its_model_unless_one_was_typed" {
    // the model in use belongs to the provider in use: switching replaces
    // it, unless the owner typed one since the last switch
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const page = try html(arena.allocator(), .setup, "", "/h", .{ .mode = .change, .form = .{ .provider = .openai, .model = "gpt-5-mini" } });
    try t.expect(has(page, "model.addEventListener(\"input\", function () { typed = true; });"));
    try t.expect(has(page, "if (!typed || model.value.trim() === \"\") model.value = models[p];"));
}
