#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <numeric>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>
#include <zstd.h>

using Bytes = std::vector<uint8_t>;
static constexpr uint64_t MAXRAW = 512ull << 20;
static constexpr uint64_t MAXFRAME = MAXRAW + (64ull << 20);
static void demand(bool b, const char *m) {
    if (!b)
        throw std::runtime_error(m);
}
static uint32_t crc(const Bytes &b) {
    uint32_t c = ~0u;
    for (auto x : b) {
        c ^= x;
        for (int i = 0; i < 8; i++)
            c = (c >> 1) ^ (0xedb88320u & -(c & 1u));
    }
    return ~c;
}
static Bytes readfile(const char *p) {
    std::ifstream f(p, std::ios::binary | std::ios::ate);
    demand(bool(f), "cannot open input");
    auto size = f.tellg();
    demand(size >= 0 && uint64_t(size) <= MAXFRAME, "input file resource limit");
    Bytes b(static_cast<size_t>(size));
    f.seekg(0);
    if (!b.empty())
        f.read(reinterpret_cast<char *>(b.data()), b.size());
    demand(bool(f), "read input");
    return b;
}
static void writefile(const char *p, const Bytes &b) {
    std::ofstream f(p, std::ios::binary);
    demand(bool(f), "cannot open output");
    f.write((const char *)b.data(), b.size());
    demand(bool(f), "output write failure");
}
static void put(Bytes &b, uint64_t n) {
    while (n >= 128) {
        b.push_back((n & 127) | 128);
        n >>= 7;
    }
    b.push_back(n);
}
struct Reader {
    const Bytes &b;
    size_t p = 0;
    uint64_t get() {
        uint64_t x = 0;
        unsigned s = 0;
        for (unsigned i = 0; i < 10; i++, s += 7) {
            demand(p < b.size(), "truncated integer");
            auto v = b[p++];
            demand(i < 9 || v < 2, "integer overflow");
            x |= uint64_t(v & 127) << s;
            if (!(v & 128)) {
                demand(i == 0 || v != 0, "noncanonical integer");
                return x;
            }
        }
        throw std::runtime_error("integer overflow");
    }
    Bytes take(size_t n) {
        demand(n <= b.size() - p, "truncated bytes");
        Bytes a(b.begin() + p, b.begin() + p + n);
        p += n;
        return a;
    }
};
static Bytes zenc(const Bytes &b, int level = 19) {
    Bytes o(ZSTD_compressBound(b.size()));
    auto n = ZSTD_compress(o.data(), o.size(), b.data(), b.size(), level);
    demand(!ZSTD_isError(n), "zstd encode");
    o.resize(n);
    return o;
}
static Bytes zdec(const Bytes &b, size_t n) {
    demand(n <= MAXRAW, "decoded stream limit");
    Bytes o(n);
    auto got = ZSTD_decompress(o.data(), o.size(), b.data(), b.size());
    demand(!ZSTD_isError(got) && got == n, "zstd decode");
    return o;
}
static bool isword(uint8_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' ||
           c >= 128;
}
struct Word {
    std::string s;
    uint32_t count = 0;
};
static std::string lower(std::string s) {
    for (auto &c : s)
        if (c >= 'A' && c <= 'Z')
            c += 32;
    return s;
}
static unsigned casing(const std::string &s) {
    bool all = true, title = !s.empty() && s[0] >= 'A' && s[0] <= 'Z';
    for (size_t i = 0; i < s.size(); i++) {
        auto c = s[i];
        if (c >= 'a' && c <= 'z')
            all = false;
        if (i && c >= 'A' && c <= 'Z')
            title = false;
    }
    if (s == lower(s))
        return 0;
    if (all)
        return 2;
    if (title)
        return 1;
    return 3;
}
static void applycase(std::string &s, unsigned c) {
    if (c == 1) {
        if (!s.empty() && s[0] >= 'a' && s[0] <= 'z')
            s[0] -= 32;
    } else if (c == 2)
        for (auto &x : s)
            if (x >= 'a' && x <= 'z')
                x -= 32;
}
struct Lex {
    std::vector<std::string> v;
    std::unordered_map<std::string, uint32_t> ids;
    bool fold = false;
};
static Lex learn(const Bytes &raw, bool fold, size_t cap, unsigned mincount) {
    std::unordered_map<std::string, uint32_t> cnt;
    for (size_t p = 0; p < raw.size();) {
        if (!isword(raw[p])) {
            p++;
            continue;
        }
        size_t q = p + 1;
        while (q < raw.size() && isword(raw[q]))
            q++;
        if (q - p >= 2 && q - p <= 256) {
            std::string s((char *)raw.data() + p, q - p);
            if (!fold || casing(s) != 3)
                cnt[fold ? lower(s) : s]++;
        }
        p = q;
    }
    std::vector<Word> w;
    for (auto &[s, n] : cnt)
        if (n >= mincount && int64_t(n - 1) * (int64_t(s.size()) - 2) > int64_t(s.size()) + 3)
            w.push_back({s, n});
    std::sort(w.begin(), w.end(), [](auto &a, auto &b) {
        auto ga = uint64_t(a.count - 1) * (a.s.size() - 1),
             gb = uint64_t(b.count - 1) * (b.s.size() - 1);
        return ga != gb ? ga > gb : a.s < b.s;
    });
    if (w.size() > cap)
        w.resize(cap);
    Lex l;
    l.fold = fold;
    for (auto &x : w)
        l.v.push_back(x.s);
    std::sort(l.v.begin(), l.v.end());
    for (size_t i = 0; i < l.v.size(); i++)
        l.ids[l.v[i]] = i;
    return l;
}
static Bytes lexmodel(const Lex &l) {
    Bytes b;
    put(b, l.v.size());
    std::string prev;
    for (auto &s : l.v) {
        size_t n = 0;
        while (n < prev.size() && n < s.size() && prev[n] == s[n])
            n++;
        put(b, n);
        put(b, s.size() - n);
        b.insert(b.end(), s.begin() + n, s.end());
        prev = s;
    }
    return b;
}
static Lex parselex(const Bytes &b, bool fold) {
    Reader r{b};
    Lex l;
    l.fold = fold;
    auto n = r.get();
    demand(n <= 65536, "vocabulary limit");
    std::string prev;
    for (size_t i = 0; i < n; i++) {
        auto p = r.get(), s = r.get();
        demand(p <= prev.size() && p + s <= 256, "vocabulary spelling limit");
        auto tail = r.take(s);
        std::string x = prev.substr(0, p);
        x.append((char *)tail.data(), tail.size());
        demand(i == 0 || prev < x, "vocabulary order");
        l.v.push_back(x);
        prev = x;
    }
    demand(r.p == b.size(), "vocabulary trailing bytes");
    return l;
}
static std::vector<uint32_t> tokenize(const Bytes &raw, const Lex &l) {
    std::vector<uint32_t> t;
    for (size_t p = 0; p < raw.size();) {
        if (isword(raw[p])) {
            size_t q = p + 1;
            while (q < raw.size() && isword(raw[q]))
                q++;
            std::string s((char *)raw.data() + p, q - p);
            unsigned c = l.fold ? casing(s) : 0;
            if (c != 3) {
                auto it = l.ids.find(l.fold ? lower(s) : s);
                if (it != l.ids.end()) {
                    t.push_back(256 + it->second * (l.fold ? 3 : 1) + c);
                    p = q;
                    continue;
                }
            }
        }
        t.push_back(raw[p++]);
    }
    return t;
}
static Bytes packtokens(const std::vector<uint32_t> &t, unsigned mode) {
    Bytes b;
    if (mode == 0)
        for (auto x : t)
            put(b, x);
    else if (mode == 1) {
        for (auto x : t) {
            demand(x < 65536, "u16 token limit");
            b.push_back(x);
            b.push_back(x >> 8);
        }
    } else if (mode == 2) {
        for (auto x : t) {
            demand(x < 65536, "u16 token limit");
            b.push_back(x);
        }
        for (auto x : t)
            b.push_back(x >> 8);
    } else if (mode == 3) {
        Bytes low, hi;
        for (auto x : t) {
            low.push_back(x & 127);
            put(hi, x >> 7);
        }
        put(b, low.size());
        b.insert(b.end(), low.begin(), low.end());
        b.insert(b.end(), hi.begin(), hi.end());
    }
    return b;
}
static std::vector<uint32_t> unpacktokens(const Bytes &b, unsigned mode, size_t n) {
    std::vector<uint32_t> t;
    t.reserve(n);
    if (mode == 0) {
        Reader r{b};
        while (r.p < b.size()) {
            auto x = r.get();
            demand(x <= 200000, "token limit");
            t.push_back(x);
            demand(t.size() <= n, "token count excess");
        }
    } else if (mode == 1 || mode == 2) {
        demand(b.size() == 2 * n, "u16 stream length");
        for (size_t i = 0; i < n; i++)
            t.push_back(mode == 1 ? (b[2 * i] | unsigned(b[2 * i + 1]) << 8)
                                  : (b[i] | unsigned(b[n + i]) << 8));
    } else {
        Reader r{b};
        demand(r.get() == n, "split stream count");
        auto low = r.take(n);
        for (auto v : low) {
            demand(v < 128, "split low symbol");
            auto x = r.get();
            demand(x <= 1600, "split token limit");
            t.push_back(v + uint32_t(x) * 128);
        }
        demand(r.p == b.size(), "split stream tail");
    }
    demand(t.size() == n, "token count");
    return t;
}
static Bytes expand(const std::vector<uint32_t> &t, const Lex &l, size_t n) {
    Bytes b;
    b.reserve(n);
    for (auto x : t) {
        if (x < 256)
            b.push_back(x);
        else {
            x -= 256;
            unsigned c = l.fold ? x % 3 : 0;
            x /= l.fold ? 3 : 1;
            demand(x < l.v.size(), "vocabulary id");
            auto s = l.v[x];
            applycase(s, c);
            demand(s.size() <= n - b.size(), "expansion exceeds raw");
            b.insert(b.end(), s.begin(), s.end());
        }
        demand(b.size() <= n, "literal exceeds raw");
    }
    demand(b.size() == n, "raw length mismatch");
    return b;
}

struct Options {
    size_t block = 65536, cap = 16384;
    unsigned mode = 0, mincount = 3;
    bool fold = false;
    int level = 19;
};
static Bytes encode(const Bytes &raw, const Options &o) {
    demand(raw.size() <= MAXRAW && o.block && o.block <= 4 * 1024 * 1024, "input/block limit");
    auto l = learn(raw, o.fold, o.cap, o.mincount);
    auto m = lexmodel(l), mz = zenc(m, o.level);
    Bytes f = {'W', 'Z', 'P', '1'};
    put(f, raw.size());
    put(f, o.block);
    put(f, o.fold);
    put(f, o.mode);
    put(f, m.size());
    put(f, mz.size());
    f.insert(f.end(), mz.begin(), mz.end());
    put(f, crc(raw));
    for (size_t p = 0; p < raw.size(); p += o.block) {
        Bytes b(raw.begin() + p, raw.begin() + std::min(p + o.block, raw.size()));
        auto t = tokenize(b, l);
        auto packed = packtokens(t, o.mode);
        auto z = zenc(packed, o.level), rz = zenc(b, o.level);
        bool coded = z.size() + 10 < rz.size();
        put(f, coded ? 1 : 0);
        put(f, coded ? t.size() : b.size());
        put(f, coded ? packed.size() : b.size());
        auto &pay = coded ? z : rz;
        put(f, pay.size());
        f.insert(f.end(), pay.begin(), pay.end());
    }
    return f;
}
static Bytes decode(const Bytes &f) {
    demand(f.size() <= MAXFRAME && f.size() >= 4 && std::memcmp(f.data(), "WZP1", 4) == 0, "magic");
    Reader r{f, 4};
    auto n = r.get(), block = r.get(), fold = r.get(), mode = r.get(), mn = r.get(), mz = r.get();
    demand(n <= MAXRAW && block && block <= 4 * 1024 * 1024 && fold < 2 && mode < 4 &&
               mn <= 32 * 1024 * 1024 && mz <= 40 * 1024 * 1024,
           "frame limits");
    auto l = parselex(zdec(r.take(mz), mn), fold);
    auto sum = r.get();
    demand(sum <= UINT32_MAX, "checksum bound");
    Bytes out;
    out.reserve(n);
    while (out.size() < n) {
        auto coded = r.get(), tn = r.get(), pn = r.get(), zn = r.get();
        size_t bn = std::min(block, n - out.size());
        demand(coded < 2 && tn <= bn && pn <= bn * 6, "block limits");
        auto b = zdec(r.take(zn), pn);
        if (coded)
            b = expand(unpacktokens(b, mode, tn), l, bn);
        else
            demand(tn == bn && pn == bn, "raw block lengths");
        out.insert(out.end(), b.begin(), b.end());
    }
    demand(r.p == f.size() && crc(out) == sum, "checksum or trailing bytes");
    return out;
}
int main(int argc, char **argv) {
    try {
        demand(argc >= 4, "usage: wordzip encode|decode INPUT OUTPUT [--block N --mode N --fold N "
                          "--cap N --mincount N --level N]");
        Options o;
        for (int i = 4; i < argc; i += 2) {
            demand(i + 1 < argc, "missing option value");
            auto n = std::stoull(argv[i + 1]);
            std::string k = argv[i];
            if (k == "--block")
                o.block = n;
            else if (k == "--mode")
                o.mode = n;
            else if (k == "--fold")
                o.fold = n;
            else if (k == "--cap")
                o.cap = n;
            else if (k == "--mincount")
                o.mincount = n;
            else if (k == "--level")
                o.level = n;
            else
                throw std::runtime_error("unknown option");
        }
        demand(o.cap <= 20000 && o.mode < 4, "encoder options");
        auto in = readfile(argv[2]);
        auto begin = std::chrono::steady_clock::now();
        Bytes out;
        if (std::string(argv[1]) == "encode")
            out = encode(in, o);
        else if (std::string(argv[1]) == "decode")
            out = decode(in);
        else
            throw std::runtime_error("unknown operation");
        auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                      std::chrono::steady_clock::now() - begin)
                      .count();
        writefile(argv[3], out);
        std::cout << "{\"input_bytes\":" << in.size() << ",\"output_bytes\":" << out.size()
                  << ",\"codec_us\":" << us << "}\n";
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
