/* Native, block-matched codec controls. No candidate algorithm lives here.
 * All controls use identical framing and independent restart blocks.
 * Dynamic system libraries avoid changing project production dependencies. */
#define _POSIX_C_SOURCE 200809L
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#define MAX_RAW ((size_t)512 * 1024 * 1024)
#define MAX_BLOCK ((size_t)64 * 1024 * 1024)
#define MIN_BZ3 ((size_t)65 * 1024)
#define HEADER 32
#define RECORD 16

static void fail(const char *s) {
  fprintf(stderr, "native-controls: %s\n", s);
  exit(1);
}
static void need(int b, const char *s) {
  if (!b)
    fail(s);
}
static void *allocate(size_t n) {
  void *p = malloc(n ? n : 1);
  need(p != NULL, "allocation failure");
  return p;
}
static uint32_t u32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 |
         (uint32_t)p[3] << 24;
}
static uint64_t u64(const uint8_t *p) {
  return (uint64_t)u32(p) | (uint64_t)u32(p + 4) << 32;
}
static void put32(uint8_t *p, uint32_t x) {
  for (unsigned i = 0; i < 4; i++)
    p[i] = (uint8_t)(x >> (8 * i));
}
static void put64(uint8_t *p, uint64_t x) {
  put32(p, (uint32_t)x);
  put32(p + 4, (uint32_t)(x >> 32));
}
static uint32_t crc_table[256];
static void crc_init(void) {
  for (unsigned i = 0; i < 256; i++) {
    uint32_t c = i;
    for (unsigned j = 0; j < 8; j++)
      c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1)));
    crc_table[i] = c;
  }
}
static uint32_t crc_add(uint32_t c, const uint8_t *p, size_t n) {
  for (size_t i = 0; i < n; i++)
    c = (c >> 8) ^ crc_table[(c ^ p[i]) & 255];
  return c;
}
static uint32_t crc(const uint8_t *p, size_t n) { return ~crc_add(~0u, p, n); }
static uint64_t clock_ns(void) {
  struct timespec t;
  need(clock_gettime(CLOCK_MONOTONIC, &t) == 0, "clock failure");
  return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
static uint8_t *read_file(const char *path, size_t *n) {
  FILE *f = fopen(path, "rb");
  need(f != NULL, "input open failure");
  need(fseek(f, 0, SEEK_END) == 0, "input seek failure");
  long size = ftell(f);
  need(size >= 0 && (uint64_t)size <= MAX_RAW * 2, "input size limit");
  *n = (size_t)size;
  rewind(f);
  uint8_t *p = allocate(*n);
  need(fread(p, 1, *n, f) == *n, "input read failure");
  need(fclose(f) == 0, "input close failure");
  return p;
}
static void write_file(const char *path, const uint8_t *p, size_t n) {
  FILE *f = fopen(path, "wb");
  need(f != NULL, "output open failure");
  need(fwrite(p, 1, n, f) == n, "output write failure");
  need(fclose(f) == 0, "output close failure");
}
static void *library(const char *name) {
  void *p = dlopen(name, RTLD_NOW | RTLD_LOCAL);
  if (!p) {
    fprintf(stderr, "%s\n", dlerror());
    fail("missing control library");
  }
  return p;
}
static void *symbol(void *lib, const char *name) {
  void *p = dlsym(lib, name);
  need(p != NULL, "missing control symbol");
  return p;
}

struct codec {
  unsigned id;
  void *lib, *state;
  size_t capacity;
  uint8_t *work;
  int (*bz_enc)(char *, unsigned *, char *, unsigned, int, int, int);
  int (*bz_dec)(char *, unsigned *, char *, unsigned, int, int);
  size_t (*z_bound)(size_t);
  size_t (*z_enc)(void *, size_t, const void *, size_t, int);
  size_t (*z_dec)(void *, size_t, const void *, size_t);
  unsigned (*z_error)(size_t);
  size_t (*lz_bound)(size_t);
  int (*lz_enc)(uint32_t, int, const void *, const uint8_t *, size_t, uint8_t *,
                size_t *, size_t);
  int (*lz_dec)(uint64_t *, uint32_t, const void *, const uint8_t *, size_t *,
                size_t, uint8_t *, size_t *, size_t);
  void *(*b3_new)(int32_t);
  void (*b3_free)(void *);
  size_t (*b3_bound)(size_t);
  int32_t (*b3_enc)(void *, uint8_t *, int32_t);
  int32_t (*b3_dec)(void *, uint8_t *, size_t, int32_t, int32_t);
  int8_t (*b3_error)(void *);
};

static unsigned codec_id(const char *s) {
  if (!strcmp(s, "bzip2"))
    return 1;
  if (!strcmp(s, "zstd"))
    return 2;
  if (!strcmp(s, "xz"))
    return 3;
  if (!strcmp(s, "bzip3"))
    return 4;
  fail("unknown codec");
  return 0;
}
static size_t codec_bound(struct codec *c, size_t n) {
  switch (c->id) {
  case 1:
    return n + n / 100 + 601;
  case 2:
    return c->z_bound(n);
  case 3:
    return c->lz_bound(n);
  case 4:
    return c->b3_bound(n);
  }
  fail("invalid codec");
  return 0;
}
static void codec_init(struct codec *c, unsigned id, size_t block) {
  memset(c, 0, sizeof(*c));
  c->id = id;
  if (id == 1) {
    c->lib = library("libbz2.so.1.0");
    c->bz_enc = symbol(c->lib, "BZ2_bzBuffToBuffCompress");
    c->bz_dec = symbol(c->lib, "BZ2_bzBuffToBuffDecompress");
  } else if (id == 2) {
    c->lib = library("libzstd.so.1");
    c->z_bound = symbol(c->lib, "ZSTD_compressBound");
    c->z_enc = symbol(c->lib, "ZSTD_compress");
    c->z_dec = symbol(c->lib, "ZSTD_decompress");
    c->z_error = symbol(c->lib, "ZSTD_isError");
  } else if (id == 3) {
    c->lib = library("liblzma.so.5");
    c->lz_bound = symbol(c->lib, "lzma_stream_buffer_bound");
    c->lz_enc = symbol(c->lib, "lzma_easy_buffer_encode");
    c->lz_dec = symbol(c->lib, "lzma_stream_buffer_decode");
  } else if (id == 4) {
    const char *path = getenv("LEX_BZIP3_LIBRARY");
    c->lib = library(path ? path : "/workspace/scratch/libbzip3.so");
    c->b3_new = symbol(c->lib, "bz3_new");
    c->b3_free = symbol(c->lib, "bz3_free");
    c->b3_bound = symbol(c->lib, "bz3_bound");
    c->b3_enc = symbol(c->lib, "bz3_encode_block");
    c->b3_dec = symbol(c->lib, "bz3_decode_block");
    c->b3_error = symbol(c->lib, "bz3_last_error");
    c->state = c->b3_new((int32_t)(block > MIN_BZ3 ? block : MIN_BZ3));
    need(c->state != NULL, "bzip3 state allocation failure");
  } else
    fail("invalid codec");
  c->capacity = codec_bound(c, (id == 4 && block < MIN_BZ3) ? MIN_BZ3 : block);
  need(c->capacity <= MAX_RAW, "codec bound limit");
  c->work = allocate(c->capacity);
}
static void codec_free(struct codec *c) {
  free(c->work);
  if (c->state)
    c->b3_free(c->state);
  dlclose(c->lib);
}
static size_t encode_block(struct codec *c, const uint8_t *p, size_t n) {
  size_t out = 0;
  switch (c->id) {
  case 1: {
    unsigned count = (unsigned)c->capacity;
    need(c->bz_enc((char *)c->work, &count, (char *)p, (unsigned)n, 9, 0, 30) ==
             0,
         "bzip2 encode failure");
    out = count;
    break;
  }
  case 2:
    out = c->z_enc(c->work, c->capacity, p, n, 19);
    need(!c->z_error(out), "zstd encode failure");
    break;
  case 3:
    need(c->lz_enc(9u | (1u << 31), 4, NULL, p, n, c->work, &out,
                   c->capacity) == 0,
         "xz encode failure");
    break;
  case 4: {
    memcpy(c->work, p, n);
    int32_t count = c->b3_enc(c->state, c->work, (int32_t)n);
    need(count >= 0 && c->b3_error(c->state) == 0, "bzip3 encode failure");
    out = (size_t)count;
    break;
  }
  }
  need(out <= c->capacity, "encode extent failure");
  return out;
}
static void decode_block(struct codec *c, const uint8_t *p, size_t n,
                         size_t raw, uint8_t *out) {
  switch (c->id) {
  case 1: {
    unsigned count = (unsigned)raw;
    need(c->bz_dec((char *)out, &count, (char *)p, (unsigned)n, 0, 0) == 0 &&
             count == raw,
         "bzip2 decode failure");
    break;
  }
  case 2: {
    size_t count = c->z_dec(out, raw, p, n);
    need(!c->z_error(count) && count == raw, "zstd decode failure");
    break;
  }
  case 3: {
    size_t input_at = 0, output_at = 0;
    uint64_t limit = (uint64_t)256 * 1024 * 1024;
    need(c->lz_dec(&limit, 0, NULL, p, &input_at, n, out, &output_at, raw) ==
                 0 &&
             input_at == n && output_at == raw,
         "xz decode failure");
    break;
  }
  case 4: {
    need(n >= 8 && n <= codec_bound(c, raw), "bzip3 compressed extent");
    int32_t row = (int32_t)u32(p + 4);
    need(row >= -1 && (n > 8 || row == -1), "bzip3 header");
    if (row != -1)
      need(n >= 9 && (p[8] & ~6u) == 0, "bzip3 model");
    memset(c->work, 0, c->capacity);
    memcpy(c->work, p, n);
    int32_t count =
        c->b3_dec(c->state, c->work, c->capacity, (int32_t)n, (int32_t)raw);
    need(count == (int32_t)raw && c->b3_error(c->state) == 0,
         "bzip3 decode failure");
    memcpy(out, c->work, raw);
    break;
  }
  }
}

static uint8_t *encode(const uint8_t *input, size_t size, unsigned id,
                       size_t block, size_t *total) {
  need(size <= MAX_RAW && block > 0 && block <= MAX_BLOCK, "encode limits");
  size_t count = (size + block - 1) / block, metadata = HEADER + count * RECORD;
  struct codec c;
  codec_init(&c, id, block);
  size_t capacity = metadata + count * codec_bound(&c, block);
  need(capacity <= MAX_RAW * 2 && capacity <= UINT32_MAX, "frame capacity");
  uint8_t *frame = allocate(capacity);
  memset(frame, 0, metadata);
  memcpy(frame, "WCTR26\0\0", 8);
  frame[8] = 1;
  frame[9] = (uint8_t)id;
  put32(frame + 12, (uint32_t)block);
  put64(frame + 16, size);
  put32(frame + 24, (uint32_t)count);
  size_t at = metadata;
  for (size_t i = 0; i < count; i++) {
    size_t pos = i * block, raw = size - pos;
    if (raw > block)
      raw = block;
    size_t n = encode_block(&c, input + pos, raw);
    uint8_t *record = frame + HEADER + i * RECORD;
    put32(record, (uint32_t)(at - metadata));
    put32(record + 4, (uint32_t)n);
    put32(record + 8, (uint32_t)raw);
    put32(record + 12, crc(input + pos, raw));
    memcpy(frame + at, c.work, n);
    at += n;
  }
  uint32_t digest =
      crc_add(crc_add(~0u, frame, 28), frame + HEADER, count * RECORD);
  put32(frame + 28, ~digest);
  codec_free(&c);
  *total = at;
  return frame;
}
struct view {
  size_t block, raw, count, metadata;
  unsigned id;
  const uint8_t *frame;
  size_t size;
};
static struct view open_frame(const uint8_t *p, size_t n, unsigned expected) {
  need(n >= HEADER && !memcmp(p, "WCTR26\0\0", 8) && p[8] == 1 && p[10] == 0 &&
           p[11] == 0,
       "frame header");
  struct view v = {
      u32(p + 12), (size_t)u64(p + 16), u32(p + 24), 0, p[9], p, n};
  need(v.id == expected && v.block > 0 && v.block <= MAX_BLOCK &&
           v.raw <= MAX_RAW,
       "frame limits");
  need(v.count == (v.raw + v.block - 1) / v.block &&
           v.count <= (n - HEADER) / RECORD,
       "restart count");
  v.metadata = HEADER + v.count * RECORD;
  need(~crc_add(crc_add(~0u, p, 28), p + HEADER, v.count * RECORD) ==
           u32(p + 28),
       "metadata checksum");
  size_t extent = 0, raw = 0;
  for (size_t i = 0; i < v.count; i++) {
    const uint8_t *r = p + HEADER + i * RECORD;
    size_t off = u32(r), enc = u32(r + 4), len = u32(r + 8);
    need(off == extent && enc <= n - v.metadata - extent,
         "restart encoded extent");
    need(len > 0 && len <= v.block &&
             len == (v.raw - raw < v.block ? v.raw - raw : v.block),
         "restart raw extent");
    extent += enc;
    raw += len;
  }
  need(extent == n - v.metadata && raw == v.raw, "frame tail");
  return v;
}
static uint8_t *decode(const uint8_t *input, size_t size, unsigned id,
                       size_t index, int indexed, size_t *total,
                       size_t *count_out) {
  struct view v = open_frame(input, size, id);
  need(!indexed || index < v.count, "block index");
  size_t n = indexed ? u32(input + HEADER + index * RECORD + 8) : v.raw;
  uint8_t *output = allocate(n);
  struct codec c;
  codec_init(&c, id, v.block);
  size_t first = indexed ? index : 0, last = indexed ? index + 1 : v.count,
         at = 0;
  for (size_t i = first; i < last; i++) {
    const uint8_t *r = input + HEADER + i * RECORD;
    size_t off = u32(r), enc = u32(r + 4), raw = u32(r + 8);
    decode_block(&c, input + v.metadata + off, enc, raw, output + at);
    need(crc(output + at, raw) == u32(r + 12), "block checksum");
    at += raw;
  }
  codec_free(&c);
  *total = n;
  *count_out = v.count;
  return output;
}
int main(int argc, char **argv) {
  need(argc >= 5, "usage: native-controls encode|decode|decode-block CODEC "
                  "INPUT OUTPUT [--block N] [--index N]");
  size_t block = 65536, index = 0;
  int indexed = !strcmp(argv[1], "decode-block"),
      encoding = !strcmp(argv[1], "encode");
  need(encoding || indexed || !strcmp(argv[1], "decode"), "operation");
  for (int i = 5; i < argc; i += 2) {
    need(i + 1 < argc, "option value");
    char *end = NULL;
    unsigned long long number = strtoull(argv[i + 1], &end, 10);
    need(argv[i + 1][0] != '-' && *end == 0 && number <= MAX_RAW,
         "numeric option");
    if (!strcmp(argv[i], "--block"))
      block = (size_t)number;
    else if (!strcmp(argv[i], "--index"))
      index = (size_t)number;
    else
      fail("unknown option");
  }
  crc_init();
  unsigned id = codec_id(argv[2]);
  size_t input_n = 0, output_n = 0, count = 0;
  uint8_t *input = read_file(argv[3], &input_n);
  uint64_t started = clock_ns();
  uint8_t *output =
      encoding ? encode(input, input_n, id, block, &output_n)
               : decode(input, input_n, id, index, indexed, &output_n, &count);
  uint64_t elapsed = clock_ns() - started;
  if (encoding)
    count = (input_n + block - 1) / block;
  struct rusage usage;
  need(getrusage(RUSAGE_SELF, &usage) == 0, "RSS measurement");
  write_file(argv[4], output, output_n);
  printf("{\"codec_ns\":%llu,\"input_bytes\":%zu,\"output_bytes\":%zu,\"header_"
         "bytes\":32,\"directory_bytes\":%zu,\"model_bytes\":0,\"blocks\":%zu,"
         "\"maxrss_kib\":%ld}\n",
         (unsigned long long)elapsed, input_n, output_n, count * RECORD, count,
         usage.ru_maxrss);
  free(input);
  free(output);
  return 0;
}
