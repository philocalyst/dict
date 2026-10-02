// Whole-file integer-alphabet lexical BWT experiment. LXB1 is transform-only:
// model and events use a charged, external zstd entropy backend.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>
#include <zstd.h>
#include <libbz3.h>

using Bytes = std::vector<uint8_t>;
using Symbols = std::vector<uint32_t>;
static constexpr size_t MAX_RAW = 64u << 20;
static constexpr size_t MAX_FRAME = 128u << 20;
static constexpr size_t MAX_MODEL = 16u << 20;
static constexpr size_t MAX_VOCAB = 65536;
static void need(bool b, const char *why) { if (!b) throw std::runtime_error(why); }
static uint32_t crc32(const Bytes &b) {
    uint32_t c = ~0u;
    for (auto x : b) { c ^= x; for (int k = 0; k < 8; ++k) c = (c >> 1) ^ (0xedb88320u & -(c & 1u)); }
    return ~c;
}
static Bytes readfile(const std::string &path, size_t cap) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    need(bool(f), "open input");
    auto n = f.tellg(); need(n >= 0 && uint64_t(n) <= cap, "input size limit");
    Bytes b(size_t(n), 0); f.seekg(0);
    if (!b.empty()) f.read(reinterpret_cast<char *>(b.data()), b.size());
    need(bool(f), "read input"); return b;
}
static void writefile(const std::string &path, const Bytes &b) {
    std::ofstream f(path, std::ios::binary); need(bool(f), "open output");
    f.write(reinterpret_cast<const char *>(b.data()), b.size()); need(bool(f), "write output");
}
static void put(Bytes &b, uint64_t v) {
    while (v >= 128) { b.push_back(uint8_t(v) | 128); v >>= 7; }
    b.push_back(uint8_t(v));
}
struct Reader {
    const Bytes &b; size_t p = 0;
    uint64_t get() {
        uint64_t x = 0;
        for (int i = 0; i < 10; ++i) {
            need(p < b.size(), "truncated varint"); uint8_t y = b[p++];
            need(i != 9 || y < 2, "varint overflow");
            x |= uint64_t(y & 127) << (7 * i);
            if (!(y & 128)) { need(i == 0 || y != 0, "noncanonical varint"); return x; }
        }
        throw std::runtime_error("varint overflow");
    }
    Bytes take(size_t n) {
        need(n <= b.size() - p, "truncated section");
        Bytes v(b.begin() + p, b.begin() + p + n); p += n; return v;
    }
};
static Bytes zenc(const Bytes &b, int level) {
    Bytes out(ZSTD_compressBound(b.size()));
    size_t n = ZSTD_compress(out.data(), out.size(), b.data(), b.size(), level);
    need(!ZSTD_isError(n), "zstd encode"); out.resize(n); return out;
}
static Bytes zdec(const Bytes &b, size_t n) {
    need(n <= MAX_FRAME, "zstd output limit"); Bytes out(n);
    size_t got = ZSTD_decompress(out.data(), out.size(), b.data(), b.size());
    need(!ZSTD_isError(got) && got == n, "zstd decode size"); return out;
}
static Bytes benc(const Bytes &b) {
    Bytes out(bz3_bound(b.size())); size_t n = out.size();
    need(bz3_compress(16u << 20, b.data(), out.data(), b.size(), &n) == BZ3_OK, "bzip3 encode");
    out.resize(n); return out;
}
static Bytes bdec(const Bytes &b, size_t n) {
    need(n <= MAX_FRAME, "bzip3 output limit"); Bytes out(n); size_t got = out.size();
    need(bz3_decompress(b.data(), out.data(), b.size(), &got) == BZ3_OK && got == n, "bzip3 decode size");
    return out;
}
// ASCII words and exact valid non-ASCII scalars. Invalid bytes become literals.
static size_t scalar(const Bytes &b, size_t p) {
    uint8_t x = b[p]; if (x < 0x80) return 1;
    size_t n = x >= 0xc2 && x <= 0xdf ? 2 : x >= 0xe0 && x <= 0xef ? 3 : x >= 0xf0 && x <= 0xf4 ? 4 : 0;
    if (!n || n > b.size() - p) return 1;
    for (size_t i = 1; i < n; ++i) if ((b[p + i] & 0xc0) != 0x80) return 1;
    if ((x == 0xe0 && b[p + 1] < 0xa0) || (x == 0xed && b[p + 1] >= 0xa0) ||
        (x == 0xf0 && b[p + 1] < 0x90) || (x == 0xf4 && b[p + 1] >= 0x90)) return 1;
    return n;
}
static bool word_scalar(const Bytes &b, size_t p, size_t n) {
    uint8_t x = b[p];
    if (x < 128) return (x >= 'a' && x <= 'z') || (x >= 'A' && x <= 'Z') ||
        (x >= '0' && x <= '9') || x == '_';
    if (n == 1) return false;
    // Explicit common script punctuation/space exclusions; all spellings stay exact.
    if (n == 3 && x == 0xe3 && b[p + 1] == 0x80) return false; // U+3000..303F
    if (n == 2 && x == 0xd8 && (b[p + 1] == 0x8c || b[p + 1] == 0x9b || b[p + 1] == 0x9f)) return false;
    return true;
}
struct Parsed { std::vector<std::string> vocab; Symbols symbols; };
enum Kind : uint32_t { BYTE = 0, WORD = 1, SUBWORD = 2, WORD_ALL = 3, WORD_SEP = 4 };
enum Order : uint32_t { LEX = 0, FREQUENCY = 1, FIRST = 2 };
static void reorder(Parsed &p, Order order) {
    const size_t n = p.vocab.size();
    std::vector<uint32_t> counts(n, 0), first(n, std::numeric_limits<uint32_t>::max()), ids(n);
    for (size_t i = 0; i < p.symbols.size(); ++i) if (p.symbols[i] >= 256) {
        auto j = p.symbols[i] - 256; need(j < n, "intermediate token");
        ++counts[j]; first[j] = std::min(first[j], uint32_t(i));
    }
    std::vector<uint32_t> keep;
    for (uint32_t j = 0; j < n; ++j) if (counts[j]) keep.push_back(j);
    need(keep.size() <= MAX_VOCAB, "vocabulary size");
    std::sort(keep.begin(), keep.end(), [&](uint32_t a, uint32_t b) {
        if (order == FREQUENCY && counts[a] != counts[b]) return counts[a] > counts[b];
        if (order == FIRST && first[a] != first[b]) return first[a] < first[b];
        return p.vocab[a] < p.vocab[b];
    });
    std::vector<std::string> sorted;
    for (uint32_t j = 0; j < keep.size(); ++j) { ids[keep[j]] = j; sorted.push_back(p.vocab[keep[j]]); }
    for (auto &x : p.symbols) if (x >= 256) x = 256 + ids[x - 256];
    p.vocab = std::move(sorted);
}
static Parsed wordparse(const Bytes &raw, size_t cap, bool full, bool separators) {
    std::unordered_map<std::string, uint32_t> counts;
    for (size_t p = 0; p < raw.size();) {
        size_t n = scalar(raw, p);
        bool word = word_scalar(raw, p, n);
        if (!word && (!separators || raw[p] == 10)) { p += n; continue; }
        size_t q = p + n;
        while (q < raw.size()) {
            size_t z = scalar(raw, q);
            if (word_scalar(raw, q, z) != word || (!word && raw[q] == 10)) break;
            q += z;
        }
        if (q - p >= (full ? 2u : 3u) && q - p <= (word ? 128u : 32u))
            ++counts[std::string(reinterpret_cast<const char *>(raw.data() + p), q - p)];
        p = q;
    }
    struct Candidate { std::string s; uint32_t n; uint64_t score; };
    std::vector<Candidate> pool;
    for (const auto &[s, n] : counts) if (full || n >= 2) {
        uint64_t score = uint64_t(n - 1) * (s.size() - 1);
        if (full || score > s.size() + 3) pool.push_back({s, n, score});
    }
    std::sort(pool.begin(), pool.end(), [](const auto &a, const auto &b) {
        return a.score != b.score ? a.score > b.score : a.s < b.s;
    });
    if (pool.size() > cap) pool.resize(cap);
    Parsed out; std::unordered_map<std::string, uint32_t> ids;
    for (auto &c : pool) { ids[c.s] = uint32_t(out.vocab.size()); out.vocab.push_back(c.s); }
    for (size_t p = 0; p < raw.size();) {
        size_t n = scalar(raw, p);
        bool word = word_scalar(raw, p, n);
        if (word || (separators && raw[p] != 10)) {
            size_t q = p + n;
            while (q < raw.size()) {
                size_t z = scalar(raw, q);
                if (word_scalar(raw, q, z) != word || (!word && raw[q] == 10)) break;
                q += z;
            }
            if (q - p <= (word ? 128u : 32u)) {
                auto it = ids.find(std::string(reinterpret_cast<const char *>(raw.data() + p), q - p));
                if (it != ids.end()) { out.symbols.push_back(256 + it->second); p = q; continue; }
            }
        }
        out.symbols.push_back(raw[p++]);
    }
    return out;
}
static Parsed subwordparse(const Bytes &raw, size_t cap) {
    Parsed out;
    std::unordered_map<std::string, uint32_t> ids;
    for (size_t p = 0; p < raw.size();) {
        size_t n = scalar(raw, p);
        if (n == 1) out.symbols.push_back(raw[p]);
        else {
            std::string s(reinterpret_cast<const char *>(raw.data() + p), n);
            auto it = ids.find(s);
            if (it == ids.end() && out.vocab.size() < MAX_VOCAB) {
                uint32_t id = uint32_t(out.vocab.size()); out.vocab.push_back(s);
                it = ids.emplace(s, id).first;
            }
            if (it == ids.end()) for (size_t i = 0; i < n; ++i) out.symbols.push_back(raw[p + i]);
            else out.symbols.push_back(256 + it->second);
        }
        p += n;
    }
    for (size_t pass = 0; pass < cap; ++pass) {
        std::unordered_map<uint64_t, uint32_t> pairs;
        for (size_t i = 1; i < out.symbols.size(); ++i) {
            uint32_t a = out.symbols[i - 1], b = out.symbols[i];
            if (a == 10 || b == 10) continue; // newline stays a reversible line boundary
            size_t la = a < 256 ? 1 : out.vocab[a - 256].size();
            size_t lb = b < 256 ? 1 : out.vocab[b - 256].size();
            if (la + lb > 64) continue;
            ++pairs[(uint64_t(a) << 32) | b];
        }
        uint64_t best = 0; uint32_t count = 0;
        for (const auto &[pair, n] : pairs) if (n > count || (n == count && pair < best)) { best = pair; count = n; }
        if (count < 4 || out.vocab.size() >= MAX_VOCAB) break;
        uint32_t a = uint32_t(best >> 32), b = uint32_t(best);
        std::string s = a < 256 ? std::string(1, char(a)) : out.vocab[a - 256];
        s += b < 256 ? std::string(1, char(b)) : out.vocab[b - 256];
        uint32_t new_id = uint32_t(256 + out.vocab.size()); out.vocab.push_back(std::move(s));
        Symbols next; next.reserve(out.symbols.size());
        for (size_t i = 0; i < out.symbols.size();) {
            if (i + 1 < out.symbols.size() && out.symbols[i] == a && out.symbols[i + 1] == b) {
                next.push_back(new_id); i += 2;
            } else next.push_back(out.symbols[i++]);
        }
        out.symbols = std::move(next);
    }
    return out;
}
static Parsed parse(const Bytes &raw, Kind kind, size_t cap, Order order) {
    Parsed p;
    if (kind == BYTE) for (auto x : raw) p.symbols.push_back(x);
    else if (kind == WORD || kind == WORD_ALL || kind == WORD_SEP)
        p = wordparse(raw, cap, kind != WORD, kind == WORD_SEP);
    else p = subwordparse(raw, cap);
    reorder(p, order); return p;
}
static void orient(Symbols &t, uint32_t direction) {
    if (direction == 1) std::reverse(t.begin(), t.end());
    else if (direction == 2) {
        size_t p = 0;
        for (size_t q = 0; q < t.size(); ++q) if (t[q] == 10) {
            std::reverse(t.begin() + p, t.begin() + q); p = q + 1;
        }
        std::reverse(t.begin() + p, t.end());
    }
}
static Bytes model_bytes(const std::vector<std::string> &v) {
    Bytes out; put(out, v.size()); std::string prev;
    for (const auto &s : v) {
        size_t common = 0;
        while (common < s.size() && common < prev.size() && s[common] == prev[common]) ++common;
        put(out, common); put(out, s.size() - common);
        out.insert(out.end(), s.begin() + common, s.end()); prev = s;
    }
    return out;
}
static std::vector<std::string> parse_model(const Bytes &b) {
    Reader r{b}; size_t n = r.get(); need(n <= MAX_VOCAB, "vocabulary count");
    std::vector<std::string> v; v.reserve(n); std::string prev;
    for (size_t i = 0; i < n; ++i) {
        size_t prefix = r.get(), suffix = r.get();
        need(prefix <= prev.size() && suffix <= 128 && prefix + suffix <= 128, "vocabulary token length");
        auto bytes = r.take(suffix); std::string s = prev.substr(0, prefix);
        s.append(reinterpret_cast<const char *>(bytes.data()), bytes.size());
        need(s.size() >= 2, "vocabulary byte length"); v.push_back(s); prev = std::move(s);
    }
    need(r.p == b.size(), "model trailing bytes"); return v;
}
static Symbols suffix_bwt(const Symbols &tokens, uint32_t alphabet, uint32_t &primary) {
    size_t n = tokens.size() + 1; need(n <= UINT32_MAX, "token count");
    Symbols s(n), p(n), c(n), pn(n), cn(n);
    for (size_t i = 0; i < tokens.size(); ++i) { need(tokens[i] + 1 < alphabet, "token alphabet"); s[i] = tokens[i] + 1; }
    s.back() = 0;
    std::vector<uint32_t> count(std::max<size_t>(n, alphabet), 0);
    for (auto x : s) ++count[x];
    for (size_t i = 1; i < alphabet; ++i) count[i] += count[i - 1];
    for (size_t i = n; i > 0; --i) p[--count[s[i - 1]]] = uint32_t(i - 1);
    uint32_t classes = 1; c[p[0]] = 0;
    for (size_t i = 1; i < n; ++i) { if (s[p[i]] != s[p[i - 1]]) ++classes; c[p[i]] = classes - 1; }
    for (size_t step = 1; step < n && classes < n; step <<= 1) {
        for (size_t i = 0; i < n; ++i) pn[i] = uint32_t(p[i] >= step ? p[i] - step : p[i] + n - step);
        std::fill(count.begin(), count.begin() + classes, 0);
        for (auto x : pn) ++count[c[x]];
        for (size_t i = 1; i < classes; ++i) count[i] += count[i - 1];
        for (size_t i = n; i > 0; --i) p[--count[c[pn[i - 1]]]] = pn[i - 1];
        cn[p[0]] = 0; uint32_t next = 1;
        for (size_t i = 1; i < n; ++i) {
            uint32_t a = p[i], b = p[i - 1];
            if (c[a] != c[b] || c[(a + step) % n] != c[(b + step) % n]) ++next;
            cn[a] = next - 1;
        }
        classes = next; c.swap(cn);
        if (step > n / 2) break;
    }
    Symbols last(n);
    for (size_t i = 0; i < n; ++i) { last[i] = s[p[i] == 0 ? n - 1 : p[i] - 1]; if (p[i] == 0) primary = uint32_t(i); }
    return last;
}
static Symbols inverse_bwt(const Symbols &last, uint32_t alphabet, uint32_t primary) {
    size_t n = last.size(); need(n && primary < n, "BWT primary");
    Symbols counts(alphabet, 0), next(n), out(n);
    for (auto x : last) { need(x < alphabet, "BWT symbol"); ++counts[x]; }
    need(counts[0] == 1 && last[primary] == 0, "BWT sentinel");
    uint32_t total = 0;
    for (auto &x : counts) { uint32_t old = x; x = total; total += old; }
    for (size_t i = 0; i < n; ++i) next[i] = counts[last[i]]++;
    uint32_t row = primary;
    for (size_t i = n; i > 0; --i) { out[i - 1] = last[row]; row = next[row]; }
    need(out.back() == 0 && row == primary, "BWT inverse cycle"); out.pop_back();
    for (auto &x : out) { need(x > 0, "duplicate sentinel"); --x; }
    return out;
}
struct Fenwick {
    std::vector<uint32_t> b;
    explicit Fenwick(size_t n) : b(n + 1, 0) {}
    void add(size_t p, int delta) { for (; p < b.size(); p += p & -p) b[p] += delta; }
    uint32_t sum(size_t p) const { uint32_t n = 0; for (; p; p -= p & -p) n += b[p]; return n; }
    size_t select(uint32_t k) const {
        size_t p = 0, step = 1; while (step < b.size()) step <<= 1;
        for (step >>= 1; step; step >>= 1) if (p + step < b.size() && b[p + step] < k) { p += step; k -= b[p]; }
        need(p + 1 < b.size(), "MTF rank"); return p + 1;
    }
};
static Bytes mtf_encode(const Symbols &last, uint32_t alphabet) {
    size_t n = last.size(); Fenwick f(n + alphabet + 1);
    std::vector<uint32_t> position(alphabet);
    for (uint32_t x = 0; x < alphabet; ++x) { position[x] = uint32_t(n + x + 1); f.add(position[x], 1); }
    size_t front = n; Bytes out; uint64_t zeros = 0;
    for (auto x : last) {
        uint32_t rank = f.sum(position[x]) - 1;
        if (rank == 0) ++zeros;
        else { if (zeros) { put(out, 0); put(out, zeros); zeros = 0; } put(out, uint64_t(rank) + 1); }
        f.add(position[x], -1); position[x] = uint32_t(front--); f.add(position[x], 1);
    }
    if (zeros) { put(out, 0); put(out, zeros); } return out;
}
static Symbols mtf_decode(const Bytes &stream, size_t n, uint32_t alphabet) {
    Fenwick f(n + alphabet + 1); std::vector<uint32_t> at(n + alphabet + 2);
    for (uint32_t x = 0; x < alphabet; ++x) { size_t p = n + x + 1; at[p] = x; f.add(p, 1); }
    size_t front = n; Symbols out; out.reserve(n); Reader r{stream};
    while (r.p < stream.size()) {
        uint64_t v = r.get();
        if (v == 0) {
            uint64_t length = r.get(); need(length && length <= n - out.size(), "MTF zero run");
            for (size_t i = 0; i < length; ++i) {
                size_t p = f.select(1); uint32_t x = at[p]; out.push_back(x);
                f.add(p, -1); at[front] = x; f.add(front--, 1);
            }
        } else {
            need(v >= 2 && v - 1 < alphabet && out.size() < n, "MTF event");
            size_t p = f.select(uint32_t(v)); uint32_t x = at[p]; out.push_back(x);
            f.add(p, -1); at[front] = x; f.add(front--, 1);
        }
    }
    need(out.size() == n, "MTF token count"); return out;
}
static Bytes direct_encode(const Symbols &symbols) { Bytes b; for (auto x : symbols) put(b, x); return b; }
static Symbols direct_decode(const Bytes &b, size_t n, uint32_t alphabet) {
    Reader r{b}; Symbols out; out.reserve(n);
    while (r.p < b.size()) { auto x = r.get(); need(x < alphabet && out.size() < n, "direct token"); out.push_back(uint32_t(x)); }
    need(out.size() == n, "direct count"); return out;
}
struct Config { Kind kind = WORD; Order order = LEX; uint32_t direction = 0, pipe = 1, backend = 1; size_t cap = 2048; int level = 19; };
static Bytes encode(const Bytes &raw, const Config &cfg) {
    need(raw.size() <= MAX_RAW && cfg.cap <= MAX_VOCAB, "encoder input limit");
    auto parsed = parse(raw, cfg.kind, cfg.cap, cfg.order);
    orient(parsed.symbols, cfg.direction);
    uint32_t alphabet = uint32_t(257 + parsed.vocab.size());
    uint32_t primary = 0;
    Symbols stream_symbols;
    if (cfg.pipe == 1) stream_symbols = suffix_bwt(parsed.symbols, alphabet, primary);
    else { stream_symbols.reserve(parsed.symbols.size() + 1); for (auto x : parsed.symbols) stream_symbols.push_back(x + 1); stream_symbols.push_back(0); }
    Bytes events = cfg.pipe == 1 ? mtf_encode(stream_symbols, alphabet) : direct_encode(stream_symbols);
    Bytes model = model_bytes(parsed.vocab);
    need(model.size() <= MAX_MODEL && events.size() <= MAX_FRAME, "encoder section limit");
    Bytes mz = cfg.backend == 1 ? zenc(model, cfg.level) : benc(model);
    Bytes ez = cfg.backend == 1 ? zenc(events, cfg.level) : benc(events);
    Bytes frame = {'L', 'X', 'B', '1'};
    put(frame, 1); put(frame, cfg.kind); put(frame, cfg.order); put(frame, cfg.direction); put(frame, cfg.pipe); put(frame, cfg.backend);
    put(frame, raw.size()); put(frame, crc32(raw)); put(frame, parsed.symbols.size()); put(frame, primary);
    put(frame, model.size()); put(frame, mz.size()); put(frame, events.size()); put(frame, ez.size());
    frame.insert(frame.end(), mz.begin(), mz.end()); frame.insert(frame.end(), ez.begin(), ez.end());
    need(frame.size() <= MAX_FRAME, "frame size limit");
    std::cerr << "{\"raw\":" << raw.size() << ",\"frame\":" << frame.size()
              << ",\"tokens\":" << parsed.symbols.size() << ",\"vocab\":" << parsed.vocab.size()
              << ",\"model_uncompressed\":" << model.size() << ",\"model_compressed\":" << mz.size()
              << ",\"events_uncompressed\":" << events.size() << ",\"events_compressed\":" << ez.size()
              << ",\"header\":" << frame.size() - mz.size() - ez.size() << "}\n";
    return frame;
}
static Bytes decode(const Bytes &frame) {
    need(frame.size() >= 4 && frame.size() <= MAX_FRAME && !std::memcmp(frame.data(), "LXB1", 4), "frame magic");
    Reader r{frame, 4};
    auto version = r.get(), kind = r.get(), order = r.get(), direction = r.get(), pipe = r.get(), backend = r.get();
    auto rawlen = r.get(), crc = r.get(), count = r.get(), primary = r.get();
    auto mn = r.get(), mz = r.get(), en = r.get(), ez = r.get();
    need(version == 1 && kind <= 4 && order <= 2 && direction <= 2 && pipe <= 1 && (backend == 1 || backend == 2), "frame flags");
    need(rawlen <= MAX_RAW && crc <= UINT32_MAX && count <= rawlen && primary <= count &&
         mn <= MAX_MODEL && mz <= MAX_MODEL && en <= 10 * (count + 1) + 16 && en <= MAX_FRAME && ez <= MAX_FRAME,
         "frame resource limits");
    need(mz <= frame.size() - r.p, "model section bound");
    Bytes coded_model = r.take(mz);
    Bytes model = backend == 1 ? zdec(coded_model, mn) : bdec(coded_model, mn);
    need(ez == frame.size() - r.p, "event section bound");
    Bytes coded_events = r.take(ez);
    Bytes events = backend == 1 ? zdec(coded_events, en) : bdec(coded_events, en);
    auto vocab = parse_model(model); need(vocab.size() <= count, "unused vocabulary bound");
    uint32_t alphabet = uint32_t(257 + vocab.size());
    Symbols symbols;
    if (pipe == 1) symbols = inverse_bwt(mtf_decode(events, size_t(count + 1), alphabet), alphabet, uint32_t(primary));
    else {
        need(primary == 0, "direct primary"); symbols = direct_decode(events, size_t(count + 1), alphabet);
        need(symbols.back() == 0, "direct sentinel"); symbols.pop_back();
        for (auto &x : symbols) { need(x > 0, "direct duplicate sentinel"); --x; }
    }
    orient(symbols, uint32_t(direction));
    Bytes out; out.reserve(size_t(rawlen));
    for (auto x : symbols) {
        if (x < 256) out.push_back(uint8_t(x));
        else { need(x - 256 < vocab.size(), "vocabulary token"); const auto &s = vocab[x - 256];
            need(s.size() <= rawlen - out.size(), "expanded size"); out.insert(out.end(), s.begin(), s.end()); }
        need(out.size() <= rawlen, "expanded size");
    }
    need(out.size() == rawlen && crc32(out) == crc, "source size or CRC"); return out;
}
static uint32_t choose(const std::string &s, std::initializer_list<const char *> values) {
    uint32_t i = 0; for (auto v : values) { if (s == v) return i; ++i; }
    throw std::runtime_error("unknown option value");
}
int main(int argc, char **argv) {
    try {
        need(argc >= 4, "usage: lexical_bwt encode|decode INPUT OUTPUT [--kind byte|word|subword|word-all|word-sep --order lex|frequency|first --direction forward|reverse|lines --pipe direct|bwt --backend zstd|bzip3 --cap N --level N]");
        std::string cmd = argv[1];
        if (cmd == "decode") { need(argc == 4, "decode arguments"); writefile(argv[3], decode(readfile(argv[2], MAX_FRAME))); return 0; }
        need(cmd == "encode", "command"); Config cfg;
        for (int i = 4; i < argc; i += 2) {
            need(i + 1 < argc, "option value"); std::string key = argv[i], val = argv[i + 1];
            if (key == "--kind") cfg.kind = Kind(choose(val, {"byte", "word", "subword", "word-all", "word-sep"}));
            else if (key == "--order") cfg.order = Order(choose(val, {"lex", "frequency", "first"}));
            else if (key == "--direction") cfg.direction = choose(val, {"forward", "reverse", "lines"});
            else if (key == "--pipe") cfg.pipe = choose(val, {"direct", "bwt"});
            else if (key == "--backend") cfg.backend = 1 + choose(val, {"zstd", "bzip3"});
            else if (key == "--cap") cfg.cap = std::stoull(val);
            else if (key == "--level") cfg.level = std::stoi(val);
            else throw std::runtime_error("unknown option");
        }
        need(cfg.level >= 1 && cfg.level <= 22, "zstd level");
        writefile(argv[3], encode(readfile(argv[2], MAX_RAW), cfg)); return 0;
    } catch (const std::exception &e) { std::cerr << "lexical_bwt: " << e.what() << "\n"; return 1; }
}
