#pragma once

// Research-only global phrase tiler for WGP6. This header has no dependency
// on bz4 internals and emits no frame. Token IDs are opaque uint32 values;
// values >= fence_min are hard boundaries and are copied through unchanged.

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <numeric>
#include <queue>
#include <stdexcept>
#include <unordered_map>
#include <utility>
#include <vector>

namespace wgp6_research {

struct PhraseMdlOptions {
  std::uint32_t fence_min = 0x80000000u;
  std::size_t max_span = 48;
  std::size_t min_occurrences = 4;
  std::size_t candidate_cap = 32000;
  unsigned rounds = 3;  // clamped to [2, 4]
};

struct PhraseMdlStats {
  std::size_t input_symbols = 0;
  std::size_t output_symbols = 0;
  std::size_t suffix_intervals = 0;
  std::size_t bounded_interval_seeds = 0;
  std::size_t candidates = 0;
  std::size_t accepted_rules = 0;
  unsigned rounds_run = 0;
  double before_mdl_bits = 0.0;
  double after_mdl_bits = 0.0;
  std::vector<double> round_mdl_bits;
};

namespace phrase_mdl_detail {

inline std::size_t uleb_bytes(std::uint64_t value) {
  std::size_t bytes = 1;
  while (value >= 0x80u) {
    value >>= 7;
    ++bytes;
  }
  return bytes;
}

struct Candidate {
  std::uint32_t pos = 0;
  std::uint32_t length = 0;
  std::uint32_t support = 0;
  std::uint64_t hash = 0;
  std::uint64_t potential = 0;
};

inline std::uint64_t phrase_hash(const std::vector<std::uint32_t>& stream,
                                 std::size_t pos,
                                 std::size_t length) {
  std::uint64_t h = 1469598103934665603ull;
  for (std::size_t i = 0; i < length; ++i) {
    std::uint32_t x = stream[pos + i];
    for (unsigned j = 0; j != 4; ++j) {
      h ^= static_cast<std::uint8_t>(x >> (8u * j));
      h *= 1099511628211ull;
    }
  }
  h ^= static_cast<std::uint64_t>(length);
  h *= 1099511628211ull;
  return h;
}

inline bool same_phrase(const std::vector<std::uint32_t>& stream,
                        const Candidate& a,
                        const Candidate& b) {
  if (a.length != b.length) return false;
  return std::equal(stream.begin() + a.pos,
                    stream.begin() + a.pos + a.length,
                    stream.begin() + b.pos);
}

inline bool candidate_better(const Candidate& a, const Candidate& b) {
  if (a.potential != b.potential) return a.potential > b.potential;
  if (a.length != b.length) return a.length > b.length;
  if (a.support != b.support) return a.support > b.support;
  return a.pos < b.pos;
}

struct SeedHeapCompare {
  bool operator()(const Candidate& a, const Candidate& b) const {
    // priority_queue top is the least useful seed; keep a bounded set of the
    // best candidates before exact phrase deduplication.
    return candidate_better(a, b);
  }
};

inline std::uint32_t get_rank(const std::vector<std::uint32_t>& rank,
                              std::size_t at,
                              std::size_t offset) {
  return at + offset < rank.size() ? rank[at + offset] + 1u : 0u;
}

inline void counting_sort_suffixes(const std::vector<std::uint32_t>& input,
                                   std::vector<std::uint32_t>& output,
                                   const std::vector<std::uint32_t>& rank,
                                   std::size_t offset,
                                   std::uint32_t classes,
                                   bool second_key) {
  // Key 0 is the out-of-range sentinel. Real class IDs are shifted by one.
  std::vector<std::size_t> counts(static_cast<std::size_t>(classes) + 1, 0);
  auto key_for = [&](std::uint32_t position) -> std::uint32_t {
    if (second_key && static_cast<std::size_t>(position) + offset >= rank.size())
      return 0;
    return (second_key ? rank[static_cast<std::size_t>(position) + offset]
                       : rank[position]) + 1;
  };
  for (std::uint32_t position : input) ++counts[key_for(position)];
  std::size_t prefix = 0;
  for (std::size_t i = 0; i < counts.size(); ++i) {
    const std::size_t count = counts[i];
    counts[i] = prefix;
    prefix += count;
  }
  output.resize(input.size());
  for (std::uint32_t position : input)
    output[counts[key_for(position)]++] = position;
}

inline std::vector<std::uint32_t> suffix_array(
    const std::vector<std::uint32_t>& symbols) {
  const std::size_t n = symbols.size();
  if (n > std::numeric_limits<std::uint32_t>::max())
    throw std::length_error("phrase MDL stream exceeds 32-bit suffix positions");
  std::vector<std::uint32_t> sa(n), rank(n), next_rank(n), scratch;
  std::iota(sa.begin(), sa.end(), 0u);
  std::vector<std::uint32_t> alphabet = symbols;
  std::sort(alphabet.begin(), alphabet.end());
  alphabet.erase(std::unique(alphabet.begin(), alphabet.end()), alphabet.end());
  for (std::size_t i = 0; i < n; ++i) {
    rank[i] = static_cast<std::uint32_t>(
        std::lower_bound(alphabet.begin(), alphabet.end(), symbols[i]) - alphabet.begin());
  }
  std::uint32_t classes = static_cast<std::uint32_t>(alphabet.size());
  for (std::size_t width = 1; classes < n; width *= 2) {
    counting_sort_suffixes(sa, scratch, rank, width, classes, true);
    counting_sort_suffixes(scratch, sa, rank, width, classes, false);
    std::uint32_t new_classes = 1;
    next_rank[sa[0]] = 0;
    for (std::size_t i = 1; i < n; ++i) {
      const std::uint32_t left = sa[i - 1];
      const std::uint32_t right = sa[i];
      const auto left_pair = std::pair<std::uint32_t, std::uint32_t>(
          rank[left], get_rank(rank, left, width));
      const auto right_pair = std::pair<std::uint32_t, std::uint32_t>(
          rank[right], get_rank(rank, right, width));
      if (left_pair != right_pair) ++new_classes;
      next_rank[right] = new_classes - 1;
    }
    rank.swap(next_rank);
    classes = new_classes;
    if (width > n / 2) break;
  }
  return sa;
}

inline std::vector<std::uint32_t> kasai_lcp(
    const std::vector<std::uint32_t>& symbols,
    const std::vector<std::uint32_t>& sa) {
  const std::size_t n = symbols.size();
  std::vector<std::uint32_t> inverse(n), lcp(n, 0);
  for (std::size_t i = 0; i < n; ++i) inverse[sa[i]] = static_cast<std::uint32_t>(i);
  std::size_t matched = 0;
  for (std::size_t position = 0; position < n; ++position) {
    const std::size_t order = inverse[position];
    if (order == 0) continue;
    const std::size_t other = sa[order - 1];
    while (position + matched < n && other + matched < n &&
           symbols[position + matched] == symbols[other + matched])
      ++matched;
    lcp[order] = static_cast<std::uint32_t>(matched);
    if (matched != 0) --matched;
  }
  return lcp;
}

inline std::vector<Candidate> propose_candidates(
    const std::vector<std::uint32_t>& stream,
    const PhraseMdlOptions& options,
    PhraseMdlStats& stats) {
  std::vector<std::uint32_t> ordinary;
  ordinary.reserve(stream.size());
  for (std::uint32_t token : stream)
    if (token < options.fence_min) ordinary.push_back(token);
  std::sort(ordinary.begin(), ordinary.end());
  ordinary.erase(std::unique(ordinary.begin(), ordinary.end()), ordinary.end());
  if (ordinary.empty() || stream.size() < options.min_occurrences * 2) return {};
  if (ordinary.size() + stream.size() >= std::numeric_limits<std::uint32_t>::max())
    throw std::length_error("phrase MDL alphabet exceeds 32-bit suffix ranks");

  std::unordered_map<std::uint32_t, std::uint32_t> token_rank;
  token_rank.reserve(ordinary.size() * 2 + 1);
  for (std::size_t i = 0; i < ordinary.size(); ++i)
    token_rank.emplace(ordinary[i], static_cast<std::uint32_t>(i));

  // Give every fence a different suffix symbol. LCPs therefore stop at a
  // fence even when the original fence value is repeated in the input.
  std::vector<std::uint32_t> symbols(stream.size());
  std::uint32_t next_fence_rank = static_cast<std::uint32_t>(ordinary.size());
  for (std::size_t i = 0; i < stream.size(); ++i) {
    if (stream[i] >= options.fence_min)
      symbols[i] = next_fence_rank++;
    else
      symbols[i] = token_rank.at(stream[i]);
  }

  const std::vector<std::uint32_t> sa = suffix_array(symbols);
  const std::vector<std::uint32_t> lcp = kasai_lcp(symbols, sa);
  const std::size_t raw_seed_cap = std::max<std::size_t>(options.candidate_cap, 1) * 8;
  std::priority_queue<Candidate, std::vector<Candidate>, SeedHeapCompare> heap;
  struct Interval { std::uint32_t depth; std::uint32_t start; };
  std::vector<Interval> stack;
  stack.reserve(64);

  for (std::size_t i = 1; i <= stream.size(); ++i) {
    const std::uint32_t current = i < stream.size() ? lcp[i] : 0;
    std::uint32_t start = static_cast<std::uint32_t>(i - 1);
    while (!stack.empty() && stack.back().depth > current) {
      const Interval interval = stack.back();
      stack.pop_back();
      const std::size_t support = i - interval.start;
      ++stats.suffix_intervals;
      if (support >= options.min_occurrences && interval.depth >= 2) {
        const std::uint32_t position = sa[interval.start];
        const std::size_t length = std::min<std::size_t>(interval.depth, options.max_span);
        if (length >= 2 && position + length <= stream.size() &&
            stream[position] < options.fence_min) {
          bool crosses_fence = false;
          for (std::size_t j = 0; j < length; ++j)
            crosses_fence |= stream[position + j] >= options.fence_min;
          if (!crosses_fence) {
            Candidate candidate;
            candidate.pos = position;
            candidate.length = static_cast<std::uint32_t>(length);
            candidate.support = static_cast<std::uint32_t>(std::min<std::size_t>(
                support, std::numeric_limits<std::uint32_t>::max()));
            candidate.hash = phrase_hash(stream, position, length);
            candidate.potential = static_cast<std::uint64_t>(candidate.support) *
                                  (candidate.length - 1);
            ++stats.bounded_interval_seeds;
            if (heap.size() < raw_seed_cap) {
              heap.push(candidate);
            } else if (candidate_better(candidate, heap.top())) {
              heap.pop();
              heap.push(candidate);
            }
          }
        }
      }
      start = interval.start;
    }
    if (current != 0 && (stack.empty() || stack.back().depth < current))
      stack.push_back({current, start});
  }

  std::vector<Candidate> seeds;
  seeds.reserve(heap.size());
  while (!heap.empty()) {
    seeds.push_back(heap.top());
    heap.pop();
  }
  std::sort(seeds.begin(), seeds.end(), [](const Candidate& a, const Candidate& b) {
    if (a.hash != b.hash) return a.hash < b.hash;
    if (a.length != b.length) return a.length < b.length;
    return a.pos < b.pos;
  });

  std::vector<Candidate> unique;
  for (std::size_t i = 0; i < seeds.size();) {
    std::size_t j = i + 1;
    Candidate best = seeds[i];
    while (j < seeds.size() && seeds[j].hash == seeds[i].hash &&
           seeds[j].length == seeds[i].length) {
      if (same_phrase(stream, best, seeds[j]) &&
          seeds[j].support > best.support)
        best = seeds[j];
      ++j;
    }
    // A 64-bit hash collision can make a bucket contain distinct phrases.
    // Emit every exact phrase in the bucket, not just its first member.
    std::vector<Candidate> bucket;
    for (std::size_t k = i; k < j; ++k) {
      bool merged = false;
      for (Candidate& existing : bucket) {
        if (same_phrase(stream, existing, seeds[k])) {
          existing.support = std::max(existing.support, seeds[k].support);
          existing.potential = static_cast<std::uint64_t>(existing.support) *
                               (existing.length - 1);
          merged = true;
          break;
        }
      }
      if (!merged) bucket.push_back(seeds[k]);
    }
    unique.insert(unique.end(), bucket.begin(), bucket.end());
    i = j;
  }
  std::sort(unique.begin(), unique.end(), candidate_better);
  if (unique.size() > options.candidate_cap) unique.resize(options.candidate_cap);
  std::sort(unique.begin(), unique.end(), [&](const Candidate& a, const Candidate& b) {
    const auto first_a = stream.begin() + a.pos;
    const auto first_b = stream.begin() + b.pos;
    if (std::lexicographical_compare(first_a, first_a + a.length,
                                     first_b, first_b + b.length)) return true;
    if (std::lexicographical_compare(first_b, first_b + b.length,
                                     first_a, first_a + a.length)) return false;
    return a.pos < b.pos;
  });
  stats.candidates = unique.size();
  return unique;
}

inline std::uint64_t edge_key(std::uint32_t state, std::uint32_t token) {
  return (static_cast<std::uint64_t>(state) << 32) | token;
}

struct AcNode {
  std::vector<std::pair<std::uint32_t, std::uint32_t>> edges;
  std::uint32_t fail = 0;
  std::uint32_t output_link = 0;
  std::int32_t terminal = -1;
};

struct AhoCorasick {
  std::vector<AcNode> nodes{1};
  std::unordered_map<std::uint64_t, std::uint32_t> transition;

  explicit AhoCorasick(const std::vector<std::uint32_t>& stream,
                       const std::vector<Candidate>& candidates) {
    std::size_t total_length = 0;
    for (const Candidate& candidate : candidates) total_length += candidate.length;
    nodes.reserve(total_length + 1);
    transition.reserve(total_length * 2 + 1);
    for (std::size_t c = 0; c < candidates.size(); ++c) {
      std::uint32_t state = 0;
      const Candidate& candidate = candidates[c];
      for (std::size_t j = 0; j < candidate.length; ++j) {
        const std::uint32_t token = stream[candidate.pos + j];
        const std::uint64_t key = edge_key(state, token);
        auto found = transition.find(key);
        if (found == transition.end()) {
          const std::uint32_t child = static_cast<std::uint32_t>(nodes.size());
          nodes.emplace_back();
          nodes[state].edges.emplace_back(token, child);
          transition.emplace(key, child);
          state = child;
        } else {
          state = found->second;
        }
      }
      nodes[state].terminal = static_cast<std::int32_t>(c);
    }
    std::queue<std::uint32_t> queue;
    for (const auto& edge : nodes[0].edges) {
      nodes[edge.second].fail = 0;
      nodes[edge.second].output_link = 0;
      queue.push(edge.second);
    }
    while (!queue.empty()) {
      const std::uint32_t state = queue.front();
      queue.pop();
      for (const auto& edge : nodes[state].edges) {
        const std::uint32_t token = edge.first;
        const std::uint32_t child = edge.second;
        std::uint32_t fallback = nodes[state].fail;
        auto found = transition.find(edge_key(fallback, token));
        while (fallback != 0 && found == transition.end()) {
          fallback = nodes[fallback].fail;
          found = transition.find(edge_key(fallback, token));
        }
        if (found != transition.end() && found->second != child)
          nodes[child].fail = found->second;
        else
          nodes[child].fail = 0;
        const std::uint32_t fail_state = nodes[child].fail;
        nodes[child].output_link = nodes[fail_state].terminal >= 0
            ? fail_state : nodes[fail_state].output_link;
        queue.push(child);
      }
    }
  }

  bool step(std::uint32_t& state, std::uint32_t token) const {
    auto found = transition.find(edge_key(state, token));
    while (state != 0 && found == transition.end()) {
      state = nodes[state].fail;
      found = transition.find(edge_key(state, token));
    }
    if (found == transition.end()) {
      state = 0;
      return false;
    }
    state = found->second;
    return true;
  }
};

using Counts = std::unordered_map<std::uint32_t, std::uint64_t>;

inline Counts count_symbols(const std::vector<std::uint32_t>& stream) {
  Counts counts;
  counts.reserve(stream.size() / 2 + 1);
  for (std::uint32_t token : stream) ++counts[token];
  return counts;
}

inline double ideal_symbol_cost(std::uint64_t count,
                                std::size_t total,
                                std::size_t alphabet,
                                double alpha = 0.5) {
  if (total == 0) return 0.0;
  const double denominator = static_cast<double>(total) +
                             alpha * static_cast<double>(std::max<std::size_t>(alphabet, 1));
  const double probability = (static_cast<double>(count) + alpha) / denominator;
  return -std::log2(std::min(1.0, std::max(probability, 1e-300)));
}

inline double definition_bits(std::uint64_t id,
                              const std::vector<std::uint32_t>& phrase) {
  std::uint64_t bytes = uleb_bytes(id) + uleb_bytes(phrase.size());
  for (std::uint32_t child : phrase) bytes += uleb_bytes(child);
  return 8.0 * static_cast<double>(bytes);
}

inline double definition_bits(std::uint64_t id,
                              const std::vector<std::uint32_t>& stream,
                              const Candidate& candidate) {
  std::uint64_t bytes = uleb_bytes(id) + uleb_bytes(candidate.length);
  for (std::size_t j = 0; j < candidate.length; ++j)
    bytes += uleb_bytes(stream[candidate.pos + j]);
  return 8.0 * static_cast<double>(bytes);
}

struct ParseResult {
  std::vector<std::uint32_t> output;
  std::vector<std::uint64_t> uses;
  std::vector<std::int32_t> choice;
  std::vector<std::size_t> predecessor;
};

inline ParseResult weighted_tile(
    const std::vector<std::uint32_t>& stream,
    const std::vector<Candidate>& candidates,
    const std::vector<bool>& active,
    const AhoCorasick& aho,
    const Counts& model_counts,
    std::size_t model_total,
    const std::vector<std::uint64_t>& estimated_uses,
    std::uint64_t next_id,
    std::uint32_t fence_min) {
  const std::size_t n = stream.size();
  const double infinity = std::numeric_limits<double>::infinity();
  std::vector<double> cost(n + 1, infinity);
  std::vector<std::size_t> predecessor(n + 1, 0);
  std::vector<std::int32_t> choice(n + 1, -1);
  std::vector<std::uint64_t> uses(candidates.size(), 0);
  cost[0] = 0.0;
  const std::size_t alphabet = model_counts.size() +
      static_cast<std::size_t>(std::count(active.begin(), active.end(), true));
  std::vector<double> phrase_costs(candidates.size(), infinity);
  for (std::size_t i = 0; i < candidates.size(); ++i) {
    if (!active[i]) continue;
    const std::uint64_t uses = std::max<std::uint64_t>(estimated_uses[i], 1);
    const double source_cost = ideal_symbol_cost(uses, model_total, alphabet);
    const double activation = definition_bits(next_id + i, stream, candidates[i]);
    phrase_costs[i] = source_cost + activation / static_cast<double>(uses);
  }
  std::uint32_t state = 0;

  for (std::size_t i = 0; i < n; ++i) {
    const std::uint32_t token = stream[i];
    const auto found = model_counts.find(token);
    const std::uint64_t count = found == model_counts.end() ? 0 : found->second;
    const double literal_cost = ideal_symbol_cost(count, model_total, alphabet);
    const double literal_total = cost[i] + literal_cost;
    if (literal_total + 1e-12 < cost[i + 1]) {
      cost[i + 1] = literal_total;
      predecessor[i + 1] = i;
      choice[i + 1] = -1;
    }

    if (token >= fence_min) {
      state = 0;
      continue;
    }
    aho.step(state, token);
    std::uint32_t output_node = state;
    while (output_node != 0) {
      const std::int32_t candidate_index = aho.nodes[output_node].terminal;
      if (candidate_index >= 0 && active[static_cast<std::size_t>(candidate_index)]) {
        const Candidate& candidate = candidates[static_cast<std::size_t>(candidate_index)];
        const std::size_t end = i + 1;
        if (end >= candidate.length) {
          const std::size_t start = end - candidate.length;
          const double total = cost[start] +
              phrase_costs[static_cast<std::size_t>(candidate_index)];
          if (total + 1e-12 < cost[end]) {
            cost[end] = total;
            predecessor[end] = start;
            choice[end] = candidate_index;
          }
        }
      }
      output_node = aho.nodes[output_node].output_link;
    }
  }

  if (!std::isfinite(cost[n])) throw std::runtime_error("phrase tiler found no path");
  std::vector<std::pair<std::size_t, std::int32_t>> reverse_ops;
  for (std::size_t end = n; end != 0;) {
    const std::size_t start = predecessor[end];
    const std::int32_t selected = choice[end];
    if (start >= end) throw std::runtime_error("invalid phrase DP predecessor");
    reverse_ops.emplace_back(start, selected);
    if (selected >= 0) ++uses[static_cast<std::size_t>(selected)];
    end = start;
  }
  std::reverse(reverse_ops.begin(), reverse_ops.end());
  ParseResult result;
  result.uses = std::move(uses);
  result.choice = std::move(choice);
  result.predecessor = std::move(predecessor);
  result.output.reserve(n);
  for (const auto& op : reverse_ops) {
    const std::size_t start = op.first;
    if (op.second < 0) {
      result.output.push_back(stream[start]);
    } else {
      result.output.push_back(next_id + static_cast<std::uint64_t>(op.second));
    }
  }
  return result;
}

inline double log2_binomial(std::uint64_t n, std::uint64_t k) {
  if (k > n) return std::numeric_limits<double>::infinity();
  k = std::min(k, n - k);
  if (k == 0) return 0.0;
  const double inv_log2 = 1.0 / std::log(2.0);
  return (std::lgamma(static_cast<double>(n) + 1.0) -
          std::lgamma(static_cast<double>(k) + 1.0) -
          std::lgamma(static_cast<double>(n - k) + 1.0)) * inv_log2;
}

inline double source_mdl_bits(const std::vector<std::uint32_t>& stream,
                              std::size_t active_rules,
                              const std::vector<std::vector<std::uint32_t>>& definitions,
                              std::uint64_t first_new_id) {
  if (stream.empty()) return 0.0;
  std::unordered_map<std::uint32_t, std::uint64_t> counts;
  counts.reserve(stream.size() / 2 + 1);
  for (std::uint32_t token : stream) ++counts[token];
  const std::uint64_t n = stream.size();
  double data_bits = std::lgamma(static_cast<double>(n) + 1.0) / std::log(2.0);
  std::vector<std::pair<std::uint32_t, std::uint64_t>> ordered_counts(counts.begin(), counts.end());
  std::sort(ordered_counts.begin(), ordered_counts.end());
  for (const auto& item : ordered_counts)
    data_bits -= std::lgamma(static_cast<double>(item.second) + 1.0) / std::log(2.0);
  const std::uint64_t k = counts.size();
  const double count_model_bits = log2_binomial(n + k - 1, k - 1);
  double headers = 8.0 * static_cast<double>(uleb_bytes(n) + uleb_bytes(k) +
                                             uleb_bytes(active_rules));
  double grammar_bits = 0.0;
  for (std::size_t i = 0; i < definitions.size(); ++i)
    grammar_bits += definition_bits(first_new_id + i, definitions[i]);
  return data_bits + count_model_bits + headers + grammar_bits;
}

inline std::vector<std::vector<std::uint32_t>> selected_definitions(
    const std::vector<std::uint32_t>& original,
    const std::vector<Candidate>& candidates,
    const std::vector<std::uint64_t>& uses) {
  std::vector<std::vector<std::uint32_t>> definitions;
  for (std::size_t i = 0; i < candidates.size(); ++i) {
    if (uses[i] == 0) continue;
    const Candidate& candidate = candidates[i];
    definitions.emplace_back(original.begin() + candidate.pos,
                             original.begin() + candidate.pos + candidate.length);
  }
  return definitions;
}

}  // namespace phrase_mdl_detail

// Rewrites `stream` in place and appends used phrase definitions to `grammar`.
// Every ordinary stream token must be an index into `grammar`; fences are
// opaque barriers. New phrase IDs are appended deterministically in byte/ID
// lexicographic phrase order. Existing definitions and fences are untouched.
inline PhraseMdlStats add_mdl_phrases(
    std::vector<std::uint32_t>& stream,
    std::vector<std::vector<std::uint32_t>>& grammar,
    const PhraseMdlOptions& requested = {}) {
  using namespace phrase_mdl_detail;
  PhraseMdlStats stats;
  stats.input_symbols = stream.size();
  stats.output_symbols = stream.size();
  if (stream.empty() || requested.max_span < 2 || requested.min_occurrences < 2 ||
      requested.candidate_cap == 0)
    return stats;
  PhraseMdlOptions options = requested;
  options.max_span = std::min<std::size_t>(options.max_span, 48);
  options.candidate_cap = std::min<std::size_t>(options.candidate_cap, 32000);
  options.rounds = std::max(2u, std::min(4u, options.rounds));
  for (std::uint32_t token : stream) {
    if (token < options.fence_min && token >= grammar.size())
      throw std::invalid_argument("ordinary atom ID is outside the supplied grammar");
  }
  if (grammar.size() + options.candidate_cap >= options.fence_min)
    throw std::length_error("phrase IDs would collide with fence range");

  const std::vector<std::uint32_t> original = stream;
  std::vector<Candidate> candidates = propose_candidates(original, options, stats);
  if (candidates.empty()) return stats;
  const AhoCorasick aho(original, candidates);
  std::vector<bool> active(candidates.size(), true);
  Counts model_counts = count_symbols(original);
  std::vector<std::uint64_t> estimated_uses(candidates.size());
  for (std::size_t i = 0; i < candidates.size(); ++i)
    estimated_uses[i] = candidates[i].support;
  std::size_t model_total = original.size();
  const std::uint64_t first_new_id = grammar.size();

  const double baseline = source_mdl_bits(original, 0, {}, first_new_id);
  stats.before_mdl_bits = baseline;
  double best_mdl = baseline;
  ParseResult best_parse;
  std::vector<std::vector<std::uint32_t>> best_definitions;

  for (unsigned round = 0; round < options.rounds; ++round) {
    ++stats.rounds_run;
    ParseResult parsed = weighted_tile(original, candidates, active, aho,
        model_counts, model_total, estimated_uses, first_new_id, options.fence_min);
    std::vector<std::vector<std::uint32_t>> definitions =
        selected_definitions(original, candidates, parsed.uses);

    // The candidate-index IDs used during DP may leave holes. Reassign the
    // actually used definitions contiguously in deterministic phrase order.
    std::vector<std::uint32_t> candidate_to_rule(candidates.size(),
        std::numeric_limits<std::uint32_t>::max());
    std::uint32_t next_rule = 0;
    for (std::size_t i = 0; i < candidates.size(); ++i)
      if (parsed.uses[i] != 0) candidate_to_rule[i] = next_rule++;
    std::vector<std::uint32_t> compact_output;
    compact_output.reserve(parsed.output.size());
    for (std::uint32_t token : parsed.output) {
      if (token < first_new_id || token >= options.fence_min) {
        compact_output.push_back(token);
      } else {
        const std::size_t candidate_index = static_cast<std::size_t>(token - first_new_id);
        if (candidate_index >= candidate_to_rule.size() ||
            candidate_to_rule[candidate_index] == std::numeric_limits<std::uint32_t>::max())
          throw std::runtime_error("DP referenced an unused phrase candidate");
        compact_output.push_back(static_cast<std::uint32_t>(first_new_id +
            candidate_to_rule[candidate_index]));
      }
    }
    Counts next_counts = count_symbols(compact_output);
    const std::vector<std::uint64_t> next_uses = parsed.uses;
    const double objective = source_mdl_bits(compact_output, definitions.size(),
                                               definitions, first_new_id);
    stats.round_mdl_bits.push_back(objective);
    if (objective + 1e-9 < best_mdl) {
      best_mdl = objective;
      best_parse.output = compact_output;
      best_parse.uses = parsed.uses;
      best_definitions = std::move(definitions);
    }

    // Prune candidates not selected by the global DP, recompute the empirical
    // model from its output, then reparse. Full model-plus-data MDL above is
    // the acceptance criterion; this step only narrows later search rounds.
    bool any_active = false;
    for (std::size_t i = 0; i < active.size(); ++i) {
      active[i] = active[i] && next_uses[i] != 0;
      any_active |= active[i];
    }
    estimated_uses = next_uses;
    model_counts = std::move(next_counts);
    model_total = compact_output.size();
    if (!any_active || round + 1 == options.rounds) break;
  }

  if (best_definitions.empty() || !(best_mdl + 1e-9 < baseline)) {
    stats.after_mdl_bits = baseline;
    stats.output_symbols = stream.size();
    return stats;
  }

  stream = std::move(best_parse.output);
  for (auto& definition : best_definitions) grammar.push_back(std::move(definition));
  stats.accepted_rules = best_definitions.size();
  stats.output_symbols = stream.size();
  stats.after_mdl_bits = best_mdl;
  return stats;
}

}  // namespace wgp6_research
