# LEX5 host and native correctness bridge

This package is the host-only preparation layer for the `LEX5-BENCH/1`
campaign. It imports the unchanged `bench4` fixture/oracle and provenance
helpers read-only, and records the accepted LEX4 control ledger plus the
future protocol, coverage, timing, build, and comparison contracts.
The exact old-five-fixture to LEX5 field/projection ledger is retained at
`experiments/frontier/lex5-20260909/benchmark/semantic-mapping-ledger.md` and
hashed into the readiness document.
The pure JSON-to-neutral-row handoff is specified in
`experiments/frontier/lex5-20260909/benchmark/input-lowering-contract.md` and
implemented only by the host validator in `bench5/lowering.py`.

`bench5/native.py` is the candidate native subprocess bridge. It compiles the
real `model.Input`/`Book` implementation against the frozen foundation-11
source, builds complete candidate artifacts, reopens and verifies them, audits
all stored semantic fields from the archive, and serves artifact-only JSONL
queries. Expected answers remain in the imported bench4 oracle and are compared
in memory; no schedule or answer table is sent to the native process or written
to an artifact. Root review remains pending. The optional native `reader_self`
timing boundary is prepared, but no timing campaign is enabled here.

Run the focused checks with:

```text
python3 -m unittest discover -s bench5 -p 'test_*.py' -v
```

Regenerate the host readiness ledger with:

```text
python3 bench5/host.py --output experiments/frontier/lex5-20260909/benchmark/readiness.json
```

Run the bounded five-fixture native correctness sweep (2048 records and 4000
oracle-checked requests per fixture) with:

```text
python3 -m bench5.native --output experiments/frontier/lex5-20260909/benchmark/native/correctness.json
```

The separate `--bench5-verify` boundary is subprocess wall time, including
launch and artifact open/load as well as verification. Native inner labels
`verify_reader_ns` and `open_envelope_reader_ns` remain reserved for the later
adapter.
