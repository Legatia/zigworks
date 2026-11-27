//! The stand-in's part for Poland's list of VAT payers: the one question
//! paymcp asks it (is this account registered to this tax number?), with
//! the answers and the refusals of the service's documentation (version
//! 1.6.2, read 2026-11-27). No key, as there.
//!
//! Three accounts are registered here, each to one tax number; any other
//! pair is not. Tax number 1111111112 is called invalid, and 9999999999
//! meets the day's limit.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sim = @import("sim.zig");
const model = @import("model.zig");

const prefix = "/api/check/nip/";
const middle = "/bank-account/";

const registered = [_][2][]const u8{
    .{ "3245174504", "61109010140000071219812874" },
    .{ "1854510877", "27114020040000300201355387" },
    .{ "2051545495", "83102010260000040270001111" },
};

pub fn handles(req: sim.Req) bool {
    return std.mem.startsWith(u8, req.path, prefix);
}

fn refuse(a: Allocator, status: u16, code: []const u8, message: []const u8) !sim.Res {
    return .{ .status = status, .body = try std.fmt.allocPrint(a, "{{\"message\":{f},\"code\":\"{s}\"}}", .{ std.json.fmt(message, .{}), code }) };
}

fn allDigits(v: []const u8) bool {
    for (v) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

pub fn handle(a: Allocator, req: sim.Req) !sim.Res {
    if (!std.mem.eql(u8, req.method, "GET")) return refuse(a, 400, "WL-190", "Niepoprawne żądanie.");
    const rest = req.path[prefix.len..];
    const cut = std.mem.indexOf(u8, rest, middle) orelse return refuse(a, 400, "WL-190", "Niepoprawne żądanie.");
    const nip = rest[0..cut];
    const account = rest[cut + middle.len ..];
    const date = try sim.param(a, req.query, "date");
    if (date.len == 0) return refuse(a, 400, "WL-101", "Pole 'data' nie może być puste.");
    if (model.dayStart(date) == null) return refuse(a, 400, "WL-102", "Pole 'data' ma nieprawidłowy format.");
    if (nip.len != 10) return refuse(a, 400, "WL-113", "Pole 'NIP' ma nieprawidłową długość. Wymagane 10 znaków.");
    if (!allDigits(nip)) return refuse(a, 400, "WL-114", "Pole 'NIP' zawiera niedozwolone znaki. Wymagane tylko cyfry.");
    if (account.len != 26) return refuse(a, 400, "WL-109", "Pole 'numer konta' ma nieprawidłową długość. Wymagane 26 znaków.");
    if (!allDigits(account)) return refuse(a, 400, "WL-110", "Pole 'numer konta' zawiera niedozwolone znaki. Wymagane tylko cyfry.");
    if (std.mem.eql(u8, nip, "1111111112")) return refuse(a, 400, "WL-115", "Nieprawidłowy NIP.");
    if (std.mem.eql(u8, nip, "9999999999")) return refuse(a, 429, "WL-191", "Limit dzienny wyczerpany.");
    const yes = for (registered) |r| {
        if (std.mem.eql(u8, r[0], nip) and std.mem.eql(u8, r[1], account)) break true;
    } else false;
    return .{ .status = 200, .body = try std.fmt.allocPrint(a, "{{\"result\":{{\"accountAssigned\":\"{s}\",\"requestDateTime\":\"{s}-{s}-{s} 12:00:00\",\"requestId\":\"{s}-{s}\"}}}}", .{ if (yes) "TAK" else "NIE", date[8..10], date[5..7], date[0..4], nip[0..5], account[19..26] }) };
}
