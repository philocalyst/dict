//! DEV-only stock-sharing oracle. It admits all original native roots, pays
//! the original group directory, and resolves each root independently after
//! explicit shared-stock preparation. No FINAL tuning and no timing claims.
const std = @import("std");
const lex = @import("lex6");
const workloads = @import("workloads");
const grammar = @import("grammar.zig");
const bundle = @import("global_bundle.zig");
const Entry = lex.model.Entry;
fn get32(b: []const u8, at: usize) usize { return std.mem.readInt(u32, b[at..][0..4], .little); }
fn oldDigest(bytes: []const u8) [32]u8 { var h = std.crypto.hash.sha2.Sha256.init(.{}); h.update(bytes[0..32]); h.update(bytes[64..]); var out: [32]u8 = undefined; h.final(&out); return out; }
const Variant = struct { name: []const u8, options: grammar.Options };
const variants = [_]Variant{
    .{ .name = "global_packet_ans", .options = .{ .typed = false, .constructions = false } },
    .{ .name = "global_typed", .options = .{ .constructions = false } },
    .{ .name = "global_surface", .options = .{ .typed = false } },
    .{ .name = "global_joint", .options = .{} },
    .{ .name = "global_owner", .options = .{ .owner_contexts = true } },
    .{ .name = "global_causal_surface", .options = .{ .typed = false, .causal = true } },
    .{ .name = "global_causal_joint", .options = .{ .causal = true } },
    .{ .name = "global_causal_joint_frequency", .options = .{ .causal = true, .frequency_order = true } },
    .{ .name = "global_causal_owner", .options = .{ .causal = true, .owner_contexts = true } },
    .{ .name = "global_causal_owner_frequency", .options = .{ .causal = true, .owner_contexts = true, .frequency_order = true } },
};
// The shared profile raises archive aggregates, never per-root unchecked
// integer domains. Entropy work remains capped by entropy.max_events (8M).
const limits = grammar.Limits{ .max_frame_bytes = 64 * 1024 * 1024, .max_roots = 65535, .max_work = 64_000_000, .max_canonical_bytes = 32 * 1024 * 1024, .dictionary = .{ .max_bytes = 32 * 1024 * 1024, .max_work = 64_000_000 }, .packet = .{ .max_work = 64_000_000 } };
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args); _ = args.next();
    const input = args.next() orelse return error.MissingInput;
    const directory = args.next() orelse return error.MissingOutput;
    if (std.mem.indexOf(u8, input, "final") != null or std.mem.indexOf(u8, input, "holdout") != null) return error.FinalTuningForbidden;
    const a = std.heap.c_allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, input, a, .limited(64 * 1024 * 1024)); defer a.free(bytes);
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..8], "LPB1\x02\x00\x00\x00") or get32(bytes, 16) != 24 or get32(bytes, 20) != 0 or !std.mem.eql(u8, bytes[32..64], &oldDigest(bytes))) return error.InvalidBundle;
    const pages = get32(bytes, 8); const roots = get32(bytes, 12);
    if (pages > (bytes.len - 64) / 24 or roots > limits.max_roots) return error.InvalidBundle;
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temporary = arena.allocator();
    const groups = try temporary.alloc(bundle.Group, pages);
    const entries = try temporary.alloc(Entry, roots); const packets = try temporary.alloc([]const u8, roots);
    var at: usize = 64 + pages * 24; var next_root: usize = 0; var canonical_bytes: usize = 0; var observation: u64 = 0;
    var identities: std.StringHashMapUnmanaged(void) = .empty; defer identities.deinit(temporary);
    for (0..pages) |page_id| {
        const record = 64 + page_id * 24; const first = get32(bytes, record); const count = get32(bytes, record + 4); const raw = get32(bytes, record + 8); const stored = get32(bytes, record + 12);
        if (first != next_root or count == 0 or count > roots - next_root or get32(bytes, record + 16) != at or get32(bytes, record + 20) != 0 or raw != stored or stored > bytes.len - at or stored > 1024 * 1024) return error.InvalidBundle;
        const frame = bytes[at..][0..stored]; at += stored;
        if (frame.len < 64 or !std.mem.eql(u8, frame[0..8], "LPD1\x01\x00\x00\x00") or get32(frame, 8) != count or get32(frame, 12) != count or !std.mem.eql(u8, frame[32..64], &oldDigest(frame))) return error.InvalidPage;
        const payload = 64 + (count + 1) * 4; if (payload > frame.len) return error.InvalidPage;
        if (get32(frame, 64) != 0 or get32(frame, payload - 4) != frame.len - payload) return error.InvalidPage;
        const canonical_start = canonical_bytes;
        for (entries[first..][0..count], packets[first..][0..count], 0..) |*entry, *packet, i| {
            const start = get32(frame, 64 + i * 4); const end = get32(frame, 64 + (i + 1) * 4);
            if (start > end or end > frame.len - payload) return error.InvalidPage;
            packet.* = frame[payload + start .. payload + end]; const decoded = try lex.packet.decode(Entry, temporary, packet.*, .{}); entry.* = decoded.value;
            try lex.validate.check(temporary, entry, .{}); observation +%= (try workloads.observe(entry)).hash;
            const restored = try lex.packet.encode(temporary, entry.*, .{});
            if (!std.mem.eql(u8, packet.*, restored)) return error.NonCanonicalSource;
            const seen = try identities.getOrPut(temporary, entry.id); if (seen.found_existing) return error.DuplicateIdentity;
            canonical_bytes += packet.len;
        }
        next_root += count;
        groups[page_id] = .{ .first = @intCast(first), .roots = @intCast(count), .original_page_bytes = @intCast(stored), .canonical_start = @intCast(canonical_start), .canonical_end = @intCast(canonical_bytes) };
    }
    if (at != bytes.len or next_root != roots) return error.InvalidBundle;
    var source_hash: [32]u8 = undefined; std.crypto.hash.sha2.Sha256.hash(bytes, &source_hash, .{});
    var buffer: [8192]u8 = undefined; var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    for (variants) |variant| {
        var stats = grammar.Stats{}; const encoded = try grammar.encodePage(Entry, a, entries, variant.options, limits, &stats); defer a.free(encoded);
        const complete = try bundle.encode(a, groups, encoded, source_hash); defer a.free(complete);
        const indexed = try bundle.open(complete);
        if (!std.mem.eql(u8, indexed.frame(), encoded) or indexed.roots != roots or indexed.groups != pages) return error.BundleMismatch;
        const verified = try bundle.prepare(Entry, a, indexed, limits); defer verified.deinit(); const page = verified.page;
        var admitted_canonical: usize = 0;
        for (entries, packets, 0..) |expected, canonical, i| {
            var decoded = try page.decode(i); defer decoded.deinit();
            if (!workloads.nativeEqual(Entry, expected, decoded.value)) return error.NativeMismatch;
            const restored = try lex.packet.encode(a, decoded.value, .{}); defer a.free(restored);
            if (!std.mem.eql(u8, canonical, restored) or !std.meta.eql(try workloads.observe(&expected), try workloads.observe(&decoded.value))) return error.SourceMismatch;
            if (variant.options.typed and !std.mem.eql(u8, expected.headword, try verified.headword(i))) return error.ProjectionMismatch;
            const found = try indexed.find(i); const group = try indexed.group(found.group);
            if (found.global != i or found.local != i - group.first) return error.SeekMismatch;
            if (found.local == 0 and group.canonical_start != admitted_canonical) return error.GroupSourceMismatch;
            admitted_canonical += restored.len;
            if (found.local + 1 == group.roots and group.canonical_end != admitted_canonical) return error.GroupSourceMismatch;
        }
        if (admitted_canonical != canonical_bytes) return error.SourceMismatch;
        const path = try std.fmt.allocPrint(a, "{s}/{s}.lgb", .{ directory, variant.name }); defer a.free(path);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = complete });
        try std.json.Stringify.value(.{ .protocol = "LEXICAL-SHARED-CONSTRUCTION/2", .input = input, .variant = variant.name, .pages = pages, .roots = roots, .complete_bundle_bytes = complete.len, .outer_source_group_directory_bytes = bundle.header_size + pages * 24, .global_frame_bytes = encoded.len, .stats = stats, .prepared_model_owned_heap_bytes = page.models.ownedHeapBytes(), .prepared_page_value_bytes = @sizeOf(grammar.Page(Entry)), .decoded_lexeme_index_bytes = page.dictionary.strings.len * @sizeOf([]const u8), .original_native_observation = observation, .gate = "all original native fields exact; production v3 canonical packet exact; full semantic admission; source observations; independent root/headword and original-group seeks", .timing = false }, .{}, &stdout.interface);
        try stdout.interface.writeByte('\n'); try stdout.interface.flush();
    }
}
