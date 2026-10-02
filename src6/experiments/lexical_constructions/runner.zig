//! DEV-only complete-page representation oracle. Original root groups are fixed.
const std = @import("std");
const lex = @import("lex6");
const workloads = @import("workloads");
const grammar = @import("grammar.zig");
const bundle = @import("bundle.zig");
const Entry = lex.model.Entry;
fn get32(b: []const u8, at: usize) usize { return std.mem.readInt(u32, b[at..][0..4], .little); }
fn oldDigest(bytes: []const u8) [32]u8 { var h = std.crypto.hash.sha2.Sha256.init(.{}); h.update(bytes[0..32]); h.update(bytes[64..]); var out: [32]u8 = undefined; h.final(&out); return out; }
const Variant = struct { name: []const u8, options: grammar.Options };
const variants = [_]Variant{
    .{ .name = "packet_ans", .options = .{ .typed = false, .constructions = false } },
    .{ .name = "typed", .options = .{ .constructions = false } },
    .{ .name = "surface", .options = .{ .typed = false } },
    .{ .name = "joint", .options = .{} },
    .{ .name = "joint_frequency", .options = .{ .frequency_order = true } },
    .{ .name = "joint_global", .options = .{ .contexts = false } },
    .{ .name = "joint_owner", .options = .{ .owner_contexts = true } },
    .{ .name = "joint_owner_frequency", .options = .{ .owner_contexts = true, .frequency_order = true } },
    .{ .name = "causal_surface", .options = .{ .typed = false, .causal = true } },
    .{ .name = "causal_joint", .options = .{ .causal = true } },
    .{ .name = "causal_owner", .options = .{ .causal = true, .owner_contexts = true } },
    .{ .name = "causal_owner_frequency", .options = .{ .causal = true, .owner_contexts = true, .frequency_order = true } },
};
pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args); _ = args.next();
    const input = args.next() orelse return error.MissingInput;
    const directory = args.next() orelse return error.MissingOutput;
    // Frozen FINAL source paths are deliberately outside this DEV oracle.
    if (std.mem.indexOf(u8, input, "final") != null) return error.FinalTuningForbidden;
    const a = std.heap.c_allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, input, a, .limited(64 * 1024 * 1024)); defer a.free(bytes);
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..5], "LPB1\x02") or get32(bytes, 16) != 24 or !std.mem.eql(u8, bytes[32..64], &oldDigest(bytes))) return error.InvalidBundle;
    const pages = get32(bytes, 8); const roots = get32(bytes, 12);
    if (pages > (bytes.len - 64) / 24) return error.InvalidBundle;
    try std.Io.Dir.cwd().createDirPath(init.io, directory);
    var buffer: [8192]u8 = undefined; var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    var totals: [variants.len]usize = @splat(64 + pages * 24);
    const groups = try a.alloc(bundle.Group, pages); defer a.free(groups);
    var images: [variants.len]std.ArrayList([]const u8) = @splat(.empty);
    defer for (&images) |*list| { for (list.items) |image| a.free(image); list.deinit(a); };
    var at: usize = 64 + pages * 24; var next_root: usize = 0;
    var observation: u64 = 0;
    var identity_arena = std.heap.ArenaAllocator.init(a); defer identity_arena.deinit();
    var identities: std.StringHashMapUnmanaged(void) = .empty; defer identities.deinit(identity_arena.allocator());
    for (0..pages) |page_id| {
        const record = 64 + page_id * 24; const first = get32(bytes, record); const count = get32(bytes, record + 4); const raw = get32(bytes, record + 8); const stored = get32(bytes, record + 12);
        if (first != next_root or get32(bytes, record + 16) != at or raw != stored or stored > bytes.len - at or stored > 1024 * 1024) return error.InvalidBundle;
        const frame = bytes[at..][0..stored]; at += stored; next_root += count;
        groups[page_id] = .{ .first = @intCast(first), .roots = @intCast(count), .original_page_bytes = @intCast(stored) };
        if (frame.len < 64 or !std.mem.eql(u8, frame[0..8], "LPD1\x01\x00\x00\x00") or get32(frame, 8) != count or get32(frame, 12) != count or !std.mem.eql(u8, frame[32..64], &oldDigest(frame))) return error.InvalidPage;
        const payload = 64 + (count + 1) * 4; if (payload > frame.len) return error.InvalidPage;
        if (get32(frame, 64) != 0 or get32(frame, payload - 4) != frame.len - payload) return error.InvalidPage;
        var arena = std.heap.ArenaAllocator.init(a); defer arena.deinit(); const temporary = arena.allocator();
        const entries = try temporary.alloc(Entry, count); const packets = try temporary.alloc([]const u8, count);
        for (entries, packets, 0..) |*entry, *packet, i| {
            const start = get32(frame, 64 + i * 4); const end = get32(frame, 64 + (i + 1) * 4);
            if (start > end or end > frame.len - payload) return error.InvalidPage;
            packet.* = frame[payload + start .. payload + end]; const decoded = try lex.packet.decode(Entry, temporary, packet.*, .{}); entry.* = decoded.value;
            try lex.validate.check(temporary, entry, .{}); observation +%= (try workloads.observe(entry)).hash;
            const seen = try identities.getOrPut(identity_arena.allocator(), entry.id);
            if (seen.found_existing) return error.DuplicateIdentity;
            seen.key_ptr.* = try identity_arena.allocator().dupe(u8, entry.id);
        }
        for (variants, 0..) |variant, v| {
            var stats = grammar.Stats{}; const encoded = try grammar.encodePage(Entry, a, entries, variant.options, .{}, &stats);
            images[v].append(a, encoded) catch |e| { a.free(encoded); return e; };
            const page = try grammar.open(Entry, a, encoded, .{}); defer page.deinit(); const prepared = try page.prepare();
            for (entries, packets, 0..) |expected, canonical, i| {
                var decoded = try page.decode(i); defer decoded.deinit();
                if (!workloads.nativeEqual(Entry, expected, decoded.value)) return error.NativeMismatch;
                const restored = try lex.packet.encode(temporary, decoded.value, .{});
                if (!std.mem.eql(u8, canonical, restored) or !std.meta.eql(try workloads.observe(&expected), try workloads.observe(&decoded.value))) return error.SourceMismatch;
                if (variant.options.typed and !std.mem.eql(u8, expected.headword, try prepared.headword(i))) return error.ProjectionMismatch;
            }
            const path = try std.fmt.allocPrint(temporary, "{s}/{s}.{d:0>5}.ltc", .{ directory, variant.name, page_id });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = encoded }); totals[v] += encoded.len;
            try std.json.Stringify.value(.{ .protocol = "LEXICAL-DIRECT-GRAMMAR/1", .variant = variant.name, .page = page_id, .first = first, .roots = count, .complete_page_bytes = encoded.len, .flat_raw_page_bytes = frame.len, .stats = stats, .prepared_model_owned_heap_bytes = page.models.ownedHeapBytes(), .prepared_page_value_bytes = @sizeOf(grammar.Page(Entry)), .decoded_lexeme_index_bytes = page.dictionary.strings.len * @sizeOf([]const u8), .gate = "original native T fully equal; complete canonical production packet exact; semantic admission; independent observation and typed headword projection", .timing = false }, .{}, &stdout.interface);
            try stdout.interface.writeByte('\n'); try stdout.interface.flush();
        }
    }
    if (at != bytes.len or next_root != roots) return error.InvalidBundle;
    for (variants, totals, images) |variant, total, image| {
        const complete = try bundle.encode(a, groups, image.items); defer a.free(complete);
        const indexed = try bundle.open(complete);
        if (complete.len != total or indexed.roots != roots) return error.BundleMismatch;
        for (0..roots) |root| {
            const found = try indexed.find(root);
            if (!std.mem.eql(u8, try indexed.page(found.page), image.items[found.page]) or found.local != root - groups[found.page].first) return error.SeekMismatch;
        }
        const path = try std.fmt.allocPrint(a, "{s}/{s}.ltb", .{ directory, variant.name }); defer a.free(path);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = complete });
        try std.json.Stringify.value(.{ .protocol = "LEXICAL-DIRECT-GRAMMAR-TOTAL/1", .input = input, .variant = variant.name, .pages = pages, .roots = roots, .complete_bundle_bytes = total, .outer_frame_directory_bytes = 64 + pages * 24, .original_native_observation = observation, .timing = false }, .{}, &stdout.interface); try stdout.interface.writeByte('\n');
    }
    try stdout.interface.flush();
}
