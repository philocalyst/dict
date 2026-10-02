//! lab DATA DUMP [--log N] [--flat] [--hoist]
//!
//! Encodes the parse stored in a B4SD dump (v1 or v2) with the baseline
//! planner, decodes it back, checks it against DATA and reports real bytes.

const std = @import("std");
const bz4 = @import("bz4");

pub fn readDump(gpa: std.mem.Allocator, words: []const u32) !bz4.Parse {
    if (words.len < 6 or words[0] != 0x44533442) return error.NotADump;
    const version = words[1];
    const entries = words[2];
    const blocks = words[3];
    var at: usize = 6;

    const body_off = try gpa.alloc(u32, entries + 1);
    var kids: std.ArrayList(u32) = .empty;
    for (0..entries) |e| {
        body_off[e] = @intCast(kids.items.len);
        const arity = if (version == 1) 2 else blk: {
            at += 1;
            break :blk words[at - 1];
        };
        try kids.appendSlice(gpa, words[at..][0..arity]);
        at += arity;
    }
    body_off[entries] = @intCast(kids.items.len);

    const block_off = try gpa.alloc(u32, blocks + 1);
    var toks: std.ArrayList(u32) = .empty;
    for (0..blocks) |b| {
        block_off[b] = @intCast(toks.items.len);
        try toks.appendSlice(gpa, words[at + 1 ..][0..words[at]]);
        at += 1 + words[at];
    }
    block_off[blocks] = @intCast(toks.items.len);
    return .{ .body_off = body_off, .kids = kids.items, .block_off = block_off, .toks = toks.items };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const data_path = args.next() orelse return error.Usage;
    const dump_path = args.next() orelse return error.Usage;
    var options: bz4.plan.Options = .{};
    var show_stats = false;
    var workers: usize = 4;
    var prunes: usize = 0;
    var bits_path: ?[]const u8 = null;
    var trace_at: ?usize = null;
    var merge: usize = 1;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--trace")) trace_at = try std.fmt.parseUnsigned(usize, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--bits")) bits_path = args.next() orelse return error.Usage;
        if (std.mem.eql(u8, arg, "--log")) options.log = try std.fmt.parseUnsigned(u8, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--classes")) options.classes = try std.fmt.parseUnsigned(u16, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--sweeps")) options.sweeps = try std.fmt.parseUnsigned(usize, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--slack")) options.table_slack = try std.fmt.parseFloat(f64, args.next() orelse return error.Usage);
        if (std.mem.eql(u8, arg, "--prune")) prunes = try std.fmt.parseUnsigned(usize, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--direct")) options.direct = try std.fmt.parseUnsigned(u32, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--merge")) merge = try std.fmt.parseUnsigned(usize, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--ring")) options.ring = try std.fmt.parseUnsigned(u8, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--leader")) options.leader = try std.fmt.parseUnsigned(u32, args.next() orelse return error.Usage, 10);
        if (std.mem.eql(u8, arg, "--rawbytes")) options.alias = false;
        if (std.mem.eql(u8, arg, "--hoist")) options.hoist = true;
        if (std.mem.eql(u8, arg, "--stats")) show_stats = true;
        if (std.mem.eql(u8, arg, "--workers")) workers = try std.fmt.parseUnsigned(usize, args.next() orelse return error.Usage, 10);
    }

    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(init.io, data_path, gpa, .limited(1 << 30));
    const dump = try cwd.readFileAllocOptions(init.io, dump_path, gpa, .limited(1 << 31), .of(u32), null);
    var dumped = try readDump(gpa, std.mem.bytesAsSlice(u32, dump));
    if (merge > 1) {
        // Every `merge` blocks of the dump become one.
        var offs: std.ArrayList(u32) = .empty;
        var b: usize = 0;
        while (b < dumped.blocks()) : (b += merge) try offs.append(gpa, dumped.block_off[b]);
        try offs.append(gpa, @intCast(dumped.toks.len));
        dumped.block_off = offs.items;
    }

    const t0 = std.Io.Clock.awake.now(init.io).nanoseconds;
    var parse = dumped;
    for (0..prunes) |round| {
        // Price every entry with a real encode, dissolve what does not pay.
        var pricing = options;
        pricing.alias = false;
        var trial = try bz4.plan.baseline(gpa, parse, pricing);
        var prices: bz4.Stats = .{ .entry_bits = try gpa.alloc(f64, trial.parse.entries()), .entry_uses = try gpa.alloc(u32, trial.parse.entries()) };
        @memset(prices.entry_bits.?, 0);
        @memset(prices.entry_uses.?, 0);
        const bytes = try bz4.encode(gpa, &trial, &prices);
        const before = parse.entries();
        parse = try bz4.plan.prune(gpa, parse, prices.entry_bits.?, prices.entry_uses.?, 10);
        std.debug.print("  prune {d}: {d} bytes, entries {d} -> {d}\n", .{ round, bytes.len, before, parse.entries() });
        if (parse.entries() == before) break;
    }
    // Let the planner settle the class count and learn which uses the past
    // takes over; then encode once more to collect the statistics.
    const fitted = try bz4.plan.fit(gpa, init.gpa, parse, options);
    init.gpa.free(fitted.bytes);
    options = fitted.options;
    var plan = try bz4.plan.baseline(gpa, parse, options);
    var stats: bz4.Stats = .{};
    if (bits_path != null) stats.token_bits = try gpa.alloc(f64, plan.parse.toks.len);
    const packed_bytes = try bz4.encode(gpa, &plan, &stats);
    if (bits_path) |path| {
        // One f32 per input byte: the token's real bits spread over its bytes.
        const lengths = try plan.parse.lengths(gpa);
        const per_byte = try gpa.alloc(f32, data.len);
        var at: usize = 0;
        for (plan.parse.toks, stats.token_bits.?) |tok, token_bits| {
            const n: usize = if (tok < 256) 1 else lengths[tok - 256];
            @memset(per_byte[at..][0..n], @floatCast(token_bits / @as(f64, @floatFromInt(n))));
            at += n;
        }
        try cwd.writeFile(init.io, .{ .sub_path = path, .data = std.mem.sliceAsBytes(per_byte) });

        if (trace_at) |from| {
            var byte_at: usize = 0;
            for (plan.parse.toks, stats.token_bits.?, 0..) |tok, token_bits, i| {
                const n: usize = if (tok < 256) 1 else lengths[tok - 256];
                if (i >= from and i < from + 120) std.debug.print("{d:6.1} \"{f}\"\n", .{ token_bits, std.zig.fmtString(data[byte_at..][0..@min(n, 70)]) });
                byte_at += n;
            }
        }
        // The most expensive tokens that contain markup, with their text.
        const Sum = struct { bits: f64 = 0, uses: u32 = 0, at: u32 = 0, len: u32 = 0 };
        const sums = try gpa.alloc(Sum, 256 + plan.parse.entries());
        @memset(sums, .{});
        at = 0;
        for (plan.parse.toks, stats.token_bits.?) |tok, token_bits| {
            const n: u32 = if (tok < 256) 1 else lengths[tok - 256];
            sums[tok].bits += token_bits;
            sums[tok].uses += 1;
            sums[tok].at = @intCast(at);
            sums[tok].len = n;
            at += n;
        }
        std.mem.sort(Sum, sums, {}, struct {
            fn more(_: void, a: Sum, b: Sum) bool {
                return a.bits > b.bits;
            }
        }.more);
        var shown: usize = 0;
        for (sums) |sum| {
            const text = data[sum.at..][0..sum.len];
            if (std.mem.indexOfScalar(u8, text, '<') == null) continue;
            std.debug.print("  {d:>8.0} B {d:>7} uses {d:>6.2} bits  \"{f}\"\n", .{ sum.bits / 8, sum.uses, sum.bits / @as(f64, @floatFromInt(sum.uses)), std.zig.fmtString(text[0..@min(text.len, 110)]) });
            shown += 1;
            if (shown == 40) break;
        }
    }
    const t1 = std.Io.Clock.awake.now(init.io).nanoseconds;

    var speed: [2]f64 = undefined;
    for (&speed, [_]usize{ 1, workers }) |*mbps, n| {
        var best: i96 = std.math.maxInt(i96);
        for (0..7) |_| {
            const a = std.Io.Clock.awake.now(init.io).nanoseconds;
            const out = try bz4.decodeAll(init.gpa, packed_bytes, n);
            const b = std.Io.Clock.awake.now(init.io).nanoseconds;
            if (!std.mem.eql(u8, out, data)) return error.RoundTripMismatch;
            init.gpa.free(out);
            best = @min(best, b - a);
        }
        mbps.* = @as(f64, @floatFromInt(data.len)) / 1e6 / (@as(f64, @floatFromInt(best)) / 1e9);
    }

    if (show_stats) {
        var cells: usize = 0;
        var histogram: [14]u32 = @splat(0);
        for (plan.model.logs) |row_log| {
            cells += @as(usize, 1) << @intCast(row_log);
            histogram[row_log] += 1;
        }
        std.debug.print("  rows={d} cells={d} KiB, rows by log 5..13: {any}\n", .{ plan.model.rows, cells * 8 / 1024, histogram[5..] });
        // Where decode time goes: model + deltas (serial) versus payloads.
        const a = std.Io.Clock.awake.now(init.io).nanoseconds;
        var d: bz4.Decoder = try .init(init.gpa, packed_bytes);
        defer d.deinit();
        const b = std.Io.Clock.awake.now(init.io).nanoseconds;
        var jobs: std.ArrayList(bz4.Job) = .empty;
        while (try d.next()) |job| try jobs.append(gpa, job);
        const c = std.Io.Clock.awake.now(init.io).nanoseconds;
        const out = try gpa.alloc(u8, data.len);
        var at: usize = 0;
        var items: usize = 0;
        for (jobs.items) |job| {
            try d.run(job, out[at..][0..job.raw_len]);
            at += job.raw_len;
            items += job.items;
        }
        const e = std.Io.Clock.awake.now(init.io).nanoseconds;
        std.debug.print("  init_ms={d:.2} deltas_ms={d:.2} payloads_ms={d:.2} ({d:.1} ns/token, {d} tokens)\n", .{
            @as(f64, @floatFromInt(b - a)) / 1e6,                                    @as(f64, @floatFromInt(c - b)) / 1e6,
            @as(f64, @floatFromInt(e - c)) / 1e6,                                    @as(f64, @floatFromInt(e - c)) / @as(f64, @floatFromInt(items)),
            items,
        });
    }

    var pos: usize = bz4.frame.magic.len;
    const header = try bz4.frame.takeVarint(packed_bytes, &pos);
    pos += header;
    var delta: usize = 0;
    var payload: usize = 0;
    var block_count: usize = 0;
    while (try bz4.frame.Block.read(packed_bytes, &pos)) |block| {
        delta += block.delta.len;
        payload += block.payload.len;
        block_count += 1;
    }
    const framing = packed_bytes.len - header - delta - payload;
    std.debug.print(
        "{s}\tclasses={d}\ttotal={d}\theader={d}\tdelta={d}\tpayload={d}\tframing={d}\tbuckets={d}\tblocks={d}\tencode_ms={d:.0}\tdecode_MBps={d:.0}\tx{d}={d:.0}\n",
        .{
            std.fs.path.basename(dump_path), options.classes, packed_bytes.len, header,                                                delta,
            payload,                         framing,          plan.model.widths.len,                                 block_count,
            @as(f64, @floatFromInt(t1 - t0)) / 1e6, speed[0],
            workers,                         speed[1],
        },
    );
    if (show_stats) inline for (.{ "delta", "payload" }) |stream| {
        for (std.enums.values(bz4.Stats.Kind)) |kind| {
            const line = @field(stats, stream).get(kind);
            if (line.events == 0) continue;
            const n: f64 = @floatFromInt(line.events);
            std.debug.print("  {s:8} {s:10} events={d:9} coded={d:6.2} raw={d:6.2} bits/event  bytes={d:.0}\n", .{
                stream,                   @tagName(kind),                                         line.events,
                line.coded_bits / n,      @as(f64, @floatFromInt(line.raw_bits)) / n,
                (line.coded_bits + @as(f64, @floatFromInt(line.raw_bits))) / 8,
            });
        }
    };
}
