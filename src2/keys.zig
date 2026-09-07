const std = @import("std");
const bits = @import("bits.zig");
const wire = @import("wire.zig");
pub const restart_interval: u16 = 16;
pub const header_bytes: usize = 40;
pub const restart_bytes: usize = 8;
pub const max_key_bytes: usize = 65_535;
const magic = "KSP2";
const version: u16 = 2;
const postings_flag: u16 = 1;
const RawHeader = struct { magic: [4]u8, version: u16, flags: u16, interval: u16, posting_width: u16, count: u32, restarts: u32, stream_end: u32, table: u32, posting: u32, end: u32, posting_count: u32 };
const HeaderLayout = wire.Layout(RawHeader);

pub const Error = error{
    BadMagic,
    UnsupportedVersion,
    InvalidFormat,
    Truncated,
    Overflow,
    InvalidUtf8,
    KeyTooLong,
    DuplicateKey,
    PostingsNotAllowed,
    NoPostings,
    ScratchTooSmall,
    InvalidRange,
    BudgetExceeded,
    OutOfMemory,
    PostingOutOfRange,
};
const OwnedEntry = struct { key: []u8, ids: []u64 };
const Restart = struct { key_offset: u32, posting_index: u32 };

pub const Owned = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    with_postings: bool,
    posting_universe: ?u64 = null,
    entries: std.ArrayList(OwnedEntry) = .empty,

    pub fn atoms(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator, .with_postings = false };
    }
    pub fn keys(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator, .with_postings = true };
    }
    /// Build a posting space whose IDs must be in `[0, universe)`.
    /// Keeping the bound on the writer makes malformed indexes impossible to
    /// produce accidentally while preserving the unbounded legacy constructor.
    pub fn keysWithUniverse(allocator: std.mem.Allocator, universe: u64) Error!Builder {
        if (universe == 0) return error.InvalidRange;
        return .{ .allocator = allocator, .with_postings = true, .posting_universe = universe };
    }
    pub fn setPostingUniverse(self: *Builder, universe: u64) Error!void {
        if (!self.with_postings or universe == 0) return error.InvalidRange;
        for (self.entries.items) |entry| for (entry.ids) |id|
            if (id >= universe) return error.PostingOutOfRange;
        self.posting_universe = universe;
    }
    pub fn deinit(self: *Builder) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.key);
            if (e.ids.len != 0) self.allocator.free(e.ids);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn addBytes(self: *Builder, key: []const u8) Error!void {
        return self.addWithPostings(key, &[_]u64{});
    }
    pub fn addWithPostings(self: *Builder, key: []const u8, ids: anytype) Error!void {
        if (key.len > max_key_bytes) return error.KeyTooLong;
        if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidUtf8;
        var copied: std.ArrayList(u64) = .empty;
        defer copied.deinit(self.allocator);
        for (ids) |id| {
            const value = bits.checkedU64(id) catch return error.PostingOutOfRange;
            if (self.posting_universe) |universe| if (value >= universe) return error.PostingOutOfRange;
            try copied.append(self.allocator, value);
        }
        if (!self.with_postings and copied.items.len != 0) return error.PostingsNotAllowed;
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const id_copy: []u64 = if (copied.items.len == 0) @constCast(&[_]u64{}) else try copied.toOwnedSlice(self.allocator);
        errdefer if (id_copy.len != 0) self.allocator.free(id_copy);
        try self.entries.append(self.allocator, .{ .key = key_copy, .ids = id_copy });
    }
    pub fn encode(self: *Builder) Error!Owned {
        std.mem.sortUnstable(OwnedEntry, self.entries.items, {}, lessEntry);
        var stream: std.ArrayList(u8) = .empty;
        defer stream.deinit(self.allocator);
        var postings: std.ArrayList(u64) = .empty;
        defer postings.deinit(self.allocator);
        var restarts: std.ArrayList(Restart) = .empty;
        defer restarts.deinit(self.allocator);
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(self.allocator);
        var total: u32 = 0;
        var ordinal: usize = 0;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const key = self.entries.items[i].key;
            const previous = if (i == 0) "" else self.entries.items[i - 1].key;
            var j = i + 1;
            while (j < self.entries.items.len and std.mem.eql(u8, key, self.entries.items[j].key)) : (j += 1) {}
            if (!self.with_postings and j != i + 1) return error.DuplicateKey;
            ids.clearRetainingCapacity();
            if (self.with_postings) for (self.entries.items[i..j]) |e| try ids.appendSlice(self.allocator, e.ids);
            std.mem.sortUnstable(u64, ids.items, {}, std.sort.asc(u64));
            var unique: usize = 0;
            for (ids.items) |id| {
                if (unique == 0 or ids.items[unique - 1] != id) {
                    ids.items[unique] = id;
                    unique += 1;
                }
            }
            ids.shrinkRetainingCapacity(unique);
            if (ids.items.len > std.math.maxInt(u32) - total) return error.Overflow;
            const restart = ordinal % restart_interval == 0;
            if (restart) try restarts.append(self.allocator, .{ .key_offset = try toU32(header_bytes + stream.items.len), .posting_index = total });
            const shared = if (restart) 0 else commonPrefix(previous, key);
            try putVar(&stream, self.allocator, shared);
            try putVar(&stream, self.allocator, key.len - shared);
            try stream.appendSlice(self.allocator, key[shared..]);
            if (self.with_postings) {
                try putVar(&stream, self.allocator, ids.items.len);
                try postings.appendSlice(self.allocator, ids.items);
            }
            total += @intCast(ids.items.len);
            ordinal += 1;
            i = j;
        }
        const stream_end = try toU32(try checked(.add, header_bytes, stream.items.len));
        const table_end = try toU32(try checked(.add, stream_end, try checked(.mul, restarts.items.len, restart_bytes)));
        const posting_offset = table_end;
        var maximum: u64 = 0;
        for (postings.items) |id| maximum = @max(maximum, id);
        const width: u8 = if (maximum == 0) 0 else @intCast(64 - @clz(maximum));
        const posting_length = (try checked(.add, try checked(.mul, postings.items.len, width), 7)) / 8;
        const posting_end = try toU32(try checked(.add, posting_offset, posting_length));
        const out = try self.allocator.alloc(u8, posting_end);
        errdefer self.allocator.free(out);
        @memset(out, 0);
        try writeHeader(out, self.with_postings, try toU32(ordinal), try toU32(restarts.items.len), stream_end, posting_offset, posting_end, total, width);
        @memcpy(out[header_bytes..stream_end], stream.items);
        var at = stream_end;
        for (restarts.items) |r| {
            for ([_]u32{ r.key_offset, r.posting_index }, 0..) |value, j| writeInt(out, at + j * 4, value);
            at += restart_bytes;
        }
        for (postings.items, 0..) |id, n|
            bits.writeBits(out[posting_offset..], n * width, width, id) catch return error.Overflow;
        return .{ .bytes = out, .allocator = self.allocator };
    }
};

pub const Hit = struct { ordinal: u32, key: []const u8, posting_count: u32, posting_offset: u32 };

/// Optional request-local metering. Immutable snapshots never own counters;
/// a copied view can charge every decoded key and posting to one budget.
pub const Work = struct {
    visited: *usize,
    indexed: *usize,
    limit: usize,

    fn consume(self: Work) Error!void {
        if (self.visited.* >= self.limit) return error.BudgetExceeded;
        self.visited.* += 1;
        self.indexed.* += 1;
    }
};

pub const Iterator = struct {
    view: *const View,
    ordinal: u32,
    end: u32,
    key_pos: usize = 0,
    posting_pos: usize = 0,
    scratch: []u8,
    key_len: usize = 0,
    prefix_limit: ?[]const u8 = null,
    fn init(view: *const View, start: u32, end: u32, scratch: []u8) Error!Iterator {
        if (start >= end) return .{ .view = view, .ordinal = start, .end = end, .scratch = scratch };
        const block = (start / restart_interval) * restart_interval;
        const r = try view.restartAt(block / restart_interval);
        var result = Iterator{ .view = view, .ordinal = block, .end = end, .key_pos = r.key_offset, .posting_pos = r.posting_index, .scratch = scratch };
        while (result.ordinal < start) _ = (try result.next()).?;
        return result;
    }
    pub fn next(self: *Iterator) Error!?Hit {
        if (self.ordinal >= self.end) return null;
        if (self.view.work) |work| try work.consume();
        const shared = try readVar(self.view.bytes, &self.key_pos);
        const suffix = try readVar(self.view.bytes, &self.key_pos);
        if (shared > max_key_bytes or shared > self.key_len or (self.ordinal % restart_interval == 0 and shared != 0)) return error.InvalidFormat;
        const shared_len: usize = @intCast(shared);
        if (suffix > max_key_bytes - shared_len) return error.InvalidFormat;
        const len = shared_len + @as(usize, @intCast(suffix));
        if (len > self.scratch.len) return error.ScratchTooSmall;
        const end = try checked(.add, self.key_pos, @as(usize, @intCast(suffix)));
        if (end > self.view.table_offset) return error.Truncated;
        @memcpy(self.scratch[shared..len], self.view.bytes[self.key_pos..end]);
        self.key_pos = end;
        self.key_len = len;
        var count: u32 = 0;
        const poff = try toU32(self.posting_pos);
        if (self.view.has_postings) {
            const n = try readVar(self.view.bytes, &self.key_pos);
            if (n > std.math.maxInt(u32)) return error.InvalidFormat;
            count = @intCast(n);
            self.posting_pos = try checked(.add, self.posting_pos, count);
            if (self.posting_pos > self.view.posting_count) return error.InvalidFormat;
        }
        if (self.prefix_limit) |prefix| if (!std.mem.startsWith(u8, self.scratch[0..len], prefix)) {
            self.ordinal = self.end;
            return null;
        };
        const hit = Hit{ .ordinal = self.ordinal, .key = self.scratch[0..len], .posting_count = count, .posting_offset = poff };
        self.ordinal += 1;
        return hit;
    }
};

pub const PostingIterator = struct {
    view: *const View,
    pos: usize,
    remaining: u32,
    previous: ?u64 = null,
    pub fn next(self: *PostingIterator) Error!?u64 {
        if (self.remaining == 0) return null;
        if (self.view.work) |work| try work.consume();
        const value = bits.readBits(self.view.bytes[self.view.posting_offset..], try checked(.mul, self.pos, self.view.posting_width), self.view.posting_width) catch return error.InvalidFormat;
        if (self.previous) |previous| if (value <= previous) return error.InvalidFormat;
        self.pos += 1;
        self.previous = value;
        self.remaining -= 1;
        return value;
    }
};

pub const View = struct {
    bytes: []const u8,
    key_count: u32,
    restart_count: u32,
    table_offset: usize,
    posting_offset: usize,
    has_postings: bool,
    posting_width: u8,
    posting_count: u32,
    work: ?Work = null,

    pub fn open(bytes: []const u8) Error!View {
        if (bytes.len < header_bytes) return error.Truncated;
        const header = HeaderLayout.read(bytes, 0) catch return error.Truncated;
        if (!std.mem.eql(u8, &header.magic, magic)) return error.BadMagic;
        if (header.version != version) return error.UnsupportedVersion;
        const flags = header.flags;
        if (flags & ~postings_flag != 0 or header.interval != restart_interval or header.posting_width > 64) return error.InvalidFormat;
        const count = header.count;
        const rc = header.restarts;
        const expected = (@as(u64, count) + restart_interval - 1) / restart_interval;
        if (rc != expected) return error.InvalidFormat;
        const stream_end = header.stream_end;
        const table = header.table;
        const posting = header.posting;
        const end = header.end;
        const pc = header.posting_count;
        if (stream_end < header_bytes or table != stream_end) return error.InvalidFormat;
        const table_end = try checked(.add, stream_end, try checked(.mul, @intCast(rc), restart_bytes));
        if (posting != table_end or end < posting or end != bytes.len) return error.Truncated;
        const used = try checked(.mul, pc, header.posting_width);
        if (bytes.len - posting != (try checked(.add, used, 7)) / 8) return error.InvalidFormat;
        if (used % 8 != 0 and bytes[bytes.len - 1] >> @as(u3, @intCast(used % 8)) != 0) return error.InvalidFormat;
        const self: View = .{ .bytes = bytes, .key_count = count, .restart_count = rc, .table_offset = table, .posting_offset = posting, .has_postings = flags & postings_flag != 0, .posting_width = @intCast(header.posting_width), .posting_count = pc };
        if (count == 0) {
            return if (stream_end == header_bytes and posting == end and pc == 0) self else error.InvalidFormat;
        }
        // Validation is deliberately allocation-free.  Two bounded buffers
        // are enough because every record is at most `max_key_bytes` bytes;
        // callers still provide their own scratch for normal iteration.
        var previous_buffer: [max_key_bytes]u8 = undefined;
        var current_buffer: [max_key_bytes]u8 = undefined;
        const previous = previous_buffer[0..];
        const current = current_buffer[0..];
        var total: u32 = 0;
        var d = try Iterator.init(&self, 0, count, current);
        var previous_len: usize = 0;
        for (0..count) |n| {
            if (n % restart_interval == 0) {
                const r = try self.restartAt(@intCast(n / restart_interval));
                if (r.key_offset != d.key_pos or r.posting_index != d.posting_pos or r.posting_index != total) return error.InvalidFormat;
            }
            const h = (try d.next()).?;
            if (!std.unicode.utf8ValidateSlice(h.key) or (n != 0 and std.mem.order(u8, previous[0..previous_len], h.key) != .lt)) return error.InvalidFormat;
            @memcpy(previous[0..h.key.len], h.key);
            previous_len = h.key.len;
            if (h.posting_count > std.math.maxInt(u32) - total) return error.InvalidFormat;
            total += h.posting_count;
            if (self.has_postings) {
                var ids = try self.postingIterator(h);
                while (try ids.next()) |_| {}
            }
        }
        if (d.key_pos != stream_end or d.posting_pos != pc or total != pc) return error.InvalidFormat;
        return self;
    }
    fn restartAt(self: *const View, n: u32) Error!Restart {
        if (n >= self.restart_count) return error.InvalidFormat;
        const at = try checked(.add, self.table_offset, try checked(.mul, n, restart_bytes));
        const key_offset = std.mem.readInt(u32, self.bytes[at..][0..4], .little);
        const posting_index = std.mem.readInt(u32, self.bytes[at + 4 ..][0..4], .little);
        if (key_offset < header_bytes or key_offset >= self.table_offset or posting_index > self.posting_count) return error.InvalidFormat;
        return .{ .key_offset = key_offset, .posting_index = posting_index };
    }
    fn lowerBound(self: *const View, needle: []const u8, scratch: []u8) Error!u32 {
        return if (try self.lowerHit(needle, scratch)) |hit| hit.ordinal else self.key_count;
    }

    fn lowerHit(self: *const View, needle: []const u8, scratch: []u8) Error!?Hit {
        if (self.key_count == 0) return null;
        var lo: u32 = 0;
        var hi = self.restart_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            var d = try Iterator.init(self, mid * restart_interval, mid * restart_interval + 1, scratch);
            const h = (try d.next()).?;
            if (std.mem.order(u8, h.key, needle) == .lt) lo = mid + 1 else hi = mid;
        }
        const block = if (lo == 0) 0 else lo - 1;
        const first = block * restart_interval;
        const last = first + @min(self.key_count - first, restart_interval);
        var d = try Iterator.init(self, first, last, scratch);
        while (try d.next()) |h| {
            if (std.mem.order(u8, h.key, needle) != .lt) return h;
        }
        if (last == self.key_count) return null;
        var next = try Iterator.init(self, last, last + 1, scratch);
        return next.next();
    }
    pub fn all(self: *const View, scratch: []u8) Iterator {
        return Iterator.init(self, 0, self.key_count, scratch) catch unreachable;
    }
    /// Decode one ordinal by replaying at most one front-coded restart block.
    pub fn ordinal(self: *const View, index: u32, scratch: []u8) Error!?Hit {
        if (index >= self.key_count) return null;
        var it = try Iterator.init(self, index, index + 1, scratch);
        return it.next();
    }
    pub fn exact(self: *const View, needle: []const u8, scratch: []u8) Error!?Hit {
        const h = try self.lowerHit(needle, scratch) orelse return null;
        return if (std.mem.eql(u8, h.key, needle)) h else null;
    }
    pub fn prefix(self: *const View, p: []const u8, scratch: []u8) Error!Iterator {
        const first = try self.lowerBound(p, scratch);
        var result = try Iterator.init(self, first, self.key_count, scratch);
        result.prefix_limit = p;
        return result;
    }
    pub fn range(self: *const View, lower: []const u8, upper: []const u8, scratch: []u8) Error!Iterator {
        if (std.mem.order(u8, lower, upper) == .gt) return error.InvalidRange;
        return Iterator.init(self, try self.lowerBound(lower, scratch), try self.lowerBound(upper, scratch), scratch);
    }
    pub fn postingIterator(self: *const View, hit: Hit) Error!PostingIterator {
        if (!self.has_postings) return if (hit.posting_count == 0) .{ .view = self, .pos = self.bytes.len, .remaining = 0 } else error.NoPostings;
        const pos = hit.posting_offset;
        if (pos > self.posting_count or hit.posting_count > self.posting_count - pos) return error.InvalidFormat;
        return .{ .view = self, .pos = pos, .remaining = hit.posting_count };
    }
    pub fn fuzzy(self: *const View, needle: []const u8, max_distance: u8, max_visited: usize, key_scratch: []u8, distance_scratch: []u16) Error!FuzzyIterator {
        if (needle.len > max_key_bytes) return error.KeyTooLong;
        if (!std.unicode.utf8ValidateSlice(needle)) return error.InvalidUtf8;
        if (distance_scratch.len < needle.len + 1) return error.ScratchTooSmall;
        return .{ .cursor = try Iterator.init(self, 0, self.key_count, key_scratch), .needle = needle, .limit = max_distance, .budget = max_visited, .distance = distance_scratch };
    }
};

pub const FuzzyIterator = struct {
    cursor: Iterator,
    needle: []const u8,
    limit: u8,
    budget: usize,
    visited: usize = 0,
    distance: []u16,
    pub fn next(self: *FuzzyIterator) Error!?Hit {
        while (try self.cursor.next()) |h| {
            if (self.visited == self.budget) return error.BudgetExceeded;
            self.visited += 1;
            if (levenshtein(self.needle, h.key, self.distance, self.limit) <= self.limit) return h;
        }
        return null;
    }
};
fn levenshtein(a: []const u8, b: []const u8, row: []u16, limit: u8) u16 {
    const cap: u16 = @as(u16, limit) + 1;
    for (row[0 .. a.len + 1], 0..) |*v, i| v.* = @intCast(@min(i, cap));
    for (b, 0..) |bc, j| {
        var diagonal = row[0];
        row[0] = @intCast(@min(j + 1, cap));
        for (a, 0..) |ac, i| {
            const old = row[i + 1];
            const sub = if (ac == bc) diagonal else diagonal + 1;
            row[i + 1] = @min(@min(@min(old + 1, row[i] + 1), sub), cap);
            diagonal = old;
        }
    }
    return row[a.len];
}

fn lessEntry(_: void, a: OwnedEntry, b: OwnedEntry) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}
fn writeInt(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn writeHeader(out: []u8, with_postings: bool, count: u32, restarts: u32, stream_end: u32, posting_offset: u32, posting_end: u32, total: u32, width: u8) Error!void {
    const header = RawHeader{ .magic = magic.*, .version = version, .flags = if (with_postings) postings_flag else 0, .interval = restart_interval, .posting_width = width, .count = count, .restarts = restarts, .stream_end = stream_end, .table = stream_end, .posting = posting_offset, .end = posting_end, .posting_count = total };
    HeaderLayout.write(out, 0, header) catch return error.Overflow;
}
fn commonPrefix(a: []const u8, b: []const u8) usize {
    return std.mem.findDiff(u8, a, b) orelse @min(a.len, b.len);
}
fn toU32(n: usize) Error!u32 {
    return if (n > std.math.maxInt(u32)) error.Overflow else @intCast(n);
}
fn checked(comptime operation: enum { add, mul }, a: usize, b: usize) Error!usize {
    return switch (operation) {
        .add => std.math.add(usize, a, b) catch error.Overflow,
        .mul => std.math.mul(usize, a, b) catch error.Overflow,
    };
}
fn putVar(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) Error!void {
    var n: u64 = @intCast(value);
    while (n >= 0x80) : (n >>= 7) try out.append(allocator, @intCast((n & 0x7f) | 0x80));
    try out.append(allocator, @intCast(n));
}
fn readVar(bytes: []const u8, pos: *usize) Error!u64 {
    var value: u64 = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        if (pos.* >= bytes.len) return error.Truncated;
        const c = bytes[pos.*];
        pos.* += 1;
        if (i == 9 and c > 1) return error.Overflow;
        value |= @as(u64, c & 0x7f) << @as(u6, @intCast(i * 7));
        if (c < 0x80) {
            if (i != 0 and value < (@as(u64, 1) << @as(u6, @intCast(i * 7)))) return error.InvalidFormat;
            return value;
        }
    }
    return error.Overflow;
}
