//! The stand-in's part for the bill watch: made-up costs of one small
//! team at Anthropic, OpenAI and AWS, answered in the shapes of their
//! cost reports as documented (read 2026-11-27): pages, the amounts as
//! each writes them (cents in a string, a number, a string), and for AWS
//! a request whose signature is checked.
//!
//! What is in it, around the stand-in's day: at Anthropic one model that
//! ran away two days ago; at OpenAI a line that began a week ago; at AWS
//! a service that tripled a week ago. Everything else is the same every
//! day.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sim = @import("sim.zig");
const cloud = @import("cloud.zig");
const model = @import("model.zig");

pub const aws_id = "AKIASIMSIMSIMSIMSIM0";
const day_s: i64 = 86400;

pub fn handles(req: sim.Req) bool {
    const p = req.path;
    return std.mem.eql(u8, p, "/v1/organizations/cost_report") or std.mem.eql(u8, p, "/v1/organization/costs") or (std.mem.eql(u8, p, "/") and req.header("x-amz-target").len > 0);
}

fn res(a: Allocator, status: u16, comptime fmt: []const u8, args: anytype) !sim.Res {
    return .{ .status = status, .body = try std.fmt.allocPrint(a, fmt, args) };
}

pub fn handle(a: Allocator, key: []const u8, now: i64, req: sim.Req) !sim.Res {
    const today = @divFloor(now, day_s) * day_s;
    if (std.mem.eql(u8, req.path, "/v1/organizations/cost_report")) return anthropic(a, key, today, req);
    if (std.mem.eql(u8, req.path, "/v1/organization/costs")) return openai(a, key, today, req);
    return aws(a, key, today, req);
}

fn anthropic(a: Allocator, key: []const u8, today: i64, req: sim.Req) !sim.Res {
    if (!std.mem.eql(u8, req.header("x-api-key"), key)) return res(a, 401, "{{\"type\":\"error\",\"error\":{{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}}}", .{});
    if (!std.mem.eql(u8, req.method, "GET")) return res(a, 405, "{{\"type\":\"error\",\"error\":{{\"type\":\"invalid_request_error\",\"message\":\"Method Not Allowed\"}}}}", .{});
    if (req.header("anthropic-version").len == 0) return res(a, 400, "{{\"type\":\"error\",\"error\":{{\"type\":\"invalid_request_error\",\"message\":\"anthropic-version: header is required\"}}}}", .{});
    const from_text = try sim.param(a, req.query, "starting_at");
    const to_text = try sim.param(a, req.query, "ending_at");
    const from = model.dayStart(from_text[0..@min(from_text.len, 10)]) orelse return res(a, 400, "{{\"type\":\"error\",\"error\":{{\"type\":\"invalid_request_error\",\"message\":\"starting_at: required, an RFC 3339 time\"}}}}", .{});
    const to = model.dayStart(to_text[0..@min(to_text.len, 10)]) orelse today + day_s;
    const limit = std.fmt.parseInt(i64, try sim.param(a, req.query, "limit"), 10) catch 7;
    if (limit < 1 or limit > 31) return res(a, 400, "{{\"type\":\"error\",\"error\":{{\"type\":\"invalid_request_error\",\"message\":\"limit: 1 to 31\"}}}}", .{});
    const page = try sim.param(a, req.query, "page");
    const skip: i64 = if (std.mem.startsWith(u8, page, "page_")) std.fmt.parseInt(i64, page[5..], 10) catch 0 else 0;
    const detailed = std.mem.eql(u8, try sim.param(a, req.query, "group_by[]"), "description");
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "{\"data\":[");
    var n: i64 = 0;
    var day = from + skip * day_s;
    while (day < to and n < limit) : (day += day_s) {
        if (n > 0) try o.append(a, ',');
        n += 1;
        try o.print(a, "{{\"starting_at\":\"{s}T00:00:00Z\",\"ending_at\":\"{s}T00:00:00Z\",\"results\":[", .{ try model.day(a, day), try model.day(a, day + day_s) });
        // (today's bucket is there and still filling: half a day)
        const back = @divFloor(today - day, day_s);
        const part: f64 = if (back == 0) 0.5 else 1;
        const sonnet_out: f64 = if (back == 2) 8000 else 800;
        if (back >= 0 and detailed) {
            try o.print(a, "{{\"amount\":\"{d:.2}\",\"context_window\":\"0-200k\",\"cost_type\":\"tokens\",\"currency\":\"USD\",\"description\":\"Claude Sonnet 5.5 Usage - Input Tokens\",\"inference_geo\":\"global\",\"model\":\"claude-sonnet-5-5\",\"service_tier\":\"standard\",\"speed\":\"standard\",\"token_type\":\"uncached_input_tokens\",\"workspace_id\":null}}", .{400 * part});
            try o.print(a, ",{{\"amount\":\"{d:.2}\",\"context_window\":\"0-200k\",\"cost_type\":\"tokens\",\"currency\":\"USD\",\"description\":\"Claude Sonnet 5.5 Usage - Output Tokens\",\"inference_geo\":\"global\",\"model\":\"claude-sonnet-5-5\",\"service_tier\":\"standard\",\"speed\":\"standard\",\"token_type\":\"output_tokens\",\"workspace_id\":null}}", .{sonnet_out * part});
            try o.print(a, ",{{\"amount\":\"{d:.5}\",\"context_window\":\"0-200k\",\"cost_type\":\"tokens\",\"currency\":\"USD\",\"description\":\"Claude Haiku 5.5 Usage - Output Tokens\",\"inference_geo\":\"global\",\"model\":\"claude-haiku-5-5\",\"service_tier\":\"standard\",\"speed\":\"standard\",\"token_type\":\"output_tokens\",\"workspace_id\":null}}", .{100.5 * part});
            try o.print(a, ",{{\"amount\":\"{d:.2}\",\"context_window\":null,\"cost_type\":\"web_search\",\"currency\":\"USD\",\"description\":\"Web Search Usage\",\"inference_geo\":null,\"model\":null,\"service_tier\":null,\"speed\":null,\"token_type\":null,\"workspace_id\":null}}", .{20 * part});
        } else if (back >= 0) {
            try o.print(a, "{{\"amount\":\"{d:.5}\",\"context_window\":null,\"cost_type\":null,\"currency\":\"USD\",\"description\":null,\"inference_geo\":null,\"model\":null,\"service_tier\":null,\"speed\":null,\"token_type\":null,\"workspace_id\":null}}", .{(520.5 + sonnet_out) * part});
        }
        try o.appendSlice(a, "]}");
    }
    const more = day < to;
    try o.print(a, "],\"has_more\":{},\"next_page\":{s}}}", .{ more, if (more) try std.fmt.allocPrint(a, "\"page_{d}\"", .{skip + n}) else "null" });
    return .{ .status = 200, .body = o.items };
}

fn openai(a: Allocator, key: []const u8, today: i64, req: sim.Req) !sim.Res {
    if (!std.mem.startsWith(u8, req.auth, "Bearer ") or !std.mem.eql(u8, req.auth[7..], key)) return res(a, 401, "{{\"error\":{{\"message\":\"Incorrect API key provided.\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":\"invalid_api_key\"}}}}", .{});
    if (!std.mem.eql(u8, req.method, "GET")) return res(a, 405, "{{\"error\":{{\"message\":\"Not allowed.\",\"type\":\"invalid_request_error\"}}}}", .{});
    const from = std.fmt.parseInt(i64, try sim.param(a, req.query, "start_time"), 10) catch return res(a, 400, "{{\"error\":{{\"message\":\"Missing required parameter: 'start_time'.\",\"type\":\"invalid_request_error\"}}}}", .{});
    const to = std.fmt.parseInt(i64, try sim.param(a, req.query, "end_time"), 10) catch today + day_s;
    const limit = std.fmt.parseInt(i64, try sim.param(a, req.query, "limit"), 10) catch 7;
    if (limit < 1 or limit > 180) return res(a, 400, "{{\"error\":{{\"message\":\"Invalid 'limit': 1 to 180.\",\"type\":\"invalid_request_error\"}}}}", .{});
    const page = try sim.param(a, req.query, "page");
    const skip: i64 = if (std.mem.startsWith(u8, page, "page_")) std.fmt.parseInt(i64, page[5..], 10) catch 0 else 0;
    const by_line = std.mem.eql(u8, try sim.param(a, req.query, "group_by"), "line_item");
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "{\"object\":\"page\",\"data\":[");
    var n: i64 = 0;
    var day = @divFloor(from, day_s) * day_s + skip * day_s;
    while (day < to and n < limit) : (day += day_s) {
        if (n > 0) try o.append(a, ',');
        n += 1;
        const back = @divFloor(today - day, day_s);
        try o.print(a, "{{\"object\":\"bucket\",\"start_time\":{d},\"end_time\":{d},\"results\":[", .{ day, day + day_s });
        const new_line = back >= 1 and back <= 7;
        if (back >= 1 and by_line) {
            try o.appendSlice(a, "{\"object\":\"organization.costs.result\",\"amount\":{\"value\":3.0,\"currency\":\"usd\"},\"line_item\":\"gpt-5.1, input\",\"project_id\":null,\"api_key_id\":null,\"quantity\":1200000,\"quantity_unit\":\"tokens\"}");
            if (new_line) try o.appendSlice(a, ",{\"object\":\"organization.costs.result\",\"amount\":{\"value\":9.0,\"currency\":\"usd\"},\"line_item\":\"text-embedding-3-small\",\"project_id\":null,\"api_key_id\":null,\"quantity\":450000000,\"quantity_unit\":\"tokens\"}");
        } else if (back >= 1) {
            try o.print(a, "{{\"object\":\"organization.costs.result\",\"amount\":{{\"value\":{d:.1},\"currency\":\"usd\"}},\"line_item\":null,\"project_id\":null,\"api_key_id\":null,\"quantity\":null,\"quantity_unit\":null}}", .{@as(f64, if (new_line) 12 else 3)});
        }
        try o.appendSlice(a, "]}");
    }
    const more = day < to;
    try o.print(a, "],\"has_more\":{},\"next_page\":{s}}}", .{ more, if (more) try std.fmt.allocPrint(a, "\"page_{d}\"", .{skip + n}) else "null" });
    return .{ .status = 200, .body = o.items };
}

fn field(text: []const u8, name: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, text, name) orelse return "";
    const rest = text[at + name.len ..];
    return rest[0 .. std.mem.indexOfAny(u8, rest, ", ") orelse rest.len];
}

fn aws(a: Allocator, secret: []const u8, today: i64, req: sim.Req) !sim.Res {
    if (!std.mem.eql(u8, req.method, "POST")) return res(a, 405, "{{\"__type\":\"MethodNotAllowed\",\"message\":\"POST only\"}}", .{});
    if (!std.mem.eql(u8, req.header("x-amz-target"), cloud.aws_target)) return res(a, 400, "{{\"__type\":\"UnknownOperationException\",\"message\":\"The stand-in answers GetCostAndUsage only.\"}}", .{});
    // the signature, worked out again from what arrived
    const auth = req.auth;
    const credential = field(auth, "Credential=");
    var scope = std.mem.splitScalar(u8, credential, '/');
    const id = scope.next() orelse "";
    _ = scope.next();
    const region = scope.next() orelse "";
    const service = scope.next() orelse "";
    if (!std.mem.eql(u8, id, aws_id)) return res(a, 400, "{{\"__type\":\"UnrecognizedClientException\",\"message\":\"The security token included in the request is invalid.\"}}", .{});
    var signed: std.ArrayList([2][]const u8) = .empty;
    var names = std.mem.splitScalar(u8, field(auth, "SignedHeaders="), ';');
    while (names.next()) |name| try signed.append(a, .{ name, req.header(name) });
    const again = try cloud.sigv4(a, .{ .method = "POST", .path = "/", .headers = signed.items, .payload = req.body, .stamp = req.header("x-amz-date"), .region = region, .service = service, .id = id, .secret = secret });
    if (!std.mem.eql(u8, again, auth) or !std.mem.eql(u8, service, "ce") or !std.mem.eql(u8, region, "us-east-1") or req.header("host").len == 0)
        return res(a, 403, "{{\"__type\":\"InvalidSignatureException\",\"message\":\"The request signature we calculated does not match the signature you provided.\"}}", .{});
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, req.body, .{}) catch return res(a, 400, "{{\"__type\":\"SerializationException\",\"message\":\"the body isn't JSON\"}}", .{});
    const jv = @import("jv.zig");
    const from = model.dayStart(jv.str(jv.at(v, &.{ "TimePeriod", "Start" })) orelse "") orelse return res(a, 400, "{{\"__type\":\"ValidationException\",\"message\":\"TimePeriod.Start is required\"}}", .{});
    const to = model.dayStart(jv.str(jv.at(v, &.{ "TimePeriod", "End" })) orelse "") orelse return res(a, 400, "{{\"__type\":\"ValidationException\",\"message\":\"TimePeriod.End is required\"}}", .{});
    if (!std.mem.eql(u8, jv.str(jv.get(v, "Granularity")) orelse "", "DAILY")) return res(a, 400, "{{\"__type\":\"ValidationException\",\"message\":\"The stand-in answers DAILY only.\"}}", .{});
    // two pages when the range is long: the first twenty days, then the rest
    const second = std.mem.eql(u8, jv.str(jv.get(v, "NextPageToken")) orelse "", "page2");
    const cut = from + 20 * day_s;
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "{\"GroupDefinitions\":[{\"Key\":\"SERVICE\",\"Type\":\"DIMENSION\"}],\"ResultsByTime\":[");
    var day = if (second) cut else from;
    const end = if (!second and to > cut) cut else to;
    var n: usize = 0;
    while (day < end) : (day += day_s) {
        if (n > 0) try o.append(a, ',');
        n += 1;
        const back = @divFloor(today - day, day_s);
        const ec2: []const u8 = if (back >= 1 and back <= 7) "60.0000000000" else "20.0000000000";
        try o.print(a, "{{\"Estimated\":{},\"Groups\":[{{\"Keys\":[\"Amazon Elastic Compute Cloud - Compute\"],\"Metrics\":{{\"UnblendedCost\":{{\"Amount\":\"{s}\",\"Unit\":\"USD\"}}}}}},{{\"Keys\":[\"Amazon Simple Storage Service\"],\"Metrics\":{{\"UnblendedCost\":{{\"Amount\":\"2.3456000000\",\"Unit\":\"USD\"}}}}}},{{\"Keys\":[\"Tax\"],\"Metrics\":{{\"UnblendedCost\":{{\"Amount\":\"0\",\"Unit\":\"USD\"}}}}}}],\"TimePeriod\":{{\"Start\":\"{s}\",\"End\":\"{s}\"}},\"Total\":{{}}}}", .{ back < 3, ec2, try model.day(a, day), try model.day(a, day + day_s) });
    }
    try o.print(a, "]{s}}}", .{if (!second and to > cut) ",\"NextPageToken\":\"page2\"" else ""});
    return .{ .status = 200, .body = o.items };
}
