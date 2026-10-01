//! Storage-only Bzip4 v4 capture driver for the language-frontier evidence lane.
//!
//! This intentionally performs exactly one encode and one serial decode.  It
//! does not read a clock, run a timing loop, or select a result after seeing a
//! size.  The Python harness hashes the input, parse dump, executable, and
//! resulting frame, and checks the decoded output independently as well.
//!
//! Build from this directory (Zig 0.16):
//!   zig build-exe -O ReleaseFast --dep bz4 -Mroot=capture_frame.zig \
//!     -Mbz4=../../bz4/v3/src/root.zig -femit-bin=bin/capture_frame
//!
//! Usage:
//!   capture_frame raw DATA FRAME [BLOCK_BYTES]
//!   capture_frame saved DATA DUMP FRAME [CLASSES]

const std = @import("std");
const bz4 = @import("bz4");

const Allocator = std.mem.Allocator;

fn readDump(gpa: Allocator, words: []const u32) !bz4.Parse {
    if (words.len < 6 or words[0] != 0x44533442) return error.NotADump;
    const version = words[1];
    if (version != 1 and version != 2) return error.UnsupportedVersion;
    const entries = words[2];
    const blocks = words[3];
    var at: usize = 6;

    const body_off = try gpa.alloc(u32, entries + 1);
    var kids: std.ArrayList(u32) = .empty;
    for (0..entries) |e| {
        body_off[e] = @intCast(kids.items.len);
        const arity = if (version == 1) 2 else blk: {
            if (at >= words.len) return error.TruncatedDump;
            at += 1;
            break :blk words[at - 1];
        };
        if (arity < 2 or at + arity > words.len) return error.TruncatedDump;
        try kids.appendSlice(gpa, words[at..][0..arity]);
        at += arity;
    }
    body_off[entries] = @intCast(kids.items.len);

    const block_off = try gpa.alloc(u32, blocks + 1);
    var toks: std.ArrayList(u32) = .empty;
    for (0..blocks) |b| {
        if (at >= words.len) return error.TruncatedDump;
        block_off[b] = @intCast(toks.items.len);
        const n = words[at];
        at += 1;
        if (at + n > words.len) return error.TruncatedDump;
        try toks.appendSlice(gpa, words[at..][0..n]);
        at += n;
    }
    block_off[blocks] = @intCast(toks.items.len);
    if (at != words.len) return error.TrailingDump;
    return .{ .body_off = body_off, .kids = kids.items, .block_off = block_off, .toks = toks.items };
}

const Breakdown = struct {
    header: usize,
    delta: usize,
    payload: usize,
    framing: usize,
    blocks: usize,
};

fn breakdown(bytes: []const u8) !Breakdown {
    if (bytes.len < bz4.frame.magic.len or !std.mem.eql(u8, bytes[0..bz4.frame.magic.len], bz4.frame.magic)) {
        return error.BadFrame;
    }
    var pos: usize = bz4.frame.magic.len;
    const header = try bz4.frame.takeVarint(bytes, &pos);
    if (@as(usize, header) > bytes.len - pos) return error.BadFrame;
    pos += header;
    var delta: usize = 0;
    var payload: usize = 0;
    var blocks: usize = 0;
    while (try bz4.frame.Block.read(bytes, &pos)) |block| {
        delta += block.delta.len;
        payload += block.payload.len;
        blocks += 1;
    }
    if (pos != bytes.len) return error.BadFrame;
    return .{
        .header = header,
        .delta = delta,
        .payload = payload,
        .framing = bytes.len - header - delta - payload,
        .blocks = blocks,
    };
}

fn usage() error{Usage} {
    std.debug.print(
        "usage: capture_frame raw DATA FRAME [BLOCK_BYTES] | saved DATA DUMP FRAME [CLASSES]\n",
        .{},
    );
    return error.Usage;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return usage();
    const data_path = args.next() orelse return usage();
    const second_path = args.next() orelse return usage();
    const frame_path = if (std.mem.eql(u8, mode, "saved")) args.next() orelse return usage() else second_path;
    const extra = if (std.mem.eql(u8, mode, "saved")) args.next() else args.next();
    const cwd = std.Io.Dir.cwd();

    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    const data = try cwd.readFileAlloc(init.io, data_path, scratch, .limited(1 << 31));

    var frame_bytes: []u8 = undefined;
    var classes: u16 = 0;
    var block_bytes: usize = 0;
    if (std.mem.eql(u8, mode, "raw")) {
        block_bytes = if (extra) |arg| try std.fmt.parseUnsigned(usize, arg, 10) else 65536;
        frame_bytes = try bz4.compress(init.gpa, data, .{ .learn = .{ .block = block_bytes } });
    } else if (std.mem.eql(u8, mode, "saved")) {
        const dump_bytes = try cwd.readFileAllocOptions(init.io, second_path, scratch, .limited(1 << 31), .of(u32), null);
        const parsed = try readDump(scratch, std.mem.bytesAsSlice(u32, dump_bytes));
        classes = if (extra) |arg| try std.fmt.parseUnsigned(u16, arg, 10) else 0;
        const fitted = try bz4.plan.fit(scratch, init.gpa, parsed, .{ .classes = classes });
        frame_bytes = fitted.bytes;
        classes = fitted.options.classes;
    } else {
        return usage();
    }
    defer init.gpa.free(frame_bytes);

    const out = try bz4.decodeAll(init.gpa, frame_bytes, 1);
    defer init.gpa.free(out);
    if (!std.mem.eql(u8, out, data)) return error.RoundTripMismatch;
    try cwd.writeFile(init.io, .{ .sub_path = frame_path, .data = frame_bytes });

    const b = try breakdown(frame_bytes);
    std.debug.print(
        "ok\tmode={s}\tclasses={d}\tblock_bytes={d}\ttotal={d}\theader={d}\tdelta={d}\tpayload={d}\tframing={d}\tblocks={d}\traw_len={d}\n",
        .{ mode, classes, block_bytes, frame_bytes.len, b.header, b.delta, b.payload, b.framing, b.blocks, data.len },
    );
}
