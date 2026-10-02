# Runtime 2: bounded LaneA seed workspace

`m_reference_reclaim.zig` is a versioned replacement for `m_reference.zig`.
It uses the same 4 GiB live allocation budget and the unchanged LaneA,
LaneM, and native fitting algorithms. The five LaneA seed candidates run in
their original order. Their temporary workspaces use the existing
`reclaim_scope.zig` allocator, so frees inside `grammar2.zig` release temporary
tables and reparses promptly. Each candidate's surviving grammar is copied
into the original seed arena before its workspace closes. LaneM's allocator
and all model decisions remain unchanged.

`budget_reclaim.zig` reports a failed allocator request with the current
phase, requested and live bytes, peak, and whether the 4 GiB quota or its
parent allocator refused the request. Some failed in-place resize requests
are normal because the allocator retries elsewhere; the final error line
records the phase and latest failed request if encoding stops.

Build into a repository-local output directory:

```sh
ZIG=/home/agent/.local/bin/zig \
  src6/experiments/wordgrammar/wgp6/runtime2_build.sh \
  src6/experiments/wordgrammar/wgp6/runtime2-backend
```

The build produces corrected `m_reference` and four unchanged helpers:
`native`, `native_forward`, `native_forward_hoist`, and `reparse_context`.
The repository ignores the example `runtime2-backend/` directory. Use a
separate ignored directory for any other local backend. No original backend
binary, learner source, Makefile, WPG2 policy, or final benchmark manifest is
modified by this build.

Development fidelity and resource evidence is in
`RUNTIME2_RESOURCE_REPORT.md` and `evidence/runtime2-dev-proof.json`.
The final corpus requires a separate, explicitly versioned run by the
benchmark owner.
