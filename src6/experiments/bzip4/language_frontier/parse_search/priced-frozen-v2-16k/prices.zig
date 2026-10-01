//! Expose actual native use prices after the same measured-bucket refit as fit.
const std = @import("std");
const bz4 = @import("bz4");
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse return error.Usage;
    const classes = try std.fmt.parseUnsigned(u16, args.next() orelse return error.Usage, 10);
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAllocOptions(init.io, path, a, .limited(1 << 28), .of(u32), null);
    const words = std.mem.bytesAsSlice(u32, bytes);
    if (words.len < 6 or words[0] != 0x44533442 or words[1] != 2) return error.BadDump;
    const n = words[2]; const blocks = words[3]; var at: usize = 6;
    const off = try a.alloc(u32, n+1);
    var kids: std.ArrayList(u32) = .empty;
    for (0..n) |e| {
        off[e] = @intCast(kids.items.len);
        if (at >= words.len) return error.BadDump;
        const arity = words[at]; at += 1;
        if (arity < 2 or arity > 4096 or arity > words.len-at) return error.BadDump;
        for (words[at..][0..arity]) |t| if (t >= 256+e) return error.NonCausal;
        try kids.appendSlice(a, words[at..][0..arity]); at += arity;
    }
    off[n] = @intCast(kids.items.len);
    const boff = try a.alloc(u32, blocks+1);
    var toks: std.ArrayList(u32) = .empty;
    for (0..blocks) |b| {
        boff[b] = @intCast(toks.items.len);
        if (at >= words.len) return error.BadDump;
        const count = words[at]; at += 1;
        if (count > words.len-at) return error.BadDump;
        for (words[at..][0..count]) |t| if (t >= 256+n) return error.BadToken;
        try toks.appendSlice(a, words[at..][0..count]); at += count;
    }
    boff[blocks] = @intCast(toks.items.len);
    if (at != words.len) return error.BadDump;
    const parse: bz4.Parse = .{ .body_off=off, .kids=kids.items, .block_off=boff, .toks=toks.items };
    var first = try bz4.plan.baseline(a, parse, .{ .classes=classes });
    var measured: bz4.Stats = .{ .entry_bits=try a.alloc(f64,first.parse.entries()), .entry_uses=try a.alloc(u32,first.parse.entries()) };
    @memset(measured.entry_bits.?,0); @memset(measured.entry_uses.?,0);
    init.gpa.free(try bz4.encode(init.gpa,&first,&measured));
    var second = try bz4.plan.baseline(a,parse,.{ .classes=classes, .bucket_uses=measured.entry_uses });
    @memset(measured.entry_bits.?,0); @memset(measured.entry_uses.?,0);
    init.gpa.free(try bz4.encode(init.gpa,&second,&measured));
    const body_row: u16 = 2*classes;
    const mass = second.model.norm[second.model.cell(body_row,0)];
    const literal = 8 + if (mass != 0) bz4.tans.cost(mass,second.model.logs[body_row]) else @as(f64,@floatFromInt(second.model.logs[body_row]));
    std.debug.print("literal\t{d}\n", .{literal});
    for (measured.entry_bits.?, measured.entry_uses.?,0..) |bits,uses,e| {
        const body = second.parse.body(e);
        const byte: i32 = if (e >= n and body.len==1 and body[0]<256) @intCast(body[0]) else -1;
        std.debug.print("price\t{d}\t{d}\t{d}\t{d}\n", .{e, bits, uses, byte});
    }
}
