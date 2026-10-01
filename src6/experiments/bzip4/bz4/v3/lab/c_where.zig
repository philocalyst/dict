//! c_where DATA DUMP — est: where the bits of a parse go, by the XML element
//! the content sits in. Use cost is static order 0 over the payload; a first
//! use is charged its DEF symbol plus its spelling (order 0 over bodies,
//! nested definitions included), all to the field of that first use.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ctx = @import("c_ctx.zig");

const Field = struct { uses: u64 = 0, use_bits: f64 = 0, firsts: u64 = 0, spell_bits: f64 = 0, bytes: u64 = 0 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const data_path = args.next() orelse return error.Usage;
    const dump_path = args.next() orelse return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(init.io, data_path, gpa, .limited(1 << 30));
    const dump = try cwd.readFileAllocOptions(init.io, dump_path, gpa, .limited(1 << 31), .of(u32), null);
    const parse = try ctx.readDump(gpa, std.mem.bytesAsSlice(u32, dump));
    const entries = parse.body_off.len - 1;

    // Payload use counts (first use excluded) and body use counts.
    const uses = try gpa.alloc(u32, 256 + entries);
    const body_uses = try gpa.alloc(u32, 256 + entries);
    const seen = try gpa.alloc(bool, 256 + entries);
    @memset(uses, 0);
    @memset(body_uses, 0);
    @memset(seen, false);
    var total: f64 = 0;
    var firsts: f64 = 0;
    // Bodies: an entry's child is a nested DEF when that child was not seen before.
    const defined = try gpa.alloc(bool, 256 + entries);
    @memset(defined, false);
    var body_total: f64 = 0;
    var body_firsts: f64 = 0;
    const Walk = struct {
        parse: ctx.Parse,
        defined: []bool,
        body_uses: []u32,
        total: *f64,
        firsts: *f64,
        fn define(w: @This(), e: u32) void {
            w.defined[e] = true;
            for (w.parse.kids[w.parse.body_off[e - 256]..w.parse.body_off[e - 256 + 1]]) |kid| {
                w.total.* += 1;
                if (kid >= 256 and !w.defined[kid]) {
                    w.firsts.* += 1;
                    w.define(kid);
                } else w.body_uses[kid] += 1;
            }
        }
    };
    const walk: Walk = .{ .parse = parse, .defined = defined, .body_uses = body_uses, .total = &body_total, .firsts = &body_firsts };
    for (parse.toks) |t| {
        total += 1;
        if (t >= 256 and !defined[t]) {
            firsts += 1;
            walk.define(t);
        } else uses[t] += 1;
    }

    // Spelling cost of each entry: its children's order-0 body prices, nested firsts included.
    const spell = try gpa.alloc(f64, 256 + entries);
    @memset(spell, 0);
    @memset(defined, false);
    const Price = struct {
        parse: ctx.Parse,
        defined: []bool,
        body_uses: []u32,
        spell: []f64,
        total: f64,
        firsts: f64,
        fn define(w: @This(), e: u32) f64 {
            w.defined[e] = true;
            var bits: f64 = 3; // arity + name, roughly what v3 pays
            for (w.parse.kids[w.parse.body_off[e - 256]..w.parse.body_off[e - 256 + 1]]) |kid| {
                if (kid >= 256 and !w.defined[kid]) {
                    bits += -std.math.log2(w.firsts / w.total) + w.define(kid);
                } else bits += -std.math.log2(@as(f64, @floatFromInt(w.body_uses[kid])) / w.total);
            }
            w.spell[e] = bits;
            return bits;
        }
    };
    const price: Price = .{ .parse = parse, .defined = defined, .body_uses = body_uses, .spell = spell, .total = body_total, .firsts = body_firsts };

    const lengths = try gpa.alloc(u32, 256 + entries);
    @memset(lengths[0..256], 1);
    {
        // lengths by expansion in definition order is not available; compute recursively.
        @memset(lengths[256..], 0);
        const Len = struct {
            parse: ctx.Parse,
            lengths: []u32,
            fn of(w: @This(), t: u32) u32 {
                if (w.lengths[t] != 0) return w.lengths[t];
                var n: u32 = 0;
                for (w.parse.kids[w.parse.body_off[t - 256]..w.parse.body_off[t - 256 + 1]]) |kid| n += w.of(kid);
                w.lengths[t] = n;
                return n;
            }
        };
        const len: Len = .{ .parse = parse, .lengths = lengths };
        for (256..256 + entries) |t| _ = len.of(@intCast(t));
    }

    var fields: std.StringArrayHashMapUnmanaged(Field) = .empty;
    @memset(seen, false);
    var pos: usize = 0;
    var field: []const u8 = "(start)";
    var scan: usize = 0;
    for (parse.toks) |t| {
        // Advance the element tracker to this token's first byte.
        while (scan < pos) : (scan += 1) if (data[scan] == '<') {
            const end = std.mem.indexOfAnyPos(u8, data, scan, " >/\n") orelse data.len;
            const close = scan + 1 < data.len and data[scan + 1] == '/';
            field = if (close) "(between)" else data[scan + 1 .. @max(end, scan + 1)];
            if (!close and end == scan + 1) field = "(between)";
        };
        const text = data[pos..][0..lengths[t]];
        const markup = std.mem.indexOfAny(u8, text, "<>") != null;
        const slot = try fields.getOrPutValue(gpa, if (markup) "(markup)" else field, .{});
        const f = slot.value_ptr;
        f.bytes += text.len;
        if (t >= 256 and !defined[t]) {
            f.firsts += 1;
            f.use_bits += -std.math.log2(firsts / total);
            f.spell_bits += price.define(t);
        } else {
            f.uses += 1;
            f.use_bits += -std.math.log2(@as(f64, @floatFromInt(uses[t])) / total);
        }
        seen[t] = true;
        pos += text.len;
    }

    const Sort = struct {
        values: []const Field,
        pub fn lessThan(s: @This(), a: usize, b: usize) bool {
            return s.values[a].use_bits + s.values[a].spell_bits > s.values[b].use_bits + s.values[b].spell_bits;
        }
    };
    fields.sort(Sort{ .values = fields.values() });
    var sum: f64 = 0;
    for (fields.values()) |f| sum += f.use_bits + f.spell_bits;
    std.debug.print("{s:<24} {s:>9} {s:>8} {s:>8} {s:>10} {s:>10} {s:>6} {s:>7}\n", .{ "field", "bytes", "uses", "firsts", "use_B", "spell_B", "share", "bpc" });
    for (fields.keys(), fields.values(), 0..) |name, f, i| {
        if (i >= 24) break;
        std.debug.print("{s:<24} {d:>9} {d:>8} {d:>8} {d:>10.0} {d:>10.0} {d:>5.1}% {d:>7.3}\n", .{
            name[0..@min(name.len, 24)],            f.bytes,
            f.uses,                                 f.firsts,
            f.use_bits / 8,                         f.spell_bits / 8,
            100 * (f.use_bits + f.spell_bits) / sum, (f.use_bits + f.spell_bits) / @as(f64, @floatFromInt(@max(f.bytes, 1))),
        });
    }
    std.debug.print("total est {d:.0} bytes\n", .{sum / 8});
}
