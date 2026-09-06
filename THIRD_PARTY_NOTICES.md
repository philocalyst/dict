# Third-party notices

## bzip3 / libbz3

Lexicon vendors and compiles the upstream `libbz3` implementation from the
`iczelia/bzip3` repository:

- repository: <https://github.com/iczelia/bzip3>
- release: `1.5.1`
- immutable source commit: `d149f093793484d8eb55900ecf09c5714e277dba`
- source date: `2024-12-16`
- license: GNU Lesser General Public License, version 3 (LGPL-3.0-or-later)
- vendored license text: [`vendor/bzip3/LICENSE`](vendor/bzip3/LICENSE)
- vendored source: [`vendor/bzip3/src/libbz3.c`](vendor/bzip3/src/libbz3.c)
- vendored public headers: `vendor/bzip3/include/libbz3.h`,
  `vendor/bzip3/include/common.h`, and `vendor/bzip3/include/libsais.h`
- bundled `libsais` notice: [`vendor/bzip3/3rdparty/libsais-LICENSE`](vendor/bzip3/3rdparty/libsais-LICENSE)

The build compiles only `vendor/bzip3/src/libbz3.c`; `libsais` is the upstream
header-only implementation included by that translation unit.  Upstream
command-line programs, man pages, pthread parallel entry points, and unrelated
build machinery are not linked into Lexicon.

The initial integration uses the upstream low-level independent-block API.  It
does not alter the vendored source.  The caller must preserve the LGPL notices
and provide the corresponding source and relinking rights required by the
license when distributing a combined artifact.  Static linking is not treated
as license-neutral; a distribution arrangement must be chosen and reviewed
before shipping a statically linked product.

The codec's wire identity is the upstream independent-block API at release
1.5.1 (`wire_version = 1`).  This is separate from the future `.lex` snapshot
format version.  A block is not a complete bzip3 frame and must be accompanied
by its original length in the containing format.

## Zig

The project itself is licensed separately by its owner.  Zig's compiler and
standard library are not vendored by this repository; see the Zig distribution
for its license and release notices.

