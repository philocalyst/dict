#include "phrase_mdl.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <random>
#include <vector>

static void expand(std::uint32_t token, std::size_t base_size,
                   const std::vector<std::vector<std::uint32_t>>& grammar,
                   std::vector<std::uint32_t>& out) {
  if (token >= 0x80000000u || token < base_size) {
    out.push_back(token);
    return;
  }
  assert(token < grammar.size());
  for (std::uint32_t child : grammar[token]) expand(child, base_size, grammar, out);
}

int main() {
  constexpr std::size_t base_size = 11;
  std::mt19937 rng(0x57475036u);
  std::uniform_int_distribution<std::uint32_t> atom(0, base_size - 1);
  std::uniform_int_distribution<unsigned> fence_id(0, 2);

  for (unsigned trial = 0; trial < 120; ++trial) {
    std::vector<std::vector<std::uint32_t>> grammar(base_size);
    std::vector<std::uint32_t> input;
    const unsigned phrase_length = 2 + rng() % 9;
    std::vector<std::uint32_t> phrase(phrase_length);
    for (auto& x : phrase) x = atom(rng);
    const unsigned repeats = 2 + rng() % 12;
    for (unsigned r = 0; r < repeats; ++r) {
      if ((rng() & 3u) == 0)
        input.push_back(0x80000000u + fence_id(rng));
      input.insert(input.end(), phrase.begin(), phrase.end());
      if ((rng() & 1u) != 0) input.push_back(atom(rng));
    }
    for (unsigned i = 0, count = rng() % 30; i < count; ++i) {
      if ((rng() & 7u) == 0) input.push_back(0x80000000u + fence_id(rng));
      else input.push_back(atom(rng));
    }
    const auto original = input;

    wgp6_research::PhraseMdlOptions options;
    options.min_occurrences = 2 + (trial % 4);
    options.candidate_cap = 1 + (trial % 31);
    options.max_span = 2 + (trial % 47);
    options.rounds = 2 + (trial % 3);
    const auto stats = wgp6_research::add_mdl_phrases(input, grammar, options);
    assert(stats.rounds_run <= 4);
    assert(grammar.size() <= base_size + options.candidate_cap);

    for (std::size_t i = base_size; i < grammar.size(); ++i) {
      assert(!grammar[i].empty());
      for (std::uint32_t child : grammar[i]) assert(child < base_size);
    }
    std::vector<std::uint32_t> decoded;
    for (std::uint32_t token : input) expand(token, base_size, grammar, decoded);
    if (decoded != original) {
      std::cerr << "round-trip failed at trial " << trial << '\n';
      return 1;
    }
  }
  std::cout << "120 deterministic randomized fence/round-trip cases passed\n";
}
