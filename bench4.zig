//! Benchmark executable entrypoint.  The implementation remains in bench4/
//! so the benchmark-specific code is easy to audit separately from src4.
const impl = @import("bench4/bench_main.zig");
pub const main = impl.main;
