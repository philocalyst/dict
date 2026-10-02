#include "phrase_mdl.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <vector>

static void expand(std::uint32_t token,
                   std::size_t base_size,
                   const std::vector<std::vector<std::uint32_t>>& grammar,
                   std::vector<std::uint32_t>& out) {
  if (token >= 0x80000000u || token < base_size) {
    out.push_back(token);
    return;
  }
  assert(token < grammar.size());
  for (std::uint32_t child : grammar[token])
    expand(child, base_size, grammar, out);
}

int main() {
  constexpr std::uint32_t fence = 0x80000005u;
  std::vector<std::vector<std::uint32_t>> grammar(16);
  std::vector<std::uint32_t> input;
  for (unsigned repeat = 0; repeat < 20; ++repeat) {
    input.insert(input.end(), {1, 7, 3, 12, 1, 7, 3, 12});
    if (repeat == 9) input.push_back(fence);
  }
  const std::vector<std::uint32_t> original = input;
  const std::size_t base_size = grammar.size();

  wgp6_research::PhraseMdlOptions options;
  options.rounds = 3;
  const auto stats = wgp6_research::add_mdl_phrases(input, grammar, options);

  std::vector<std::uint32_t> decoded;
  for (std::uint32_t token : input) expand(token, base_size, grammar, decoded);
  assert(decoded == original);
  for (std::size_t i = base_size; i < grammar.size(); ++i) {
    for (std::uint32_t child : grammar[i]) assert(child < base_size);
  }
  for (std::uint32_t token : input) {
    if (token >= 0x80000000u) assert(token == fence);
  }
  std::cout << "rules=" << stats.accepted_rules
            << " candidates=" << stats.candidates
            << " rounds=" << stats.rounds_run
            << " symbols=" << stats.input_symbols << "->" << stats.output_symbols
            << " mdl=" << stats.before_mdl_bits << "->" << stats.after_mdl_bits
            << '\n';
}
