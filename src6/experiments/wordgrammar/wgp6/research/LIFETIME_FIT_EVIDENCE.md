# Bounded faithful Lane A + M native fit: allocation and fidelity evidence

The private `lifetime_fit.zig` calls the frozen native v4 baseline planner and
encoder in the same class order and with the same measured bucket uses as
`bz4.plan.fit`. It releases each losing class trial arena before trying the
next class. The returned winner contains only the owning frame bytes and the
selected class count; it cannot retain a pointer into a released trial. The
learner epoch and seed lifetime work lives in `learner_epochs.zig` and
`m_reference.zig`, maintained separately. These changes alter allocation
lifetimes, not the Lane A or M procedures or native frame format.

## Exact output and memory

The retained historical controls in
`/workspace/scratch/wgp6/m-faithful-8m` were made with original
`m_reference.zig` SHA256
`4472ed59049329d87749303fd924f390e0be2a6463f9432e35c2ba075f71cc25`
and binary SHA256
`8bca12bdfffaf41d2fe39278eb2a5f9f2591da2560944c0b871ff005b63fec73`.
The bounded integrated run used source SHA256
`f046619191388287e6ae1697a43253682ec8c02ee814f969a8660f15b0301425`
and binary SHA256
`4f7faf921798b7f56d8f85eaa990e1d3da73655e996bc95df33140e84adb2060`.
The latter binary was copied to the read-only snapshot
`/workspace/scratch/wgp6/lifetime-fit-provenance/m_reference-4f7faf921798b7f5`.
The original `m_lexicon.zig` and `grammar2.zig` hashes are unchanged:
`a49bf471bbaa90332bb13c20f1eaccabf1e04d716e2dae9a1ae519736ac77f90`
and `d78548b8625421713009b475f961880b5e0cb996ecfad045244df56ffb153a62`.
The frozen native planner and encoder hashes are
`0e98a6cc7b2a94ca85501f1a17b0b5124e7d0ff7eb39179ca3ef40a72bf55c4d`
and `f272401694b481a06eff5ab7318613af95b63328a2544954d2c9b5b465059349`.

| 8 MiB corpus | Exact old/new default frame | Default whole encoder peak | Seed / M learning / native fit peaks |
| --- | ---: | ---: | ---: |
| FreeDict | 564,416 B | 1,350,742,082 B | 1,350,742,082 / 600,313,540 / 365,307,171 B |
| GCIDE | 1,279,033 B | 3,641,298,390 B | 3,641,298,390 / 540,976,752 / 797,533,554 B |
| Japanese OMW | 331,721 B | 763,396,574 B | 763,396,574 / 723,629,898 / 232,958,513 B |

All three `m-epochs-8m` default frames compare byte for byte to the retained
historical frame files. Their SHA256 values are, in table order,
`cac3fbb0c159988e0db8b11856611125cf1f90252a2bf8ff454912f8f14a4580`,
`384b559fe139acfe2c0506f3679ff987de1edd253141b2b6346da85955d2085a`,
and `96d9cb80ebfa39331cae101ae96fd693e8b6e12e1e4ef029b4f6083fe07544c1`.
Each integrated 8 MiB default and hoisted frame also passed fresh full decode
and every block's fresh restart extraction. Raw source, frame, source, and
binary hashes are in `/workspace/scratch/wgp6/m-epochs-8m/rows.jsonl`.

The first 22 MiB of the Japanese development content was admitted under the
same live 4 GiB allocation limit in both settings. Default: 906,545-byte
frame; hoisted: 949,206-byte frame. Both fresh-decode to all 23,068,672
original bytes. Whole encoder peak was 2,335,229,020 B in each run; seed
peak 2,163,318,974 B and learning peak 2,335,229,020 B. Native fit peaks
were 555,935,058 B default and 445,019,697 B hoisted. The two detailed
records are in `/workspace/scratch/wgp6/m-epochs-22m/rows.jsonl`.
The 22 MiB raw SHA256 is
`afc08b9be7c16d6354c57c38b9bc438e9db50c4eb8a177ca257c121d7d4d509f`;
default and hoisted frame hashes are
`bf71dd2455a63ce9fe83f3c0e219765431538c434d18385da192913795413bb0`
and `9f5dc2db0283032817860d8ed0e67784d903d16809051e619be70fd5eaaeb009`.

## Native fit isolated from learning

`lifetime_fit_probe.zig` accepts a retained trusted `P6F1` parse and runs
either the original or lifetime native fit under the same 4 GiB `Budget`.
The source SHA256 is
`bf0e9a54c5fe84c15331cf8ddacf3b9ec0ef64940fa8ac2f098424c8562dd280`;
the built binary SHA256 is
`99451e7da57b9f002e6ead8ada5d15e45d314a2abc3688eea509e518c2b3788d`,
preserved at
`/workspace/scratch/wgp6/lifetime-fit-provenance/lifetime_fit_probe-99451e7da57b9f00`.
The `lifetime_fit.zig` source SHA256 is
`d4e38b884438505fd8b90e47c10ee4c5f5c12aa20fbc1ec2b14c2bd4a203ca52`.

| Retained 8 MiB parse | Isolated lifetime fit peak | Frame bytes | Selected classes |
| --- | ---: | ---: | ---: |
| FreeDict | 356,432,157 B | 564,416 | 64 |
| GCIDE | 787,064,124 B | 1,279,033 | 128 |
| Japanese OMW | 225,655,095 B | 331,721 | 64 |

All three isolated output files in `/workspace/scratch/wgp6/m-fit-only-8m-*.frame`
compare byte for byte to the historical 8 MiB controls. On retained 1 MiB
hoisted parses, the original and lifetime fit also agreed exactly: OMW
47,208 B/class 1 with allocator peaks 14,577,163 B versus 12,242,631 B;
GCIDE 198,488 B/class 32 with peaks 122,506,443 B versus 64,966,375 B.
Those output files are in `/workspace/scratch/wgp6/m-fit-probe-1m-*-hoist-*.frame`.

The `Budget` peak is the maximum sum of live allocation requests crossing
its allocator, including arena chunks and the encoded frame. It is not
process RSS or system page cache. The 4,294,967,296-byte cap remained in
force. Phase peaks are measured after resetting the peak counter to current
live usage at the phase boundary, so they include any data that remains live
from earlier phases. Historical uncapped control runs did not measure live
allocator peaks; no before/after whole-encoder memory ratio is inferred from
them. The GCIDE seed peak is close to the cap and is the next scaling risk.

To rebuild and run the native fit check from the `wgp6` directory:

```sh
zig test --dep bz4 -Mroot=lifetime_fit.zig -Mbz4=../../bzip4/bz4/v3/src/root.zig
zig build-exe --dep bz4 -O ReleaseFast -Mroot=lifetime_fit_probe.zig -O ReleaseFast -Mbz4=../../bzip4/bz4/v3/src/root.zig -femit-bin=/workspace/scratch/wgp6/lifetime_fit_probe
/workspace/scratch/wgp6/lifetime_fit_probe /workspace/scratch/wgp6/m-faithful-8m/freedict.forward /workspace/scratch/wgp6/recheck.frame 0 lifetime
cmp /workspace/scratch/wgp6/recheck.frame /workspace/scratch/wgp6/m-faithful-8m/freedict.frame
```

The direct unit test compares exact frames, class choices, and decoded bytes
against the frozen fit for a graph with forward references in default,
hoisted, and fixed-class settings. Both Debug and ReleaseFast tests passed.
