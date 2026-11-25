//! The harness commands the app runs, through the binary desk.json names.
const std = @import("std");

pub const Command = enum { run, stop, autostart_on, autostart_off, autostart_query };
