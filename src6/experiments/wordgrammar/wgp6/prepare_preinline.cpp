// Independent productive spelling learner for the unchanged native bz4 v4 backend.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <numeric>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

using U = uint32_t;
static constexpr U Fence = 0x80000000;
static constexpr U Cut = 0xffffff00;
struct Lex {
  std::vector<std::vector<U>> body;
  U add(std::vector<U> x) { body.push_back(std::move(x)); return U(body.size() + 255); }
};
static int kind(unsigned char c) {
  return (c >= 128 || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) ? 0 :
         (c >= '0' && c <= '9') ? 1 : 2;
}
static std::string read(const std::string &path, size_t maximum = 64 * 1024 * 1024) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  if (!f) throw std::runtime_error("input open");
  auto size = f.tellg();
  if (size < 0 || uint64_t(size) > maximum) throw std::runtime_error("input byte budget");
  std::string x(size_t(size), 0); f.seekg(0); f.read(x.data(), x.size());
  if (!f) throw std::runtime_error("input read");
  return x;
}
static void grow(std::vector<U> &seq, Lex &lex, U least) {
  while (true) {
    std::unordered_map<uint64_t, U> counts;
    U most = 0;
    for (size_t i = 0; i + 1 < seq.size(); ++i) {
      if (seq[i] >= Fence || seq[i + 1] >= Fence) continue;
      U n = ++counts[(uint64_t(seq[i]) << 32) | seq[i + 1]];
      most = std::max(most, n);
      if (seq[i] == seq[i + 1] && i + 2 < seq.size() && seq[i + 2] == seq[i]) ++i;
    }
    if (most < least) return;
    U bar = std::max(least, most / 2 + 1);
    std::vector<uint64_t> pairs;
    for (auto kv : counts) if (kv.second >= bar) pairs.push_back(kv.first);
    std::sort(pairs.begin(), pairs.end());
    std::unordered_map<uint64_t, U> chosen;
    for (auto pair : pairs) chosen.emplace(pair, lex.add({U(pair >> 32), U(pair)}));
    size_t out = 0;
    for (size_t i = 0; i < seq.size();) {
      auto hit = i + 1 < seq.size() ? chosen.find((uint64_t(seq[i]) << 32) | seq[i + 1]) : chosen.end();
      seq[out++] = hit == chosen.end() ? seq[i] : hit->second;
      i += hit == chosen.end() ? 1 : 2;
    }
    seq.resize(out);
  }
}
struct Seed { std::string text; U support; double cost; };
struct Suffix { U type, at; };
struct TrieNode { std::map<unsigned char, U> child; int seed = -1; };
static U get32(const std::string &bytes, size_t &at) {
  if (at > bytes.size() || bytes.size() - at < 4) throw std::runtime_error("price input truncated");
  U value = 0; for (U i = 0; i < 4; ++i) value |= U(static_cast<unsigned char>(bytes[at++])) << (8 * i);
  return value;
}
struct PriceModel {
  U tokens = 0, classes = 0;
  std::vector<float> price;
  std::vector<U> next, seed;
  void load(const std::string &path, const std::string &map, size_t count) {
    std::string data = read(path, 192 * 1024 * 1024), mapping = read(map);
    if (data.substr(0, 4) != "P6C1" || mapping.substr(0, 4) != "P6S1") throw std::runtime_error("price magic");
    size_t at = 4; tokens = get32(data, at); classes = get32(data, at);
    if (tokens < 256 || classes == 0 || classes > 128 || uint64_t(tokens) * (classes + 1) > 20000000)
      throw std::runtime_error("price model budget");
    size_t cells = size_t(tokens) * (classes + 1);
    if (data.size() - at != cells * 8) throw std::runtime_error("price layout");
    for (size_t i = 0; i < cells; ++i) {
      U bits = get32(data, at); float cost; std::memcpy(&cost, &bits, 4);
      U following = get32(data, at);
      if (!std::isfinite(cost) || cost < 0 || cost > 100 || following >= classes) throw std::runtime_error("price cell");
      price.push_back(cost); next.push_back(following);
    }
    at = 4;
    if (get32(mapping, at) != count || mapping.size() - at != count * 4) throw std::runtime_error("seed map layout");
    for (size_t i = 0; i < count; ++i) {
      U token = get32(mapping, at);
      if (token != UINT32_MAX && token >= tokens) throw std::runtime_error("seed map token");
      seed.push_back(token);
    }
  }
};
struct Parser {
  std::vector<TrieNode> trie{1};
  std::vector<Seed> *seeds;
  double bytes[256];
  const PriceModel *model = nullptr;
  Parser(std::vector<Seed> &s, const double *b) : seeds(&s) {
    std::copy(b, b + 256, bytes);
    for (U i = 0; i < s.size(); ++i) {
      U node = 0;
      for (unsigned char c : s[i].text) {
        auto it = trie[node].child.find(c);
        if (it == trie[node].child.end()) {
          U next = U(trie.size()); trie[node].child.emplace(c, next);
          trie.emplace_back(); node = next;
        } else node = it->second;
      }
      trie[node].seed = int(i);
    }
  }
  std::vector<U> parse(const std::string &s, size_t shorter = SIZE_MAX) const {
    if (model) return conditional(s, shorter);
    std::vector<double> cost(s.size() + 1, 0);
    std::vector<U> next(s.size()), sym(s.size());
    for (size_t back = s.size(); back != 0; --back) {
      size_t i = back - 1;
      cost[i] = bytes[static_cast<unsigned char>(s[i])] + cost[i + 1];
      next[i] = U(i + 1); sym[i] = static_cast<unsigned char>(s[i]);
      U node = 0;
      for (size_t j = i; j < s.size(); ++j) {
        auto it = trie[node].child.find(static_cast<unsigned char>(s[j]));
        if (it == trie[node].child.end()) break;
        node = it->second;
        int seed = trie[node].seed;
        if (seed >= 0 && j + 1 - i < shorter) {
          double trial = (*seeds)[size_t(seed)].cost + cost[j + 1];
          if (trial < cost[i]) { cost[i] = trial; next[i] = U(j + 1); sym[i] = U(256 + seed); }
        }
      }
    }
    std::vector<U> result;
    for (size_t i = 0; i < s.size(); i = next[i]) result.push_back(sym[i]);
    return result;
  }
  std::vector<U> conditional(const std::string &s, size_t shorter) const {
    const U states = model->classes + 1;
    if (uint64_t(s.size() + 1) * states > 1000000) throw std::runtime_error("conditional word DP budget");
    std::vector<double> cost((s.size() + 1) * states);
    std::vector<U> next(s.size() * states), sym(s.size() * states), row(s.size() * states);
    for (size_t back = s.size(); back != 0; --back) {
      size_t i = back - 1;
      std::vector<std::pair<size_t,U>> choices{{i+1, static_cast<unsigned char>(s[i])}};
      U node = 0;
      for (size_t j = i; j < s.size(); ++j) {
        auto it = trie[node].child.find(static_cast<unsigned char>(s[j]));
        if (it == trie[node].child.end()) break;
        node = it->second;
        int seed = trie[node].seed;
        if (seed >= 0 && j + 1 - i < shorter) choices.push_back({j+1, U(256+seed)});
      }
      for (U state = 0; state < states; ++state) {
        size_t cell = i * states + state; cost[cell] = std::numeric_limits<double>::infinity();
        for (auto option : choices) {
          U symbol = option.second;
          U token = symbol < 256 ? symbol : model->seed[symbol - 256];
          double price; U following;
          if (token != UINT32_MAX) {
            size_t priced = size_t(token) * states + state;
            price = model->price[priced]; following = model->next[priced];
          } else {
            price = (*seeds)[symbol - 256].cost;
            unsigned char last = (*seeds)[symbol - 256].text.back();
            following = model->next[size_t(last) * states + state];
          }
          double trial = price + cost[option.first * states + following];
          if (trial < cost[cell]) { cost[cell] = trial; next[cell] = U(option.first); sym[cell] = symbol; row[cell] = following; }
        }
      }
    }
    std::vector<U> result;
    U state = model->classes;
    for (size_t i = 0; i < s.size();) {
      size_t cell = i * states + state;
      result.push_back(sym[cell]); i = next[cell]; state = row[cell];
    }
    return result;
  }
};
static void put(std::ofstream &f, U x) {
  char b[4]; for (U i = 0; i < 4; ++i) b[i] = char(x >> (8 * i)); f.write(b, 4);
}
static void array(std::ofstream &f, const std::vector<U> &x) {
  if (x.size() >= UINT32_MAX) throw std::runtime_error("parse array budget");
  put(f, U(x.size())); for (U n : x) put(f, n);
}
int main(int argc, char **argv) try {
  if (argc < 3) throw std::runtime_error("prepare INPUT PARSE [--block N --seed all|prefix|suffix|edge --rounds N --defcost N --floor N --share N --capacity N --once 0|1]");
  size_t block = 65536, rounds = 4, capacity = 200000, share = 0, maxfragment = 32, preinline = 1;
  std::string mode = "all", pricepath, mappath; double defcost = 16, floor = 4; bool once = true;
  for (int i = 3; i < argc; i += 2) {
    if (i + 1 == argc) throw std::runtime_error("missing option");
    std::string k = argv[i], v = argv[i + 1];
    if (k == "--seed") mode = v;
    else if (k == "--prices") pricepath = v;
    else if (k == "--price-map") mappath = v;
    else if (k == "--block") block = std::stoul(v);
    else if (k == "--rounds") rounds = std::stoul(v);
    else if (k == "--capacity") capacity = std::stoul(v);
    else if (k == "--max-fragment") maxfragment = std::stoul(v);
    else if (k == "--preinline") preinline = std::stoul(v);
    else if (k == "--share") share = std::stoul(v);
    else if (k == "--defcost") defcost = std::stod(v);
    else if (k == "--floor") floor = std::stod(v);
    else if (k == "--once") once = std::stoul(v) != 0;
    else throw std::runtime_error("unknown option");
  }
  if (block == 0 || block > 65536 || rounds > 16 || capacity > 200000 || share > 256 || maxfragment < 2 || maxfragment > 128 ||
      !std::isfinite(floor) || floor < 0 || floor > 32 || !std::isfinite(defcost) || defcost < 0 || defcost > 256 ||
      (mode != "all" && mode != "prefix" && mode != "suffix" && mode != "edge"))
    throw std::runtime_error("invalid policy");
  std::string raw = read(argv[1]);
  const auto start = std::chrono::steady_clock::now();
  std::vector<std::string> types;
  std::unordered_map<std::string, U> ids;
  std::vector<U> stream, starts;
  for (size_t at = 0; at < raw.size();) {
    size_t end = at + 1;
    if (kind(static_cast<unsigned char>(raw[at])) != 2)
      while (end < raw.size() && kind(static_cast<unsigned char>(raw[end])) == kind(static_cast<unsigned char>(raw[at]))) ++end;
    std::string atom = raw.substr(at, end - at);
    auto inserted = ids.emplace(atom, U(types.size()));
    if (inserted.second) types.push_back(atom);
    stream.push_back(inserted.first->second); starts.push_back(U(at)); at = end;
  }
  std::vector<U> frequency(types.size());
  for (U type : stream) frequency[type]++;
  double counts[256] = {}, total = 0, bytecost[256];
  for (const auto &t : types) for (unsigned char c : t) { counts[c]++; total++; }
  for (size_t c = 0; c < 256; ++c) bytecost[c] = std::min(8.0, -std::log2((counts[c] + 1) / (total + 256)));
  std::vector<Suffix> suffix;
  for (U t = 0; t < types.size(); ++t) if (types[t].size() <= 512)
    for (U at = 0; at + 1 < types[t].size(); ++at) if (mode != "prefix" || at == 0) suffix.push_back({t, at});
  std::sort(suffix.begin(), suffix.end(), [&](Suffix a, Suffix b) {
    const auto &x = types[a.type]; const auto &y = types[b.type];
    size_t n = std::min(x.size() - a.at, y.size() - b.at);
    int order = std::memcmp(x.data() + a.at, y.data() + b.at, n);
    if (order) return order < 0;
    if (x.size() - a.at != y.size() - b.at) return x.size() - a.at < y.size() - b.at;
    return a.type != b.type ? a.type < b.type : a.at < b.at;
  });
  std::vector<U> lcp(suffix.size());
  for (size_t i = 1; i < suffix.size(); ++i) {
    auto a = suffix[i - 1], b = suffix[i];
    size_t n = std::min({maxfragment, types[a.type].size() - a.at, types[b.type].size() - b.at});
    while (lcp[i] < n && types[a.type][a.at + lcp[i]] == types[b.type][b.at + lcp[i]]) lcp[i]++;
  }
  std::vector<Seed> seeds;
  for (U len = 2; len <= maxfragment; ++len) {
    for (size_t from = 0; from < suffix.size();) {
      size_t end = from + 1; while (end < suffix.size() && lcp[end] >= len) ++end;
      U support = 0;
      if (end - from >= 3) {
        for (size_t i = from; i < end; ++i) {
          auto s = suffix[i]; bool prefix = s.at == 0, tail = s.at + len == types[s.type].size();
          if ((mode == "suffix" && !tail) || (mode == "edge" && !prefix && !tail)) continue;
          if (len <= types[s.type].size() - s.at) support++;
        }
      }
      if (support >= 3) {
        int left = -2, right = -2;
        bool left_branch = false, right_branch = len == maxfragment;
        for (size_t i = from; i < end; ++i) {
          auto q = suffix[i]; bool prefix = q.at == 0, tail = q.at + len == types[q.type].size();
          if ((mode == "suffix" && !tail) || (mode == "edge" && !prefix && !tail)) continue;
          int l = prefix ? -1 : static_cast<unsigned char>(types[q.type][q.at-1]);
          int r = tail ? -1 : static_cast<unsigned char>(types[q.type][q.at+len]);
          left_branch |= l == -1 || (left != -2 && left != l);
          right_branch |= r == -1 || (right != -2 && right != r);
          left = l; right = r;
        }
        if (!left_branch || !right_branch) { from = end; continue; }
        auto s = suffix[from];
        std::string text = types[s.type].substr(s.at, len);
        double literal = 0; for (unsigned char c : text) literal += bytecost[c];
        if (support * (literal - floor - 3) > literal + defcost)
          seeds.push_back({text, support, floor + 3 + (literal + defcost) / support});
      }
      from = end;
    }
  }
  auto gain = [&](const Seed &s) { double literal = 0; for (unsigned char c : s.text) literal += bytecost[c]; return s.support * (literal - s.cost); };
  std::sort(seeds.begin(), seeds.end(), [&](const Seed &a, const Seed &b) { double ga = gain(a), gb = gain(b); return ga != gb ? ga > gb : a.text < b.text; });
  if (seeds.size() > capacity) seeds.resize(capacity);
  std::sort(seeds.begin(), seeds.end(), [](const Seed &a, const Seed &b) { return a.text.size() != b.text.size() ? a.text.size() < b.text.size() : a.text < b.text; });
  Parser parser(seeds, bytecost);
  PriceModel prices;
  if (!pricepath.empty()) {
    if (mappath.empty()) throw std::runtime_error("--prices requires --price-map");
    prices.load(pricepath, mappath, seeds.size()); parser.model = &prices;
  }
  std::vector<std::vector<U>> words(types.size()), bodies(seeds.size());
  std::vector<U> uses(seeds.size());
  for (size_t round = 0; round <= rounds; ++round) {
    std::fill(uses.begin(), uses.end(), 0);
    for (size_t t = 0; t < types.size(); ++t) {
      words[t] = parser.parse(types[t]);
      for (U s : words[t]) if (s >= 256) uses[s - 256]++;
    }
    for (size_t c = seeds.size(); c != 0; --c) {
      size_t i = c - 1; bodies[i] = parser.parse(seeds[i].text, seeds[i].text.size());
      if (uses[i]) for (U s : bodies[i]) if (s >= 256) uses[s - 256]++;
    }
    if (round == rounds) break;
    double all = 0; for (U n : uses) all += n;
    for (size_t i = 0; i < seeds.size(); ++i) {
      double body = defcost;
      for (U s : bodies[i]) body += s < 256 ? bytecost[s] : seeds[s - 256].cost;
      double probability = -std::log2((uses[i] + 1.0) / (all + seeds.size()));
      double next = floor + probability + body / std::max(U(1), uses[i]);
      seeds[i].cost = .5 * seeds[i].cost + .5 * next;
    }
  }
  Lex lex; for (auto &b : bodies) lex.add(b);
  std::vector<U> atom(types.size());
  for (size_t t = 0; t < types.size(); ++t) {
    std::vector<U> word = words[t];
    double best = 0; size_t donor = 0, keep = 0;
    for (size_t back = 1; back <= std::min(share, t); ++back) {
      size_t common = 0, maximum = std::min({size_t(255), types[t].size(), types[t-back].size()});
      while (common < maximum && types[t][common] == types[t-back][common]) ++common;
      double g = 4.0 * common - 5 - 2 * std::log2(1 + 4.0 * back);
      if (types[t-back].size() >= 2 && g > best) { best = g; donor = t - back; keep = common; }
    }
    if (keep) {
      word = {atom[donor]};
      if (keep != types[donor].size()) word.push_back(Cut + U(keep));
      auto tail = parser.parse(types[t].substr(keep)); word.insert(word.end(), tail.begin(), tail.end());
    }
    atom[t] = word.size() == 1 ? word[0] : lex.add(word);
  }
  std::vector<U> seq;
  U fences = 0;
  for (size_t i = 0; i < stream.size(); ++i) {
    if (starts[i] >= (uint64_t(fences) + 1) * block) seq.push_back(Fence + fences++);
    U type = stream[i], symbol = atom[type];
    bool word = symbol >= 256 + seeds.size();
    bool allowed = word && frequency[type] <= preinline;
    if (allowed) for (U child : lex.body[symbol - 256]) if (child >= Cut) allowed = false;
    if (allowed) seq.insert(seq.end(), lex.body[symbol - 256].begin(), lex.body[symbol - 256].end());
    else seq.push_back(symbol);
  }
  grow(seq, lex, 4);
  std::vector<U> refs(lex.body.size()), id(lex.body.size());
  std::vector<bool> kept(lex.body.size());
  std::vector<bool> live(lex.body.size());
  std::vector<U> pending;
  for (U k : seq) if (k >= 256 && k < Fence) pending.push_back(k - 256);
  while (!pending.empty()) {
    U e = pending.back(); pending.pop_back();
    if (live[e]) continue;
    live[e] = true;
    for (U k : lex.body[e]) if (k >= 256 && k < Cut) pending.push_back(k - 256);
  }
  for (size_t i = 0; i < lex.body.size(); ++i) if (live[i])
    for (U k : lex.body[i]) if (k >= 256 && k < Cut) refs[k - 256]++;
  for (U k : seq) if (k >= 256 && k < Fence) refs[k - 256] += once ? 1 : 2;
  for (size_t i = 0; i < refs.size(); ++i) kept[i] = refs[i] >= 2;
  for (size_t i = 0; i < lex.body.size(); ++i) if (live[i]) for (size_t j = 0; j < lex.body[i].size(); ++j)
    if (lex.body[i][j] >= Cut) { kept[i] = true; U previous = lex.body[i][j-1]; if (previous >= 256) kept[previous-256] = true; }
  U nkept = 0; for (size_t i = 0; i < kept.size(); ++i) id[i] = 256 + (nkept += kept[i]) - kept[i];
  auto expand = [&](auto &&self, U k, std::vector<U> &out) -> void {
    if (k < 256 || k >= Cut) out.push_back(k);
    else if (kept[k-256]) out.push_back(id[k-256]);
    else for (U child : lex.body[k-256]) self(self, child, out);
  };
  std::vector<U> body_off{0}, kids, block_off{0}, toks;
  for (size_t i = 0; i < lex.body.size(); ++i) if (kept[i]) {
    for (U k : lex.body[i]) expand(expand, k, kids);
    body_off.push_back(U(kids.size()));
  }
  for (U k : seq) {
    if (k >= Fence) block_off.push_back(U(toks.size())); else expand(expand, k, toks);
  }
  block_off.push_back(U(toks.size()));
  auto duration = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-start).count();
  std::ofstream out(argv[2], std::ios::binary); out.write("P6P1", 4);
  array(out, body_off); array(out, kids); array(out, block_off); array(out, toks);
  if (!out) throw std::runtime_error("parse write");
  std::ofstream map(std::string(argv[2]) + ".seeds", std::ios::binary); map.write("P6S1", 4);
  put(map, U(seeds.size()));
  for (size_t i = 0; i < seeds.size(); ++i) put(map, kept[i] ? id[i] : UINT32_MAX);
  if (!map) throw std::runtime_error("seed map write");
  std::cout << "{\"codec_ns\":" << duration << ",\"raw_bytes\":" << raw.size()
            << ",\"types\":" << types.size() << ",\"seed_candidates\":" << seeds.size()
            << ",\"entries\":" << nkept << ",\"body_items\":" << kids.size()
            << ",\"tokens\":" << toks.size() << ",\"blocks\":" << block_off.size()-1 << "}\n";
} catch (const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
