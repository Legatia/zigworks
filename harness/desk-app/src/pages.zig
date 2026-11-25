//! The app's own pages, shown while there's no desk to show.
const std = @import("std");

pub const Screen = enum { setup, down, connecting };
