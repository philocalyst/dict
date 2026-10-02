// AH1: fixed-point nonstationary bit histories. Source-only DEV scorer.
// Log2 below is reporting only; no floating arithmetic reaches prediction.
#include "../context_mixer/squash_table.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr uint32_t Q = 32768;
constexpr size_t Families = 8;
constexpr size_t MapRows = 1u << 18;
constexpr size_t MapWays = 4;
constexpr size_t MatchRows = 1u << 17;
constexpr size_t MatchWays = 4;
constexpr uint32_t MatchWindow = 1u << 20;
constexpr size_t MaxSource = 1u << 24;
constexpr size_t ByteFeatures = 8;
constexpr size_t FinalFeatures = 5;

int64_t signed_div_pow2(int64_t x, unsigned shift) {
    return x / (int64_t(1) << shift);  // C++20 truncates toward zero.
}
uint64_t mix64(uint64_t x) {
    x ^= x >> 30; x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27; x *= 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}
uint32_t clamp_p(int64_t x) { return uint32_t(std::clamp<int64_t>(x, 1, Q - 1)); }
uint32_t advance_p(uint32_t p, bool bit, unsigned shift) {
    int64_t difference = (bit ? int64_t(Q) : 0) - p;
    int64_t delta = signed_div_pow2(difference, shift);
    if (!delta && difference) delta = difference > 0 ? 1 : -1;
    return clamp_p(int64_t(p) + delta);
}

struct Tables {
    std::array<int16_t, Q> stretch{};
    Tables() {
        stretch[0] = -2048;
        for (uint32_t p = 1; p < Q; ++p) {
            if (p <= kSquash[0]) { stretch[p] = -2048; continue; }
            if (p >= kSquash[4096]) { stretch[p] = 2048; continue; }
            auto it = std::lower_bound(std::begin(kSquash), std::end(kSquash), p);
            size_t high = size_t(it - std::begin(kSquash));
            size_t low = high - 1;
            size_t selected = uint32_t(p - kSquash[low]) <= uint32_t(kSquash[high] - p) ? low : high;
            stretch[p] = int16_t(int(selected) - 2048);
        }
    }
    uint32_t squash(int64_t x) const {
        return kSquash[std::clamp<int64_t>(x, -2048, 2048) + 2048];
    }
};

struct Counts { uint16_t zero = 0, one = 0; };
void add_count(Counts& c, bool bit) {
    if (bit) ++c.one; else ++c.zero;
    if (uint32_t(c.one) + c.zero >= 512) {
        c.one = uint16_t((uint32_t(c.one) + 1) >> 1);
        c.zero = uint16_t((uint32_t(c.zero) + 1) >> 1);
    }
}
uint32_t count_probability(const Counts& c) {
    return clamp_p(((uint32_t(c.one) + 1) * Q) / (uint32_t(c.one) + c.zero + 2));
}

struct Cell {
    uint16_t p = Q / 2;
    uint8_t recent = 1;  // sentinel disambiguates early histories
    uint8_t count = 0;
};
struct Row {
    uint64_t value = 0;
    uint32_t meta = 0;
    uint32_t age = 0;
    std::array<Cell, 7> cells{};
    uint8_t last_byte = 0;
    uint8_t run = 0;
    uint8_t used = 0;
    uint8_t reserved = 0;
};
static_assert(sizeof(Cell) == 4);
static_assert(sizeof(Row) == 48);
struct Key { uint64_t value = 0; uint32_t meta = 0; };
struct Ref { Key key; uint8_t slot = 0; uint8_t family = 0; };

uint8_t phase(unsigned bpos) { return bpos < 3 ? 0 : bpos < 6 ? 1 : 2; }
uint8_t high_bits(unsigned bpos, uint16_t prefix) {
    if (bpos < 3) return 0;
    if (bpos < 6) return uint8_t((prefix >> (bpos - 3)) & 7);
    return uint8_t((prefix >> (bpos - 6)) & 63);
}
uint8_t state_slot(unsigned bpos, uint16_t prefix) {
    unsigned inner = bpos < 3 ? bpos : bpos < 6 ? bpos - 3 : bpos - 6;
    if (inner == 0) return 0;
    if (inner == 1) return uint8_t(1 + (prefix & 1));
    return uint8_t(3 + (prefix & 3));
}
uint32_t make_meta(uint8_t family, unsigned bpos, uint16_t prefix,
                   uint8_t len1 = 0, uint8_t len2 = 0) {
    return uint32_t(family) | (uint32_t(phase(bpos)) << 4) |
           (uint32_t(high_bits(bpos, prefix)) << 6) |
           (uint32_t(std::min<unsigned>(len1, 15)) << 12) |
           (uint32_t(std::min<unsigned>(len2, 15)) << 16);
}
Ref byte_ref(uint64_t history, uint32_t at, unsigned order, uint8_t family,
             unsigned bpos, uint16_t prefix) {
    uint64_t mask = order == 8 ? ~uint64_t(0) : ((uint64_t(1) << (8 * order)) - 1);
    return {{history & mask, make_meta(family, bpos, prefix,
                                      uint8_t(std::min<uint32_t>(at, order)), 0)},
            state_slot(bpos, prefix), family};
}

struct HistoryMap {
    std::vector<Row> rows = std::vector<Row>(MapRows);
    std::array<std::array<uint16_t, 256>, Families> state_probability{};
    uint32_t clock = 0, occupied = 0;
    uint64_t replacements = 0, peeks = 0, updates = 0;
    HistoryMap() {
        for (auto& family : state_probability) family.fill(Q / 2);
    }
    size_t first(const Key& key) const {
        return size_t(mix64(key.value ^ mix64(uint64_t(key.meta) * 0x9e3779b97f4a7c15ULL)) &
                      (MapRows / MapWays - 1)) * MapWays;
    }
    const Row* peek(const Key& key) {
        ++peeks;
        size_t start = first(key);
        for (size_t i = 0; i < MapWays; ++i) {
            const Row& row = rows[start + i];
            if (row.used && row.value == key.value && row.meta == key.meta) return &row;
        }
        return nullptr;
    }
    Row& touch(const Key& key) {
        ++updates;
        size_t start = first(key), target = start;
        bool found = false;
        for (size_t i = 0; i < MapWays; ++i) {
            Row& row = rows[start + i];
            if (row.used && row.value == key.value && row.meta == key.meta) {
                target = start + i; found = true; break;
            }
            if (!row.used) { target = start + i; found = true; break; }
            if (row.age < rows[target].age) target = start + i;
        }
        Row& row = rows[target];
        if (!found) { ++replacements; row = Row{}; }
        else if (!row.used) { ++occupied; row = Row{}; }
        row.value = key.value; row.meta = key.meta; row.used = 1; row.age = ++clock;
        return row;
    }
    uint32_t predict(const Ref& ref, uint8_t& previous_state) {
        const Row* row = peek(ref.key);
        const Cell* cell = row ? &row->cells[ref.slot] : nullptr;
        previous_state = cell ? cell->recent : 1;
        uint32_t global = state_probability[ref.family][previous_state];
        if (!cell) return global;
        return clamp_p((uint32_t(cell->count) * cell->p + 8 * global) /
                       (uint32_t(cell->count) + 8));
    }
    void accept(const Ref& ref, uint8_t previous_state, bool bit) {
        uint16_t& global = state_probability[ref.family][previous_state];
        global = uint16_t(advance_p(global, bit, 7));
        Cell& cell = touch(ref.key).cells[ref.slot];
        uint8_t recent = cell.recent;
        bool repeated = ((recent & 15) == 0 || (recent & 15) == 15);
        bool surprise = cell.count >= 4 && repeated &&
                        bool(recent & 1) != bit;
        unsigned shift = surprise || cell.count < 4 ? 2 :
                         cell.count < 16 ? 3 : cell.count < 64 ? 4 : 5;
        cell.p = uint16_t(advance_p(cell.p, bit, shift));
        cell.recent = uint8_t((uint32_t(recent) << 1 | bit) & 255);
        if (cell.count < 255) ++cell.count;
    }
    uint32_t run_probability(const Key& key, unsigned bpos, uint16_t prefix) {
        const Row* row = peek(key);
        if (!row || !row->run) return Q / 2;
        if (uint16_t((uint16_t(row->last_byte) + 256) >> (8 - bpos)) != prefix) return Q / 2;
        bool expected = (row->last_byte >> (7 - bpos)) & 1;
        uint32_t hit = ((uint32_t(row->run) + 1) * Q) / (uint32_t(row->run) + 2);
        return clamp_p(expected ? hit : Q - hit);
    }
    void finish_byte(const Key& key, uint8_t byte) {
        Row& row = touch(key);
        row.run = row.run && row.last_byte == byte
                  ? uint8_t(std::min<unsigned>(255, unsigned(row.run) + 1)) : 1;
        row.last_byte = byte;
    }
};

bool ascii_boundary(uint8_t b) {
    if (b <= 32 || b == 127) return true;
    if (b >= 128) return false;
    return b == ',' || b == '.' || b == ';' || b == ':' || b == '!' ||
           b == '?' || b == '\'' || b == '"' || b == '(' || b == ')' ||
           b == '[' || b == ']' || b == '{' || b == '}' || b == '-' || b == '/';
}
struct Token {
    uint32_t tail = 0;
    uint8_t length = 0;
    void push(uint8_t b) {
        tail = (tail << 8) | b;
        if (length < 15) ++length;
    }
    void clear() { tail = 0; length = 0; }
};
struct TextState {
    Token current{}, previous{};
    Token before_scalar{};
    uint32_t previous_scalar = 0;
    uint8_t scalar_bytes = 0, previous_scalar_bytes = 0, pending = 0, script = 7, boundary = 3;
    uint32_t codepoint = 0, minimum = 0, assembling = 0;
    void finish(uint32_t cp, bool valid) {
        if (!valid) { script = 7; boundary = 3; assembling = 0; scalar_bytes = 0; return; }
        previous_scalar = assembling;
        previous_scalar_bytes = scalar_bytes;
        if (cp < 128) script = 0;
        else if (cp <= 0x024f) script = 1;
        else if (cp >= 0x0370 && cp <= 0x052f) script = 2;
        else if (cp >= 0x0600 && cp <= 0x08ff) script = 3;
        else if (cp >= 0x3040 && cp <= 0x30ff) script = 4;
        else if (cp >= 0x3400 && cp <= 0x9fff) script = 5;
        else if ((cp >= 0xac00 && cp <= 0xd7af) ||
                 (cp >= 0x0900 && cp <= 0x0d7f)) script = 6;
        else script = 7;
        bool space = cp == ' ' || cp == '\t' || cp == '\r' || cp == '\n' || cp == 0x3000;
        bool punct = (cp < 128 && ascii_boundary(uint8_t(cp))) ||
                     cp == 0x3002 || cp == 0xff01 || cp == 0xff1f;
        boundary = space ? 0 : punct ? 1 : script != 7 ? 2 : 3;
        if ((punct || space) && cp >= 128) {
            // The UTF-8 bytes of a separator were added while its scalar
            // was incomplete. Preserve the token as it stood before them.
            current = before_scalar;
            if (current.length) previous = current;
            current.clear();
        }
        assembling = 0; scalar_bytes = 0;
    }
    void feed(uint8_t b) {
        Token prior_token = current;
        if (ascii_boundary(b)) {
            if (current.length) previous = current;
            current.clear();
        } else current.push(b);
        if (pending && b >= 0x80 && b <= 0xbf) {
            assembling = (assembling << 8) | b;
            ++scalar_bytes;
            codepoint = (codepoint << 6) | (b & 63);
            if (--pending == 0)
                finish(codepoint, codepoint >= minimum && codepoint <= 0x10ffff &&
                                  !(codepoint >= 0xd800 && codepoint <= 0xdfff));
            return;
        }
        if (pending) { pending = 0; finish(0, false); }
        if (b < 128) { assembling = b; scalar_bytes = 1; finish(b, true); }
        else if (b >= 0xc2 && b <= 0xdf) {
            before_scalar = prior_token;
            assembling = b; scalar_bytes = 1; codepoint = b & 31; pending = 1; minimum = 0x80;
        } else if (b >= 0xe0 && b <= 0xef) {
            before_scalar = prior_token;
            assembling = b; scalar_bytes = 1; codepoint = b & 15; pending = 2; minimum = 0x800;
        } else if (b >= 0xf0 && b <= 0xf4) {
            before_scalar = prior_token;
            assembling = b; scalar_bytes = 1; codepoint = b & 7; pending = 3; minimum = 0x10000;
        } else { assembling = 0; scalar_bytes = 0; finish(0, false); }
    }
    Ref word_ref(unsigned bpos, uint16_t prefix) const {
        uint64_t value = (uint64_t(previous.tail) << 32) | current.tail;
        return {{value, make_meta(6, bpos, prefix, previous.length, current.length)},
                state_slot(bpos, prefix), 6};
    }
    Ref scalar_ref(unsigned bpos, uint16_t prefix) const {
        uint64_t value = (uint64_t(previous_scalar) << 32) | current.tail;
        return {{value, make_meta(7, bpos, prefix, previous_scalar_bytes, current.length)},
                state_slot(bpos, prefix), 7};
    }
};

struct MatchEntry {
    uint64_t context = 0;
    uint32_t at = 0, age = 0;
};
static_assert(sizeof(MatchEntry) == 16);
struct MatchState {
    std::vector<MatchEntry> entries = std::vector<MatchEntry>(MatchRows);
    std::array<std::array<Counts, 8>, 4> confidence{};
    uint32_t donor = 0, run = 0, clock = 0;
    bool active = false, divergent = false;
    uint64_t replacements = 0, eligible = 0, matched = 0;
    size_t first(uint64_t h) const { return size_t(mix64(h) & (MatchRows / MatchWays - 1)) * MatchWays; }
    unsigned tier() const { return !active ? 0 : run == 0 ? 1 : run < 4 ? 2 : 3; }
    void begin(uint64_t h, uint32_t at) {
        divergent = false;
        if (active && donor < at && at - donor <= MatchWindow) { ++eligible; return; }
        active = false; run = 0;
        if (at < 8) return;
        size_t start = first(h);
        for (size_t i = 0; i < MatchWays; ++i) {
            const MatchEntry& entry = entries[start + i];
            if (entry.age && entry.context == h && entry.at < at &&
                at - entry.at <= MatchWindow) {
                donor = entry.at; active = true; ++eligible; return;
            }
        }
    }
    uint32_t predict(unsigned bpos, uint32_t fallback, const std::vector<uint8_t>& raw) const {
        if (!active || divergent) return fallback;
        bool expected = (raw[donor] >> (7 - bpos)) & 1;
        const Counts& c = confidence[tier()][bpos];
        uint32_t hit = ((uint32_t(c.one) + 1) * Q) /
                       (uint32_t(c.zero) + c.one + 2);
        uint32_t residual = Q - hit;
        return clamp_p(expected ? hit + (residual * fallback) / Q
                                : (residual * fallback) / Q);
    }
    void accept_bit(unsigned bpos, bool bit, const std::vector<uint8_t>& raw) {
        if (!active || divergent) return;
        bool expected = (raw[donor] >> (7 - bpos)) & 1;
        add_count(confidence[tier()][bpos], expected == bit);
        if (expected != bit) divergent = true;
    }
    void finish(uint64_t h, uint32_t at) {
        if (active && !divergent) { ++donor; ++run; ++matched; }
        else { active = false; run = 0; }
        // A padded history of fewer than eight completed bytes is not the
        // exact eight-byte history used by later match queries.
        if (at < 8) return;
        size_t start = first(h), target = start;
        bool found = false;
        for (size_t i = 0; i < MatchWays; ++i) {
            MatchEntry& entry = entries[start + i];
            if (entry.age && entry.context == h) { target = start + i; found = true; break; }
            if (!entry.age) { target = start + i; found = true; break; }
            if (entry.age < entries[target].age) target = start + i;
        }
        if (!found) ++replacements;
        entries[target] = MatchEntry{h, at, ++clock};
    }
};

template <size_t N> struct MixerRow {
    std::array<int16_t, N + 1> weight{};
    std::array<int64_t, N + 1> residual{};
};
template <size_t N> struct Mixer {
    std::vector<MixerRow<N>> rows;
    explicit Mixer(size_t count) : rows(count) {
        for (auto& row : rows) {
            for (size_t i = 0; i < N; ++i) row.weight[i] = int16_t(256 / N);
        }
    }
    uint32_t predict(const Tables& table, uint32_t context,
                     const std::array<uint32_t, N>& probability) const {
        const MixerRow<N>& row = rows.at(context);
        int64_t dot = 0;
        for (size_t i = 0; i < N; ++i)
            dot += int64_t(row.weight[i]) * table.stretch[probability[i]];
        dot += int64_t(row.weight[N]) * 256;
        return clamp_p(table.squash(signed_div_pow2(dot, 8)));
    }
    void accept(const Tables& table, uint32_t context,
                const std::array<uint32_t, N>& probability,
                uint32_t prediction, bool bit) {
        MixerRow<N>& row = rows.at(context);
        std::array<int16_t, N + 1> feature{};
        for (size_t i = 0; i < N; ++i) {
            feature[i] = table.stretch[probability[i]];
        }
        feature[N] = 256;
        int32_t error = (bit ? int32_t(Q) : 0) - int32_t(prediction);
        for (size_t i = 0; i <= N; ++i) {
            row.residual[i] += int64_t(error) * feature[i];
            int64_t delta = row.residual[i] / (int64_t(1) << 24);
            row.residual[i] -= delta * (int64_t(1) << 24);
            int64_t next = int64_t(row.weight[i]) + delta;
            if (next < -512 || next > 512) row.residual[i] = 0;
            row.weight[i] = int16_t(std::clamp<int64_t>(next, -512, 512));
        }
    }
};

struct Model {
    Tables tables;
    HistoryMap map;
    MatchState match;
    Mixer<ByteFeatures> layer1{64};
    Mixer<FinalFeatures> byte_only{128}, word_scalar{128};
    TextState text;
    std::array<Counts, 256> base{};
    uint64_t history = 0, bit_count = 0;
    std::array<std::array<double, 4>, 2> variant_bits{};
    std::array<std::array<double, 4>, 11> expert_bits{};
    Model() = default;
    void accept_byte(uint8_t value, uint32_t at, const std::vector<uint8_t>& raw) {
        constexpr std::array<unsigned, 6> orders{1, 2, 3, 4, 6, 8};
        uint64_t before = history;
        match.begin(before, at);
        uint16_t prefix = 1;
        unsigned section = raw.empty() ? 0 : std::min<unsigned>(3, unsigned((uint64_t(at) * 4) / raw.size()));
        for (unsigned bpos = 0; bpos < 8; ++bpos) {
            bool bit = (value >> (7 - bpos)) & 1;
            std::array<Ref, Families> refs{};
            std::array<uint8_t, Families> prior_state{};
            std::array<uint32_t, Families> p{};
            for (size_t i = 0; i < orders.size(); ++i)
                refs[i] = byte_ref(before, at, orders[i], uint8_t(i), bpos, prefix);
            refs[6] = text.word_ref(bpos, prefix);
            refs[7] = text.scalar_ref(bpos, prefix);
            for (size_t i = 0; i < Families; ++i)
                p[i] = map.predict(refs[i], prior_state[i]);
            uint32_t p_base = count_probability(base[prefix]);
            Ref order2_first = byte_ref(before, at, 2, 1, 0, 1);
            uint32_t p_run = map.run_probability(order2_first.key, bpos, prefix);
            std::array<uint32_t, ByteFeatures> first_inputs{
                p_base, p[0], p[1], p[2], p[3], p[4], p[5], p_run
            };
            uint32_t first_context = bpos | (unsigned(text.script) << 3);
            uint32_t p_first = layer1.predict(tables, first_context, first_inputs);
            uint32_t p_match = match.predict(bpos, p_first, raw);
            uint32_t second_context = bpos | (unsigned(text.boundary) << 3) |
                                      (match.tier() << 5);
            std::array<uint32_t, FinalFeatures> byte_inputs{
                p_first, p_match, p_first, p_first, p_base
            };
            std::array<uint32_t, FinalFeatures> word_inputs{
                p_first, p_match, p[6], p[7], p_base
            };
            uint32_t p_byte = byte_only.predict(tables, second_context, byte_inputs);
            uint32_t p_word = word_scalar.predict(tables, second_context, word_inputs);
            variant_bits[0][section] -= std::log2(double(bit ? p_byte : Q - p_byte) / Q);
            variant_bits[1][section] -= std::log2(double(bit ? p_word : Q - p_word) / Q);
            std::array<uint32_t, 11> expert{p_base, p[0], p[1], p[2], p[3],
                                            p[4], p[5], p_run, p[6], p[7], p_match};
            for (size_t i = 0; i < expert.size(); ++i)
                expert_bits[i][section] -= std::log2(double(bit ? expert[i] : Q - expert[i]) / Q);
            // All three output probabilities were fixed before the bit was
            // revealed, so a range decoder can mirror this update order.
            layer1.accept(tables, first_context, first_inputs, p_first, bit);
            byte_only.accept(tables, second_context, byte_inputs, p_byte, bit);
            word_scalar.accept(tables, second_context, word_inputs, p_word, bit);
            add_count(base[prefix], bit);
            for (size_t i = 0; i < Families; ++i)
                map.accept(refs[i], prior_state[i], bit);
            match.accept_bit(bpos, bit, raw);
            prefix = uint16_t((prefix << 1) | bit);
            ++bit_count;
        }
        Ref order2_first = byte_ref(before, at, 2, 1, 0, 1);
        map.finish_byte(order2_first.key, value);
        match.finish(before, at);
        history = (history << 8) | value;
        text.feed(value);
    }
    uint64_t fixed_state_bytes() const {
        return uint64_t(map.rows.capacity()) * sizeof(Row) +
               uint64_t(match.entries.capacity()) * sizeof(MatchEntry) +
               uint64_t(layer1.rows.capacity()) * sizeof(MixerRow<ByteFeatures>) +
               uint64_t(byte_only.rows.capacity() + word_scalar.rows.capacity()) * sizeof(MixerRow<FinalFeatures>) +
               MatchWindow + sizeof(Model);
    }
};

void emit_sections(const std::array<double, 4>& sections) {
    std::cout << "{\"quarter_bits\":[";
    for (size_t j = 0; j < sections.size(); ++j) {
        if (j) std::cout << ',';
        std::cout << sections[j];
    }
    std::cout << "],\"total_bits\":";
    double total = 0;
    for (double v : sections) total += v;
    std::cout << total << '}';
}
} // namespace

int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("usage: ah_score SOURCE");
        std::ifstream in(argv[1], std::ios::binary);
        if (!in) throw std::runtime_error("cannot open input");
        std::vector<uint8_t> raw((std::istreambuf_iterator<char>(in)), {});
        if (raw.size() > MaxSource) throw std::runtime_error("source exceeds 16 MiB cap");
        Model model;
        if (model.fixed_state_bytes() > 16u * 1024u * 1024u)
            throw std::runtime_error("fixed decoder state exceeds 16 MiB");
        for (size_t i = 0; i < raw.size(); ++i)
            model.accept_byte(raw[i], uint32_t(i), raw);
        std::cout << std::setprecision(12);
        std::cout << "{\"status\":\"development_only_integer_predictor_ideal_bits_not_frame_bytes\",";
        std::cout << "\"source_bytes\":" << raw.size() << ",\"source_bits\":" << model.bit_count;
        std::cout << ",\"fixed_decoder_state_bytes\":" << model.fixed_state_bytes();
        std::cout << ",\"row_bytes\":" << sizeof(Row) << ",\"row_capacity\":" << MapRows;
        std::cout << ",\"row_occupied\":" << model.map.occupied;
        std::cout << ",\"row_replacements\":" << model.map.replacements;
        std::cout << ",\"row_peeks\":" << model.map.peeks;
        std::cout << ",\"row_updates\":" << model.map.updates;
        std::cout << ",\"match_replacements\":" << model.match.replacements;
        std::cout << ",\"match_eligible_bytes\":" << model.match.eligible;
        std::cout << ",\"match_continuation_bytes\":" << model.match.matched;
        std::cout << ",\"variants\":{\"byte_only\":";
        emit_sections(model.variant_bits[0]);
        std::cout << ",\"word_scalar\":";
        emit_sections(model.variant_bits[1]);
        std::cout << "},\"experts\":{";
        const char* names[] = {"partial_byte", "byte1", "byte2", "byte3", "byte4",
                               "byte6", "byte8", "prior_byte_run", "joint_word",
                               "prior_scalar", "causal_match"};
        for (size_t i = 0; i < 11; ++i) {
            if (i) std::cout << ',';
            std::cout << '"' << names[i] << "\":";
            emit_sections(model.expert_bits[i]);
        }
        std::cout << "}}\n";
    } catch (const std::exception& e) {
        std::cerr << "AH1: " << e.what() << '\n';
        return 1;
    }
    return 0;
}
