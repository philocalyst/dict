//! Reflection-compiled native grammar and independent root rANS programs.
//! No shadow lexical schema or per-node/template offsets are serialized.
const std = @import("std");
const lex = @import("lex6");
const ans = @import("entropy.zig");
const surface = @import("surface.zig");
const admission = @import("construction_admission.zig");
const construction = @import("construction_model.zig");
const fingerprint = @import("dag").schemaFingerprint;
pub const header_size = 96;
pub const Limits = struct {
    max_frame_bytes: usize = 4 * 1024 * 1024,
    max_roots: usize = 4096,
    max_work: usize = 8_000_000,
    dictionary: surface.Limits = .{},
    max_canonical_bytes: usize = surface.default_max_bytes,
    packet: lex.packet.Limits = .{},
    semantic: lex.validate.Scope = .{},
    construction: construction.Limits = .{},
};
pub const Options = struct { typed: bool = true, constructions: bool = true, causal: bool = false, frequency_order: bool = false, contexts: bool = true, owner_contexts: bool = false };
pub const Error = ans.Error || surface.Error || lex.packet.Error || lex.validate.Error || admission.Error || error{ InvalidFrame, InvalidSchema, DigestMismatch, InvalidLexeme, NonCanonicalDefault, TooManyRoots, DepthLimit, AllocationLimit, InvalidIndex };
fn bytesType(comptime T: type) bool { return switch (@typeInfo(T)) { .pointer => |p| p.size == .slice and p.child == u8, else => false }; }
fn reachable(comptime T: type, comptime prior: []const type) []const type {
    @setEvalBranchQuota(500_000);
    for (prior) |P| if (P == T) return prior;
    comptime var result: []const type = prior ++ .{T};
    switch (@typeInfo(T)) {
        .optional => |p| result = reachable(p.child, result),
        .pointer => |p| result = reachable(p.child, result),
        .array => |p| result = reachable(p.child, result),
        .@"struct" => |s| inline for (s.fields) |f| { result = reachable(f.type, result); },
        .@"union" => |s| inline for (s.fields) |f| { result = reachable(f.type, result); },
        else => {},
    }
    return result;
}
fn context(comptime Root: type, comptime T: type, comptime field: usize) u32 {
    @setEvalBranchQuota(500_000);
    inline for (comptime reachable(Root, &.{}), 0..) |P, i| if (P == T) return @intCast((i * 64 + field) * 10);
    @compileError("unreachable native type");
}
fn fieldOrdinal(comptime T: type, comptime name: []const u8) usize {
    inline for (@typeInfo(T).@"struct".fields, 0..) |f, i| if (comptime std.mem.eql(u8, f.name, name)) return i;
    @compileError("missing native field");
}
const Budget = struct {
    limits: Limits, work: usize = 0, allocated: usize = 0, owner_contexts: bool = false,
    fn step(self: *Budget, depth: usize, extra: usize) Error!void {
        if (depth > self.limits.packet.max_depth) return error.DepthLimit;
        self.work = std.math.add(usize, self.work, 1) catch return error.WorkLimit;
        self.work = std.math.add(usize, self.work, extra) catch return error.WorkLimit;
        if (self.work > self.limits.max_work or self.work > self.limits.packet.max_work) return error.WorkLimit;
    }
    fn reserve(self: *Budget, n: usize) Error!void {
        self.allocated = std.math.add(usize, self.allocated, n) catch return error.AllocationLimit;
        if (self.allocated > self.limits.packet.max_allocation_bytes) return error.AllocationLimit;
    }
};
const Inventory = struct {
    allocator: std.mem.Allocator,
    own_strings: bool = false,
    limits: surface.Limits = .{},
    strings: std.ArrayList([]const u8) = .empty,
    counts: std.ArrayList(usize) = .empty,
    map: std.StringHashMapUnmanaged(u32) = .empty,
    total: usize = 0,
    fn deinit(self: *Inventory) void { self.strings.deinit(self.allocator); self.counts.deinit(self.allocator); self.map.deinit(self.allocator); }
    fn add(self: *Inventory, s: []const u8) Error!void {
        const item = try self.map.getOrPut(self.allocator, s);
        if (item.found_existing) { self.counts.items[item.value_ptr.*] += 1; return; }
        if (self.strings.items.len >= self.limits.max_lexemes or self.total > self.limits.max_bytes or s.len > self.limits.max_bytes - self.total) return error.AllocationLimit;
        const stored = if (self.own_strings) try self.allocator.dupe(u8, s) else s;
        item.key_ptr.* = stored;
        item.value_ptr.* = @intCast(self.strings.items.len);
        try self.strings.append(self.allocator, stored); try self.counts.append(self.allocator, 1); self.total += s.len;
    }
    fn order(self: *Inventory) Error!void {
        const Record = struct { bytes: []const u8, count: usize, ordinal: usize };
        const records = try self.allocator.alloc(Record, self.strings.items.len); defer self.allocator.free(records);
        for (records, self.strings.items, self.counts.items, 0..) |*r, s, n, i| r.* = .{ .bytes = s, .count = n, .ordinal = i };
        std.mem.sort(Record, records, {}, struct { fn less(_: void, a: Record, b: Record) bool { return a.count > b.count or (a.count == b.count and a.ordinal < b.ordinal); } }.less);
        self.map.clearRetainingCapacity();
        for (records, 0..) |r, i| { self.strings.items[i] = r.bytes; self.counts.items[i] = r.count; try self.map.put(self.allocator, r.bytes, @intCast(i)); }
    }
};
fn dictionaryLimits(limits: Limits) surface.Limits {
    var bounded = limits.dictionary;
    bounded.max_work = @min(bounded.max_work, limits.max_work);
    return bounded;
}
fn collect(comptime T: type, inv: *Inventory, value: T, budget: *Budget, depth: usize) Error!void {
    @setEvalBranchQuota(500_000); try budget.step(depth, 0);
    if (comptime bytesType(T)) { if (value.len > budget.limits.packet.max_slice_length) return error.SliceTooLong; try budget.step(depth, value.len); return inv.add(value); }
    switch (@typeInfo(T)) {
        .void, .bool, .int, .@"enum" => {},
        .optional => |o| if (value) |v| { try collect(o.child, inv, v, budget, depth + 1); },
        .pointer => |p| if (p.size == .one) { try collect(p.child, inv, value.*, budget, depth + 1); } else if (p.size == .slice) {
            if (value.len > budget.limits.packet.max_slice_length) return error.SliceTooLong;
            for (value) |v| try collect(p.child, inv, v, budget, depth + 1);
        } else return error.UnsupportedType,
        .array => |ar| for (value) |v| try collect(ar.child, inv, v, budget, depth + 1),
        .@"struct" => |s| inline for (s.fields) |f| {
            if (comptime lex.packet.defaultCount(T) != 0 and lex.packet.elidable(f)) {
                if (!lex.packet.equalsDefault(f.type, @field(value, f.name), lex.packet.defaultValue(f))) try collect(f.type, inv, @field(value, f.name), budget, depth + 1);
            } else try collect(f.type, inv, @field(value, f.name), budget, depth + 1);
        },
        .@"union" => switch (value) { inline else => |v| try collect(@TypeOf(v), inv, v, budget, depth + 1) },
        else => return error.UnsupportedType,
    }
}
fn emit(comptime Root: type, comptime T: type, a: std.mem.Allocator, out: *std.ArrayList(ans.Event), inv: *const Inventory, value: T, ctx: u32, budget: *Budget, depth: usize) Error!void {
    @setEvalBranchQuota(500_000); try budget.step(depth, 0);
    if (comptime bytesType(T)) { return ans.emitInteger(out, a, ctx, inv.map.get(value) orelse return error.InvalidLexeme); }
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try out.append(a, .{ .context = ctx, .symbol = @intFromBool(value) }),
        .int => |i| {
            if (i.bits > 64) return error.UnsupportedType;
            const U = std.meta.Int(.unsigned, i.bits);
            const encoded: U = if (i.signedness == .signed) encoded: { const x: U = @bitCast(value); break :encoded (x << 1) ^ (0 -% (x >> (i.bits - 1))); } else @intCast(value);
            try ans.emitInteger(out, a, ctx, @intCast(encoded));
        },
        .@"enum" => |e| inline for (e.fields, 0..) |f, i| { if (value == @field(T, f.name)) { try ans.emitInteger(out, a, ctx, i); return; } },
        .optional => |o| {
            try out.append(a, .{ .context = if (budget.owner_contexts) 300000 + ctx else ctx, .symbol = @intFromBool(value != null) });
            if (value) |v| try emit(Root, o.child, a, out, inv, v, if (budget.owner_contexts) ctx else context(Root, T, 63), budget, depth + 1);
        },
        .pointer => |p| if (p.size == .one) { try emit(Root, p.child, a, out, inv, value.*, ctx, budget, depth + 1); } else if (p.size == .slice) {
            try ans.emitInteger(out, a, if (budget.owner_contexts) 400000 + ctx else ctx, value.len);
            for (value) |v| try emit(Root, p.child, a, out, inv, v, if (budget.owner_contexts) ctx else context(Root, T, 63), budget, depth + 1);
        } else return error.UnsupportedType,
        .array => |ar| for (value) |v| try emit(Root, ar.child, a, out, inv, v, if (budget.owner_contexts) ctx else context(Root, T, 63), budget, depth + 1),
        .@"struct" => |s| {
            const defaults = comptime lex.packet.defaultCount(T); var mask: u64 = 0; comptime var bit = 0;
            if (defaults != 0) {
                inline for (s.fields) |f| if (comptime lex.packet.elidable(f)) {
                    if (!lex.packet.equalsDefault(f.type, @field(value, f.name), lex.packet.defaultValue(f))) mask |= @as(u64, 1) << bit;
                    bit += 1;
                };
                try ans.emitInteger(out, a, if (budget.owner_contexts) 600000 + ctx else context(Root, T, 62), mask);
            }
            bit = 0;
            inline for (s.fields, 0..) |f, i| {
                if (comptime defaults != 0 and lex.packet.elidable(f)) {
                    const present = mask & (@as(u64, 1) << bit) != 0; bit += 1;
                    if (present) try emit(Root, f.type, a, out, inv, @field(value, f.name), context(Root, T, i), budget, depth + 1);
                } else try emit(Root, f.type, a, out, inv, @field(value, f.name), context(Root, T, i), budget, depth + 1);
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null) return error.UnsupportedType;
            switch (value) { inline else => |v, tag| {
                inline for (u.fields, 0..) |f, i| if (comptime std.mem.eql(u8, f.name, @tagName(tag))) {
                    try ans.emitInteger(out, a, if (budget.owner_contexts) 500000 + ctx else context(Root, T, 62), i);
                    try emit(Root, @TypeOf(v), a, out, inv, v, if (budget.owner_contexts) context(Root, T, i) else context(Root, T, 63), budget, depth + 1);
                };
            } }
        },
        else => return error.UnsupportedType,
    }
}
fn read(comptime Root: type, comptime T: type, a: std.mem.Allocator, d: *ans.Decoder, dict: []const []const u8, ctx: u32, budget: *Budget, depth: usize) Error!T {
    @setEvalBranchQuota(500_000); try budget.step(depth, 0);
    if (comptime bytesType(T)) {
        const id = try d.integer(ctx); if (id >= dict.len) return error.InvalidLexeme;
        const s = dict[@intCast(id)]; if (s.len > budget.limits.packet.max_slice_length) return error.SliceTooLong;
        try budget.step(depth, s.len); try budget.reserve(s.len); return a.dupe(u8, s);
    }
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => switch (try d.byte(ctx)) { 0 => false, 1 => true, else => error.InvalidBoolean },
        .int => |i| integer: {
            if (i.bits > 64) return error.UnsupportedType;
            const encoded = try d.integer(ctx); const U = std.meta.Int(.unsigned, i.bits);
            if (encoded > std.math.maxInt(U)) return error.IntegerOverflow;
            const n: U = @intCast(encoded);
            break :integer if (i.signedness == .signed) @bitCast((n >> 1) ^ (0 -% (n & 1))) else @intCast(n);
        },
        .@"enum" => |e| enumeration: { const ordinal = try d.integer(ctx); inline for (e.fields, 0..) |f, i| if (ordinal == i) { break :enumeration @field(T, f.name); }; return error.InvalidEnum; },
        .optional => |o| optional: {
            const p = try d.byte(if (budget.owner_contexts) 300000 + ctx else ctx); if (p == 0) break :optional null; if (p != 1) return error.InvalidBoolean;
            break :optional try read(Root, o.child, a, d, dict, if (budget.owner_contexts) ctx else context(Root, T, 63), budget, depth + 1);
        },
        .pointer => |p| pointer: {
            if (p.size == .one) {
                try budget.reserve(@sizeOf(p.child)); const owned = try a.create(p.child);
                owned.* = try read(Root, p.child, a, d, dict, ctx, budget, depth + 1); break :pointer owned;
            }
            if (p.size != .slice) return error.UnsupportedType;
            const n64 = try d.integer(if (budget.owner_contexts) 400000 + ctx else ctx);
            if (n64 > budget.limits.packet.max_slice_length or n64 > std.math.maxInt(usize)) return error.SliceTooLong;
            const n: usize = @intCast(n64); if (n > budget.limits.max_work - budget.work) return error.WorkLimit;
            try budget.reserve(std.math.mul(usize, n, @sizeOf(p.child)) catch return error.AllocationLimit);
            const owned = try a.alloc(p.child, n);
            for (owned) |*v| v.* = try read(Root, p.child, a, d, dict, if (budget.owner_contexts) ctx else context(Root, T, 63), budget, depth + 1);
            break :pointer owned;
        },
        .array => |ar| array: { var result: T = undefined; for (&result) |*v| v.* = try read(Root, ar.child, a, d, dict, if (budget.owner_contexts) ctx else context(Root, T, 63), budget, depth + 1); break :array result; },
        .@"struct" => |s| structure: {
            var result: T = undefined; const defaults = comptime lex.packet.defaultCount(T);
            const mask = if (defaults != 0) try d.integer(if (budget.owner_contexts) 600000 + ctx else context(Root, T, 62)) else 0;
            if (defaults < 64 and mask >> @as(u6, @intCast(defaults)) != 0) return error.InvalidDefaultMask;
            comptime var bit = 0;
            inline for (s.fields, 0..) |f, i| {
                if (comptime defaults != 0 and lex.packet.elidable(f)) {
                    const present = mask & (@as(u64, 1) << bit) != 0; bit += 1;
                    if (!present) @field(result, f.name) = lex.packet.defaultValue(f) else {
                        @field(result, f.name) = try read(Root, f.type, a, d, dict, context(Root, T, i), budget, depth + 1);
                        if (lex.packet.equalsDefault(f.type, @field(result, f.name), lex.packet.defaultValue(f))) return error.NonCanonicalDefault;
                    }
                } else @field(result, f.name) = try read(Root, f.type, a, d, dict, context(Root, T, i), budget, depth + 1);
            }
            break :structure result;
        },
        .@"union" => |u| union_value: {
            if (u.tag_type == null) return error.UnsupportedType; const ordinal = try d.integer(if (budget.owner_contexts) 500000 + ctx else context(Root, T, 62));
            inline for (u.fields, 0..) |f, i| if (ordinal == i) { break :union_value @unionInit(T, f.name, try read(Root, f.type, a, d, dict, if (budget.owner_contexts) context(Root, T, i) else context(Root, T, 63), budget, depth + 1)); };
            return error.InvalidUnionTag;
        },
        else => error.UnsupportedType,
    };
}
fn get32(bytes: []const u8, at: usize) u32 { return std.mem.readInt(u32, bytes[at..][0..4], .little); }
fn put32(bytes: []u8, at: usize, n: usize) void { std.mem.writeInt(u32, bytes[at..][0..4], @intCast(n), .little); }
pub fn digest(bytes: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{}); h.update(bytes[0..64]); h.update(bytes[96..]); var out: [32]u8 = undefined; h.final(&out); return out;
}
pub fn reseal(bytes: []u8) void { @memcpy(bytes[64..96], &digest(bytes)); }
pub const Stats = struct { models: usize = 0, model_bytes: usize = 0, dictionary_stream_bytes: usize = 0, root_stream_bytes: usize = 0, root_directory_bytes: usize = 0, lexemes: usize = 0, decoded_dictionary_bytes: usize = 0, root_events: usize = 0, dictionary_events: usize = 0, surfaces: surface.Stats = .{} };
pub fn encodePage(comptime Root: type, a: std.mem.Allocator, values: []const Root, options: Options, limits: Limits, stats: *Stats) Error![]u8 {
    stats.* = .{};
    if (options.causal and !options.constructions) return error.InvalidFrame;
    if (limits.dictionary.max_bytes > surface.absolute_max_bytes or limits.max_canonical_bytes > surface.absolute_max_bytes or limits.max_roots > 1_000_000) return error.WorkLimit;
    if (values.len > limits.max_roots) return error.TooManyRoots;
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temporary = arena.allocator();
    var inv = Inventory{ .allocator = temporary, .limits = limits.dictionary }; defer inv.deinit(); var budget = Budget{ .limits = limits };
    const canonical = try temporary.alloc([]const u8, values.len);
    var canonical_bytes: usize = 0;
    for (values, canonical) |v, *p| {
        p.* = try lex.packet.encode(temporary, v, limits.packet);
        canonical_bytes = std.math.add(usize, canonical_bytes, p.len) catch return error.InputTooLarge;
        if (canonical_bytes > limits.max_canonical_bytes) return error.InputTooLarge;
        if (options.typed) try collect(Root, &inv, v, &budget, 0) else try inv.add(p.*);
    }
    if (options.frequency_order) try inv.order();
    const streams = try temporary.alloc([]const ans.Event, values.len + 1);
    streams[0] = if (options.causal) try surface.causalEvents(temporary, inv.strings.items, &stats.surfaces, dictionaryLimits(limits)) else try surface.events(temporary, inv.strings.items, options.constructions, &stats.surfaces, dictionaryLimits(limits));
    budget = .{ .limits = limits, .owner_contexts = options.owner_contexts };
    for (values, canonical, streams[1..]) |v, packet_bytes, *s| {
        var events: std.ArrayList(ans.Event) = .empty;
        if (options.typed) try emit(Root, Root, temporary, &events, &inv, v, context(Root, Root, 63), &budget, 0)
        else try ans.emitInteger(&events, temporary, 0, inv.map.get(packet_bytes).?);
        s.* = events.items; stats.root_events += events.items.len;
    }
    const models = try ans.Models.train(temporary, streams, options.contexts);
    var model_wire: std.ArrayList(u8) = .empty; try models.write(&model_wire, temporary);
    const dictionary_wire = try ans.encode(temporary, streams[0], models);
    const root_offsets = try temporary.alloc(u32, values.len + 1); root_offsets[0] = 0;
    var root_wire: std.ArrayList(u8) = .empty;
    for (streams[1..], 0..) |s, i| { try root_wire.appendSlice(temporary, try ans.encode(temporary, s, models)); root_offsets[i + 1] = @intCast(root_wire.items.len); }
    const length = header_size + model_wire.items.len + dictionary_wire.len + root_offsets.len * 4 + root_wire.items.len;
    if (length > limits.max_frame_bytes) return error.InputTooLarge;
    const out = try a.alloc(u8, length); @memset(out[0..header_size], 0);
    @memcpy(out[0..4], "LTC1"); out[4] = if (options.causal) 2 else 1; out[5] = @intFromBool(options.typed) | (@as(u8, @intFromBool(options.constructions)) << 1) | (@as(u8, @intFromBool(options.frequency_order)) << 2) | (@as(u8, @intFromBool(options.owner_contexts)) << 3) | (@as(u8, @intFromBool(options.causal)) << 4);
    std.mem.writeInt(u64, out[8..16], comptime fingerprint(Root), .little);
    put32(out, 16, values.len); put32(out, 20, inv.strings.items.len); put32(out, 24, inv.total); put32(out, 28, model_wire.items.len); put32(out, 32, dictionary_wire.len); put32(out, 36, root_wire.items.len);
    put32(out, 40, stats.root_events); put32(out, 44, streams[0].len);
    var max_packet: usize = 0; for (canonical) |p| { max_packet = @max(max_packet, p.len); } put32(out, 48, max_packet);
    put32(out, 52, canonical_bytes);
    var at: usize = header_size;
    @memcpy(out[at..][0..model_wire.items.len], model_wire.items); at += model_wire.items.len;
    @memcpy(out[at..][0..dictionary_wire.len], dictionary_wire); at += dictionary_wire.len;
    for (root_offsets) |offset| { put32(out, at, offset); at += 4; }
    @memcpy(out[at..], root_wire.items); reseal(out);
    stats.models = 1 + models.overrides.len; stats.model_bytes = model_wire.items.len; stats.dictionary_stream_bytes = dictionary_wire.len; stats.root_stream_bytes = root_wire.items.len; stats.root_directory_bytes = root_offsets.len * 4;
    stats.lexemes = inv.strings.items.len; stats.decoded_dictionary_bytes = inv.total; stats.dictionary_events = streams[0].len;
    return out;
}
pub fn Page(comptime Root: type) type {
    return struct {
        allocator: std.mem.Allocator, bytes: []const u8, limits: Limits, models: ans.Models, dictionary: surface.Dictionary, offsets: []const u8, streams: []const u8, roots: usize,
        const Self = @This();
        pub fn deinit(self: Self) void { self.dictionary.deinit(self.allocator); self.models.deinit(self.allocator); }
        pub fn decoder(self: Self, i: usize) Error!ans.Decoder {
            if (i >= self.roots) return error.InvalidIndex;
            const start = get32(self.offsets, i * 4); const end = get32(self.offsets, (i + 1) * 4);
            var d = try ans.Decoder.init(self.streams[start..end], self.models);
            d.event_limit = @min(ans.max_events, self.limits.max_work);
            return d;
        }
        pub fn decode(self: Self, i: usize) Error!lex.packet.Decoded(Root) {
            var d = try self.decoder(i);
            if (self.bytes[5] & 1 == 0) {
                const id = try d.integer(0); if (id >= self.dictionary.strings.len) return error.InvalidLexeme;
                try d.finish(); return lex.packet.decode(Root, self.allocator, self.dictionary.strings[@intCast(id)], self.limits.packet);
            }
            var result = lex.packet.Decoded(Root){ .arena = std.heap.ArenaAllocator.init(self.allocator), .value = undefined }; errdefer result.arena.deinit();
            var budget = Budget{ .limits = self.limits, .owner_contexts = self.bytes[5] & 8 != 0 };
            result.value = try read(Root, Root, result.arena.allocator(), &d, self.dictionary.strings, context(Root, Root, 63), &budget, 0);
            try d.finish(); return result;
        }
        /// Used only after prepare's complete native root admission; page bytes
        /// and decoded shared dictionary must stay immutable for the view lifetime.
        fn identityHeadword(self: Self, i: usize) Error!struct { id: []const u8, headword: []const u8 } {
            if (comptime Root != lex.model.Entry and Root != construction.Document) @compileError("headword projection needs native Entry or construction Document");
            if (self.bytes[5] & 1 == 0) return error.UnsupportedType;
            var d = try self.decoder(i);
            if (comptime Root == construction.Document) {
                // Derived from Document's actual field/type order, not a wire
                // byte offset or an independently declared lexical schema.
                if (comptime fieldOrdinal(Root, "entry") != 0 or @FieldType(Root, "entry") != lex.model.Entry) @compileError("Entry must be the first required construction Document field");
                if (comptime lex.packet.defaultCount(Root) != 0) _ = try d.integer(if (self.bytes[5] & 8 != 0) 600000 + context(Root, Root, 63) else context(Root, Root, 62));
            }
            const entry_owner = if (comptime Root == construction.Document) context(Root, Root, fieldOrdinal(Root, "entry")) else context(Root, Root, 63);
            _ = try d.integer(if (self.bytes[5] & 8 != 0) 600000 + entry_owner else context(Root, lex.model.Entry, 62));
            const id = try d.integer(context(Root, lex.model.Entry, fieldOrdinal(lex.model.Entry, "id")));
            const head = try d.integer(context(Root, lex.model.Entry, fieldOrdinal(lex.model.Entry, "headword")));
            if (id >= self.dictionary.strings.len or head >= self.dictionary.strings.len) return error.InvalidLexeme;
            return .{ .id = self.dictionary.strings[@intCast(id)], .headword = self.dictionary.strings[@intCast(head)] };
        }
        pub fn prepare(self: Self) Error!Prepared(Root) {
            var total_events: usize = 0;
            var max_packet: usize = 0;
            var canonical_bytes: usize = 0;
            var arena = std.heap.ArenaAllocator.init(self.allocator); defer arena.deinit(); const temporary = arena.allocator();
            var inventory = Inventory{ .allocator = temporary, .own_strings = true, .limits = self.limits.dictionary }; defer inventory.deinit();
            var inventory_budget = Budget{ .limits = self.limits };
            var identities: std.StringHashMapUnmanaged(void) = .empty; defer identities.deinit(temporary);
            for (0..self.roots) |i| {
                var d = try self.decoder(i);
                var decoded = try self.decode(i); defer decoded.deinit();
                if (comptime Root == lex.model.Entry) try lex.validate.check(self.allocator, &decoded.value, self.limits.semantic);
                if (comptime Root == construction.Document) try admission.check(self.allocator, decoded.value, self.limits.construction, self.limits.semantic);
                if (comptime Root == lex.model.Entry or Root == construction.Document) {
                    const id = if (comptime Root == lex.model.Entry) decoded.value.id else decoded.value.entry.id;
                    const seen = try identities.getOrPut(temporary, id);
                    if (seen.found_existing) return error.DuplicateIdentity;
                    seen.key_ptr.* = try temporary.dupe(u8, id);
                }
                const canonical = try lex.packet.encode(self.allocator, decoded.value, self.limits.packet);
                defer self.allocator.free(canonical);
                max_packet = @max(max_packet, canonical.len);
                canonical_bytes = std.math.add(usize, canonical_bytes, canonical.len) catch return error.WorkLimit;
                if (canonical_bytes > get32(self.bytes, 52)) return error.InvalidFrame;
                if (canonical.len > get32(self.bytes, 48)) return error.InvalidFrame;
                if (self.bytes[5] & 1 != 0) try collect(Root, &inventory, decoded.value, &inventory_budget, 0) else {
                    const id = try d.integer(0);
                    if (id >= self.dictionary.strings.len or !std.mem.eql(u8, canonical, self.dictionary.strings[@intCast(id)])) return error.InvalidFrame;
                    try inventory.add(canonical);
                    d = try self.decoder(i);
                }
                // Replaying the same bounded typed grammar is deliberate for
                // the count guard; the first implementation charges this setup.
                if (self.bytes[5] & 1 != 0) {
                    var replay_arena = std.heap.ArenaAllocator.init(self.allocator); defer replay_arena.deinit(); var budget = Budget{ .limits = self.limits, .owner_contexts = self.bytes[5] & 8 != 0 };
                    _ = try read(Root, Root, replay_arena.allocator(), &d, self.dictionary.strings, context(Root, Root, 63), &budget, 0);
                } else _ = try d.integer(0);
                try d.finish(); total_events += d.events;
                if (total_events > self.limits.max_work) return error.WorkLimit;
            }
            if (total_events != get32(self.bytes, 40)) return error.InvalidFrame;
            if (max_packet != get32(self.bytes, 48)) return error.InvalidFrame;
            if (canonical_bytes != get32(self.bytes, 52)) return error.InvalidFrame;
            if (self.bytes[5] & 4 != 0) try inventory.order();
            if (inventory.strings.items.len != self.dictionary.strings.len) return error.InvalidLexeme;
            for (inventory.strings.items, self.dictionary.strings) |expected, actual| if (!std.mem.eql(u8, expected, actual)) { return error.InvalidLexeme; };
            return .{ .page = self };
        }
    };
}
pub fn Prepared(comptime Root: type) type {
    return struct { page: Page(Root), pub fn headword(self: @This(), i: usize) Error![]const u8 { return (try self.page.identityHeadword(i)).headword; } };
}
pub fn open(comptime Root: type, a: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Page(Root) {
    if (bytes.len < header_size or bytes.len > limits.max_frame_bytes or !std.mem.eql(u8, bytes[0..4], "LTC1") or !std.mem.eql(u8, bytes[6..8], &.{0, 0}) or !std.mem.eql(u8, bytes[56..64], &@as([8]u8, @splat(0)))) return error.InvalidFrame;
    // Version2 adds only bounded causal byte programs. Reject unused aliases.
    if ((bytes[4] == 1 and bytes[5] > 15) or (bytes[4] == 2 and (bytes[5] > 31 or bytes[5] & 18 != 18)) or (bytes[4] != 1 and bytes[4] != 2)) return error.InvalidFrame;
    if (limits.dictionary.max_bytes > surface.absolute_max_bytes or limits.max_canonical_bytes > surface.absolute_max_bytes or limits.max_roots > 1_000_000) return error.WorkLimit;
    if (std.mem.readInt(u64, bytes[8..16], .little) != comptime fingerprint(Root)) return error.InvalidSchema;
    if (!std.mem.eql(u8, bytes[64..96], &digest(bytes))) return error.DigestMismatch;
    const roots: usize = get32(bytes, 16); const n: usize = get32(bytes, 20); const total_bytes: usize = get32(bytes, 24);
    if (roots > limits.max_roots) return error.TooManyRoots;
    if (get32(bytes, 40) > limits.max_work or get32(bytes, 44) > limits.max_work or get32(bytes, 48) > limits.packet.max_input_bytes or get32(bytes, 52) > limits.max_canonical_bytes) return error.WorkLimit;
    const model_bytes: usize = get32(bytes, 28); const dict_bytes: usize = get32(bytes, 32); const root_bytes: usize = get32(bytes, 36);
    const directory_bytes = (roots + 1) * 4;
    const need = std.math.add(usize, model_bytes, dict_bytes) catch return error.InvalidFrame;
    const end = std.math.add(usize, need, directory_bytes + root_bytes) catch return error.InvalidFrame;
    if (end != bytes.len - header_size) return error.InvalidFrame;
    const models = try ans.Models.read(a, bytes[header_size..][0..model_bytes]); errdefer models.deinit(a);
    var d = try ans.Decoder.init(bytes[header_size + model_bytes..][0..dict_bytes], models);
    d.event_limit = @min(ans.max_events, limits.max_work);
    const dictionary = try surface.decode(a, &d, n, total_bytes, bytes[5] & 2 != 0, bytes[5] & 16 != 0, dictionaryLimits(limits)); errdefer dictionary.deinit(a);
    try d.finish(); if (d.events != get32(bytes, 44)) return error.InvalidFrame;
    const at = header_size + model_bytes + dict_bytes;
    const offsets = bytes[at..][0..directory_bytes]; const streams = bytes[at + directory_bytes..];
    if (get32(offsets, 0) != 0 or get32(offsets, roots * 4) != streams.len) return error.InvalidFrame;
    var prior: usize = 0;
    for (0..roots) |i| { const next: usize = get32(offsets, (i + 1) * 4); if (next < prior or next - prior < 4 or next > streams.len) return error.InvalidFrame; prior = next; }
    return .{ .allocator = a, .bytes = bytes, .limits = limits, .models = models, .dictionary = dictionary, .offsets = offsets, .streams = streams, .roots = roots };
}
