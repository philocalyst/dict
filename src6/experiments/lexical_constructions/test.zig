const std = @import("std");
const lex = @import("lex6");
const workloads = @import("workloads");
const grammar = @import("grammar.zig");
const cm = @import("construction_model.zig");
const admission = @import("construction_admission.zig");
const bundle = @import("bundle.zig");
const shared = @import("global_bundle.zig");
test { _ = @import("entropy.zig"); _ = @import("surface.zig"); _ = cm; }
test "direct typed grammar and surface ablations preserve every native rich field" {
    const a = std.testing.allocator;
    var source = try workloads.rich(a, 8); defer source.deinit();
    for ([_]grammar.Options{ .{ .typed = false, .constructions = false }, .{ .constructions = false }, .{ .typed = false }, .{}, .{ .frequency_order = true }, .{ .contexts = false }, .{ .owner_contexts = true }, .{ .owner_contexts = true, .frequency_order = true }, .{ .typed = false, .causal = true }, .{ .causal = true }, .{ .causal = true, .owner_contexts = true }, .{ .causal = true, .owner_contexts = true, .frequency_order = true } }) |options| {
        var stats = grammar.Stats{}; const frame = try grammar.encodePage(lex.model.Entry, a, source.entries, options, .{}, &stats); defer a.free(frame);
        const page = try grammar.open(lex.model.Entry, a, frame, .{}); defer page.deinit();
        const prepared = try page.prepare();
        for (source.entries, 0..) |entry, i| {
            var decoded = try page.decode(i); defer decoded.deinit();
            try std.testing.expect(workloads.nativeEqual(lex.model.Entry, entry, decoded.value));
            const expected = try lex.packet.encode(a, entry, .{}); defer a.free(expected);
            const actual = try lex.packet.encode(a, decoded.value, .{}); defer a.free(actual);
            try std.testing.expectEqualSlices(u8, expected, actual);
            if (options.typed) try std.testing.expectEqualStrings(entry.headword, try prepared.headword(i));
        }
        try std.testing.expect(stats.model_bytes != 0);
    }
}
test "shared stock pays original groups and gives independently admitted roots" {
    const a = std.testing.allocator;
    const entries = [_]lex.model.Entry{ .{ .id = "one", .headword = "abcabcabcabcabcabcabcabc" }, .{ .id = "two", .headword = "abcabcabcabcabcabcabcabcabcabc" } };
    const first = try lex.packet.encode(a, entries[0], .{}); defer a.free(first);
    const second = try lex.packet.encode(a, entries[1], .{}); defer a.free(second);
    var stats = grammar.Stats{}; const frame = try grammar.encodePage(lex.model.Entry, a, &entries, .{ .causal = true }, .{}, &stats); defer a.free(frame);
    const groups = [_]shared.Group{ .{ .first = 0, .roots = 1, .original_page_bytes = @intCast(72 + first.len), .canonical_start = 0, .canonical_end = @intCast(first.len) }, .{ .first = 1, .roots = 1, .original_page_bytes = @intCast(72 + second.len), .canonical_start = @intCast(first.len), .canonical_end = @intCast(first.len + second.len) } };
    const image = try shared.encode(a, &groups, frame, @splat(0)); defer a.free(image);
    try std.testing.expectEqual(frame.len + shared.header_size + 48, image.len);
    const indexed = try shared.open(image); const verified = try shared.prepare(lex.model.Entry, a, indexed, .{}); defer verified.deinit();
    for (entries, 0..) |entry, i| {
        const found = try indexed.find(i); try std.testing.expectEqual(i, found.group); try std.testing.expectEqual(@as(usize, 0), found.local);
        try std.testing.expectEqualStrings(entry.headword, try verified.headword(i));
        var decoded = try verified.decode(i); defer decoded.deinit(); try std.testing.expect(workloads.nativeEqual(lex.model.Entry, entry, decoded.value));
    }
    const bad = try a.dupe(u8, image); defer a.free(bad);
    // Shift both group boundaries and raw source footprints, retaining valid
    // total accounting/checksum. Only native canonical admission detects it.
    std.mem.writeInt(u32, bad[128 + 16..][0..4], @intCast(first.len + 1), .little);
    std.mem.writeInt(u32, bad[128 + 8..][0..4], @intCast(73 + first.len), .little);
    std.mem.writeInt(u32, bad[152 + 12..][0..4], @intCast(first.len + 1), .little);
    std.mem.writeInt(u32, bad[152 + 8..][0..4], @intCast(71 + second.len), .little); shared.reseal(bad);
    const aliases = try shared.open(bad);
    try std.testing.expectError(error.InvalidBundle, shared.prepare(lex.model.Entry, a, aliases, .{}));
    try std.testing.expectError(error.InvalidIndex, verified.headword(2));
}
test "first-class construction document is encoded through its native type, not a parallel schema" {
    const a = std.testing.allocator;
    const documents = [_]cm.Document{.{ .entry = .{ .id = "mwe", .headword = "取って戻す" }, .programs = &.{.{ .id = "compound", .meta = .{ .language = .{ .tag = "ja" } }, .parameters = &.{ .{ .name = .{ .local = "left" } }, .{ .name = .{ .local = "right" } } }, .body = &.{ .{ .slot = .{ .binding = 0, .role = .{ .local = "verb" } } }, .{ .literal = .{ .bytes = "って" } }, .{ .slot = .{ .binding = 1, .role = .{ .local = "verb" } } } } }}, .instances = &.{ .{ .program = 0, .bindings = &.{ .{ .bytes = "取", .target = .{ .entry = .{ .id = "取る" } } }, .{ .bytes = "戻す", .target = .{ .entry = .{ .id = "戻す" } } } }, .authoritative = .{ .bytes = "取って戻す" }, .meta = .{ .language = .{ .tag = "ja" } } } } }};
    var stats = grammar.Stats{}; const frame = try grammar.encodePage(cm.Document, a, &documents, .{}, .{}, &stats); defer a.free(frame);
    const page = try grammar.open(cm.Document, a, frame, .{}); defer page.deinit();
    // Explicit authoritative target; no reference is inferred from spelling.
    var explicit_documents = documents;
    const explicit_instances = [_]cm.Instance{instance: { var instance = documents[0].instances[0]; instance.authoritative.target = .{ .entry = .{ .id = "mwe" } }; break :instance instance; }};
    explicit_documents[0].instances = &explicit_instances;
    // The separately encoded first fixture intentionally omits that reference.
    try std.testing.expectError(error.InvalidSurfaceReference, page.prepare());
    var explicit_stats = grammar.Stats{};
    const explicit_frame = try grammar.encodePage(cm.Document, a, &explicit_documents, .{}, .{}, &explicit_stats); defer a.free(explicit_frame);
    const explicit_page = try grammar.open(cm.Document, a, explicit_frame, .{}); defer explicit_page.deinit();
    const prepared = try explicit_page.prepare();
    try std.testing.expectEqualStrings("取って戻す", try prepared.headword(0));
    var decoded = try explicit_page.decode(0); defer decoded.deinit();
    try std.testing.expect(workloads.nativeEqual(cm.Document, explicit_documents[0], decoded.value));
    const exact = try cm.execute(a, decoded.value.programs, decoded.value.instances[0], .{}); defer a.free(exact);
    try std.testing.expectEqualStrings(documents[0].entry.headword, exact);
}
test "defaults are fingerprinted, zero roots are canonical, and exact outer seek bytes are paid" {
    const a = std.testing.allocator;
    const A = struct { value: u32 = 1 };
    const B = struct { value: u32 = 2 };
    var stats = grammar.Stats{};
    const frame = try grammar.encodePage(A, a, &.{.{}}, .{}, .{}, &stats); defer a.free(frame);
    try std.testing.expectError(error.InvalidSchema, grammar.open(B, a, frame, .{}));
    const zero = try grammar.encodePage(lex.model.Entry, a, &.{}, .{}, .{}, &stats); defer a.free(zero);
    const zero_page = try grammar.open(lex.model.Entry, a, zero, .{}); defer zero_page.deinit();
    const zero_prepared = try zero_page.prepare(); try std.testing.expectError(error.InvalidIndex, zero_prepared.headword(0));
    const original_bytes = 64 + 8 + std.mem.readInt(u32, frame[52..56], .little);
    const encoded = try bundle.encode(a, &.{.{ .first = 0, .roots = 1, .original_page_bytes = original_bytes }}, &.{frame}); defer a.free(encoded);
    const indexed = try bundle.open(encoded); try std.testing.expectEqual(frame.len + 64 + 24, encoded.len);
    try std.testing.expectEqualSlices(u8, frame, try indexed.page(0));
    const found = try indexed.find(0); try std.testing.expectEqual(@as(usize, 0), found.page); try std.testing.expectEqual(@as(usize, 0), found.local);
    try std.testing.expectError(error.InvalidIndex, indexed.find(1));
}
test "unused construction cycles and wrong targets cannot obtain prepared proof" {
    const a = std.testing.allocator;
    const cycle = cm.Document{ .entry = .{ .id = "e", .headword = "ev" }, .programs = &.{.{ .id = "cycle", .body = &.{.{ .call = .{ .program = 0, .arguments = &.{} } }} }} };
    try std.testing.expectError(error.InvalidProgram, admission.check(a, cycle, .{}, .{}));
    const literal = [_]cm.Program{.{ .id = "literal", .body = &.{.{ .literal = .{ .bytes = "é" } }} }};
    const wrong = cm.Document{ .entry = .{ .id = "e", .headword = "é" }, .programs = &literal, .instances = &.{.{ .program = 0, .authoritative = .{ .bytes = "é", .target = .{ .entry = .{ .id = "e" } } } }} };
    try std.testing.expectError(error.AuthoritativeMismatch, admission.check(a, wrong, .{}, .{}));
    var stats = grammar.Stats{}; const image = try grammar.encodePage(cm.Document, a, &.{cycle}, .{}, .{}, &stats); defer a.free(image);
    const page = try grammar.open(cm.Document, a, image, .{}); defer page.deinit();
    try std.testing.expectError(error.InvalidProgram, page.prepare());
    const bad_span = cm.Instance{ .program = 0, .authoritative = .{ .bytes = "é" }, .realizations = &.{.{ .instruction = 0, .spans = &.{.{ .start = 1, .end = 2 }} }} };
    try std.testing.expectError(error.InvalidRealization, cm.execute(a, &literal, bad_span, .{}));
    const repeated = [_]cm.Program{ .{ .id = "leaf", .body = &.{.{ .literal = .{ .bytes = "x" } }} }, .{ .id = "pair", .body = &.{ .{ .call = .{ .program = 0, .arguments = &.{} } }, .{ .call = .{ .program = 0, .arguments = &.{} } } } } };
    try std.testing.expectError(error.ConstructionDepthLimit, cm.execute(a, &repeated, .{ .program = 1, .authoritative = .{ .bytes = "xx" } }, .{ .max_depth = 0 }));
}
test "construction analysis references resolve Analysis occurrences independently of surfaces" {
    const a = std.testing.allocator;
    const entry = lex.model.Entry{ .id = "e", .headword = "ev", .content = &.{ .{ .form = .{ .representations = &.{.{ .meta = .{ .id = "surface" }, .text = .{ .content = &.{.{ .text = "ev" }} } }} } }, .{ .analysis = .{ .meta = .{ .id = "analysis" }, .process = .{ .namespace = "urn:test:tr", .local = "root" } } } } };
    const programs = [_]cm.Program{.{ .id = "literal", .body = &.{.{ .literal = .{ .bytes = "ev" } }} }};
    var instances = [_]cm.Instance{.{ .program = 0, .analysis = .{ .local = "analysis" }, .authoritative = .{ .bytes = "ev", .target = .{ .local = "surface" } } }};
    const document = cm.Document{ .entry = entry, .programs = &programs, .instances = &instances };
    try admission.check(a, document, .{}, .{});
    instances[0].analysis = .{ .local = "surface" };
    try std.testing.expectError(error.InvalidAnalysisReference, admission.check(a, document, .{}, .{}));
}
test "resealed frame bounds, malformed rANS state, offsets, schema and truncated input reject" {
    const a = std.testing.allocator;
    const entries = [_]lex.model.Entry{.{ .id = "id", .headword = "é" }};
    var stats = grammar.Stats{}; const frame = try grammar.encodePage(lex.model.Entry, a, &entries, .{}, .{}, &stats); defer a.free(frame);
    const bad = try a.dupe(u8, frame); defer a.free(bad);
    for (0..frame.len) |n| if (n < 96 or n == frame.len - 1) {
        const result = grammar.open(lex.model.Entry, a, frame[0..n], .{});
        if (result) |page| { page.deinit(); return error.ExpectedRejection; } else |_| {}
    };
    @memcpy(bad, frame); std.mem.writeInt(u32, bad[16..20], 4097, .little); grammar.reseal(bad);
    try std.testing.expectError(error.TooManyRoots, grammar.open(lex.model.Entry, a, bad, .{}));
    @memcpy(bad, frame); std.mem.writeInt(u32, bad[24..28], 1024 * 1024 + 1, .little); grammar.reseal(bad);
    try std.testing.expectError(error.AllocationLimit, grammar.open(lex.model.Entry, a, bad, .{}));
    @memcpy(bad, frame); bad[8] ^= 1; grammar.reseal(bad);
    try std.testing.expectError(error.InvalidSchema, grammar.open(lex.model.Entry, a, bad, .{}));
    @memcpy(bad, frame); bad[frame.len - 1] ^= 1;
    try std.testing.expectError(error.DigestMismatch, grammar.open(lex.model.Entry, a, bad, .{}));
    const page = try grammar.open(lex.model.Entry, a, frame, .{ .packet = .{ .max_allocation_bytes = 1 } }); defer page.deinit();
    try std.testing.expectError(error.AllocationLimit, page.decode(0));
    @memcpy(bad, frame); bad[4] = 2; grammar.reseal(bad);
    try std.testing.expectError(error.InvalidFrame, grammar.open(lex.model.Entry, a, bad, .{}));
    try std.testing.expectError(error.WorkLimit, grammar.open(lex.model.Entry, a, frame, .{ .dictionary = .{ .max_work = 1 } }));
}
