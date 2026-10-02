//! Development-only adapter for the unchanged native bz4 v4 automaton.
//! Parse and price interchange are private encoder artifacts, never archives.
const std = @import("std");
const bz4 = @import("bz4");

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn takeArray(gpa: std.mem.Allocator, bytes: []const u8, at: *usize) ![]u32 {
    if (bytes.len - at.* < 4) return error.BadParse;
    const count = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
    at.* += 4;
    if (count > (bytes.len - at.*) / 4) return error.BadParse;
    const out = try gpa.alloc(u32, count);
    for (out) |*x| {
        x.* = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
        at.* += 4;
    }
    return out;
}

fn readParse(gpa: std.mem.Allocator, bytes: []const u8) !bz4.Parse {
    if (!std.mem.startsWith(u8, bytes, "P6P1")) return error.BadParse;
    var at: usize = 4;
    const body_off = try takeArray(gpa, bytes, &at);
    const kids = try takeArray(gpa, bytes, &at);
    const block_off = try takeArray(gpa, bytes, &at);
    const toks = try takeArray(gpa, bytes, &at);
    if (at != bytes.len or body_off.len == 0 or block_off.len == 0) return error.BadParse;
    if (body_off[0] != 0 or body_off[body_off.len - 1] != kids.len or block_off[0] != 0 or block_off[block_off.len - 1] != toks.len) return error.BadParse;
    for (body_off[0 .. body_off.len - 1], body_off[1..]) |a, b| if (a >= b or b > kids.len) return error.BadParse;
    for (block_off[0 .. block_off.len - 1], block_off[1..]) |a, b| if (a > b or b > toks.len) return error.BadParse;
    const lengths = try gpa.alloc(u64, body_off.len - 1);
    defer gpa.free(lengths);
    for (body_off[0 .. body_off.len - 1], body_off[1..], 0..) |a, b, entry| {
        var length: u64 = 0;
        var preceding: u64 = 0;
        for (kids[a..b], 0..) |kid, index| {
            if (kid >= bz4.Parse.cut) {
                if (index == 0 or kids[a + index - 1] >= bz4.Parse.cut or kid == bz4.Parse.cut) return error.BadParse;
                const retained = kid - bz4.Parse.cut;
                if (retained > preceding) return error.BadParse;
                length = length - preceding + retained;
                preceding = retained;
            } else {
                if (kid >= 256 and kid - 256 >= entry) return error.BadParse;
                preceding = if (kid < 256) 1 else lengths[kid - 256];
                length += preceding;
                if (length > 64 * 1024 * 1024) return error.BadParse;
            }
        }
        lengths[entry] = length;
    }
    var raw_length: u64 = 0;
    for (toks) |tok| {
        if (tok >= 256 and tok - 256 >= body_off.len - 1) return error.BadParse;
        raw_length += if (tok < 256) 1 else lengths[tok - 256];
        if (raw_length > 64 * 1024 * 1024) return error.BadParse;
    }
    return .{ .body_off = body_off, .kids = kids, .block_off = block_off, .toks = toks };
}

fn readRole(gpa: std.mem.Allocator, bytes: []const u8, entries: usize) !bz4.Role {
    if (!std.mem.startsWith(u8, bytes, "P6R1") or bytes.len < 8) return error.BadRole;
    const types = std.mem.readInt(u32, bytes[4..8], .little);
    if (types > 500000 or entries > 500000) return error.RoleBudget;
    var at: usize = 8;
    const kinds = try takeArray(gpa, bytes, &at);
    const terminal = try takeArray(gpa, bytes, &at);
    const context_off = try takeArray(gpa, bytes, &at);
    const context_tokens = try takeArray(gpa, bytes, &at);
    if (at != bytes.len or kinds.len != entries or terminal.len != entries or context_off.len == 0 or context_tokens.len > 4000000) return error.BadRole;
    if (context_off[0] != 0 or context_off[context_off.len - 1] != context_tokens.len) return error.BadRole;
    for (context_off[0 .. context_off.len - 1], context_off[1..]) |a, b| if (a > b or b > context_tokens.len) return error.BadRole;
    for (kinds, terminal) |kind, last| {
        if (kind > 2 or (last != std.math.maxInt(u32) and last >= types)) return error.BadRole;
        if (kind == 0 and last != std.math.maxInt(u32)) return error.BadRole;
    }
    for (context_tokens) |token| if (token < 256 or token - 256 >= types) return error.BadRole;
    return .{ .kinds = kinds, .terminal = terminal, .context_off = context_off, .context_tokens = context_tokens, .types = types };
}

const Ledger = struct {
    header_bytes: usize,
    directory_bytes: usize,
    model_dictionary_bytes: usize,
    payload_bytes: usize,
    raw_bytes: usize,
    blocks: usize,
    block_raw_lengths: std.ArrayList(usize),
};

fn ledger(gpa: std.mem.Allocator, bytes: []const u8) !Ledger {
    if (!std.mem.startsWith(u8, bytes, bz4.frame.magic)) return error.BadFrame;
    var pos = bz4.frame.magic.len;
    const header_len = try bz4.frame.takeVarint(bytes, &pos);
    if (header_len > bytes.len - pos) return error.BadFrame;
    const header_bytes = pos;
    pos += header_len;
    var model_dictionary_bytes: usize = header_len;
    var payload_bytes: usize = 0;
    var raw_bytes: usize = 0;
    var blocks: usize = 0;
    var lengths: std.ArrayList(usize) = .empty;
    errdefer lengths.deinit(gpa);
    while (try bz4.frame.Block.read(bytes, &pos)) |b| {
        model_dictionary_bytes += b.delta.len;
        payload_bytes += b.payload.len;
        raw_bytes += b.raw_len;
        if (b.items != 0) {
            blocks += 1;
            try lengths.append(gpa, b.raw_len);
        }
    }
    if (pos != bytes.len) return error.BadFrame;
    return .{ .header_bytes = header_bytes, .directory_bytes = bytes.len - header_bytes - model_dictionary_bytes - payload_bytes, .model_dictionary_bytes = model_dictionary_bytes, .payload_bytes = payload_bytes, .raw_bytes = raw_bytes, .blocks = blocks, .block_raw_lengths = lengths };
}

fn writeLedger(init: std.process.Init, stats: Ledger, codec_ns: i96, frame_bytes: usize, classes: ?u16) !void {
    try json(init, .{ .codec_ns = codec_ns, .frame_bytes = frame_bytes, .classes = classes, .header_bytes = stats.header_bytes, .directory_bytes = stats.directory_bytes, .model_dictionary_bytes = stats.model_dictionary_bytes, .payload_bytes = stats.payload_bytes, .raw_bytes = stats.raw_bytes, .blocks = stats.blocks, .block_raw_lengths = stats.block_raw_lengths.items });
}

fn json(init: std.process.Init, value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("{f}\n", .{std.json.fmt(value, .{})});
    try writer.interface.flush();
}

fn varCost(model: bz4.Model, row: u16, sym: u16) f64 {
    const frequency = model.norm[model.cell(row, sym)];
    return @log2(@as(f64, @floatFromInt(@as(u32, 1) << @intCast(model.logs[row]))) / (@as(f64, @floatFromInt(frequency)) + 0.25));
}

fn appendInt(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

fn priceCells(entries: usize, classes: u16) !usize {
    if (classes == 0 or classes > 128) return error.PriceBudget;
    const tokens = std.math.add(usize, entries, 256) catch return error.PriceBudget;
    const cells = std.math.mul(usize, tokens, @as(usize, classes) + 1) catch return error.PriceBudget;
    if (cells > 20_000_000) return error.PriceBudget;
    const bytes = std.math.add(usize, std.math.mul(usize, cells, 8) catch return error.PriceBudget, 12) catch return error.PriceBudget;
    if (bytes > 192 * 1024 * 1024) return error.PriceBudget;
    return cells;
}

fn priceFile(gpa: std.mem.Allocator, input: bz4.Parse, plan: *bz4.Plan, classes: u16) ![]u8 {
    const cells = try priceCells(input.entries(), classes);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.ensureTotalCapacityPrecise(gpa, 12 + cells * 8);
    try bytes.appendSlice(gpa, "P6C1");
    try appendInt(&bytes, gpa, @intCast(256 + input.entries()));
    try appendInt(&bytes, gpa, classes);
    var aliases: [256]u32 = undefined;
    for (&aliases, 0..) |*alias, byte| alias.* = @intCast(byte);
    for (input.entries()..plan.parse.entries()) |e| {
        const body = plan.parse.body(e);
        if (body.len == 1 and body[0] < 256) aliases[body[0]] = @intCast(256 + e);
    }
    const model = plan.model;
    for (0..256 + input.entries()) |original| {
        const token: u32 = if (original < 256) aliases[original] else @intCast(original);
        const sym: u16 = if (token < 256) 0 else plan.bucket[token - 256];
        for (0..classes + 1) |state| {
            var row: u16 = @intCast(if (state == classes) 2 * classes else state);
            var price: f64 = 0;
            const via = plan.via[sym];
            if (via != 0) {
                price += varCost(model, row, via);
                row = model.next[model.cell(row, via)];
            }
            price += varCost(model, row, sym) + @as(f64, @floatFromInt(model.widths[sym]));
            try appendInt(&bytes, gpa, @bitCast(@as(f32, @floatCast(@max(0, price)))));
            try appendInt(&bytes, gpa, model.next[model.cell(row, sym)]);
        }
    }
    return bytes.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const operation = args.next() orelse return error.Usage;
    const input_path = args.next() orelse return error.Usage;
    const output_path = args.next() orelse return error.Usage;
    const parameter = if (args.next()) |arg| try std.fmt.parseUnsigned(u32, arg, 10) else 0;
    const classes: u16 = if (std.mem.eql(u8, operation, "compile") or std.mem.eql(u8, operation, "prices")) std.math.cast(u16, parameter) orelse return error.BadClasses else 0;
    if (classes != 0 and (classes > 128 or !std.math.isPowerOfTwo(classes))) return error.BadClasses;
    const price_path = args.next();
    if (args.next() != null) return error.Usage;
    const byte_limit: usize = if (std.mem.eql(u8, operation, "original")) 64 * 1024 * 1024 else 512 * 1024 * 1024;
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, init.gpa, .limited(byte_limit));
    defer init.gpa.free(input);
    const start = now(init.io);
    if (std.mem.eql(u8, operation, "original")) {
        if (price_path != null or parameter == 0 or parameter > 65536) return error.BadBlock;
        const bytes = try bz4.compress(init.gpa, input, .{ .learn = .{ .block = parameter } });
        defer init.gpa.free(bytes);
        const duration = now(init.io) - start;
        var stats = try ledger(init.gpa, bytes);
        defer stats.block_raw_lengths.deinit(init.gpa);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = bytes });
        try writeLedger(init, stats, duration, bytes.len, null);
    } else if (std.mem.eql(u8, operation, "compile") or std.mem.eql(u8, operation, "prices")) {
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        const parse = try readParse(arena.allocator(), input);
        const role_path = try std.fmt.allocPrint(arena.allocator(), "{s}.roles", .{input_path});
        const role_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, role_path, arena.allocator(), .limited(32 * 1024 * 1024));
        const role = try readRole(arena.allocator(), role_bytes, parse.entries());
        if (classes != 0 and (price_path != null or std.mem.eql(u8, operation, "prices"))) {
            _ = try priceCells(parse.entries(), classes);
        }
        const fit = try bz4.plan.fit(arena.allocator(), init.gpa, parse, .{ .classes = classes, .role = role });
        defer init.gpa.free(fit.bytes);
        if (price_path) |path| {
            var planned = try bz4.plan.baseline(arena.allocator(), parse, fit.options);
            const measured = try bz4.encode(init.gpa, &planned, null);
            defer init.gpa.free(measured);
            if (!std.mem.eql(u8, fit.bytes, measured)) return error.ReplannedFrameMismatch;
            const price_bytes = try priceFile(init.gpa, parse, &planned, fit.options.classes);
            defer init.gpa.free(price_bytes);
            const duration = now(init.io) - start;
            var stats = try ledger(init.gpa, fit.bytes);
            defer stats.block_raw_lengths.deinit(init.gpa);
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = price_bytes });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = fit.bytes });
            try writeLedger(init, stats, duration, fit.bytes.len, fit.options.classes);
            return;
        }
        if (std.mem.eql(u8, operation, "prices")) {
            var planned = try bz4.plan.baseline(arena.allocator(), parse, fit.options);
            const measured = try bz4.encode(init.gpa, &planned, null);
            defer init.gpa.free(measured);
            const price_bytes = try priceFile(init.gpa, parse, &planned, fit.options.classes);
            defer init.gpa.free(price_bytes);
            const duration = now(init.io) - start;
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = price_bytes });
            try json(init, .{ .codec_ns = duration, .classes = fit.options.classes, .tokens = 256 + parse.entries(), .price_bytes = price_bytes.len, .fitted_frame_bytes = fit.bytes.len });
            return;
        }
        const duration = now(init.io) - start;
        var stats = try ledger(init.gpa, fit.bytes);
        defer stats.block_raw_lengths.deinit(init.gpa);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = fit.bytes });
        try writeLedger(init, stats, duration, fit.bytes.len, fit.options.classes);
    } else if (std.mem.eql(u8, operation, "decode")) {
        if (parameter != 0 or price_path != null) return error.Usage;
        const decoded = try bz4.decompress(init.gpa, input, 1);
        defer init.gpa.free(decoded);
        const duration = now(init.io) - start;
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = decoded });
        try json(init, .{ .codec_ns = duration, .decoded = decoded.len });
    } else if (std.mem.eql(u8, operation, "extract")) {
        if (price_path != null) return error.Usage;
        var decoder = try bz4.Decoder.init(init.gpa, input);
        defer decoder.deinit();
        var index: usize = 0;
        var parsed: usize = 0;
        var chosen: ?bz4.Job = null;
        while (try decoder.next()) |job| {
            parsed += 1;
            if (job.items != 0) {
                if (index == parameter) {
                    chosen = job;
                    break;
                }
                index += 1;
            }
        }
        const job = chosen orelse return error.BlockOutOfRange;
        const decoded = try init.gpa.alloc(u8, job.raw_len);
        defer init.gpa.free(decoded);
        try decoder.run(job, decoded);
        const duration = now(init.io) - start;
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = decoded });
        try json(init, .{ .codec_ns = duration, .block_index = parameter, .blocks_parsed = parsed, .raw_bytes = decoded.len, .access_mode = "replay_dictionary_deltas_then_decode_block" });
    } else if (std.mem.eql(u8, operation, "inspect")) {
        if (parameter != 0 or price_path != null) return error.Usage;
        var stats = try ledger(init.gpa, input);
        defer stats.block_raw_lengths.deinit(init.gpa);
        var out: std.Io.Writer.Allocating = .init(init.gpa);
        defer out.deinit();
        try out.writer.print("{f}\n", .{std.json.fmt(.{ .frame_bytes = input.len, .header_bytes = stats.header_bytes, .directory_bytes = stats.directory_bytes, .model_dictionary_bytes = stats.model_dictionary_bytes, .payload_bytes = stats.payload_bytes, .raw_bytes = stats.raw_bytes, .blocks = stats.blocks, .block_raw_lengths = stats.block_raw_lengths.items }, .{})});
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = out.written() });
        try writeLedger(init, stats, now(init.io) - start, input.len, null);
    } else return error.Usage;
}
