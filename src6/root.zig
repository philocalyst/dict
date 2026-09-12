//! LEX6: typed lexical documents with independently compressed entry pages.
pub const model = @import("model.zig");
pub const query = @import("query.zig");
pub const render = @import("render.zig");
pub const validate = @import("validate.zig");
pub const archive = @import("archive.zig");
pub const compression = @import("compression.zig");

test {
    _ = @import("model_test.zig");
    _ = @import("semantic_test.zig");
    _ = @import("walk_test.zig");
    _ = @import("packet_test.zig");
    _ = @import("compression_test.zig");
    _ = @import("archive_test.zig");
}
