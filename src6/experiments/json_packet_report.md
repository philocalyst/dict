# JSON versus the LEX6 packet: bounded experiment

Status: exploratory evidence only. This is not a production codec switch and
does not change the `src6` public module graph. No timing measurements were
taken.

## Question and method

Zig 0.16's reflective JSON implementation can walk the current recursive
model directly: slices become arrays, structs become objects, tagged unions
become one-key objects, and enums use their tag names. The experiment aliases
the exact `Entry` type of `fixtures.rich` (the fixture is declared as the
production `model.Entry`) and compares it with `packet.encode`/`packet.decode`.

JSON uses:

```zig
std.json.Stringify.value(value, .{
    .emit_null_optional_fields = false,
    .emit_strings_as_arrays = false,
    .emit_nonportable_numbers_as_strings = false,
}, writer)
```

and `std.json.parseFromSliceLeaky` inside an owned `std.heap.ArenaAllocator`.
The arena is released by `OwnedJson.deinit`; “leaky” here means leaky to the
arena, not to the caller. `std.json.Stringify.valueAlloc` was also checked in
the Zig 0.16 source, but the experiment uses `Stringify.value` with a budgeted
writer so temporary output capacity is bounded too.

Before reflection, `preflightJson` scans the complete input with
`std.json.Scanner`. It enforces `max_input_bytes`, `max_tokens`, and
`max_depth`; a capped child allocator bounds scanner stack growth to a small
multiple of the admitted depth. Parsing uses an explicit budget allocator and
the caller chooses `max_allocation_bytes`. This bounds admitted heap memory,
but the parser remains recursive and therefore still consumes call stack
proportional to the admitted depth. JSON's standard `ParseOptions` has no
native depth or total-allocation limit.

The standalone Debug command used for the measurements was:

```text
/etc/profiles/per-user/mileswirht/bin/zig test \
  -cflags -std=c99 -Ivendor/bzip3/include -DVERSION='"1.5.1"' \
  -fno-sanitize=undefined -- vendor/bzip3/src/libbz3.c \
  --dep compression --dep fixtures --dep packet \
  -O Debug -Mroot=src6/experiments/json_packet.zig \
  -Ivendor/bzip3/include -O Debug -Mcompression=src6/compression.zig \
  -O Debug -Mfixtures=src6/fixtures.zig \
  -O Debug -Mpacket=src6/packet.zig -lc
```

The `-O Debug` placement is intentional: Zig resets per-module options at
each `-M` declaration.

## Exact size and round-trip evidence

Each row contains the same repeated complete rich entry value, not a partial
field projection. `packet` and `json` are the complete uncompressed serialized
byte strings. The final columns are the complete forced low-level bzip3 block
bytes for those strings, including bzip3's block metadata. Both compressed
blocks were decoded and compared byte-for-byte with their own uncompressed
input. A shared archive directory is not included in either candidate, so no
candidate receives a directory accounting advantage here.

| entries | packet bytes | JSON bytes | packet bzip3 bytes | JSON bzip3 bytes |
| ---: | ---: | ---: | ---: | ---: |
| 32 | 31,110 | 182,433 | 597 | 1,220 |
| 256 | 248,839 | 1,459,457 | 600 | 1,220 |
| 2,048 | 1,990,663 | 11,675,649 | 601 | 1,224 |

All five experiment tests passed in Debug. The packet and JSON values were
deep-compared by content (not `std.meta.eql`, which deliberately compares a
slice's pointer and length). The bzip3 restores were separately checked with
`std.mem.eql(u8, ...)`. The small compressed sizes are expected for this
deliberately repeated rich fixture; they are not a claim about an
incompressible corpus.

## Semantic and hostile-input checks

The edge fixture and parser tests establish the following:

- `Source.bytes` containing invalid UTF-8 is emitted as a JSON number array
  (`[255,0,128,65,195,169]`) and parses back to the exact bytes. Valid UTF-8
  strings remain JSON strings (also exercised by the rich fixture).
- `i64` minimum and maximum values survive the JSON number path exactly.
- Non-default enum tags (`free`, `style`, `stem`, `transliteration`, and
  `deprecated`) and nontrivial union tags (`reset`, `custom`, `resource`,
  `unresolved`, and `default`) survive deep comparison. The current model's
  added `Translation.content` default is also traversed in the rich-group
  rows.
- An omitted `Metadata.language` field receives its declared `.inherit`
  default, while explicit `{"language":{"reset":{}}}` remains `.reset`.
- The default reflective parser rejects both unknown fields and duplicate
  fields (`ignore_unknown_fields = false`, `duplicate_field_behavior =
  .error`).
- The scanner preflight rejects over-depth and over-token inputs before
  reflective parsing. A deliberately small caller allocation budget returns
  `error.OutOfMemory` without leaking the arena or budget state.

This is enough to show that reflective JSON can preserve the current model's
semantics under the tested cases. It is not enough to promote JSON as a
production archive replacement: every future field, union case, numeric
spelling rule, hostile-input bound, and compatibility policy would still need
the same explicit review. A custom packet remains meaningful only if it keeps
full semantics and its existing bounds; fewer lines obtained by dropping
those bounds would not be an equivalent candidate.

## Native memory accounting note

The pinned `vendor/bzip3/include/libsais.h` source gives a source-level
accounting proof, not a runtime allocator observation. In the single-thread
`libsais_unbwt_main` path it allocates:

```text
bucket2  = 256 * 256 * sizeof(u32)       = 262,144 bytes
fastbits = (1 + 2^17) * sizeof(u16)      = 262,146 bytes
```

`libsais_alloc_aligned` asks `malloc` for `size + sizeof(short) + 4096 - 1`,
so those two allocations alone request 266,241 + 266,243 = 532,484 bytes,
before the small context allocation. Therefore “512 KiB” is a rounded payload
lower bound, not a safe exact upper bound and not an observed measurement.
The current compression wrapper charges
`compression.libsais_accounted_bytes = 1 MiB`, which is the conservative
choice for this pinned implementation. These allocations are internal C
`malloc` calls and cannot be redirected through the Zig allocator; the charge
is admission accounting, not an all-allocation injection claim.

The final API review retained the conservative `max_block_bytes` boundary:
it caps both logical payload and native block-state capacity. A compressed
request is refused if the codec's 65 KiB minimum state exceeds that cap, even
for a smaller payload. The production comment was corrected to describe this
behavior; the experiment does not reinterpret the limit as logical-only.
