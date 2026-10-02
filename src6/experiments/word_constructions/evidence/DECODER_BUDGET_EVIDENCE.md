# Private native-v4 prepared decoder allocation cap

The unchanged v4 `Model.read` accepts up to 32,768 rows and 67,108,864
row-symbol cells. `Model.init` allocates two `u16` tables immediately, so an
admitted model may request 268,435,456 bytes before its row contents are
decoded. An all-log-13 row table would imply a 2,147,483,648-byte `Cell`
array by the raw row-count formula, but the unchanged `Model.layout`
rejects that case first because row start units must fit in `u18`. The
concrete admitted gap is the immediate 256 MiB
`norm`+`next` request. The previous WPG2 preflight bounded native header
**length** to 8 MiB but did not bound these allocations.

A reproducible 18-byte v4 frame in
`/workspace/scratch/gwt1-header-bomb/wide-model.bz4` has only a 12-byte
arithmetic-coded model header. Zig's own `binary.Decoder` reads `log=13` and
scalars `[2045, 32767, 0, 0, 0, 0, 0, 0]`: 2,046 buckets, 32,768 rows,
2,048 symbols and exactly 67,108,864 cells, all within the old scalar
limits. A resealed WPG2 envelope is only 37 bytes. The old direct Decoder
returned `OutOfMemory` under a 128 MiB address-space limit. The generator
and scalar probe are in the adjacent scratch fixture directory.

The private `prepared_jobs.zig` now gives the unchanged v4 Decoder arena and
the immutable Job directory one stable `Budget` with a strict
536,870,912-byte live-request cap. It is stored in `Prepared`, so the arena's
allocator pointer remains valid until `wpg_close`. Allocation, resize,
remap, and free all update live/peak counts. Failure unwinds the decoder and
Job directory; the direct wide-header probe returned `OutOfMemory`,
`peak=201334444`, `live=0`. The private C ABI exposes
`wpg_budget_stats(handle, live, peak, limit)` for review and benchmarking.
The encoded frame and caller output buffers have separate explicit envelope
bounds and are not charged against this decoder-only cap. Original native-v4
source and frame bytes were not changed.

| Admitted native frame | Raw bytes | Jobs | Decoder budget peak |
| --- | ---: | ---: | ---: |
| GCIDE GWT1 quality, 8 MiB | 8,388,608 | 128 | 21,612,924 B |
| OMW WPG2 strong hoist, 8 MiB original | 5,613,360 transformed | 86 | 7,106,360 B |
| OMW WPG2 DP, 8 MiB original | 5,613,360 transformed | 86 | 5,409,398 B |
| Japanese v4, 22 MiB | 23,068,672 | 352 | 28,857,302 B |

The new cap leaves substantial headroom above these actual live peaks.
The 8 MiB GCIDE GWT1 native decode still matches source SHA-256
`8b93c30f4a5d659f879af5fc7db9de38ee524cc07b91ada7be2905cf5aaf519b`.
The OMW WPG2 strong-hoist full native reader output still matches its saved
pre-cap source SHA-256
`d76875c462ecbadb0e9bc6efb371c598a2197fcc0ff5bf53e722ea2674037261`.

Validation after rebuilding `libwpgjobs.a`, `prepared_wpg`, and
`prepared_geometry`: Zig budget tests 2/2 passed, WPG2 registration and
archive tests 5/5 passed, the independent WPG2 review passed 464 constructor
cases plus malformed-frame cases, and GWT1 passed 39 native archive cases
(six valid, 33 rejected). GWT1's resealed wide-header `inspect` and `decode`
both reject; failed full decode leaves an existing destination untouched.

The post-budget source and runtime hashes are in
`wpg2-post-budget-manifest.sha256`. Earlier manifests remain as historical
snapshots of the reader before the cap. Final ranked native reader timings
must use the newly linked binaries and identify their hashes.
