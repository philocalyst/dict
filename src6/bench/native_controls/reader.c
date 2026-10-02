/* Persistent prepared reader for the WCTR26 comparison frames.
 * Reuses the frozen native codec implementation without changing codec.c. */
#define main native_controls_cli_main
#include "codec.c"
#undef main

static uint8_t *read_file_timed(const char *path, size_t *n, uint64_t *elapsed,
                                int measure) {
  uint64_t start = measure ? clock_ns() : 0;
  uint8_t *p = read_file(path, n);
  *elapsed = measure ? clock_ns() - start : 0;
  return p;
}

int main(int argc, char **argv) {
  need(argc >= 5,
       "usage: native-controls-reader CODEC FRAME RAW REPORT [--mode verify|full|query] "
       "[--measure 0|1 --quiet-gate FRONTIER2026-ACCESS-QUIET]");
  int measure = 0;
  const char *mode = "query";
  int got_gate = 0;
  for (int i = 5; i < argc; i += 2) {
    need(i + 1 < argc, "option value");
    if (!strcmp(argv[i], "--mode")) {
      need(!strcmp(argv[i + 1], "verify") || !strcmp(argv[i + 1], "full") ||
               !strcmp(argv[i + 1], "query"),
           "invalid reader mode");
      mode = argv[i + 1];
    } else if (!strcmp(argv[i], "--measure")) {
      need(!strcmp(argv[i + 1], "0") || !strcmp(argv[i + 1], "1"),
           "invalid measure value");
      measure = !strcmp(argv[i + 1], "1");
    } else if (!strcmp(argv[i], "--quiet-gate")) {
      need(!strcmp(argv[i + 1], "FRONTIER2026-ACCESS-QUIET"),
           "timing requires explicit access quiet gate");
      got_gate = 1;
    } else {
      fail("unknown reader option");
    }
  }
  need(!measure || got_gate, "timing requires explicit access quiet gate");
  if (measure) {
    const char *gate = getenv("FRONTIER2026_ACCESS_QUIET");
    need(gate && !strcmp(gate, "FRONTIER2026-ACCESS-QUIET"),
         "timing gate environment token missing");
  }
  crc_init();
  unsigned id = codec_id(argv[1]);
  size_t frame_n = 0, raw_n = 0;
  uint64_t frame_read_ns = 0, raw_read_ns = 0;
  uint8_t *frame = read_file_timed(argv[2], &frame_n, &frame_read_ns, measure);
  uint8_t *oracle = read_file_timed(argv[3], &raw_n, &raw_read_ns, measure);

  uint64_t start = measure ? clock_ns() : 0;
  struct view v = open_frame(frame, frame_n, id);
  need(v.block == 65536, "reader requires matched 65536-byte frames");
  need(v.count > 0, "reader requires a nonempty frame");
  need(v.raw == raw_n, "oracle length");
  struct codec c;
  codec_init(&c, id, v.block);
  uint8_t *whole = NULL;
  if (strcmp(mode, "query"))
    whole = allocate(v.raw);
  uint64_t prepare_ns = measure ? clock_ns() - start : 0;

  uint64_t full_decode_ns = 0;
  int full_verified = 0;
  if (whole) {
    start = measure && !strcmp(mode, "full") ? clock_ns() : 0;
    size_t at = 0;
    for (size_t i = 0; i < v.count; i++) {
      const uint8_t *r = frame + HEADER + i * RECORD;
      size_t off = u32(r), enc = u32(r + 4), raw = u32(r + 8);
      decode_block(&c, frame + v.metadata + off, enc, raw, whole + at);
      need(crc(whole + at, raw) == u32(r + 12), "full decode block checksum");
      at += raw;
    }
    full_decode_ns = measure && !strcmp(mode, "full") ? clock_ns() - start : 0;
    need(at == raw_n && memcmp(whole, oracle, raw_n) == 0,
         "full decode oracle mismatch");
    size_t raw_at = 0;
    for (size_t i = 0; i < v.count; i++) {
      const uint8_t *r = frame + HEADER + i * RECORD;
      size_t raw = u32(r + 8);
      need(memcmp(whole + raw_at, oracle + raw_at, raw) == 0,
           "restart oracle mismatch");
      raw_at += raw;
    }
    full_verified = 1;
  }

  uint32_t expected_crc[3] = {0, 0, 0};
  size_t page_index[3] = {0, v.count / 2, v.count - 1};
  size_t page_length[3];
  for (size_t j = 0; j < 3; j++) {
    size_t offset = page_index[j] * v.block;
    page_length[j] = raw_n - offset < v.block ? raw_n - offset : v.block;
    expected_crc[j] = crc(oracle + offset, page_length[j]);
  }
  uint32_t query_crcs[256] = {0};
  uint64_t query_256_ns = 0;
  size_t query_count = 0;
  if (strcmp(mode, "full")) {
    start = measure && !strcmp(mode, "query") ? clock_ns() : 0;
    for (size_t i = 0; i < 256; i++) {
      size_t slot = i % 3, index = page_index[slot];
      const uint8_t *r = frame + HEADER + index * RECORD;
      size_t off = u32(r), enc = u32(r + 4), raw = u32(r + 8);
      uint8_t *page = allocate(raw);
      decode_block(&c, frame + v.metadata + off, enc, raw, page);
      uint32_t page_crc = crc(page, raw);
      need(raw == page_length[slot] && page_crc == u32(r + 12) &&
               page_crc == expected_crc[slot],
           "query checksum or oracle mismatch");
      query_crcs[i] = page_crc;
      free(page);
    }
    query_256_ns = measure && !strcmp(mode, "query") ? clock_ns() - start : 0;
    query_count = 256;
  }
  uint64_t query_checksum = query_count ? 1469598103934665603ull : 0;
  for (size_t i = 0; i < query_count; i++)
    query_checksum = (query_checksum ^ query_crcs[i]) * 1099511628211ull;

  char report[2048];
  int report_n = snprintf(report, sizeof(report),
         "{\"format\":\"WCTR26\",\"codec\":\"%s\","
         "\"frame_bytes\":%zu,\"raw_bytes\":%zu,\"block_bytes\":%zu,"
         "\"blocks\":%zu,\"frame_read_ns\":%llu,\"oracle_read_ns\":%llu,"
         "\"mode\":\"%s\",\"prepare_ns\":%llu,\"full_decode_ns\":%llu,"
         "\"all_blocks_oracle_verified\":%s,\"query_oracle_verified\":%s,"
         "\"query_count\":%zu,"
         "\"measure_enabled\":%s,"
         "\"query_indices\":[%zu,%zu,%zu],\"query_256_ns\":%llu,"
         "\"query_checksum\":%llu}\n",
         argv[1], frame_n, raw_n, v.block, v.count,
         (unsigned long long)frame_read_ns, (unsigned long long)raw_read_ns,
         mode,
         (unsigned long long)prepare_ns, (unsigned long long)full_decode_ns,
         full_verified ? "true" : "false",
         query_count ? "true" : "false", query_count,
         measure ? "true" : "false",
         page_index[0], page_index[1], page_index[2],
         (unsigned long long)query_256_ns,
         (unsigned long long)query_checksum);
  need(report_n > 0 && (size_t)report_n < sizeof(report), "report overflow");
  FILE *report_file = fopen(argv[4], "wb");
  need(report_file != NULL && fwrite(report, 1, (size_t)report_n, report_file) ==
                                   (size_t)report_n &&
           fclose(report_file) == 0,
       "report write failure");
  fputs(report, stdout);
  codec_free(&c);
  free(frame);
  free(oracle);
  free(whole);
  return 0;
}
