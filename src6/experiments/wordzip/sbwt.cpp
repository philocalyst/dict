// A fully delivered grammar + cyclic symbol BWT + MTF/zero-run + rANS codec.
// No compression library or external vocabulary participates in decoding.
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <numeric>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <unordered_map>
#include <vector>
using Bytes = std::vector<uint8_t>;
using Tokens = std::vector<uint32_t>;
static constexpr uint64_t MAXRAW = 512ull << 20;
static constexpr uint64_t MAXFRAME = MAXRAW + (64ull << 20);
static void need(bool v, const char *m) {
    if (!v)
        throw std::runtime_error(m);
}
static Bytes read(const char *p) {
    std::ifstream f(p, std::ios::binary | std::ios::ate);
    need(bool(f), "open input");
    auto size = f.tellg();
    need(size >= 0 && uint64_t(size) <= MAXFRAME, "input file resource limit");
    Bytes b(static_cast<size_t>(size));
    f.seekg(0);
    if (!b.empty())
        f.read(reinterpret_cast<char *>(b.data()), b.size());
    need(bool(f), "read input");
    return b;
}
static void write(const char *p, const Bytes &b) {
    std::ofstream f(p, std::ios::binary);
    need(bool(f), "open output");
    f.write((char *)b.data(), b.size());
    need(bool(f), "write output");
}
static uint32_t crc(const Bytes &b) {
    static std::array<uint32_t, 256> t = []() {
        std::array<uint32_t, 256> a{};
        for (uint32_t i = 0; i < 256; i++) {
            auto x = i;
            for (int j = 0; j < 8; j++)
                x = (x >> 1) ^ (0xedb88320u & -(x & 1u));
            a[i] = x;
        }
        return a;
    }();
    uint32_t c = ~0u;
    for (auto x : b)
        c = t[(c ^ x) & 255] ^ (c >> 8);
    return ~c;
}
static void put(Bytes &b, uint64_t x) {
    while (x >= 128) {
        b.push_back((x & 127) | 128);
        x >>= 7;
    }
    b.push_back(x);
}
static void u32(Bytes &b, uint32_t x) {
    for (int i = 0; i < 4; i++)
        b.push_back(x >> (8 * i));
}
static void u64(Bytes &b, uint64_t x) {
    for (int i = 0; i < 8; i++)
        b.push_back(x >> (8 * i));
}
struct Reader {
    const Bytes &b;
    size_t p = 0;
    uint64_t get() {
        uint64_t x = 0;
        for (unsigned i = 0; i < 10; i++) {
            need(p < b.size(), "truncated integer");
            uint8_t y = b[p++];
            need(i != 9 || y < 2, "integer overflow");
            x |= uint64_t(y & 127) << (7 * i);
            if (!(y & 128)) {
                need(i == 0 || y, "noncanonical integer");
                return x;
            }
        }
        throw std::runtime_error("integer overflow");
    }
    uint32_t r32() {
        need(b.size() - p >= 4, "truncated u32");
        uint32_t x = 0;
        for (int i = 0; i < 4; i++)
            x |= uint32_t(b[p++]) << (8 * i);
        return x;
    }
    uint64_t r64() {
        auto lo = r32(), hi = r32();
        return lo | (uint64_t(hi) << 32);
    }
    Bytes take(size_t n) {
        need(n <= b.size() - p, "truncated bytes");
        Bytes x(b.begin() + p, b.begin() + p + n);
        p += n;
        return x;
    }
};

static constexpr uint32_t RANS_L = 1u << 23;
struct Rans {
    unsigned bits = 12;
    uint32_t scale = 4096;
    std::vector<uint32_t> f, c;
    std::vector<uint16_t> lookup;
};
static Rans train(const std::vector<Tokens> &seq, size_t alphabet, unsigned forced = 0) {
    std::vector<uint64_t> counts(alphabet);
    uint64_t total = 0;
    for (auto &s : seq)
        for (auto x : s) {
            need(x < alphabet, "entropy symbol");
            counts[x]++;
            total++;
        }
    size_t live = std::count_if(counts.begin(), counts.end(), [](auto x) { return x > 0; });
    Rans a;
    while (a.scale < live * 2 && a.bits < 16) {
        a.bits++;
        a.scale *= 2;
    }
    if (forced) {
        a.bits = forced;
        a.scale = 1u << forced;
    }
    need(live <= a.scale && alphabet <= 65536, "entropy alphabet limit");
    a.f.resize(alphabet);
    a.c.resize(alphabet);
    if (!total) {
        a.f[0] = a.scale;
    } else {
        uint32_t sum = 0;
        for (size_t i = 0; i < alphabet; i++)
            if (counts[i])
                sum += (a.f[i] = std::max<uint64_t>(1, counts[i] * a.scale / total));
        while (sum > a.scale) {
            size_t best = 0;
            for (size_t i = 1; i < alphabet; i++)
                if (a.f[i] > a.f[best])
                    best = i;
            need(a.f[best] > 1, "normalize frequencies");
            a.f[best]--;
            sum--;
        }
        std::vector<size_t> order(alphabet);
        std::iota(order.begin(), order.end(), 0);
        std::sort(order.begin(), order.end(), [&](auto x, auto y) {
            return counts[x] != counts[y] ? counts[x] > counts[y] : x < y;
        });
        for (size_t j = 0; sum < a.scale; j++, sum++)
            a.f[order[j % live]]++;
    }
    uint32_t sum = 0;
    for (size_t i = 0; i < alphabet; i++) {
        a.c[i] = sum;
        sum += a.f[i];
    }
    need(sum == a.scale, "frequency sum");
    return a;
}
static void prepare(Rans &a) {
    a.lookup.resize(a.scale);
    for (size_t x = 0; x < a.f.size(); x++)
        for (uint32_t i = 0; i < a.f[x]; i++)
            a.lookup[a.c[x] + i] = x;
}
static Bytes model(const Rans &a) {
    Bytes b;
    put(b, a.bits);
    put(b, a.f.size());
    size_t live = std::count_if(a.f.begin(), a.f.end(), [](auto x) { return x > 0; });
    put(b, live);
    size_t prev = 0;
    for (size_t i = 0; i < a.f.size(); i++)
        if (a.f[i]) {
            put(b, i - prev);
            put(b, a.f[i]);
            prev = i + 1;
        }
    return b;
}
static Rans parsemodel(const Bytes &b) {
    Reader r{b};
    Rans a;
    a.bits = r.get();
    need(a.bits >= 12 && a.bits <= 16, "entropy precision");
    a.scale = 1u << a.bits;
    auto n = r.get(), live = r.get();
    need(n && n <= 65536 && live && live <= n, "entropy table limit");
    a.f.resize(n);
    a.c.resize(n);
    size_t next = 0;
    uint32_t sum = 0;
    for (size_t j = 0; j < live; j++) {
        auto delta = r.get(), f = r.get();
        need(delta < n - next && f && f <= a.scale - sum, "entropy entry");
        size_t x = next + delta;
        a.f[x] = f;
        sum += f;
        next = x + 1;
    }
    need(sum == a.scale && r.p == b.size(), "entropy model sum/tail");
    sum = 0;
    for (size_t x = 0; x < n; x++) {
        a.c[x] = sum;
        sum += a.f[x];
    }
    prepare(a);
    return a;
}
static Bytes rencode(const Tokens &s, const Rans &a) {
    uint32_t state = RANS_L;
    Bytes tail;
    for (auto it = s.rbegin(); it != s.rend(); it++) {
        auto x = *it;
        need(x < a.f.size() && a.f[x], "uncoded symbol");
        uint32_t f = a.f[x];
        uint64_t xmax = uint64_t(RANS_L >> a.bits) * 256 * f;
        while (state >= xmax) {
            tail.push_back(state & 255);
            state >>= 8;
        }
        state = (state / f) * a.scale + state % f + a.c[x];
    }
    Bytes out;
    u32(out, state);
    out.insert(out.end(), tail.rbegin(), tail.rend());
    return out;
}
static Tokens rdecode(const Bytes &b, size_t n, const Rans &a) {
    Reader r{b};
    uint32_t state = r.r32();
    need(state >= RANS_L && state < uint64_t(RANS_L) * 256, "rANS initial state");
    Tokens out;
    out.reserve(n);
    for (size_t i = 0; i < n; i++) {
        auto low = state & (a.scale - 1);
        auto x = a.lookup[low];
        out.push_back(x);
        state = a.f[x] * (state >> a.bits) + low - a.c[x];
        while (state < RANS_L) {
            need(r.p < b.size(), "rANS truncation");
            state = (state << 8) | b[r.p++];
        }
    }
    need(state == RANS_L && r.p == b.size(), "rANS final state/tail");
    return out;
}
static unsigned context(uint32_t prev, unsigned rows) {
    if (rows == 1)
        return 0;
    if (rows == 2)
        return prev < 2 ? 0 : 1;
    if (rows == 4)
        return prev < 2 ? prev : (prev < 16 ? 2 : 3);
    if (prev < 2)
        return prev;
    unsigned bit = 0;
    for (uint32_t x = prev - 1; x > 1; x >>= 1)
        bit++;
    return std::min<unsigned>(7, 2 + bit);
}
static std::vector<Rans> contextual_train(const std::vector<Tokens> &seq, size_t alphabet,
                                          unsigned rows) {
    std::vector<Tokens> parts(rows);
    for (auto &s : seq) {
        uint32_t prev = 0;
        for (auto x : s) {
            parts[context(prev, rows)].push_back(x);
            prev = x;
        }
    }
    std::vector<Rans> models;
    for (auto &s : parts)
        models.push_back(train({s}, alphabet));
    return models;
}
static Bytes contextual_model(const std::vector<Rans> &rows) {
    Bytes b;
    put(b, rows.size());
    for (auto &a : rows) {
        auto m = model(a);
        put(b, m.size());
        b.insert(b.end(), m.begin(), m.end());
    }
    return b;
}
static std::vector<Rans> contextual_parse(const Bytes &b) {
    Reader r{b};
    auto n = r.get();
    need(n == 1 || n == 2 || n == 4 || n == 8, "entropy contexts");
    std::vector<Rans> rows;
    for (size_t i = 0; i < n; i++) {
        auto len = r.get();
        rows.push_back(parsemodel(r.take(len)));
    }
    need(r.p == b.size(), "context model tail");
    return rows;
}
static Bytes contextual_encode(const Tokens &s, const std::vector<Rans> &rows) {
    uint32_t state = RANS_L;
    Bytes tail;
    for (size_t i = s.size(); i-- > 0;) {
        auto &a = rows[context(i ? s[i - 1] : 0, rows.size())];
        auto x = s[i];
        need(x < a.f.size() && a.f[x], "context uncoded symbol");
        auto f = a.f[x];
        uint64_t xmax = uint64_t(RANS_L >> a.bits) * 256 * f;
        while (state >= xmax) {
            tail.push_back(state & 255);
            state >>= 8;
        }
        state = (state / f) * a.scale + state % f + a.c[x];
    }
    Bytes out;
    u32(out, state);
    out.insert(out.end(), tail.rbegin(), tail.rend());
    return out;
}
static Tokens contextual_decode(const Bytes &b, size_t n, const std::vector<Rans> &rows) {
    Reader r{b};
    uint32_t state = r.r32(), prev = 0;
    need(state >= RANS_L && state < uint64_t(RANS_L) * 256, "context rANS state");
    Tokens out;
    out.reserve(n);
    for (size_t i = 0; i < n; i++) {
        auto &a = rows[context(prev, rows.size())];
        auto low = state & (a.scale - 1);
        auto x = a.lookup[low];
        out.push_back(x);
        prev = x;
        state = a.f[x] * (state >> a.bits) + low - a.c[x];
        while (state < RANS_L) {
            need(r.p < b.size(), "context rANS truncation");
            state = (state << 8) | b[r.p++];
        }
    }
    need(state == RANS_L && r.p == b.size(), "context rANS tail");
    return out;
}
static Bytes compressmodel(const Bytes &b) {
    need(b.size() <= 8 * 1024 * 1024, "model input resource limit");
    Tokens t(b.begin(), b.end());
    auto a = train({t}, 256);
    auto m = model(a), z = rencode(t, a);
    Bytes out;
    put(out, b.size());
    put(out, m.size());
    out.insert(out.end(), m.begin(), m.end());
    out.insert(out.end(), z.begin(), z.end());
    return out;
}
static Bytes decompressmodel(const Bytes &b) {
    Reader r{b};
    auto n = r.get(), m = r.get();
    need(n <= 8 * 1024 * 1024, "grammar serialized limit");
    auto a = parsemodel(r.take(m));
    auto t = rdecode(r.take(b.size() - r.p), n, a);
    return Bytes(t.begin(), t.end());
}

struct Grammar {
    std::vector<Tokens> rules;
    std::vector<std::string> exp;
};
static Grammar basegrammar() {
    Grammar g;
    for (unsigned i = 0; i < 256; i++)
        g.exp.push_back(std::string(1, char(i)));
    return g;
}
static uint64_t pairkey(uint32_t a, uint32_t b) { return uint64_t(a) << 32 | b; }
static bool word(uint8_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' ||
           c >= 128;
}
static Grammar build(const Bytes &raw, size_t block, size_t cap, unsigned passes, unsigned policy) {
    auto g = basegrammar();
    std::unordered_map<std::string, uint32_t> words;
    if (policy) {
        std::unordered_map<std::string, uint32_t> counts;
        for (size_t p = 0; p < raw.size();) {
            if (!word(raw[p])) {
                p++;
                continue;
            }
            size_t q = p + 1;
            while (q < raw.size() && word(raw[q]))
                q++;
            if (q - p >= 3 && q - p <= 64)
                counts[std::string((char *)raw.data() + p, q - p)]++;
            p = q;
        }
        std::vector<std::pair<std::string, uint32_t>> v;
        for (auto &x : counts)
            if (x.second >= 4 && (x.second - 1) * (x.first.size() - 2) > x.first.size() + 5)
                v.push_back(x);
        std::sort(v.begin(), v.end(), [](auto &a, auto &b) {
            auto x = (a.second - 1) * (a.first.size() - 1),
                 y = (b.second - 1) * (b.first.size() - 1);
            return x != y ? x > y : a.first < b.first;
        });
        if (v.size() > cap / 2)
            v.resize(cap / 2);
        for (auto &x : v) {
            words[x.first] = g.exp.size();
            Tokens r;
            for (uint8_t c : x.first)
                r.push_back(c);
            g.rules.push_back(r);
            g.exp.push_back(x.first);
        }
    }
    std::vector<Tokens> blocks;
    for (size_t start = 0; start < raw.size(); start += block) {
        Tokens seq;
        size_t end = std::min(start + block, raw.size());
        for (size_t p = start; p < end;) {
            if (policy && word(raw[p])) {
                size_t q = p + 1;
                while (q < end && word(raw[q]))
                    q++;
                auto it = words.find(std::string((char *)raw.data() + p, q - p));
                if (it != words.end()) {
                    seq.push_back(it->second);
                    p = q;
                    continue;
                }
            }
            seq.push_back(raw[p++]);
        }
        blocks.push_back(std::move(seq));
    }
    struct Pair {
        uint64_t key;
        uint32_t count;
    };
    for (unsigned pass = 0; pass < passes && g.rules.size() < cap; pass++) {
        std::unordered_map<uint64_t, uint32_t> cnt;
        for (auto &s : blocks)
            for (size_t i = 1; i < s.size(); i++)
                cnt[pairkey(s[i - 1], s[i])]++;
        std::vector<Pair> rank;
        for (auto &[k, c] : cnt) {
            uint32_t a = k >> 32, b = uint32_t(k);
            if (c >= 8 && g.exp[a].size() + g.exp[b].size() <= 256)
                rank.push_back({k, c});
        }
        std::sort(rank.begin(), rank.end(), [](auto &a, auto &b) {
            return a.count != b.count ? a.count > b.count : a.key < b.key;
        });
        if (rank.size() > std::min<size_t>(512, cap - g.rules.size()))
            rank.resize(std::min<size_t>(512, cap - g.rules.size()));
        std::vector<bool> left(g.exp.size()), right(g.exp.size());
        std::unordered_map<uint64_t, uint32_t> selected;
        for (auto &x : rank) {
            uint32_t a = x.key >> 32, b = x.key;
            if (a == b || right[a] || left[b])
                continue;
            left[a] = right[b] = true;
            selected[x.key] = g.exp.size();
            g.rules.push_back({a, b});
            g.exp.push_back(g.exp[a] + g.exp[b]);
        }
        if (selected.empty())
            break;
        size_t changed = 0;
        for (auto &s : blocks) {
            Tokens t;
            t.reserve(s.size());
            for (size_t i = 0; i < s.size();) {
                if (i + 1 < s.size()) {
                    auto it = selected.find(pairkey(s[i], s[i + 1]));
                    if (it != selected.end()) {
                        t.push_back(it->second);
                        i += 2;
                        changed++;
                        continue;
                    }
                }
                t.push_back(s[i++]);
            }
            s.swap(t);
        }
        if (!changed)
            break;
    }
    // Stored-site pruning: inline every rule with fewer than two stored uses.
    std::vector<uint32_t> uses(g.exp.size());
    std::vector<bool> reach(g.exp.size());
    Tokens todo;
    for (auto &s : blocks)
        for (auto x : s)
            if (x >= 256) {
                uses[x]++;
                todo.push_back(x);
            }
    while (!todo.empty()) {
        auto x = todo.back();
        todo.pop_back();
        if (reach[x])
            continue;
        reach[x] = true;
        for (auto y : g.rules[x - 256])
            if (y >= 256) {
                uses[y]++;
                todo.push_back(y);
            }
    }
    std::vector<uint32_t> ids(g.exp.size());
    for (uint32_t i = 0; i < 256; i++)
        ids[i] = i;
    Grammar pruned = basegrammar();
    for (size_t i = 256; i < g.exp.size(); i++)
        if (reach[i] && uses[i] >= 2) {
            ids[i] = pruned.exp.size();
            pruned.exp.push_back(g.exp[i]);
            pruned.rules.push_back({});
        }
    std::function<void(uint32_t, Tokens &)> lower = [&](uint32_t x, Tokens &out) {
        if (x < 256 || ids[x])
            out.push_back(ids[x]);
        else
            for (auto y : g.rules[x - 256])
                lower(y, out);
    };
    for (size_t i = 256; i < g.exp.size(); i++)
        if (ids[i])
            for (auto x : g.rules[i - 256])
                lower(x, pruned.rules[ids[i] - 256]);
    return pruned;
}
static Bytes grammarmodel(const Grammar &g) {
    Bytes b;
    put(b, g.rules.size());
    for (auto &r : g.rules) {
        put(b, r.size());
        for (auto x : r)
            put(b, x);
    }
    return b;
}
static Grammar parsegrammar(const Bytes &b) {
    Reader r{b};
    auto g = basegrammar();
    auto n = r.get();
    need(n <= 32768, "grammar rule bound");
    size_t total = 256;
    for (size_t i = 0; i < n; i++) {
        auto count = r.get();
        need(count >= 2 && count <= 256, "grammar arity");
        Tokens rule;
        std::string s;
        for (size_t j = 0; j < count; j++) {
            auto x = r.get();
            need(x < g.exp.size(), "grammar forward ref");
            need(g.exp[x].size() <= 256 - s.size(), "grammar expansion bound");
            rule.push_back(x);
            s += g.exp[x];
        }
        total += s.size();
        need(total <= 8 * 1024 * 1024, "grammar expanded limit");
        g.rules.push_back(rule);
        g.exp.push_back(s);
    }
    need(r.p == b.size(), "grammar trailing bytes");
    return g;
}
// Stored expansions can share affixes directly instead of shipping grammar edges.
static Bytes flatmodel(const Grammar &g, bool reverse) {
    Bytes b;
    put(b, g.exp.size() - 256);
    std::string prev;
    for (size_t i = 256; i < g.exp.size(); i++) {
        auto word = g.exp[i];
        if (reverse)
            std::reverse(word.begin(), word.end());
        size_t shared = 0;
        while (shared < prev.size() && shared < word.size() && prev[shared] == word[shared])
            shared++;
        put(b, shared);
        put(b, word.size() - shared);
        b.insert(b.end(), word.begin() + shared, word.end());
        prev = word;
    }
    return b;
}
static Grammar parseflat(const Bytes &b, bool reverse) {
    Reader r{b};
    auto g = basegrammar();
    auto n = r.get();
    need(n <= 32768, "flat vocabulary count");
    size_t total = 256;
    std::string prev;
    for (size_t i = 0; i < n; i++) {
        auto shared = r.get(), tail = r.get();
        need(shared <= prev.size() && shared + tail >= 2 && shared + tail <= 256,
             "flat vocabulary length");
        auto bytes = r.take(tail);
        auto word = prev.substr(0, shared);
        word.append((char *)bytes.data(), bytes.size());
        need(i == 0 || prev <= word, "flat vocabulary order");
        prev = word;
        if (reverse)
            std::reverse(word.begin(), word.end());
        total += word.size();
        need(total <= 8 * 1024 * 1024, "flat expansion memory");
        g.exp.push_back(word);
    }
    need(r.p == b.size(), "flat vocabulary tail");
    return g;
}
static void reorder_dictionary(Grammar &g, std::vector<Tokens> &roots, bool reverse) {
    Tokens ids(g.exp.size() - 256);
    std::iota(ids.begin(), ids.end(), 256);
    std::vector<std::string> keys = g.exp;
    if (reverse)
        for (auto &x : keys)
            std::reverse(x.begin(), x.end());
    std::sort(ids.begin(), ids.end(),
              [&](auto a, auto b) { return keys[a] != keys[b] ? keys[a] < keys[b] : a < b; });
    Tokens remap(g.exp.size());
    std::iota(remap.begin(), remap.end(), 0);
    auto exp = g.exp;
    for (size_t i = 0; i < ids.size(); i++) {
        exp[i + 256] = g.exp[ids[i]];
        remap[ids[i]] = i + 256;
    }
    g.exp = std::move(exp);
    for (auto &t : roots)
        for (auto &x : t)
            x = remap[x];
}
struct Node {
    std::unordered_map<uint8_t, uint32_t> next;
    uint32_t symbol = UINT32_MAX;
};
static std::vector<Node> trie(const Grammar &g) {
    std::vector<Node> t(1);
    for (uint32_t x = 256; x < g.exp.size(); x++) {
        uint32_t p = 0;
        for (uint8_t c : g.exp[x]) {
            auto it = t[p].next.find(c);
            if (it == t[p].next.end()) {
                uint32_t q = t.size();
                t[p].next[c] = q;
                t.push_back({});
                p = q;
            } else
                p = it->second;
        }
        if (t[p].symbol == UINT32_MAX)
            t[p].symbol = x;
    }
    return t;
}
static Tokens parse(const Bytes &b, const std::vector<Node> &tr) {
    Tokens t;
    for (size_t p = 0; p < b.size();) {
        uint32_t node = 0, best = b[p];
        size_t q = p, n = 1;
        while (q < b.size()) {
            auto it = tr[node].next.find(b[q]);
            if (it == tr[node].next.end())
                break;
            node = it->second;
            q++;
            if (tr[node].symbol != UINT32_MAX) {
                best = tr[node].symbol;
                n = q - p;
            }
        }
        t.push_back(best);
        p += n;
    }
    return t;
}
// The encoder may optimize ambiguous phrase boundaries; no parse metadata is sent.
static Tokens parse_dp(const Bytes &b, const std::vector<Node> &tr,
                       const std::vector<double> &price) {
    std::vector<double> cost(b.size() + 1);
    std::vector<uint32_t> chosen(b.size()), length(b.size());
    for (size_t p = b.size(); p-- > 0;) {
        cost[p] = price[b[p]] + cost[p + 1];
        chosen[p] = b[p];
        length[p] = 1;
        uint32_t node = 0;
        for (size_t q = p; q < b.size(); q++) {
            auto it = tr[node].next.find(b[q]);
            if (it == tr[node].next.end())
                break;
            node = it->second;
            auto x = tr[node].symbol;
            if (x != UINT32_MAX) {
                double candidate = price[x] + cost[q + 1];
                if (candidate < cost[p]) {
                    cost[p] = candidate;
                    chosen[p] = x;
                    length[p] = q - p + 1;
                }
            }
        }
    }
    Tokens t;
    for (size_t p = 0; p < b.size(); p += length[p])
        t.push_back(chosen[p]);
    return t;
}
static Tokens ordering(const Grammar &g, unsigned mode) {
    Tokens ids(g.exp.size());
    std::iota(ids.begin(), ids.end(), 0);
    if (mode) {
        std::vector<std::string> keys = g.exp;
        if (mode == 2)
            for (auto &x : keys)
                std::reverse(x.begin(), x.end());
        std::sort(ids.begin(), ids.end(), [&](auto a, auto b) {
            if (mode == 3 && keys[a].size() != keys[b].size())
                return keys[a].size() < keys[b].size();
            return keys[a] != keys[b] ? keys[a] < keys[b] : a < b;
        });
    }
    return ids;
}
static std::pair<Tokens, uint32_t> bwt(const Tokens &s) {
    size_t n = s.size();
    need(n, "empty BWT");
    std::vector<uint32_t> sa(n), rank = s, tmp(n), shift(n);
    std::iota(sa.begin(), sa.end(), 0);
    std::sort(sa.begin(), sa.end(),
              [&](auto a, auto b) { return rank[a] != rank[b] ? rank[a] < rank[b] : a < b; });
    uint32_t groups = 1;
    tmp[sa[0]] = 0;
    for (size_t i = 1; i < n; i++) {
        groups += (s[sa[i]] != s[sa[i - 1]]);
        tmp[sa[i]] = groups - 1;
    }
    rank.swap(tmp);
    for (size_t len = 1; len < n && groups < n; len *= 2) {
        for (size_t i = 0; i < n; i++)
            shift[i] = (sa[i] + n - len) % n;
        std::vector<size_t> counts(groups);
        for (auto x : shift)
            counts[rank[x]]++;
        size_t at = 0;
        for (auto &x : counts) {
            auto old = x;
            x = at;
            at += old;
        }
        for (auto x : shift)
            sa[counts[rank[x]]++] = x;
        uint32_t next = 1;
        tmp[sa[0]] = 0;
        for (size_t i = 1; i < n; i++) {
            auto a = sa[i], b = sa[i - 1];
            next += (rank[a] != rank[b] || rank[(a + len) % n] != rank[(b + len) % n]);
            tmp[a] = next - 1;
        }
        rank.swap(tmp);
        groups = next;
    }
    Tokens last(n);
    uint32_t primary = 0;
    for (size_t i = 0; i < n; i++) {
        last[i] = s[(sa[i] + n - 1) % n];
        if (sa[i] == 0)
            primary = i;
    }
    return {last, primary};
}
static Tokens ibwt(const Tokens &last, uint32_t primary, size_t alphabet) {
    size_t n = last.size();
    need(n && primary < n, "BWT primary");
    std::vector<uint32_t> cnt(alphabet), lf(n);
    for (auto x : last) {
        need(x < alphabet, "BWT symbol");
        cnt[x]++;
    }
    uint32_t sum = 0;
    for (auto &x : cnt) {
        auto old = x;
        x = sum;
        sum += old;
    }
    for (size_t i = 0; i < n; i++)
        lf[i] = cnt[last[i]]++;
    Tokens t(n);
    uint32_t row = primary;
    for (size_t i = n; i-- > 0;) {
        t[i] = last[row];
        row = lf[row];
    }
    return t;
}
static Tokens events(const Tokens &last, size_t alphabet) {
    Tokens list(alphabet), pos(alphabet), ev;
    std::iota(list.begin(), list.end(), 0);
    std::iota(pos.begin(), pos.end(), 0);
    uint32_t run = 0;
    auto flush = [&]() {
        if (!run)
            return;
        uint32_t x = run - 1;
        while (true) {
            ev.push_back(x & 1);
            if (x < 2)
                break;
            x = (x - 2) / 2;
        }
        run = 0;
    };
    for (auto x : last) {
        auto rank = pos[x];
        if (!rank) {
            run++;
            continue;
        }
        flush();
        ev.push_back(rank + 1);
        for (uint32_t j = rank; j; j--) {
            list[j] = list[j - 1];
            pos[list[j]] = j;
        }
        list[0] = x;
        pos[x] = 0;
    }
    flush();
    return ev;
}
// A tiered MTF sequence moves one boundary value per 64-symbol segment.
// Large ranks therefore avoid shifting the entire dictionary alphabet.
struct MoveFront {
    std::vector<uint16_t> data;
    std::vector<uint8_t> heads;
    size_t alphabet;
    explicit MoveFront(size_t n) : data((n + 63) / 64 * 64), heads((n + 63) / 64), alphabet(n) {
        std::iota(data.begin(), data.end(), 0);
    }
    uint16_t at(size_t block, size_t offset) const {
        return data[block * 64 + ((heads[block] + offset) & 63)];
    }
    void set(size_t block, size_t offset, uint16_t x) {
        data[block * 64 + ((heads[block] + offset) & 63)] = x;
    }
    uint16_t front() const { return at(0, 0); }
    uint16_t move(size_t rank) {
        need(rank < alphabet, "MTF rank");
        size_t block = rank / 64, off = rank % 64;
        auto x = at(block, off);
        for (size_t j = off; j; j--)
            set(block, j, at(block, j - 1));
        set(block, 0, block ? at(block - 1, 63) : x);
        if (block) {
            for (size_t b = block - 1; b; b--) {
                auto last = at(b - 1, 63);
                heads[b] = (heads[b] - 1) & 63;
                set(b, 0, last);
            }
            heads[0] = (heads[0] - 1) & 63;
            set(0, 0, x);
        }
        return x;
    }
};
static Tokens unevents(const Tokens &ev, size_t n, size_t alphabet) {
    MoveFront list(alphabet);
    Tokens last;
    last.reserve(n);
    for (size_t p = 0; p < ev.size();) {
        auto x = ev[p++];
        if (x < 2) {
            uint64_t run = 0, weight = 1;
            while (true) {
                run += weight * (x + 1);
                need(run <= n - last.size(), "zero run exceeds roots");
                if (p == ev.size() || ev[p] >= 2)
                    break;
                need(weight <= n, "zero run overflow");
                weight *= 2;
                x = ev[p++];
            }
            last.insert(last.end(), run, list.front());
        } else {
            auto rank = x - 1;
            need(rank < alphabet && last.size() < n, "MTF event bound");
            last.push_back(list.move(rank));
        }
    }
    need(last.size() == n, "root count");
    return last;
}
static Bytes expand(const Tokens &t, const Grammar &g, size_t n) {
    Bytes b;
    b.reserve(n);
    for (auto x : t) {
        need(x < g.exp.size(), "expansion symbol");
        auto &s = g.exp[x];
        need(s.size() <= n - b.size(), "expansion raw bound");
        b.insert(b.end(), s.begin(), s.end());
    }
    need(b.size() == n, "expansion raw length");
    return b;
}

struct Record {
    uint64_t offset;
    uint32_t encoded, raw, roots, primary, evs, sum;
};
struct Opt {
    size_t block = 65536, cap = 16384;
    unsigned passes = 64, policy = 0, order = 1, dp = 2, contexts = 1, dict = 0;
    int index = -1;
};
static Bytes encode(const Bytes &raw, const Opt &o) {
    need(raw.size() <= MAXRAW && o.block && o.block <= 4 * 1024 * 1024 && o.cap <= 32768 &&
             (raw.size() + o.block - 1) / o.block <= 1000000,
         "encoder limits");
    auto g = build(raw, o.block, o.cap, o.passes, o.policy);
    auto tr = trie(g);
    std::vector<Bytes> rawblocks;
    std::vector<Tokens> roots;
    for (size_t p = 0; p < raw.size(); p += o.block) {
        rawblocks.emplace_back(raw.begin() + p, raw.begin() + std::min(p + o.block, raw.size()));
        roots.push_back(parse(rawblocks.back(), tr));
    }
    for (unsigned round = 0; round < o.dp; round++) {
        std::vector<uint64_t> counts(g.exp.size());
        uint64_t total = 0;
        for (auto &t : roots)
            for (auto x : t) {
                counts[x]++;
                total++;
            }
        std::vector<double> price(g.exp.size());
        for (size_t x = 0; x < price.size(); x++)
            price[x] = std::log2(double(total + g.exp.size()) / (counts[x] + 1));
        for (size_t i = 0; i < roots.size(); i++)
            roots[i] = parse_dp(rawblocks[i], tr, price);
    }
    if (o.dict)
        reorder_dictionary(g, roots, o.dict == 2);
    auto ids = ordering(g, o.order);
    Tokens ranks(ids.size());
    for (size_t i = 0; i < ids.size(); i++)
        ranks[ids[i]] = i;
    auto gm = compressmodel(o.dict ? flatmodel(g, o.dict == 2) : grammarmodel(g));
    std::vector<Tokens> evs;
    std::vector<Record> rs;
    for (size_t i = 0; i < roots.size(); i++) {
        auto t = roots[i];
        for (auto &x : t)
            x = ranks[x];
        auto [last, primary] = bwt(t);
        evs.push_back(events(last, g.exp.size()));
        rs.push_back({0, 0, uint32_t(rawblocks[i].size()), uint32_t(t.size()), primary,
                      uint32_t(evs.back().size()), crc(rawblocks[i])});
    }
    auto a = contextual_train(evs, g.exp.size() + 1, o.contexts);
    auto am = compressmodel(contextual_model(a));
    Bytes payload;
    for (size_t i = 0; i < rs.size(); i++) {
        auto z = contextual_encode(evs[i], a);
        rs[i].offset = payload.size();
        if (z.size() < rs[i].raw) {
            rs[i].encoded = z.size();
            payload.insert(payload.end(), z.begin(), z.end());
        } else {
            rs[i].primary = UINT32_MAX;
            rs[i].encoded = rs[i].raw;
            auto p = i * o.block;
            payload.insert(payload.end(), raw.begin() + p, raw.begin() + p + rs[i].raw);
        }
    }
    Bytes f = {'W', 'S', 'B', '2'};
    u32(f, 2);
    u32(f, o.block);
    u32(f, rs.size());
    u64(f, raw.size());
    u32(f, gm.size());
    u32(f, am.size());
    u32(f, 0);
    u32(f, o.order + 4 * o.dict);
    f.insert(f.end(), gm.begin(), gm.end());
    f.insert(f.end(), am.begin(), am.end());
    for (auto &r : rs) {
        u64(f, r.offset);
        u32(f, r.encoded);
        u32(f, r.raw);
        u32(f, r.roots);
        u32(f, r.primary);
        u32(f, r.evs);
        u32(f, r.sum);
    }
    auto metadata = crc(f);
    for (int j = 0; j < 4; j++)
        f[32 + j] = metadata >> (8 * j);
    f.insert(f.end(), payload.begin(), payload.end());
    std::cerr << "rules=" << g.rules.size() << " grammar=" << gm.size() << " entropy=" << am.size()
              << " blocks=" << rs.size() << "\n";
    return f;
}
static Bytes decode(const Bytes &f, const Opt &o) {
    need(f.size() <= MAXFRAME && f.size() >= 40 && std::memcmp(f.data(), "WSB2", 4) == 0,
         "frame magic");
    Reader r{f, 4};
    auto version = r.r32(), block = r.r32(), count = r.r32();
    auto n = r.r64();
    auto gn = r.r32(), an = r.r32(), sum = r.r32(), reserved = r.r32();
    need(version == 2 && reserved < 12 && count <= 1000000 && gn <= 9 * 1024 * 1024 &&
             an <= 9 * 1024 * 1024 && n <= MAXRAW && block && block <= 4 * 1024 * 1024 &&
             count == (n + block - 1) / block,
         "frame header");
    uint64_t meta = 40ull + gn + an + 32ull * count;
    need(meta <= f.size(), "metadata length");
    Bytes check(f.begin(), f.begin() + meta);
    std::fill(check.begin() + 32, check.begin() + 36, 0);
    need(crc(check) == sum, "metadata checksum");
    auto dictionary = decompressmodel(r.take(gn));
    auto g = reserved / 4 ? parseflat(dictionary, reserved / 4 == 2) : parsegrammar(dictionary);
    auto ids = ordering(g, reserved % 4);
    auto a = contextual_parse(decompressmodel(r.take(an)));
    for (auto &row : a)
        need(row.f.size() == g.exp.size() + 1, "event alphabet");
    std::vector<Record> rs;
    uint64_t offset = 0, total = 0;
    for (size_t i = 0; i < count; i++) {
        Record q{r.r64(), r.r32(), r.r32(), r.r32(), r.r32(), r.r32(), r.r32()};
        size_t expected = std::min<uint64_t>(block, n - total);
        need(q.offset == offset && q.raw == expected && q.encoded &&
                 q.encoded <= f.size() - meta - offset && q.roots && q.roots <= q.raw && q.evs &&
                 q.evs <= q.roots * 2,
             "block directory");
        if (q.primary == UINT32_MAX)
            need(q.encoded == q.raw, "raw payload length");
        else
            need(q.primary < q.roots, "primary index");
        offset += q.encoded;
        total += q.raw;
        rs.push_back(q);
    }
    need(meta + offset == f.size() && total == n, "frame exact length");
    need(o.index < 0 || unsigned(o.index) < rs.size(), "block index");
    Bytes out;
    out.reserve(o.index < 0 ? n : rs[o.index].raw);
    for (size_t i = 0; i < rs.size(); i++) {
        if (o.index >= 0 && i != unsigned(o.index))
            continue;
        auto &q = rs[i];
        Bytes z(f.begin() + meta + q.offset, f.begin() + meta + q.offset + q.encoded), b;
        if (q.primary == UINT32_MAX)
            b = std::move(z);
        else {
            auto ev = contextual_decode(z, q.evs, a);
            auto last = unevents(ev, q.roots, g.exp.size());
            auto t = ibwt(last, q.primary, g.exp.size());
            for (auto &x : t)
                x = ids[x];
            b = expand(t, g, q.raw);
        }
        need(crc(b) == q.sum, "block checksum");
        out.insert(out.end(), b.begin(), b.end());
    }
    return out;
}
int main(int argc, char **argv) {
    try {
        need(argc >= 4, "usage: sbwt encode|decode INPUT OUTPUT [--block N --cap N --passes N "
                        "--policy 0|1 --index N]");
        Opt o;
        for (int i = 4; i < argc; i += 2) {
            need(i + 1 < argc, "option value");
            auto n = std::stoull(argv[i + 1]);
            need(n <= UINT32_MAX, "option range");
            std::string k = argv[i];
            if (k == "--block")
                o.block = n;
            else if (k == "--cap")
                o.cap = n;
            else if (k == "--passes")
                o.passes = n;
            else if (k == "--policy")
                o.policy = n;
            else if (k == "--index") {
                need(n <= 1000000, "block index range");
                o.index = n;
            } else if (k == "--order")
                o.order = n;
            else if (k == "--dp")
                o.dp = n;
            else if (k == "--contexts")
                o.contexts = n;
            else if (k == "--dict")
                o.dict = n;
            else
                throw std::runtime_error("unknown option");
        }
        need(o.policy < 2 && o.passes <= 256 && o.order < 4 && o.dp < 8 && o.dict < 3 &&
                 (o.contexts == 1 || o.contexts == 2 || o.contexts == 4 || o.contexts == 8),
             "encoder policy");
        auto b = read(argv[2]);
        auto begin = std::chrono::steady_clock::now();
        Bytes out;
        if (std::string(argv[1]) == "encode")
            out = encode(b, o);
        else if (std::string(argv[1]) == "decode")
            out = decode(b, o);
        else
            throw std::runtime_error("operation");
        auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                      std::chrono::steady_clock::now() - begin)
                      .count();
        auto us = ns / 1000;
        struct rusage usage{};
        getrusage(RUSAGE_SELF, &usage);
        write(argv[3], out);
        std::cout << "{\"input_bytes\":" << b.size() << ",\"output_bytes\":" << out.size()
                  << ",\"codec_us\":" << us << ",\"codec_ns\":" << ns
                  << ",\"peakrss_kib\":" << usage.ru_maxrss << "}\n";
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
