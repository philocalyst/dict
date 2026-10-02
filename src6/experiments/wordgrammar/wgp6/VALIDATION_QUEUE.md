# Validation of the post-capture research pipeline

The measured maximal spelling results in `RESULTS.md` were produced with
native binaries, fresh decoded in full, and recorded before this queue.
The subsequently added concrete pipeline (`encode.py`, `native.zig`,
`test_pipeline.py`) and NAME-terminal variant are source-only until the
following checks run. Do not register them as verified final candidates or
claim new results from their source alone.

The parent released the quiet capture before these checks ran. The frozen
WGP5 source/binary and independent safety audit are unchanged by this
research directory. The concrete pipeline and NAME variant have now been
built and tested; remaining large-pipeline verification is listed below.

1. Format the new C++ and Zig sources without semantic changes.
2. Build `make ZIG=/home/agent/.local/bin/zig`, then run `make test` with the
   same Zig path. The suite checks complete-frame argmin and encoder-time
   sums; fresh full decode; every restart in a fresh decoder process;
   deterministic encoded bytes; arbitrary/invalid UTF-8, all byte values,
   random and tiny sources; private graph cycles/CUT bounds/class validation;
   and price-matrix resource rejection before model fitting.
3. Compile the retained selected 8 MiB parse graphs with the new native
   wrapper and require byte-identical frames to the existing evidence.
   Decode and extract every restart from those frames, comparing exact raw
   spans. This validates the wrapper without inventing a new size result.
4. Run the complete fixed pipeline once on all three retained old 8 MiB
   development inputs, recording all source/binary/backend hashes and every
   intermediate full-frame size. Require the same selected sizes as the
   already measured graph family. Verify all selected restart payloads.
5. Build `prepare_nameprice native_nameprice` and run the isolated 1 MiB
   native screen with the same global parameters:

   ```
   python3 context_screen.py /workspace/scratch/wgp6/name-terminal-1m \
     --size 1048576 --corpora freedict,gcide,omw --classes 0 --floor 0 \
     --steps 4 --once 1 --max-fragment 128 --prepare ./prepare_nameprice \
     --compiler ./native_nameprice --combined
   ```

   This is only an old-development ablation. Preserve any loss as a negative
   result. It does not change the fixed maximal pipeline or the frozen WGP5
   policies. No held-out observations may guide its policy.

6. Freeze source/binary hashes after successful checks. If reporting speed,
   run serial paired complete decode with the actual old native frames;
   separately report model/delta preparation and payload work for extraction.
   The old decoder is unchanged, but an identical decoder alone is not
   evidence of equal memory or latency for a changed dictionary graph.

Completed after release: formatting/build; all five `test_pipeline.py`
tests; initial and conditional 1 MiB GCIDE spelling preparations under
ASAN/UBSAN and exact native decode; complete 1/8 MiB NAME screens; both
1 MiB separated-role screens; fresh full decode and every restart for
all three hoisted maximal graphs; faithful Lane M reference regeneration;
byte-identical epoch-lifetime refactor on all three 8 MiB references in
both profiles; real development 22 MiB Japanese fresh roundtrip in both
profiles under the 4 GiB allocator budget; native fit helper tests and
independent Sol fidelity audit; all four context-tiler integrity tests.

Completed step 3: all three retained selected 8 MiB graphs compiled through
the concrete native wrapper byte-identically to their archived frames, with
fresh full decode and every selected restart verified.

Still outstanding for the original `encode.py` policy: step 4's full
encoder/parser pipeline 8 MiB reproduction.
The follow-up M/context family is a distinct research policy with its own
fingerprints, complete-frame ledger, and final validation scope.
