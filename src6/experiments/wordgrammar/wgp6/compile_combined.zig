//! Compile an isolated productive spelling Parse with unchanged bz4 v4 code.
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
    for (kids) |kid| if (kid >= 256 and kid < bz4.Parse.cut and kid - 256 >= body_off.len - 1) return error.BadParse;
    for (toks) |tok| if (tok >= 256 and tok - 256 >= body_off.len - 1) return error.BadParse;
    return .{ .body_off = body_off, .kids = kids, .block_off = block_off, .toks = toks };
}

const Ledger = struct {
    header_bytes: usize,
    directory_bytes: usize,
    model_dictionary_bytes: usize,
    payload_bytes: usize,
    raw_bytes: usize,
    blocks: usize,
};

fn ledger(bytes: []const u8) !Ledger {
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
    while (try bz4.frame.Block.read(bytes, &pos)) |b| {
        model_dictionary_bytes += b.delta.len;
        payload_bytes += b.payload.len;
        raw_bytes += b.raw_len;
        if (b.items != 0) blocks += 1;
    }
    if (pos != bytes.len) return error.BadFrame;
    return .{ .header_bytes = header_bytes, .directory_bytes = bytes.len - header_bytes - model_dictionary_bytes - payload_bytes, .model_dictionary_bytes = model_dictionary_bytes, .payload_bytes = payload_bytes, .raw_bytes = raw_bytes, .blocks = blocks };
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

fn priceFile(gpa: std.mem.Allocator, input: bz4.Parse, plan: *bz4.Plan, classes: u16) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
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
    const classes = if (args.next()) |arg| try std.fmt.parseUnsigned(u16, arg, 10) else 0;
    const price_path = args.next();
    if (args.next() != null) return error.Usage;
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, init.gpa, .limited(512 * 1024 * 1024));
    defer init.gpa.free(input);
    const start = now(init.io);
    if (std.mem.eql(u8, operation, "compile") or std.mem.eql(u8, operation, "prices")) {
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        const parse = try readParse(arena.allocator(), input);
        const fit = try bz4.plan.fit(arena.allocator(), init.gpa, parse, .{ .classes = classes });
        defer init.gpa.free(fit.bytes);
        if (price_path) |path| {
            var planned = try bz4.plan.baseline(arena.allocator(), parse, fit.options);
            const measured = try bz4.encode(init.gpa, &planned, null);
            defer init.gpa.free(measured);
            if (!std.mem.eql(u8, fit.bytes, measured)) return error.ReplannedFrameMismatch;
            const price_bytes = try priceFile(init.gpa, parse, &planned, fit.options.classes);
            defer init.gpa.free(price_bytes);
            const duration = now(init.io) - start;
            const stats = try ledger(fit.bytes);
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = price_bytes });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = fit.bytes });
            try json(init, .{ .codec_ns = duration, .frame_bytes = fit.bytes.len, .classes = fit.options.classes, .entries = parse.entries(), .ledger = stats, .price_bytes = price_bytes.len });
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
        const stats = try ledger(fit.bytes);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = fit.bytes });
        try json(init, .{ .codec_ns = duration, .frame_bytes = fit.bytes.len, .classes = fit.options.classes, .entries = parse.entries(), .ledger = stats });
    } else if (std.mem.eql(u8, operation, "decode")) {
        const decoded = try bz4.decompress(init.gpa, input, 1);
        defer init.gpa.free(decoded);
        const duration = now(init.io) - start;
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = decoded });
        try json(init, .{ .codec_ns = duration, .decoded = decoded.len });
    } else return error.Usage;
}
