// Independent productive spelling learner for the unchanged native bz4 v4
// backend.
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
static std::string read(const std::string &path,
                        size_t maximum = 64 * 1024 * 1024) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  if (!f)
    throw std::runtime_error("input open");
  auto size = f.tellg();
  if (size < 0 || uint64_t(size) > maximum)
    throw std::runtime_error("input byte budget");
  std::string x(size_t(size), 0);
  f.seekg(0);
  f.read(x.data(), x.size());
  if (!f)
    throw std::runtime_error("input read");
  return x;
}
struct Seed {
  std::string text;
  U support;
  double cost;
};
struct Suffix {
  U type, at;
};
struct TrieNode {
  std::map<unsigned char, U> child;
  int seed = -1;
};
static U get32(const std::string &bytes, size_t &at) {
  if (at > bytes.size() || bytes.size() - at < 4)
    throw std::runtime_error("price input truncated");
  U value = 0;
  for (U i = 0; i < 4; ++i)
    value |= U(static_cast<unsigned char>(bytes[at++])) << (8 * i);
  return value;
}
struct PriceModel {
  U tokens = 0, classes = 0;
  std::vector<float> price;
  std::vector<U> next, seed;
  void load(const std::string &data, size_t entries) {
    if (data.substr(0, 4) != "P6C1")
      throw std::runtime_error("price magic");
    size_t at = 4;
    tokens = get32(data, at);
    classes = get32(data, at);
    if (tokens != entries + 256 || !classes || classes > 128 ||
        uint64_t(tokens) * (classes + 1) > 20000000)
      throw std::runtime_error("price model budget");
    size_t cells = size_t(tokens) * (classes + 1);
    if (data.size() - at != cells * 8)
      throw std::runtime_error("price layout");
    price.reserve(cells);
    next.reserve(cells);
    for (size_t i = 0; i < cells; ++i) {
      U bits = get32(data, at);
      float cost;
      std::memcpy(&cost, &bits, 4);
      U following = get32(data, at);
      if (!std::isfinite(cost) || cost < 0 || cost > 100 ||
          following >= classes)
        throw std::runtime_error("price cell");
      price.push_back(cost);
      next.push_back(following);
    }
    seed.resize(entries);
    std::iota(seed.begin(), seed.end(), 256);
  }
};
struct Parser {
  std::vector<TrieNode> trie{1};
  std::vector<Seed> *seeds;
  double bytes[256];
  const PriceModel *model = nullptr;
  const std::vector<std::pair<size_t, U>> *anchors = nullptr;
  mutable uint64_t work_cells = 0;
  Parser(std::vector<Seed> &s, const double *b) : seeds(&s) {
    std::copy(b, b + 256, bytes);
    for (U i = 0; i < s.size(); ++i) {
      if (s[i].text.size() > 256)
        continue;
      U node = 0;
      for (unsigned char c : s[i].text) {
        auto it = trie[node].child.find(c);
        if (it == trie[node].child.end()) {
          U next = U(trie.size());
          trie[node].child.emplace(c, next);
          trie.emplace_back();
          node = next;
        } else
          node = it->second;
      }
      trie[node].seed = int(i);
    }
  }
  std::vector<U> parse(const std::string &s, size_t shorter = SIZE_MAX) const {
    if (model)
      return conditional(s, shorter);
    std::vector<double> cost(s.size() + 1, 0);
    std::vector<U> next(s.size()), sym(s.size());
    for (size_t back = s.size(); back != 0; --back) {
      size_t i = back - 1;
      cost[i] = bytes[static_cast<unsigned char>(s[i])] + cost[i + 1];
      next[i] = U(i + 1);
      sym[i] = static_cast<unsigned char>(s[i]);
      U node = 0;
      for (size_t j = i; j < s.size(); ++j) {
        auto it = trie[node].child.find(static_cast<unsigned char>(s[j]));
        if (it == trie[node].child.end())
          break;
        node = it->second;
        int seed = trie[node].seed;
        if (seed >= 0 && j + 1 - i < shorter) {
          double trial = (*seeds)[size_t(seed)].cost + cost[j + 1];
          if (trial < cost[i]) {
            cost[i] = trial;
            next[i] = U(j + 1);
            sym[i] = U(256 + seed);
          }
        }
      }
    }
    std::vector<U> result;
    for (size_t i = 0; i < s.size(); i = next[i])
      result.push_back(sym[i]);
    return result;
  }
  std::vector<U> conditional(const std::string &s, size_t shorter) const {
    const U states = model->classes + 1;
    if (uint64_t(s.size() + 1) * states > 10000000)
      throw std::runtime_error("conditional restart DP budget");
    std::vector<double> cost((s.size() + 1) * states);
    std::vector<U> next(s.size() * states), sym(s.size() * states),
        row(s.size() * states);
    for (size_t back = s.size(); back != 0; --back) {
      size_t i = back - 1;
      std::vector<std::pair<size_t, U>> choices{
          {i + 1, static_cast<unsigned char>(s[i])}};
      if (anchors && (*anchors)[i].first > i + 1)
        choices.push_back((*anchors)[i]);
      U node = 0;
      for (size_t j = i; j < s.size(); ++j) {
        auto it = trie[node].child.find(static_cast<unsigned char>(s[j]));
        if (it == trie[node].child.end())
          break;
        node = it->second;
        int seed = trie[node].seed;
        if (seed >= 0 && j + 1 - i < shorter)
          choices.push_back({j + 1, U(256 + seed)});
      }
      if (uint64_t(choices.size()) * states > 20000000000ULL - work_cells)
        throw std::runtime_error("conditional work budget");
      work_cells += uint64_t(choices.size()) * states;
      for (U state = 0; state < states; ++state) {
        size_t cell = i * states + state;
        cost[cell] = std::numeric_limits<double>::infinity();
        for (auto option : choices) {
          U symbol = option.second;
          U token = symbol < 256 ? symbol : model->seed[symbol - 256];
          double price;
          U following;
          if (token != UINT32_MAX) {
            size_t priced = size_t(token) * states + state;
            price = model->price[priced];
            following = model->next[priced];
          } else {
            price = (*seeds)[symbol - 256].cost;
            unsigned char last = (*seeds)[symbol - 256].text.back();
            following = model->next[size_t(last) * states + state];
          }
          double trial = price + cost[option.first * states + following];
          if (trial < cost[cell]) {
            cost[cell] = trial;
            next[cell] = U(option.first);
            sym[cell] = symbol;
            row[cell] = following;
          }
        }
      }
    }
    std::vector<U> result;
    U state = model->classes;
    for (size_t i = 0; i < s.size();) {
      size_t cell = i * states + state;
      result.push_back(sym[cell]);
      i = next[cell];
      state = row[cell];
    }
    return result;
  }
};

struct Graph {
  std::vector<std::vector<U>> bodies, blocks;
  std::vector<std::string> spellings;
  std::vector<U> array(const std::string &data, size_t &at) {
    U n = get32(data, at);
    if (n > (data.size() - at) / 4)
      throw std::runtime_error("graph array");
    std::vector<U> out;
    out.reserve(n);
    while (n--)
      out.push_back(get32(data, at));
    return out;
  }
  void load(const std::string &data, const std::string &raw) {
    if (data.substr(0, 4) != "P6F1" && data.substr(0, 4) != "P6P1")
      throw std::runtime_error("graph magic");
    size_t at = 4;
    auto off = array(data, at), kids = array(data, at), boff = array(data, at),
         toks = array(data, at);
    if (at != data.size() || off.empty() || boff.empty() || off.front() ||
        off.back() != kids.size() || boff.front() ||
        boff.back() != toks.size() || off.size() > 500001 ||
        kids.size() > 4000000 || toks.size() > 16000000)
      throw std::runtime_error("graph layout budget");
    for (size_t i = 0; i + 1 < off.size(); ++i) {
      if (off[i] >= off[i + 1] || off[i + 1] > kids.size())
        throw std::runtime_error("graph body");
      bodies.emplace_back(kids.begin() + off[i], kids.begin() + off[i + 1]);
    }
    for (size_t i = 0; i + 1 < boff.size(); ++i) {
      if (boff[i] > boff[i + 1] || boff[i + 1] > toks.size())
        throw std::runtime_error("graph block");
      blocks.emplace_back(toks.begin() + boff[i], toks.begin() + boff[i + 1]);
    }
    std::vector<U> pending(bodies.size());
    std::vector<std::vector<U>> succ(bodies.size());
    for (U i = 0; i < bodies.size(); ++i)
      for (U c : bodies[i])
        if (c >= 256) {
          if (c - 256 >= bodies.size())
            throw std::runtime_error("graph child");
          ++pending[i];
          succ[c - 256].push_back(i);
        }
    std::vector<U> ready;
    for (U i = 0; i < pending.size(); ++i)
      if (!pending[i])
        ready.push_back(i);
    spellings.resize(bodies.size());
    size_t all = 0;
    for (size_t i = 0; i < ready.size(); ++i) {
      U e = ready[i];
      std::string &s = spellings[e];
      for (U c : bodies[e]) {
        size_t n = c < 256 ? 1 : spellings[c - 256].size();
        if (s.size() + n > 64 * 1024 * 1024 || all + n > 64 * 1024 * 1024)
          throw std::runtime_error("spelling materialization budget");
        if (c < 256)
          s += char(c);
        else
          s += spellings[c - 256];
        all += n;
      }
      for (U parent : succ[e])
        if (!--pending[parent])
          ready.push_back(parent);
    }
    if (ready.size() != bodies.size())
      throw std::runtime_error("cyclic graph");
    size_t pos = 0;
    for (auto &block : blocks) {
      size_t start = pos;
      for (U tok : block) {
        if (tok >= 256 && tok - 256 >= bodies.size())
          throw std::runtime_error("graph root");
        if (tok < 256) {
          if (pos >= raw.size() || raw[pos++] != char(tok))
            throw std::runtime_error("source mismatch");
        } else {
          auto &s = spellings[tok - 256];
          if (s.size() > raw.size() - pos || raw.compare(pos, s.size(), s) != 0)
            throw std::runtime_error("source mismatch");
          pos += s.size();
        }
      }
      if (pos - start > 65536)
        throw std::runtime_error("restart raw budget");
    }
    if (pos != raw.size())
      throw std::runtime_error("source mismatch");
  }
};
static void put(std::string &f, U x) {
  char b[4];
  for (U i = 0; i < 4; ++i)
    b[i] = char(x >> (8 * i));
  f.append(b, 4);
}
static void array(std::string &f, const std::vector<U> &x) {
  put(f, U(x.size()));
  for (U n : x)
    put(f, n);
}
static std::string serializeGraph(Graph &g, bool prune) {
  std::vector<U> map(g.bodies.size(), UINT32_MAX), stack;
  if (prune) {
    for (auto &b : g.blocks)
      for (U t : b)
        if (t >= 256 && map[t - 256] == UINT32_MAX) {
          map[t - 256] = 0;
          stack.push_back(t - 256);
        }
    for (size_t i = 0; i < stack.size(); ++i)
      for (U t : g.bodies[stack[i]])
        if (t >= 256 && map[t - 256] == UINT32_MAX) {
          map[t - 256] = 0;
          stack.push_back(t - 256);
        }
  } else
    std::fill(map.begin(), map.end(), 0);
  U count = 0;
  for (U &m : map)
    if (m != UINT32_MAX)
      m = 256 + count++;
  std::vector<U> off{0}, kids, boff{0}, toks;
  for (size_t i = 0; i < g.bodies.size(); ++i)
    if (map[i] != UINT32_MAX) {
      for (U t : g.bodies[i])
        kids.push_back(t < 256 ? t : map[t - 256]);
      off.push_back(U(kids.size()));
    }
  for (auto &b : g.blocks) {
    for (U t : b)
      toks.push_back(t < 256 ? t : map[t - 256]);
    boff.push_back(U(toks.size()));
  }
  std::string f("P6F1");
  array(f, off);
  array(f, kids);
  array(f, boff);
  array(f, toks);
  return f;
}
int main(int argc, char **argv) {
  try {
    if (argc < 5 || argc > 7)
      throw std::runtime_error(
          "usage RAW GRAPH PRICES OUTPUT [payload|spelling|both] [prune0|1]");
    auto raw = read(argv[1], 64 * 1024 * 1024),
         graphBytes = read(argv[2], 128 * 1024 * 1024),
         priceBytes = read(argv[3], 192 * 1024 * 1024);
    std::string mode = argc >= 6 ? argv[5] : "both";
    bool prune = argc >= 7 ? std::stoi(argv[6]) != 0 : false;
    if (argc >= 7 && std::string(argv[6]) != "0" && std::string(argv[6]) != "1")
      throw std::runtime_error("prune policy");
    if (mode != "payload" && mode != "spelling" && mode != "both")
      throw std::runtime_error("mode");
    auto start = std::chrono::steady_clock::now();
    Graph graph;
    graph.load(graphBytes, raw);
    PriceModel prices;
    prices.load(priceBytes, graph.bodies.size());
    std::vector<Seed> seeds;
    seeds.reserve(graph.spellings.size());
    for (auto &s : graph.spellings)
      seeds.push_back({s, 0, 0});
    size_t possibleNodes = 1;
    for (const auto &seed : seeds)
      if (seed.text.size() <= 256)
        possibleNodes += seed.text.size();
    if (possibleNodes > 4000000)
      throw std::runtime_error("trie node budget");
    double bytes[256] = {};
    Parser parser(seeds, bytes);
    parser.model = &prices;
    if (parser.trie.size() > 4000000)
      throw std::runtime_error("trie node budget");
    U changedBodies = 0, changedBlocks = 0;
    if (argc >= 7 && std::string(argv[6]) != "0" && std::string(argv[6]) != "1")
      throw std::runtime_error("prune policy");
    if (mode != "payload")
      for (size_t i = 0; i < graph.bodies.size(); ++i)
        if (graph.spellings[i].size() <= 256) {
          auto body =
              parser.parse(graph.spellings[i], graph.spellings[i].size());
          if (body != graph.bodies[i]) {
            ++changedBodies;
            graph.bodies[i] = std::move(body);
          }
        }
    if (mode != "spelling") {
      size_t pos = 0;
      for (auto &block : graph.blocks) {
        size_t n = 0;
        for (U t : block)
          n += t < 256 ? 1 : graph.spellings[t - 256].size();
        // The bounded trie may omit long existing macros. Preserve their
        // original edges so the previous byte-exact parse remains admissible.
        std::vector<std::pair<size_t, U>> anchors(n);
        size_t at = 0;
        for (U t : block) {
          size_t length = t < 256 ? 1 : graph.spellings[t - 256].size();
          anchors[at] = {at + length, t};
          at += length;
        }
        parser.anchors = &anchors;
        auto next = parser.parse(raw.substr(pos, n));
        parser.anchors = nullptr;
        pos += n;
        if (next != block) {
          ++changedBlocks;
          block = std::move(next);
        }
      }
    }
    auto serialized = serializeGraph(graph, prune);
    auto duration = std::chrono::duration_cast<std::chrono::nanoseconds>(
                        std::chrono::steady_clock::now() - start)
                        .count();
    // File serialization is excluded from the native codec clock.
    std::ofstream output(argv[4], std::ios::binary);
    if (!output)
      throw std::runtime_error("output open");
    output.write(serialized.data(), serialized.size());
    if (!output)
      throw std::runtime_error("output write");
    std::cout << "{\"codec_ns\":" << duration
              << ",\"entries\":" << graph.bodies.size()
              << ",\"input_bytes\":" << raw.size()
              << ",\"classes\":" << prices.classes
              << ",\"conditional_work_cells\":" << parser.work_cells
              << ",\"changed_spellings\":" << changedBodies
              << ",\"changed_blocks\":" << changedBlocks
              << ",\"prune\":" << (prune ? "true" : "false") << ",\"mode\":\""
              << mode << "\"}\n";
  } catch (const std::exception &e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}
