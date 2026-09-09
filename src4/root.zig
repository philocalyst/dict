//! LEX4's public surface. Modules graduate into this namespace only after
//! their wire invariants, differential tests, and benchmark ablations pass.

pub const schema = @import("schema.zig");
pub const wire = @import("wire.zig");
pub const table = @import("table.zig");
pub const container = @import("container.zig");
pub const cold = @import("cold.zig");
pub const automaton = @import("automaton.zig");
pub const forest = @import("forest.zig");
pub const grammar = @import("grammar.zig");
pub const bitvector = @import("bitvector.zig");
pub const entropy = @import("entropy.zig");
pub const rank = @import("rank.zig");
pub const snapshot = @import("snapshot.zig");
pub const compiler = @import("compiler.zig");
pub const text_index = @import("text_index.zig");
pub const axes = @import("axes.zig");
pub const search = @import("search_product.zig");
pub const terms = @import("terms.zig");
pub const concepts = @import("concepts.zig");
pub const relations = @import("relations.zig");
pub const rich_content = @import("rich_content.zig");

pub const Layer = schema.Layer;
pub const Kind = schema.Kind;
pub const KindSet = schema.KindSet;
pub const Node = schema.Node;
pub const Rank = schema.Rank;
pub const Snapshot = snapshot.Snapshot;
pub const Query = snapshot.Query;
pub const Entry = snapshot.Entry;
pub const EntryRank = snapshot.EntryRank;

test {
    _ = schema;
    _ = wire;
    _ = table;
    _ = container;
    _ = cold;
    _ = automaton;
    _ = forest;
    _ = grammar;
    _ = bitvector;
    _ = entropy;
    _ = rank;
    _ = snapshot;
    _ = compiler;
    _ = text_index;
    _ = axes;
    _ = search;
    _ = terms;
    _ = concepts;
    _ = relations;
    _ = rich_content;
}
