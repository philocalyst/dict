// Bounded integer bit-context scorer. Development diagnostic, no archive wire.
// All predictions use prior decoded bits; probabilities are quantized to 1/4096.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr uint32_t Q = 4096;
constexpr uint32_t Alpha = 8;
constexpr size_t E = 7;
constexpr uint32_t WeightTotal = 65536;
constexpr uint32_t MatchWindow = 1 << 20;
constexpr size_t MatchSlots = 1 << 18;

uint64_t scramble(uint64_t x) {
    x ^= x >> 30; x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27; x *= 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

struct Row {
    uint64_t history = 0;
    uint16_t prefix = 0;
    uint16_t zeros = 0;
    uint16_t ones = 0;
    uint8_t used = 0;
};

struct ContextTable {
    std::vector<Row> rows;
    size_t occupied = 0;
    uint64_t collisions = 0;
    explicit ContextTable(unsigned slot_bits) : rows(size_t(1) << slot_bits) {}
    size_t index(uint64_t history, uint16_t prefix) const {
        return scramble(history ^ (uint64_t(prefix) * 0x9e3779b97f4a7c15ULL)) & (rows.size() - 1);
    }
    const Row* lookup(uint64_t history, uint16_t prefix) const {
        const Row& row = rows[index(history, prefix)];
        return row.used && row.history == history && row.prefix == prefix ? &row : nullptr;
    }
    uint32_t predict(uint64_t history, uint16_t prefix, uint32_t fallback) const {
        const Row* row = lookup(history, prefix);
        if (!row) return fallback;
        uint32_t total = uint32_t(row->zeros) + row->ones;
        uint32_t probability = (uint32_t(row->ones) * Q + Alpha * fallback) / (total + Alpha);
        return std::clamp(probability, 1u, Q - 1);
    }
    void update(uint64_t history, uint16_t prefix, bool bit) {
        Row& row = rows[index(history, prefix)];
        if (!row.used || row.history != history || row.prefix != prefix) {
            if (row.used) ++collisions;
            else ++occupied;
            row = Row{history, prefix, 0, 0, 1};
        }
        if (bit) ++row.ones;
        else ++row.zeros;
        if (uint32_t(row.ones) + row.zeros >= 512) {
            row.ones = uint16_t((uint32_t(row.ones) + 1) >> 1);
            row.zeros = uint16_t((uint32_t(row.zeros) + 1) >> 1);
        }
    }
};

struct MatchEntry { uint64_t context = 0; uint32_t at = 0; bool used = false; };
struct MatchState {
    std::vector<MatchEntry> table = std::vector<MatchEntry>(MatchSlots);
    std::array<uint32_t, 5> hits{};
    std::array<uint32_t, 5> misses{};
    uint32_t donor = 0;
    uint32_t run = 0;
    bool active = false;
    bool divergent = false;
    uint64_t eligible_bytes = 0;
    uint64_t matched_bytes = 0;
    uint64_t collisions = 0;

    size_t bucket() const {
        if (run == 0) return 0;
        if (run == 1) return 1;
        if (run < 4) return 2;
        if (run < 8) return 3;
        return 4;
    }
    void begin_byte(uint64_t history, uint32_t at) {
        divergent = false;
        if (active && donor < at && at - donor <= MatchWindow) {
            ++eligible_bytes;
            return;
        }
        active = false;
        run = 0;
        if (at < 8) return;
        const MatchEntry& entry = table[scramble(history) & (MatchSlots - 1)];
        if (entry.used && entry.context == history && entry.at < at && at - entry.at <= MatchWindow) {
            donor = entry.at;
            active = true;
            ++eligible_bytes;
        }
    }
    uint32_t predict(unsigned bit_position, uint32_t fallback,
                     const std::vector<uint8_t>& decoded) const {
        if (!active || divergent) return fallback;
        bool predicted_bit = (decoded[donor] >> (7 - bit_position)) & 1;
        size_t b = bucket();
        uint32_t hit_probability = ((hits[b] + 1) * Q) / (hits[b] + misses[b] + 2);
        uint32_t value = predicted_bit
            ? hit_probability + ((Q - hit_probability) * fallback) / Q
            : ((Q - hit_probability) * fallback) / Q;
        return std::clamp(value, 1u, Q - 1);
    }
    void accept_bit(unsigned bit_position, bool bit, const std::vector<uint8_t>& decoded) {
        if (!active || divergent) return;
        bool predicted_bit = (decoded[donor] >> (7 - bit_position)) & 1;
        if (predicted_bit == bit) ++hits[bucket()];
        else { ++misses[bucket()]; divergent = true; }
        if (hits[bucket()] + misses[bucket()] > (1u << 22)) {
            for (size_t i = 0; i < hits.size(); ++i) {
                hits[i] = (hits[i] + 1) >> 1;
                misses[i] = (misses[i] + 1) >> 1;
            }
        }
    }
    void end_byte(uint64_t history_before, uint32_t at) {
        if (active && !divergent) { ++donor; ++run; ++matched_bytes; }
        else { active = false; run = 0; }
        MatchEntry& entry = table[scramble(history_before) & (MatchSlots - 1)];
        if (entry.used && entry.context != history_before) ++collisions;
        entry = MatchEntry{history_before, at, true};
    }
};

struct Model {
    std::array<Row, 256> base{};
    ContextTable one{16}, two{17}, four{18}, eight{18}, word{18};
    MatchState match;
    std::array<std::array<uint32_t, E>, 8> weights{};
    std::array<double, E> losses{};
    double mixture_loss = 0;
    uint64_t history = 0;
    uint64_t word_hash = 1469598103934665603ULL;
    uint32_t word_length = 0;

    Model() {
        for (auto& row : weights) for (auto& w : row) w = WeightTotal / E;
    }
    static bool boundary(uint8_t b) {
        if (b <= 32 || b == 127) return true;
        if (b >= 128) return false;
        return b == ',' || b == '.' || b == ';' || b == ':' || b == '!' ||
               b == '?' || b == '\'' || b == '"' || b == '(' || b == ')' ||
               b == '[' || b == ']' || b == '{' || b == '}' || b == '-' || b == '/';
    }
    void end_word_byte(uint8_t b) {
        if (boundary(b)) { word_hash = 1469598103934665603ULL; word_length = 0; }
        else {
            if (word_length == 16) { word_hash = 1469598103934665603ULL; word_length = 0; }
            word_hash = (word_hash ^ b) * 1099511628211ULL;
            ++word_length;
        }
    }
    static void update_base(Row& row, bool bit) {
        if (bit) ++row.ones;
        else ++row.zeros;
        if (uint32_t(row.ones) + row.zeros >= 512) {
            row.ones = uint16_t((uint32_t(row.ones) + 1) >> 1);
            row.zeros = uint16_t((uint32_t(row.zeros) + 1) >> 1);
        }
    }
    void accept_byte(uint8_t value, uint32_t at, const std::vector<uint8_t>& raw) {
        const uint64_t before = history;
        match.begin_byte(history, at);
        uint16_t prefix = 1;
        for (unsigned bpos = 0; bpos < 8; ++bpos) {
            bool bit = (value >> (7 - bpos)) & 1;
            const Row& zero = base[prefix];
            uint32_t p0 = ((uint32_t(zero.ones) + 1) * Q) /
                          (uint32_t(zero.zeros) + zero.ones + 2);
            uint32_t p1 = one.predict(history & 0xff, prefix, p0);
            uint32_t p2 = two.predict(history & 0xffff, prefix, p1);
            uint32_t p4 = four.predict(history & 0xffffffffULL, prefix, p2);
            uint32_t p8 = eight.predict(history, prefix, p4);
            uint32_t pw = word.predict(word_hash ^ (uint64_t(word_length) << 56), prefix, p2);
            uint32_t pm = match.predict(bpos, p8, raw);
            std::array<uint32_t, E> prediction{p0, p1, p2, p4, p8, pw, pm};
            auto& w = weights[bpos];
            uint64_t weighted = 0, sum_w = 0;
            for (size_t i = 0; i < E; ++i) { weighted += uint64_t(w[i]) * prediction[i]; sum_w += w[i]; }
            uint32_t mixed = std::clamp(uint32_t(weighted / sum_w), 1u, Q - 1);
            mixture_loss -= std::log2(double(bit ? mixed : Q - mixed) / Q);
            std::array<uint64_t, E> posterior{};
            uint64_t posterior_sum = 0;
            for (size_t i = 0; i < E; ++i) {
                uint32_t likelihood = bit ? prediction[i] : Q - prediction[i];
                losses[i] -= std::log2(double(likelihood) / Q);
                posterior[i] = uint64_t(w[i]) * likelihood;
                posterior_sum += posterior[i];
            }
            for (size_t i = 0; i < E; ++i) {
                uint32_t normalized = uint32_t((posterior[i] * WeightTotal) / posterior_sum);
                // Fixed 1/1024 prior injection permits slow deterministic switching.
                w[i] = std::max<uint32_t>(1u, uint32_t((1023 * normalized + WeightTotal / E) / 1024));
            }
            update_base(base[prefix], bit);
            one.update(history & 0xff, prefix, bit);
            two.update(history & 0xffff, prefix, bit);
            four.update(history & 0xffffffffULL, prefix, bit);
            eight.update(history, prefix, bit);
            word.update(word_hash ^ (uint64_t(word_length) << 56), prefix, bit);
            match.accept_bit(bpos, bit, raw);
            prefix = uint16_t((prefix << 1) | bit);
        }
        match.end_byte(before, at);
        history = (history << 8) | value;
        end_word_byte(value);
    }
};

} // namespace

int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("usage: bit_mix_score SOURCE");
        std::ifstream input(argv[1], std::ios::binary);
        if (!input) throw std::runtime_error("cannot open source");
        std::vector<uint8_t> raw((std::istreambuf_iterator<char>(input)), {});
        if (raw.size() > (1u << 24)) throw std::runtime_error("source >16 MiB diagnostic cap");
        Model model;
        for (size_t at = 0; at < raw.size(); ++at) model.accept_byte(raw[at], uint32_t(at), raw);
        const char* names[] = {"base", "byte1", "byte2", "byte4", "byte8", "word", "match"};
        std::cout << std::setprecision(12);
        std::cout << "{\"status\":\"development_only_quantized_ideal_bits_not_frame_bytes\",";
        std::cout << "\"source_bytes\":" << raw.size() << ",\"expert_ideal_bits\":{";
        for (size_t i = 0; i < E; ++i) {
            if (i) std::cout << ',';
            std::cout << '"' << names[i] << "\":" << model.losses[i];
        }
        std::cout << "},\"integer_discounted_mixture_ideal_bits\":" << model.mixture_loss;
        std::cout << ",\"live_contexts\":{";
        std::cout << "\"byte1\":" << model.one.occupied << ",\"byte2\":" << model.two.occupied;
        std::cout << ",\"byte4\":" << model.four.occupied << ",\"byte8\":" << model.eight.occupied;
        std::cout << ",\"word\":" << model.word.occupied << "},\"context_collisions\":{";
        std::cout << "\"byte1\":" << model.one.collisions << ",\"byte2\":" << model.two.collisions;
        std::cout << ",\"byte4\":" << model.four.collisions << ",\"byte8\":" << model.eight.collisions;
        std::cout << ",\"word\":" << model.word.collisions << "},";
        std::cout << "\"match_eligible_bytes\":" << model.match.eligible_bytes;
        std::cout << ",\"match_exact_continuation_bytes\":" << model.match.matched_bytes;
        std::cout << ",\"match_table_collisions\":" << model.match.collisions << "}\n";
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
