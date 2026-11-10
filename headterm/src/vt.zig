//! VT/xterm emulator: escape-sequence parser plus screen model. No I/O.
//!
//! The parser follows Paul Williams' DEC-compatible state machine
//! (https://vt100.net/emu/dec_ansi_parser), with UTF-8 decoding in the
//! ground state instead of 8-bit C1 controls, and ':' accepted as a
//! sub-parameter separator (for SGR 38:2:r:g:b and friends).
//!
//! Anything the terminal would send back to the program (cursor position
//! reports, device attributes) is appended to `reply`; the caller drains it
//! and writes it to the PTY.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const default_scrollback = 2000;
const max_params = 32;
const max_osc_len = 4096;
const max_title_len = 1024;

pub const Cell = struct {
    cp: u21 = ' ',
    /// 1 for normal cells, 2 for the left half of a wide character,
    /// 0 for the right half (a spacer that renders as nothing).
    width: u2 = 1,
    style: Style = .{},
};

const blank: Cell = .{};

pub const Color = union(enum) {
    default,
    palette: u8,
    rgb: [3]u8,
};

/// SGR attributes, stored per cell.
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    underline_color: Color = .default,
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    /// 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed
    underline: u3 = 0,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
};

const Charset = enum { ascii, dec_special };

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
    /// Set after printing into the last column: the next printable
    /// character wraps first (xterm's "do_wrap").
    pending_wrap: bool = false,
    style: Style = .{},
    origin: bool = false,
    g: [2]Charset = .{ .ascii, .ascii },
    gl: u1 = 0,
};

pub const Modes = struct {
    app_cursor: bool = false, // DECCKM (?1)
    app_keypad: bool = false, // DECKPAM
    autowrap: bool = true, // DECAWM (?7)
    cursor_visible: bool = true, // DECTCEM (?25)
    insert: bool = false, // IRM (4)
    bracketed_paste: bool = false, // ?2004
    focus_events: bool = false, // ?1004
    /// Last mouse tracking mode enabled (9, 1000, 1002, 1003) or 0.
    mouse_tracking: u16 = 0,
    mouse_sgr: bool = false, // ?1006
};

const Row = struct {
    cells: []Cell,
    /// Text ran past the right edge and continues on the next row
    /// (autowrap), so the two rows form one logical line.
    wrapped: bool = false,

    fn fill(row: *Row, cell: Cell) void {
        @memset(row.cells, cell);
        row.wrapped = false;
    }
};

const Grid = struct {
    /// Rotated, not copied, when the screen scrolls.
    rows: []Row,
    /// DECSC slot. Each buffer has its own, as in xterm.
    saved: Cursor = .{},

    fn init(gpa: Allocator, cols: usize, nrows: usize) !Grid {
        const rows = try gpa.alloc(Row, nrows);
        var done: usize = 0;
        errdefer {
            for (rows[0..done]) |r| gpa.free(r.cells);
            gpa.free(rows);
        }
        for (rows) |*r| {
            r.* = .{ .cells = try gpa.alloc(Cell, cols) };
            @memset(r.cells, blank);
            done += 1;
        }
        return .{ .rows = rows };
    }

    fn deinit(self: *Grid, gpa: Allocator) void {
        for (self.rows) |r| gpa.free(r.cells);
        gpa.free(self.rows);
    }

    fn clear(self: *Grid) void {
        for (self.rows) |*r| r.fill(blank);
    }
};

/// Bounded ring of rendered (UTF-8, right-trimmed) lines that scrolled off
/// the top of the main screen.
pub const Scrollback = struct {
    lines: [][]u8,
    start: usize = 0,
    len: usize = 0,

    fn init(gpa: Allocator, max: usize) !Scrollback {
        return .{ .lines = try gpa.alloc([]u8, max) };
    }

    fn deinit(self: *Scrollback, gpa: Allocator) void {
        self.clear(gpa);
        gpa.free(self.lines);
    }

    fn clear(self: *Scrollback, gpa: Allocator) void {
        for (0..self.len) |i| gpa.free(self.lines[(self.start + i) % self.lines.len]);
        self.start = 0;
        self.len = 0;
    }

    fn push(self: *Scrollback, gpa: Allocator, line: []u8) void {
        if (self.lines.len == 0) {
            gpa.free(line);
            return;
        }
        if (self.len == self.lines.len) {
            gpa.free(self.lines[self.start]);
            self.lines[self.start] = line;
            self.start = (self.start + 1) % self.lines.len;
        } else {
            self.lines[(self.start + self.len) % self.lines.len] = line;
            self.len += 1;
        }
    }

    /// Line `i`, where 0 is the oldest kept line.
    pub fn get(self: *const Scrollback, i: usize) []const u8 {
        return self.lines[(self.start + i) % self.lines.len];
    }
};

const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    dcs_entry,
    dcs_passthrough,
    osc_string,
    sos_pm_apc_string,
};

pub const Options = struct {
    cols: usize = 80,
    rows: usize = 24,
    scrollback: usize = default_scrollback,
};

pub const Terminal = struct {
    gpa: Allocator,
    cols: usize,
    rows: usize,
    main: Grid,
    alt: Grid,
    alt_active: bool = false,
    cursor: Cursor = .{},
    /// Scroll region (DECSTBM), inclusive, 0-based.
    top: usize = 0,
    bottom: usize,
    tabs: []bool,
    modes: Modes = .{},
    title: std.ArrayList(u8) = .empty,
    /// Bytes to send back to the program through the PTY.
    reply: std.ArrayList(u8) = .empty,
    scrollback: Scrollback,
    /// Last printed codepoint, for REP (CSI b).
    last_printed: ?u21 = null,

    state: State = .ground,
    params: [max_params]u16 = undefined,
    /// Bit i set: param i was introduced by ':' (a sub-parameter).
    sub_mask: u32 = 0,
    n_params: usize = 0,
    param_seen: bool = false,
    private: u8 = 0,
    inter: [2]u8 = undefined,
    n_inter: usize = 0,
    osc: std.ArrayList(u8) = .empty,
    utf8_need: u3 = 0,
    utf8_cp: u21 = 0,

    pub fn init(gpa: Allocator, opts: Options) !Terminal {
        const cols = @max(opts.cols, 1);
        const rows = @max(opts.rows, 1);
        var main = try Grid.init(gpa, cols, rows);
        errdefer main.deinit(gpa);
        var alt = try Grid.init(gpa, cols, rows);
        errdefer alt.deinit(gpa);
        const tabs = try gpa.alloc(bool, cols);
        errdefer gpa.free(tabs);
        resetTabs(tabs, 0);
        return .{
            .gpa = gpa,
            .cols = cols,
            .rows = rows,
            .main = main,
            .alt = alt,
            .bottom = rows - 1,
            .tabs = tabs,
            .scrollback = try Scrollback.init(gpa, opts.scrollback),
        };
    }

    pub fn deinit(self: *Terminal) void {
        self.main.deinit(self.gpa);
        self.alt.deinit(self.gpa);
        self.gpa.free(self.tabs);
        self.title.deinit(self.gpa);
        self.reply.deinit(self.gpa);
        self.osc.deinit(self.gpa);
        self.scrollback.deinit(self.gpa);
    }

    fn grid(self: *Terminal) *Grid {
        return if (self.alt_active) &self.alt else &self.main;
    }

    fn line(self: *Terminal, r: usize) []Cell {
        return self.grid().rows[r].cells;
    }

    /// A cell cleared by an erase, insert, delete or scroll. It takes the
    /// current background color (xterm's "bce", which ncurses relies on).
    fn erased(self: *const Terminal) Cell {
        return .{ .style = .{ .bg = self.cursor.style.bg } };
    }

    // ------------------------------------------------------------------
    // Output

    /// Visible cells of row `r` of the active screen.
    pub fn rowCells(self: *const Terminal, r: usize) []const Cell {
        const g = if (self.alt_active) &self.alt else &self.main;
        return g.rows[r].cells;
    }

    /// True if row `r` of the active screen continues on row `r + 1`.
    pub fn rowWrapped(self: *const Terminal, r: usize) bool {
        const g = if (self.alt_active) &self.alt else &self.main;
        return g.rows[r].wrapped;
    }

    /// Appends row `r` as UTF-8 with trailing spaces removed.
    pub fn appendRowText(self: *const Terminal, r: usize, out: *std.ArrayList(u8), gpa: Allocator) !void {
        try appendCellsText(self.rowCells(r), out, gpa, true);
    }

    /// Like appendRowText but keeps trailing blanks (the row is padded to
    /// its full width), so a search for "$ " matches a prompt.
    pub fn appendRowTextPadded(self: *const Terminal, r: usize, out: *std.ArrayList(u8), gpa: Allocator) !void {
        try appendCellsText(self.rowCells(r), out, gpa, false);
    }

    /// Appends the runs of row `r` that have a non-default style: maximal
    /// ranges of cells with equal attributes, `end` exclusive.
    pub fn appendStyleRuns(self: *const Terminal, r: usize, out: *std.ArrayList(StyleRun), gpa: Allocator) !void {
        const cells = self.rowCells(r);
        var i: usize = 0;
        while (i < cells.len) {
            const st = shownStyle(cells[i].style);
            var j = i + 1;
            while (j < cells.len and std.meta.eql(shownStyle(cells[j].style), st)) j += 1;
            if (!std.meta.eql(st, Style{})) try out.append(gpa, .{ .start = i, .end = j, .style = st });
            i = j;
        }
    }

    /// Text of cells [start, end) of row `r`, trailing spaces removed.
    pub fn appendRangeText(self: *const Terminal, r: usize, start: usize, end: usize, out: *std.ArrayList(u8), gpa: Allocator) !void {
        try appendCellsText(self.rowCells(r)[start..end], out, gpa, true);
    }

    /// Whole visible screen, one line per row joined by '\n'. Caller owns.
    pub fn screenText(self: *const Terminal, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (0..self.rows) |r| {
            if (r > 0) try out.append(gpa, '\n');
            try self.appendRowText(r, &out, gpa);
        }
        return out.toOwnedSlice(gpa);
    }

    // ------------------------------------------------------------------
    // Parser

    pub fn feed(self: *Terminal, bytes: []const u8) Allocator.Error!void {
        for (bytes) |b| try self.feedByte(b);
    }

    fn feedByte(self: *Terminal, b: u8) !void {
        // A UTF-8 sequence cut short by anything other than a continuation
        // byte becomes U+FFFD; the byte is then processed normally.
        if (self.utf8_need > 0) {
            if (b >= 0x80 and b <= 0xBF) {
                self.utf8_cp = (self.utf8_cp << 6) | (b & 0x3F);
                self.utf8_need -= 1;
                if (self.utf8_need == 0) try self.print(self.utf8_cp);
                return;
            }
            self.utf8_need = 0;
            try self.print(0xFFFD);
        }

        // "Anywhere" transitions.
        if (b == 0x18 or b == 0x1A) { // CAN, SUB
            self.state = .ground;
            return;
        }
        if (b == 0x1B) {
            switch (self.state) {
                .osc_string => try self.oscDispatch(false),
                else => {},
            }
            self.enterEscape();
            return;
        }

        switch (self.state) {
            .ground => {
                if (b < 0x20) return self.execute(b);
                if (b < 0x7F) return self.print(b);
                if (b == 0x7F) return;
                return self.utf8Start(b);
            },
            .escape => {
                if (b < 0x20) return self.execute(b);
                switch (b) {
                    0x20...0x2F => {
                        self.collect(b);
                        self.state = .escape_intermediate;
                    },
                    '[' => {
                        self.clearParams();
                        self.state = .csi_entry;
                    },
                    ']' => {
                        self.osc.clearRetainingCapacity();
                        self.state = .osc_string;
                    },
                    'P' => {
                        self.clearParams();
                        self.state = .dcs_entry;
                    },
                    'X', '^', '_' => self.state = .sos_pm_apc_string,
                    0x30...0x4F, 0x51...0x57, 0x59, 0x5A, 0x5C, 0x60...0x7E => {
                        self.state = .ground;
                        try self.escDispatch(b);
                    },
                    else => {},
                }
            },
            .escape_intermediate => {
                if (b < 0x20) return self.execute(b);
                switch (b) {
                    0x20...0x2F => self.collect(b),
                    0x30...0x7E => {
                        self.state = .ground;
                        try self.escDispatch(b);
                    },
                    else => {},
                }
            },
            .csi_entry, .csi_param => {
                if (b < 0x20) return self.execute(b);
                switch (b) {
                    '0'...'9', ';', ':' => {
                        self.param(b);
                        self.state = .csi_param;
                    },
                    0x3C...0x3F => {
                        if (self.state == .csi_entry) {
                            self.private = b;
                            self.state = .csi_param;
                        } else {
                            self.state = .csi_ignore;
                        }
                    },
                    0x20...0x2F => {
                        self.collect(b);
                        self.state = .csi_intermediate;
                    },
                    0x40...0x7E => {
                        self.state = .ground;
                        try self.csiDispatch(b);
                    },
                    else => {},
                }
            },
            .csi_intermediate => {
                if (b < 0x20) return self.execute(b);
                switch (b) {
                    0x20...0x2F => self.collect(b),
                    0x30...0x3F => self.state = .csi_ignore,
                    0x40...0x7E => {
                        self.state = .ground;
                        try self.csiDispatch(b);
                    },
                    else => {},
                }
            },
            .csi_ignore => {
                if (b < 0x20) return self.execute(b);
                if (b >= 0x40 and b <= 0x7E) self.state = .ground;
            },
            // DCS content (sixel, XTGETTCAP, ...) is not supported; it is
            // consumed up to the string terminator.
            .dcs_entry => {
                if (b >= 0x40 and b <= 0x7E) self.state = .dcs_passthrough;
            },
            .dcs_passthrough, .sos_pm_apc_string => {},
            .osc_string => {
                if (b == 0x07) {
                    try self.oscDispatch(true);
                    self.state = .ground;
                } else if (b >= 0x20) {
                    if (self.osc.items.len < max_osc_len) try self.osc.append(self.gpa, b);
                }
            },
        }
    }

    fn enterEscape(self: *Terminal) void {
        self.state = .escape;
        self.n_inter = 0;
    }

    fn clearParams(self: *Terminal) void {
        self.n_params = 0;
        self.param_seen = false;
        self.sub_mask = 0;
        self.private = 0;
        self.n_inter = 0;
        self.params[0] = 0;
    }

    fn collect(self: *Terminal, b: u8) void {
        if (self.n_inter < self.inter.len) {
            self.inter[self.n_inter] = b;
            self.n_inter += 1;
        }
    }

    fn param(self: *Terminal, b: u8) void {
        self.param_seen = true;
        if (b == ';' or b == ':') {
            if (self.n_params + 1 < max_params) {
                self.n_params += 1;
                self.params[self.n_params] = 0;
                if (b == ':') self.sub_mask |= @as(u32, 1) << @intCast(self.n_params);
            }
            return;
        }
        const p = &self.params[self.n_params];
        p.* = std.math.mul(u16, p.*, 10) catch std.math.maxInt(u16);
        p.* = std.math.add(u16, p.*, b - '0') catch std.math.maxInt(u16);
    }

    fn paramCount(self: *const Terminal) usize {
        return if (self.param_seen) self.n_params + 1 else 0;
    }

    /// Parameter `i`, with 0 or missing mapped to `default`.
    fn arg(self: *const Terminal, i: usize, default: usize) usize {
        if (i >= self.paramCount()) return default;
        const v = self.params[i];
        return if (v == 0) default else v;
    }

    fn isSub(self: *const Terminal, i: usize) bool {
        return i < 32 and (self.sub_mask >> @intCast(i)) & 1 == 1;
    }

    fn utf8Start(self: *Terminal, b: u8) !void {
        switch (b) {
            0xC2...0xDF => {
                self.utf8_need = 1;
                self.utf8_cp = b & 0x1F;
            },
            0xE0...0xEF => {
                self.utf8_need = 2;
                self.utf8_cp = b & 0x0F;
            },
            0xF0...0xF4 => {
                self.utf8_need = 3;
                self.utf8_cp = b & 0x07;
            },
            else => try self.print(0xFFFD),
        }
    }

    // ------------------------------------------------------------------
    // C0 controls and ESC sequences

    fn execute(self: *Terminal, b: u8) !void {
        switch (b) {
            0x08 => { // BS
                if (self.cursor.pending_wrap) {
                    self.cursor.pending_wrap = false;
                    if (self.cursor.col > 0) self.cursor.col -= 1;
                } else if (self.cursor.col > 0) {
                    self.cursor.col -= 1;
                }
            },
            0x09 => self.tabForward(1),
            0x0A, 0x0B, 0x0C => try self.index(),
            0x0D => self.carriageReturn(),
            0x0E => self.cursor.gl = 1, // SO
            0x0F => self.cursor.gl = 0, // SI
            else => {},
        }
    }

    fn escDispatch(self: *Terminal, final: u8) !void {
        if (self.n_inter == 0) {
            switch (final) {
                '7' => self.saveCursor(),
                '8' => self.restoreCursor(),
                'D' => try self.index(),
                'E' => {
                    try self.index();
                    self.carriageReturn();
                },
                'H' => self.tabs[self.cursor.col] = true,
                'M' => try self.reverseIndex(),
                'c' => self.fullReset(),
                '=' => self.modes.app_keypad = true,
                '>' => self.modes.app_keypad = false,
                'Z' => try self.reply.appendSlice(self.gpa, da1_reply),
                else => {},
            }
            return;
        }
        switch (self.inter[0]) {
            '#' => if (final == '8') self.screenAlignment(),
            '(', ')' => {
                const set: Charset = if (final == '0') .dec_special else .ascii;
                self.cursor.g[if (self.inter[0] == '(') 0 else 1] = set;
            },
            else => {},
        }
    }

    fn oscDispatch(self: *Terminal, bel: bool) !void {
        const data = self.osc.items;
        const semi = std.mem.indexOfScalar(u8, data, ';') orelse data.len;
        const num = std.fmt.parseInt(u16, data[0..semi], 10) catch return;
        const rest = if (semi < data.len) data[semi + 1 ..] else "";
        switch (num) {
            0, 2 => {
                self.title.clearRetainingCapacity();
                try self.title.appendSlice(self.gpa, rest[0..@min(rest.len, max_title_len)]);
            },
            // Default foreground/background color queries. Some programs
            // (vim, fish) wait briefly for these; answer white on black.
            10, 11 => if (std.mem.eql(u8, rest, "?")) {
                const rgb = if (num == 10) "ffff/ffff/ffff" else "0000/0000/0000";
                try self.reply.print(self.gpa, "\x1b]{d};rgb:{s}{s}", .{ num, rgb, if (bel) "\x07" else "\x1b\\" });
            },
            else => {},
        }
    }

    // ------------------------------------------------------------------
    // CSI

    fn csiDispatch(self: *Terminal, final: u8) !void {
        if (self.n_inter > 0) return self.csiIntermediate(final);
        switch (self.private) {
            0 => {},
            '?' => return self.csiPrivate(final),
            '>' => {
                switch (final) {
                    'c' => try self.reply.appendSlice(self.gpa, "\x1b[>1;10;0c"), // DA2
                    'q' => try self.reply.appendSlice(self.gpa, "\x1bP>|headterm 0.1.0\x1b\\"), // XTVERSION
                    else => {},
                }
                return;
            },
            else => return,
        }

        const c = &self.cursor;
        switch (final) {
            '@' => self.insertChars(self.arg(0, 1)),
            'A' => self.cursorUp(self.arg(0, 1)),
            'B', 'e' => self.cursorDown(self.arg(0, 1)),
            'C', 'a' => self.cursorRight(self.arg(0, 1)),
            'D' => self.cursorLeft(self.arg(0, 1)),
            'E' => {
                self.cursorDown(self.arg(0, 1));
                c.col = 0;
            },
            'F' => {
                self.cursorUp(self.arg(0, 1));
                c.col = 0;
            },
            'G', '`' => self.setCol(self.arg(0, 1) - 1),
            'H', 'f' => self.setPosition(self.arg(0, 1) - 1, self.arg(1, 1) - 1),
            'I' => self.tabForward(self.arg(0, 1)),
            'J' => try self.eraseDisplay(self.arg(0, 0)),
            'K' => self.eraseLine(self.arg(0, 0)),
            'L' => self.insertLines(self.arg(0, 1)),
            'M' => self.deleteLines(self.arg(0, 1)),
            'P' => self.deleteChars(self.arg(0, 1)),
            'S' => try self.scrollUp(self.arg(0, 1)),
            'T' => if (self.paramCount() <= 1) try self.scrollDown(self.arg(0, 1)),
            'X' => self.eraseChars(self.arg(0, 1)),
            'Z' => self.tabBackward(self.arg(0, 1)),
            'b' => if (self.last_printed) |cp| {
                for (0..@min(self.arg(0, 1), self.cols * self.rows)) |_| try self.print(cp);
            },
            'c' => if (self.arg(0, 0) == 0) try self.reply.appendSlice(self.gpa, da1_reply),
            'd' => self.setRow(self.arg(0, 1) - 1),
            'g' => switch (self.arg(0, 0)) {
                0 => self.tabs[c.col] = false,
                3 => @memset(self.tabs, false),
                else => {},
            },
            'h', 'l' => {
                const on = final == 'h';
                for (0..self.paramCount()) |i| {
                    if (self.params[i] == 4) self.modes.insert = on;
                }
            },
            'm' => self.sgr(),
            'n' => switch (self.arg(0, 0)) {
                5 => try self.reply.appendSlice(self.gpa, "\x1b[0n"),
                6 => {
                    const pos = self.reportPosition();
                    try self.reply.print(self.gpa, "\x1b[{d};{d}R", .{ pos[0], pos[1] });
                },
                else => {},
            },
            'r' => self.setScrollRegion(self.arg(0, 1), self.arg(1, self.rows)),
            's' => self.saveCursor(),
            'u' => self.restoreCursor(),
            't' => if (self.arg(0, 0) == 18) {
                try self.reply.print(self.gpa, "\x1b[8;{d};{d}t", .{ self.rows, self.cols });
            },
            else => {},
        }
    }

    fn csiPrivate(self: *Terminal, final: u8) !void {
        switch (final) {
            'h', 'l' => {
                const on = final == 'h';
                for (0..self.paramCount()) |i| try self.setPrivateMode(self.params[i], on);
            },
            'n' => if (self.arg(0, 0) == 6) {
                const pos = self.reportPosition();
                try self.reply.print(self.gpa, "\x1b[?{d};{d}R", .{ pos[0], pos[1] });
            },
            else => {},
        }
    }

    fn csiIntermediate(self: *Terminal, final: u8) !void {
        const first = self.inter[0];
        if (first == '!' and final == 'p') return self.softReset();
        // DECRQM: report whether a mode is set (1), reset (2) or unknown (0).
        if (first == '$' and final == 'p') {
            const mode = self.arg(0, 0);
            if (self.private == '?') {
                const state: u8 = if (self.privateMode(mode)) |on| (if (on) 1 else 2) else 0;
                try self.reply.print(self.gpa, "\x1b[?{d};{d}$y", .{ mode, state });
            } else {
                const state: u8 = if (mode == 4) (if (self.modes.insert) 1 else 2) else 0;
                try self.reply.print(self.gpa, "\x1b[{d};{d}$y", .{ mode, state });
            }
        }
    }

    fn privateMode(self: *const Terminal, mode: usize) ?bool {
        return switch (mode) {
            1 => self.modes.app_cursor,
            6 => self.cursor.origin,
            7 => self.modes.autowrap,
            25 => self.modes.cursor_visible,
            47, 1047, 1049 => self.alt_active,
            1004 => self.modes.focus_events,
            1006 => self.modes.mouse_sgr,
            2004 => self.modes.bracketed_paste,
            9, 1000, 1002, 1003 => self.modes.mouse_tracking == mode,
            else => null,
        };
    }

    fn setPrivateMode(self: *Terminal, mode: u16, on: bool) !void {
        switch (mode) {
            1 => self.modes.app_cursor = on,
            6 => {
                self.cursor.origin = on;
                self.setPosition(0, 0);
            },
            7 => {
                self.modes.autowrap = on;
                if (!on) self.cursor.pending_wrap = false;
            },
            25 => self.modes.cursor_visible = on,
            47 => if (on) self.enterAlt(false) else self.leaveAlt(false),
            1047 => if (on) self.enterAlt(false) else self.leaveAlt(true),
            1048 => if (on) self.saveCursor() else self.restoreCursor(),
            1049 => if (on) {
                if (!self.alt_active) {
                    self.saveCursor();
                    self.enterAlt(true);
                }
            } else if (self.alt_active) {
                self.leaveAlt(false);
                self.restoreCursor();
            },
            1004 => self.modes.focus_events = on,
            1006 => self.modes.mouse_sgr = on,
            2004 => self.modes.bracketed_paste = on,
            9, 1000, 1002, 1003 => self.modes.mouse_tracking = if (on) mode else 0,
            else => {},
        }
    }

    fn sgr(self: *Terminal) void {
        const st = &self.cursor.style;
        const n = self.paramCount();
        if (n == 0) {
            st.* = .{};
            return;
        }
        var i: usize = 0;
        while (i < n) {
            const p = self.params[i];
            var j = i + 1;
            while (j < n and self.isSub(j)) j += 1;
            const subs = self.params[i + 1 .. j];
            switch (p) {
                0 => st.* = .{},
                1 => st.bold = true,
                2 => st.faint = true,
                3 => st.italic = true,
                4 => st.underline = if (subs.len > 0) @intCast(@min(subs[0], 5)) else 1,
                5, 6 => st.blink = true,
                7 => st.inverse = true,
                8 => st.invisible = true,
                9 => st.strikethrough = true,
                21 => st.underline = 2,
                22 => {
                    st.bold = false;
                    st.faint = false;
                },
                23 => st.italic = false,
                24 => st.underline = 0,
                25 => st.blink = false,
                27 => st.inverse = false,
                28 => st.invisible = false,
                29 => st.strikethrough = false,
                30...37 => st.fg = .{ .palette = @intCast(p - 30) },
                39 => st.fg = .default,
                40...47 => st.bg = .{ .palette = @intCast(p - 40) },
                49 => st.bg = .default,
                53 => st.overline = true,
                55 => st.overline = false,
                59 => st.underline_color = .default,
                90...97 => st.fg = .{ .palette = @intCast(p - 90 + 8) },
                100...107 => st.bg = .{ .palette = @intCast(p - 100 + 8) },
                38, 48, 58 => {
                    const target = switch (p) {
                        38 => &st.fg,
                        48 => &st.bg,
                        else => &st.underline_color,
                    };
                    if (subs.len > 0) {
                        // Colon form: 38:5:n, 38:2:r:g:b or 38:2:colorspace:r:g:b
                        if (parseColor(subs[0], subs[1..], true)) |col| target.* = col;
                    } else if (i + 1 < n) {
                        // Semicolon form: 38;5;n or 38;2;r;g;b
                        const kind = self.params[i + 1];
                        const want: usize = if (kind == 5) 1 else if (kind == 2) 3 else 0;
                        const avail = self.params[i + 2 .. @min(n, i + 2 + want)];
                        if (parseColor(kind, avail, false)) |col| target.* = col;
                        i += 2 + want;
                        continue;
                    }
                },
                else => {},
            }
            i = j;
        }
    }

    // ------------------------------------------------------------------
    // Printing

    fn print(self: *Terminal, cp_in: u21) !void {
        var cp = cp_in;
        if (cp >= 0x5F and cp <= 0x7E and self.cursor.g[self.cursor.gl] == .dec_special) {
            cp = dec_special[cp - 0x5F];
        }
        const w = charWidth(cp);
        // Combining marks and other zero-width characters are dropped in v0.
        if (w == 0) return;

        const c = &self.cursor;
        if (c.pending_wrap and self.modes.autowrap) {
            try self.wrapLine();
        }
        if (w == 2 and c.col == self.cols - 1) {
            if (self.cols < 2) return;
            if (self.modes.autowrap) {
                self.clearCells(c.row, c.col, self.cols);
                try self.wrapLine();
            } else {
                c.col -= 1;
            }
        }

        const row = self.line(c.row);
        if (self.modes.insert) self.shiftRight(c.row, c.col, w);
        self.splitWide(c.row, c.col);
        if (w == 2) self.splitWide(c.row, c.col + 1);
        row[c.col] = .{ .cp = cp, .width = w, .style = c.style };
        if (w == 2) row[c.col + 1] = .{ .cp = 0, .width = 0, .style = c.style };
        self.last_printed = cp_in;

        if (c.col + w >= self.cols) {
            c.col = self.cols - 1;
            c.pending_wrap = self.modes.autowrap;
        } else {
            c.col += w;
            c.pending_wrap = false;
        }
    }

    fn wrapLine(self: *Terminal) !void {
        self.grid().rows[self.cursor.row].wrapped = true;
        self.cursor.pending_wrap = false;
        self.cursor.col = 0;
        try self.index();
    }

    /// If (r, col) is half of a wide character, blank the other half.
    fn splitWide(self: *Terminal, r: usize, col: usize) void {
        const row = self.line(r);
        if (col >= self.cols) return;
        if (row[col].width == 0 and col > 0) row[col - 1] = blank;
        if (row[col].width == 2 and col + 1 < self.cols) row[col + 1] = blank;
    }

    fn clearCells(self: *Terminal, r: usize, from: usize, to: usize) void {
        if (from >= to) return;
        self.splitWide(r, from);
        self.splitWide(r, to - 1);
        @memset(self.line(r)[from..to], self.erased());
    }

    fn shiftRight(self: *Terminal, r: usize, col: usize, n_in: usize) void {
        const row = self.line(r);
        const n = @min(n_in, self.cols - col);
        self.splitWide(r, col);
        std.mem.copyBackwards(Cell, row[col + n ..], row[col .. self.cols - n]);
        @memset(row[col .. col + n], self.erased());
        if (row[self.cols - 1].width == 2) row[self.cols - 1] = blank;
    }

    // ------------------------------------------------------------------
    // Cursor movement

    fn carriageReturn(self: *Terminal) void {
        self.cursor.col = 0;
        self.cursor.pending_wrap = false;
    }

    fn setCol(self: *Terminal, col: usize) void {
        self.cursor.col = @min(col, self.cols - 1);
        self.cursor.pending_wrap = false;
    }

    fn setRow(self: *Terminal, row: usize) void {
        const c = &self.cursor;
        c.row = if (c.origin) @min(self.top + row, self.bottom) else @min(row, self.rows - 1);
        c.pending_wrap = false;
    }

    fn setPosition(self: *Terminal, row: usize, col: usize) void {
        self.setRow(row);
        self.setCol(col);
    }

    /// 1-based (row, col) as reported by CPR, relative to the scroll region
    /// in origin mode.
    fn reportPosition(self: *const Terminal) [2]usize {
        const c = self.cursor;
        const row = if (c.origin) c.row -| self.top else c.row;
        return .{ row + 1, c.col + 1 };
    }

    fn cursorUp(self: *Terminal, n: usize) void {
        const c = &self.cursor;
        const limit = if (c.row >= self.top) self.top else 0;
        c.row = @max(c.row -| n, limit);
        c.pending_wrap = false;
    }

    fn cursorDown(self: *Terminal, n: usize) void {
        const c = &self.cursor;
        const limit = if (c.row <= self.bottom) self.bottom else self.rows - 1;
        c.row = @min(c.row + n, limit);
        c.pending_wrap = false;
    }

    fn cursorRight(self: *Terminal, n: usize) void {
        self.setCol(self.cursor.col + n);
    }

    fn cursorLeft(self: *Terminal, n: usize) void {
        self.setCol(self.cursor.col -| n);
    }

    fn tabForward(self: *Terminal, n: usize) void {
        const c = &self.cursor;
        for (0..n) |_| {
            if (c.col >= self.cols - 1) break;
            c.col += 1;
            while (c.col < self.cols - 1 and !self.tabs[c.col]) c.col += 1;
        }
    }

    fn tabBackward(self: *Terminal, n: usize) void {
        const c = &self.cursor;
        c.pending_wrap = false;
        for (0..n) |_| {
            if (c.col == 0) break;
            c.col -= 1;
            while (c.col > 0 and !self.tabs[c.col]) c.col -= 1;
        }
    }

    fn saveCursor(self: *Terminal) void {
        self.grid().saved = self.cursor;
    }

    fn restoreCursor(self: *Terminal) void {
        self.cursor = self.grid().saved;
        self.cursor.row = @min(self.cursor.row, self.rows - 1);
        self.cursor.col = @min(self.cursor.col, self.cols - 1);
    }

    // ------------------------------------------------------------------
    // Scrolling

    fn index(self: *Terminal) !void {
        const c = &self.cursor;
        if (c.row == self.bottom) {
            try self.scrollUp(1);
        } else if (c.row < self.rows - 1) {
            c.row += 1;
        }
    }

    fn reverseIndex(self: *Terminal) !void {
        const c = &self.cursor;
        if (c.row == self.top) {
            try self.scrollDown(1);
        } else if (c.row > 0) {
            c.row -= 1;
        }
    }

    /// Scrolls the scroll region up by `n` lines. Lines leaving the top of
    /// the main screen go to scrollback.
    fn scrollUp(self: *Terminal, n_in: usize) !void {
        const n = @min(n_in, self.bottom - self.top + 1);
        const rows = self.grid().rows;
        if (!self.alt_active and self.top == 0) {
            for (rows[0..n]) |r| try self.pushScrollback(r.cells);
        }
        std.mem.rotate(Row, rows[self.top .. self.bottom + 1], n);
        for (rows[self.bottom + 1 - n .. self.bottom + 1]) |*r| r.fill(self.erased());
    }

    fn scrollDown(self: *Terminal, n_in: usize) !void {
        const n = @min(n_in, self.bottom - self.top + 1);
        const region = self.grid().rows[self.top .. self.bottom + 1];
        std.mem.rotate(Row, region, region.len - n);
        for (region[0..n]) |*r| r.fill(self.erased());
    }

    fn pushScrollback(self: *Terminal, cells: []const Cell) !void {
        if (self.scrollback.lines.len == 0) return;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try appendCellsText(cells, &out, self.gpa, true);
        self.scrollback.push(self.gpa, try out.toOwnedSlice(self.gpa));
    }

    fn setScrollRegion(self: *Terminal, top: usize, bottom_in: usize) void {
        const bottom = @min(bottom_in, self.rows);
        if (top >= bottom) return;
        self.top = top - 1;
        self.bottom = bottom - 1;
        self.setPosition(0, 0);
    }

    // ------------------------------------------------------------------
    // Editing

    fn eraseDisplay(self: *Terminal, mode: usize) !void {
        const c = &self.cursor;
        c.pending_wrap = false;
        switch (mode) {
            0 => {
                self.clearCells(c.row, c.col, self.cols);
                self.grid().rows[c.row].wrapped = false;
                for (self.grid().rows[c.row + 1 ..]) |*r| r.fill(self.erased());
            },
            1 => {
                for (self.grid().rows[0..c.row]) |*r| r.fill(self.erased());
                self.clearCells(c.row, 0, c.col + 1);
            },
            2 => for (self.grid().rows) |*r| r.fill(self.erased()),
            3 => self.scrollback.clear(self.gpa),
            else => {},
        }
    }

    fn eraseLine(self: *Terminal, mode: usize) void {
        const c = &self.cursor;
        c.pending_wrap = false;
        switch (mode) {
            0 => {
                self.clearCells(c.row, c.col, self.cols);
                self.grid().rows[c.row].wrapped = false;
            },
            1 => self.clearCells(c.row, 0, c.col + 1),
            2 => {
                self.clearCells(c.row, 0, self.cols);
                self.grid().rows[c.row].wrapped = false;
            },
            else => {},
        }
    }

    fn eraseChars(self: *Terminal, n: usize) void {
        const c = &self.cursor;
        c.pending_wrap = false;
        self.clearCells(c.row, c.col, @min(c.col + n, self.cols));
    }

    fn insertChars(self: *Terminal, n: usize) void {
        self.cursor.pending_wrap = false;
        self.shiftRight(self.cursor.row, self.cursor.col, n);
    }

    fn deleteChars(self: *Terminal, n_in: usize) void {
        const c = &self.cursor;
        c.pending_wrap = false;
        const row = self.line(c.row);
        const n = @min(n_in, self.cols - c.col);
        self.splitWide(c.row, c.col);
        self.splitWide(c.row, c.col + n - 1);
        std.mem.copyForwards(Cell, row[c.col .. self.cols - n], row[c.col + n ..]);
        @memset(row[self.cols - n ..], self.erased());
    }

    fn insertLines(self: *Terminal, n_in: usize) void {
        const c = &self.cursor;
        if (c.row < self.top or c.row > self.bottom) return;
        const region = self.grid().rows[c.row .. self.bottom + 1];
        const n = @min(n_in, region.len);
        std.mem.rotate(Row, region, region.len - n);
        for (region[0..n]) |*r| r.fill(self.erased());
        c.col = 0;
        c.pending_wrap = false;
    }

    fn deleteLines(self: *Terminal, n_in: usize) void {
        const c = &self.cursor;
        if (c.row < self.top or c.row > self.bottom) return;
        const region = self.grid().rows[c.row .. self.bottom + 1];
        const n = @min(n_in, region.len);
        std.mem.rotate(Row, region, n);
        for (region[region.len - n ..]) |*r| r.fill(self.erased());
        c.col = 0;
        c.pending_wrap = false;
    }

    fn screenAlignment(self: *Terminal) void {
        for (self.grid().rows) |*r| r.fill(.{ .cp = 'E' });
        self.top = 0;
        self.bottom = self.rows - 1;
        self.cursor.origin = false;
        self.setPosition(0, 0);
    }

    // ------------------------------------------------------------------
    // Modes and resets

    fn enterAlt(self: *Terminal, clear: bool) void {
        if (self.alt_active) return;
        self.alt_active = true;
        if (clear) self.alt.clear();
    }

    fn leaveAlt(self: *Terminal, clear: bool) void {
        if (!self.alt_active) return;
        if (clear) self.alt.clear();
        self.alt_active = false;
    }

    fn softReset(self: *Terminal) void {
        self.modes.insert = false;
        self.modes.autowrap = true;
        self.modes.cursor_visible = true;
        self.modes.app_cursor = false;
        self.modes.app_keypad = false;
        self.top = 0;
        self.bottom = self.rows - 1;
        self.cursor.origin = false;
        self.cursor.style = .{};
        self.cursor.g = .{ .ascii, .ascii };
        self.cursor.gl = 0;
        self.cursor.pending_wrap = false;
        self.grid().saved = .{};
    }

    fn fullReset(self: *Terminal) void {
        self.main.clear();
        self.alt.clear();
        self.main.saved = .{};
        self.alt.saved = .{};
        self.alt_active = false;
        self.cursor = .{};
        self.modes = .{};
        self.top = 0;
        self.bottom = self.rows - 1;
        self.last_printed = null;
        resetTabs(self.tabs, 0);
    }

    /// Resizes both screens without reflowing. If the cursor would fall off
    /// the bottom, the top of the screen is scrolled away first.
    pub fn resize(self: *Terminal, cols_in: usize, rows_in: usize) !void {
        const cols = @max(cols_in, 1);
        const rows = @max(rows_in, 1);
        if (cols == self.cols and rows == self.rows) return;

        const tabs = try self.gpa.alloc(bool, cols);
        errdefer self.gpa.free(tabs);
        @memcpy(tabs[0..@min(cols, self.cols)], self.tabs[0..@min(cols, self.cols)]);
        if (cols > self.cols) resetTabs(tabs, self.cols);

        var main = try Grid.init(self.gpa, cols, rows);
        errdefer main.deinit(self.gpa);
        var alt = try Grid.init(self.gpa, cols, rows);
        errdefer alt.deinit(self.gpa);

        const shift = if (self.cursor.row >= rows) self.cursor.row - rows + 1 else 0;
        if (!self.alt_active) {
            for (self.main.rows[0..shift]) |r| try self.pushScrollback(r.cells);
        }
        copyGrid(&main, &self.main, if (self.alt_active) 0 else shift, cols);
        copyGrid(&alt, &self.alt, if (self.alt_active) shift else 0, cols);
        main.saved = self.main.saved;
        alt.saved = self.alt.saved;

        self.main.deinit(self.gpa);
        self.alt.deinit(self.gpa);
        self.gpa.free(self.tabs);
        self.main = main;
        self.alt = alt;
        self.tabs = tabs;
        self.cols = cols;
        self.rows = rows;
        self.top = 0;
        self.bottom = rows - 1;
        self.cursor.row = @min(self.cursor.row - shift, rows - 1);
        self.cursor.col = @min(self.cursor.col, cols - 1);
        self.cursor.pending_wrap = false;
        for ([_]*Grid{ &self.main, &self.alt }) |g| {
            g.saved.row = @min(g.saved.row, rows - 1);
            g.saved.col = @min(g.saved.col, cols - 1);
        }
    }
};

const da1_reply = "\x1b[?62;22c";

pub const StyleRun = struct {
    start: usize,
    end: usize,
    style: Style,
};

/// The attributes reported to clients; underline color is not.
fn shownStyle(s: Style) Style {
    var x = s;
    x.underline_color = .default;
    return x;
}

fn copyGrid(dst: *Grid, src: *const Grid, skip: usize, cols: usize) void {
    var r: usize = 0;
    while (r < dst.rows.len and r + skip < src.rows.len) : (r += 1) {
        const from = src.rows[r + skip].cells;
        const to = dst.rows[r].cells;
        const n = @min(cols, from.len);
        @memcpy(to[0..n], from[0..n]);
        // A wide char cut in half at the new right edge becomes a blank.
        if (n > 0 and to[n - 1].width == 2) to[n - 1] = blank;
        dst.rows[r].wrapped = src.rows[r + skip].wrapped;
    }
}

fn resetTabs(tabs: []bool, from: usize) void {
    for (tabs[from..], from..) |*t, i| t.* = i % 8 == 0 and i != 0;
}

fn parseColor(kind: u16, rest: []const u16, colon: bool) ?Color {
    switch (kind) {
        5 => if (rest.len >= 1) return .{ .palette = @truncate(rest[0]) },
        2 => {
            // The colon form may carry a color-space id before r:g:b.
            const rgb = if (colon and rest.len >= 4) rest[1..4] else if (rest.len >= 3) rest[0..3] else return null;
            return .{ .rgb = .{ @truncate(rgb[0]), @truncate(rgb[1]), @truncate(rgb[2]) } };
        },
        else => {},
    }
    return null;
}

fn appendCellsText(cells: []const Cell, out: *std.ArrayList(u8), gpa: Allocator, trim: bool) !void {
    const start = out.items.len;
    var prev_wide = false;
    for (cells) |cell| {
        if (cell.width == 0) {
            if (!prev_wide) try out.append(gpa, ' ');
            prev_wide = false;
            continue;
        }
        prev_wide = cell.width == 2;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cell.cp, &buf) catch blk: {
            buf[0] = '?';
            break :blk 1;
        };
        try out.appendSlice(gpa, buf[0..n]);
    }
    if (!trim) return;
    var end = out.items.len;
    while (end > start and out.items[end - 1] == ' ') end -= 1;
    out.shrinkRetainingCapacity(end);
}

/// DEC Special Graphics (ESC ( 0) for 0x5F..0x7E: line drawing and symbols.
const dec_special = [_]u21{
    0x00A0, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0,
    0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C,
    0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534,
    0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
};

const Range = struct { u21, u21 };

const zero_width = [_]Range{
    .{ 0x0300, 0x036F }, .{ 0x0483, 0x0489 },   .{ 0x0591, 0x05BD },   .{ 0x0610, 0x061A },
    .{ 0x064B, 0x065F }, .{ 0x0E31, 0x0E31 },   .{ 0x0E34, 0x0E3A },   .{ 0x0E47, 0x0E4E },
    .{ 0x1AB0, 0x1AFF }, .{ 0x1DC0, 0x1DFF },   .{ 0x200B, 0x200F },   .{ 0x2028, 0x202E },
    .{ 0x2060, 0x2064 }, .{ 0x20D0, 0x20FF },   .{ 0xFE00, 0xFE0F },   .{ 0xFE20, 0xFE2F },
    .{ 0xFEFF, 0xFEFF }, .{ 0x1F3FB, 0x1F3FF }, .{ 0xE0000, 0xE0FFF },
};

const wide = [_]Range{
    .{ 0x1100, 0x115F },   .{ 0x231A, 0x231B },   .{ 0x2329, 0x232A },   .{ 0x23E9, 0x23EC },
    .{ 0x23F0, 0x23F0 },   .{ 0x23F3, 0x23F3 },   .{ 0x25FD, 0x25FE },   .{ 0x2614, 0x2615 },
    .{ 0x2648, 0x2653 },   .{ 0x267F, 0x267F },   .{ 0x2693, 0x2693 },   .{ 0x26A1, 0x26A1 },
    .{ 0x26AA, 0x26AB },   .{ 0x26BD, 0x26BE },   .{ 0x26C4, 0x26C5 },   .{ 0x26CE, 0x26CE },
    .{ 0x26D4, 0x26D4 },   .{ 0x26EA, 0x26EA },   .{ 0x26F2, 0x26F3 },   .{ 0x26F5, 0x26F5 },
    .{ 0x26FA, 0x26FA },   .{ 0x26FD, 0x26FD },   .{ 0x2705, 0x2705 },   .{ 0x270A, 0x270B },
    .{ 0x2728, 0x2728 },   .{ 0x274C, 0x274C },   .{ 0x274E, 0x274E },   .{ 0x2753, 0x2755 },
    .{ 0x2757, 0x2757 },   .{ 0x2795, 0x2797 },   .{ 0x27B0, 0x27B0 },   .{ 0x27BF, 0x27BF },
    .{ 0x2B1B, 0x2B1C },   .{ 0x2B50, 0x2B50 },   .{ 0x2B55, 0x2B55 },   .{ 0x2E80, 0x303E },
    .{ 0x3041, 0x33FF },   .{ 0x3400, 0x4DBF },   .{ 0x4E00, 0x9FFF },   .{ 0xA000, 0xA4CF },
    .{ 0xA960, 0xA97F },   .{ 0xAC00, 0xD7A3 },   .{ 0xF900, 0xFAFF },   .{ 0xFE10, 0xFE19 },
    .{ 0xFE30, 0xFE6F },   .{ 0xFF00, 0xFF60 },   .{ 0xFFE0, 0xFFE6 },   .{ 0x16FE0, 0x16FE4 },
    .{ 0x17000, 0x18CFF }, .{ 0x1B000, 0x1B2FF }, .{ 0x1F004, 0x1F004 }, .{ 0x1F0CF, 0x1F0CF },
    .{ 0x1F18E, 0x1F18E }, .{ 0x1F191, 0x1F19A }, .{ 0x1F200, 0x1F251 }, .{ 0x1F300, 0x1F320 },
    .{ 0x1F32D, 0x1F335 }, .{ 0x1F337, 0x1F37C }, .{ 0x1F37E, 0x1F393 }, .{ 0x1F3A0, 0x1F3CA },
    .{ 0x1F3CF, 0x1F3D3 }, .{ 0x1F3E0, 0x1F3F0 }, .{ 0x1F3F4, 0x1F3F4 }, .{ 0x1F3F8, 0x1F43E },
    .{ 0x1F440, 0x1F440 }, .{ 0x1F442, 0x1F4FC }, .{ 0x1F4FF, 0x1F53D }, .{ 0x1F54B, 0x1F54E },
    .{ 0x1F550, 0x1F567 }, .{ 0x1F57A, 0x1F57A }, .{ 0x1F595, 0x1F596 }, .{ 0x1F5A4, 0x1F5A4 },
    .{ 0x1F5FB, 0x1F64F }, .{ 0x1F680, 0x1F6C5 }, .{ 0x1F6CC, 0x1F6CC }, .{ 0x1F6D0, 0x1F6D2 },
    .{ 0x1F6D5, 0x1F6D7 }, .{ 0x1F6DC, 0x1F6DF }, .{ 0x1F6EB, 0x1F6EC }, .{ 0x1F6F4, 0x1F6FC },
    .{ 0x1F7E0, 0x1F7EB }, .{ 0x1F7F0, 0x1F7F0 }, .{ 0x1F90C, 0x1F93A }, .{ 0x1F93C, 0x1F945 },
    .{ 0x1F947, 0x1F9FF }, .{ 0x1FA70, 0x1FAFF }, .{ 0x20000, 0x2FFFD }, .{ 0x30000, 0x3FFFD },
};

fn inRanges(cp: u21, ranges: []const Range) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// Display width: 0 for combining/zero-width, 2 for East Asian wide and
/// emoji-presentation characters, else 1. Approximates wcwidth().
pub fn charWidth(cp: u21) u2 {
    if (cp < 0x300) return 1;
    if (inRanges(cp, &zero_width)) return 0;
    if (inRanges(cp, &wide)) return 2;
    return 1;
}

// ======================================================================
// Tests

const testing = std.testing;

fn testTerm(cols: usize, rows: usize) !Terminal {
    return Terminal.init(testing.allocator, .{ .cols = cols, .rows = rows, .scrollback = 100 });
}

fn expectScreen(t: *const Terminal, expected: []const u8) !void {
    const s = try t.screenText(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(expected, s);
}

fn expectCursor(t: *const Terminal, row: usize, col: usize) !void {
    try testing.expectEqual(row, t.cursor.row);
    try testing.expectEqual(col, t.cursor.col);
}

test "plain text, CR LF and trailing space trimming" {
    var t = try testTerm(10, 3);
    defer t.deinit();
    try t.feed("hello  \r\nworld");
    try expectScreen(&t, "hello\nworld\n");
    try expectCursor(&t, 1, 5);
}

test "autowrap with pending wrap state" {
    var t = try testTerm(5, 3);
    defer t.deinit();
    try t.feed("abcde");
    // Cursor stays on the last column until the next printable character.
    try expectCursor(&t, 0, 4);
    try testing.expect(t.cursor.pending_wrap);
    try t.feed("f");
    try expectScreen(&t, "abcde\nf\n");
    try expectCursor(&t, 1, 1);

    // CR clears the pending wrap: no blank line is produced.
    var t2 = try testTerm(5, 3);
    defer t2.deinit();
    try t2.feed("abcde\r\nx");
    try expectScreen(&t2, "abcde\nx\n");
}

test "autowrap disabled overwrites last column" {
    var t = try testTerm(5, 2);
    defer t.deinit();
    try t.feed("\x1b[?7labcdefg");
    try expectScreen(&t, "abcdg\n");
    try expectCursor(&t, 0, 4);
}

test "scrolling pushes lines into scrollback" {
    var t = try testTerm(5, 2);
    defer t.deinit();
    try t.feed("1\r\n2\r\n3\r\n4");
    try expectScreen(&t, "3\n4");
    try testing.expectEqual(@as(usize, 2), t.scrollback.len);
    try testing.expectEqualStrings("1", t.scrollback.get(0));
    try testing.expectEqualStrings("2", t.scrollback.get(1));
}

test "scrollback is bounded" {
    var t = try Terminal.init(testing.allocator, .{ .cols = 5, .rows = 1, .scrollback = 3 });
    defer t.deinit();
    try t.feed("a\r\nb\r\nc\r\nd\r\ne");
    try testing.expectEqual(@as(usize, 3), t.scrollback.len);
    try testing.expectEqualStrings("b", t.scrollback.get(0));
    try testing.expectEqualStrings("d", t.scrollback.get(2));
}

test "scroll region (DECSTBM) confines scrolling" {
    var t = try testTerm(5, 5);
    defer t.deinit();
    try t.feed("top\r\na\r\nb\r\nc\r\nbot");
    try t.feed("\x1b[2;4r"); // region rows 2..4, cursor homes
    try expectCursor(&t, 0, 0);
    try t.feed("\x1b[4;1H\n"); // LF at bottom margin scrolls the region
    try expectScreen(&t, "top\nb\nc\n\nbot");
    try testing.expectEqual(@as(usize, 0), t.scrollback.len);
    try t.feed("\x1b[2;1H\x1bM"); // RI at top margin scrolls down
    try expectScreen(&t, "top\n\nb\nc\nbot");
}

test "origin mode positions relative to scroll region" {
    var t = try testTerm(10, 6);
    defer t.deinit();
    try t.feed("\x1b[3;5r\x1b[?6h");
    try expectCursor(&t, 2, 0);
    try t.feed("\x1b[2;3H");
    try expectCursor(&t, 3, 2);
    try t.feed("\x1b[9;1H"); // clamped to bottom margin
    try expectCursor(&t, 4, 0);
    try t.feed("\x1b[6n");
    try testing.expectEqualStrings("\x1b[3;1R", t.reply.items);
}

test "cursor movement sequences" {
    var t = try testTerm(20, 10);
    defer t.deinit();
    try t.feed("\x1b[5;10H");
    try expectCursor(&t, 4, 9);
    try t.feed("\x1b[2A");
    try expectCursor(&t, 2, 9);
    try t.feed("\x1b[3B");
    try expectCursor(&t, 5, 9);
    try t.feed("\x1b[4C");
    try expectCursor(&t, 5, 13);
    try t.feed("\x1b[20D");
    try expectCursor(&t, 5, 0);
    try t.feed("\x1b[7G");
    try expectCursor(&t, 5, 6);
    try t.feed("\x1b[2d");
    try expectCursor(&t, 1, 6);
    try t.feed("\x1b[2E");
    try expectCursor(&t, 3, 0);
    try t.feed("\x1b[5G\x1b[1F");
    try expectCursor(&t, 2, 0);
    try t.feed("\x1b[3;4f");
    try expectCursor(&t, 2, 3);
    try t.feed("\x1b[H");
    try expectCursor(&t, 0, 0);
    try t.feed("\x1b[99;99H");
    try expectCursor(&t, 9, 19);
}

test "erase in display and line" {
    var t = try testTerm(5, 3);
    defer t.deinit();
    try t.feed("aaaaa\r\nbbbbb\r\nccccc");
    try t.feed("\x1b[2;3H\x1b[K");
    try expectScreen(&t, "aaaaa\nbb\nccccc");
    try t.feed("\x1b[1K");
    try expectScreen(&t, "aaaaa\n\nccccc");
    try t.feed("\x1b[1;2H\x1b[J");
    try expectScreen(&t, "a\n\n");
    try t.feed("\x1b[3;1Hzzzzz\x1b[3;3H\x1b[1J");
    try expectScreen(&t, "\n\n   zz");
    try t.feed("\x1b[2J");
    try expectScreen(&t, "\n\n");
}

test "erase characters (ECH)" {
    var t = try testTerm(8, 1);
    defer t.deinit();
    try t.feed("abcdefgh\x1b[1;3H\x1b[3X");
    try expectScreen(&t, "ab   fgh");
    try expectCursor(&t, 0, 2);
}

test "insert and delete characters" {
    var t = try testTerm(8, 1);
    defer t.deinit();
    try t.feed("abcdef\x1b[1;3H\x1b[2@");
    try expectScreen(&t, "ab  cdef");
    try t.feed("\x1b[3P");
    try expectScreen(&t, "abdef");
    try t.feed("\x1b[1;1H\x1b[4h"); // insert mode
    try t.feed("XY");
    try expectScreen(&t, "XYabdef");
}

test "insert and delete lines" {
    var t = try testTerm(3, 4);
    defer t.deinit();
    try t.feed("1\r\n2\r\n3\r\n4");
    try t.feed("\x1b[2;2H\x1b[L");
    try expectScreen(&t, "1\n\n2\n3");
    try expectCursor(&t, 1, 0);
    try t.feed("\x1b[2M");
    try expectScreen(&t, "1\n3\n\n");
    // IL inside a scroll region does not touch lines below it.
    try t.feed("\x1b[H\x1b[2Ja\r\nb\r\nc\r\nd\x1b[1;3r\x1b[1;1H\x1b[L");
    try expectScreen(&t, "\na\nb\nd");
}

test "scroll up and down (SU/SD)" {
    var t = try testTerm(3, 3);
    defer t.deinit();
    try t.feed("1\r\n2\r\n3\x1b[S");
    try expectScreen(&t, "2\n3\n");
    try t.feed("\x1b[2T");
    try expectScreen(&t, "\n\n2");
}

test "IND, NEL and RI" {
    var t = try testTerm(5, 3);
    defer t.deinit();
    try t.feed("ab\x1bDc");
    try expectScreen(&t, "ab\n  c\n");
    try t.feed("\x1bEd");
    try expectScreen(&t, "ab\n  c\nd");
    try t.feed("\x1bM\x1bM\x1bMx");
    try expectScreen(&t, " x\nab\n  c");
}

test "alternate screen 1049 saves and restores" {
    var t = try testTerm(10, 3);
    defer t.deinit();
    try t.feed("shell$ ");
    try t.feed("\x1b[?1049h");
    try testing.expect(t.alt_active);
    try expectScreen(&t, "\n\n");
    try t.feed("\x1b[2;1Hvim stuff");
    try expectScreen(&t, "\nvim stuff\n");
    try t.feed("\x1b[?1049l");
    try testing.expect(!t.alt_active);
    try expectScreen(&t, "shell$\n\n");
    try expectCursor(&t, 0, 7);
    // Alt screen scrolling never reaches scrollback.
    try t.feed("\x1b[?1049h\r\n\r\n\r\n\r\n\x1b[?1049l");
    try testing.expectEqual(@as(usize, 0), t.scrollback.len);
}

test "alternate screen 47 and 1047" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    try t.feed("main");
    try t.feed("\x1b[?47h\x1b[Halt\x1b[?47l");
    try expectScreen(&t, "main\n");
    // 47 does not clear the alt buffer, so the old content is still there.
    try t.feed("\x1b[?47h");
    try expectScreen(&t, "alt\n");
    try t.feed("\x1b[?47l\x1b[?1047h\x1b[?1047l\x1b[?47h");
    try expectScreen(&t, "\n");
}

test "DECSC/DECRC and CSI s/u" {
    var t = try testTerm(10, 5);
    defer t.deinit();
    try t.feed("\x1b[2;3H\x1b7\x1b[5;5H\x1b8");
    try expectCursor(&t, 1, 2);
    try t.feed("\x1b[3;4H\x1b[s\x1b[H\x1b[u");
    try expectCursor(&t, 2, 3);
}

test "tabs" {
    var t = try testTerm(20, 1);
    defer t.deinit();
    try t.feed("a\tb");
    try expectCursor(&t, 0, 9);
    try t.feed("\x1b[1;3H\x1bH\x1b[1;1H\tX");
    try expectScreen(&t, "a X     b");
    try t.feed("\x1b[1;1H\x1b[2I"); // stops are now 2, 8, 16
    try expectCursor(&t, 0, 8);
    try t.feed("\x1b[1;20H\x1b[Z");
    try expectCursor(&t, 0, 16);
    try t.feed("\x1b[3g\x1b[1;1H\t"); // no stops: to last column
    try expectCursor(&t, 0, 19);
}

test "UTF-8 and wide characters" {
    var t = try testTerm(6, 2);
    defer t.deinit();
    try t.feed("h\xc3\xa9\xe4\xb8\xad");
    try expectScreen(&t, "hé中\n");
    try expectCursor(&t, 0, 4);
    // A wide char that does not fit in the last column wraps.
    try t.feed("x\xf0\x9f\x98\x80");
    try expectScreen(&t, "hé中x\n😀");
    try expectCursor(&t, 1, 2);
    // Overwriting half of a wide char blanks the other half.
    try t.feed("\x1b[1;4Hy");
    try expectScreen(&t, "hé yx\n😀");
    try testing.expectEqual(@as(u2, 2), charWidth(0x4E2D));
    try testing.expectEqual(@as(u2, 1), charWidth('a'));
    try testing.expectEqual(@as(u2, 0), charWidth(0x0301));
}

test "invalid UTF-8 becomes U+FFFD" {
    var t = try testTerm(10, 1);
    defer t.deinit();
    try t.feed("a\xffb\xc3c");
    try expectScreen(&t, "a\u{FFFD}b\u{FFFD}c");
}

test "sequences split across feed calls" {
    var t = try testTerm(10, 3);
    defer t.deinit();
    const input = "\x1b[2;3Hhi\xe4\xb8\xad\x1b]0;my title\x07\x1b[6n";
    for (input) |b| try t.feed(&.{b});
    try expectScreen(&t, "\n  hi中\n");
    try testing.expectEqualStrings("my title", t.title.items);
    try testing.expectEqualStrings("\x1b[2;7R", t.reply.items);
}

test "CPR, DSR and device attributes replies" {
    var t = try testTerm(10, 5);
    defer t.deinit();
    try t.feed("\x1b[3;4H\x1b[6n");
    try testing.expectEqualStrings("\x1b[3;4R", t.reply.items);
    t.reply.clearRetainingCapacity();
    try t.feed("\x1b[5n\x1b[c");
    try testing.expectEqualStrings("\x1b[0n\x1b[?62;22c", t.reply.items);
    t.reply.clearRetainingCapacity();
    try t.feed("\x1b[>c");
    try testing.expectEqualStrings("\x1b[>1;10;0c", t.reply.items);
    t.reply.clearRetainingCapacity();
    try t.feed("\x1b[?2004$p");
    try testing.expectEqualStrings("\x1b[?2004;2$y", t.reply.items);
}

test "OSC title with BEL and ST, unknown OSC ignored" {
    var t = try testTerm(10, 1);
    defer t.deinit();
    try t.feed("\x1b]2;first\x1b\\a\x1b]0;second\x07b\x1b]52;c;Zm9v\x07c\x1b]8;;http://x\x1b\\d");
    try testing.expectEqualStrings("second", t.title.items);
    try expectScreen(&t, "abcd");
}

test "unknown and ignored sequences are consumed" {
    var t = try testTerm(30, 1);
    defer t.deinit();
    try t.feed("a\x1b[>4;1mb\x1b[?1000;1006hc\x1b[2 qd\x1bP+q544e\x1b\\e\x1b_apc\x1b\\f\x1b[?u");
    try t.feed("g\x1b(Bh\x1b[=5ui\x1b%Gj\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20;21;22;23;24;25;26;27;28;29;30;31;32;33;34;35mk");
    try expectScreen(&t, "abcdefghijk");
    try testing.expectEqual(@as(u16, 1000), t.modes.mouse_tracking);
    try testing.expect(t.modes.mouse_sgr);
}

test "SGR parsing including 256 and truecolor forms" {
    var t = try testTerm(10, 1);
    defer t.deinit();
    try t.feed("\x1b[1;4;31m");
    try testing.expect(t.cursor.style.bold);
    try testing.expectEqual(@as(u3, 1), t.cursor.style.underline);
    try testing.expectEqual(Color{ .palette = 1 }, t.cursor.style.fg);
    try t.feed("\x1b[38;5;208;48;2;10;20;30m");
    try testing.expectEqual(Color{ .palette = 208 }, t.cursor.style.fg);
    try testing.expectEqual(Color{ .rgb = .{ 10, 20, 30 } }, t.cursor.style.bg);
    try t.feed("\x1b[38:2::1:2:3;4:3m");
    try testing.expectEqual(Color{ .rgb = .{ 1, 2, 3 } }, t.cursor.style.fg);
    try testing.expectEqual(@as(u3, 3), t.cursor.style.underline);
    try t.feed("\x1b[38:5:99;1m");
    try testing.expectEqual(Color{ .palette = 99 }, t.cursor.style.fg);
    try testing.expect(t.cursor.style.bold);
    try t.feed("\x1b[m");
    try testing.expectEqual(Style{}, t.cursor.style);
    try t.feed("x\x1b[0;97;101mz");
    try testing.expectEqual(Color{ .palette = 15 }, t.cursor.style.fg);
    try expectScreen(&t, "xz");
}

test "DECSET modes: cursor keys, cursor visibility, bracketed paste" {
    var t = try testTerm(10, 1);
    defer t.deinit();
    try t.feed("\x1b[?1h\x1b[?25l\x1b[?2004h");
    try testing.expect(t.modes.app_cursor);
    try testing.expect(!t.modes.cursor_visible);
    try testing.expect(t.modes.bracketed_paste);
    try t.feed("\x1b[?25h\x1b[?1;2004l");
    try testing.expect(!t.modes.app_cursor);
    try testing.expect(t.modes.cursor_visible);
    try testing.expect(!t.modes.bracketed_paste);
}

test "DEC special graphics line drawing" {
    var t = try testTerm(10, 1);
    defer t.deinit();
    try t.feed("\x1b(0lqqk\x1b(B x");
    try expectScreen(&t, "┌──┐ x");
    try t.feed("\x0eq\x0fq"); // SO/SI with G1 = ascii
    try expectScreen(&t, "┌──┐ xqq");
}

test "REP repeats last character" {
    var t = try testTerm(10, 1);
    defer t.deinit();
    try t.feed("-\x1b[4b");
    try expectScreen(&t, "-----");
}

test "resize keeps content and moves cursor into view" {
    var t = try testTerm(10, 4);
    defer t.deinit();
    try t.feed("1\r\n2\r\n3\r\n4");
    try t.resize(5, 2);
    try expectScreen(&t, "3\n4");
    try expectCursor(&t, 1, 1);
    try testing.expectEqualStrings("2", t.scrollback.get(t.scrollback.len - 1));
    try t.resize(8, 3);
    try expectScreen(&t, "3\n4\n");
    try t.feed("\x1b[3;8Hx");
    try expectScreen(&t, "3\n4\n       x");
}

test "RIS resets the screen" {
    var t = try testTerm(5, 2);
    defer t.deinit();
    try t.feed("ab\x1b[?1049h\x1b[?1hxy\x1bc");
    try testing.expect(!t.alt_active);
    try testing.expect(!t.modes.app_cursor);
    try expectScreen(&t, "\n");
    try expectCursor(&t, 0, 0);
}

test "backspace and carriage return with pending wrap" {
    var t = try testTerm(3, 2);
    defer t.deinit();
    try t.feed("abc\x08x");
    try expectScreen(&t, "axc\n");
}

fn expectRuns(t: *const Terminal, row: usize, expected: []const StyleRun) !void {
    var runs: std.ArrayList(StyleRun) = .empty;
    defer runs.deinit(testing.allocator);
    try t.appendStyleRuns(row, &runs, testing.allocator);
    try testing.expectEqual(expected.len, runs.items.len);
    for (expected, runs.items) |e, got| {
        try testing.expectEqual(e.start, got.start);
        try testing.expectEqual(e.end, got.end);
        try testing.expect(std.meta.eql(e.style, got.style));
    }
}

test "styles are stored per cell" {
    var t = try testTerm(20, 2);
    defer t.deinit();
    try t.feed("ab\x1b[1;31mcd\x1b[0m e\x1b[38;5;208;48;2;1;2;3mf\x1b[m");
    try testing.expect(t.rowCells(0)[2].style.bold);
    try testing.expectEqual(Color{ .palette = 1 }, t.rowCells(0)[3].style.fg);
    try testing.expect(!t.rowCells(0)[4].style.bold);
    try expectRuns(&t, 0, &.{
        .{ .start = 2, .end = 4, .style = .{ .bold = true, .fg = .{ .palette = 1 } } },
        .{ .start = 6, .end = 7, .style = .{ .fg = .{ .palette = 208 }, .bg = .{ .rgb = .{ 1, 2, 3 } } } },
    });
    try expectRuns(&t, 1, &.{});
}

test "wide characters carry their style on both halves" {
    var t = try testTerm(10, 1);
    defer t.deinit();
    try t.feed("\x1b[4m\xe4\xb8\xad\x1b[24mx");
    try expectRuns(&t, 0, &.{.{ .start = 0, .end = 2, .style = .{ .underline = 1 } }});
}

test "erase uses the current background color (bce)" {
    var t = try testTerm(6, 3);
    defer t.deinit();
    try t.feed("\x1b[44mab\x1b[K\x1b[m");
    const blue: Style = .{ .bg = .{ .palette = 4 } };
    try expectRuns(&t, 0, &.{.{ .start = 0, .end = 6, .style = blue }});
    try expectScreen(&t, "ab\n\n");
    // Only the background is used: bold does not leak into erased cells.
    try t.feed("\x1b[2;1H\x1b[1;42m\x1b[2X\x1b[m");
    try expectRuns(&t, 1, &.{.{ .start = 0, .end = 2, .style = .{ .bg = .{ .palette = 2 } } }});
    // Erasing with default colors clears the style again.
    try t.feed("\x1b[1;1H\x1b[2K");
    try expectRuns(&t, 0, &.{});
    // Scrolling in a new line uses the current background too.
    try t.feed("\x1b[3;1H\x1b[45m\n\x1b[m");
    try expectRuns(&t, 2, &.{.{ .start = 0, .end = 6, .style = .{ .bg = .{ .palette = 5 } } }});
}

test "curses-style menu: the selected item is inverse" {
    var t = try testTerm(20, 5);
    defer t.deinit();
    // What ncurses sends for a box-less menu with item 2 highlighted.
    try t.feed("\x1b[?1049h\x1b[H\x1b[2J\x1b[1;1H\x1b[1mMenu\x1b[m");
    try t.feed("\x1b[2;3HOpen\x1b[3;3H\x1b[7mSave    \x1b[m\x1b[4;3HQuit");
    try expectScreen(&t, "Menu\n  Open\n  Save\n  Quit\n");
    try expectRuns(&t, 1, &.{});
    try expectRuns(&t, 2, &.{.{ .start = 2, .end = 10, .style = .{ .inverse = true } }});
    // Moving the selection down repaints both rows.
    try t.feed("\x1b[3;3HSave    \x1b[4;3H\x1b[7mQuit    \x1b[m");
    try expectRuns(&t, 2, &.{});
    try expectRuns(&t, 3, &.{.{ .start = 2, .end = 10, .style = .{ .inverse = true } }});

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try t.appendRangeText(3, 2, 10, &text, testing.allocator);
    try testing.expectEqualStrings("Quit", text.items);
}

test "rows remember autowrap, and the flag moves with scrolling" {
    var t = try testTerm(5, 3);
    defer t.deinit();
    try t.feed("1\r\nabcdefg");
    try testing.expect(!t.rowWrapped(0));
    try testing.expect(t.rowWrapped(1));
    try testing.expect(!t.rowWrapped(2));
    try t.feed("\r\n"); // scrolls: the wrapped row moves to the top
    try expectScreen(&t, "abcde\nfg\n");
    try testing.expect(t.rowWrapped(0));
    try testing.expect(!t.rowWrapped(1));
    // Reaching the edge and then CR LF is not a wrap.
    try t.feed("xyzuv\r\n");
    try expectScreen(&t, "fg\nxyzuv\n");
    try testing.expect(!t.rowWrapped(0));
    try testing.expect(!t.rowWrapped(1));
    // Erasing to the end of the line ends the logical line there.
    try t.feed("\x1b[1;1Habcdefg");
    try testing.expect(t.rowWrapped(0));
    try t.feed("\x1b[1;3H\x1b[K");
    try testing.expect(!t.rowWrapped(0));
}
