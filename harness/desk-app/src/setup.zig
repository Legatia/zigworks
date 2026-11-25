//! The app's own "Set up" screen, apart from the window: the providers it
//! offers, the form, what's wrong with it, and the command line of each
//! step ([Continue]: `harness init`, `harness config set`, the key piped to
//! `harness secret add NAME --stdin`). The key itself never comes here.
const std = @import("std");

pub const Provider = enum { anthropic, openai, openrouter, opencode, omnigate, other };

/// The format an address of one's own speaks (`[provider NAME] api`).
pub const Api = enum { openai, anthropic };

pub const Entry = struct {
    id: Provider,
    /// As the screen shows it.
    label: []const u8,
    /// harness's name for it (model.zig's presets); "" for Other, whose
    /// section is named when it is written.
    name: []const u8,
    /// The model the form starts with; "" when harness names none.
    model: []const u8,
    /// `memory_model` and `worker_model`; null: the model.
    helper: ?[]const u8,
    /// Whether it takes an address.
    address: bool,
};

/// The screen's providers, in its order. The models are the ones harness's
/// own code and README use with each provider (none is named for opencode,
/// nor for an address of one's own: the owner types it).
pub const entries = [_]Entry{
    // claude-opus-4-8: the newest Claude that answers without thinking when a
    // request doesn't ask for it; harness's requests carry no thinking blocks
    .{ .id = .anthropic, .label = "Anthropic", .name = "anthropic", .model = "claude-opus-4-8", .helper = "claude-haiku-4-5", .address = false },
    .{ .id = .openai, .label = "OpenAI", .name = "openai", .model = "gpt-5", .helper = null, .address = false },
    .{ .id = .openrouter, .label = "OpenRouter", .name = "openrouter", .model = "anthropic/claude-sonnet-4", .helper = null, .address = false },
    .{ .id = .opencode, .label = "opencode", .name = "opencode", .model = "", .helper = null, .address = false },
    // harness init's routes
    .{ .id = .omnigate, .label = "omnigate", .name = "omnigate", .model = "claude-sonnet", .helper = "claude-haiku", .address = true },
    .{ .id = .other, .label = "Other", .name = "", .model = "", .helper = null, .address = true },
};

pub fn entry(p: Provider) Entry {
    return entries[@backingInt(p)];
}

/// The preset `name` is, or null (a section of one's own, or nothing).
fn presetOf(name: []const u8) ?Provider {
    for (entries) |e| if (e.name.len > 0 and std.mem.eql(u8, e.name, name)) return e.id;
    return null;
}

pub const Form = struct {
    provider: Provider = .anthropic,
    model: []const u8 = "",
    url: []const u8 = "",
    api: Api = .openai,
    /// "Provider and key…": ask for the key again.
    replace: bool = false,
};

/// What `harness config get` printed for the values in use.
pub const InUse = struct {
    /// `model.provider`
    provider: []const u8 = "",
    /// `model.model`
    model: []const u8 = "",
    /// `model.url` (omnigate's address)
    url: []const u8 = "",
    /// `model.key` (omnigate's secret)
    model_key: []const u8 = "",
    /// `provider NAME.api`, `.url` and `.key` of the provider in use.
    api: []const u8 = "",
    section_url: []const u8 = "",
    section_key: []const u8 = "",
    /// `provider NAME.auth` of the provider in use ("": its format's own).
    auth: []const u8 = "",
};

/// What [Continue] does about the key: nothing (`keep`), one was typed
/// (`given`), or none, for a server that takes none (Other only).
pub const KeyChoice = enum { keep, given, none };

/// Whether the key may be left empty: an address of one's own may take
/// none (a local server), so its section gets `auth = none`.
pub fn keyOptional(p: Provider) bool {
    return p == .other;
}

/// The key as typed, without the spaces or line ends around it (a pasted
/// key often brings one).
pub fn trimKey(key: []const u8) []const u8 {
    return std.mem.trim(u8, key, " \t\r\n");
}

/// The form for the values in use. A provider that is no preset is a
/// section of one's own: Other, with its format and address.
pub fn formOf(u: InUse) Form {
    const name = if (u.provider.len == 0) "omnigate" else u.provider;
    if (presetOf(name)) |p| return .{ .provider = p, .model = u.model, .url = if (p == .omnigate) u.url else "" };
    return .{
        .provider = .other,
        .model = u.model,
        .url = u.section_url,
        .api = if (std.mem.eql(u8, u.api, "anthropic")) .anthropic else .openai,
    };
}

/// The `[provider NAME]` Other is written to: the one in use when it is of
/// one's own, else "other".
pub fn sectionOf(before: ?InUse) []const u8 {
    const u = before orelse return "other";
    if (u.provider.len == 0 or presetOf(u.provider) != null) return "other";
    return u.provider;
}

/// harness's name for the form's provider.
fn nameOf(f: Form, before: ?InUse) []const u8 {
    return if (f.provider == .other) sectionOf(before) else entry(f.provider).name;
}

/// What's wrong with the form, as the line under it; null: nothing.
pub fn problem(f: Form) ?[]const u8 {
    if (trim(f.model).len == 0) return "Model is empty.";
    if (entry(f.provider).address) {
        const u = trim(f.url);
        if (u.len == 0) return "Address is empty.";
        // as harness reads it (model.validUrl): lower case
        if (!std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://")) return "Address must start with http:// or https://.";
    }
    return null;
}

/// An address that starts http:// and isn't this computer: what goes to it,
/// the key included, crosses the network unencrypted. The "Set up" page
/// says so under the Address field (its script holds the same rule).
pub fn plainRemote(url: []const u8) bool {
    const u = trim(url);
    if (!std.mem.startsWith(u8, u, "http://")) return false;
    var h = u["http://".len..];
    if (std.mem.indexOfAny(u8, h, "/?#")) |i| h = h[0..i];
    if (std.mem.lastIndexOfScalar(u8, h, '@')) |i| h = h[i + 1 ..];
    if (h.len > 0 and h[0] == '[') {
        h = h[0 .. (std.mem.indexOfScalar(u8, h, ']') orelse h.len - 1) + 1];
    } else if (std.mem.indexOfScalar(u8, h, ':')) |i| h = h[0..i];
    if (h.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(h, "localhost") or std.ascii.endsWithIgnoreCase(h, ".localhost") or std.mem.eql(u8, h, "[::1]")) return false;
    // 127.0.0.0/8
    var parts = std.mem.splitScalar(u8, h, '.');
    var n: usize = 0;
    var loop = true;
    while (parts.next()) |part| : (n += 1) {
        if (n == 0 and !std.mem.eql(u8, part, "127")) loop = false;
        if (part.len == 0) loop = false;
        for (part) |c| if (!std.ascii.isDigit(c)) {
            loop = false;
        };
    }
    return !(loop and n == 4);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// `harness init`.
pub fn initArgv(a: std.mem.Allocator, binary: []const u8, home: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{ binary, "init", "--home", home });
}

/// `harness config set` with every pair in one call (written together, or
/// none is): the provider, the model, the address. `memory_model` and
/// `worker_model` follow at the first setup and when the provider changes
/// (the old ones were the old provider's); otherwise they stay as the
/// owner left them. `before`: the values in use ("Provider and key…").
/// For Other, `key` sets how the key is sent: `none` writes `auth = none`;
/// a key `given` where `none` was in use writes the format's own way back.
pub fn configArgv(a: std.mem.Allocator, binary: []const u8, home: []const u8, f: Form, before: ?InUse, key: KeyChoice) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(a, &.{ binary, "config", "set" });
    const name = nameOf(f, before);
    const model = trim(f.model);
    if (f.provider == .other) {
        try out.appendSlice(a, &.{
            try std.fmt.allocPrint(a, "provider {s}.api", .{name}), @tagName(f.api),
            try std.fmt.allocPrint(a, "provider {s}.url", .{name}), trim(f.url),
        });
        const was_none = if (before) |u| std.mem.eql(u8, u.provider, name) and std.mem.eql(u8, u.auth, "none") else false;
        const auth: ?[]const u8 = switch (key) {
            .none => "none",
            .given => if (was_none) (if (f.api == .anthropic) "x-api-key" else "bearer") else null,
            .keep => null,
        };
        if (auth) |v| try out.appendSlice(a, &.{ try std.fmt.allocPrint(a, "provider {s}.auth", .{name}), v });
    }
    try out.appendSlice(a, &.{ "model.provider", name, "model.model", model });
    if (f.provider == .omnigate) try out.appendSlice(a, &.{ "model.url", trim(f.url) });
    const same = if (before) |u| std.mem.eql(u8, if (u.provider.len == 0) "omnigate" else u.provider, name) else false;
    if (!same) {
        const helper = entry(f.provider).helper orelse model;
        try out.appendSlice(a, &.{ "model.memory_model", helper, "model.worker_model", helper });
    }
    try out.appendSlice(a, &.{ "--home", home });
    return out.toOwnedSlice(a);
}

/// The stored secret the provider's key goes under: the one config.ini
/// names for the provider in use (omnigate: `[model] key`; another:
/// its section's `key`), else harness's default, the provider's name.
pub fn keyName(f: Form, before: ?InUse) []const u8 {
    const name = nameOf(f, before);
    if (before) |u| {
        const in_use = if (u.provider.len == 0) "omnigate" else u.provider;
        if (f.provider == .omnigate) {
            if (u.model_key.len > 0) return u.model_key;
        } else if (std.mem.eql(u8, in_use, name) and u.section_key.len > 0) return u.section_key;
    }
    return name;
}

/// `harness secret add NAME --stdin`: the key comes on its input.
pub fn secretArgv(a: std.mem.Allocator, binary: []const u8, home: []const u8, name: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{ binary, "secret", "add", name, "--stdin", "--home", home });
}

/// `harness config get KEY`.
pub fn readArgv(a: std.mem.Allocator, binary: []const u8, home: []const u8, key: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{ binary, "config", "get", key, "--home", home });
}

/// What "Provider and key…" reads with `harness config get`, after
/// `model.provider` said `provider`: in `inUse`'s order.
pub fn readKeys(a: std.mem.Allocator, provider: []const u8) ![7][]const u8 {
    return .{
        "model.model",
        "model.url",
        "model.key",
        try std.fmt.allocPrint(a, "provider {s}.api", .{provider}),
        try std.fmt.allocPrint(a, "provider {s}.url", .{provider}),
        try std.fmt.allocPrint(a, "provider {s}.key", .{provider}),
        try std.fmt.allocPrint(a, "provider {s}.auth", .{provider}),
    };
}

/// The values in use from `readKeys`' answers.
pub fn inUse(provider: []const u8, values: [7][]const u8) InUse {
    return .{
        .provider = provider,
        .model = values[0],
        .url = values[1],
        .model_key = values[2],
        .api = values[3],
        .section_url = values[4],
        .section_key = values[5],
        .auth = values[6],
    };
}

/// The harness the app carries: beside its own program, on every system
/// (macOS: `harness-desk.app/Contents/MacOS/harness`; Windows:
/// `harness.exe` beside `harness-desk.exe`; Linux: `harness` beside
/// `harness-desk`).
pub fn beside(a: std.mem.Allocator, exe_dir: []const u8, windows: bool) ![]const u8 {
    const dir = std.mem.trimEnd(u8, exe_dir, if (windows) "\\/" else "/");
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ dir, if (windows) "\\" else "/", if (windows) "harness.exe" else "harness" });
}

const t = std.testing;

fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("want {d} words, got {d}:\n", .{ want.len, got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return error.TestExpectedEqual;
    }
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

test "provider_table_matches_harness" {
    // the order and labels the screen shows
    const labels = [_][]const u8{ "Anthropic", "OpenAI", "OpenRouter", "opencode", "omnigate", "Other" };
    try t.expectEqual(labels.len, entries.len);
    for (labels, entries, 0..) |l, e, i| {
        try t.expectEqualStrings(l, e.label);
        try t.expectEqual(@as(Provider, @fromBackingInt(@intCast(i))), e.id);
    }
    // harness's names (model.zig's presets)
    try t.expectEqualStrings("anthropic", entry(.anthropic).name);
    try t.expectEqualStrings("openai", entry(.openai).name);
    try t.expectEqualStrings("openrouter", entry(.openrouter).name);
    try t.expectEqualStrings("opencode", entry(.opencode).name);
    try t.expectEqualStrings("omnigate", entry(.omnigate).name);
    try t.expectEqualStrings("", entry(.other).name);
    // the usual models, as harness's own code and README use them
    try t.expectEqualStrings("claude-sonnet", entry(.omnigate).model);
    try t.expectEqualStrings("claude-haiku", entry(.omnigate).helper.?);
    try t.expectEqualStrings("claude-opus-4-8", entry(.anthropic).model);
    try t.expectEqualStrings("claude-haiku-4-5", entry(.anthropic).helper.?);
    try t.expectEqualStrings("gpt-5", entry(.openai).model);
    try t.expectEqualStrings("anthropic/claude-sonnet-4", entry(.openrouter).model);
    // none named for these: the owner types it
    try t.expectEqualStrings("", entry(.opencode).model);
    try t.expectEqualStrings("", entry(.other).model);
    // an address for omnigate and Other only
    for (entries) |e| try t.expectEqual(e.id == .omnigate or e.id == .other, e.address);
}

test "config_argv_per_provider" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectArgv(&.{
        "/b/harness",       "config",          "set",                "model.provider",   "anthropic",
        "model.model",      "claude-opus-4-8", "model.memory_model", "claude-haiku-4-5", "model.worker_model",
        "claude-haiku-4-5", "--home",          "/h",
    }, try configArgv(a, "/b/harness", "/h", .{ .provider = .anthropic, .model = "claude-opus-4-8" }, null, .keep));
    try expectArgv(&.{
        "/b/harness",  "config", "set",                "model.provider", "openai",
        "model.model", "gpt-5",  "model.memory_model", "gpt-5",          "model.worker_model",
        "gpt-5",       "--home", "/h",
    }, try configArgv(a, "/b/harness", "/h", .{ .provider = .openai, .model = "gpt-5" }, null, .keep));
    try expectArgv(&.{
        "/b/harness",   "config",             "set",          "model.provider",         "omnigate",
        "model.model",  "claude-sonnet",      "model.url",    "https://og.example.com", "model.memory_model",
        "claude-haiku", "model.worker_model", "claude-haiku", "--home",                 "/h",
    }, try configArgv(a, "/b/harness", "/h", .{ .provider = .omnigate, .model = "claude-sonnet", .url = "https://og.example.com" }, null, .keep));
    // an address of one's own: its section's format and address, in the same call
    try expectArgv(&.{
        "/b/harness",         "config",                   "set",            "provider other.api", "anthropic",
        "provider other.url", "http://127.0.0.1:8080/v1", "model.provider", "other",              "model.model",
        "m1",                 "model.memory_model",       "m1",             "model.worker_model", "m1",
        "--home",             "/h",
    }, try configArgv(a, "/b/harness", "/h", .{ .provider = .other, .model = "m1", .url = "http://127.0.0.1:8080/v1", .api = .anthropic }, null, .keep));
    // values are trimmed
    const trimmed = try configArgv(a, "/b/harness", "/h", .{ .provider = .openai, .model = "  gpt-5 \t" }, null, .keep);
    try t.expectEqualStrings("gpt-5", trimmed[6]);
}

test "helpers_follow_only_on_first_setup_or_a_new_provider" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before: InUse = .{ .provider = "openai", .model = "gpt-5" };
    // the same provider, another model: the helpers the owner may have tuned stay
    try expectArgv(&.{ "/b/harness", "config", "set", "model.provider", "openai", "model.model", "gpt-5-mini", "--home", "/h" }, try configArgv(a, "/b/harness", "/h", .{ .provider = .openai, .model = "gpt-5-mini" }, before, .keep));
    // another provider: they follow, since the old ones were the old provider's
    const moved = try configArgv(a, "/b/harness", "/h", .{ .provider = .anthropic, .model = "claude-opus-4-8" }, before, .keep);
    try t.expectEqualStrings("model.memory_model", moved[7]);
    try t.expectEqualStrings("claude-haiku-4-5", moved[8]);
    // a section of one's own named as before: the same provider
    const own: InUse = .{ .provider = "local", .model = "llama3.1:8b", .api = "openai", .section_url = "http://127.0.0.1:11434/v1" };
    const same = try configArgv(a, "/b/harness", "/h", .{ .provider = .other, .model = "qwen", .url = "http://127.0.0.1:11434/v1" }, own, .keep);
    try expectArgv(&.{ "/b/harness", "config", "set", "provider local.api", "openai", "provider local.url", "http://127.0.0.1:11434/v1", "model.provider", "local", "model.model", "qwen", "--home", "/h" }, same);
}

test "key_name_per_provider" {
    // first setup: harness's defaults
    try t.expectEqualStrings("anthropic", keyName(.{ .provider = .anthropic }, null));
    try t.expectEqualStrings("openrouter", keyName(.{ .provider = .openrouter }, null));
    try t.expectEqualStrings("opencode", keyName(.{ .provider = .opencode }, null));
    try t.expectEqualStrings("openai", keyName(.{ .provider = .openai }, null));
    try t.expectEqualStrings("omnigate", keyName(.{ .provider = .omnigate }, null));
    try t.expectEqualStrings("other", keyName(.{ .provider = .other }, null));
    // later: the secret config.ini names
    try t.expectEqualStrings("og-work", keyName(.{ .provider = .omnigate }, .{ .provider = "anthropic", .model_key = "og-work" }));
    try t.expectEqualStrings("my-anthropic", keyName(.{ .provider = .anthropic }, .{ .provider = "anthropic", .section_key = "my-anthropic" }));
    // a section key belongs to the provider in use, not to another one
    try t.expectEqualStrings("openai", keyName(.{ .provider = .openai }, .{ .provider = "anthropic", .section_key = "my-anthropic" }));
    try t.expectEqualStrings("local", keyName(.{ .provider = .other }, .{ .provider = "local", .api = "openai" }));
    try t.expectEqualStrings("lan-key", keyName(.{ .provider = .other }, .{ .provider = "local", .api = "openai", .section_key = "lan-key" }));
}

test "problems_name_the_field" {
    try t.expectEqualStrings("Model is empty.", problem(.{ .provider = .opencode, .model = "  " }).?);
    try t.expectEqualStrings("Address is empty.", problem(.{ .provider = .omnigate, .model = "claude-sonnet" }).?);
    try t.expectEqualStrings("Address must start with http:// or https://.", problem(.{ .provider = .other, .model = "m", .url = "127.0.0.1:8080" }).?);
    try t.expect(problem(.{ .provider = .other, .model = "m", .url = " https://gw.example.com/v1 " }) == null);
    // an address is ignored where none is taken
    try t.expect(problem(.{ .provider = .anthropic, .model = "claude-opus-4-8", .url = "junk" }) == null);
}

test "a_hand_made_section_reads_as_other_and_saves_to_it" {
    const own: InUse = .{ .provider = "local", .model = "llama3.1:8b", .api = "anthropic", .section_url = "http://127.0.0.1:11434/v1", .url = "" };
    const f = formOf(own);
    try t.expectEqual(Provider.other, f.provider);
    try t.expectEqual(Api.anthropic, f.api);
    try t.expectEqualStrings("http://127.0.0.1:11434/v1", f.url);
    try t.expectEqualStrings("llama3.1:8b", f.model);
    try t.expectEqualStrings("local", sectionOf(own));
    try t.expectEqualStrings("other", sectionOf(null));
    try t.expectEqualStrings("other", sectionOf(.{ .provider = "anthropic" }));
    // a preset reads as itself; omnigate's address is [model] url
    const og = formOf(.{ .provider = "omnigate", .model = "claude-sonnet", .url = "https://og.example.com" });
    try t.expectEqual(Provider.omnigate, og.provider);
    try t.expectEqualStrings("https://og.example.com", og.url);
    try t.expectEqual(Provider.openrouter, formOf(.{ .provider = "openrouter", .model = "x/y" }).provider);
    // no provider printed: harness's default
    try t.expectEqual(Provider.omnigate, formOf(.{}).provider);
}

test "values_are_single_argv_words" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try configArgv(a, "/b/harness", "/h", .{ .provider = .other, .model = "a b \"c\" ; d", .url = "https://x.example/v1?a=1&b=2" }, null, .keep);
    var seen_model = false;
    for (got) |w| if (std.mem.eql(u8, w, "a b \"c\" ; d")) {
        seen_model = true;
    };
    try t.expect(seen_model);
    try expectArgv(&.{ "/b/harness", "init", "--home", "/h" }, try initArgv(a, "/b/harness", "/h"));
    try expectArgv(&.{ "/b/harness", "secret", "add", "anthropic", "--stdin", "--home", "/h" }, try secretArgv(a, "/b/harness", "/h", "anthropic"));
    try expectArgv(&.{ "/b/harness", "config", "get", "provider local.url", "--home", "/h" }, try readArgv(a, "/b/harness", "/h", "provider local.url"));
}

test "provider_and_key_reads_these_settings" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const keys = try readKeys(arena.allocator(), "local");
    try expectArgv(&.{ "model.model", "model.url", "model.key", "provider local.api", "provider local.url", "provider local.key", "provider local.auth" }, &keys);
    const u = inUse("local", .{ "llama3.1:8b", "", "omnigate", "openai", "http://127.0.0.1:11434/v1", "", "none" });
    try t.expectEqualStrings("none", u.auth);
    try t.expectEqualStrings("local", u.provider);
    try t.expectEqualStrings("llama3.1:8b", u.model);
    try t.expectEqualStrings("omnigate", u.model_key);
    try t.expectEqualStrings("openai", u.api);
    try t.expectEqualStrings("http://127.0.0.1:11434/v1", u.section_url);
    try t.expectEqualStrings("", u.section_key);
}

test "harness_sits_beside_the_apps_program" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/Applications/harness-desk.app/Contents/MacOS/harness", try beside(a, "/Applications/harness-desk.app/Contents/MacOS", false));
    try t.expectEqualStrings("/opt/harness/harness", try beside(a, "/opt/harness/", false));
    try t.expectEqualStrings("C:\\Program Files\\harness\\harness.exe", try beside(a, "C:\\Program Files\\harness", true));
}

test "other_without_a_key_takes_none_and_a_new_key_takes_it_back" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f: Form = .{ .provider = .other, .model = "llama3.1:8b", .url = "http://127.0.0.1:11434/v1" };
    const none = try configArgv(a, "/b/harness", "/h", f, null, .none);
    try t.expectEqualStrings("provider other.auth", none[7]);
    try t.expectEqualStrings("none", none[8]);
    // a key now, where none was taken: the format's own way of sending it
    const was: InUse = .{ .provider = "other", .model = "m", .api = "anthropic", .section_url = "http://x/v1", .auth = "none" };
    const given = try configArgv(a, "/b/harness", "/h", .{ .provider = .other, .model = "m", .url = "http://x/v1", .api = .anthropic }, was, .given);
    try t.expectEqualStrings("provider other.auth", given[7]);
    try t.expectEqualStrings("x-api-key", given[8]);
    // a way of sending it set by hand stays
    var hand = was;
    hand.auth = "bearer";
    const kept = try configArgv(a, "/b/harness", "/h", .{ .provider = .other, .model = "m", .url = "http://x/v1", .api = .anthropic }, hand, .given);
    for (kept) |w| try t.expect(!std.mem.endsWith(u8, w, ".auth"));
    // presets never get an auth line
    for (try configArgv(a, "/b/harness", "/h", .{ .provider = .openai, .model = "gpt-5" }, null, .given)) |w| try t.expect(!std.mem.endsWith(u8, w, ".auth"));
    try t.expect(keyOptional(.other) and !keyOptional(.anthropic) and !keyOptional(.omnigate));
}

test "the_address_is_checked_as_harness_checks_it" {
    // harness takes http:// and https:// as written, lower case
    try t.expectEqualStrings("Address must start with http:// or https://.", problem(.{ .provider = .other, .model = "m", .url = "HTTPS://gw.example.com/v1" }).?);
}

test "a_key_loses_the_spaces_around_it" {
    try t.expectEqualStrings("sk-abc", trimKey(" sk-abc \r\n"));
    try t.expectEqualStrings("sk a", trimKey("\tsk a\n"));
    try t.expectEqualStrings("", trimKey(" \n"));
}

test "a_plain_address_that_is_not_this_computer_is_told_apart" {
    for ([_][]const u8{
        "http://gateway.example.com/v1",
        "http://192.168.1.20:8080/v1",
        " http://10.0.0.2 ",
        "http://localhost.example.com/v1",
        "http://127.0.0.1.example.com",
        "http://127.0.0.1@gateway.example.com/v1",
        "http://[2001:db8::1]:8080/v1",
        "http://1270.0.0.1/v1",
    }) |u| try t.expect(plainRemote(u));
    for ([_][]const u8{
        "https://gateway.example.com/v1",
        "http://localhost:8080/v1",
        "http://LOCALHOST/v1",
        "http://app.localhost/v1",
        "http://127.0.0.1:9/v1",
        "http://127.8.9.10",
        "http://[::1]:8080/v1",
        "http://me@127.0.0.1:9/v1",
        "http://",
        "",
        "gateway.example.com",
    }) |u| try t.expect(!plainRemote(u));
}
