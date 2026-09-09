//! Authenticated cold payload section with explicit decode accounting.
//!
//! `View.open` is envelope-only: it validates offsets and the encoded-source
//! digest without touching the codec. `Reader.read` performs at most one
//! decode for its lifetime, records that decode in `Accounting`, and returns a
//! borrowed slice. A caller cannot accidentally report a bzip3 read as
//! per-query-free because the accounting object exposes the cold transition.

const std = @import("std");

pub const Error = error{
    InvalidFormat,
    UnsupportedVersion,
    InvalidCodec,
    Truncated,
    CorruptChecksum,
    OutOfBounds,
    Overflow,
    OutOfMemory,
    CodecUnavailable,
    WorkspaceTooSmall,
};

pub const Kind = enum(u8) { raw = 0, bzip3 = 1 };

pub const EncodeFn = *const fn (allocator: std.mem.Allocator, input: []const u8, context: ?*anyopaque) Error![]u8;
pub const DecodeFn = *const fn (allocator: std.mem.Allocator, compressed: []const u8, original_size: usize, context: ?*anyopaque) Error![]u8;
pub const DecodeIntoFn = *const fn (compressed: []const u8, output: []u8, context: ?*anyopaque) Error!usize;

/// bzip3 is supplied by the host codec layer so this section remains usable
/// in a freestanding reader and testable without a mandatory libbz3 link.
/// The hook must return allocator-owned bytes; Reader frees them exactly once.
pub const Hooks = struct {
    encode: ?EncodeFn = null,
    decode: ?DecodeFn = null,
    decode_into: ?DecodeIntoFn = null,
    context: ?*anyopaque = null,
};

/// Explicit caller-owned decoded storage. A codec that cannot fit reports
/// `WorkspaceTooSmall`; no hidden growth or allocator use is permitted.
pub const Cache = struct {
    storage: []u8,
    used: usize = 0,

    pub fn init(storage: []u8) Cache {
        return .{ .storage = storage };
    }

    pub fn clear(self: *Cache) void {
        self.used = 0;
    }
};

pub const Owned = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Accounting = struct {
    decode_count: u32 = 0,
    /// Encoded bytes retained by the borrowed view, not a codec-internal
    /// allocation estimate.
    encoded_bytes: usize = 0,
    decoded_bytes: usize = 0,
    /// Caller-visible resident bound: encoded view bytes plus decoded cache.
    workspace_bytes: usize = 0,
    decode_ns: u64 = 0,
    read_count: u64 = 0,

    pub fn coldDecodeCost(self: Accounting) usize {
        return self.decoded_bytes;
    }

    pub fn queryDecodeCount(self: Accounting) u32 {
        return self.decode_count;
    }

    pub fn compressedBytes(self: Accounting) usize {
        return self.encoded_bytes;
    }

    pub fn workspaceBytes(self: Accounting) usize {
        return self.workspace_bytes;
    }

    pub fn decodeLatencyNs(self: Accounting) u64 {
        return self.decode_ns;
    }
};

const magic = "L4CO";
const version: u16 = 1;
const header_bytes: usize = 64;
const digest_bytes: usize = 16;

fn writeU16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}

fn writeU32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

fn readU16(bytes: []const u8, at: usize) Error!u16 {
    if (at + 2 > bytes.len) return error.Truncated;
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn readU32(bytes: []const u8, at: usize) Error!u32 {
    if (at + 4 > bytes.len) return error.Truncated;
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn checkedU32(value: usize) Error!u32 {
    return std.math.cast(u32, value) orelse error.Overflow;
}

fn digest(bytes: []const u8) [digest_bytes]u8 {
    var result: [digest_bytes]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &result, .{});
    return result;
}

fn decodePayload(
    allocator: std.mem.Allocator,
    kind: Kind,
    encoded: []const u8,
    original_size: usize,
    hooks: Hooks,
) Error![]u8 {
    return switch (kind) {
        .raw => if (encoded.len != original_size) error.InvalidFormat else allocator.dupe(u8, encoded),
        .bzip3 => if (hooks.decode) |decode| decode(allocator, encoded, original_size, hooks.context) else error.CodecUnavailable,
    };
}

pub const Builder = struct {
    allocator: std.mem.Allocator,
    codec_kind: Kind = .raw,
    hooks: Hooks = .{},

    pub const Options = struct {
        codec_kind: Kind = .raw,
        hooks: Hooks = .{},
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) Builder {
        return .{ .allocator = allocator, .codec_kind = options.codec_kind, .hooks = options.hooks };
    }

    pub fn finish(self: *Builder, plain: []const u8) Error!Owned {
        const encoded = if (self.codec_kind == .raw)
            try self.allocator.dupe(u8, plain)
        else if (self.hooks.encode) |encode|
            try encode(self.allocator, plain, self.hooks.context)
        else
            return error.CodecUnavailable;
        defer self.allocator.free(encoded);
        const total = std.math.add(usize, header_bytes, encoded.len) catch return error.Overflow;
        var out = try self.allocator.alloc(u8, total);
        errdefer self.allocator.free(out);
        @memset(out, 0);
        @memcpy(out[header_bytes..], encoded);
        std.mem.copyForwards(u8, out[0..4], magic);
        writeU16(out, 4, version);
        out[6] = @intFromEnum(self.codec_kind);
        out[7] = 0;
        writeU32(out, 8, try checkedU32(plain.len));
        writeU32(out, 12, try checkedU32(encoded.len));
        writeU32(out, 16, try checkedU32(total));
        const plain_digest = digest(plain);
        const encoded_digest = digest(encoded);
        @memcpy(out[20..][0..digest_bytes], &plain_digest);
        @memcpy(out[36..][0..digest_bytes], &encoded_digest);
        return .{ .bytes = out, .allocator = self.allocator };
    }
};

pub const View = struct {
    bytes: []const u8,
    codec_kind: Kind,
    original_size: usize,
    payload_offset: usize,
    payload_len: usize,
    plain_digest: [digest_bytes]u8,
    encoded_digest: [digest_bytes]u8,

    pub fn open(bytes: []const u8) Error!View {
        if (bytes.len < header_bytes) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidFormat;
        if (try readU16(bytes, 4) != version) return error.UnsupportedVersion;
        const codec_kind = std.enums.fromInt(Kind, bytes[6]) orelse return error.InvalidCodec;
        if (bytes[7] != 0) return error.InvalidFormat;
        const original_size = try readU32(bytes, 8);
        const payload_len = try readU32(bytes, 12);
        const total = try readU32(bytes, 16);
        if (total != bytes.len or @as(usize, payload_len) + header_bytes != bytes.len) return error.InvalidFormat;
        var plain_digest: [digest_bytes]u8 = undefined;
        var encoded_digest: [digest_bytes]u8 = undefined;
        @memcpy(&plain_digest, bytes[20..][0..digest_bytes]);
        @memcpy(&encoded_digest, bytes[36..][0..digest_bytes]);
        return .{ .bytes = bytes, .codec_kind = codec_kind, .original_size = original_size, .payload_offset = header_bytes, .payload_len = payload_len, .plain_digest = plain_digest, .encoded_digest = encoded_digest };
    }

    pub fn payload(self: *const View) []const u8 {
        return self.bytes[self.payload_offset..][0..self.payload_len];
    }

    pub fn verifyEncoded(self: *const View) Error!void {
        if (!std.mem.eql(u8, &self.encoded_digest, &digest(self.payload()))) return error.CorruptChecksum;
    }

    /// Full verification is intentionally separate from open and performs the
    /// codec decode plus the authenticated plaintext digest check.
    pub fn verify(self: *const View, allocator: std.mem.Allocator, hooks: Hooks) Error!void {
        try self.verifyEncoded();
        const decoded = try decodePayload(allocator, self.codec_kind, self.payload(), self.original_size, hooks);
        defer allocator.free(decoded);
        if (!std.mem.eql(u8, &self.plain_digest, &digest(decoded))) return error.CorruptChecksum;
    }
};

pub const Reader = struct {
    view: View,
    allocator: std.mem.Allocator,
    hooks: Hooks,
    cache: ?*Cache = null,
    decoded: ?[]const u8 = null,
    decoded_owned: ?[]u8 = null,
    accounting: Accounting = .{},

    pub fn init(view: View, allocator: std.mem.Allocator, hooks: Hooks) Reader {
        return .{
            .view = view,
            .allocator = allocator,
            .hooks = hooks,
            .accounting = .{ .encoded_bytes = view.payload_len, .workspace_bytes = std.math.add(usize, view.payload_len, view.original_size) catch std.math.maxInt(usize) },
        };
    }

    /// Construct a reader with a caller-owned decoded cache. The cache path
    /// requires `Hooks.decode_into`; this is intentional, because falling back
    /// to an allocator would make the advertised resident bound untruthful.
    pub fn initCached(view: View, cache: *Cache, hooks: Hooks) Reader {
        return .{
            .view = view,
            .allocator = std.heap.page_allocator,
            .hooks = hooks,
            .cache = cache,
            .accounting = .{ .encoded_bytes = view.payload_len, .workspace_bytes = std.math.add(usize, view.payload_len, cache.storage.len) catch std.math.maxInt(usize) },
        };
    }

    pub fn deinit(self: *Reader) void {
        if (self.decoded_owned) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }

    pub fn stats(self: *const Reader) Accounting {
        return self.accounting;
    }

    pub fn ensureDecoded(self: *Reader) Error![]const u8 {
        if (self.decoded == null) {
            try self.view.verifyEncoded();
            if (self.view.codec_kind == .raw) {
                if (self.view.payload_len != self.view.original_size) return error.InvalidFormat;
                const plain = self.view.payload();
                if (!std.mem.eql(u8, &self.view.plain_digest, &digest(plain))) return error.CorruptChecksum;
                self.decoded = plain;
                // Raw still crosses the reader's one-time materialization
                // boundary; counting it keeps mixed raw/cold telemetry
                // comparable without pretending a codec ran.
                self.accounting.decode_count = 1;
                self.accounting.decoded_bytes = 0;
                return plain;
            }
            const started = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
            if (self.cache) |cache| {
                const decode_into = self.hooks.decode_into orelse return error.CodecUnavailable;
                if (cache.storage.len < self.view.original_size) return error.WorkspaceTooSmall;
                const written = try decode_into(self.view.payload(), cache.storage, self.hooks.context);
                if (written != self.view.original_size) return error.InvalidFormat;
                cache.used = written;
                self.decoded = cache.storage[0..written];
            } else {
                self.decoded_owned = try decodePayload(self.allocator, self.view.codec_kind, self.view.payload(), self.view.original_size, self.hooks);
                self.decoded = self.decoded_owned;
            }
            const finished = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
            self.accounting.decode_count += 1;
            self.accounting.decoded_bytes = self.decoded.?.len;
            self.accounting.decode_ns = @intCast(finished - started);
            if (!std.mem.eql(u8, &self.view.plain_digest, &digest(self.decoded.?))) {
                if (self.decoded_owned) |bytes| self.allocator.free(bytes);
                if (self.cache) |cache| cache.used = 0;
                self.decoded_owned = null;
                self.decoded = null;
                return error.CorruptChecksum;
            }
        }
        return self.decoded.?;
    }

    pub fn read(self: *Reader, offset: usize, length: usize) Error![]const u8 {
        const bytes = try self.ensureDecoded();
        const end = std.math.add(usize, offset, length) catch return error.Overflow;
        if (end > bytes.len) return error.OutOfBounds;
        self.accounting.read_count += 1;
        return bytes[offset..end];
    }
};

fn identityEncode(allocator: std.mem.Allocator, input: []const u8, _: ?*anyopaque) Error![]u8 {
    return allocator.dupe(u8, input);
}

fn identityDecode(allocator: std.mem.Allocator, encoded: []const u8, original_size: usize, _: ?*anyopaque) Error![]u8 {
    if (encoded.len != original_size) return error.InvalidFormat;
    return allocator.dupe(u8, encoded);
}

fn identityDecodeInto(encoded: []const u8, output: []u8, _: ?*anyopaque) Error!usize {
    if (output.len < encoded.len) return error.WorkspaceTooSmall;
    @memcpy(output[0..encoded.len], encoded);
    return encoded.len;
}

test "cold raw section opens cheaply and decodes once with authenticated bytes" {
    var builder = Builder.init(std.testing.allocator, .{ .codec_kind = .raw });
    var owned = try builder.finish("cold payload — café — 東京");
    defer owned.deinit();
    const view = try View.open(owned.bytes);
    try std.testing.expectEqual(@as(u32, 0), (Reader.init(view, std.testing.allocator, .{})).stats().decode_count);
    var reader = Reader.init(view, std.testing.allocator, .{});
    defer reader.deinit();
    try std.testing.expectEqualStrings("cold", try reader.read(0, 4));
    try std.testing.expectEqual(@as(u32, 1), reader.stats().decode_count);
    try std.testing.expectEqual(@as(usize, 1), reader.stats().read_count);
    try std.testing.expectEqual(@as(usize, owned.bytes.len - header_bytes), reader.stats().compressedBytes());
    try std.testing.expect(reader.stats().workspaceBytes() >= reader.stats().decoded_bytes);
    try std.testing.expectEqualStrings("payload", try reader.read(5, 7));
    try std.testing.expectEqual(@as(u32, 1), reader.stats().decode_count);
    try view.verify(std.testing.allocator, .{});
}

test "cold open rejects encoded-source mutation before decode" {
    var builder = Builder.init(std.testing.allocator, .{ .codec_kind = .raw });
    var owned = try builder.finish("authenticated");
    defer owned.deinit();
    const changed = try std.testing.allocator.dupe(u8, owned.bytes);
    defer std.testing.allocator.free(changed);
    changed[changed.len - 1] ^= 0x01;
    const changed_view = try View.open(changed);
    try std.testing.expectError(error.CorruptChecksum, changed_view.verifyEncoded());
}

test "bzip3 hook is decoded once and never reported as a free query" {
    const hooks: Hooks = .{ .encode = identityEncode, .decode = identityDecode };
    var builder = Builder.init(std.testing.allocator, .{ .codec_kind = .bzip3, .hooks = hooks });
    var owned = try builder.finish("cold bzip3 payload");
    defer owned.deinit();
    const view = try View.open(owned.bytes);
    var reader = Reader.init(view, std.testing.allocator, hooks);
    defer reader.deinit();
    try std.testing.expectEqualStrings("cold", try reader.read(0, 4));
    try std.testing.expectEqualStrings("bzip3", try reader.read(5, 5));
    try std.testing.expectEqual(@as(u32, 1), reader.stats().decode_count);
    try std.testing.expect(reader.stats().coldDecodeCost() != 0);
    try std.testing.expect(reader.stats().compressedBytes() != 0);
    try std.testing.expect(reader.stats().workspaceBytes() >= reader.stats().decoded_bytes);
    try view.verify(std.testing.allocator, hooks);
}

test "caller-owned cold cache is bounded and decoded exactly once" {
    const hooks: Hooks = .{ .encode = identityEncode, .decode_into = identityDecodeInto };
    var builder = Builder.init(std.testing.allocator, .{ .codec_kind = .bzip3, .hooks = hooks });
    var owned = try builder.finish("caller-owned cold cache");
    defer owned.deinit();
    var cache_storage: [64]u8 = undefined;
    var cache = Cache.init(&cache_storage);
    const view = try View.open(owned.bytes);
    var reader = Reader.initCached(view, &cache, hooks);
    defer reader.deinit();
    try std.testing.expectEqualStrings("caller", try reader.read(0, 6));
    try std.testing.expectEqualStrings("owned", try reader.read(7, 5));
    try std.testing.expectEqual(@as(u32, 1), reader.stats().queryDecodeCount());
    try std.testing.expectEqual(@as(usize, 23), cache.used);
    try std.testing.expectEqual(@as(usize, owned.bytes.len - header_bytes + cache_storage.len), reader.stats().workspaceBytes());
    var too_small_storage: [2]u8 = undefined;
    var too_small = Cache.init(&too_small_storage);
    var small_reader = Reader.initCached(view, &too_small, hooks);
    defer small_reader.deinit();
    try std.testing.expectError(error.WorkspaceTooSmall, small_reader.read(0, 1));
}
