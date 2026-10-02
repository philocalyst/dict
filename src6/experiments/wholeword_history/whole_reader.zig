//! Bounded research admission and fresh native-v4 decoding for the block study.
const std = @import("std");
const bz4 = @import("bz4");
const Budget = @import("budget.zig").Budget;

const max_raw = 32 * 1024 * 1024;
const max_frame = 64 * 1024 * 1024;

const Ledger = struct {
    header_bytes: usize,
    directory_bytes: usize,
    dictionary_bytes: usize,
    payload_bytes: usize,
    raw_bytes: usize,
    payload_blocks: usize,
    all_blocks: usize,
};

fn admit(bytes: []const u8) !Ledger {
    if (bytes.len > max_frame or !std.mem.startsWith(u8, bytes, bz4.frame.magic)) return error.BadFrame;
    var pos: usize = bz4.frame.magic.len;
    const header_len = try bz4.frame.takeVarint(bytes, &pos);
    if (header_len > 8 * 1024 * 1024 or header_len > bytes.len - pos) return error.BadFrame;
    const header_bytes = pos;
    pos += header_len;
    var dictionary_bytes: usize = header_len;
    var payload_bytes: usize = 0;
    var raw_bytes: usize = 0;
    var all_blocks: usize = 0;
    var payload_blocks: usize = 0;
    var delta_total: usize = 0;
    var defs_total: usize = 0;
    while (try bz4.frame.Block.read(bytes, &pos)) |block| {
        all_blocks += 1;
        if (all_blocks > 512 or block.raw_len > max_raw or block.items > block.raw_len) return error.BadFrame;
        if (block.delta_bytes > 16 * 1024 * 1024 or block.defs > 1_000_000) return error.BadFrame;
        delta_total = std.math.add(usize, delta_total, block.delta_bytes) catch return error.BadFrame;
        defs_total = std.math.add(usize, defs_total, block.defs) catch return error.BadFrame;
        raw_bytes = std.math.add(usize, raw_bytes, block.raw_len) catch return error.BadFrame;
        if (delta_total > 64 * 1024 * 1024 or defs_total > 1_000_000 or raw_bytes > max_raw) return error.BadFrame;
        if (block.items != 0) payload_blocks += 1;
        dictionary_bytes += block.delta.len;
        payload_bytes += block.payload.len;
    }
    if (pos != bytes.len) return error.BadFrame;
    return .{
        .header_bytes = header_bytes,
        .directory_bytes = bytes.len - header_bytes - dictionary_bytes - payload_bytes,
        .dictionary_bytes = dictionary_bytes,
        .payload_bytes = payload_bytes,
        .raw_bytes = raw_bytes,
        .payload_blocks = payload_blocks,
        .all_blocks = all_blocks,
    };
}

fn report(init: std.process.Init, value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("{f}\n", .{std.json.fmt(value, .{})});
    try writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return error.Usage;
    const frame_path = args.next() orelse return error.Usage;
    const other = args.next();
    if (args.next() != null) return error.Usage;
    if (std.mem.eql(u8, mode, "inspect")) {
        if (other != null) return error.Usage;
    } else if (other == null or (!std.mem.eql(u8, mode, "decode") and !std.mem.eql(u8, mode, "verify"))) return error.Usage;

    var budget: Budget = .{ .parent = init.gpa, .limit = 4 * 1024 * 1024 * 1024 };
    const bounded = budget.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, frame_path, bounded, .limited(max_frame));
    defer bounded.free(bytes);
    const ledger = try admit(bytes);
    if (std.mem.eql(u8, mode, "inspect")) {
        try report(init, .{ .frame_bytes = bytes.len, .ledger = ledger });
        return;
    }
    const raw = try bz4.decompress(bounded, bytes, 1);
    defer bounded.free(raw);
    if (raw.len != ledger.raw_bytes) return error.BadFrame;
    const crc = std.hash.Crc32.hash(raw);
    if (std.mem.eql(u8, mode, "verify")) {
        const oracle = try std.Io.Dir.cwd().readFileAlloc(init.io, other.?, bounded, .limited(max_raw));
        defer bounded.free(oracle);
        if (!std.mem.eql(u8, raw, oracle)) return error.NotExact;
    } else try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = other.?, .data = raw });
    try report(init, .{ .frame_bytes = bytes.len, .raw_bytes = raw.len, .raw_crc32 = crc, .verified = std.mem.eql(u8, mode, "verify"), .ledger = ledger, .decoder_peak_allocated_bytes = budget.peak, .decoder_allocation_limit = budget.limit });
}
