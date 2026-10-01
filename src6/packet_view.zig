//! Immutable, allocation-free typed projections of canonical lexical packets.
//!
//! `open` validates every wire value, including fields that will never be
//! projected, with one scanner derived from the same Zig types as packet.zig.
//! This is structural validation, NOT lexical semantic admission. Untrusted
//! dictionaries still require the ordinary document/library admission pass.
//! All derived views borrow their packet bytes; those bytes must stay alive and
//! immutable until every view and iterator is finished. Omitted declared
//! defaults borrow their immutable schema constants instead of allocating them.
const std = @import("std");
const packet = @import("packet.zig");

pub const Limits = packet.Limits;
pub const Error = packet.Error || error{WrongUnionTag};

const Scanner = struct {
    bytes: []const u8,
    limits: Limits,
    version: u8,
    at: usize = 0,
    work: usize = 0,

    fn step(self: *Scanner, depth: usize) Error!void {
        if (depth > self.limits.max_depth) return error.DepthLimit;
        if (self.work >= self.limits.max_work) return error.WorkLimit;
        self.work += 1;
    }

    fn byte(self: *Scanner) Error!u8 {
        if (self.at >= self.bytes.len) return error.Truncated;
        const result = self.bytes[self.at];
        self.at += 1;
        return result;
    }

    fn take(self: *Scanner, count: usize) Error![]const u8 {
        const end = std.math.add(usize, self.at, count) catch return error.Truncated;
        if (end > self.bytes.len) return error.Truncated;
        const result = self.bytes[self.at..end];
        self.at = end;
        return result;
    }

    fn varint(self: *Scanner) Error!u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        var count: usize = 0;
        while (count < 10) : (count += 1) {
            const part = try self.byte();
            if (count == 9 and part > 1) return error.IntegerOverflow;
            value |= @as(u64, part & 0x7f) << shift;
            if (part & 0x80 == 0) {
                if (count != 0 and part == 0) return error.NonCanonicalVarint;
                return value;
            }
            if (count != 9) shift += 7;
        }
        return error.IntegerOverflow;
    }

    fn length(self: *Scanner) Error!usize {
        const value = try self.varint();
        if (value > std.math.maxInt(usize)) return error.IntegerOverflow;
        const result: usize = @intCast(value);
        if (result > self.limits.max_slice_length) return error.SliceTooLong;
        return result;
    }

    fn byteWork(self: *Scanner, length_: usize) Error!void {
        if (length_ > self.limits.max_work - self.work) return error.WorkLimit;
        self.work += length_;
    }
};

fn isBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}

fn Default(comptime T: type) type {
    return struct { value: T };
}

fn expectedField(comptime T: type, comptime expected: ?Default(T), comptime field: std.builtin.Type.StructField) ?Default(field.type) {
    return if (expected) |value| .{ .value = @field(value.value, field.name) } else null;
}

fn integer(comptime T: type, scanner: *Scanner) Error!T {
    const info = @typeInfo(T).int;
    if (info.bits > 64) return error.UnsupportedType;
    const value = try scanner.varint();
    const U = std.meta.Int(.unsigned, info.bits);
    if (value > std.math.maxInt(U)) return error.IntegerOverflow;
    const narrowed: U = @intCast(value);
    if (info.signedness == .signed) {
        const raw: U = (narrowed >> 1) ^ (0 -% (narrowed & 1));
        return @bitCast(raw);
    }
    return @intCast(narrowed);
}

fn scalarValue(comptime T: type, scanner: *Scanner) Error!T {
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => switch (try scanner.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidBoolean,
        },
        .int => integer(T, scanner),
        .@"enum" => |info| result: {
            const ordinal = try scanner.varint();
            inline for (info.fields, 0..) |field, index| {
                if (ordinal == index) break :result @field(T, field.name);
            }
            return error.InvalidEnum;
        },
        else => error.UnsupportedType,
    };
}

/// The single wire scanner. The optional compile-time comparison reports
/// equality with an allocation-free declared default while validating the
/// same value. Ordinary model defaults compare in the first traversal. An
/// unusual nested user default that overrides another declared default uses
/// this same bounded scanner again, with all comparison work charged.
fn scanValue(comptime T: type, scanner: *Scanner, depth: usize, comptime expected: ?Default(T), comptime canonical_defaults: bool) Error!bool {
    @setEvalBranchQuota(300_000);
    try scanner.step(depth);
    if (comptime isBytes(T)) {
        const length = try scanner.length();
        try scanner.byteWork(length);
        const bytes = try scanner.take(length);
        return if (expected) |value| std.mem.eql(u8, bytes, value.value) else false;
    }
    switch (@typeInfo(T)) {
        .void, .bool, .int, .@"enum" => {
            const value = try scalarValue(T, scanner);
            return if (expected) |default| packet.equalsDefault(T, value, default.value) else false;
        },
        .optional => |optional| {
            const present = try scanner.byte();
            if (present == 0) return if (expected) |value| value.value == null else false;
            if (present != 1) return error.InvalidBoolean;
            const child_expected: ?Default(optional.child) = if (expected) |value| if (value.value) |child| .{ .value = child } else null else null;
            const same = try scanValue(optional.child, scanner, depth + 1, child_expected, canonical_defaults);
            return expected != null and child_expected != null and same;
        },
        .pointer => |pointer| {
            if (pointer.size == .one) return scanValue(pointer.child, scanner, depth + 1, null, canonical_defaults);
            if (pointer.size != .slice) return error.UnsupportedType;
            const length = try scanner.length();
            if (length > scanner.limits.max_work - scanner.work) return error.WorkLimit;
            // Elidable slice defaults are necessarily empty. We still visit
            // every element even when its length already differs.
            for (0..length) |_| _ = try scanValue(pointer.child, scanner, depth + 1, null, canonical_defaults);
            return if (expected) |value| length == value.value.len else false;
        },
        .array => |array| {
            var same = expected != null;
            if (comptime expected != null) {
                inline for (0..array.len) |index| {
                    const child_same = try scanValue(array.child, scanner, depth + 1, .{ .value = expected.?.value[index] }, canonical_defaults);
                    same = child_same and same;
                }
            } else {
                for (0..array.len) |_| _ = try scanValue(array.child, scanner, depth + 1, null, canonical_defaults);
            }
            return same;
        },
        .@"struct" => |structure| {
            const defaults = comptime packet.defaultCount(T);
            const sparse = defaults != 0 and scanner.version >= 3;
            const mask = if (sparse) try scanner.varint() else 0;
            if (defaults < 64 and mask >> @as(u6, @intCast(defaults)) != 0) return error.InvalidDefaultMask;
            var same = expected != null;
            comptime var bit = 0;
            inline for (structure.fields) |field| {
                const child_expected = comptime expectedField(T, expected, field);
                if (comptime defaults != 0 and packet.elidable(field)) {
                    const present = mask & (@as(u64, 1) << bit) != 0;
                    bit += 1;
                    if (sparse and !present) {
                        if (comptime child_expected != null) same = same and packet.equalsDefault(field.type, packet.defaultValue(field), child_expected.?.value);
                    } else if (sparse and canonical_defaults) {
                        const start = scanner.at;
                        const default_equal = try scanValue(field.type, scanner, depth + 1, .{ .value = packet.defaultValue(field) }, true);
                        if (default_equal) return error.NonCanonicalDefault;
                        if (comptime child_expected != null) {
                            if (comptime packet.equalsDefault(field.type, packet.defaultValue(field), child_expected.?.value)) {
                                same = false;
                            } else {
                                var comparison = scanner.*;
                                comparison.at = start;
                                const child_same = try scanValue(field.type, &comparison, depth + 1, child_expected, false);
                                scanner.work = comparison.work;
                                same = same and child_same;
                            }
                        }
                    } else {
                        const child_same = try scanValue(field.type, scanner, depth + 1, child_expected, canonical_defaults);
                        same = same and child_same;
                    }
                } else {
                    const child_same = try scanValue(field.type, scanner, depth + 1, child_expected, canonical_defaults);
                    same = same and child_same;
                }
            }
            return same;
        },
        .@"union" => |info| {
            if (info.tag_type == null) return error.UnsupportedType;
            const ordinal = try scanner.varint();
            if (!packet.unionTagAllowed(T, scanner.version, ordinal)) return error.InvalidUnionTag;
            inline for (info.fields, 0..) |field, index| {
                if (ordinal == index) {
                    const child_expected: ?Default(field.type) = comptime if (expected) |value| if (std.mem.eql(u8, @tagName(std.meta.activeTag(value.value)), field.name)) .{ .value = @field(value.value, field.name) } else null else null;
                    const same = try scanValue(field.type, scanner, depth + 1, child_expected, canonical_defaults);
                    return child_expected != null and same;
                }
            }
            return error.InvalidUnionTag;
        },
        else => return error.UnsupportedType,
    }
}

fn selectorName(comptime selector: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(selector))) {
        .enum_literal, .@"enum" => @tagName(selector),
        else => selector,
    };
}

fn fieldType(comptime T: type, comptime selector: anytype) type {
    if (@typeInfo(T) != .@"struct") @compileError("field() requires a struct view");
    return @FieldType(T, selectorName(selector));
}

fn elementType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) p.child else @compileError("values() requires a slice or array view"),
        .array => |a| a.child,
        else => @compileError("values() requires a slice or array view"),
    };
}

/// A child view already has its exact, fully validated parent extent. If no
/// later field is present on this wire, its own end is the parent's end. The
/// declaration order and sparse-mask ordinals come from the actual schema.
fn lastPresentField(comptime T: type, comptime selected: []const u8, version: u8, mask: u64) bool {
    const defaults = comptime packet.defaultCount(T);
    const sparse = defaults != 0 and version >= 3;
    comptime var after = false;
    comptime var bit = 0;
    inline for (@typeInfo(T).@"struct".fields) |field_| {
        const elidable = comptime defaults != 0 and packet.elidable(field_);
        if (comptime after) {
            if (comptime elidable) {
                if (!sparse or mask & (@as(u64, 1) << bit) != 0) return false;
            } else return false;
        }
        if (comptime elidable) bit += 1;
        if (comptime std.mem.eql(u8, field_.name, selected)) after = true;
    }
    return true;
}

const PacketBody = struct { bytes: []const u8, version: u8 };

fn packetBody(bytes: []const u8, limits: Limits) Error!PacketBody {
    if (bytes.len > limits.max_input_bytes) return error.InputTooLarge;
    if (bytes.len < 5) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "LXP6")) return error.InvalidMagic;
    const version = bytes[4];
    if (version != 2 and version != packet.schema_version) return error.UnsupportedVersion;
    return .{ .bytes = bytes[5..], .version = version };
}

/// Validate the full canonical packet and borrow immutable bytes. No allocator
/// is accepted or used. max_allocation_bytes applies only to decodeOwned;
/// input, slice, depth and logical-work limits apply to this structural scan.
pub fn open(comptime T: type, bytes: []const u8, limits: Limits) Error!View(T) {
    const body = try packetBody(bytes, limits);
    var scanner = Scanner{ .bytes = body.bytes, .limits = limits, .version = body.version };
    _ = try scanValue(T, &scanner, 0, null, true);
    if (scanner.at != scanner.bytes.len) return error.TrailingBytes;
    return .{ .backing = .{ .wire = scanner.bytes }, .version = body.version, .limits = limits, .depth = 0, .scanned_work = scanner.work };
}

/// Prepared factory for a VerifiedArchive/VerifiedReader admission proof.
/// PRECONDITIONS: exactly this immutable packet was already fully canonical
/// and semantically admitted as T under these same limits. The archive must
/// retain its verified/digest-checked packet boundaries and immutable byte lifetime;
/// compressed pages must come from its validated bounded decode path.
///
/// This deliberately does not create an admission proof or authenticate a
/// publisher. Zig callers can fabricate proof-wrapper fields, so the prior
/// verification and immutable-lifetime requirements remain caller contracts.
/// Ordinary or untrusted packet bytes MUST use open, whose complete canonical
/// scan is independent of this prepared path. Input bounds and frame markers
/// are still checked here; repeated subtree admission is unnecessary once the
/// caller's existing proof binds the whole exact extent and actual schema.
/// No structural work is charged again, because this factory performs none.
pub fn fromVerifiedDocument(comptime T: type, bytes: []const u8, limits: Limits) Error!View(T) {
    const body = try packetBody(bytes, limits);
    return .{ .backing = .{ .wire = body.bytes }, .version = body.version, .limits = limits, .depth = 0, .scanned_work = 0 };
}

pub fn View(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Value = T;
        const Backing = union(enum) { wire: []const u8, native: *const T, raw_byte: u8 };
        backing: Backing,
        version: u8,
        limits: Limits,
        depth: usize,
        scanned_work: usize = 0,
        /// Extent precision, not an admission/trust state. A prefix view has
        /// a bounded upper end but its single value may end before that bound.
        /// Every prefix still comes from full canonical prior root admission.
        exact_extent: bool = true,

        fn scanner(self: Self, bytes: []const u8) Scanner {
            return .{ .bytes = bytes, .limits = self.limits, .version = self.version };
        }

        fn child(self: Self, comptime C: type, backing: View(C).Backing, work: usize) View(C) {
            return .{ .backing = backing, .version = self.version, .limits = self.limits, .depth = self.depth + 1, .scanned_work = work, .exact_extent = self.exact_extent };
        }

        fn prefixChild(self: Self, comptime C: type, bytes: []const u8, work: usize) View(C) {
            var value = self.child(C, .{ .wire = bytes }, work);
            value.exact_extent = false;
            return value;
        }

        /// Logical scanner work of this view's creation, including preceding
        /// fields when a projection needed to locate its wire span.
        pub fn scannedWork(self: Self) usize {
            return self.scanned_work;
        }

        pub fn field(self: Self, comptime selector: anytype) Error!View(fieldType(T, selector)) {
            const name = comptime selectorName(selector);
            const C = fieldType(T, selector);
            switch (self.backing) {
                .native => |value| return self.child(C, .{ .native = &@field(value.*, name) }, 0),
                .raw_byte => return error.UnsupportedType,
                .wire => |bytes| {
                    var scan = self.scanner(bytes);
                    try scan.step(self.depth);
                    const defaults = comptime packet.defaultCount(T);
                    const sparse = defaults != 0 and self.version >= 3;
                    const mask = if (sparse) try scan.varint() else 0;
                    comptime var bit = 0;
                    inline for (@typeInfo(T).@"struct".fields) |f| {
                        const present = if (comptime defaults != 0 and packet.elidable(f)) result: {
                            const set = !sparse or mask & (@as(u64, 1) << bit) != 0;
                            bit += 1;
                            break :result set;
                        } else true;
                        if (comptime std.mem.eql(u8, f.name, name)) {
                            if (!present) {
                                const value = @as(*const C, @ptrCast(@alignCast(f.default_value_ptr.?)));
                                return self.child(C, .{ .native = value }, scan.work);
                            }
                            const start = scan.at;
                            if (self.exact_extent and lastPresentField(T, name, self.version, mask)) {
                                return self.child(C, .{ .wire = bytes[start..] }, scan.work);
                            }
                            // Only a typed prefix is needed for navigation.
                            // Avoid traversing the target merely to locate
                            // its end; materialization locates that end later.
                            return self.prefixChild(C, bytes[start..], scan.work);
                        }
                        if (present) _ = try scanValue(f.type, &scan, self.depth + 1, null, false);
                    }
                    unreachable;
                },
            }
        }

        pub fn tag(self: Self) Error!std.meta.Tag(T) {
            switch (self.backing) {
                .native => |value| return std.meta.activeTag(value.*),
                .raw_byte => return error.UnsupportedType,
                .wire => |bytes| {
                    var scan = self.scanner(bytes);
                    try scan.step(self.depth);
                    const ordinal = try scan.varint();
                    if (!packet.unionTagAllowed(T, self.version, ordinal)) return error.InvalidUnionTag;
                    inline for (@typeInfo(T).@"union".fields, 0..) |f, index| {
                        if (ordinal == index) return @field(std.meta.Tag(T), f.name);
                    }
                    return error.InvalidUnionTag;
                },
            }
        }

        pub fn payload(self: Self, comptime selected: std.meta.Tag(T)) Error!View(@FieldType(T, @tagName(selected))) {
            const C = @FieldType(T, @tagName(selected));
            switch (self.backing) {
                .native => |value| {
                    if (std.meta.activeTag(value.*) != selected) return error.WrongUnionTag;
                    return self.child(C, .{ .native = &@field(value.*, @tagName(selected)) }, 0);
                },
                .raw_byte => return error.UnsupportedType,
                .wire => |bytes| {
                    var scan = self.scanner(bytes);
                    try scan.step(self.depth);
                    const ordinal = try scan.varint();
                    if (!packet.unionTagAllowed(T, self.version, ordinal) or ordinal >= @typeInfo(T).@"union".fields.len) return error.InvalidUnionTag;
                    const selected_ordinal = comptime result: {
                        for (@typeInfo(T).@"union".fields, 0..) |field_, index| {
                            if (std.mem.eql(u8, field_.name, @tagName(selected))) break :result index;
                        }
                        unreachable;
                    };
                    if (ordinal != selected_ordinal) return error.WrongUnionTag;
                    // A validated tagged union has exactly one payload; no
                    // rescan is needed to discover its already bounded end.
                    return self.child(C, .{ .wire = bytes[scan.at..] }, scan.work);
                },
            }
        }

        pub fn optional(self: Self) Error!?View(@typeInfo(T).optional.child) {
            const C = @typeInfo(T).optional.child;
            switch (self.backing) {
                .native => |value| {
                    if (value.*) |*payload_| return self.child(C, .{ .native = payload_ }, 0);
                    return null;
                },
                .raw_byte => return error.UnsupportedType,
                .wire => |bytes| {
                    var scan = self.scanner(bytes);
                    try scan.step(self.depth);
                    return switch (try scan.byte()) {
                        0 => null,
                        1 => self.child(C, .{ .wire = bytes[scan.at..] }, scan.work),
                        else => error.InvalidBoolean,
                    };
                },
            }
        }

        pub fn pointee(self: Self) Error!View(@typeInfo(T).pointer.child) {
            if (@typeInfo(T).pointer.size != .one) @compileError("pointee() requires an ownership pointer view");
            const C = @typeInfo(T).pointer.child;
            switch (self.backing) {
                .native => |value| return self.child(C, .{ .native = value.* }, 0),
                .raw_byte => return error.UnsupportedType,
                .wire => |bytes| {
                    var scan = self.scanner(bytes);
                    try scan.step(self.depth);
                    return self.child(C, .{ .wire = bytes }, scan.work);
                },
            }
        }

        pub fn values(self: Self) Error!Iterator(T) {
            _ = comptime elementType(T);
            switch (self.backing) {
                .native => |value| return .{ .backing = .{ .native = value }, .version = self.version, .limits = self.limits, .depth = self.depth, .remaining = value.len },
                .raw_byte => return error.UnsupportedType,
                .wire => |bytes| {
                    var scan = self.scanner(bytes);
                    try scan.step(self.depth);
                    const length = if (@typeInfo(T) == .array) @typeInfo(T).array.len else try scan.length();
                    if (comptime isBytes(T)) try scan.byteWork(length);
                    return .{ .backing = .{ .wire = scan }, .version = self.version, .limits = self.limits, .depth = self.depth, .remaining = length, .exact_extent = self.exact_extent };
                },
            }
        }

        /// Exact original UTF-8/binary byte span, with no normalization or copy.
        pub fn text(self: Self) Error![]const u8 {
            if (comptime !isBytes(T) or !@typeInfo(T).pointer.is_const) @compileError("text() requires an immutable byte slice view");
            switch (self.backing) {
                .native => |value| return value.*,
                .raw_byte => return error.UnsupportedType,
                .wire => |bytes| {
                    var scan = self.scanner(bytes);
                    try scan.step(self.depth);
                    const length = try scan.length();
                    try scan.byteWork(length);
                    return scan.take(length);
                },
            }
        }

        pub fn scalar(self: Self) Error!T {
            switch (self.backing) {
                .native => |value| return value.*,
                .raw_byte => |value| return if (T == u8) value else error.UnsupportedType,
                .wire => |bytes| {
                    var scan = self.scanner(bytes);
                    try scan.step(self.depth);
                    return scalarValue(T, &scan);
                },
            }
        }

        /// Explicitly allocate an independently owned value. Projection itself
        /// never calls this path. Defaults contain no dynamic owned payload.
        pub fn decodeOwned(self: Self, allocator: std.mem.Allocator) Error!packet.Decoded(T) {
            switch (self.backing) {
                .native => |value| return .{ .arena = std.heap.ArenaAllocator.init(allocator), .value = value.* },
                .raw_byte => |value| return if (T == u8) .{ .arena = std.heap.ArenaAllocator.init(allocator), .value = value } else error.UnsupportedType,
                .wire => |bytes| {
                    const end = if (self.exact_extent) bytes.len else precise: {
                        var scan = self.scanner(bytes);
                        _ = try scanValue(T, &scan, self.depth, null, false);
                        break :precise scan.at;
                    };
                    const length = std.math.add(usize, end, 5) catch return error.InputTooLarge;
                    const framed = allocator.alloc(u8, length) catch return error.OutOfMemory;
                    defer allocator.free(framed);
                    @memcpy(framed[0..4], "LXP6");
                    framed[4] = self.version;
                    @memcpy(framed[5..], bytes[0..end]);
                    return packet.decode(T, allocator, framed, self.limits);
                },
            }
        }
    };
}

/// Typed sequential traversal carries one cumulative work budget for all next
/// calls. Advancing a cursor scans the previous element only when another is
/// requested; a consumer reading a prefix of its final requested item avoids
/// traversing that item's unused descendants. Root admission already validated
/// all elements. Wire byte strings have raw bytes rather than integer varints; their
/// scalar child views preserve that distinction.
pub fn Iterator(comptime Collection: type) type {
    const C = elementType(Collection);
    return struct {
        const Self = @This();
        pub const Element = C;
        backing: union(enum) { wire: Scanner, native: *const Collection },
        version: u8,
        limits: Limits,
        depth: usize,
        remaining: usize,
        index: usize = 0,
        exact_extent: bool = true,
        pending: bool = false,

        pub fn scannedWork(self: Self) usize {
            return switch (self.backing) {
                .wire => |scan| scan.work,
                .native => 0,
            };
        }

        pub fn next(self: *Self) Error!?View(C) {
            if (self.remaining == 0) return null;
            var exact = true;
            const backing: View(C).Backing = switch (self.backing) {
                .native => |value| .{ .native = &value.*[self.index] },
                .wire => |*scan| result: {
                    if (comptime isBytes(Collection)) break :result .{ .raw_byte = try scan.byte() };
                    if (self.pending) {
                        _ = try scanValue(C, scan, self.depth + 1, null, false);
                        self.pending = false;
                    }
                    const start = scan.at;
                    if (self.remaining == 1 and self.exact_extent) {
                        scan.at = scan.bytes.len;
                    } else {
                        // The collection's count establishes that one canonical
                        // element starts here. Its validated upper bound can
                        // be borrowed before computing the element's own end.
                        self.pending = true;
                        exact = false;
                    }
                    break :result .{ .wire = scan.bytes[start..] };
                },
            };
            self.index += 1;
            self.remaining -= 1;
            return .{ .backing = backing, .version = self.version, .limits = self.limits, .depth = self.depth + 1, .scanned_work = self.scannedWork(), .exact_extent = exact };
        }
    };
}
