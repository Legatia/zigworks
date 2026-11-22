//! Who acts: what started a run (`by`), the definition doing a call
//! (`agent`) and the definitions that delegated it; and the patterns that
//! rules sections and grants match them with.
const std = @import("std");
const rules = @import("rules.zig");

/// Who makes a call: its definition, the definitions that delegated it
/// (through `parent`) and what started its run at the top of the chain.
pub const Who = struct {
    /// The definition doing the call: `main` or `helper` until gap 1.
    agent: []const u8 = "main",
    /// What started the run, the same down a delegation chain: `owner`,
    /// `schedule:NAME`, `trigger:NAME`, `workflow:NAME/STEP`, `app:NAME`.
    by: []const u8 = "owner",
    /// The run that delegated this one: its definition is the first that
    /// delegated, its parent's the next.
    parent: ?*const Who = null,

    /// A run nobody watches, so nobody can answer a question in it: one a
    /// schedule, a trigger or a workflow started. (A workflow's tool step
    /// is not a run and can wait in the inbox.)
    pub fn unattended(w: Who) bool {
        const k = kindOf(w.by);
        return eql(k, "schedule") or eql(k, "trigger") or eql(k, "workflow");
    }
};

/// The kinds of a who: what started a run, and `agent` for definitions.
const kinds = [_][]const u8{ "owner", "schedule", "trigger", "workflow", "app", "agent" };

/// What of a call's who a pattern matches: its definition, one of the
/// definitions that delegated it, or what started its run.
pub const Reach = struct { agent: bool = false, chain: bool = false, by: bool = false };

pub fn reach(pattern: []const u8, w: Who) Reach {
    if (!eql(kindOf(pattern), "agent")) return .{ .by = matchesBy(pattern, w.by) };
    // a call with no definition (a trigger's poll, an app's own act) is
    // no definition's: no agent: pattern reaches it
    if (w.agent.len == 0) return .{};
    var r: Reach = .{ .agent = matchesAgent(pattern, w.agent) };
    var p = w.parent;
    while (p) |x| : (p = x.parent) if (matchesAgent(pattern, x.agent)) {
        r.chain = true;
        break;
    };
    return r;
}

/// Whether an `agent:` pattern matches the definition `agent`.
pub fn matchesAgent(pattern: []const u8, agent: []const u8) bool {
    if (!eql(kindOf(pattern), "agent")) return false;
    const name = nameOf(pattern) orelse return true;
    return rules.glob(name, agent);
}

/// Whether a pattern matches what started a run: the same kind, then the
/// name as a glob (a kind alone covers every name; `workflow:NAME` covers
/// all of its steps). `agent:` patterns name definitions, never a `by`.
pub fn matchesBy(pattern: []const u8, by: []const u8) bool {
    const kind = kindOf(pattern);
    if (eql(kind, "agent") or !eql(kind, kindOf(by))) return false;
    const name = nameOf(pattern) orelse return true;
    const of = nameOf(by) orelse return false;
    if (eql(kind, "workflow") and std.mem.indexOfScalar(u8, name, '/') == null)
        return rules.glob(name, of[0 .. std.mem.indexOfScalar(u8, of, '/') orelse of.len]);
    return rules.glob(name, of);
}

/// `text` is a who pattern: a kind, or `KIND:NAME` with `*` as in rules.
pub fn isPattern(text: []const u8) bool {
    return check(text, true);
}

/// `text` is a who value, as a grant's `who` holds one: `owner` or
/// `KIND:NAME` (`workflow:NAME` or `workflow:NAME/STEP`), with no `*`.
pub fn isValue(text: []const u8) bool {
    return check(text, false);
}

fn check(text: []const u8, pattern: bool) bool {
    const kind = kindOf(text);
    for (kinds) |k| {
        if (eql(k, kind)) break;
    } else return false;
    // owner has no name; another kind alone is every name of it
    const name = nameOf(text) orelse return eql(kind, "owner") or pattern;
    if (eql(kind, "owner")) return false;
    if (eql(kind, "workflow")) if (std.mem.indexOfScalar(u8, name, '/')) |s|
        return nameOk(name[0..s], pattern) and nameOk(name[s + 1 ..], pattern);
    return nameOk(name, pattern);
}

/// A part's own name: never empty, a space or control character, `:`,
/// `/` or a bracket; `*` only in a pattern.
fn nameOk(name: []const u8, star: bool) bool {
    if (name.len == 0) return false;
    for (name) |c| switch (c) {
        0...0x20, 0x7f, ':', '/', '[', ']' => return false,
        '*' => if (!star) return false,
        else => {},
    };
    return true;
}

fn kindOf(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, ':') orelse text.len];
}

fn nameOf(text: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    return text[colon + 1 ..];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const t = std.testing;

test "who_patterns_match_by_and_definitions" {
    for ([_][2][]const u8{
        .{ "owner", "owner" },
        .{ "schedule", "schedule:btc-watch" },
        .{ "schedule:btc-*", "schedule:btc-watch" },
        .{ "workflow:release", "workflow:release/draft" },
        .{ "workflow:rel*", "workflow:release/draft" },
        .{ "workflow:release/draft", "workflow:release/draft" },
    }) |c| try t.expect(matchesBy(c[0], c[1]));
    for ([_][2][]const u8{
        .{ "owner", "schedule:x" },
        .{ "schedule:btc-*", "schedule:eth" },
        .{ "trigger:mail", "schedule:mail" },
        .{ "workflow:release/post", "workflow:release/draft" },
        .{ "workflow:rel", "workflow:release/draft" },
        // agent: patterns name definitions, never what started a run
        .{ "agent:main", "owner" },
    }) |c| try t.expect(!matchesBy(c[0], c[1]));
    try t.expect(matchesAgent("agent:main", "main"));
    try t.expect(matchesAgent("agent:*", "helper"));
    try t.expect(matchesAgent("agent", "coder"));
    try t.expect(!matchesAgent("owner", "main"));
    try t.expect(!matchesAgent("agent:coder", "main"));
}

test "a_pattern_reaches_the_definition_its_delegators_or_the_origin" {
    const m: Who = .{ .by = "schedule:x" };
    const h: Who = .{ .agent = "helper", .by = m.by, .parent = &m };
    try t.expectEqual(Reach{ .agent = true }, reach("agent:helper", h));
    try t.expectEqual(Reach{ .chain = true }, reach("agent:main", h));
    try t.expectEqual(Reach{ .agent = true, .chain = true }, reach("agent:*", h));
    try t.expectEqual(Reach{ .by = true }, reach("schedule:x", h));
    try t.expectEqual(Reach{}, reach("owner", h));
}

test "who_values_and_patterns_follow_the_name_rule" {
    for ([_][]const u8{ "owner", "schedule", "schedule:btc-*", "workflow:release/draft", "agent:*", "app:notes" }) |p|
        try t.expect(isPattern(p));
    for ([_][]const u8{ "owner:x", "nobody:x", "schedule:", "", "*", "schedule:a b", "schedule:a:b", "agent:a/b", "workflow:a/b/c", "workflow:/x", "trigger:a]" }) |p|
        try t.expect(!isPattern(p));
    for ([_][]const u8{ "owner", "schedule:btc-watch", "workflow:release", "workflow:release/draft", "agent:main" }) |v|
        try t.expect(isValue(v));
    for ([_][]const u8{ "", "schedule", "agent:*", "schedule:a b" }) |v|
        try t.expect(!isValue(v));
}

test "runs_nobody_watches" {
    for ([_][]const u8{ "schedule:x", "trigger:mail", "workflow:r/s", "schedule:weekly review" }) |by|
        try t.expect((Who{ .by = by }).unattended());
    for ([_][]const u8{ "owner", "app:notes" }) |by|
        try t.expect(!(Who{ .by = by }).unattended());
    // a task named as 0.3 allowed is still reached by the kind alone
    try t.expect(matchesBy("schedule", "schedule:weekly review"));
}

test "a_call_with_no_definition_matches_no_agent_pattern" {
    // a trigger's poll, an app's own act: no definition's
    const poll: Who = .{ .agent = "", .by = "trigger:btc" };
    try t.expectEqual(Reach{}, reach("agent:*", poll));
    try t.expectEqual(Reach{}, reach("agent", poll));
    try t.expectEqual(Reach{ .by = true }, reach("trigger:btc", poll));
    try t.expectEqual(Reach{ .by = true }, reach("trigger", poll));
}
