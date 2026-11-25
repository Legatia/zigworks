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
};

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
        if (!std.ascii.startsWithIgnoreCase(u, "http://") and !std.ascii.startsWithIgnoreCase(u, "https://")) return "Address must start with http:// or https://.";
    }
    return null;
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
pub fn configArgv(a: std.mem.Allocator, binary: []const u8, home: []const u8, f: Form, before: ?InUse) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(a, &.{ binary, "config", "set" });
    const name = nameOf(f, before);
    const model = trim(f.model);
    if (f.provider == .other) {
        try out.appendSlice(a, &.{
            try std.fmt.allocPrint(a, "provider {s}.api", .{name}), @tagName(f.api),
            try std.fmt.allocPrint(a, "provider {s}.url", .{name}), trim(f.url),
        });
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
    }, try configArgv(a, "/b/harness", "/h", .{ .provider = .anthropic, .model = "claude-opus-4-8" }, null));
    try expectArgv(&.{
        "/b/harness",  "config", "set",                "model.provider", "openai",
        "model.model", "gpt-5",  "model.memory_model", "gpt-5",          "model.worker_model",
        "gpt-5",       "--home", "/h",
    }, try configArgv(a, "/b/harness", "/h", .{ .provider = .openai, .model = "gpt-5" }, null));
    try expectArgv(&.{
        "/b/harness",   "config",             "set",          "model.provider",         "omnigate",
        "model.model",  "claude-sonnet",      "model.url",    "https://og.example.com", "model.memory_model",
        "claude-haiku", "model.worker_model", "claude-haiku", "--home",                 "/h",
    }, try configArgv(a, "/b/harness", "/h", .{ .provider = .omnigate, .model = "claude-sonnet", .url = "https://og.example.com" }, null));
    // an address of one's own: its section's format and address, in the same call
    try expectArgv(&.{
        "/b/harness",         "config",                   "set",            "provider other.api", "anthropic",
        "provider other.url", "http://127.0.0.1:8080/v1", "model.provider", "other",              "model.model",
        "m1",                 "model.memory_model",       "m1",             "model.worker_model", "m1",
        "--home",             "/h",
    }, try configArgv(a, "/b/harness", "/h", .{ .provider = .other, .model = "m1", .url = "http://127.0.0.1:8080/v1", .api = .anthropic }, null));
    // values are trimmed
    const trimmed = try configArgv(a, "/b/harness", "/h", .{ .provider = .openai, .model = "  gpt-5 \t" }, null);
    try t.expectEqualStrings("gpt-5", trimmed[6]);
}

test "helpers_follow_only_on_first_setup_or_a_new_provider" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before: InUse = .{ .provider = "openai", .model = "gpt-5" };
    // the same provider, another model: the helpers the owner may have tuned stay
    try expectArgv(&.{ "/b/harness", "config", "set", "model.provider", "openai", "model.model", "gpt-5-mini", "--home", "/h" }, try configArgv(a, "/b/harness", "/h", .{ .provider = .openai, .model = "gpt-5-mini" }, before));
    // another provider: they follow, since the old ones were the old provider's
    const moved = try configArgv(a, "/b/harness", "/h", .{ .provider = .anthropic, .model = "claude-opus-4-8" }, before);
    try t.expectEqualStrings("model.memory_model", moved[7]);
    try t.expectEqualStrings("claude-haiku-4-5", moved[8]);
    // a section of one's own named as before: the same provider
    const own: InUse = .{ .provider = "local", .model = "llama3.1:8b", .api = "openai", .section_url = "http://127.0.0.1:11434/v1" };
    const same = try configArgv(a, "/b/harness", "/h", .{ .provider = .other, .model = "qwen", .url = "http://127.0.0.1:11434/v1" }, own);
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
    const got = try configArgv(a, "/b/harness", "/h", .{ .provider = .other, .model = "a b \"c\" ; d", .url = "https://x.example/v1?a=1&b=2" }, null);
    var seen_model = false;
    for (got) |w| if (std.mem.eql(u8, w, "a b \"c\" ; d")) {
        seen_model = true;
    };
    try t.expect(seen_model);
    try expectArgv(&.{ "/b/harness", "init", "--home", "/h" }, try initArgv(a, "/b/harness", "/h"));
    try expectArgv(&.{ "/b/harness", "secret", "add", "anthropic", "--stdin", "--home", "/h" }, try secretArgv(a, "/b/harness", "/h", "anthropic"));
    try expectArgv(&.{ "/b/harness", "config", "get", "provider local.url", "--home", "/h" }, try readArgv(a, "/b/harness", "/h", "provider local.url"));
}
