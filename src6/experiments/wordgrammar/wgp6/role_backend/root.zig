//! bz4: the lexical automaton. See DESIGN.md.

const std = @import("std");

pub const bits = @import("bits.zig");
pub const tans = @import("tans.zig");
pub const frame = @import("frame.zig");
pub const Model = @import("model.zig").Model;
pub const Parse = @import("encode.zig").Parse;
pub const Plan = @import("encode.zig").Plan;
pub const encode = @import("encode.zig").encode;
pub const Stats = @import("encode.zig").Stats;
pub const Decoder = @import("decode.zig").Decoder;
pub const Job = @import("decode.zig").Job;
pub const decodeAll = @import("decode.zig").decodeAll;
pub const plan = @import("plan.zig");
pub const Role = @import("classes.zig").Role;
pub const learn = @import("learn.zig");

pub const Options = struct { learn: learn.Options = .{}, plan: plan.Options = .{} };

/// Bytes to frame: learn a parse, fit a plan to it, encode; once with
/// once-seen words spelled in place and once with them defined, keeping the
/// smaller frame. The frame belongs to `gpa`.
pub fn compress(gpa: std.mem.Allocator, data: []const u8, options: Options) ![]u8 {
    var best: ?[]u8 = null;
    errdefer if (best) |bytes| gpa.free(bytes);
    for ([_]bool{ true, false }) |in_place| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var how = options.learn;
        how.once_in_place = in_place;
        const parse = try learn.learn(arena.allocator(), data, how);
        const bytes = (try plan.fit(arena.allocator(), gpa, parse, options.plan)).bytes;
        if (best == null or bytes.len < best.?.len) {
            if (best) |old| gpa.free(old);
            best = bytes;
        } else gpa.free(bytes);
    }
    return best.?;
}

/// Frame to bytes, payloads on `workers` threads.
pub const decompress = decodeAll;

test {
    _ = bits;
    _ = tans;
    _ = @import("binary.zig");
    _ = @import("test.zig");
}
