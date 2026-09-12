const std = @import("std");
const bytes = @import("bytes.zig");
const columns = @import("columns.zig");
const entities = @import("entities.zig");
const keys = @import("keys.zig");
const model = @import("model.zig");
const sets = @import("sets.zig");
const stored = @import("stored.zig");
const strings = @import("strings.zig");
const topology = @import("topology.zig");
const values = @import("values.zig");
const bindings = @import("bindings.zig");
const catalog = @import("catalog.zig");
const facts = @import("facts.zig");
const query = @import("query.zig");
const targets = @import("targets.zig");

pub const Error = columns.Error || sets.Error || strings.Error || topology.Error || entities.Error || values.Error || bindings.Error || catalog.Error || facts.Error || error{
    MissingSection,
    UnsupportedInput,
    ConflictingDomain,
};

const Tag = enum(u32) { strings = 1, entities = 2, keys = 3, topology = 4, values = 5, bindings = 6, catalog = 7, facts = 8 };

pub const Owned = bytes.Owned;

pub fn build(allocator: std.mem.Allocator, input: model.Input) (Error || std.mem.Allocator.Error)!Owned {
    var pool = strings.Builder.init(allocator);
    defer pool.deinit();
    var entity_store = try entities.build(allocator, &pool, input.records);
    defer entity_store.deinit();
    var key_store = try keys.build(allocator, &pool, input.keys);
    defer key_store.deinit();
    var topology_store = try topology.build(allocator, &pool, input.documents, .{});
    defer topology_store.deinit();
    var value_store = try values.build(allocator, &pool, &topology_store, input.documents, input.values);
    defer value_store.deinit();
    var binding_store = try bindings.build(allocator, &topology_store, input.documents, input.records, input.bindings);
    defer binding_store.deinit();
    var catalog_store = try catalog.build(allocator, &pool, input.predicates, input.external_identity_domains, input.external_ranks);
    defer catalog_store.deinit();
    var fact_store = try facts.build(allocator, &pool, &topology_store, input.documents, input.records, input.external_ranks, input.facts);
    defer fact_store.deinit();
    var string_store = try pool.build(allocator);
    defer string_store.deinit();
    return bytes.buildArchive(allocator, &.{
        .{ .tag = @intFromEnum(Tag.strings), .data = string_store.bytes },
        .{ .tag = @intFromEnum(Tag.entities), .data = entity_store.bytes },
        .{ .tag = @intFromEnum(Tag.keys), .data = key_store.bytes },
        .{ .tag = @intFromEnum(Tag.topology), .data = topology_store.bytes },
        .{ .tag = @intFromEnum(Tag.values), .data = value_store.bytes },
        .{ .tag = @intFromEnum(Tag.bindings), .data = binding_store.bytes },
        .{ .tag = @intFromEnum(Tag.catalog), .data = catalog_store.bytes },
        .{ .tag = @intFromEnum(Tag.facts), .data = fact_store.bytes },
    });
}

pub fn Opened(comptime Source: type) type {
    const Span = bytes.Span(Source);
    return struct {
        strings: strings.ViewFor(Span),
        entities: entities.ViewFor(Span),
        keys: keys.ViewFor(Span),
        topology: topology.ViewFor(Span),
        values: values.ViewFor(Span),
        bindings: bindings.ViewFor(Span),
        catalog: catalog.ViewFor(Span),
        facts: facts.ViewFor(Span),

        const Self = @This();

        pub const ReadError = Error || bytes.SourceError(Source);

        pub fn validate(self: *const Self, allocator: std.mem.Allocator) (ReadError || std.mem.Allocator.Error)!Book(Source) {
            try self.strings.verify(allocator);
            var domains: model.DomainCatalogue = .{};
            try domains.setOwned(model.Domain{ .string = {} }, @intCast(self.strings.count()));
            try domains.setOwned(model.Domain{ .document = {} }, @intCast(self.topology.documents.row_count));
            try domains.setOwned(model.Domain{ .occurrence = {} }, @intCast(self.topology.occurrences.row_count));
            try domains.setOwned(model.Domain{ .fact = {} }, @intCast(self.facts.rows.row_count));
            try domains.setOwned(model.Domain{ .binding = {} }, @intCast(self.bindings.records.row_count));
            try domains.setOwned(.source_order, @intCast(self.bindings.source_order.row_count));
            try domains.setOwned(model.Domain{ .value = {} }, @intCast(self.values.rows.row_count));
            try domains.setOwned(model.Domain{ .text = {} }, 0);
            try self.catalog.declare(&domains);
            try self.entities.deriveDomains(&domains);
            const record_space = try model.RecordSpace.fromCatalogue(domains);
            try self.entities.verify(domains, self.strings);
            try self.keys.verify(allocator, self.strings, domains);
            try self.topology.verify(allocator, domains, self.strings);
            try self.bindings.verify(domains, record_space, self.topology);
            try self.catalog.verify(domains);
            try self.values.verify(allocator, domains, self.topology, self.catalog, self.strings);
            try self.facts.verify(domains, record_space, self.topology, self.catalog);
            return .{
                .strings = self.strings,
                .entities = self.entities,
                .keys = self.keys,
                .topology = self.topology,
                .values = self.values,
                .bindings = self.bindings,
                .catalog = self.catalog,
                .facts = self.facts,
                .domains = domains,
                .record_space = record_space,
            };
        }

        pub fn lookup(self: *const Self, match: query.Match) !query.Lookup(Source) {
            return .{
                .strings = self.strings,
                .keys = self.keys,
                .range = switch (match) {
                    .exact => |wanted| try self.keys.exact(wanted),
                    .prefix => |wanted| try self.keys.prefix(wanted),
                },
            };
        }
    };
}

pub fn Book(comptime Source: type) type {
    const Span = bytes.Span(Source);
    return struct {
        strings: strings.ViewFor(Span),
        entities: entities.ViewFor(Span),
        keys: keys.ViewFor(Span),
        topology: topology.ViewFor(Span),
        values: values.ViewFor(Span),
        bindings: bindings.ViewFor(Span),
        catalog: catalog.ViewFor(Span),
        facts: facts.ViewFor(Span),
        domains: model.DomainCatalogue,
        record_space: model.RecordSpace,

        const Self = @This();

        fn queryContext(self: *const Self) query.Context(Source) {
            return .{
                .bindings = self.bindings,
                .topology = self.topology,
                .strings = self.strings,
                .domains = self.domains,
                .record_space = self.record_space,
            };
        }

        pub fn lookup(self: *const Self, match: query.Match) !query.EntrySelection(Source) {
            return .{
                .lookup = .{
                    .strings = self.strings,
                    .keys = self.keys,
                    .range = switch (match) {
                        .exact => |wanted| try self.keys.exact(wanted),
                        .prefix => |wanted| try self.keys.prefix(wanted),
                    },
                },
                .capability = self.queryContext(),
            };
        }

        pub fn descendants(self: *const Self, scope: topology.Scope, namespace_uri: []const u8, local_name: []const u8) !topology.ViewFor(Span).Descendants(strings.ViewFor(Span)) {
            return self.topology.descendants(self.strings, scope, namespace_uri, local_name);
        }

        pub fn plainText(self: *const Self, occurrence: model.OccurrenceId, output: []u8) ![]const u8 {
            return self.topology.plainText(self.strings, occurrence, output);
        }

        pub fn plainTextSnippet(self: *const Self, occurrence: model.OccurrenceId, output: []u8) ![]const u8 {
            return self.topology.plainTextSnippet(self.strings, occurrence, output);
        }

        pub fn attributeByName(self: *const Self, occurrence: model.OccurrenceId, namespace_uri: []const u8, local_name: []const u8) !?strings.TextFor(Span) {
            return self.topology.attributeByName(self.strings, occurrence, namespace_uri, local_name);
        }

        pub fn effectiveLanguage(self: *const Self, occurrence: model.OccurrenceId) !topology.ViewFor(Span).Language {
            return self.topology.effectiveLanguage(self.strings, occurrence);
        }

        pub fn lookupXmlId(self: *const Self, document: model.DocumentId, id: []const u8) !?model.OccurrenceId {
            return self.topology.lookupXmlId(self.strings, document, id);
        }

        pub fn string(self: *const Self, id: model.StringId) strings.TextFor(Span) {
            return self.strings.text(id);
        }

        pub fn record(self: *const Self, comptime kind: model.Kind, id: model.Ref(kind)) !entities.StoredProperties {
            return self.entities.record(kind, id);
        }

        pub fn RecordsFor(comptime kind: model.Kind) type {
            return entities.ViewFor(Span).TableFor(kind);
        }

        pub fn records(self: *const Self, comptime kind: model.Kind) !RecordsFor(kind) {
            return self.entities.table(kind);
        }

        pub fn recordByIdentity(self: *const Self, comptime kind: model.Kind, identity: model.Identity) !?model.Ref(kind) {
            return self.entities.recordByIdentity(kind, identity, self.strings);
        }

        pub fn value(self: *const Self, id: model.ValueId) values.HandleFor(Span) {
            return self.values.handle(self.strings, id);
        }

        pub fn fact(self: *const Self, id: model.FactId) !facts.Fact {
            return self.facts.rows.field(.value, @intFromEnum(id));
        }

        pub fn predicate(self: *const Self, id: model.PredicateId) !catalog.Predicate {
            return self.catalog.predicate(id);
        }

        pub fn predicateName(self: *const Self, id: model.PredicateId) !strings.TextFor(Span) {
            return self.strings.text((try self.predicate(id)).name);
        }

        pub fn externalDomain(self: *const Self, id: model.ExternalDomainId) !catalog.ExternalIdentityDomain {
            return self.catalog.externalDomain(id);
        }

        pub fn externalScopes(self: *const Self, id: model.ExternalDomainId) !catalog.ViewFor(Span).ScopeCursor {
            return self.catalog.externalScopes(id);
        }

        pub fn externalKeys(self: *const Self, id: model.ExternalDomainId) !catalog.ViewFor(Span).KeyCursor {
            return self.catalog.externalKeys(id);
        }

        pub fn elementName(self: *const Self, occurrence: model.OccurrenceId) !?topology.Name {
            return self.topology.elementName(occurrence);
        }

        pub fn namespaces(self: *const Self, occurrence: model.OccurrenceId) !topology.ViewFor(Span).NamespaceCursor {
            return self.topology.namespacesOf(occurrence);
        }

        pub fn attributes(self: *const Self, occurrence: model.OccurrenceId) !topology.ViewFor(Span).AttributeCursor {
            return self.topology.attributesOf(occurrence);
        }

        pub fn events(self: *const Self, scope: topology.Scope) !topology.ViewFor(Span).EventCursor {
            return self.topology.eventsIn(scope);
        }

        pub fn sources(self: *const Self, reference: model.AnyRef, role: model.BindingRole) query.SourceSelection(query.RecordSources(Source), Source) {
            return .{ .producer = .{
                .capability = self.queryContext(),
                .record = reference,
                .role = role,
            } };
        }

        pub fn source(self: *const Self, handle: model.SourceHandle) query.SourceSelection(query.SingletonSource(Source), Source) {
            return .{ .producer = .{
                .capability = self.queryContext(),
                .handle = handle,
            } };
        }

        pub fn claimsFrom(self: *const Self, reference: model.AnyRef) !facts.ViewFor(Span).ClaimCursor {
            return self.facts.claimsFrom(reference, self.record_space);
        }

        pub fn claimsTo(self: *const Self, reference: model.AnyRef) !facts.ViewFor(Span).ClaimCursor {
            return self.facts.claimsTo(reference, self.record_space);
        }

        pub fn claimsMatching(self: *const Self, subject: targets.Target) facts.ViewFor(Span).ClaimScan {
            return self.facts.claimsMatching(subject);
        }

        pub fn claimsTargeting(self: *const Self, target: targets.Target) facts.ViewFor(Span).ClaimScan {
            return self.facts.claimsTargeting(target);
        }
    };
}

pub fn open(source: anytype) (Error || bytes.SourceError(@TypeOf(source)))!Opened(@TypeOf(source)) {
    const Source = @TypeOf(source);
    const archive = try bytes.ArchiveFor(Source).open(source);
    const Span = bytes.Span(Source);
    const string_section = (try archive.section(@intFromEnum(Tag.strings))) orelse return error.MissingSection;
    const entity_section = (try archive.section(@intFromEnum(Tag.entities))) orelse return error.MissingSection;
    const key_section = (try archive.section(@intFromEnum(Tag.keys))) orelse return error.MissingSection;
    const topology_section = (try archive.section(@intFromEnum(Tag.topology))) orelse return error.MissingSection;
    const value_section = (try archive.section(@intFromEnum(Tag.values))) orelse return error.MissingSection;
    const binding_section = (try archive.section(@intFromEnum(Tag.bindings))) orelse return error.MissingSection;
    const catalog_section = (try archive.section(@intFromEnum(Tag.catalog))) orelse return error.MissingSection;
    const fact_section = (try archive.section(@intFromEnum(Tag.facts))) orelse return error.MissingSection;
    return .{
        .strings = try strings.ViewFor(Span).open(string_section),
        .entities = try entities.ViewFor(Span).open(entity_section),
        .keys = try keys.ViewFor(Span).open(key_section),
        .topology = try topology.ViewFor(Span).open(topology_section, .{}),
        .values = try values.ViewFor(Span).open(value_section),
        .bindings = try bindings.ViewFor(Span).open(binding_section),
        .catalog = try catalog.ViewFor(Span).open(catalog_section),
        .facts = try facts.ViewFor(Span).open(fact_section),
    };
}

test "vertical archive supports bounded keys and validated source traversal" {
    const occurrences = [_]model.OccurrenceInput{
        .{ .name = .{ .namespace_uri = "", .local_name = "entry" }, .content = &.{.{ .child = @enumFromInt(1) }} },
        .{ .name = .{ .namespace_uri = "", .local_name = "definition" }, .content = &.{.{ .text = "animal" }} },
    };
    const documents = [_]model.DocumentInput{.{ .scope = "d", .occurrences = &occurrences, .content = &.{.{ .child = @enumFromInt(0) }} }};
    const records = [_]model.RecordInput{
        .{ .entry = .{ .written = "cat", .features = @enumFromInt(1), .external_id = .{ .text = "e-cat" } } },
        .{ .definition = .{} },
    };
    const value_inputs = [_]model.ValueInput{
        .{ .string = "normalized animal" },
        .{ .product = .{ .type_label = "entry", .fields = &.{.{ .name = "definition", .value = @enumFromInt(0) }} } },
    };
    const key_inputs = [_]model.KeyInput{.{ .headword = .{ .key = "cat", .entry = @enumFromInt(0) } }};
    const binding_inputs = [_]model.BindingInput{
        .{
            .record = .{ .entry = @enumFromInt(0) },
            .source = .{ .occurrence = .{ .document = @enumFromInt(0), .occurrence = @enumFromInt(0) } },
        },
        .{
            .record = .{ .definition = @enumFromInt(0) },
            .source = .{ .occurrence = .{ .document = @enumFromInt(0), .occurrence = @enumFromInt(1) } },
        },
    };
    const predicates = [_]model.PredicateInput{.{ .name = "related" }};
    const fact_inputs = [_]model.FactInput{.{ .relation = .{
        .subject = .{ .record = .{ .entry = @enumFromInt(0) } },
        .predicate = @enumFromInt(0),
        .object = .{ .record = .{ .entry = @enumFromInt(0) } },
    } }};
    var owned = try build(std.testing.allocator, .{
        .documents = &documents,
        .records = &records,
        .keys = &key_inputs,
        .bindings = &binding_inputs,
        .predicates = &predicates,
        .facts = &fact_inputs,
        .values = &value_inputs,
    });
    defer owned.deinit();
    const archive_bytes: []const u8 = owned.bytes;
    const opened = try open(archive_bytes);
    const Returned = struct {
        fn validate(local: Opened([]const u8)) !Book([]const u8) {
            return local.validate(std.testing.allocator);
        }

        fn openedLookup(local: Opened([]const u8)) !query.Lookup([]const u8) {
            return local.lookup(.{ .exact = "cat" });
        }

        fn lookup(local: Book([]const u8)) !query.EntrySelection([]const u8) {
            return local.lookup(.{ .exact = "cat" });
        }

        fn text(local: Book([]const u8), id: model.StringId) strings.TextFor(bytes.Span([]const u8)) {
            return local.string(id);
        }

        fn value(local: Book([]const u8), id: model.ValueId) values.HandleFor(bytes.Span([]const u8)) {
            return local.value(id);
        }
    };
    const bounded = try Returned.openedLookup(opened);
    var bounded_hits = bounded.iterator();
    var output: [32]u8 = undefined;
    try std.testing.expectEqualStrings("cat", try (try bounded_hits.next()).?.key.render(&output));
    const book = try Returned.validate(opened);
    var record_sources = book.sources(.{ .entry = @enumFromInt(0) }, .realization).iterator();
    try std.testing.expectEqual(model.SourceHandle{ .occurrence = @enumFromInt(0) }, (try record_sources.next()).?);
    var attached = book.source(.{ .occurrence = @enumFromInt(0) }).bindings(.entry, .attached).iterator();
    try std.testing.expectEqual(@as(model.Ref(.entry), @enumFromInt(0)), (try attached.next()).?.record);
    var claims = try book.claimsFrom(.{ .entry = @enumFromInt(0) });
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum((try claims.nextRun()).?.lo));
    var incoming = try book.claimsTo(.{ .entry = @enumFromInt(0) });
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum((try incoming.nextRun()).?.lo));
    const entry = try book.record(.entry, @enumFromInt(0));
    const entries = try book.records(.entry);
    const identities = entries.project(.{.external_id});
    try std.testing.expectEqualDeep(entry.external_id, try identities.at(@enumFromInt(0)));
    const empty_sources = try book.records(.source);
    try std.testing.expectEqual(@as(usize, 0), empty_sources.count());
    try std.testing.expectError(error.IndexOutOfBounds, empty_sources.at(@enumFromInt(0)));
    const origins = try (try book.lookup(.{ .exact = "cat" })).project(.{.origin});
    try std.testing.expectEqual(keys.Origin{ .headword = @enumFromInt(0) }, try origins.at(0));
    try std.testing.expectEqual(@as(model.Ref(.entry), @enumFromInt(0)), (try book.recordByIdentity(.entry, .{ .text = "e-cat" })).?);
    const normalized = (try book.value(entry.features.?).field("definition")).?;
    try std.testing.expectEqual(@as(usize, 17), try normalized.byteLength());
    try std.testing.expectEqualStrings("normal", try normalized.snippet(output[0..6]));
    try std.testing.expectEqualStrings("normalized animal", try normalized.render(&output));
    const returned_text = Returned.text(book, entry.written.?);
    try std.testing.expectEqualStrings("cat", try returned_text.render(&output));
    const returned_value = Returned.value(book, entry.features.?);
    try std.testing.expect((try returned_value.field("definition")) != null);
    const returned_query = try Returned.lookup(book);
    var returned_hits = returned_query.iterator();
    try std.testing.expectEqualStrings("cat", try (try returned_hits.next()).?.key.render(&output));
    try std.testing.expectEqualStrings("related", try (try book.predicateName(@enumFromInt(0))).render(&output));
    const text_plan = (try book.lookup(.{ .exact = "cat" })).sources(.realization).descendants(.definition).texts();
    var text_chain = text_plan.iterator();
    const text = (try text_chain.next()).?;
    try std.testing.expectEqualStrings("animal", try text.render(&output));
    const source_plan = (try book.lookup(.{ .exact = "cat" })).sources(.realization);
    var projected_bindings = source_plan.bindings(.definition, .within).iterator();
    try std.testing.expectEqual(@as(model.BindingId, @enumFromInt(1)), (try projected_bindings.next()).?.binding_id);
    var descendants = try book.descendants(.{ .occurrence = @enumFromInt(0) }, "", "definition");
    const definition = (try descendants.nextHandle()).?;
    try std.testing.expectEqualStrings("animal", try book.plainText(definition, &output));
}
