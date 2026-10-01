const std = @import("std");
const model = @import("model.zig");
const construction = @import("construction.zig");
const public_construction = @import("construction_api.zig");
const validate = @import("validate.zig");
const packet = @import("packet.zig");
const packet_view = @import("packet_view.zig");
const query = @import("query.zig");
const archive = @import("archive.zig");
const a = std.testing.allocator;

fn arabic() model.Entry {
    return .{
        .id = "arabic-ktb",
        .headword = "كَتَبَ",
        .content = &.{
            .{ .form = .{ .meta = .{ .id = "form" }, .representations = &.{.{
                .meta = .{ .id = "written", .language = .{ .tag = "ar" } },
                .text = .{ .content = &.{.{ .text = "كَتَبَ" }} },
            }} } },
            .{ .analysis = .{ .meta = .{ .id = "analysis" }, .kind = .morphology } },
            // The occurrence precedes its named program to exercise forward IDs.
            .{ .construction = .{
                .meta = .{ .id = "pattern-occurrence", .language = .{ .tag = "ar" } },
                .analysis = .{ .local = "analysis" },
                .program = .{ .local = "root-pattern" },
                .bindings = &.{.{ .bytes = "كَتَبَ", .target = .{ .local = "written" } }},
                .authoritative = .{ .local = "written" },
                .realizations = &.{.{ .step = 6, .spans = &.{.{ .start = 12, .end = 12 }}, .role = .{ .local = "person" } }},
            } },
            .{ .construction_program = .{
                .meta = .{ .id = "root-pattern", .language = .{ .tag = "ar" } },
                .process = .{ .namespace = "urn:lexical-process", .local = "root-pattern" },
                .parameters = &.{.{ .name = .{ .local = "root-source" }, .role = .{ .local = "root" } }},
                .body = &.{
                    .{ .copy = .{ .binding = 0, .spans = &.{.{ .start = 0, .end = 2 }} } },
                    .{ .literal = .{ .bytes = "َ" } },
                    .{ .copy = .{ .binding = 0, .spans = &.{.{ .start = 4, .end = 6 }} } },
                    .{ .literal = .{ .bytes = "َ" } },
                    .{ .copy = .{ .binding = 0, .spans = &.{.{ .start = 8, .end = 10 }} } },
                    .{ .literal = .{ .bytes = "َ" } },
                    .{ .zero = .{ .meta = .{ .id = "zero-person" }, .role = .{ .local = "person" } } },
                },
            } },
        },
    };
}

fn turkish() model.Entry {
    return .{ .id = "turkish-ev", .headword = "evlerimizden", .content = &.{
        .{ .form = .{ .representations = &.{
            .{ .meta = .{ .id = "tr-written" }, .text = .{ .content = &.{.{ .text = "evlerimizden" }} } },
        } } },
        .{ .construction_program = .{
            .meta = .{ .id = "suffix-chain" },
            .parameters = &.{.{ .name = .{ .local = "stem" } }},
            .body = &.{
                .{ .call = .{ .program = .{ .local = "base" }, .arguments = &.{.{ .binding = 0 }} } },
                .{ .literal = .{ .bytes = "ler" } },
                .{ .literal = .{ .bytes = "imiz" } },
                .{ .literal = .{ .bytes = "den" } },
            },
        } },
        .{ .construction_program = .{
            .meta = .{ .id = "base" },
            .parameters = &.{.{ .name = .{ .local = "stem" } }},
            .body = &.{.{ .slot = .{ .binding = 0 } }},
        } },
        .{ .construction = .{ .program = .{ .local = "suffix-chain" }, .bindings = &.{.{ .bytes = "ev" }}, .authoritative = .{ .local = "tr-written" } } },
    } };
}

fn reduplication() model.Entry {
    return .{ .id = "nfd-repeat", .headword = "é-é", .content = &.{
        .{ .form = .{ .representations = &.{
            .{ .meta = .{ .id = "nfd-written" }, .text = .{ .content = &.{.{ .text = "é-é" }} } },
        } } },
        .{ .construction_program = .{
            .meta = .{ .id = "repeat" },
            .parameters = &.{.{ .name = .{ .local = "stem" } }},
            .body = &.{ .{ .slot = .{ .binding = 0 } }, .{ .literal = .{ .bytes = "-" } }, .{ .slot = .{ .binding = 0 } } },
        } },
        .{ .construction = .{ .program = .{ .local = "repeat" }, .bindings = &.{.{ .bytes = "é" }}, .authoritative = .{ .local = "nfd-written" } } },
    } };
}

test "Arabic discontinuous copy, zero realization, typed resolution, packet and archive" {
    const entry = arabic();
    try validate.check(a, &entry, .{});
    try std.testing.expect((try query.resolve(&entry, "root-pattern")).?.as(model.ConstructionProgram) != null);
    try std.testing.expect((try query.resolve(&entry, "pattern-occurrence")).?.as(model.Construction) != null);
    var selected = query.entry(&entry).select(.construction, .descendants);
    try std.testing.expectEqualStrings("root-pattern", (try selected.next()).?.value.program.local);
    try std.testing.expect(try selected.next() == null);
    const realized = try public_construction.realize(a, &entry, "pattern-occurrence", .{});
    defer a.free(realized);
    try std.testing.expectEqualStrings("كَتَبَ", realized);

    const bytes = try packet.encode(a, entry, .{});
    defer a.free(bytes);
    try std.testing.expectEqual(packet.schema_version, bytes[4]);
    var decoded = try packet.decode(model.Entry, a, bytes, .{});
    defer decoded.deinit();
    try validate.check(a, &decoded.value, .{});
    const direct = try packet_view.open(model.Entry, bytes, .{ .max_allocation_bytes = 0 });
    var content = try (try direct.field(.content)).values();
    _ = try content.next();
    _ = try content.next();
    const occurrence = try (try content.next()).?.payload(.construction);
    const program = try (try content.next()).?.payload(.construction_program);
    const program_id = (try (try (try program.field(.meta)).field(.id)).optional()).?;
    try std.testing.expectEqualStrings("root-pattern", try program_id.text());
    try std.testing.expectEqual(model.Reference.local, try (try occurrence.field(.program)).tag());

    var built = try archive.build(a, .{ .entries = &.{entry} }, .{ .compression = .raw });
    defer built.deinit();
    const view = try archive.Archive.open(built.bytes, .{});
    const verified = try view.verify(a);
    var projected = try verified.view(a, archive.EntryId{ .value = 0 });
    defer projected.deinit();
    var values = try (try projected.value.field(.content)).values();
    _ = try values.next();
    _ = try values.next();
    try std.testing.expectEqual(model.Item.construction, try (try values.next()).?.tag());
    var loaded = try view.load(a, archive.EntryId{ .value = 0 });
    defer loaded.deinit();
    try std.testing.expectEqualStrings("root-pattern", loaded.value.content[2].construction.program.local);
}

test "Turkish forward call and NFD reduplication retain exact bytes" {
    const tr = turkish();
    try validate.check(a, &tr, .{});
    const nfd = reduplication();
    try validate.check(a, &nfd, .{});
    var changed = nfd;
    var items = try a.dupe(model.Item, nfd.content);
    defer a.free(items);
    items[2].construction.bindings = &.{.{ .bytes = "é" }};
    changed.content = items;
    try std.testing.expectError(error.AuthoritativeMismatch, validate.check(a, &changed, .{}));
}

test "cycles, scalar boundaries, output and work limits reject before publication" {
    var entry = turkish();
    var items = try a.dupe(model.Item, entry.content);
    defer a.free(items);
    entry.content = items;
    items[1].construction_program.body = &.{.{ .call = .{ .program = .{ .local = "suffix-chain" }, .arguments = &.{.{ .binding = 0 }} } }};
    try std.testing.expectError(error.ConstructionCycle, validate.check(a, &entry, .{}));
    const original = turkish();
    try std.testing.expectError(error.ConstructionOutputLimit, validate.check(a, &original, .{ .construction = .{ .max_output_bytes = 3 } }));
    try std.testing.expectError(error.ConstructionWorkLimit, validate.check(a, &original, .{ .construction = .{ .max_work = 1 } }));
    var arabic_entry = arabic();
    var arabic_items = try a.dupe(model.Item, arabic_entry.content);
    defer a.free(arabic_items);
    arabic_entry.content = arabic_items;
    arabic_items[3].construction_program.body = &.{.{ .copy = .{ .binding = 0, .spans = &.{.{ .start = 1, .end = 2 }} } }};
    try std.testing.expectError(error.InvalidSpan, validate.check(a, &arabic_entry, .{}));
}

test "external programs are preserved only with explicit unverified proof" {
    var entry = reduplication();
    var items = try a.dupe(model.Item, entry.content);
    defer a.free(items);
    entry.content = items;
    items[2].construction.meta.id = "external-use";
    items[2].construction.program = .{ .entry = .{ .id = "other-entry", .fragment = "repeat" } };
    try std.testing.expectError(error.InvalidProgram, validate.check(a, &entry, .{}));
    items[2].construction.proof = .external_unverified;
    try validate.check(a, &entry, .{});
    try std.testing.expectError(error.UnverifiedConstruction, public_construction.realize(a, &entry, "external-use", .{}));
    items[2].construction.program = .{ .local = "repeat" };
    try std.testing.expectError(error.InvalidProgram, validate.check(a, &entry, .{}));

    // A locally named program can itself depend on an external shared program.
    items[1].construction_program.body = &.{.{ .call = .{
        .program = .{ .resource = .{ .id = "construction-library", .fragment = "repeat" } },
        .arguments = &.{.{ .binding = 0 }},
    } }};
    try validate.check(a, &entry, .{});
    items[2].construction.proof = .exact_local;
    try std.testing.expectError(error.InvalidProgram, validate.check(a, &entry, .{}));
}

test "foreign surface labels cannot suppress local execution or exact comparison" {
    var entry = model.Entry{ .id = "foreign-label", .headword = "y", .content = &.{
        .{ .form = .{ .representations = &.{.{ .meta = .{ .id = "written" }, .text = .{ .content = &.{.{ .text = "y" }} } }} } },
        .{ .construction_program = .{
            .meta = .{ .id = "local" },
            .parameters = &.{.{ .name = .{ .local = "unused" } }},
            .body = &.{.{ .literal = .{ .bytes = "x", .target = .{ .iri = "urn:foreign:literal" } } }},
        } },
        .{ .construction = .{
            .program = .{ .local = "local" },
            .bindings = &.{.{ .bytes = "z", .target = .{ .iri = "urn:foreign:binding" } }},
            .authoritative = .{ .local = "written" },
            .proof = .external_unverified,
        } },
    } };
    try std.testing.expectError(error.InvalidProgram, validate.check(a, &entry, .{}));
    var items = try a.dupe(model.Item, entry.content);
    defer a.free(items);
    entry.content = items;
    items[2].construction.proof = .exact_local;
    try std.testing.expectError(error.AuthoritativeMismatch, validate.check(a, &entry, .{}));
}

test "foreign binding labels and foreign callees do not hide known invalid copies" {
    var entry = model.Entry{ .id = "foreign-span", .headword = "é", .content = &.{
        .{ .form = .{ .representations = &.{.{ .meta = .{ .id = "written" }, .text = .{ .content = &.{.{ .text = "é" }} } }} } },
        .{ .construction_program = .{
            .meta = .{ .id = "copy" },
            .parameters = &.{.{ .name = .{ .local = "source" } }},
            .body = &.{.{ .copy = .{ .binding = 0, .spans = &.{.{ .start = 1, .end = 2 }} } }},
        } },
        .{ .construction = .{
            .program = .{ .local = "copy" },
            .bindings = &.{.{ .bytes = "é", .target = .{ .iri = "urn:foreign:source" } }},
            .authoritative = .{ .local = "written" },
        } },
    } };
    try std.testing.expectError(error.InvalidSpan, validate.check(a, &entry, .{}));
    var items = try a.dupe(model.Item, entry.content);
    defer a.free(items);
    entry.content = items;
    items[1].construction_program.body = &.{
        .{ .copy = .{ .binding = 0, .spans = &.{.{ .start = 1, .end = 2 }} } },
        .{ .call = .{
            .program = .{ .resource = .{ .id = "library", .fragment = "external" } },
            .arguments = &.{.{ .binding = 0 }},
        } },
    };
    items[2].construction.proof = .external_unverified;
    try std.testing.expectError(error.InvalidSpan, validate.check(a, &entry, .{}));
}

test "runtime call argument copies consume the shared work budget" {
    var parameters: [256]model.ConstructionParameter = undefined;
    for (&parameters) |*parameter| parameter.* = .{ .name = .{ .local = "p" } };
    var arguments: [256]model.ConstructionArgument = undefined;
    for (&arguments) |*argument| argument.* = .{ .binding = 0 };
    var calls: [8]model.ConstructionStep = undefined;
    for (&calls) |*step| step.* = .{ .call = .{ .program = .{ .local = "callee" }, .arguments = &arguments } };
    const entry = model.Entry{ .id = "large-frames", .headword = "x", .content = &.{
        .{ .form = .{ .representations = &.{.{ .meta = .{ .id = "written" }, .text = .{ .content = &.{} } }} } },
        .{ .construction_program = .{ .meta = .{ .id = "callee" }, .parameters = &parameters, .body = &.{.{ .zero = .{} }} } },
        .{ .construction_program = .{ .meta = .{ .id = "caller" }, .parameters = &.{.{ .name = .{ .local = "p" } }}, .body = &calls } },
        .{ .construction = .{ .program = .{ .local = "caller" }, .bindings = &.{.{ .bytes = "" }}, .authoritative = .{ .local = "written" } } },
    } };
    try validate.check(a, &entry, .{});
    try std.testing.expectError(error.ConstructionWorkLimit, validate.check(a, &entry, .{ .construction = .{ .max_work = 3000 } }));
}

test "long repeated zero-output calls consume the shared lookup-work budget" {
    const long_id = "program-" ++ "x" ** 1024;
    const entry = model.Entry{ .id = "zero-call", .headword = "zero", .content = &.{
        .{ .form = .{ .representations = &.{.{ .meta = .{ .id = "empty-representation" }, .text = .{ .content = &.{} } }} } },
        .{ .construction_program = .{ .meta = .{ .id = long_id }, .body = &.{.{ .zero = .{} }} } },
        .{ .construction_program = .{ .meta = .{ .id = "caller" }, .body = &.{
            .{ .call = .{ .program = .{ .local = long_id }, .arguments = &.{} } },
            .{ .call = .{ .program = .{ .local = long_id }, .arguments = &.{} } },
        } } },
        .{ .construction = .{ .program = .{ .local = "caller" }, .authoritative = .{ .local = "empty-representation" } } },
    } };
    try validate.check(a, &entry, .{});
    try std.testing.expectError(error.ConstructionWorkLimit, validate.check(a, &entry, .{ .construction = .{ .max_work = 6000 } }));
}

test "an unused leaf-first call DAG still enforces maximum total path depth" {
    const entry = model.Entry{ .id = "unused-chain", .headword = "unused", .content = &.{
        .{ .construction_program = .{ .meta = .{ .id = "leaf" }, .body = &.{.{ .zero = .{} }} } },
        .{ .construction_program = .{ .meta = .{ .id = "middle" }, .body = &.{
            .{ .call = .{ .program = .{ .local = "leaf" }, .arguments = &.{} } },
        } } },
        .{ .construction_program = .{ .meta = .{ .id = "root" }, .body = &.{
            .{ .call = .{ .program = .{ .local = "middle" }, .arguments = &.{} } },
        } } },
    } };
    try std.testing.expectError(error.ConstructionDepthLimit, validate.check(a, &entry, .{ .construction = .{ .max_call_depth = 1 } }));
}

test "schema three remains readable and cannot import construction tags" {
    // Old Entry fields have the same wire layout. Re-marking a construction-free
    // schema-4 packet as schema 3 recreates a valid historical Entry packet.
    const plain = model.Entry{ .id = "legacy-entry", .headword = "legacy" };
    const old_entry = try packet.encode(a, plain, .{});
    defer a.free(old_entry);
    old_entry[4] = 3;
    var reopened = try packet.decode(model.Entry, a, old_entry, .{});
    defer reopened.deinit();
    try std.testing.expectEqualStrings("legacy", reopened.value.headword);
    const old_view = try packet_view.open(model.Entry, old_entry, .{});
    try std.testing.expectEqualStrings("legacy", try (try old_view.field(.headword)).text());
    const legacy_analysis = "LXP6\x03\x10\x00";
    var old = try packet.decode(model.Item, a, legacy_analysis, .{});
    defer old.deinit();
    try std.testing.expectEqual(model.Item.analysis, std.meta.activeTag(old.value));
    try std.testing.expectEqual(model.Item.analysis, try (try packet_view.open(model.Item, legacy_analysis, .{})).tag());
    try std.testing.expectError(error.InvalidUnionTag, packet.decode(model.Item, a, "LXP6\x03\x12", .{}));
    try std.testing.expectError(error.InvalidUnionTag, packet_view.open(model.Item, "LXP6\x03\x13", .{}));
    try std.testing.expectError(error.InvalidUnionTag, packet.decode(model.Item, a, "LXP6\x02\x10", .{}));
    _ = construction.Limits{};
}
