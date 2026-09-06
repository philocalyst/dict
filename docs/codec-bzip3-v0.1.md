# Independent payload codecs v0.1

The reusable codec layer is in [`src/codec.zig`](../src/codec.zig).  It has two
explicit wire kinds:

| Kind | Default | Behavior |
|---|---:|---|
| `raw` | yes | Copies bytes exactly; useful for tiny or latency-critical values |
| `bzip3` | no | Encodes one independently addressable block with pinned upstream libbz3 |

The default is intentionally raw.  A compiler or caller must opt into bzip3
after measuring the workload and can record the selected kind beside each
block.  Both kinds return an owned block and preserve an explicit
`original_size`, so switching codecs cannot change lexical meaning.

## Bzip3 contract

`src/codec/bzip3.zig` wraps only the low-level `bz3_new`,
`bz3_encode_block`, `bz3_decode_block`, `bz3_bound`,
`bz3_min_memory_needed`, and decode-capacity probe APIs, plus the version
function.  One `Encoder` or `Decoder` owns one native state and is not shared
between concurrent operations.  The one-shot helpers create and destroy that
state around one block.

The state block-size range is checked against upstream's documented 65 KiB to
511 MiB range and the C `int32_t` ABI.  Before allocation, the wrapper checks:

- configured block, compressed, and original lengths;
- checked arithmetic around `bz3_bound`;
- `bz3_min_memory_needed(block_size) + bz3_bound(block_size)` against the
  caller's memory limit;
- the upstream capacity probe, reserving the full configured block workspace
  when intermediate LZP/RLE data can exceed the final text size.

The decoder copies compressed bytes into its mutable work buffer, validates the
returned output length against the declared original size, maps upstream error
codes to typed Zig errors, and frees the complete allocation on every failure
path.  It never invokes the high-level bzip3 frame API for snapshot payloads.

## Verification

The codec tests cover empty and short literal blocks, Unicode and arbitrary
bytes, repetitive 120 KiB blocks, resource limits, corrupted CRC data, raw and
bzip3 semantic equivalence, and interoperability with an upstream high-level
multi-block frame.  Debug and ReleaseSafe are both required to pass:

```text
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
```

The upstream high-level frame helper in this pinned release computes its last
block size as `in_size % block_size` even when only one exact or partial block
exists.  The differential fixture therefore uses two full-sized blocks plus a
nonempty remainder.  Lexicon does not rely on that helper and does not expose
its frame behavior.

