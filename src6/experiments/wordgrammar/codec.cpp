// Experimental shared grammar source. Exact bytes, independent raw restart
// blocks. Native self-contained static contextual rANS; no external decoder
// dependency.
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <numeric>
#include <queue>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <unordered_map>
#include <vector>
using U = uint32_t;
using Q = uint64_t;
using B = std::vector<uint8_t>;
constexpr U SCALE = 65536, RB = 1u << 23, MAX_V = 16384, MAX_RAW = 1u << 28,
            MAX_ENCODE = 1u << 26, MAX_BLOCK = 65536;
constexpr Q WORK_BUDGET = Q(4) << 30, DP_BUDGET = Q(128) << 20;
static long peakrss() {
  struct rusage u{};
  if (getrusage(RUSAGE_SELF, &u))
    return -1;
  return u.ru_maxrss;
}
static void fail(const std::string &s) { throw std::runtime_error(s); }
static B read(const std::string &p, Q limit = Q(MAX_RAW) * 2) {
  std::ifstream f(p, std::ios::binary);
  if (!f)
    fail("open input");
  f.seekg(0, std::ios::end);
  auto n = f.tellg();
  if (n < 0 || Q(n) > limit)
    fail("input limit");
  B b((size_t)n);
  f.seekg(0);
  f.read((char *)b.data(), b.size());
  if (!f)
    fail("read");
  return b;
}
static void write(const std::string &p, const B &b) {
  std::ofstream f(p, std::ios::binary);
  if (!f)
    fail("open output");
  f.write((const char *)b.data(), b.size());
  if (!f)
    fail("write");
}
static void put(B &b, Q v) {
  do {
    uint8_t x = v & 127;
    v >>= 7;
    b.push_back(x | (v ? 128 : 0));
  } while (v);
}
struct R {
  const B &b;
  size_t p = 0;
  Q get() {
    Q v = 0;
    int s = 0;
    size_t a = p;
    for (int i = 0; i < 10; i++) {
      if (p == b.size())
        fail("truncated varint");
      uint8_t x = b[p++];
      if (i == 9 && (x & 254))
        fail("varint overflow");
      v |= Q(x & 127) << s;
      if (!(x & 128)) {
        if (p - a > 1 && x == 0)
          fail("noncanonical varint");
        return v;
      }
      s += 7;
    }
    fail("varint length");
    return 0;
  }
  U u(U hi) {
    auto x = get();
    if (x > hi)
      fail("integer bound");
    return U(x);
  }
};
static U checksum(const uint8_t *p, size_t n) {
  U h = 2166136261u;
  while (n--)
    h = (h ^ *p++) * 16777619u;
  return h;
}
static void fixed(B &b, U x) {
  for (int i = 0; i < 4; i++)
    b.push_back(x >> (8 * i));
}
static U fixedread(const B &b, size_t &p) {
  if (b.size() - p < 4)
    fail("truncated fixed");
  U x = 0;
  for (int i = 0; i < 4; i++)
    x |= U(b[p++]) << (8 * i);
  return x;
}
struct Pair {
  Q key;
  U count = 0;
  std::vector<U> pos;
};
struct Copy {
  U length, distance;
};
struct Grammar {
  std::vector<std::array<U, 2>> rules;
  std::vector<B> words;
  std::vector<std::vector<U>> blocks;
  std::vector<std::vector<Copy>> copies;
};
static Grammar learn(const B &raw, U block, U lim, U mincount, U maxlen,
                     const std::vector<uint8_t> *mask = nullptr) {
  Grammar g;
  g.words.resize(256);
  for (U i = 0; i < 256; i++)
    g.words[i].push_back(i);
  if (raw.empty())
    return g;
  U n = raw.size();
  std::vector<U> s(n), next(n), prev(n);
  std::vector<U> heads;
  constexpr U END = ~U(0);
  std::unordered_map<Q, U> idx;
  idx.reserve(std::min<U>(n, 65536));
  std::vector<Pair> ps;
  ps.reserve(std::min<U>(n, 65536));
  auto key = [](U a, U b) { return Q(a) << 32 | b; };
  auto rec = [&](Q k) -> U {
    auto it = idx.find(k);
    if (it != idx.end())
      return it->second;
    U id = ps.size();
    idx.emplace(k, id);
    ps.push_back({k, 0, {}});
    return id;
  };
  for (U i = 0; i < n; i++) {
    if (mask && !(*mask)[i]) {
      s[i] = prev[i] = next[i] = END;
      continue;
    }
    s[i] = raw[i];
    prev[i] = (i % block && (!mask || (*mask)[i - 1])) ? i - 1 : END;
    next[i] = ((i + 1) % block && i + 1 < n && (!mask || (*mask)[i + 1]))
                  ? i + 1
                  : END;
    if (prev[i] == END)
      heads.push_back(i);
  }
  for (U i = 0; i < n; i++)
    if (next[i] != END) {
      auto id = rec(key(s[i], s[next[i]]));
      ps[id].count++;
      ps[id].pos.push_back(i);
    }
  using H = std::pair<U, Q>;
  std::priority_queue<H> heap;
  for (auto &p : ps)
    if (p.count >= mincount)
      heap.push({p.count, p.key});
  Q phrasebudget = 256;
  std::vector<U> changed;
  auto del = [&](U i) {
    if (i == END || next[i] == END)
      return;
    U id = idx.at(key(s[i], s[next[i]]));
    if (!ps[id].count)
      fail("internal pair count");
    ps[id].count--;
    changed.push_back(id);
  };
  auto add = [&](U i) {
    if (i == END || next[i] == END)
      return;
    U id = rec(key(s[i], s[next[i]]));
    ps[id].count++;
    ps[id].pos.push_back(i);
    changed.push_back(id);
  };
  while (g.rules.size() < lim && !heap.empty()) {
    auto h = heap.top();
    heap.pop();
    U id = idx.at(h.second);
    if (h.first != ps[id].count)
      continue;
    if (h.first < mincount)
      break;
    U a = U(h.second >> 32), b = U(h.second);
    if (g.words[a].size() + g.words[b].size() > maxlen ||
        phrasebudget + g.words[a].size() + g.words[b].size() > (1u << 25)) {
      continue;
    }
    // Move positions so newly appended occurrences cannot invalidate iterators.
    std::vector<U> occ;
    occ.swap(ps[id].pos);
    U ns = g.words.size();
    bool made = false;
    changed.clear();
    for (U i : occ) {
      if (s[i] != a || next[i] == END || s[next[i]] != b)
        continue;
      U j = next[i], l = prev[i], r = next[j];
      if (!made) {
        made = true;
        g.rules.push_back({a, b});
        B w = g.words[a];
        w.insert(w.end(), g.words[b].begin(), g.words[b].end());
        phrasebudget += w.size();
        g.words.push_back(std::move(w));
      }
      del(l);
      del(i);
      del(j);
      s[i] = ns;
      s[j] = END;
      next[i] = r;
      if (r != END)
        prev[r] = i;
      next[j] = prev[j] = END;
      add(l);
      add(i);
    }
    if (!made)
      continue;
    std::sort(changed.begin(), changed.end());
    changed.erase(std::unique(changed.begin(), changed.end()), changed.end());
    for (U t : changed)
      if (ps[t].count >= mincount)
        heap.push({ps[t].count, ps[t].key});
    if (heap.size() > ps.size() * 3) {
      decltype(heap) fresh;
      for (auto &p : ps)
        if (p.count >= mincount)
          fresh.push({p.count, p.key});
      heap.swap(fresh);
    }
  }
  for (U h : heads) {
    std::vector<U> out;
    for (U i = h; i != END; i = next[i])
      out.push_back(s[i]);
    g.blocks.push_back(std::move(out));
  }
  return g;
}
struct E {
  U cum = 0, freq = 0, bits = 16;
};
struct Row {
  U bits = 16;
  std::vector<E> enc;
  std::vector<uint16_t> dec;
  std::vector<std::pair<U, U>> entries;
};
static Row normalized(const std::vector<Q> &cnt, bool table = true,
                      U bits = 16) {
  Row r;
  r.bits = bits;
  U scale = 1u << bits;
  r.enc.resize(cnt.size());
  Q total = 0;
  U nz = 0;
  for (auto x : cnt)
    if (x) {
      total += x;
      nz++;
    }
  if (!nz || nz > scale)
    fail("model support");
  U remain = scale - nz;
  std::vector<std::pair<long double, U>> fraction;
  std::vector<U> f(cnt.size());
  U assigned = nz;
  for (U i = 0; i < cnt.size(); i++)
    if (cnt[i]) {
      long double z = (long double)cnt[i] * remain / total;
      U a = (U)z;
      f[i] = a + 1;
      assigned += a;
      fraction.push_back({z - a, i});
    }
  std::sort(fraction.begin(), fraction.end(), [](auto a, auto b) {
    return a.first > b.first || (a.first == b.first && a.second < b.second);
  });
  for (U i = 0; i < scale - assigned; i++)
    f[fraction[i].second]++;
  U c = 0;
  if (table)
    r.dec.resize(scale);
  for (U i = 0; i < f.size(); i++)
    if (f[i]) {
      r.enc[i] = {c, f[i], bits};
      r.entries.push_back({i, f[i]});
      if (table)
        std::fill(r.dec.begin() + c, r.dec.begin() + c + f[i], i);
      c += f[i];
    }
  if (c != scale)
    fail("normalization");
  return r;
}
static void rput(U &state, B &out, const E &e) {
  if (!e.freq)
    fail("zero probability");
  Q threshold = Q((RB >> e.bits) << 8) * e.freq;
  while (state >= threshold) {
    out.push_back(state & 255);
    state >>= 8;
  }
  state = U((Q(state / e.freq) << e.bits) + state % e.freq + e.cum);
}
static U rget(U &state, const Row &r, const B &payload, size_t &p) {
  U slot = state & ((1u << r.bits) - 1);
  U s = r.dec[slot];
  auto e = r.enc[s];
  state = e.freq * (state >> r.bits) + slot - e.cum;
  while (state < RB) {
    if (p == payload.size())
      fail("truncated rANS");
    state = (state << 8) | payload[p++];
  }
  return s;
}
static U coarse(const B &w, U k) {
  uint8_t x = w.back();
  U c;
  if (x == '\n' || x == '\r')
    c = 1;
  else if (x == ' ' || x == '\t')
    c = 2;
  else if (x > 127)
    c = 3 + (x & 7);
  else if (x >= '0' && x <= '9')
    c = 11;
  else if (x >= 'A' && x <= 'Z')
    c = 12;
  else if (x >= 'a' && x <= 'z')
    c = 13 + ((x - 'a') % 5);
  else
    c = 18 + (x % 5);
  return c % k;
}
struct Models {
  std::vector<uint8_t> cls;
  std::vector<Row> rows;
  Row global;
  std::vector<Row> patches;
  std::vector<int> patchids;
  std::vector<U> patchprev;
  std::vector<Row> parameters;
};
static Models models(const Grammar &g, U k, U rounds, double prune) {
  U v = g.words.size();
  Models m;
  m.cls.resize(v);
  for (U s = 0; s < v; s++)
    m.cls[s] = coarse(g.words[s], k);
  std::vector<Q> global(v, 0);
  for (U s = 0; s < 256; s++)
    global[s] = 1;
  std::vector<std::unordered_map<U, U>> next(v);
  for (auto &b : g.blocks) {
    U p = 0;
    for (U s : b) {
      global[s]++;
      next[p][s]++;
      p = s;
    }
  }
  m.global = normalized(global);
  std::vector<std::vector<Q>> counts;
  auto collect = [&] {
    counts.assign(k, std::vector<Q>(v + 1));
    for (U p = 0; p < v; p++)
      for (auto [s, n] : next[p])
        counts[m.cls[p]][s] += n;
  };
  for (U round = 0; round < rounds; round++) {
    collect();
    std::vector<double> tot(k);
    for (U c = 0; c < k; c++)
      tot[c] = std::accumulate(counts[c].begin(), counts[c].end(), double(0));
    U changed = 0;
    for (U p = 0; p < v; p++) {
      if (next[p].empty())
        continue;
      double best = 1e300;
      U bc = m.cls[p];
      for (U c = 0; c < k; c++) {
        double cost = 0;
        for (auto [s, n] : next[p])
          cost -= n * std::log2((counts[c][s] + 0.05) / (tot[c] + 0.05 * v));
        if (cost < best) {
          best = cost;
          bc = c;
        }
      }
      changed += bc != m.cls[p];
      m.cls[p] = bc;
    }
    if (!changed)
      break;
  }
  collect();
  m.rows.reserve(k);
  for (U c = 0; c < k; c++) {
    Q total = std::accumulate(counts[c].begin(), counts[c].end(), Q(0));
    Q escape = 1;
    for (U s = 0; s < v; s++)
      if (counts[c][s]) {
        double gain = counts[c][s] *
                      std::log2((double(counts[c][s]) / std::max<Q>(1, total)) /
                                (double(m.global.enc[s].freq) / SCALE));
        if (gain < prune) {
          escape += counts[c][s];
          counts[c][s] = 0;
        }
      }
    counts[c][v] = escape;
    U bits = std::getenv("WGR_ROW_BITS")
                 ? std::stoul(std::getenv("WGR_ROW_BITS"))
                 : 16;
    if (bits < 8 || bits > 16)
      fail("row precision");
    m.rows.push_back(normalized(counts[c], true, bits));
  }
  if (!g.copies.empty()) {
    std::vector<std::vector<Q>> pc(6, std::vector<Q>(256));
    for (auto &block : g.copies)
      for (auto c : block) {
        U values[2] = {c.length, c.distance};
        for (U t = 0; t < 2; t++) {
          U value = values[t], pos = 0;
          do {
            U byte = value & 127;
            value >>= 7;
            if (value)
              byte |= 128;
            pc[t * 3 + pos++][byte]++;
          } while (value);
        }
      }
    for (auto &row : pc) {
      if (std::accumulate(row.begin(), row.end(), Q(0)) == 0)
        row[0] = 1;
      m.parameters.push_back(normalized(row, false));
    }
  }
  return m;
}

// Exact Viterbi over bytes and previous source class. Grammar is unchanged;
// only the selected derivation changes, and every restart returns to the same
// state.
static void reparse(Grammar &g, const B &raw, U block, const Models &m) {
  struct T {
    std::unordered_map<uint8_t, U> edges;
    U symbol = ~U(0);
  };
  std::vector<T> trie(1);
  for (U s = 0; s < g.words.size(); s++) {
    U node = 0;
    for (uint8_t x : g.words[s]) {
      auto it = trie[node].edges.find(x);
      if (it == trie[node].edges.end()) {
        U n = trie.size();
        trie[node].edges.emplace(x, n);
        trie.push_back({});
        node = n;
      } else
        node = it->second;
    }
    trie[node].symbol = s;
  }
  U v = g.words.size(), k = m.rows.size();
  std::vector<std::vector<float>> price(v, std::vector<float>(k));
  for (U s = 0; s < v; s++)
    for (U c = 0; c < k; c++) {
      auto &r = m.rows[c];
      if (r.enc[s].freq)
        price[s][c] = r.bits - std::log2(float(r.enc[s].freq));
      else if (m.global.enc[s].freq)
        price[s][c] = r.bits + 16 - std::log2(float(r.enc[v].freq)) -
                      std::log2(float(m.global.enc[s].freq));
      else
        price[s][c] = 1e20f;
    }
  std::vector<std::vector<U>> roots;
  for (size_t off = 0; off < raw.size(); off += block) {
    U len = std::min<size_t>(block, raw.size() - off);
    size_t cells = size_t(len + 1) * k;
    if (Q(cells) *
            (sizeof(float) + sizeof(U) * 2 + sizeof(uint8_t) + sizeof(Copy)) >
        DP_BUDGET)
      fail("joint parse scratch budget");
    std::vector<float> dp(cells, 1e25f);
    std::vector<U> chosen(cells, ~U(0));
    std::vector<uint8_t> back(cells);
    dp[m.cls[0]] = 0;
    for (U i = 0; i < len; i++) {
      U node = 0;
      for (U j = i; j < len; j++) {
        auto it = trie[node].edges.find(raw[off + j]);
        if (it == trie[node].edges.end())
          break;
        node = it->second;
        U s = trie[node].symbol;
        if (s == ~U(0))
          continue;
        U to = m.cls[s];
        float best = 1e25f;
        U bc = 0;
        for (U c = 0; c < k; c++) {
          float cost = dp[size_t(i) * k + c] + price[s][c];
          if (cost < best) {
            best = cost;
            bc = c;
          }
        }
        size_t t = size_t(j + 1) * k + to;
        if (best < dp[t]) {
          dp[t] = best;
          chosen[t] = s;
          back[t] = bc;
        }
      }
    }
    U c = std::min_element(dp.end() - k, dp.end()) - (dp.end() - k), i = len;
    std::vector<U> seq;
    while (i) {
      size_t at = size_t(i) * k + c;
      U s = chosen[at];
      if (s == ~U(0))
        fail("parse unreachable");
      seq.push_back(s);
      i -= g.words[s].size();
      c = back[at];
    }
    std::reverse(seq.begin(), seq.end());
    roots.push_back(std::move(seq));
  }
  g.blocks.swap(roots);
}
static void prunegrammar(Grammar &g) {
  U v = g.words.size();
  std::vector<uint8_t> used(v, 0);
  for (auto &b : g.blocks)
    for (U s : b)
      used[s] = 1;
  for (U s = v; s-- > 256;)
    if (used[s]) {
      used[g.rules[s - 256][0]] = 1;
      used[g.rules[s - 256][1]] = 1;
    }
  std::vector<U> map(v);
  Grammar n;
  n.words.assign(g.words.begin(), g.words.begin() + 256);
  for (U s = 0; s < 256; s++)
    map[s] = s;
  for (U s = 256; s < v; s++)
    if (used[s]) {
      map[s] = n.words.size();
      auto ab = g.rules[s - 256];
      n.rules.push_back({map[ab[0]], map[ab[1]]});
      n.words.push_back(std::move(g.words[s]));
    }
  n.blocks = std::move(g.blocks);
  for (auto &b : n.blocks)
    for (U &s : b)
      s = map[s];
  g = std::move(n);
}

// Productive macro extension: a phrase may bind an exact earlier surface in
// the current restart block. Copies refer to output bytes, so a repeated stem
// remains reusable even when its surrounding grammar segmentation changes.
static void surfacecache(Grammar &g, const B &raw, U block, const Models &m,
                         U minmatch) {
  struct T {
    std::unordered_map<uint8_t, U> edges;
    U symbol = ~U(0);
  };
  std::vector<T> trie(1);
  for (U s = 0; s < g.words.size(); s++) {
    U node = 0;
    for (uint8_t x : g.words[s]) {
      auto it = trie[node].edges.find(x);
      if (it == trie[node].edges.end()) {
        U n = trie.size();
        trie[node].edges.emplace(x, n);
        trie.push_back({});
        node = n;
      } else
        node = it->second;
    }
    trie[node].symbol = s;
  }
  U v = g.words.size(), mv = m.global.enc.size();
  bool contextual = std::getenv("WGR_CONTEXT");
  U k = contextual ? m.rows.size() : 1;
  U copyclass = (mv > v ? m.cls[v] : coarse(B{0}, m.rows.size()));
  std::vector<std::vector<float>> price(v + 1, std::vector<float>(k, 12));
  for (U s = 0; s < v + 1; s++)
    for (U c = 0; c < k; c++) {
      if (s >= mv)
        continue;
      if (contextual) {
        auto &r = m.rows[c];
        if (r.enc[s].freq)
          price[s][c] = r.bits - std::log2(float(r.enc[s].freq));
        else if (m.global.enc[s].freq)
          price[s][c] = r.bits + 16 - std::log2(float(r.enc[mv].freq)) -
                        std::log2(float(m.global.enc[s].freq));
        else
          price[s][c] = 24;
      } else
        price[s][c] = m.global.enc[s].freq
                          ? 16 - std::log2(float(m.global.enc[s].freq))
                          : 24;
    }
  std::vector<std::vector<U>> roots;
  std::vector<std::vector<Copy>> copies;
  auto varbits = [&](U value, U kind) {
    if (!std::getenv("WGR_PARAMPRICE") || m.parameters.empty()) {
      U n = 8;
      while (value >= 128) {
        value >>= 7;
        n += 8;
      }
      return float(n);
    }
    float cost = 0;
    U pos = 0;
    do {
      U byte = value & 127;
      value >>= 7;
      if (value)
        byte |= 128;
      U freq = m.parameters[kind * 3 + pos++].enc[byte].freq;
      cost += freq ? 16 - std::log2(float(freq)) : 24;
    } while (value);
    return cost;
  };
  for (size_t off = 0; off < raw.size(); off += block) {
    U len = std::min<size_t>(block, raw.size() - off);
    size_t cells = size_t(len + 1) * k;
    if (Q(cells) *
            (sizeof(float) + sizeof(U) * 2 + sizeof(uint8_t) + sizeof(Copy)) >
        DP_BUDGET)
      fail("joint parse scratch budget");
    std::vector<float> dp(cells, 1e25f);
    std::vector<U> chosen(cells, ~U(0)), back(cells);
    std::vector<uint8_t> backclass(cells);
    std::vector<Copy> copy(cells);
    dp[contextual ? m.cls[0] : 0] = 0;
    std::vector<int> head(1 << 18, -1), chain(len, -1);
    std::vector<Copy> matches(len);
    auto hash = [&](U i) {
      U x = U(raw[off + i]) | (U(raw[off + i + 1]) << 8) |
            (U(raw[off + i + 2]) << 16) | (U(raw[off + i + 3]) << 24);
      return (x * 2654435761u) >> (32 - 18);
    };
    for (U i = 0; i + 4 <= len; i++) {
      U h = hash(i), best = 0, dist = 0;
      int prev = head[h];
      for (U tries = 0; prev >= 0 && tries < 16; prev = chain[prev], tries++) {
        U limit = std::min<U>(4096, len - i);
        if (best == limit)
          break;
        if (raw[off + prev + best] != raw[off + i + best])
          continue;
        U n = 0;
        while (n + 8 <= limit) {
          Q a, b;
          std::memcpy(&a, raw.data() + off + prev + n, 8);
          std::memcpy(&b, raw.data() + off + i + n, 8);
          if (a != b)
            break;
          n += 8;
        }
        while (n < limit && raw[off + prev + n] == raw[off + i + n])
          n++;
        if (n > best) {
          best = n;
          dist = i - prev;
        }
      }
      matches[i] = {best, dist};
      chain[i] = head[h];
      head[h] = i;
    }
    auto relax = [&](U i, U j, U sym, float extra, Copy cp) {
      float best = 1e25f;
      U bc = 0;
      for (U c = 0; c < k; c++) {
        float value = dp[size_t(i) * k + c] + price[sym][c] + extra;
        if (value < best) {
          best = value;
          bc = c;
        }
      }
      U tc = contextual ? (sym == v ? copyclass : m.cls[sym]) : 0;
      size_t at = size_t(j) * k + tc;
      if (best < dp[at]) {
        dp[at] = best;
        chosen[at] = sym;
        back[at] = i;
        backclass[at] = bc;
        copy[at] = cp;
      }
    };
    for (U i = 0; i < len; i++) {
      U node = 0;
      for (U j = i; j < len; j++) {
        auto it = trie[node].edges.find(raw[off + j]);
        if (it == trie[node].edges.end())
          break;
        node = it->second;
        U sym = trie[node].symbol;
        if (sym != ~U(0))
          relax(i, j + 1, sym, 0, {0, 0});
      }
      auto mt = matches[i];
      if (mt.length >= minmatch)
        relax(i, i + mt.length, v,
              varbits(mt.length, 0) + varbits(mt.distance, 1), mt);
    }
    std::vector<U> seq;
    std::vector<Copy> cp;
    U i = len, c = std::min_element(dp.end() - k, dp.end()) - (dp.end() - k);
    while (i) {
      size_t at = size_t(i) * k + c;
      U sym = chosen[at];
      if (sym == ~U(0))
        fail("cache parse unreachable");
      seq.push_back(sym);
      if (sym == v)
        cp.push_back(copy[at]);
      i = back[at];
      c = backclass[at];
    }
    std::reverse(seq.begin(), seq.end());
    std::reverse(cp.begin(), cp.end());
    roots.push_back(std::move(seq));
    copies.push_back(std::move(cp));
  }
  g.blocks.swap(roots);
  g.copies.swap(copies);
  g.words.push_back(B{0});
}
// Select sparse exact-predecessor predictive states by complete delivered cost.
// Rows have only 256 slots and escape back to the delivered class source.
static void patches(Models &m, const Grammar &g, U cap) {
  U v = g.words.size();
  m.patchids.assign(v, -1);
  std::vector<std::unordered_map<U, U>> cnt(v);
  for (auto &b : g.blocks) {
    U p = 0;
    for (U s : b) {
      cnt[p][s]++;
      p = s;
    }
  }
  struct Candidate {
    double gain;
    U prev;
    std::vector<std::pair<U, Q>> count;
  };
  std::vector<Candidate> candidates;
  auto cost = [&](U p, U s) {
    auto &r = m.rows[m.cls[p]];
    if (r.enc[s].freq)
      return r.bits - std::log2(double(r.enc[s].freq));
    return r.bits + 16 - std::log2(double(r.enc[v].freq)) -
           std::log2(double(m.global.enc[s].freq));
  };
  for (U p = 0; p < v; p++) {
    Q total = 0;
    for (auto [s, n] : cnt[p])
      total += n;
    if (total < 32 || cnt[p].size() < 2)
      continue;
    std::vector<std::pair<double, U>> rank;
    for (auto [s, n] : cnt[p]) {
      double gain = n * (cost(p, s) + std::log2(double(n) / total));
      rank.push_back({gain, s});
    }
    std::sort(rank.rbegin(), rank.rend());
    std::vector<Q> counts(v + 1);
    Q escape = total + 1;
    for (U i = 0; i < std::min<size_t>(rank.size(), 24); i++) {
      U s = rank[i].second;
      if (rank[i].first <= 0)
        continue;
      counts[s] = cnt[p][s];
      escape -= counts[s];
    }
    counts[v] = escape;
    Row row = normalized(counts, false, 8);
    double gain = 0;
    for (auto [s, n] : cnt[p]) {
      double after = row.enc[s].freq
                         ? 8 - std::log2(double(row.enc[s].freq))
                         : 8 - std::log2(double(row.enc[v].freq)) + cost(p, s);
      gain += n * (cost(p, s) - after);
    }
    // Charge a conservative worst-case predecessor/row and delta-coded entries.
    gain -= 32 + row.entries.size() * 32;
    if (gain > 64) {
      Candidate c{gain, p, {}};
      for (U s = 0; s < counts.size(); s++)
        if (counts[s])
          c.count.push_back({s, counts[s]});
      candidates.push_back(std::move(c));
    }
  }
  std::sort(candidates.begin(), candidates.end(),
            [](auto &a, auto &b) { return a.gain > b.gain; });
  if (candidates.size() > cap)
    candidates.resize(cap);
  std::sort(candidates.begin(), candidates.end(),
            [](auto &a, auto &b) { return a.prev < b.prev; });
  for (auto &c : candidates) {
    std::vector<Q> counts(v + 1);
    for (auto [s, n] : c.count)
      counts[s] = n;
    m.patchids[c.prev] = m.patches.size();
    m.patchprev.push_back(c.prev);
    m.patches.push_back(normalized(counts, true, 8));
  }
}
static void putrow(B &f, const Row &r) {
  put(f, r.entries.size());
  U last = 0;
  for (auto [s, n] : r.entries) {
    put(f, s - last);
    put(f, n);
    last = s + 1;
  }
}
static Row getrow(R &r, U v, U bits = 16) {
  U scale = 1u << bits;
  U n = r.u(v);
  if (!n)
    fail("empty row");
  Row out;
  out.bits = bits;
  out.enc.resize(v);
  out.dec.resize(scale);
  U last = 0, c = 0;
  for (U i = 0; i < n; i++) {
    U delta = r.u(v);
    if (delta >= v - last)
      fail("row symbol");
    U s = last + delta;
    U f = r.u(scale);
    if (!f || f > scale - c)
      fail("row frequency");
    out.enc[s] = {c, f, bits};
    std::fill(out.dec.begin() + c, out.dec.begin() + c + f, s);
    out.entries.push_back({s, f});
    last = s + 1;
    c += f;
  }
  if (c != scale)
    fail("row sum");
  return out;
}
struct EncodeStats {
  Q raw, frame, model, directory, roots_payload, parameters, ns, roots;
  U rules, patches, search = 1, limit = 0;
  double train_ms, entropy_ms;
};
static EncodeStats last_stats;
static void report(const EncodeStats &s) {
  std::cerr << "{\"raw\":" << s.raw << ",\"frame\":" << s.frame
            << ",\"model\":" << s.model
            << ",\"directory_bytes\":" << s.directory
            << ",\"root_payload_bytes\":" << s.roots_payload
            << ",\"copy_parameter_bytes\":" << s.parameters
            << ",\"codec_ns\":" << s.ns << ",\"peakrss_kib\":" << peakrss()
            << ",\"rules\":" << s.rules << ",\"patches\":" << s.patches
            << ",\"roots\":" << s.roots << ",\"train_ms\":" << s.train_ms
            << ",\"entropy_ms\":" << s.entropy_ms
            << ",\"search_candidates\":" << s.search
            << ",\"requested_rule_limit\":" << s.limit << "}\n";
}
static B encode(const B &raw, U block, U lim, U mincount, U maxlen, U k,
                U rounds, double prune, bool emit = true) {
  auto start = std::chrono::steady_clock::now();
  std::vector<uint8_t> mask;
  bool copyfirst = std::getenv("WGR_COPYFIRST");
  if (copyfirst) {
    Grammar seed = learn(raw, block, 0, mincount, maxlen);
    Models source = models(seed, 1, 0, prune);
    surfacecache(seed, raw, block, source, 6);
    mask.assign(raw.size(), 0);
    U off = 0;
    for (U bi = 0; bi < seed.blocks.size(); bi++) {
      U ci = 0;
      for (U sym : seed.blocks[bi]) {
        if (sym == 256) {
          off += seed.copies[bi][ci++].length;
        } else
          mask[off++] = 1;
      }
    }
    if (off != raw.size())
      fail("mask length");
  }
  Grammar g =
      learn(raw, block, lim, mincount, maxlen, copyfirst ? &mask : nullptr);
  auto trained = std::chrono::steady_clock::now();
  Models m = models(g, k, rounds, prune);
  bool copy = std::getenv("WGR_COPY");
  if (copy) {
    surfacecache(g, raw, block, m, 6);
    m = models(g, k, rounds, prune);
    if (auto option = std::getenv("WGR_REFINE")) {
      U refinements = std::stoul(option);
      if (refinements > 8)
        fail("refinements");
      for (U pass = 0; pass < refinements; pass++) {
        g.words.pop_back();
        surfacecache(g, raw, block, m, 6);
        m = models(g, k, rounds, prune);
      }
    }
  } else if (std::getenv("WGR_REPARSE")) {
    reparse(g, raw, block, m);
    prunegrammar(g);
    m = models(g, k, rounds, prune);
  }
  bool patch = copy && std::getenv("WGR_PATCH");
  if (patch)
    patches(m, g, 256);
  U rowbits = m.rows[0].bits;
  if (rowbits != 16 && (!copy || patch))
    fail("row precision requires copy without patch");
  B f = {'W', 'G', 'R',
         uint8_t(rowbits != 16 ? '5'
                 : patch       ? '4'
                 : copy        ? '3'
                               : '1')};
  put(f, raw.size());
  put(f, block);
  put(f, maxlen);
  put(f, g.rules.size());
  put(f, k);
  if (rowbits != 16)
    put(f, rowbits);
  for (auto ab : g.rules) {
    put(f, ab[0]);
    put(f, ab[1]);
  }
  U v = g.words.size();
  if (k > 1)
    f.insert(f.end(), m.cls.begin(), m.cls.end());
  putrow(f, m.global);
  for (auto &r : m.rows)
    putrow(f, r);
  std::vector<Row> paramrows;
  std::vector<std::vector<std::pair<U, U>>> paramstreams;
  if (copy) {
    std::vector<std::vector<Q>> cnt(6, std::vector<Q>(256));
    for (auto &cp : g.copies) {
      std::vector<std::pair<U, U>> stream;
      for (auto c : cp) {
        U values[2] = {c.length, c.distance};
        for (U t = 0; t < 2; t++) {
          U value = values[t], i = 0;
          do {
            U byte = value & 127;
            value >>= 7;
            if (value)
              byte |= 128;
            U ctx = t * 3 + i;
            cnt[ctx][byte]++;
            stream.push_back({ctx, byte});
            i++;
          } while (value);
        }
      }
      paramstreams.push_back(std::move(stream));
    }
    for (auto &row : cnt) {
      if (std::accumulate(row.begin(), row.end(), Q(0)) == 0)
        row[0] = 1;
      paramrows.push_back(normalized(row));
      putrow(f, paramrows.back());
    }
  }
  if (patch) {
    put(f, m.patches.size());
    U last = 0;
    for (U i = 0; i < m.patches.size(); i++) {
      put(f, m.patchprev[i] - last);
      last = m.patchprev[i] + 1;
      putrow(f, m.patches[i]);
    }
  }
  size_t modelsize = f.size();
  if (modelsize - 4 > (1u << 24))
    fail("model header budget");
  put(f, g.blocks.size());
  U offset = 0;
  Q nt = 0, rootpayload = 0, copyparams = 0;
  U blockid = 0;
  for (auto &b : g.blocks) {
    B payload;
    U state = RB;
    for (size_t i = b.size(); i-- > 0;) {
      U s = b[i], p = i ? b[i - 1] : 0;
      auto &r = m.rows[m.cls[p]];
      int pid = patch ? m.patchids[p] : -1;
      bool direct = pid >= 0 && m.patches[pid].enc[s].freq;
      if (direct)
        rput(state, payload, m.patches[pid].enc[s]);
      else {
        if (r.enc[s].freq)
          rput(state, payload, r.enc[s]);
        else {
          rput(state, payload, m.global.enc[s]);
          rput(state, payload, r.enc[v]);
        }
        if (pid >= 0)
          rput(state, payload, m.patches[pid].enc[v]);
      }
    }
    B p;
    if (copy) {
      B side;
      U side_state = RB;
      auto &events = paramstreams[blockid];
      for (size_t j = events.size(); j-- > 0;) {
        auto [ctx, byte] = events[j];
        rput(side_state, side, paramrows[ctx].enc[byte]);
      }
      fixed(p, side_state);
      std::reverse(side.begin(), side.end());
      p.insert(p.end(), side.begin(), side.end());
    }
    blockid++;
    B params = std::move(p);
    p.clear();
    fixed(p, state);
    std::reverse(payload.begin(), payload.end());
    p.insert(p.end(), payload.begin(), payload.end());
    U rawlen = std::min<U>(block, raw.size() - offset);
    put(f, rawlen);
    put(f, b.size());
    put(f, p.size() + params.size());
    if (copy)
      put(f, params.size());
    fixed(f, checksum(raw.data() + offset, rawlen));
    copyparams += params.size();
    rootpayload += p.size();
    f.insert(f.end(), params.begin(), params.end());
    f.insert(f.end(), p.begin(), p.end());
    offset += rawlen;
    nt += b.size();
  }
  if (std::getenv("WGR_PACK")) {
    B header(f.begin() + 4, f.begin() + modelsize);
    std::vector<Q> counts(256);
    for (uint8_t x : header)
      counts[x]++;
    Row byte = normalized(counts);
    B packed;
    U state = RB;
    for (size_t i = header.size(); i-- > 0;)
      rput(state, packed, byte.enc[header[i]]);
    B payload;
    fixed(payload, state);
    std::reverse(packed.begin(), packed.end());
    payload.insert(payload.end(), packed.begin(), packed.end());
    B outer = {'W', 'G', 'P', f[3]};
    put(outer, header.size());
    put(outer, payload.size());
    putrow(outer, byte);
    outer.insert(outer.end(), payload.begin(), payload.end());
    size_t packedmodel = outer.size();
    outer.insert(outer.end(), f.begin() + modelsize, f.end());
    f.swap(outer);
    modelsize = packedmodel;
  }
  auto end = std::chrono::steady_clock::now();
  last_stats = {
      raw.size(),
      f.size(),
      modelsize,
      f.size() - modelsize - rootpayload - copyparams,
      rootpayload,
      copyparams,
      Q(std::chrono::duration_cast<std::chrono::nanoseconds>(end - start)
            .count()),
      nt,
      U(g.rules.size()),
      U(m.patches.size()),
      1,
      lim,
      std::chrono::duration<double, std::milli>(trained - start).count(),
      std::chrono::duration<double, std::milli>(end - trained).count()};
  if (emit)
    report(last_stats);
  return f;
}
struct BlockInfo {
  Q raw_begin, raw_size, payload_offset, payload_size, roots, parameter_bytes;
};
struct DecodeInfo {
  Q raw = 0, frame = 0, model = 0, directory = 0, payload = 0;
  U block = 0;
  std::vector<BlockInfo> blocks;
};
static DecodeInfo decode_info;
static std::string inspect_json() {
  std::string out =
      "{\"raw_bytes\":" + std::to_string(decode_info.raw) +
      ",\"frame_bytes\":" + std::to_string(decode_info.frame) +
      ",\"model_bytes\":" + std::to_string(decode_info.model) +
      ",\"directory_bytes\":" + std::to_string(decode_info.directory) +
      ",\"payload_bytes\":" + std::to_string(decode_info.payload) +
      ",\"block_bytes\":" + std::to_string(decode_info.block) +
      ",\"records\":[";
  bool first = true;
  for (auto b : decode_info.blocks) {
    if (!first)
      out += ",";
    first = false;
    out += "{\"raw_offset\":" + std::to_string(b.raw_begin) +
           ",\"raw_size\":" + std::to_string(b.raw_size) +
           ",\"payload_offset\":" + std::to_string(b.payload_offset) +
           ",\"payload_size\":" + std::to_string(b.payload_size) +
           ",\"roots\":" + std::to_string(b.roots) +
           ",\"parameter_bytes\":" + std::to_string(b.parameter_bytes) + "}";
  }
  return out + "]}\n";
}
static B decode(const B &f, long selected = -1) {
  if (f.size() >= 4 && std::memcmp(f.data(), "WGP", 3) == 0) {
    R outer{f, 4};
    U unpacked = outer.u(1 << 24), packed = outer.u(1 << 24);
    Row byte = getrow(outer, 256);
    if (packed < 4 || packed > f.size() - outer.p)
      fail("packed header length");
    B compressed(f.begin() + outer.p, f.begin() + outer.p + packed);
    outer.p += packed;
    size_t p = 0;
    U state = fixedread(compressed, p);
    if (state < RB)
      fail("packed header state");
    B expanded = {'W', 'G', 'R', f[3]};
    for (U i = 0; i < unpacked; i++)
      expanded.push_back(rget(state, byte, compressed, p));
    if (state != RB || p != compressed.size())
      fail("packed header termination");
    expanded.insert(expanded.end(), f.begin() + outer.p, f.end());
    B result = decode(expanded, selected);
    Q diff = decode_info.model;
    decode_info.frame = f.size();
    decode_info.model = outer.p;
    for (auto &b : decode_info.blocks)
      b.payload_offset = b.payload_offset - diff + outer.p;
    return result;
  }

  if (f.size() < 4 || std::memcmp(f.data(), "WGR", 3) ||
      (f[3] != '1' && f[3] != '3' && f[3] != '4' && f[3] != '5'))
    fail("magic");
  bool copy = f[3] == '3' || f[3] == '4' || f[3] == '5';
  bool patch = f[3] == '4';
  R r{f, 4};
  U raw = r.u(MAX_RAW), block = r.u(MAX_BLOCK), maxlen = r.u(4096),
    nr = r.u(MAX_V - 256), k = r.u(64);
  if (!block || !maxlen || !k)
    fail("header");
  U rowbits = f[3] == '5' ? r.u(16) : 16;
  if (rowbits < 8)
    fail("row precision");
  U v = nr + 256 + copy;
  std::vector<B> words(v);
  for (U s = 0; s < 256; s++)
    words[s].push_back(s);
  Q budget = 0;
  for (U i = 0; i < nr; i++) {
    U id = i + 256, a = r.u(id - 1), b = r.u(id - 1);
    if (words[a].size() + words[b].size() > maxlen)
      fail("phrase length");
    words[id] = words[a];
    words[id].insert(words[id].end(), words[b].begin(), words[b].end());
    budget += words[id].size();
    if (budget > 1 << 25)
      fail("dictionary budget");
  }
  std::vector<uint8_t> cls(v, 0);
  if (k > 1)
    for (U i = 0; i < v; i++) {
      if (r.p == f.size())
        fail("truncated classes");
      cls[i] = f[r.p++];
      if (cls[i] >= k)
        fail("class");
    }
  Row global = getrow(r, v);
  for (U s = 0; s < 256; s++)
    if (!global.enc[s].freq)
      fail("missing byte fallback");
  std::vector<Row> rows;
  for (U i = 0; i < k; i++) {
    rows.push_back(getrow(r, v + 1, rowbits));
    if (!rows.back().enc[v].freq)
      fail("missing escape");
  }
  std::vector<Row> paramrows;
  if (copy)
    for (U i = 0; i < 6; i++)
      paramrows.push_back(getrow(r, 256));
  std::vector<int> patchids(v, -1);
  std::vector<Row> patchrows;
  if (patch) {
    U n = r.u(256), last = 0;
    for (U i = 0; i < n; i++) {
      U delta = r.u(v);
      if (delta >= v - last)
        fail("patch predecessor");
      U p = last + delta;
      last = p + 1;
      patchids[p] = patchrows.size();
      patchrows.push_back(getrow(r, v + 1, 8));
      if (!patchrows.back().enc[v].freq)
        fail("patch escape");
    }
  }
  decode_info = {raw, f.size(), r.p, 0, 0, block, {}};
  U nb = r.u(MAX_RAW);
  if (nb != (raw + block - 1) / block)
    fail("block count");
  if (selected >= long(nb))
    fail("selected block");
  B out;
  out.reserve(selected == -1 ? raw : std::min(block, raw));
  Q expanded = 0;
  for (U i = 0; i < nb; i++) {
    U len = r.u(block), roots = r.u(block), bytes = r.u(block * 8 + 1024);
    U paramlen = copy ? r.u(bytes) : 0;
    U hash = fixedread(f, r.p);
    if (len != std::min<U>(block, raw - i * Q(block)) || !roots ||
        roots > len || bytes < 4 || bytes > f.size() - r.p)
      fail("block header");
    decode_info.blocks.push_back(
        {Q(i) * block, len, r.p, bytes, roots, paramlen});
    decode_info.payload += bytes;
    if (paramlen > bytes - 4)
      fail("parameter length");
    size_t payloadend = r.p + bytes;
    if (selected == -2 || (selected >= 0 && long(i) != selected)) {
      r.p = payloadend;
      expanded += len;
      continue;
    }
    if (paramlen > bytes - 4)
      fail("parameter length");
    B param(f.begin() + r.p, f.begin() + r.p + paramlen);
    size_t cp = 0;
    U cpstate = copy ? fixedread(param, cp) : RB;
    if (cpstate < RB)
      fail("parameter state");
    auto getparam = [&](U kind) {
      U value = 0;
      for (U z = 0; z < 3; z++) {
        U byte = rget(cpstate, paramrows[kind * 3 + z], param, cp);
        value |= (byte & 127) << (7 * z);
        if (!(byte & 128)) {
          if (z && byte == 0)
            fail("parameter canonicality");
          return value;
        }
      }
      fail("parameter varint");
      return U(0);
    };
    B payload(f.begin() + r.p + paramlen, f.begin() + payloadend);
    r.p = payloadend;
    size_t pos = 0;
    U state = fixedread(payload, pos);
    if (state < RB)
      fail("initial state");
    U prev = 0;
    size_t begin = out.size();
    for (U j = 0; j < roots; j++) {
      int pid = patchids[prev];
      U s = pid >= 0 ? rget(state, patchrows[pid], payload, pos) : v;
      if (s == v) {
        s = rget(state, rows[cls[prev]], payload, pos);
        if (s == v)
          s = rget(state, global, payload, pos);
      }
      if (s >= v)
        fail("symbol");
      if (copy && s == v - 1) {
        U n = getparam(0), dist = getparam(1);
        if (n < 6 || n > len - (out.size() - begin) || !dist ||
            dist > out.size() - begin)
          fail("copy bound");
        size_t dst = out.size();
        out.resize(dst + n);
        U first = std::min(n, dist);
        std::memcpy(out.data() + dst, out.data() + dst - dist, first);
        U filled = first;
        while (filled < n) {
          U step = std::min(filled, n - filled);
          std::memcpy(out.data() + dst + filled, out.data() + dst, step);
          filled += step;
        }
      } else {
        if (words[s].size() > len - (out.size() - begin))
          fail("expansion bound");
        out.insert(out.end(), words[s].begin(), words[s].end());
      }
      prev = s;
    }
    if (cp != param.size() || cpstate != RB)
      fail("parameter tail");
    if (out.size() - begin != len || pos != payload.size() || state != RB)
      fail("rANS termination");
    if (checksum(out.data() + begin, len) != hash)
      fail("checksum");
    expanded += len;
  }
  decode_info.directory = f.size() - decode_info.model - decode_info.payload;
  if (r.p != f.size() || expanded != raw)
    fail("frame tail");
  return out;
}
int main(int argc, char **argv) {
  try {
    if (argc < 4)
      fail("usage: wordgrammar encode[-fast|-auto] INPUT OUTPUT [block rules "
           "classes rounds prune min-count max-phrase] | decode INPUT OUTPUT "
           "[block-index]");
    std::string mode = argv[1];
    bool encoding =
        mode == "encode" || mode == "encode-fast" || mode == "encode-auto";
    bool profile = mode != "encode" && encoding;
    B raw = read(argv[2], encoding ? MAX_ENCODE : Q(MAX_RAW) * 2), out;
    if (encoding) {
      if (profile) {
        for (auto name : {"WGR_PATCH", "WGR_COPYFIRST", "WGR_REPARSE"})
          unsetenv(name);
        for (auto name :
             {"WGR_COPY", "WGR_PACK", "WGR_CONTEXT", "WGR_PARAMPRICE"})
          setenv(name, "1", 1);
        setenv("WGR_REFINE", "2", 1);
        setenv("WGR_ROW_BITS", "14", 1);
      }
      auto val = [&](int i, U d) {
        if (argc <= i)
          return d;
        auto x = std::stoull(argv[i]);
        if (x > std::numeric_limits<U>::max())
          fail("option bound");
        return U(x);
      };
      U block = val(4, 65536), rules = val(5, profile ? 16128 : 4096),
        classes = val(6, profile ? 32 : 8), rounds = val(7, 2),
        mincount = val(9, 8), maxlen = val(10, 128);
      double prune = argc > 8 ? std::stod(argv[8]) : 24;
      if (!block || block > MAX_BLOCK)
        fail("raw restart block limit");
      if (Q(raw.size()) * 64 +
              Q(block + 1) * classes *
                  (sizeof(float) + sizeof(U) * 2 + sizeof(uint8_t) +
                   sizeof(Copy)) +
              (Q(64) << 20) >
          WORK_BUDGET)
        fail("estimated encoder work budget");
      if (rules > MAX_V - 256 || !classes || classes > 64 || rounds > 20 ||
          mincount < 2 || !maxlen || maxlen > 4096 || !std::isfinite(prune))
        fail("option");
      if (mode == "encode-auto") {
        if (argc > 5)
          fail("encode-auto accepts only an optional raw restart block size");
        auto start = std::chrono::steady_clock::now();
        EncodeStats best{};
        double train = 0, entropy = 0;
        U candidates = 0;
        for (U capacity : {0u, 128u, 512u, 2048u, 8192u, 16128u}) {
          B candidate = encode(raw, block, capacity, 8, 128, 32, 2, 24, false);
          train += last_stats.train_ms;
          entropy += last_stats.entropy_ms;
          candidates++;
          if (out.empty() || candidate.size() < out.size()) {
            out.swap(candidate);
            best = last_stats;
          }
        }
        best.ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                      std::chrono::steady_clock::now() - start)
                      .count();
        best.train_ms = train;
        best.entropy_ms = entropy;
        best.search = candidates;
        last_stats = best;
        report(best);
      } else
        out =
            encode(raw, block, rules, mincount, maxlen, classes, rounds, prune);
    } else if (mode == "inspect") {
      decode(raw, -2);
      std::string info = inspect_json();
      out.assign(info.begin(), info.end());
    } else if (mode == "decode") {
      long selected = argc > 4 ? std::stol(argv[4]) : -1;
      if (selected < -1)
        fail("block index");
      auto begin = std::chrono::steady_clock::now();
      out = decode(raw, selected);
      auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                    std::chrono::steady_clock::now() - begin)
                    .count();
      std::cerr << "{\"codec_ns\":" << ns << ",\"peakrss_kib\":" << peakrss()
                << ",\"decoded\":" << out.size() << "}\n";
    } else
      fail("mode");
    write(argv[3], out);
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "wordgrammar: " << e.what() << "\n";
    return 1;
  }
}
